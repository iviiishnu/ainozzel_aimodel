import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/tflite_service.dart';

void main() {
  // Mirrors ai_service/ood.py `scores`: 1 − mean cosine similarity to the k
  // nearest (L2-normalised) prototypes.
  final protos = Float32List.fromList([
    1, 0, 0, //
    0, 1, 0, //
    0, 0, 1, //
  ]);

  test('image on a prototype scores 0 with k = 1', () {
    expect(TfliteService.unfamiliarScore([5, 0, 0], protos, 1), closeTo(0, 1e-6));
  });

  test('features are normalised before comparing', () {
    expect(TfliteService.unfamiliarScore([0.01, 0, 0], protos, 1),
        closeTo(TfliteService.unfamiliarScore([100, 0, 0], protos, 1), 1e-6));
  });

  test('averages the k nearest prototypes', () {
    // sims to the three prototypes: 1/√2, 1/√2, 0 → top-2 mean 1/√2
    expect(TfliteService.unfamiliarScore([1, 1, 0], protos, 2),
        closeTo(1 - 0.70710678, 1e-6));
    // top-3 mean (1/√2 + 1/√2 + 0) / 3
    expect(TfliteService.unfamiliarScore([1, 1, 0], protos, 3),
        closeTo(1 - 2 * 0.70710678 / 3, 1e-6));
  });

  test('something unlike every prototype scores high', () {
    expect(TfliteService.unfamiliarScore([-1, -1, -1], protos, 3), greaterThan(1.5));
  });
}
