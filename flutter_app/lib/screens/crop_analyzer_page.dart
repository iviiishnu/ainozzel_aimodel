import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/widgets/in_app_camera_page.dart';
import 'package:flutter_app/widgets/live_camera_page.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';
import '../services/analysis_service.dart';
import '../services/app_strings.dart';
import '../services/blynk_service.dart';
import '../services/language_state.dart';
import '../services/tflite_service.dart';
import 'gallery_result_screen.dart';
import 'settings_page.dart';
import '../widgets/info_card.dart';
import '../widgets/camera_choice.dart';
import '../widgets/web_camera_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────
const Color _kDarkTeal   = Color(0xFF0B5D5A);
const Color _kGreen      = Color(0xFF2E8B3D);
const Color _kOrange     = Color(0xFFF28C28);
const Color _kMintTop    = Color(0xFFE3F4E6);
const Color _kMintBottom = Color(0xFFF7FBF2);
const Color _kLeaf       = Color(0xFF5DB36B);

// ─────────────────────────────────────────────────────────────────────────────
// CROP ANALYZER PAGE
// ─────────────────────────────────────────────────────────────────────────────
class CropAnalyzerPage extends StatefulWidget {
  const CropAnalyzerPage({super.key});

  static String getSeverity(double damagePercent) =>
      AppConfig.severityFor(damagePercent);

  @override
  State<CropAnalyzerPage> createState() => _CropAnalyzerPageState();
}

class _CropAnalyzerPageState extends State<CropAnalyzerPage> {
  // ── Business state (unchanged) ────────────────────────────────────────────
  File? _image;
  Map<String, dynamic>? _parsedResult;
  bool _isLoading = false;
  final ImagePicker picker = ImagePicker();

  bool? _isMotorRunning;
  String? _iotStatus;
  Timer? _motorStatusTimer;

  bool get _useOnDeviceInference =>
      AppConfig.useOnDevice && TfliteService.isLoaded;

  @override
  void initState() {
    super.initState();
    _startMotorPolling();
  }

  void _startMotorPolling() {
    _motorStatusTimer?.cancel();
    _motorStatusTimer = null;
    if (!AppConfig.iotConfigured) return;
    _motorStatusTimer =
        Timer.periodic(const Duration(seconds: 3), (_) async {
      final status = await BlynkService.getMotorStatus();
      if (mounted) setState(() => _isMotorRunning = status);
    });
  }

  @override
  void dispose() {
    _motorStatusTimer?.cancel();
    super.dispose();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (!mounted) return;
    setState(() {});
    _startMotorPolling();
  }

  // ── Image picking (unchanged logic) ──────────────────────────────────────
  Future<void> pickImage(ImageSource source) async {
    final s = AppStrings.of(LanguageState.selected.value);

    if (source == ImageSource.camera) {
      await _pickFromCamera(s);
      return;
    }

    // Gallery — navigate to result page
    final XFile? pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 85,
    );

    if (!mounted) return;
    if (pickedFile == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.noImageCaptured)));
      return;
    }

    if (kIsWeb) {
      final bytes = await pickedFile.readAsBytes();
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GalleryResultScreen(imageBytes: bytes),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              GalleryResultScreen(imageFile: File(pickedFile.path)),
        ),
      );
    }
  }

  // ── Camera: ask webcam or tablet camera ────────────────────────────────
  Future<void> _pickFromCamera(AppStrings s) async {
    final choice = await askCameraChoice(context);
    if (choice == null || !mounted) return;

    if (choice == CameraChoice.webcam) {
      if (kIsWeb) {
        // Browser: the computer's webcam
        final Uint8List? bytes = await Navigator.push<Uint8List>(
          context,
          MaterialPageRoute(builder: (_) => const WebCameraPage()),
        );
        if (!mounted) return;
        if (bytes == null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(s.noImageCaptured)));
          return;
        }
        _showResult(imageBytes: bytes);
        return;
      }
      // Tablet: the USB/OTG webcam
      final File? imageFile = await Navigator.push<File>(
        context,
        MaterialPageRoute(builder: (_) => const InAppCameraPage()),
      );
      if (!mounted) return;
      if (imageFile == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.noImageCaptured)));
        return;
      }
      _showResult(imageFile: imageFile);
      return;
    }

    // The tablet's own camera (system camera app)
    if (!kIsWeb && !(await Permission.camera.request()).isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Camera permission denied — allow it in Settings.')));
      return;
    }
    final XFile? shot = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 85,
    );
    if (!mounted) return;
    if (shot == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.noImageCaptured)));
      return;
    }
    if (kIsWeb) {
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      _showResult(imageBytes: bytes);
    } else {
      _showResult(imageFile: File(shot.path));
    }
  }

  // This page has no result area of its own: every photo opens the result
  // screen (image, disease, damage, sprayer status).
  void _showResult({File? imageFile, Uint8List? imageBytes}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GalleryResultScreen(imageFile: imageFile, imageBytes: imageBytes),
      ),
    );
  }

  Future<void> _analyzeImage(File imageFile) async {
    setState(() {
      _image = imageFile;
      _isLoading = true;
      _parsedResult = null;
      _iotStatus = null;
    });

    final result = await AnalysisService.analyze(imageFile);
    if (!mounted) return;
    setState(() {
      _parsedResult = result;
      _isLoading = false;
    });

    final iot = await AnalysisService.sendToSprayer(result);
    if (mounted) setState(() => _iotStatus = iot);
  }

  Future<void> _analyzeBytes(Uint8List bytes) async {
    setState(() {
      _image = null;
      _isLoading = true;
      _parsedResult = null;
      _iotStatus = null;
    });

    final result = await AnalysisService.analyzeBytes(bytes);
    if (!mounted) return;
    setState(() {
      _parsedResult = result;
      _isLoading = false;
    });

    final iot = await AnalysisService.sendToSprayer(result);
    if (mounted) setState(() => _iotStatus = iot);
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'High':   return Colors.red;
      case 'Medium': return Colors.orange;
      case 'Low':    return Colors.green;
      default:       return Colors.grey;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: LanguageState.selected,
      builder: (context, lang, _) {
        final s = AppStrings.of(lang);
        return _buildScaffold(s);
      },
    );
  }

  Widget _buildScaffold(AppStrings s) {
    final List<String> fallbacks = [
      GoogleFonts.notoSansDevanagari().fontFamily!,
      GoogleFonts.notoSansKannada().fontFamily!,
      GoogleFonts.notoSansTelugu().fontFamily!,
      GoogleFonts.notoSansTamil().fontFamily!,
    ];

    TextStyle localized(TextStyle base) =>
        base.copyWith(fontFamilyFallback: fallbacks);

    return Scaffold(
      // ── App bar ──────────────────────────────────────────────────────────
      appBar: AppBar(
        backgroundColor: _kDarkTeal,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          s.appBarTitle,
          style: localized(GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          )),
        ),
        actions: [
          Tooltip(
            message: _useOnDeviceInference
                ? s.onDeviceTflite
                : s.serverInference,
            child: IconButton(
              icon: Icon(
                _useOnDeviceInference
                    ? Icons.phone_android
                    : Icons.cloud_outlined,
                color: Colors.white,
              ),
              onPressed: () async {
                await AppConfig.setUseOnDevice(!AppConfig.useOnDevice);
                if (!mounted) return;
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _useOnDeviceInference
                          ? '📱 ${s.onDeviceTflite}'
                          : '☁️ ${s.serverInference}',
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: s.settings,
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
            onPressed: _openSettings,
          ),
        ],
      ),

      // ── Body ─────────────────────────────────────────────────────────────
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool isDesktop = constraints.maxWidth >= 600;
          final double maxW = constraints.maxWidth;
          final double maxH = constraints.maxHeight;

          return Stack(
            children: [
              // Background gradient
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_kMintTop, _kMintBottom],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),

              // Subtle faint leaf decorations (no animation, no overlap)
              Positioned(
                left: -55,
                top: -45,
                child: Transform.rotate(
                  angle: -0.5,
                  child: Icon(Icons.eco,
                      size: isDesktop ? 240 : 160,
                      color: _kLeaf.withValues(alpha: 0.07)),
                ),
              ),
              Positioned(
                right: -55,
                bottom: -55,
                child: Transform.rotate(
                  angle: 2.4,
                  child: Icon(Icons.eco,
                      size: isDesktop ? 280 : 180,
                      color: _kLeaf.withValues(alpha: 0.06)),
                ),
              ),

              // Main scrollable content
              SafeArea(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: maxH),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isDesktop ? 32 : 16,
                        vertical: isDesktop ? 24 : 16,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // ── 1. SVCE banner ─────────────────────────────
                          _buildBanner(isDesktop),
                          SizedBox(height: isDesktop ? 18 : 12),

                          // ── 2. Title + accent bar ───────────────────────
                          _buildTitle(s, isDesktop, fallbacks),
                          SizedBox(height: isDesktop ? 28 : 20),

                          // ── 3. Three action boxes ───────────────────────
                          _buildActionRow(s, isDesktop, maxW, fallbacks),
                          SizedBox(height: isDesktop ? 28 : 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 1. SVCE banner ─────────────────────────────────────────────────────────
  Widget _buildBanner(bool isDesktop) {
    return Container(
      width: isDesktop ? 420 : double.infinity,
      height: isDesktop ? 100 : 76,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Image.asset(
        'assets/images/svce_logo.png',
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Center(
          child: Text(
            'SVCE',
            style: GoogleFonts.poppins(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: _kDarkTeal,
            ),
          ),
        ),
      ),
    );
  }

  // ── 2. Title ───────────────────────────────────────────────────────────────
  Widget _buildTitle(AppStrings s, bool isDesktop, List<String> fallbacks) {
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            s.aiCropAnalyzer,
            style: GoogleFonts.poppins(
              fontSize: isDesktop ? 32 : 22,
              fontWeight: FontWeight.w900,
              color: _kDarkTeal,
              letterSpacing: 1.5,
            ).copyWith(fontFamilyFallback: fallbacks),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: isDesktop ? 72 : 56,
          height: 5,
          decoration: BoxDecoration(
            color: _kOrange,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ],
    );
  }

  // ── 3. Image card ──────────────────────────────────────────────────────────
  Widget _buildImageCard(
    AppStrings s,
    bool isDesktop,
    double maxW,
    double maxH,
    List<String> fallbacks,
  ) {
    final double cardH = (maxH * 0.42).clamp(280.0, 520.0);

    return Center(
      child: Container(
        width: min(maxW, 1100),
        height: cardH,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: _image == null
            ? _buildEmptyCard(s, isDesktop, fallbacks)
            : _buildImagePreview(),
      ),
    );
  }

  Widget _buildEmptyCard(
      AppStrings s, bool isDesktop, List<String> fallbacks) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                size: isDesktop ? 64 : 52,
                color: _kGreen.withValues(alpha: 0.7)),
            const SizedBox(height: 14),
            Text(
              s.noImageSelected,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: isDesktop ? 20 : 16,
                fontWeight: FontWeight.bold,
                color: _kDarkTeal,
              ).copyWith(fontFamilyFallback: fallbacks),
            ),
            const SizedBox(height: 10),
            Text(
              s.chooseHint,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: isDesktop ? 14 : 12,
                color: Colors.grey[500],
                height: 1.5,
              ).copyWith(fontFamilyFallback: fallbacks),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Image.file(_image!, fit: BoxFit.contain),
    );
  }

  // ── 4. Action row ──────────────────────────────────────────────────────────
  Widget _buildActionRow(
    AppStrings s,
    bool isDesktop,
    double maxW,
    List<String> fallbacks,
  ) {
    final double boxW = isDesktop ? 200 : (maxW - 64) / 3;
    final double boxH = isDesktop ? 160 : max(110, boxW * 0.8);

    return Center(
      child: Wrap(
        spacing: isDesktop ? 20 : 10,
        runSpacing: 12,
        alignment: WrapAlignment.center,
        children: [
          // Gallery
          _ActionBox(
            icon: Icons.photo_library_outlined,
            label: s.gallery,
            iconSize: isDesktop ? 60 : 44,
            width: boxW,
            height: boxH,
            isHighlighted: false,
            enabled: !_isLoading,
            fallbacks: fallbacks,
            onTap: () => pickImage(ImageSource.gallery),
          ),
          // Live Camera (highlighted, center)
          _ActionBox(
            icon: Icons.videocam_rounded,
            label: s.liveCamera,
            iconSize: isDesktop ? 64 : 48,
            width: isDesktop ? boxW + 20 : boxW,
            height: isDesktop ? boxH + 20 : boxH,
            isHighlighted: true,
            enabled: !_isLoading,
            fallbacks: fallbacks,
            useLiveCamIcon: true,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LiveCameraPage()),
            ),
          ),
          // Camera
          _ActionBox(
            icon: Icons.photo_camera_outlined,
            label: s.camera,
            iconSize: isDesktop ? 60 : 44,
            width: boxW,
            height: boxH,
            isHighlighted: false,
            enabled: !_isLoading,
            fallbacks: fallbacks,
            onTap: () => pickImage(ImageSource.camera),
          ),
        ],
      ),
    );
  }

  // ── Loading ────────────────────────────────────────────────────────────────
  Widget _buildLoadingCard(AppStrings s, List<String> fallbacks) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: _kDarkTeal),
            const SizedBox(width: 20),
            Text(
              s.analyzing,
              style: GoogleFonts.poppins(fontSize: 16, color: _kDarkTeal)
                  .copyWith(fontFamilyFallback: fallbacks),
            ),
          ],
        ),
      ),
    );
  }

  // ── Results ────────────────────────────────────────────────────────────────
  Widget _buildResults(
      AppStrings s, bool isDesktop, List<String> fallbacks) {
    if (_parsedResult!['error'] != null) {
      return Card(
        color: Colors.red[50],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  [
                    _parsedResult!['error'],
                    if (_parsedResult!['message'] != null)
                      _parsedResult!['message'],
                  ].join('\n'),
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Source badge
        if (_parsedResult!['source'] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _parsedResult!['source'] == 'on_device'
                      ? Icons.phone_android
                      : Icons.cloud_outlined,
                  size: 14,
                  color: Colors.grey[600],
                ),
                const SizedBox(width: 4),
                Text(
                  _parsedResult!['source'] == 'on_device'
                      ? s.onDeviceTflite
                      : _parsedResult!['source'] == 'server_fallback'
                          ? s.serverFallback
                          : s.serverInference,
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                if (_parsedResult!['inference_ms'] != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${_parsedResult!['inference_ms']}ms',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ],
            ),
          ),

        // Uncertain warning
        if (_parsedResult!['status'] == 'Uncertain')
          Card(
            color: Colors.orange[50],
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.orange),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _parsedResult!['message'] ?? s.retakeHint,
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          InfoCard(
            title: s.disease,
            value: _parsedResult!['disease'] ?? 'Unknown',
            icon: Icons.coronavirus_outlined,
            valueColor: Colors.red[700],
          ),
          InfoCard(
            title: s.severity,
            value: CropAnalyzerPage.getSeverity(
              (_parsedResult!['damage_percent'] as num?)?.toDouble() ?? 0.0,
            ),
            icon: Icons.bar_chart,
            valueColor: _severityColor(
              CropAnalyzerPage.getSeverity(
                (_parsedResult!['damage_percent'] as num?)?.toDouble() ?? 0.0,
              ),
            ),
          ),
        ],

        InfoCard(
          title: s.damage,
          value: _parsedResult!['damage_percent'] != null
              ? '${(_parsedResult!['damage_percent'] as num).toStringAsFixed(2)}%'
              : 'N/A',
          icon: Icons.warning_amber,
        ),
        InfoCard(
          title: s.confidence,
          value: _parsedResult!['confidence_percent'] != null
              ? '${(_parsedResult!['confidence_percent'] as num).toStringAsFixed(2)}%'
              : 'N/A',
          progress: ((_parsedResult!['confidence_percent'] as num?)
                          ?.toDouble() ??
                      0) /
                  100,
          icon: Icons.show_chart,
        ),

        // Sprayer status
        Card(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: ListTile(
            leading: Icon(
              _isMotorRunning == true ? Icons.flash_on : Icons.flash_off,
              color: _isMotorRunning == true ? _kGreen : Colors.grey,
            ),
            title: Text(s.sprayer),
            subtitle: Text(
              [
                _isMotorRunning == null
                    ? s.motorUnavailable
                    : (_isMotorRunning! ? s.motorRunning : s.motorStopped),
                if (_iotStatus != null) _iotStatus!,
              ].join(' • '),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ACTION BOX WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class _ActionBox extends StatefulWidget {
  final IconData icon;
  final String label;
  final double iconSize;
  final double width;
  final double height;
  final bool isHighlighted;
  final bool enabled;
  final bool useLiveCamIcon;
  final List<String> fallbacks;
  final VoidCallback onTap;

  const _ActionBox({
    required this.icon,
    required this.label,
    required this.iconSize,
    required this.width,
    required this.height,
    required this.isHighlighted,
    required this.enabled,
    required this.fallbacks,
    required this.onTap,
    this.useLiveCamIcon = false,
  });

  @override
  State<_ActionBox> createState() => _ActionBoxState();
}

class _ActionBoxState extends State<_ActionBox> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool active = widget.enabled && !_pressed;

    final Color bgColor = widget.isHighlighted
        ? (_hovered ? const Color(0xFF1E7A2F) : _kGreen)
        : Colors.white;

    final Color borderColor =
        widget.isHighlighted ? Colors.transparent : _kLeaf;

    final Color iconColor =
        widget.isHighlighted ? Colors.white : _kDarkTeal;
    final Color labelColor =
        widget.isHighlighted ? Colors.white : _kDarkTeal;

    return Semantics(
      button: true,
      label: widget.label,
      enabled: widget.enabled,
      child: Tooltip(
        message: widget.label,
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.enabled ? widget.onTap : null,
            child: AnimatedScale(
              scale: _hovered && active ? 1.05 : (_pressed ? 0.96 : 1.0),
              duration: const Duration(milliseconds: 130),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  color: widget.enabled
                      ? bgColor
                      : Colors.grey[200],
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: widget.enabled
                        ? borderColor
                        : Colors.grey.shade300,
                    width: 1.8,
                  ),
                  gradient: widget.isHighlighted && widget.enabled
                      ? LinearGradient(
                          colors: [
                            _hovered
                                ? const Color(0xFF1E7A2F)
                                : _kGreen,
                            _kDarkTeal,
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                  boxShadow: widget.enabled
                      ? [
                          BoxShadow(
                            color: widget.isHighlighted
                                ? _kGreen.withValues(alpha: 0.30)
                                : Colors.black.withValues(alpha: 0.08),
                            blurRadius: widget.isHighlighted ? 18 : 10,
                            offset: const Offset(0, 5),
                          ),
                        ]
                      : [],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    widget.useLiveCamIcon
                        ? LiveCamIcon(
                            size: widget.iconSize,
                            color: widget.enabled
                                ? Colors.white
                                : Colors.grey.shade400,
                          )
                        : Icon(
                            widget.icon,
                            size: widget.iconSize,
                            color: widget.enabled
                                ? iconColor
                                : Colors.grey[400],
                          ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: widget.enabled
                                ? labelColor
                                : Colors.grey[400],
                          ).copyWith(
                              fontFamilyFallback: widget.fallbacks),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE CAM ICON  — custom line-art webcam with signal arcs and LIVE badge
// ─────────────────────────────────────────────────────────────────────────────
class LiveCamIcon extends StatelessWidget {
  final double size;
  final Color color;

  const LiveCamIcon({
    super.key,
    this.size = 72,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LiveCamPainter(color: color, size: size),
      ),
    );
  }
}

class _LiveCamPainter extends CustomPainter {
  final Color color;
  final double size;

  const _LiveCamPainter({required this.color, required this.size});

  @override
  void paint(Canvas canvas, Size sz) {
    final double s = size;
    final double sw = (s / 28).clamp(1.5, 3.5); // stroke width

    final Paint p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // ── Coordinate helpers (canvas is s × s) ────────────────────────────
    // Centre of lens circle
    final double cx = s * 0.50;
    final double cy = s * 0.44;

    // ── 1. Lens circles ──────────────────────────────────────────────────
    canvas.drawCircle(Offset(cx, cy), s * 0.195, p); // outer ring
    canvas.drawCircle(Offset(cx, cy), s * 0.120, p); // middle ring
    canvas.drawCircle(Offset(cx, cy), s * 0.048, fill); // inner filled dot

    // ── 2. Viewfinder brackets ───────────────────────────────────────────
    // Left bracket "["
    _bracket(canvas, p, cx - s * 0.24, cy, s * 0.13, sw, left: true);
    // Right bracket "]"
    _bracket(canvas, p, cx + s * 0.24, cy, s * 0.13, sw, left: false);

    // ── 3. Signal arcs ABOVE the lens ────────────────────────────────────
    for (int i = 1; i <= 3; i++) {
      final double r = s * (0.08 + i * 0.065);
      final Rect rect = Rect.fromCenter(
          center: Offset(cx, cy), width: r * 2, height: r * 2);
      canvas.drawArc(rect, -pi * 0.82, pi * 0.64, false, p);
    }

    // ── 4. Signal arcs LEFT ───────────────────────────────────────────────
    for (int i = 1; i <= 3; i++) {
      final double r = s * (0.07 + i * 0.055);
      final Rect rect = Rect.fromCenter(
          center: Offset(cx, cy), width: r * 2, height: r * 2);
      canvas.drawArc(rect, pi * 0.6, pi * 0.8, false, p);
    }

    // ── 5. Signal arcs RIGHT ─────────────────────────────────────────────
    for (int i = 1; i <= 3; i++) {
      final double r = s * (0.07 + i * 0.055);
      final Rect rect = Rect.fromCenter(
          center: Offset(cx, cy), width: r * 2, height: r * 2);
      canvas.drawArc(rect, -pi * 0.4, -pi * 0.8, false, p);
    }

    // ── 6. Neck + base stand ─────────────────────────────────────────────
    final double neckTop = cy + s * 0.20;
    final double neckBot = cy + s * 0.32;
    canvas.drawLine(Offset(cx, neckTop), Offset(cx, neckBot), p);

    // Angled legs
    canvas.drawLine(
        Offset(cx, neckBot), Offset(cx - s * 0.14, neckBot + s * 0.06), p);
    canvas.drawLine(
        Offset(cx, neckBot), Offset(cx + s * 0.14, neckBot + s * 0.06), p);

    // Base line
    canvas.drawLine(Offset(cx - s * 0.16, neckBot + s * 0.065),
        Offset(cx + s * 0.16, neckBot + s * 0.065), p);

    // ── 7. LIVE badge ─────────────────────────────────────────────────────
    final double bW = s * 0.38;
    final double bH = s * 0.14;
    final double bX = cx - bW / 2;
    final double bY = neckTop + s * 0.01;

    // Badge background (semi-transparent filled rounded rect)
    final Paint badgeBg = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(bX, bY, bW, bH), Radius.circular(bH / 2)),
        badgeBg);
    // Badge border
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(bX, bY, bW, bH), Radius.circular(bH / 2)),
        p..strokeWidth = sw * 0.7);

    // "LIVE" text inside badge
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: 'LIVE',
        style: TextStyle(
          color: color,
          fontSize: bH * 0.62,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(cx - tp.width / 2, bY + (bH - tp.height) / 2),
    );
  }

  /// Draws "[" (left=true) or "]" (left=false) bracket at (x, cy).
  void _bracket(Canvas canvas, Paint p, double x, double cy, double halfH,
      double sw, {required bool left}) {
    final double armLen = sw * 2.8;
    final double sign = left ? 1 : -1;
    final path = Path()
      ..moveTo(x + sign * armLen, cy - halfH)
      ..lineTo(x, cy - halfH)
      ..lineTo(x, cy + halfH)
      ..lineTo(x + sign * armLen, cy + halfH);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_LiveCamPainter old) =>
      old.color != color || old.size != size;
}
