import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:uvccamera/uvccamera.dart';

import '../config.dart';
import '../services/analysis_service.dart';
import '../services/blynk_service.dart';
import '../services/browser_camera.dart';
import '../services/usb_webcam.dart';

/// Live Camera Page
/// ────────────────
/// Shows the USB/OTG webcam (never the built-in cameras) and, while scanning
/// is on, captures a frame every [AppConfig.liveIntervalSeconds], analyses it
/// and forwards the damage % to the sprayer. In the web app it uses the
/// computer's webcam instead, analysed by the server.
class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({super.key});

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage>
    with WidgetsBindingObserver {
  final UsbWebcam _webcam = UsbWebcam();
  // Web build: the computer's webcam through the browser.
  final BrowserCamera? _browser = kIsWeb ? BrowserCamera() : null;

  bool get _ready => _browser?.isReady ?? _webcam.isReady;
  String get _status => _browser?.status ?? _webcam.status;

  Timer? _scanTimer;
  Timer? _motorStatusTimer;
  bool _scanning = false;
  bool _isProcessing = false;

  Map<String, dynamic>? _result;
  String? _iotStatus;
  bool? _isMotorRunning;
  int? _cycleMs; // capture + analysis time of the last scan
  int _diseasedStreak = 0; // consecutive 'Diseased' frames …
  String? _streakDisease; // … all with this disease

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The camera turns on as soon as the page opens.
    if (_browser != null) {
      _browser.addListener(_onWebcamChanged);
      _browser.start();
    } else {
      _webcam.addListener(_onWebcamChanged);
      _webcam.start();
    }
    if (AppConfig.iotConfigured) {
      _motorStatusTimer =
          Timer.periodic(const Duration(seconds: 3), (_) => _refreshMotor());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _motorStatusTimer?.cancel();
    if (_browser != null) {
      _browser.removeListener(_onWebcamChanged);
      _browser.dispose();
    } else {
      _webcam.removeListener(_onWebcamChanged);
      _webcam.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopScanning();
      _browser != null ? _browser.stop() : _webcam.stop();
    } else if (state == AppLifecycleState.resumed) {
      _browser != null ? _browser.start() : _webcam.start();
    }
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  // Stop auto-scan if the webcam goes away; rebuild for status/preview.
  void _onWebcamChanged() {
    if (!_ready) _stopScanning();
    if (mounted) setState(() {});
  }

  // ── Scanning loop ─────────────────────────────────────────────────────────

  void _startScanning() {
    _scanTimer?.cancel();
    setState(() => _scanning = true);
    _runCycle();
  }

  void _stopScanning() {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (mounted && _scanning) setState(() => _scanning = false);
  }

  /// One capture → analyse → spray cycle, then the next one is scheduled so
  /// cycles *start* every [AppConfig.liveIntervalSeconds] (or straight away
  /// if this one ran over), instead of a fixed timer that silently skips a
  /// tick whenever analysis is still busy.
  Future<void> _runCycle() async {
    if (!_scanning) return;
    final started = DateTime.now();
    await _captureAndAnalyze();
    if (!mounted || !_scanning) return;
    final interval = Duration(seconds: AppConfig.liveIntervalSeconds);
    final wait = interval - DateTime.now().difference(started);
    _scanTimer = Timer(wait.isNegative ? Duration.zero : wait, _runCycle);
  }

  Future<void> _captureAndAnalyze() async {
    if (_isProcessing || !_ready) return;
    setState(() => _isProcessing = true);
    final stopwatch = Stopwatch()..start();

    try {
      final Map<String, dynamic> result;
      if (_browser != null) {
        // Web: no on-device model, the server analyses the frame.
        result = await AnalysisService.analyzeBytes(await _browser.capture());
      } else {
        final file = await _webcam.takePicture();
        result = await AnalysisService.analyze(file, liveFrame: true);
        file.delete().catchError((_) => file);
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _cycleMs = stopwatch.elapsedMilliseconds;
      });

      // Spray only after [AppConfig.confirmFrames] frames in a row with the
      // same disease: one odd frame of a healthy leaf, or a model hopping
      // between diseases on something it doesn't know, must not start the motor.
      if (result['status'] != 'Diseased') {
        _diseasedStreak = 0;
        _streakDisease = null;
      } else if (result['disease'] == _streakDisease) {
        _diseasedStreak++;
      } else {
        _diseasedStreak = 1;
        _streakDisease = result['disease'] as String?;
      }
      if (_diseasedStreak > 0 && _diseasedStreak < AppConfig.confirmFrames) {
        setState(() => _iotStatus = 'Confirming $_streakDisease '
            '($_diseasedStreak/${AppConfig.confirmFrames}) — no spray yet');
        return;
      }

      // Don't hold the next capture on a slow network: the ESP32 gets the
      // damage % as soon as the call lands.
      AnalysisService.sendToSprayer(result).then((iot) {
        if (mounted) setState(() => _iotStatus = iot);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _result = {'status': 'Error', 'error': 'Capture failed: $e'});
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _refreshMotor() async {
    final status = await BlynkService.getMotorStatus();
    if (mounted) setState(() => _isMotorRunning = status);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  Color _severityColor(String? severity) {
    switch (severity) {
      case 'High':
        return Colors.red;
      case 'Medium':
        return Colors.orange;
      case 'Low':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        title: const Text('Live Scan'),
        backgroundColor: const Color(0xFF0D1B2A),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: ready
                      ? (_browser != null
                          ? _browser.preview()
                          : UvcCameraPreview(_webcam.controller!))
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_status,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 16),
                              textAlign: TextAlign.center),
                        ),
                ),
                if (_isProcessing)
                  const Positioned(
                    top: 12,
                    right: 12,
                    child: Chip(
                      avatar: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      label: Text('Analyzing…'),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(flex: 3, child: _buildResultPanel()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _scanning ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: ready
                        ? (_scanning ? _stopScanning : _startScanning)
                        : null,
                    icon: Icon(_scanning ? Icons.stop : Icons.play_arrow),
                    label: Text(_scanning
                        ? 'Stop auto-scan'
                        : 'Auto-scan every ${AppConfig.liveIntervalSeconds}s'),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  ),
                  onPressed:
                      ready && !_isProcessing ? _captureAndAnalyze : null,
                  icon: const Icon(Icons.camera),
                  label: const Text('Scan now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultPanel() {
    final r = _result;
    final textStyle = const TextStyle(color: Colors.white70, fontSize: 14);

    Widget content;
    if (r == null) {
      content = Text('Point the camera at a leaf and tap "Scan now".',
          style: textStyle, textAlign: TextAlign.center);
    } else if (r['status'] == 'Error') {
      content = Text('${r['error']}${r['message'] != null ? '\n${r['message']}' : ''}',
          style: const TextStyle(color: Colors.redAccent, fontSize: 15),
          textAlign: TextAlign.center);
    } else if (r['status'] == 'Healthy') {
      content = Text(
          'Healthy leaf — no spray\n'
          'Confidence ${(r['confidence_percent'] as num).toStringAsFixed(1)}%',
          style: const TextStyle(
              color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center);
    } else if (r['status'] == 'NotLeaf') {
      content = Text(r['message'] ?? 'Not a crop leaf — no spray',
          style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 18),
          textAlign: TextAlign.center);
    } else if (r['status'] == 'Uncertain') {
      content = Text(r['message'] ?? 'Low confidence — adjust the leaf and retry.',
          style: const TextStyle(color: Colors.orangeAccent, fontSize: 15),
          textAlign: TextAlign.center);
    } else {
      final damage = (r['damage_percent'] as num).toDouble();
      final conf = (r['confidence_percent'] as num).toDouble();
      final severity = r['severity'] as String?;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${r['disease']}',
              style: const TextStyle(
                  color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Damage ${damage.toStringAsFixed(1)}%  •  '
            'Confidence ${conf.toStringAsFixed(1)}%',
            style: textStyle,
          ),
          const SizedBox(height: 6),
          Chip(
            backgroundColor: _severityColor(severity),
            label: Text('Severity: $severity',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            content,
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (_cycleMs != null)
                  Text('• ${(_cycleMs! / 1000).toStringAsFixed(1)}s / scan',
                      style: TextStyle(
                          color: _cycleMs! >
                                  AppConfig.liveIntervalSeconds * 1000
                              ? Colors.orangeAccent
                              : Colors.white70,
                          fontSize: 14)),
                if (_iotStatus != null) Text('• $_iotStatus', style: textStyle),
                Text(
                  _isMotorRunning == null
                      ? '• Motor: n/a'
                      : '• Motor: ${_isMotorRunning! ? 'RUNNING' : 'stopped'}',
                  style: textStyle,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
