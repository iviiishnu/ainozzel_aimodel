import 'package:flutter_app/config.dart';
import 'package:flutter_app/services/analysis_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The only thing standing between a camera result and the pumps is
/// AnalysisService.sendToSprayer: nothing but 'Diseased' may be forwarded.
void main() {
  group('sendToSprayer never forwards non-diseased results', () {
    for (final entry in {
      'Healthy': 'Healthy — no spray',
      'Uncertain': 'Not sure — no spray',
      'NotLeaf': 'Not a leaf — no spray',
      'Error': 'Not sent (no leaf analysed)',
    }.entries) {
      test(entry.key, () async {
        final msg = await AnalysisService.sendToSprayer({
          'status': entry.key,
          // A damage value must not matter for these statuses.
          'damage_percent': 90.0,
          'spray_recommended': true,
        });
        expect(msg, entry.value);
      });
    }

    test('missing status', () async {
      expect(await AnalysisService.sendToSprayer({'damage_percent': 90.0}),
          'Not sent (no leaf analysed)');
    });
  });

  test('a diseased leaf is not sent when Blynk is not configured', () async {
    final msg = await AnalysisService.sendToSprayer(
        {'status': 'Diseased', 'damage_percent': 40.0});
    expect(msg, 'IoT not configured');
  });

  group('severity bands match the server and firmware (15 / 35)', () {
    test('thresholds', () {
      expect(AppConfig.severityFor(0), 'Low');
      expect(AppConfig.severityFor(14.99), 'Low');
      expect(AppConfig.severityFor(15), 'Medium');
      expect(AppConfig.severityFor(34.99), 'Medium');
      expect(AppConfig.severityFor(35), 'High');
      expect(AppConfig.severityFor(100), 'High');
    });

    test('defaults equal the server .env.example', () {
      expect(AppConfig.damageMedium, 15);
      expect(AppConfig.damageHigh, 35);
      expect(AppConfig.confidenceThreshold, 0.50);
      expect(AppConfig.sprayConfidence, 0.60);
      expect(AppConfig.maxHealthyProb, 0.10);
    });
  });
}
