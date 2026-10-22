import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

enum CameraChoice { webcam, device }

/// Asks which camera takes the photo: the USB webcam (in the browser: the
/// computer's webcam) or the tablet's own camera. Null if dismissed.
Future<CameraChoice?> askCameraChoice(BuildContext context) {
  return showModalBottomSheet<CameraChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Which camera?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.videocam),
            title: const Text('Webcam'),
            subtitle: Text(kIsWeb
                ? "This computer's webcam"
                : 'USB webcam plugged into the tablet'),
            onTap: () => Navigator.pop(context, CameraChoice.webcam),
          ),
          ListTile(
            leading: const Icon(Icons.tablet_android),
            title: const Text('Tablet camera'),
            subtitle: Text(kIsWeb
                ? "The device's own camera (phone / tablet browser)"
                : "The tablet's built-in camera"),
            onTap: () => Navigator.pop(context, CameraChoice.device),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
