import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/item_store.dart';
import 'screens/home_screen.dart';
import 'services/kiri_reconstruction_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = ItemStore(
    documentsDir: await getApplicationDocumentsDirectory(),
    reconstruction: KiriReconstructionService.fromEnvironment(),
  );
  await store.load();
  unawaited(store.refreshPending());
  runApp(ArMenuApp(store: store));
}

class ArMenuApp extends StatelessWidget {
  const ArMenuApp({super.key, required this.store});

  final ItemStore store;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFE4572E);
    return MaterialApp(
      title: 'AR Menu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomeScreen(store: store),
    );
  }
}
