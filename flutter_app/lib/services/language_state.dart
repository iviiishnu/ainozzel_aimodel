import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide language selection.
///
/// Usage anywhere:
///   LanguageState.selected.value          // current value (null = none chosen)
///   LanguageState.select('English')       // set and persist
///   ValueListenableBuilder(
///     valueListenable: LanguageState.selected, ...)
class LanguageState {
  LanguageState._();

  static const _kKey = 'app_language';

  /// Holds the currently selected language code, or null when none is chosen.
  /// We intentionally do NOT pre-load from prefs so the user must choose every
  /// time the app starts (keeps the "disabled until selected" welcome behaviour).
  static final ValueNotifier<String?> selected = ValueNotifier<String?>(null);

  /// Set the language and persist it.
  static Future<void> select(String language) async {
    selected.value = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, language);
  }

  /// Read the last persisted language (call this if you need it in other
  /// screens without triggering the welcome gate).
  static Future<String?> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kKey);
  }
}
