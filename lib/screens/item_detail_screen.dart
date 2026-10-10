import 'package:flutter/material.dart';

import '../data/item_store.dart';
import '../models/ar_item.dart';
import '../widgets/item_widgets.dart';
import 'ar_viewer_screen.dart';

class ItemDetailScreen extends StatelessWidget {
  const ItemDetailScreen({
    super.key,
    required this.store,
    required this.itemId,
  });

  final ItemStore store;
  final String itemId;

  Future<void> _edit(BuildContext context, ArItem item) async {
    final updated = await showModalBottomSheet<ArItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EditItemSheet(item: item),
    );
    if (updated != null) await store.upsert(updated);
  }

  Future<void> _delete(BuildContext context, ArItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${item.name}?'),
        content: const Text(
          'Its 3D model and photo will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      Navigator.of(context).pop();
      await store.delete(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final item = store.byId(itemId);
        if (item == null) return const Scaffold();
        final text = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(
            title: Text(item.name),
            actions: [
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(context, item),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(context, item),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: ItemThumbnail(store: store, item: item, size: 200),
              ),
              const SizedBox(height: 20),
              Text(item.name, style: text.headlineSmall),
              if (item.price != null) ...[
                const SizedBox(height: 4),
                Text(formatPrice(item.price!), style: text.titleMedium),
              ],
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(item.description, style: text.bodyLarge),
              ],
              const SizedBox(height: 20),
              _StatusCard(item: item),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: item.canShowInAr
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ArViewerScreen(store: store, initialItem: item),
                        ),
                      )
                    : null,
                icon: const Icon(Icons.view_in_ar),
                label: const Text('View in AR'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => store.upsert(
                  item.copyWith(
                    kind: item.isOnMenu ? ItemKind.scan : ItemKind.menu,
                  ),
                ),
                icon: Icon(
                  item.isOnMenu
                      ? Icons.remove_circle_outline
                      : Icons.add_circle_outline,
                ),
                label: Text(item.isOnMenu ? 'Remove from menu' : 'Add to menu'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.item});

  final ArItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, title, body) = switch (item.status) {
      ModelStatus.processing => (
        Icons.hourglass_top,
        scheme.tertiary,
        'Building 3D model',
        'Your photos are being turned into a 3D model in the cloud. '
            'This page updates automatically when it is ready.',
      ),
      ModelStatus.failed => (
        Icons.error_outline,
        scheme.error,
        'Scan failed',
        item.error ?? 'Something went wrong while building the model.',
      ),
      ModelStatus.ready => (
        Icons.check_circle_outline,
        scheme.primary,
        '3D model ready',
        'Shown about ${(item.displaySize * 100).round()} cm across in AR.',
      ),
    };
    return Card.outlined(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(body),
      ),
    );
  }
}

class _EditItemSheet extends StatefulWidget {
  const _EditItemSheet({required this.item});

  final ArItem item;

  @override
  State<_EditItemSheet> createState() => _EditItemSheetState();
}

class _EditItemSheetState extends State<_EditItemSheet> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _description = TextEditingController(
    text: widget.item.description,
  );
  late final _price = TextEditingController(
    text: widget.item.price?.toStringAsFixed(2) ?? '',
  );
  late bool _onMenu = widget.item.isOnMenu;
  late double _size = widget.item.displaySize;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _price.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final price = double.tryParse(_price.text.trim().replaceAll(',', '.'));
    Navigator.pop(
      context,
      widget.item.copyWith(
        name: name,
        description: _description.text.trim(),
        price: price,
        clearPrice: price == null,
        kind: _onMenu ? ItemKind.menu : ItemKind.scan,
        displaySize: _size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description'),
            textCapitalization: TextCapitalization.sentences,
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            decoration: const InputDecoration(
              labelText: 'Price',
              prefixText: '\$ ',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show on menu'),
            value: _onMenu,
            onChanged: (v) => setState(() => _onMenu = v),
          ),
          Text('Size in AR: ${(_size * 100).round()} cm'),
          Slider(
            value: _size,
            min: 0.05,
            max: 1.0,
            divisions: 19,
            onChanged: (v) => setState(() => _size = v),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
