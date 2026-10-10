import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/item_store.dart';

/// Guided photo capture around a real object, then upload for 3D
/// reconstruction. Pops with a message for the home screen to show.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.store});

  final ItemStore store;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  /// Enough overlap for a clean model: roughly 3 rings of ~15 photos.
  static const _recommendedPhotos = 45;
  static const _autoInterval = Duration(milliseconds: 1200);

  CameraController? _camera;
  String? _cameraError;
  final _photos = <File>[];
  Timer? _autoTimer;
  bool _capturing = false;
  bool _submitted = false;

  ItemStore get store => widget.store;
  int get _minPhotos => store.reconstruction?.minPhotos ?? 20;
  int get _maxPhotos => store.reconstruction?.maxPhotos ?? 300;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (store.reconstruction != null) _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoTimer?.cancel();
    _camera?.dispose();
    if (!_submitted) {
      for (final photo in _photos) {
        photo.delete().ignore();
      }
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopAuto();
      camera.dispose();
      setState(() => _camera = null);
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } on CameraException catch (e) {
      setState(() => _cameraError = e.description ?? e.code);
    } on StateError {
      setState(() => _cameraError = 'No camera found on this device.');
    }
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || _capturing || _photos.length >= _maxPhotos) return;
    _capturing = true;
    try {
      final shot = await camera.takePicture();
      if (mounted) setState(() => _photos.add(File(shot.path)));
    } on CameraException catch (e) {
      debugPrint('Capture failed: ${e.description}');
    } finally {
      _capturing = false;
    }
    if (_photos.length >= _maxPhotos) _stopAuto();
  }

  void _toggleAuto() {
    if (_autoTimer != null) {
      _stopAuto();
    } else {
      setState(
        () => _autoTimer = Timer.periodic(_autoInterval, (_) => _capture()),
      );
    }
  }

  void _stopAuto() {
    _autoTimer?.cancel();
    if (mounted) setState(() => _autoTimer = null);
  }

  void _undo() {
    if (_photos.isEmpty) return;
    final last = _photos.removeLast();
    last.delete().ignore();
    setState(() {});
  }

  Future<void> _finish() async {
    _stopAuto();
    final details = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _DetailsDialog(),
    );
    if (details == null || !mounted) return;

    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UploadDialog(progress: progress),
    );
    try {
      await store.createScan(
        name: details.$1,
        description: details.$2,
        photos: List.of(_photos),
        onProgress: (v) => progress.value = v,
      );
      _submitted = true;
      if (!mounted) return;
      Navigator.of(context)
        ..pop() // upload dialog
        ..pop(
          'Photos uploaded. "${details.$1}" will appear in My scans when its 3D model is ready.',
        );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (store.reconstruction == null) return const _NotConfigured();

    final camera = _camera;
    final count = _photos.length;
    final enough = count >= _minPhotos;
    final auto = _autoTimer != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan object'),
        actions: [
          TextButton(
            onPressed: enough ? _finish : null,
            child: Text(
              'Done',
              style: TextStyle(color: enough ? Colors.white : Colors.white38),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (camera != null && camera.value.isInitialized)
                  Center(child: CameraPreview(camera))
                else
                  Center(
                    child: _cameraError != null
                        ? Text(
                            _cameraError!,
                            style: const TextStyle(color: Colors.white),
                          )
                        : const CircularProgressIndicator(),
                  ),
                const IgnorePointer(child: _FramingGuide()),
                Positioned(
                  left: 16,
                  right: 16,
                  top: 12,
                  child: _Instructions(count: count, min: _minPhotos),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: LinearProgressIndicator(
              value: (count / _recommendedPhotos).clamp(0.0, 1.0),
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Text(
            '$count photos · ${enough ? 'ready to build' : 'need at least $_minPhotos'}'
            ' · $_recommendedPhotos+ recommended',
            style: const TextStyle(color: Colors.white70),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Remove last photo',
                    onPressed: count > 0 ? _undo : null,
                    icon: const Icon(Icons.undo),
                    color: Colors.white,
                    iconSize: 30,
                  ),
                  _ShutterButton(onPressed: auto ? null : _capture),
                  IconButton(
                    tooltip: auto ? 'Stop auto capture' : 'Auto capture',
                    onPressed: camera == null ? null : _toggleAuto,
                    icon: Icon(
                      auto ? Icons.pause_circle : Icons.motion_photos_auto,
                    ),
                    color: auto ? Colors.redAccent : Colors.white,
                    iconSize: 34,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions({required this.count, required this.min});

  final int count;
  final int min;

  @override
  Widget build(BuildContext context) {
    final tip = count == 0
        ? 'Put the object on a plain surface with even light. Keep it inside the frame.'
        : count < 15
        ? 'Walk slowly around the object at table height.'
        : count < 30
        ? 'Now go around again from a higher angle, looking down.'
        : 'Finish with a lap close to the top so the whole object is covered.';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(tip, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

/// Corner brackets to help keep the object centered.
class _FramingGuide extends StatelessWidget {
  const _FramingGuide();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.7,
        child: AspectRatio(
          aspectRatio: 1,
          child: CustomPaint(painter: _BracketPainter()),
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final l = size.shortestSide * 0.15;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, l)
      ..lineTo(0, 0)
      ..lineTo(l, 0)
      ..moveTo(w - l, 0)
      ..lineTo(w, 0)
      ..lineTo(w, l)
      ..moveTo(w, h - l)
      ..lineTo(w, h)
      ..lineTo(w - l, h)
      ..moveTo(l, h)
      ..lineTo(0, h)
      ..lineTo(0, h - l);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onPressed == null ? Colors.white24 : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _DetailsDialog extends StatefulWidget {
  const _DetailsDialog();

  @override
  State<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<_DetailsDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name, _description.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('What did you scan?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Build 3D model')),
      ],
    );
  }
}

class _UploadDialog extends StatelessWidget {
  const _UploadDialog({required this.progress});

  final ValueListenable<double> progress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Uploading photos'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value > 0 ? value : null),
              const SizedBox(height: 12),
              Text('${(value * 100).round()}%'),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan object')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          '3D scanning needs a photogrammetry backend.\n\n'
          'Run the app with your KIRI Engine API key:\n\n'
          'flutter run --dart-define=KIRI_API_KEY=your_key',
        ),
      ),
    );
  }
}
