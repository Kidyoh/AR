import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/ar_item.dart';
import '../services/glb_bounds.dart';
import '../services/reconstruction_service.dart';

/// Local-first store for menu items and scanned objects.
///
/// Everything lives under the app documents directory:
///   `items.json`        – the item list
///   `models/<id>.glb`   – 3D models
///   `thumbs/<id>.jpg`   – thumbnails
class ItemStore extends ChangeNotifier {
  ItemStore({
    required this.documentsDir,
    this.reconstruction,
    http.Client? client,
    AssetBundle? assets,
  }) : _client = client ?? http.Client(),
       _assets = assets ?? rootBundle;

  final Directory documentsDir;

  /// Null when no photogrammetry backend is configured; scanning is disabled.
  final ReconstructionService? reconstruction;
  final http.Client _client;
  final AssetBundle _assets;
  final _uuid = const Uuid();

  List<ArItem> _items = [];
  bool _refreshing = false;
  Timer? _poller;

  List<ArItem> get items => List.unmodifiable(_items);
  List<ArItem> get menu => _items.where((i) => i.isOnMenu).toList();
  List<ArItem> get scans => _items.where((i) => !i.isOnMenu).toList();
  bool get hasPendingScans =>
      _items.any((i) => i.status == ModelStatus.processing);

  File get _indexFile => File(p.join(documentsDir.path, 'items.json'));

  /// Absolute path of a file stored relative to the documents directory.
  String absolutePath(String relative) => p.join(documentsDir.path, relative);

  ArItem? byId(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> load() async {
    if (await _indexFile.exists()) {
      final list = jsonDecode(await _indexFile.readAsString()) as List;
      _items = list.cast<Map<String, dynamic>>().map(ArItem.fromJson).toList();
    } else {
      final seed =
          jsonDecode(await _assets.loadString('assets/menu.json')) as List;
      _items = seed
          .cast<Map<String, dynamic>>()
          .map(ArItem.fromMenuSeed)
          .toList();
      await _save();
    }
    notifyListeners();
    _syncPoller();
  }

  Future<void> upsert(ArItem item) async {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index == -1) {
      _items.insert(0, item);
    } else {
      _items[index] = item;
    }
    await _save();
    notifyListeners();
    _syncPoller();
  }

  Future<void> delete(ArItem item) async {
    _items.removeWhere((i) => i.id == item.id);
    for (final relative in [item.localModelPath, item.thumbnailPath]) {
      if (relative == null) continue;
      final file = File(absolutePath(relative));
      if (await file.exists()) await file.delete();
    }
    await _save();
    notifyListeners();
    _syncPoller();
  }

  /// Uploads [photos] for reconstruction and adds a processing item.
  /// The first photo becomes the thumbnail. Photos are deleted afterwards.
  Future<ArItem> createScan({
    required String name,
    required String description,
    required List<File> photos,
    void Function(double progress)? onProgress,
  }) async {
    final service = reconstruction;
    if (service == null) {
      throw ReconstructionException(
        'No 3D reconstruction service is configured.',
      );
    }
    final id = _uuid.v4();
    final jobId = await service.submit(photos, onProgress: onProgress);

    final thumbRelative = p.join('thumbs', '$id.jpg');
    final thumb = File(absolutePath(thumbRelative));
    await thumb.parent.create(recursive: true);
    await photos.first.copy(thumb.path);
    for (final photo in photos) {
      if (await photo.exists()) await photo.delete();
    }

    final item = ArItem(
      id: id,
      name: name,
      description: description,
      kind: ItemKind.scan,
      status: ModelStatus.processing,
      createdAt: DateTime.now(),
      thumbnailPath: thumbRelative,
      scanJobId: jobId,
    );
    await upsert(item);
    return item;
  }

  /// Checks every processing scan and downloads models that are finished.
  Future<void> refreshPending() async {
    final service = reconstruction;
    if (service == null || _refreshing) return;
    _refreshing = true;
    try {
      final pending = _items
          .where(
            (i) => i.status == ModelStatus.processing && i.scanJobId != null,
          )
          .toList();
      for (final item in pending) {
        await _refreshOne(service, item);
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOne(ReconstructionService service, ArItem item) async {
    try {
      final status = await service.status(item.scanJobId!);
      // The user may have deleted the scan while we were waiting.
      if (byId(item.id) == null) return;
      switch (status) {
        case ReconstructionStatus.uploading:
        case ReconstructionStatus.queued:
        case ReconstructionStatus.processing:
          return;
        case ReconstructionStatus.failed:
          await upsert(
            item.copyWith(
              status: ModelStatus.failed,
              error:
                  'The 3D reconstruction failed. Try again with more photos, '
                  'even lighting and a plain background.',
            ),
          );
        case ReconstructionStatus.expired:
          await upsert(
            item.copyWith(
              status: ModelStatus.failed,
              error: 'The scan expired before the model was downloaded.',
            ),
          );
        case ReconstructionStatus.done:
          final relative = p.join('models', '${item.id}.glb');
          final file = File(absolutePath(relative));
          await service.downloadModel(item.scanJobId!, file);
          final bounds = GlbBounds.measure(await file.readAsBytes());
          if (byId(item.id) == null) {
            await file.delete();
            return;
          }
          await upsert(
            item.copyWith(
              status: ModelStatus.ready,
              localModelPath: relative,
              modelExtent: bounds?.extent,
              clearScanJobId: true,
              clearError: true,
            ),
          );
      }
    } catch (e) {
      // Network hiccups are retried on the next poll.
      debugPrint('Refreshing scan ${item.id} failed: $e');
    }
  }

  /// Makes sure [item]'s model is on disk (downloading a remote GLB if
  /// needed) and its size is known. Returns the updated item.
  Future<ArItem> ensureLocalModel(ArItem item) async {
    var current = byId(item.id) ?? item;
    if (current.localModelPath == null ||
        !await File(absolutePath(current.localModelPath!)).exists()) {
      final url = current.remoteModelUrl;
      if (url == null) throw StateError('${current.name} has no 3D model yet.');
      final response = await _client.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw HttpException(
          'Model download failed (HTTP ${response.statusCode})',
        );
      }
      final relative = p.join('models', '${current.id}.glb');
      final file = File(absolutePath(relative));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes, flush: true);
      current = current.copyWith(localModelPath: relative);
    }
    if (current.modelExtent == null) {
      final bytes = await File(absolutePath(current.localModelPath!))
          .readAsBytes();
      final extent = GlbBounds.measure(bytes)?.extent;
      if (extent != null && extent > 0) {
        current = current.copyWith(modelExtent: extent);
      }
    }
    if (current != byId(current.id)) await upsert(current);
    return current;
  }

  /// Polls the backend while scans are processing.
  void _syncPoller() {
    if (hasPendingScans && reconstruction != null) {
      _poller ??= Timer.periodic(
        const Duration(seconds: 20),
        (_) => refreshPending(),
      );
    } else {
      _poller?.cancel();
      _poller = null;
    }
  }

  Future<void> _save() async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(_items.map((i) => i.toJson()).toList()),
      flush: true,
    );
    await tmp.rename(_indexFile.path);
  }

  @override
  void dispose() {
    _poller?.cancel();
    _client.close();
    super.dispose();
  }
}
