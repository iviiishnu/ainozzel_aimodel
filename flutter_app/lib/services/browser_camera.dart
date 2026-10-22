// Webcam in the browser (web build). On Android the USB webcam is used
// instead (usb_webcam.dart); there this is an inert stub.
export 'browser_camera_stub.dart'
    if (dart.library.js_interop) 'browser_camera_web.dart';
