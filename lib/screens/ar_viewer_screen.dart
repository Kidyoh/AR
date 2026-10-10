import 'dart:async';
import 'dart:io';

import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3, Vector4;

import '../data/item_store.dart';
import '../models/ar_item.dart';
import '../widgets/item_widgets.dart';

/// Scale to hand the AR plugin so the model's longest side is
/// [ArItem.displaySize] meters.
///
/// The platforms interpret scale differently: Android (SceneView) fits the
/// model into a cube of `scale.x` meters, while iOS (SceneKit) multiplies the
/// model's native size, so there we divide by the measured extent.
double arScaleFor(ArItem item, {required bool android}) {
  if (android) return item.displaySize;
  final extent = item.modelExtent;
  if (extent == null || extent <= 0) return 1;
  return item.displaySize / extent;
}

/// The plugin resolves local GLBs differently per platform: iOS appends the
/// uri to the Documents directory, Android loads the path as given.
String arUriFor(ItemStore store, ArItem item, {required bool android}) {
  final relative = item.localModelPath!;
  return android ? store.absolutePath(relative) : relative;
}

/// Opens the AR viewer with a quick fade, which is lighter than a slide while
/// the camera spins up.
Route<void> arViewerRoute(ItemStore store, ArItem item) {
  return PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => ArViewerScreen(store: store, initialItem: item),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

/// Full in-app AR: detect surfaces, tap to place the selected item, drag and
/// rotate placed items. Several items can be placed side by side.
class ArViewerScreen extends StatefulWidget {
  const ArViewerScreen({
    super.key,
    required this.store,
    required this.initialItem,
  });

  final ItemStore store;
  final ArItem initialItem;

  @override
  State<ArViewerScreen> createState() => _ArViewerScreenState();
}

class _ArViewerScreenState extends State<ArViewerScreen> {
  ARSessionManager? _session;
  ARObjectManager? _objects;
  ARAnchorManager? _anchors;

  final _placedAnchors = <ARAnchor>[];
  late ArItem _selected = widget.initialItem;
  bool _loadingModel = false;
  double? _downloadProgress;
  bool _placing = false;
  bool _surfaceFound = false;

  /// Covers the camera view until AR is running, hiding the plugin's
  /// permission/startup flicker.
  bool _arStarted = false;
  bool _coverGone = false;

  /// Short tip shown after the first placement, then faded out.
  bool _showGestureTip = false;
  Timer? _tipTimer;

  ItemStore get store => widget.store;

  List<ArItem> get _choices => (_selected.isOnMenu ? store.menu : store.scans)
      .where((i) => i.canShowInAr)
      .toList();

  @override
  void initState() {
    super.initState();
    _select(widget.initialItem);
    // Warm the other choices too, so switching never waits.
    for (final item in _choices) {
      if (item.id != widget.initialItem.id) {
        store.ensureLocalModel(item).ignore();
      }
    }
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _session?.dispose();
    super.dispose();
  }

  bool _isPrepared(ArItem item) =>
      item.localModelPath != null &&
      (item.modelExtent != null || Platform.isAndroid);

  /// Makes sure the model is on disk before the user taps. Models are
  /// usually prefetched at startup, in which case this is instant.
  Future<void> _select(ArItem item) async {
    final known = store.byId(item.id) ?? item;
    final needsWork = !_isPrepared(known);
    setState(() {
      _selected = known;
      _loadingModel = needsWork;
      _downloadProgress = null;
    });
    try {
      final ready = await store.ensureLocalModel(
        known,
        onProgress: (v) {
          if (mounted && _selected.id == item.id) {
            setState(() => _downloadProgress = v);
          }
        },
      );
      if (mounted && _selected.id == item.id) setState(() => _selected = ready);
    } catch (e) {
      _showError('Could not load ${item.name}. Check your connection.');
    } finally {
      if (mounted && _selected.id == item.id && _loadingModel) {
        setState(() => _loadingModel = false);
      }
    }
  }

  void _onArViewCreated(
    ARSessionManager session,
    ARObjectManager objects,
    ARAnchorManager anchors,
    ARLocationManager location,
  ) {
    _session = session;
    _objects = objects;
    _anchors = anchors;

    session.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      showWorldOrigin: false,
      handlePans: true,
      handleRotation: true,
    );
    objects.onInitialize();
    session.onPlaneOrPointTap = _onTap;
    session.onPlaneDetected = (count) {
      if (!_surfaceFound && count > 0 && mounted) {
        setState(() => _surfaceFound = true);
      }
    };
    session.onError = (error) => _showError(error);
    if (mounted) setState(() => _arStarted = true);
  }

  Future<void> _onTap(List<ARHitTestResult> hits) async {
    final anchors = _anchors;
    final objects = _objects;
    if (anchors == null || objects == null || _loadingModel || _placing) {
      return;
    }

    ARHitTestResult? hit;
    for (final h in hits) {
      if (h.type == ARHitTestResultType.plane) {
        hit = h;
        break;
      }
    }
    final item = _selected;
    if (hit == null || item.localModelPath == null) return;

    _placing = true;
    try {
      final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
      if (await anchors.addAnchor(anchor) != true) {
        _showError('Could not anchor to that surface. Try again.');
        return;
      }

      final android = Platform.isAndroid;
      final node = ARNode(
        type: NodeType.fileSystemAppFolderGLB,
        uri: arUriFor(store, item, android: android),
        scale: Vector3.all(arScaleFor(item, android: android)),
        position: Vector3.zero(),
        rotation: Vector4(1, 0, 0, 0),
        data: {'itemId': item.id},
      );
      if (await objects.addNode(node, planeAnchor: anchor) == true) {
        HapticFeedback.lightImpact();
        final first = _placedAnchors.isEmpty;
        setState(() => _placedAnchors.add(anchor));
        if (first) {
          // Hide the plane grid once something is placed: less visual noise
          // and less to render. Taps on the surface still work.
          _session?.showPlanes(false);
          _flashGestureTip();
        }
      } else {
        anchors.removeAnchor(anchor);
        _showError('Could not display ${item.name}.');
      }
    } finally {
      _placing = false;
    }
  }

  void _flashGestureTip() {
    _tipTimer?.cancel();
    setState(() => _showGestureTip = true);
    _tipTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showGestureTip = false);
    });
  }

  void _clear() {
    for (final anchor in _placedAnchors) {
      _anchors?.removeAnchor(anchor);
    }
    _session?.showPlanes(true);
    setState(_placedAnchors.clear);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String? get _hint {
    if (_loadingModel) {
      final p = _downloadProgress;
      return p == null
          ? 'Preparing ${_selected.name}…'
          : 'Downloading ${_selected.name}… ${(p * 100).round()}%';
    }
    if (!_surfaceFound) return 'Move your phone slowly to find a surface';
    if (_showGestureTip) {
      return 'Drag to move · twist with two fingers to rotate';
    }
    if (_placedAnchors.isEmpty) {
      return 'Tap a surface to place ${_selected.name}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    final hint = _hint;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('AR view'),
        actions: [
          if (_placedAnchors.isNotEmpty)
            TextButton.icon(
              onPressed: _clear,
              icon: const Icon(Icons.layers_clear),
              label: const Text('Clear'),
            ),
        ],
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: _onArViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          if (!_coverGone)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _arStarted,
                child: AnimatedOpacity(
                  opacity: _arStarted ? 0 : 1,
                  duration: const Duration(milliseconds: 350),
                  onEnd: () => setState(() => _coverGone = true),
                  child: const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: hint == null
                    ? const SizedBox.shrink()
                    : _Hint(
                        key: ValueKey(hint),
                        text: hint,
                        busy: _loadingModel,
                      ),
              ),
            ),
          ),
          if (choices.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: 92,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: choices.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => _Choice(
                      key: ValueKey(choices[i].id),
                      store: store,
                      item: choices[i],
                      selected: choices[i].id == _selected.id,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _select(choices[i]);
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.text, required this.busy});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(text, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.store,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final ItemStore store;
  final ArItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 84,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            ItemThumbnail(store: store, item: item, size: 48),
            const SizedBox(height: 4),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
