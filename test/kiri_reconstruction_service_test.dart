import 'dart:convert';
import 'dart:io';

import 'package:ar_menu/services/kiri_reconstruction_service.dart';
import 'package:ar_menu/services/reconstruction_service.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response ok(Map<String, dynamic> data) => http.Response(
  jsonEncode({'code': 0, 'msg': 'success', 'data': data, 'ok': true}),
  200,
);

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('kiri_test'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<List<File>> photos(int n) async => [
    for (var i = 0; i < n; i++)
      await File('${tmp.path}/p$i.jpg').writeAsBytes([i, i, i]),
  ];

  test('submit uploads photos as multipart and returns the serial', () async {
    late http.Request captured;
    final service = KiriReconstructionService(
      apiKey: 'secret',
      client: MockClient((request) async {
        captured = request;
        return ok({'serialize': 'abc123', 'calculateType': 1});
      }),
    );
    final progress = <double>[];

    final id = await service.submit(await photos(20), onProgress: progress.add);

    expect(id, 'abc123');
    expect(captured.method, 'POST');
    expect(
      captured.url.toString(),
      'https://api.kiriengine.app/api/v1/open/photo/image',
    );
    expect(captured.headers['Authorization'], 'Bearer secret');
    final body = latin1.decode(captured.bodyBytes);
    expect('name="imagesFiles"'.allMatches(body).length, 20);
    expect(body, contains('name="fileFormat"\r\n\r\nglb'));
    expect(progress.last, closeTo(1, 1e-9));
  });

  test('submit rejects too few photos without calling the API', () async {
    final service = KiriReconstructionService(
      apiKey: 'k',
      client: MockClient((_) async => fail('should not be called')),
    );
    final few = await photos(5);
    await expectLater(
      service.submit(few),
      throwsA(isA<ReconstructionException>()),
    );
  });

  test('status maps KIRI codes', () async {
    final codes = {
      -1: ReconstructionStatus.uploading,
      0: ReconstructionStatus.processing,
      1: ReconstructionStatus.failed,
      2: ReconstructionStatus.done,
      3: ReconstructionStatus.queued,
      4: ReconstructionStatus.expired,
    };
    for (final entry in codes.entries) {
      final service = KiriReconstructionService(
        apiKey: 'k',
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/open/model/getStatus');
          expect(request.url.queryParameters['serialize'], 'job');
          return ok({'serialize': 'job', 'status': entry.key});
        }),
      );
      expect(await service.status('job'), entry.value);
    }
  });

  test('API errors surface the KIRI message', () async {
    final service = KiriReconstructionService(
      apiKey: 'k',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'code': 2001,
            'msg': 'Insufficient balance',
            'ok': false,
          }),
          200,
        ),
      ),
    );
    await expectLater(
      service.status('job'),
      throwsA(
        isA<ReconstructionException>().having(
          (e) => e.message,
          'message',
          contains('Insufficient balance'),
        ),
      ),
    );
  });

  test('downloadModel extracts the GLB from the zip', () async {
    final glb = [0x67, 0x6C, 0x54, 0x46, 1, 2, 3];
    final zip = ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile('readme.txt', 2, [1, 2]))
        ..addFile(ArchiveFile('scan/model.glb', glb.length, glb)),
    );
    final service = KiriReconstructionService(
      apiKey: 'k',
      client: MockClient((request) async {
        if (request.url.path.endsWith('getModelZip')) {
          return ok({
            'modelUrl': 'https://files.example/model.zip',
            'serialize': 'job',
          });
        }
        expect(request.url.host, 'files.example');
        return http.Response.bytes(zip, 200);
      }),
    );
    final out = File('${tmp.path}/models/out.glb');

    await service.downloadModel('job', out);

    expect(await out.readAsBytes(), glb);
  });
}
