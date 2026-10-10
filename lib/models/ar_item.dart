/// Where an item shows up in the app.
enum ItemKind { menu, scan }

/// Lifecycle of an item's 3D model.
enum ModelStatus {
  /// Photos were uploaded and the cloud is still building the model.
  processing,

  /// A model is available (either already on disk or downloadable from
  /// [ArItem.remoteModelUrl]).
  ready,

  /// Reconstruction failed or expired.
  failed,
}

/// A single thing that can be placed in AR: a menu dish or a scanned object.
class ArItem {
  const ArItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.description = '',
    this.price,
    this.remoteModelUrl,
    this.assetModelPath,
    this.localModelPath,
    this.thumbnailPath,
    this.scanJobId,
    this.modelExtent,
    this.displaySize = 0.25,
    this.error,
  });

  final String id;
  final String name;
  final String description;

  /// Menu price. Null for items that are not for sale.
  final double? price;
  final ItemKind kind;
  final ModelStatus status;
  final DateTime createdAt;

  /// GLB on the web (used by seeded menu items). Downloaded and cached into
  /// [localModelPath] the first time it is shown in AR.
  final String? remoteModelUrl;

  /// GLB bundled with the app (e.g. `assets/models/avocado.glb`). Preferred
  /// over [remoteModelUrl] because it needs no network and is pre-optimized.
  final String? assetModelPath;

  /// GLB path relative to the app documents directory, e.g. `models/<id>.glb`.
  final String? localModelPath;

  /// JPEG path relative to the app documents directory.
  final String? thumbnailPath;

  /// Cloud reconstruction job id while [status] is [ModelStatus.processing].
  final String? scanJobId;

  /// Longest side of the model's bounding box, in model units. Used to scale
  /// the model to [displaySize] in AR.
  final double? modelExtent;

  /// How big the longest side of the model should appear in AR, in meters.
  final double displaySize;

  final String? error;

  bool get isOnMenu => kind == ItemKind.menu;
  bool get canShowInAr =>
      status == ModelStatus.ready &&
      (localModelPath != null ||
          assetModelPath != null ||
          remoteModelUrl != null);

  ArItem copyWith({
    String? name,
    String? description,
    double? price,
    bool clearPrice = false,
    ItemKind? kind,
    ModelStatus? status,
    String? remoteModelUrl,
    String? assetModelPath,
    String? localModelPath,
    bool clearLocalModel = false,
    String? thumbnailPath,
    String? scanJobId,
    bool clearScanJobId = false,
    double? modelExtent,
    double? displaySize,
    String? error,
    bool clearError = false,
  }) {
    return ArItem(
      id: id,
      createdAt: createdAt,
      name: name ?? this.name,
      description: description ?? this.description,
      price: clearPrice ? null : (price ?? this.price),
      kind: kind ?? this.kind,
      status: status ?? this.status,
      remoteModelUrl: remoteModelUrl ?? this.remoteModelUrl,
      assetModelPath: assetModelPath ?? this.assetModelPath,
      localModelPath: clearLocalModel
          ? null
          : (localModelPath ?? this.localModelPath),
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      scanJobId: clearScanJobId ? null : (scanJobId ?? this.scanJobId),
      modelExtent: clearLocalModel
          ? modelExtent
          : (modelExtent ?? this.modelExtent),
      displaySize: displaySize ?? this.displaySize,
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'price': price,
    'kind': kind.name,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'remoteModelUrl': remoteModelUrl,
    'assetModelPath': assetModelPath,
    'localModelPath': localModelPath,
    'thumbnailPath': thumbnailPath,
    'scanJobId': scanJobId,
    'modelExtent': modelExtent,
    'displaySize': displaySize,
    'error': error,
  };

  factory ArItem.fromJson(Map<String, dynamic> json) {
    return ArItem(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      price: (json['price'] as num?)?.toDouble(),
      kind: ItemKind.values.byName(json['kind'] as String? ?? 'scan'),
      status: ModelStatus.values.byName(json['status'] as String? ?? 'ready'),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      remoteModelUrl: json['remoteModelUrl'] as String?,
      assetModelPath: json['assetModelPath'] as String?,
      localModelPath: json['localModelPath'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      scanJobId: json['scanJobId'] as String?,
      modelExtent: (json['modelExtent'] as num?)?.toDouble(),
      displaySize: (json['displaySize'] as num?)?.toDouble() ?? 0.25,
      error: json['error'] as String?,
    );
  }

  /// Builds a menu item from an entry in `assets/menu.json`.
  factory ArItem.fromMenuSeed(Map<String, dynamic> json) {
    return ArItem(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      price: (json['price'] as num?)?.toDouble(),
      kind: ItemKind.menu,
      status: ModelStatus.ready,
      createdAt: DateTime.now(),
      remoteModelUrl: json['modelUrl'] as String?,
      assetModelPath: json['modelAsset'] as String?,
      displaySize: (json['displaySize'] as num?)?.toDouble() ?? 0.25,
    );
  }
}
