// ─────────────────────────────────────────────────────────────────────────────
// RESULT MODEL
// ─────────────────────────────────────────────────────────────────────────────
class TfliteResult {
  final String disease;
  final double confidence;
  final bool isUncertain;
  final double healthyProb; // model probability of the Healthy class
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
