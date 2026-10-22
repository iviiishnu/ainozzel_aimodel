import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// The computer's webcam in the browser (getUserMedia), shown with a <video>
/// element and captured as a JPEG through a <canvas>.
class BrowserCamera extends ChangeNotifier {
  static int _views = 0;

  final String _viewType = 'browser-camera-${_views++}';
  late final web.HTMLVideoElement _video = web.HTMLVideoElement()
    ..autoplay = true
    ..muted = true
    ..setAttribute('playsinline', 'true')
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.objectFit = 'contain'
    ..style.backgroundColor = 'black';
  bool _registered = false;
  web.MediaStream? _stream;
  String _status = 'Starting webcam…';
  bool _ready = false;
  bool _disposed = false;

  String get status => _status;
  bool get isReady => _ready;

  void _set(String status, {bool ready = false}) {
    _status = status;
    _ready = ready;
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_stream != null) return;
    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video);
      _registered = true;
    }
    _set('Starting webcam… (allow camera access if the browser asks)');
    try {
      final constraints = web.MediaStreamConstraints(
        video: {
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        }.jsify()!,
        audio: false.toJS,
      );
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      if (_disposed) {
        _stopTracks(stream);
        return;
      }
      _stream = stream;
      _video.srcObject = stream;
      await _video.play().toDart;
      // Wait for the first frame so capture() never grabs an empty image.
      for (int i = 0; i < 50 && _video.videoWidth == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _set('Webcam ready', ready: _video.videoWidth > 0);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('NotAllowed') || msg.contains('Permission')) {
        _set('Camera permission was blocked. Allow the camera in the browser '
            '(icon in the address bar) and open this page again.');
      } else if (msg.contains('NotFound') || msg.contains('DevicesNotFound')) {
        _set('No webcam found. Plug in the USB webcam and open this page again.');
      } else if (msg.contains('NotReadable') || msg.contains('TrackStart')) {
        _set('The webcam is in use by another program. Close it and try again.');
      } else {
        _set('Could not start the webcam: $msg');
      }
    }
  }

  void stop() {
    final stream = _stream;
    _stream = null;
    if (stream != null) _stopTracks(stream);
    _video.srcObject = null;
    if (_ready) _set('Webcam stopped');
  }

  static void _stopTracks(web.MediaStream stream) {
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
  }

  Widget preview() => HtmlElementView(viewType: _viewType);

  /// Current frame as JPEG bytes.
  Future<Uint8List> capture() async {
    if (!_ready) throw StateError('Webcam not ready');
    final canvas = web.HTMLCanvasElement()
      ..width = _video.videoWidth
      ..height = _video.videoHeight;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(_video, 0, 0);
    final dataUrl = canvas.toDataURL('image/jpeg', 0.92.toJS);
    return base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
