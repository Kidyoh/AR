import 'package:flutter/material.dart';

import '../data/item_store.dart';
import '../models/ar_item.dart';
import '../widgets/item_widgets.dart';
import 'ar_viewer_screen.dart';
import 'item_detail_screen.dart';
import 'scan_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.store});

  final ItemStore store;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  ItemStore get store => widget.store;

  void _openAr(ArItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArViewerScreen(store: store, initialItem: item),
      ),
    );
  }

  void _openDetails(ArItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ItemDetailScreen(store: store, itemId: item.id),
      ),
    );
  }

  Future<void> _startScan() async {
    final message = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => ScanScreen(store: store)));
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final onMenu = _tab == 0;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = onMenu ? store.menu : store.scans;
        final firstReady = items.where((i) => i.canShowInAr);
        return Scaffold(
          appBar: AppBar(
            title: Text(onMenu ? 'Menu' : 'My scans'),
            actions: [
              if (firstReady.isNotEmpty)
                IconButton(
                  tooltip: onMenu
                      ? 'Place dishes on your table'
                      : 'View scans in AR',
                  icon: const Icon(Icons.view_in_ar),
                  onPressed: () => _openAr(firstReady.first),
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: store.refreshPending,
            child: items.isEmpty
                ? _EmptyState(onMenu: onMenu)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: items.length,
                    itemBuilder: (context, i) => ItemTile(
                      store: store,
                      item: items[i],
                      onTap: () => _openDetails(items[i]),
                      onViewInAr: () => _openAr(items[i]),
                    ),
                  ),
          ),
          floatingActionButton: onMenu
              ? null
              : FloatingActionButton.extended(
                  onPressed: _startScan,
                  icon: const Icon(Icons.threed_rotation),
                  label: const Text('Scan object'),
                ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.restaurant_menu_outlined),
                selectedIcon: Icon(Icons.restaurant_menu),
                label: 'Menu',
              ),
              NavigationDestination(
                icon: Icon(Icons.view_in_ar_outlined),
                selectedIcon: Icon(Icons.view_in_ar),
                label: 'Scans',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onMenu});

  final bool onMenu;

  @override
  Widget build(BuildContext context) {
    // ListView so pull-to-refresh still works when empty.
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(
          onMenu ? Icons.restaurant_menu : Icons.threed_rotation,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 16),
        Text(
          onMenu
              ? 'No dishes on the menu yet.\nScan a dish and add it to the menu.'
              : 'Scan any object to turn it into a 3D model you can place in AR.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ],
    );
  }
}
