import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'reconstruction_service.dart';

/// Photogrammetry through the KIRI Engine API (https://docs.kiriengine.app).
///
/// The API key is read from `--dart-define=KIRI_API_KEY=...`. For production,
/// put these calls behind your own backend so the key never ships in the app.
class KiriReconstructionService implements ReconstructionService {
  KiriReconstructionService({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  static const _base = 'https://api.kiriengine.app/api/v1/open';
  static const apiKeyFromEnvironment = String.fromEnvironment('KIRI_API_KEY');

  /// Returns null when no API key was provided at build time.
  static KiriReconstructionService? fromEnvironment() =>
      apiKeyFromEnvironment.isEmpty
      ? null
      : KiriReconstructionService(apiKey: apiKeyFromEnvironment);

  final String apiKey;
  final http.Client _client;

  @override
  int get minPhotos => 20;

  @override
  int get maxPhotos => 300;

  Map<String, String> get _auth => {'Authorization': 'Bearer $apiKey'};

  @override
  Future<String> submit(
    List<File> photos, {
    void Function(double progress)? onProgress,
  }) async {
    if (photos.length < minPhotos || photos.length > maxPhotos) {
      throw ReconstructionException(
        'Need between $minPhotos and $maxPhotos photos, got ${photos.length}.',
      );
    }
    final request =
        _ProgressMultipartRequest(
            'POST',
            Uri.parse('$_base/photo/image'),
            onProgress,
          )
          ..headers.addAll(_auth)
          ..fields.addAll({
            'modelQuality': '1', // medium
            'textureQuality':
                '2', // 1K: lighter models load and render smoother in AR
            'fileFormat': 'glb',
            'isMask': '1', // auto-mask the object out of the background
            'textureSmoothing': '0',
          });
    for (final photo in photos) {
      request.files.add(
        await http.MultipartFile.fromPath('imagesFiles', photo.path),
      );
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    final data = _unwrap(response);
    final serial = data['serialize'];
    if (serial is! String || serial.isEmpty) {
      throw ReconstructionException('KIRI did not return a job id.');
    }
    return serial;
  }

  @override
  Future<ReconstructionStatus> status(String jobId) async {
    final response = await _client.get(
      Uri.parse(
        '$_base/model/getStatus',
      ).replace(queryParameters: {'serialize': jobId}),
      headers: _auth,
    );
    return switch (_unwrap(response)['status']) {
      -1 => ReconstructionStatus.uploading,
      0 => ReconstructionStatus.processing,
      1 => ReconstructionStatus.failed,
      2 => ReconstructionStatus.done,
      3 => ReconstructionStatus.queued,
      4 => ReconstructionStatus.expired,
      final other => throw ReconstructionException(
        'Unknown KIRI status: $other',
      ),
    };
  }

  @override
  Future<void> downloadModel(String jobId, File destination) async {
    final response = await _client.get(
      Uri.parse(
        '$_base/model/getModelZip',
      ).replace(queryParameters: {'serialize': jobId}),
      headers: _auth,
    );
    final url = _unwrap(response)['modelUrl'];
    if (url is! String || url.isEmpty) {
      throw ReconstructionException('KIRI did not return a download link.');
    }

    final zip = await _client.get(Uri.parse(url));
    if (zip.statusCode != 200) {
      throw ReconstructionException(
        'Model download failed (HTTP ${zip.statusCode}).',
      );
    }
    final archive = ZipDecoder().decodeBytes(zip.bodyBytes);
    final glb = archive.files.where(
      (f) => f.isFile && f.name.toLowerCase().endsWith('.glb'),
    );
    final bytes = glb.isEmpty ? null : glb.first.readBytes();
    if (bytes == null) {
      throw ReconstructionException(
        'The downloaded archive has no .glb model.',
      );
    }
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes, flush: true);
  }

  /// KIRI wraps every payload as `{code, msg, data, ok}`.
  Map<String, dynamic> _unwrap(http.Response response) {
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    if (body is! Map<String, dynamic>) {
      throw ReconstructionException(
        'Unexpected KIRI response (HTTP ${response.statusCode}).',
      );
    }
    if (response.statusCode != 200 || body['ok'] != true || body['code'] != 0) {
      throw ReconstructionException(
        'KIRI error: ${body['msg'] ?? 'HTTP ${response.statusCode}'}',
      );
    }
    final data = body['data'];
    return data is Map<String, dynamic> ? data : const {};
  }
}

/// Multipart request that reports how many body bytes have been sent.
class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(super.method, super.url, this.onProgress);

  final void Function(double progress)? onProgress;

  @override
  http.ByteStream finalize() {
    final stream = super.finalize();
    final callback = onProgress;
    if (callback == null) return stream;
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(
      stream.transform(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            if (total > 0) callback(sent / total);
            sink.add(chunk);
          },
        ),
      ),
    );
  }
}
