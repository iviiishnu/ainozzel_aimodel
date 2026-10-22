import 'dart:io';
import 'dart:typed_data';

import 'tflite_result.dart';

export 'tflite_result.dart';

/// Web build: tflite_flutter needs dart:ffi, which browsers don't have.
/// The model never loads, so AnalysisService always uses the server.
class TfliteService {
  static bool get isLoaded => false;

  static Future<void> loadModel() async {}

  static Future<TfliteResult> predictFromFile(File imageFile) =>
      throw UnsupportedError('On-device model is not available on web');

  static Future<TfliteResult> predictFromBytes(Uint8List imageBytes) =>
      throw UnsupportedError('On-device model is not available on web');

  static Future<TfliteResult> predictCameraFrame(File frame,
          {required bool swapRedBlue, int maxWidth = 640}) =>
      throw UnsupportedError('On-device model is not available on web');

  static void dispose() {}
}
