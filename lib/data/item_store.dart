import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
///   `thumbs/<id>.png`   – small thumbnails
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

  /// In-flight model preparations, so concurrent callers share one load.
  final _modelLoads = <String, Future<ArItem>>{};

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
    final seedJson =
        jsonDecode(await _assets.loadString('assets/menu.json')) as List;
    final seed = seedJson
        .cast<Map<String, dynamic>>()
        .map(ArItem.fromMenuSeed)
        .toList();
    if (await _indexFile.exists()) {
      final list = jsonDecode(await _indexFile.readAsString()) as List;
      _items = list.cast<Map<String, dynamic>>().map(ArItem.fromJson).toList();
      if (_adoptBundledModels(seed)) await _save();
    } else {
      _items = seed;
      await _save();
    }
    notifyListeners();
    _syncPoller();
  }

  /// Points seeded menu items saved by an older version at the optimized
  /// models now bundled with the app. Returns true if anything changed.
  bool _adoptBundledModels(List<ArItem> seed) {
    var changed = false;
    for (final seeded in seed) {
      final asset = seeded.assetModelPath;
      final index = _items.indexWhere((i) => i.id == seeded.id);
      if (asset == null || index == -1) continue;
      final item = _items[index];
      if (item.assetModelPath == asset) continue;
      final old = item.localModelPath;
      if (old != null) File(absolutePath(old)).delete().ignore();
      _items[index] = item.copyWith(
        assetModelPath: asset,
        clearLocalModel: true,
      );
      changed = true;
    }
    return changed;
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

    final thumbRelative = p.join('thumbs', '$id.png');
    await _writeThumbnail(photos.first, File(absolutePath(thumbRelative)));
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
      // The user may have deleted or edited the scan while we were waiting.
      final latest = byId(item.id);
      if (latest == null) return;
      switch (status) {
        case ReconstructionStatus.uploading:
        case ReconstructionStatus.queued:
        case ReconstructionStatus.processing:
          return;
        case ReconstructionStatus.failed:
          await upsert(
            latest.copyWith(
              status: ModelStatus.failed,
              error:
                  'The 3D reconstruction failed. Try again with more photos, '
                  'even lighting and a plain background.',
            ),
          );
        case ReconstructionStatus.expired:
          await upsert(
            latest.copyWith(
              status: ModelStatus.failed,
              error: 'The scan expired before the model was downloaded.',
            ),
          );
        case ReconstructionStatus.done:
          final relative = p.join('models', '${item.id}.glb');
          final file = File(absolutePath(relative));
          await service.downloadModel(item.scanJobId!, file);
          final bounds = GlbBounds.measure(await file.readAsBytes());
          final current = byId(item.id);
          if (current == null) {
            await file.delete();
            return;
          }
          await upsert(
            current.copyWith(
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

  /// Makes sure [item]'s model is on disk (copying a bundled GLB or
  /// downloading a remote one if needed) and its size is known.
  /// [onProgress] reports download progress from 0 to 1.
  Future<ArItem> ensureLocalModel(
    ArItem item, {
    void Function(double progress)? onProgress,
  }) {
    // Block body on purpose: returning the removed Future from the callback
    // would make whenComplete wait on itself.
    return _modelLoads[item.id] ??= _prepareModel(item, onProgress)
        .whenComplete(() {
          _modelLoads.remove(item.id);
        });
  }

  /// Prepares every model in the background so opening AR is instant.
  Future<void> prefetchModels() async {
    for (final item in List.of(_items)) {
      if (!item.canShowInAr) continue;
      try {
        await ensureLocalModel(item);
      } catch (e) {
        debugPrint('Prefetching ${item.name} failed: $e');
      }
    }
  }

  Future<ArItem> _prepareModel(
    ArItem item,
    void Function(double progress)? onProgress,
  ) async {
    var current = byId(item.id) ?? item;
    final local = current.localModelPath;
    if (local == null || !await File(absolutePath(local)).exists()) {
      final relative = p.join('models', '${current.id}.glb');
      final file = File(absolutePath(relative));
      await file.parent.create(recursive: true);
      final asset = current.assetModelPath;
      if (asset != null) {
        final data = await _assets.load(asset);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      } else if (current.remoteModelUrl != null) {
        await _download(Uri.parse(current.remoteModelUrl!), file, onProgress);
      } else {
        throw StateError('${current.name} has no 3D model yet.');
      }
      current = current.copyWith(localModelPath: relative);
    }
    if (current.modelExtent == null) {
      final bytes = await File(
        absolutePath(current.localModelPath!),
      ).readAsBytes();
      final extent = GlbBounds.measure(bytes)?.extent;
      if (extent != null && extent > 0) {
        current = current.copyWith(modelExtent: extent);
      }
    }
    // Skip saving if the item was deleted meanwhile.
    final stored = byId(current.id);
    if (stored != null && current != stored) {
      await upsert(
        stored.copyWith(
          localModelPath: current.localModelPath,
          modelExtent: current.modelExtent,
        ),
      );
      return byId(current.id)!;
    }
    return current;
  }

  /// Streams [url] into [file] via a temp file, reporting progress.
  Future<void> _download(
    Uri url,
    File file,
    void Function(double progress)? onProgress,
  ) async {
    final response = await _client.send(http.Request('GET', url));
    if (response.statusCode != 200) {
      throw HttpException(
        'Model download failed (HTTP ${response.statusCode})',
      );
    }
    final total = response.contentLength ?? 0;
    final tmp = File('${file.path}.part');
    final sink = tmp.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.close();
    }
    await tmp.rename(file.path);
  }

  /// Saves a small PNG copy of [photo] so lists never decode full-size
  /// camera images. Falls back to copying the original.
  Future<void> _writeThumbnail(File photo, File dest) async {
    await dest.parent.create(recursive: true);
    try {
      final codec = await ui.instantiateImageCodec(
        await photo.readAsBytes(),
        targetWidth: 400,
      );
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (png == null) throw StateError('PNG encoding failed');
      await dest.writeAsBytes(png.buffer.asUint8List(), flush: true);
    } catch (e) {
      debugPrint('Thumbnail resize failed, keeping original: $e');
      await photo.copy(dest.path);
    }
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
