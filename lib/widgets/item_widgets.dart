import 'dart:io';

import 'package:flutter/material.dart';

import '../data/item_store.dart';
import '../models/ar_item.dart';

String formatPrice(double price) => '\$${price.toStringAsFixed(2)}';

/// Square thumbnail for an item, falling back to an icon.
class ItemThumbnail extends StatelessWidget {
  const ItemThumbnail({
    super.key,
    required this.store,
    required this.item,
    this.size = 56,
  });

  final ItemStore store;
  final ArItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = item.thumbnailPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox.square(
        dimension: size,
        child: thumb != null
            ? Image.file(File(store.absolutePath(thumb)), fit: BoxFit.cover)
            : ColoredBox(
                color: scheme.secondaryContainer,
                child: Icon(
                  item.isOnMenu ? Icons.restaurant : Icons.view_in_ar,
                  color: scheme.onSecondaryContainer,
                  size: size * 0.45,
                ),
              ),
      ),
    );
  }
}

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.store,
    required this.item,
    required this.onTap,
    required this.onViewInAr,
  });

  final ItemStore store;
  final ArItem item;
  final VoidCallback onTap;
  final VoidCallback onViewInAr;

  @override
  Widget build(BuildContext context) {
    final subtitle = switch (item.status) {
      ModelStatus.processing => 'Building 3D model…',
      ModelStatus.failed => 'Scan failed',
      ModelStatus.ready =>
        item.price != null
            ? formatPrice(item.price!)
            : (item.description.isNotEmpty
                  ? item.description
                  : '3D model ready'),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: ItemThumbnail(store: store, item: item),
        title: Text(item.name),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
        trailing: switch (item.status) {
          ModelStatus.processing => const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          ModelStatus.failed => Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          ModelStatus.ready => IconButton.filledTonal(
            tooltip: 'View in AR',
            icon: const Icon(Icons.view_in_ar),
            onPressed: item.canShowInAr ? onViewInAr : null,
          ),
        },
      ),
    );
  }
}
