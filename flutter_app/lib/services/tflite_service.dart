// On-device model on Android/desktop; a stub on web (no dart:ffi there).
export 'tflite_service_io.dart'
    if (dart.library.js_interop) 'tflite_service_web.dart';
