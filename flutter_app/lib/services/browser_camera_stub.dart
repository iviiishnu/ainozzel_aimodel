import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Non-web builds: the browser camera doesn't exist (see usb_webcam.dart).
class BrowserCamera extends ChangeNotifier {
  String get status => 'Browser camera is only available in the web app.';
  bool get isReady => false;

  Future<void> start() async {}
  void stop() {}

  Widget preview() => const SizedBox.shrink();

  Future<Uint8List> capture() =>
      throw UnsupportedError('Browser camera is only available on web');
}
