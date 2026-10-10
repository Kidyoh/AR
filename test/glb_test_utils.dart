import 'dart:convert';
import 'dart:typed_data';

/// Builds a minimal GLB containing only a JSON chunk.
Uint8List buildGlb(Map<String, dynamic> json) {
  var jsonBytes = utf8.encode(jsonEncode(json));
  // Chunks are 4-byte aligned and padded with spaces.
  final padding = (4 - jsonBytes.length % 4) % 4;
  jsonBytes = Uint8List.fromList([...jsonBytes, ...List.filled(padding, 0x20)]);
  final total = 12 + 8 + jsonBytes.length;
  final data = ByteData(total)
    ..setUint32(0, 0x46546C67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, total, Endian.little)
    ..setUint32(12, jsonBytes.length, Endian.little)
    ..setUint32(16, 0x4E4F534A, Endian.little);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(20, total, jsonBytes);
  return bytes;
}

/// A unit cube mesh (-0.5..0.5) placed under [nodes].
Uint8List cubeGlb(
  List<Map<String, dynamic>> nodes, {
  List<int> roots = const [0],
}) {
  return buildGlb({
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {'nodes': roots},
    ],
    'nodes': nodes,
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
          },
        ],
      },
    ],
    'accessors': [
      {
        'componentType': 5126,
        'count': 8,
        'type': 'VEC3',
        'min': [-0.5, -0.5, -0.5],
        'max': [0.5, 0.5, 0.5],
      },
    ],
  });
}
