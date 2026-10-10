import 'dart:async';

import 'package:flutter/cupertino.dart';
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
  runApp(ArMenuApp(store: store));
  // Warm up models after the first frame so opening AR never waits.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(store.prefetchModels());
    unawaited(store.refreshPending());
  });
}

class ArMenuApp extends StatelessWidget {
  const ArMenuApp({super.key, required this.store});

  final ItemStore store;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFE4572E);
    const transitions = PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    );
    return MaterialApp(
      title: 'AR Menu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: seed,
        useMaterial3: true,
        pageTransitionsTheme: transitions,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
        pageTransitionsTheme: transitions,
      ),
      home: HomeScreen(store: store),
    );
  }
}
