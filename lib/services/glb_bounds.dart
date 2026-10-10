import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Reads the bounding box of a binary glTF (.glb) without loading geometry.
///
/// glTF requires POSITION accessors to carry `min`/`max`, so the box can be
/// computed from the JSON chunk alone by pushing each mesh's local box through
/// its node's world transform.
class GlbBounds {
  GlbBounds._(this.min, this.max);

  final Vector3 min;
  final Vector3 max;

  Vector3 get size => max - min;

  /// Longest side of the box, in model units (meters by glTF convention).
  double get extent => math.max(size.x, math.max(size.y, size.z));

  static const _magic = 0x46546C67; // "glTF"
  static const _jsonChunk = 0x4E4F534A; // "JSON"

  /// Returns null when [bytes] is not a GLB or contains no measurable mesh.
  static GlbBounds? measure(Uint8List bytes) {
    final json = _readJson(bytes);
    if (json == null) return null;

    final nodes = (json['nodes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final meshes =
        (json['meshes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final accessors =
        (json['accessors'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    Vector3? lo;
    Vector3? hi;
    void include(Vector3 p) {
      lo ??= p.clone();
      hi ??= p.clone();
      Vector3.min(lo!, p, lo!);
      Vector3.max(hi!, p, hi!);
    }

    void includeMesh(int meshIndex, Matrix4 world) {
      if (meshIndex >= meshes.length) return;
      final primitives =
          (meshes[meshIndex]['primitives'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          [];
      for (final primitive in primitives) {
        final position = (primitive['attributes'] as Map?)?['POSITION'];
        if (position is! int || position >= accessors.length) continue;
        final a = accessors[position];
        final mn = _vec3(a['min']);
        final mx = _vec3(a['max']);
        if (mn == null || mx == null) continue;
        for (final corner in _corners(mn, mx)) {
          include(world.transformed3(corner));
        }
      }
    }

    final visited = <int>{};
    void visit(int index, Matrix4 parent) {
      if (index >= nodes.length || !visited.add(index)) return;
      final node = nodes[index];
      final world = parent.multiplied(_localMatrix(node));
      final mesh = node['mesh'];
      if (mesh is int) includeMesh(mesh, world);
      for (final child in (node['children'] as List?) ?? const []) {
        if (child is int) visit(child, world);
      }
    }

    final scenes =
        (json['scenes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final sceneIndex = json['scene'] as int? ?? 0;
    if (sceneIndex < scenes.length) {
      for (final root in (scenes[sceneIndex]['nodes'] as List?) ?? const []) {
        if (root is int) visit(root, Matrix4.identity());
      }
    }

    // No scene graph: fall back to raw mesh boxes.
    if (lo == null) {
      for (var i = 0; i < meshes.length; i++) {
        includeMesh(i, Matrix4.identity());
      }
    }

    if (lo == null || hi == null) return null;
    return GlbBounds._(lo!, hi!);
  }

  static Map<String, dynamic>? _readJson(Uint8List bytes) {
    if (bytes.lengthInBytes < 20) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != _magic) return null;
    final chunkLength = data.getUint32(12, Endian.little);
    final chunkType = data.getUint32(16, Endian.little);
    if (chunkType != _jsonChunk || 20 + chunkLength > bytes.lengthInBytes) {
      return null;
    }
    final text = utf8.decode(bytes.sublist(20, 20 + chunkLength));
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static Matrix4 _localMatrix(Map<String, dynamic> node) {
    final matrix = node['matrix'];
    if (matrix is List && matrix.length == 16) {
      // glTF matrices are column-major, same as vector_math.
      return Matrix4.fromList(
        matrix.map((e) => (e as num).toDouble()).toList(),
      );
    }
    final t = _vec3(node['translation']) ?? Vector3.zero();
    final s = _vec3(node['scale']) ?? Vector3.all(1);
    final r = node['rotation'];
    final q = r is List && r.length == 4
        ? Quaternion(
            (r[0] as num).toDouble(),
            (r[1] as num).toDouble(),
            (r[2] as num).toDouble(),
            (r[3] as num).toDouble(),
          )
        : Quaternion.identity();
    return Matrix4.compose(t, q, s);
  }

  static Vector3? _vec3(Object? value) {
    if (value is! List || value.length < 3) return null;
    return Vector3(
      (value[0] as num).toDouble(),
      (value[1] as num).toDouble(),
      (value[2] as num).toDouble(),
    );
  }

  static Iterable<Vector3> _corners(Vector3 mn, Vector3 mx) sync* {
    for (final x in [mn.x, mx.x]) {
      for (final y in [mn.y, mx.y]) {
        for (final z in [mn.z, mx.z]) {
          yield Vector3(x, y, z);
        }
      }
    }
  }
}
