// ─────────────────────────────────────────────────────────────────────────────
// RESULT MODEL
// ─────────────────────────────────────────────────────────────────────────────
class TfliteResult {
  final String disease;
  final double confidence;
  final bool isUncertain;
  final double healthyProb; // model probability of the Healthy class
  final double notLeafProb; // model probability of the Not_Leaf class
  /// Highest-probability class, even when below the confidence threshold
  /// ([disease] is then 'Uncertain').
  final String topClass;
  /// Most likely disease (Healthy and Not_Leaf excluded) and its probability.
  final String bestDisease;
  final double bestDiseaseProb;
  /// Share of the frame that looks like plant tissue (HSV colour test).
  final double leafFraction;
  final bool leafDetected;
  /// How unlike every training leaf the image is (ood.py); null = check off.
  final double? unfamiliarScore;
  final double? unfamiliarThreshold;
  final double damagePercent;
  final List<double> allProbs;
  final int inferenceMs;
  // Time per step: platform decode (Live Scan only), crop/resize/quality in
  // the background isolate, and everything end to end.
  final int decodeMs, prepareMs, totalMs;

  const TfliteResult({
    required this.disease,
    required this.confidence,
    required this.isUncertain,
    required this.healthyProb,
    required this.notLeafProb,
    required this.topClass,
    required this.bestDisease,
    required this.bestDiseaseProb,
    required this.leafFraction,
    required this.leafDetected,
    this.unfamiliarScore,
    this.unfamiliarThreshold,
    required this.damagePercent,
    required this.allProbs,
    required this.inferenceMs,
    this.decodeMs = 0,
    this.prepareMs = 0,
    this.totalMs = 0,
  });

  double get confidencePercent => confidence * 100;

  /// Probability the leaf is diseased at all: 1 - P(Healthy) - P(Not_Leaf).
  /// Same as inference.spray_score() on the server.
  double get sprayScore => (1.0 - healthyProb - notLeafProb).clamp(0.0, 1.0);

  /// Looks like no real training leaf (e.g. a leaf-print shirt) → never spray.
  bool get isUnfamiliar =>
      unfamiliarScore != null && unfamiliarScore! > unfamiliarThreshold!;

  @override
  String toString() =>
      'TfliteResult(disease: $disease, confidence: ${confidencePercent.toStringAsFixed(1)}%, '
      'damage: $damagePercent%, leaf: $leafDetected, '
      'unfamiliar: ${unfamiliarScore?.toStringAsFixed(3)}/${unfamiliarThreshold?.toStringAsFixed(3)}, '
      'ms: decode $decodeMs + prepare $prepareMs + model $inferenceMs = $totalMs)';
}
