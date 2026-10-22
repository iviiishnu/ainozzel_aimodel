import 'package:shared_preferences/shared_preferences.dart';

/// App configuration — nothing environment-specific is hardcoded here.
///
/// Values are resolved in this order:
///   1. Saved on the device from the in-app Settings screen
///   2. Build-time defaults passed with
///        flutter run --dart-define-from-file=config/app_config.json
///      (see config/app_config.example.json)
///   3. Empty / safe defaults below
class AppConfig {
  AppConfig._();

  // ── Build-time defaults (--dart-define) ───────────────────────────────────
  static const String _defaultBackendUrl =
      String.fromEnvironment('BACKEND_URL');
  static const String _defaultBlynkServer =
      String.fromEnvironment('BLYNK_SERVER', defaultValue: 'blynk.cloud');
  static const String _defaultBlynkToken =
      String.fromEnvironment('BLYNK_AUTH_TOKEN');

  // ── Decision thresholds (override with --dart-define) ─────────────────────
  // Keep in sync with ai_service/.env (DAMAGE_MEDIUM / DAMAGE_HIGH /
  // CONFIDENCE_THRESHOLD) and the ESP32 firmware (DAMAGE_MEDIUM / DAMAGE_HIGH).
  // Whether to spray comes from the classifier (only diseased leaves); the
  // damage bands only set how long the ESP32 sprays.
  static final double confidenceThreshold =
      _doubleDefine(const String.fromEnvironment('CONFIDENCE_THRESHOLD'), 0.50);
  static const String healthyClass = 'Healthy'; // label in class_names.json
  // "Not a crop leaf" (shirts, hands, soil …) → never sprayed.
  static const String notLeafClass = 'Not_Leaf';
  // A disease is only sprayed when the model is at least this sure of it …
  static final double sprayConfidence =
      _doubleDefine(const String.fromEnvironment('SPRAY_CONFIDENCE'), 0.60);
  // … and gives "Healthy" less than this. Real camera leaves look different
  // from the dataset photos; these two cut healthy-leaf sprays ~5× on the
  // field-simulated validation set.
  static final double maxHealthyProb =
      _doubleDefine(const String.fromEnvironment('MAX_HEALTHY_PROB'), 0.10);
  // Live scan: consecutive frames diagnosed with the SAME disease before the
  // motor runs, so one bad frame — or a model flipping between diseases on
  // something it doesn't understand — never sprays. Measured: 2 same-disease
  // frames take healthy-leaf sprays 1% → 0%; 3 cost far more diseased leaves
  // (61% → 53% caught) for no further gain. Non-leaf objects are stopped by
  // the Not_Leaf class and the unfamiliar-image check, not by this.
  static final int confirmFrames =
      int.tryParse(const String.fromEnvironment('CONFIRM_FRAMES')) ?? 2;
  static final double damageMedium = // ≥ → Medium
      _doubleDefine(const String.fromEnvironment('DAMAGE_MEDIUM'), 15);
  static final double damageHigh = // ≥ → High
      _doubleDefine(const String.fromEnvironment('DAMAGE_HIGH'), 35);

  static double _doubleDefine(String value, double fallback) =>
      double.tryParse(value) ?? fallback;

  // ── Blynk virtual pins (must match the ESP32 firmware + Blynk template) ──
  static const int damagePin = 4; // app → ESP32: damage %
  static const int motorStatusPin = 5; // ESP32 → app: 1 = motor running

  // ── Keys for saved settings ───────────────────────────────────────────────
  static const _kBackendUrl = 'backend_url';
  static const _kBlynkServer = 'blynk_server';
  static const _kBlynkToken = 'blynk_token';
  static const _kUseOnDevice = 'use_on_device';
  // v2: the default changed 5 s → 3 s; a new key drops the old saved 5.
  static const _kLiveInterval = 'live_interval_s_v2';

  static SharedPreferences? _prefs;

  static Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String _get(String key, String fallback) =>
      _prefs?.getString(key) ?? fallback;

  /// Spring backend base URL, e.g. http://192.168.1.20:8000 (no trailing /).
  static String get backendUrl =>
      _get(_kBackendUrl, _defaultBackendUrl).trim().replaceAll(RegExp(r'/+$'), '');

  /// Blynk cloud host for your account region, e.g. blynk.cloud or blr1.blynk.cloud.
  static String get blynkServer => _get(_kBlynkServer, _defaultBlynkServer).trim();

  static String get blynkToken => _get(_kBlynkToken, _defaultBlynkToken).trim();

  static bool get iotConfigured => blynkToken.isNotEmpty && blynkServer.isNotEmpty;

  /// true = run the TFLite model on the tablet; false = send to the backend.
  static bool get useOnDevice => _prefs?.getBool(_kUseOnDevice) ?? true;

  /// Length of one capture → analyse → spray cycle on the Live Camera screen.
  static const int defaultLiveIntervalSeconds = 3;
  static int get liveIntervalSeconds =>
      _prefs?.getInt(_kLiveInterval) ?? defaultLiveIntervalSeconds;

  static Future<void> save({
    required String backendUrl,
    required String blynkServer,
    required String blynkToken,
    required bool useOnDevice,
    required int liveIntervalSeconds,
  }) async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setString(_kBackendUrl, backendUrl.trim());
    await p.setString(_kBlynkServer, blynkServer.trim());
    await p.setString(_kBlynkToken, blynkToken.trim());
    await p.setBool(_kUseOnDevice, useOnDevice);
    await p.setInt(_kLiveInterval, liveIntervalSeconds);
  }

  // ── Camera / diagnostics ──────────────────────────────────────────────────
  static const _kCameraResolution = 'camera_resolution';

  /// USB webcam resolution: 'low' (~480p), 'medium' (~720p), 'high' (~1080p),
  /// 'max'. Higher = more leaf detail when the leaf is small in the frame,
  /// but slower to decode on the tablet.
  static const cameraResolutions = ['low', 'medium', 'high', 'max'];
  static String get cameraResolution {
    final v = _prefs?.getString(_kCameraResolution);
    return cameraResolutions.contains(v) ? v! : 'medium';
  }

  static Future<void> setCameraResolution(String value) async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setString(_kCameraResolution, value);
  }

  /// The uvccamera plugin saves photos with red and blue swapped (seen on the
  /// TB311XU tablet + USB webcam: skin blue, leaves teal) → swap them back.
  /// Turn off in Settings if a different camera shows blue-tinted results.
  static const _kCameraSwapRedBlue = 'camera_swap_rb';
  static bool get cameraSwapRedBlue => _prefs?.getBool(_kCameraSwapRedBlue) ?? true;
  static Future<void> setCameraSwapRedBlue(bool value) async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setBool(_kCameraSwapRedBlue, value);
  }

  static Future<void> setUseOnDevice(bool value) async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    await p.setBool(_kUseOnDevice, value);
  }

  static String severityFor(double damagePercent) {
    if (damagePercent < damageMedium) return 'Low';
    if (damagePercent < damageHigh) return 'Medium';
    return 'High';
  }
}
