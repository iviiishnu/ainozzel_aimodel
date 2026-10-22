import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'api_service.dart';
import 'blynk_service.dart';
import 'tflite_service.dart';

/// Single place that turns an image into a result and forwards it to the
/// sprayer. Used by both the photo screen and the live camera screen.
///
/// Result map keys (same as the server JSON):
///   status: 'Healthy' | 'Diseased' | 'Uncertain' | 'NotLeaf' | 'Error'
///   disease, confidence_percent, damage_percent, severity,
///   spray_recommended, message, source, inference_ms, error
///
/// Only 'Diseased' sprays. Healthy, Uncertain and NotLeaf never run the motor.
class AnalysisService {
  AnalysisService._();

  /// [liveFrame]: a USB-camera frame from Live Scan. Always analysed on the
  /// tablet (fast decode + colour fix) — never waits for the server, so a
  /// scan stays well under 3 s.
  static Future<Map<String, dynamic>> analyze(File image,
      {bool liveFrame = false}) async {
    if (liveFrame) {
      if (!TfliteService.isLoaded) return _error('On-device model not loaded');
      try {
        return await _onDevice(image, true);
      } catch (e) {
        return _error('On-device analysis failed: $e');
      }
    }

    final onDevice = AppConfig.useOnDevice && TfliteService.isLoaded;
    if (!onDevice) {
      try {
        final result = await ApiService.uploadImage(image);
        result['source'] = 'server';
        return _normalize(result);
      } on ServerUnavailableException catch (e) {
        if (!TfliteService.isLoaded) return _error(e.message);
        debugPrint('Server unavailable ($e) → on-device fallback');
        final result = await _onDevice(image, false);
        result['source'] = 'on_device_fallback';
        result['note'] = 'Server unavailable: ${e.message}';
        return result;
      }
    }

    try {
      return await _onDevice(image, false);
    } catch (e) {
      return _error('On-device analysis failed: $e');
    }
  }

  static Future<Map<String, dynamic>> _onDevice(File image, bool liveFrame) async {
    final r = liveFrame
        ? await TfliteService.predictCameraFrame(image,
            swapRedBlue: AppConfig.cameraSwapRedBlue)
        : await TfliteService.predictFromFile(image);
    return _decide(r);
  }

  /// Gallery pick on web: raw bytes, no file path. Server first; on-device
  /// only where the model is loaded (never on web).
  static Future<Map<String, dynamic>> analyzeBytes(Uint8List bytes) async {
    if (AppConfig.useOnDevice && TfliteService.isLoaded) {
      try {
        return _decide(await TfliteService.predictFromBytes(bytes));
      } catch (e) {
        return _error('On-device analysis failed: $e');
      }
    }
    try {
      final result = await ApiService.uploadBytes(bytes);
      result['source'] = 'server';
      return _normalize(result);
    } on ServerUnavailableException catch (e) {
      return _error(e.message, source: 'server');
    }
  }

  static Map<String, dynamic> _decide(TfliteResult r) {
    if (!r.leafDetected) {
      return _error('No leaf detected.',
          message: 'Please capture a clear photo of a crop leaf.',
          source: 'on_device');
    }
    // Not sure it is diseased → don't spray (a healthy leaf in odd light is
    // the usual cause). Damage is still shown for information.
    if (r.isUncertain) {
      return {
        'status': 'Uncertain',
        'disease': 'Uncertain',
        'confidence_percent': r.confidencePercent,
        'damage_percent': r.damagePercent,
        'severity': AppConfig.severityFor(r.damagePercent),
        'spray_recommended': false,
        'message': 'Disease not recognised '
            '(${r.confidencePercent.toStringAsFixed(1)}% confidence) — not spraying.',
        'inference_ms': r.inferenceMs,
        'source': 'on_device',
      };
    }
    if (r.disease == AppConfig.notLeafClass) {
      return {
        'status': 'NotLeaf',
        'disease': 'None',
        'confidence_percent': r.confidencePercent,
        'damage_percent': 0.0,
        'severity': 'None',
        'spray_recommended': false,
        'message': 'Not a crop leaf — not spraying.',
        'inference_ms': r.inferenceMs,
        'source': 'on_device',
      };
    }
    // Looks like no real training leaf (printed fabric, unknown object): the
    // winning class is a guess.
    if (r.isUnfamiliar) {
      return {
        'status': 'Uncertain',
        'disease': 'Uncertain',
        'confidence_percent': r.confidencePercent,
        'damage_percent': r.damagePercent,
        'severity': AppConfig.severityFor(r.damagePercent),
        'spray_recommended': false,
        'message': "Doesn't look like a crop leaf the model knows "
            '(unfamiliar ${r.unfamiliarScore!.toStringAsFixed(2)} > '
            '${r.unfamiliarThreshold!.toStringAsFixed(2)}) — not spraying.',
        'inference_ms': r.inferenceMs,
        'source': 'on_device',
      };
    }
    if (r.disease == AppConfig.healthyClass) {
      return {
        'status': 'Healthy',
        'disease': 'None',
        'confidence_percent': r.confidencePercent,
        // Leftover non-green pixels on a healthy leaf are soil/stems/shadow.
        'damage_percent': 0.0,
        'severity': 'None',
        'spray_recommended': false,
        'message': 'Leaf is healthy — no spray.',
        'inference_ms': r.inferenceMs,
        'source': 'on_device',
      };
    }
    // Looks like a disease, but not clearly: the model still gives "Healthy"
    // a real chance, or isn't sure enough of the disease → don't spray.
    if (r.confidence < AppConfig.sprayConfidence ||
        r.healthyProb >= AppConfig.maxHealthyProb) {
      return {
        'status': 'Uncertain',
        'disease': 'Uncertain',
        'confidence_percent': r.confidencePercent,
        'damage_percent': r.damagePercent,
        'severity': AppConfig.severityFor(r.damagePercent),
        'spray_recommended': false,
        'message': 'Possibly ${r.disease} '
            '(${r.confidencePercent.toStringAsFixed(1)}%, healthy '
            '${(r.healthyProb * 100).toStringAsFixed(1)}%) — not sure, not spraying.',
        'inference_ms': r.inferenceMs,
        'source': 'on_device',
      };
    }
    return {
      'status': 'Diseased',
      'disease': r.disease,
      'confidence_percent': r.confidencePercent,
      'damage_percent': r.damagePercent,
      'severity': AppConfig.severityFor(r.damagePercent),
      'spray_recommended': true,
      'inference_ms': r.inferenceMs,
      'source': 'on_device',
    };
  }

  static Map<String, dynamic> _normalize(Map<String, dynamic> r) {
    if (r['error'] != null) {
      r['status'] = 'Error';
      return r;
    }
    final damage = (r['damage_percent'] as num?)?.toDouble() ?? 0.0;
    r['damage_percent'] = damage;
    r['severity'] ??= AppConfig.severityFor(damage);
    r['spray_recommended'] ??= r['status'] == 'Diseased';
    return r;
  }

  static Map<String, dynamic> _error(String error,
          {String? message, String source = 'on_device'}) =>
      {
        'status': 'Error',
        'error': error,
        if (message != null) 'message': message,
        'source': source,
      };

  /// Sends the damage % of a diseased leaf to the ESP32 via Blynk; the
  /// firmware picks the spray time from it (Low → short burst, Medium → ~2 s,
  /// High → longer). Healthy / uncertain / error results are never sent, so
  /// the motor cannot run for them.
  /// Returns a short status line for the UI.
  static Future<String> sendToSprayer(Map<String, dynamic> result) async {
    switch (result['status']) {
      case 'Diseased':
        break;
      case 'Healthy':
        return 'Healthy — no spray';
      case 'Uncertain':
        return 'Not sure — no spray';
      case 'NotLeaf':
        return 'Not a leaf — no spray';
      default:
        return 'Not sent (no leaf analysed)';
    }
    if (!AppConfig.iotConfigured) return 'IoT not configured';

    // ≥ 1: the firmware treats 0 as "no spray", but a recognised disease
    // gets at least the short burst even if leaf colour shows little damage.
    final damage = (result['damage_percent'] as num).round().clamp(1, 100);
    try {
      await BlynkService.setVirtualPin(AppConfig.damagePin, damage);
      return 'Sent $damage% to sprayer';
    } catch (e) {
      debugPrint('Blynk send failed: $e');
      return 'Sprayer unreachable';
    }
  }
}
