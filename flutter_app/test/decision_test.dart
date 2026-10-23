import 'package:flutter_app/config.dart';
import 'package:flutter_app/services/analysis_service.dart';
import 'package:flutter_app/services/tflite_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors ai_service/tests/test_inference.py: the app and the server must
/// make the same spray decision for the same model output.
TfliteResult result({
  String top = 'Rust',
  double conf = 0.95,
  double healthy = 0.02,
  double notLeaf = 0.01,
  String bestDisease = 'Rust',
  double bestDiseaseProb = 0.95,
  double leafFraction = 0.5,
  double? unfamiliar,
}) {
  final uncertain = conf < AppConfig.confidenceThreshold;
  return TfliteResult(
    disease: uncertain ? 'Uncertain' : top,
    confidence: conf,
    isUncertain: uncertain,
    healthyProb: healthy,
    notLeafProb: notLeaf,
    topClass: top,
    bestDisease: bestDisease,
    bestDiseaseProb: bestDiseaseProb,
    leafFraction: leafFraction,
    leafDetected: leafFraction >= 0.10,
    unfamiliarScore: unfamiliar,
    unfamiliarThreshold: unfamiliar == null ? null : 0.40,
    damagePercent: 20.0,
    allProbs: const [],
    inferenceMs: 1,
  );
}

Map<String, dynamic> decide(TfliteResult r) => AnalysisService.decide(r);

void main() {
  tearDown(() => AppConfig.sprayRule = 'confidence');

  group('leaf pre-check', () {
    test('almost no plant colour is rejected even if the model is sure', () {
      final d = decide(result(leafFraction: 0.01, conf: 0.99));
      expect(d['status'], 'Error');
      expect(d['error'], 'No leaf detected.');
    });

    test('dark diseased leaf (fraction 0.05) with a confident result passes', () {
      final d = decide(result(leafFraction: 0.05, conf: 0.95));
      expect(d['status'], 'Diseased');
      expect(d['spray_recommended'], true);
    });

    test('dark frame with a not-quite-confident result is rejected', () {
      expect(decide(result(leafFraction: 0.05, conf: 0.70))['status'], 'Error');
      expect(
          decide(result(leafFraction: 0.05, top: 'Not_Leaf', conf: 0.99))['status'],
          'Error');
    });

    test('dark frame, confident Healthy, passes and never sprays', () {
      final d = decide(result(
          leafFraction: 0.05, top: 'Healthy', conf: 0.95, healthy: 0.95));
      expect(d['status'], 'Healthy');
      expect(d['spray_recommended'], false);
    });
  });

  group('confidence rule (default)', () {
    test('confident disease sprays', () {
      expect(decide(result())['spray_recommended'], true);
    });

    test('confidence split between two diseases does not spray', () {
      final d = decide(result(top: 'Anthracnose', conf: 0.38, healthy: 0.05));
      expect(d['status'], 'Uncertain');
      expect(d['spray_recommended'], false);
    });

    test('real chance of Healthy blocks the spray', () {
      expect(decide(result(conf: 0.80, healthy: 0.15))['spray_recommended'], false);
    });

    test('Healthy and Not_Leaf never spray', () {
      expect(decide(result(top: 'Healthy', conf: 0.97, healthy: 0.97))['spray_recommended'], false);
      expect(decide(result(top: 'Not_Leaf', conf: 0.9))['status'], 'NotLeaf');
    });

    test('unfamiliar image never sprays', () {
      expect(decide(result(unfamiliar: 0.6))['spray_recommended'], false);
    });
  });

  group('score rule', () {
    setUp(() => AppConfig.sprayRule = 'score');

    test('split disease confidence now sprays, naming the likeliest disease', () {
      final d = decide(result(
          top: 'Anthracnose',
          conf: 0.38,
          healthy: 0.05,
          notLeaf: 0.02,
          bestDisease: 'Anthracnose',
          bestDiseaseProb: 0.38));
      expect(d['status'], 'Diseased');
      expect(d['spray_recommended'], true);
      expect(d['disease'], 'Anthracnose');
      expect(d['spray_score_percent'], closeTo(93.0, 1e-9));
    });

    test('Healthy leaf does not spray', () {
      final d = decide(result(top: 'Healthy', conf: 0.9, healthy: 0.9));
      expect(d['status'], 'Healthy');
      expect(d['spray_recommended'], false);
    });

    test('Not_Leaf does not spray', () {
      final d = decide(result(top: 'Not_Leaf', conf: 0.6, notLeaf: 0.6, healthy: 0.05));
      expect(d['spray_recommended'], false);
    });

    test('below the threshold does not spray; above does', () {
      expect(decide(result(healthy: 0.31, notLeaf: 0.0, conf: 0.69, bestDiseaseProb: 0.69))['spray_recommended'], false);
      expect(decide(result(healthy: 0.29, notLeaf: 0.0, conf: 0.71, bestDiseaseProb: 0.71))['spray_recommended'], true);
    });

    test('unfamiliar image is still blocked', () {
      expect(decide(result(unfamiliar: 0.6))['spray_recommended'], false);
    });
  });

  test('sprayScore matches the server formula', () {
    expect(result(healthy: 0.2, notLeaf: 0.1).sprayScore, closeTo(0.7, 1e-9));
  });
}
