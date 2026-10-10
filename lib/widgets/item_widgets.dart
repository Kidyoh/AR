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
    this.hero = false,
  });

  final ItemStore store;
  final ArItem item;
  final double size;

  /// Fly the thumbnail between the list and the detail page.
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = item.thumbnailPath;
    // Decode at display size: full-size camera photos make lists stutter.
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final child = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox.square(
        dimension: size,
        child: thumb != null
            ? Image.file(
                File(store.absolutePath(thumb)),
                fit: BoxFit.cover,
                cacheWidth: cacheSize,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: child,
                      ),
              )
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
    return hero ? Hero(tag: 'thumb-${item.id}', child: child) : child;
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
        leading: ItemThumbnail(store: store, item: item, hero: true),
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
