import 'dart:typed_data';

import 'package:ar_menu/services/glb_bounds.dart';
import 'package:flutter_test/flutter_test.dart';

import 'glb_test_utils.dart';

void main() {
  test('measures a plain mesh', () {
    final bounds = GlbBounds.measure(
      cubeGlb([
        {'mesh': 0},
      ]),
    )!;
    expect(bounds.extent, closeTo(1, 1e-9));
  });

  test('applies TRS transforms through the node hierarchy', () {
    final bounds = GlbBounds.measure(
      cubeGlb([
        {
          'scale': [2, 2, 2],
          'children': [1],
        },
        {
          'translation': [10, 0, 0],
          'scale': [1, 3, 1],
          'mesh': 0,
        },
      ]),
    )!;
    // Child is 1x3x1, parent doubles it -> 2x6x2; translation 10 -> x in 19..21.
    expect(bounds.extent, closeTo(6, 1e-9));
    expect(bounds.min.x, closeTo(19, 1e-9));
    expect(bounds.max.x, closeTo(21, 1e-9));
  });

  test('applies column-major matrices and rotations', () {
    // Scale 0.01 like many exported models (e.g. centimeters).
    final matrix = [0.01, 0, 0, 0, 0, 0.01, 0, 0, 0, 0, 0.01, 0, 0, 0, 0, 1];
    final scaled = GlbBounds.measure(
      cubeGlb([
        {'matrix': matrix, 'mesh': 0},
      ]),
    )!;
    expect(scaled.extent, closeTo(0.01, 1e-9));

    // 90 degrees around Z swaps the X and Y sizes.
    final rotated = GlbBounds.measure(
      cubeGlb([
        {
          'rotation': [0, 0, 0.7071067811865476, 0.7071067811865476],
          'scale': [4, 1, 1],
          'mesh': 0,
        },
      ]),
    )!;
    expect(rotated.size.x, closeTo(1, 1e-9));
    expect(rotated.size.y, closeTo(4, 1e-9));
  });

  test('returns null for non-GLB data', () {
    expect(GlbBounds.measure(Uint8List.fromList(List.filled(64, 1))), isNull);
    expect(GlbBounds.measure(Uint8List(0)), isNull);
  });
}
