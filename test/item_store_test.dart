import 'dart:convert';
import 'dart:io';

import 'package:ar_menu/data/item_store.dart';
import 'package:ar_menu/models/ar_item.dart';
import 'package:ar_menu/screens/ar_viewer_screen.dart';
import 'package:ar_menu/services/reconstruction_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'glb_test_utils.dart';

String p(Directory dir, String relative) => '${dir.path}/$relative';

class FakeAssets extends CachingAssetBundle {
  FakeAssets(this.files);
  final Map<String, Object> files;

  @override
  Future<ByteData> load(String key) async {
    final file = files[key];
    if (file == null) throw StateError('Missing asset $key');
    final bytes = file is String ? utf8.encode(file) : file as List<int>;
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

class FakeReconstruction implements ReconstructionService {
  ReconstructionStatus next = ReconstructionStatus.processing;
  final Uint8List model = cubeGlb([
    {
      'scale': [0.4, 0.4, 0.4],
      'mesh': 0,
    },
  ]);

  @override
  int get minPhotos => 2;
  @override
  int get maxPhotos => 10;

  @override
  Future<String> submit(
    List<File> photos, {
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(1);
    return 'job-1';
  }

  @override
  Future<ReconstructionStatus> status(String jobId) async => next;

  @override
  Future<void> downloadModel(String jobId, File destination) async {
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(model);
  }
}

void main() {
  late Directory docs;
  late FakeReconstruction backend;
  final seed = jsonEncode([
    {
      'id': 'menu-1',
      'name': 'Soup',
      'price': 5,
      'modelUrl': 'https://models.example/soup.glb',
      'displaySize': 0.2,
    },
  ]);

  ItemStore newStore({http.Client? client}) => ItemStore(
    documentsDir: docs,
    reconstruction: backend,
    assets: FakeAssets({'assets/menu.json': seed}),
    client:
        client ??
        MockClient(
          (_) async => http.Response.bytes(
            cubeGlb([
              {'mesh': 0},
            ]),
            200,
          ),
        ),
  );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('store_test');
    backend = FakeReconstruction();
  });
  tearDown(() async => docs.delete(recursive: true));

  test('seeds the menu on first launch and persists it', () async {
    final store = newStore();
    await store.load();
    expect(store.menu.single.name, 'Soup');
    expect(store.menu.single.price, 5);

    await store.upsert(store.menu.single.copyWith(name: 'Tomato soup'));
    final reloaded = newStore();
    await reloaded.load();
    expect(reloaded.menu.single.name, 'Tomato soup');
    store.dispose();
    reloaded.dispose();
  });

  test('downloads and measures remote menu models once', () async {
    var downloads = 0;
    final store = newStore(
      client: MockClient((_) async {
        downloads++;
        return http.Response.bytes(
          cubeGlb([
            {'mesh': 0},
          ]),
          200,
        );
      }),
    );
    await store.load();

    final first = await store.ensureLocalModel(store.menu.single);
    final second = await store.ensureLocalModel(first);

    expect(downloads, 1);
    expect(first.localModelPath, 'models/menu-1.glb');
    expect(first.modelExtent, closeTo(1, 1e-9));
    expect(
      File(store.absolutePath(first.localModelPath!)).existsSync(),
      isTrue,
    );
    expect(second.modelExtent, first.modelExtent);
    store.dispose();
  });

  test('scan goes from processing to ready with a measured model', () async {
    final store = newStore();
    await store.load();
    final photos = [
      for (var i = 0; i < 3; i++)
        await File('${docs.path}/photo$i.jpg').writeAsBytes([i]),
    ];

    final scan = await store.createScan(
      name: 'Mug',
      description: '',
      photos: photos,
    );
    expect(scan.status, ModelStatus.processing);
    expect(scan.kind, ItemKind.scan);
    expect(File(store.absolutePath(scan.thumbnailPath!)).existsSync(), isTrue);
    expect(photos.every((p) => !p.existsSync()), isTrue);

    await store.refreshPending();
    expect(store.byId(scan.id)!.status, ModelStatus.processing);

    backend.next = ReconstructionStatus.done;
    await store.refreshPending();
    final ready = store.byId(scan.id)!;
    expect(ready.status, ModelStatus.ready);
    expect(ready.canShowInAr, isTrue);
    expect(ready.scanJobId, isNull);
    expect(ready.modelExtent, closeTo(0.4, 1e-9));
    store.dispose();
  });

  test('failed scans keep an explanation', () async {
    final store = newStore();
    await store.load();
    final photo = await File('${docs.path}/a.jpg').writeAsBytes([1]);
    final scan = await store.createScan(
      name: 'Vase',
      description: '',
      photos: [photo, photo],
    );

    backend.next = ReconstructionStatus.failed;
    await store.refreshPending();

    final failed = store.byId(scan.id)!;
    expect(failed.status, ModelStatus.failed);
    expect(failed.error, isNotEmpty);
    expect(failed.canShowInAr, isFalse);
    store.dispose();
  });

  test('AR scale fits the model to its display size on both platforms', () {
    final item = ArItem(
      id: 'x',
      name: 'x',
      kind: ItemKind.scan,
      status: ModelStatus.ready,
      createdAt: DateTime(2026),
      displaySize: 0.3,
      modelExtent: 1.5,
    );
    expect(arScaleFor(item, android: true), 0.3);
    expect(arScaleFor(item, android: false), closeTo(0.2, 1e-9));
  });

  test('items survive a JSON round trip', () {
    final item = ArItem(
      id: 'id',
      name: 'Cake',
      description: 'Chocolate',
      price: 4.25,
      kind: ItemKind.menu,
      status: ModelStatus.failed,
      createdAt: DateTime.utc(2026, 1, 2),
      localModelPath: 'models/id.glb',
      thumbnailPath: 'thumbs/id.jpg',
      scanJobId: 'job',
      modelExtent: 0.5,
      displaySize: 0.15,
      error: 'nope',
    );
    final copy = ArItem.fromJson(jsonDecode(jsonEncode(item.toJson())));
    expect(copy.toJson(), item.toJson());
  });

  group('model loading', () {
    final bundled = cubeGlb([
      {
        'scale': [0.1, 0.1, 0.1],
        'mesh': 0,
      },
    ]);
    final bundledSeed = jsonEncode([
      {
        'id': 'menu-1',
        'name': 'Soup',
        'modelAsset': 'assets/models/soup.glb',
        'modelUrl': 'https://models.example/soup.glb',
      },
    ]);

    ItemStore bundledStore({required http.Client client}) => ItemStore(
      documentsDir: docs,
      assets: FakeAssets({
        'assets/menu.json': bundledSeed,
        'assets/models/soup.glb': bundled,
      }),
      client: client,
    );

    test('bundled models are copied without touching the network', () async {
      final store = bundledStore(
        client: MockClient((_) async => fail('no network expected')),
      );
      await store.load();

      final ready = await store.ensureLocalModel(store.menu.single);

      expect(
        File(store.absolutePath(ready.localModelPath!)).readAsBytesSync(),
        bundled,
      );
      expect(ready.modelExtent, closeTo(0.1, 1e-9));
      store.dispose();
    });

    test(
      'concurrent requests share one download and report progress',
      () async {
        var downloads = 0;
        final store = newStore(
          client: MockClient.streaming((request, _) async {
            downloads++;
            final bytes = cubeGlb([
              {'mesh': 0},
            ]);
            return http.StreamedResponse(
              Stream.fromIterable([bytes.sublist(0, 10), bytes.sublist(10)]),
              200,
              contentLength: bytes.length,
            );
          }),
        );
        await store.load();
        final progress = <double>[];

        final results = await Future.wait([
          store.ensureLocalModel(store.menu.single, onProgress: progress.add),
          store.ensureLocalModel(store.menu.single),
        ]);

        expect(downloads, 1);
        expect(results[0].localModelPath, results[1].localModelPath);
        expect(progress, isNotEmpty);
        expect(progress.last, 1.0);
        expect(
          File(store.absolutePath('models/menu-1.glb.part')).existsSync(),
          isFalse,
        );
        store.dispose();
      },
    );

    test('older installs switch to the bundled model', () async {
      // Saved by a version that downloaded the large remote model.
      final old = ArItem.fromMenuSeed({
        'id': 'menu-1',
        'name': 'My soup',
        'modelUrl': 'https://models.example/soup.glb',
      }).copyWith(localModelPath: 'models/menu-1.glb', modelExtent: 5);
      final oldModel = File(p(docs, 'models/menu-1.glb'));
      await oldModel.create(recursive: true);
      await File(
        p(docs, 'items.json'),
      ).writeAsString(jsonEncode([old.toJson()]));

      final store = bundledStore(
        client: MockClient((_) async => fail('no network expected')),
      );
      await store.load();
      final migrated = store.menu.single;

      expect(migrated.name, 'My soup');
      expect(migrated.assetModelPath, 'assets/models/soup.glb');
      expect(migrated.localModelPath, isNull);
      expect(migrated.modelExtent, isNull);

      final ready = await store.ensureLocalModel(migrated);
      expect(ready.modelExtent, closeTo(0.1, 1e-9));
      store.dispose();
    });

    test('prefetch prepares every viewable model', () async {
      final store = bundledStore(
        client: MockClient((_) async => fail('no network expected')),
      );
      await store.load();

      await store.prefetchModels();

      final item = store.menu.single;
      expect(item.localModelPath, isNotNull);
      expect(item.modelExtent, isNotNull);
      store.dispose();
    });
  });
}
