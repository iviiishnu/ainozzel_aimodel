import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/browser_camera.dart';

/// Web build: shows the computer's webcam and captures one photo.
/// Pops with the JPEG bytes, or null if the user backs out.
class WebCameraPage extends StatefulWidget {
  const WebCameraPage({super.key});

  @override
  State<WebCameraPage> createState() => _WebCameraPageState();
}

class _WebCameraPageState extends State<WebCameraPage> {
  final BrowserCamera _camera = BrowserCamera();
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _camera.start();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (!_camera.isReady || _isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final Uint8List bytes = await _camera.capture();
      if (mounted) Navigator.pop(context, bytes);
    } catch (e) {
      if (mounted) {
        setState(() => _isCapturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Capture Leaf (webcam)'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: ListenableBuilder(
        listenable: _camera,
        builder: (context, _) {
          final ready = _camera.isReady;
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: ready
                      ? _camera.preview()
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.videocam,
                                  color: Colors.white54, size: 48),
                              const SizedBox(height: 16),
                              Text(
                                _camera.status,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 16),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: FloatingActionButton.large(
                  onPressed: ready && !_isCapturing ? _capture : null,
                  backgroundColor: ready ? Colors.white : Colors.grey,
                  child: _isCapturing
                      ? const CircularProgressIndicator()
                      : const Icon(Icons.camera, color: Colors.black, size: 48),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
