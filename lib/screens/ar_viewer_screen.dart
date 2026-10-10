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
  bool _surfaceFound = false;

  ItemStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _select(widget.initialItem);
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  /// Downloads/measures the model up front so placing it is instant.
  Future<void> _select(ArItem item) async {
    setState(() {
      _selected = item;
      _loadingModel = true;
    });
    try {
      final ready = await store.ensureLocalModel(item);
      if (mounted && _selected.id == item.id) setState(() => _selected = ready);
    } catch (e) {
      _showError('Could not load ${item.name}: $e');
    } finally {
      if (mounted && _selected.id == item.id) {
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
  }

  Future<void> _onTap(List<ARHitTestResult> hits) async {
    final anchors = _anchors;
    final objects = _objects;
    if (anchors == null || objects == null || _loadingModel) return;

    ARHitTestResult? hit;
    for (final h in hits) {
      if (h.type == ARHitTestResultType.plane) {
        hit = h;
        break;
      }
    }
    final item = _selected;
    if (hit == null || item.localModelPath == null) return;

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
      setState(() => _placedAnchors.add(anchor));
    } else {
      anchors.removeAnchor(anchor);
      _showError('Could not display ${item.name}.');
    }
  }

  void _clear() {
    for (final anchor in _placedAnchors) {
      _anchors?.removeAnchor(anchor);
    }
    setState(_placedAnchors.clear);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final choices = (_selected.isOnMenu ? store.menu : store.scans)
        .where((i) => i.canShowInAr)
        .toList();
    final hint = _loadingModel
        ? 'Loading ${_selected.name}…'
        : !_surfaceFound
        ? 'Move your phone slowly to find a surface'
        : 'Tap a surface to place ${_selected.name}';

    return Scaffold(
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
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: _Hint(text: hint, busy: _loadingModel),
          ),
          if (choices.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: choices.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => _Choice(
                    store: store,
                    item: choices[i],
                    selected: choices[i].id == _selected.id,
                    onTap: () => _select(choices[i]),
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
  const _Hint({required this.text, required this.busy});

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
      child: Container(
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
