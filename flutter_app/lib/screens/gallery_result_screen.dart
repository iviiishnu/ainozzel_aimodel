import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config.dart';
import '../services/analysis_service.dart';
import '../services/app_strings.dart';
import '../services/language_state.dart';
import '../widgets/info_card.dart';

const Color _kDarkTeal = Color(0xFF0B5D5A);
const Color _kGreen = Color(0xFF2E8B3D);
const Color _kMintTop = Color(0xFFE3F4E6);
const Color _kMintBottom = Color(0xFFF7FBF2);

/// Result page for a photo picked from the gallery. Pass [imageFile] on
/// Android/desktop and [imageBytes] on web (no file paths there).
class GalleryResultScreen extends StatefulWidget {
  final File? imageFile;
  final Uint8List? imageBytes;

  const GalleryResultScreen({this.imageFile, this.imageBytes, super.key})
      : assert(imageFile != null || imageBytes != null);

  @override
  State<GalleryResultScreen> createState() => _GalleryResultScreenState();
}

class _GalleryResultScreenState extends State<GalleryResultScreen> {
  Map<String, dynamic>? _result;
  String? _iotStatus;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    final result = widget.imageBytes != null
        ? await AnalysisService.analyzeBytes(widget.imageBytes!)
        : await AnalysisService.analyze(widget.imageFile!);
    if (!mounted) return;
    setState(() => _result = result);

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

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(LanguageState.selected.value);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _kDarkTeal,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          s.appBarTitle,
          style: GoogleFonts.poppins(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_kMintTop, _kMintBottom],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Container(
                      color: Colors.white,
                      child: widget.imageBytes != null
                          ? Image.memory(widget.imageBytes!, fit: BoxFit.contain)
                          : Image.file(widget.imageFile!, fit: BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_result == null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(color: _kGreen),
                        const SizedBox(height: 12),
                        Text(s.analyzing),
                      ],
                    ),
                  )
                else
                  _buildResult(s, _result!),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResult(AppStrings s, Map<String, dynamic> r) {
    if (r['error'] != null) {
      return Card(
        color: Colors.red[50],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ListTile(
          leading: const Icon(Icons.error_outline, color: Colors.red),
          title: Text(
            [r['error'], if (r['message'] != null) r['message']].join('\n'),
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }

    final damage = (r['damage_percent'] as num?)?.toDouble() ?? 0.0;
    final confidence = (r['confidence_percent'] as num?)?.toDouble() ?? 0.0;
    final severity = AppConfig.severityFor(damage);
    final status = r['status'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (status == 'Uncertain' || status == 'NotLeaf')
          Card(
            color: Colors.orange[50],
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const Icon(Icons.warning_amber, color: Colors.orange),
              title: Text(r['message'] ?? s.retakeHint,
                  style: const TextStyle(color: Colors.orange)),
            ),
          )
        else ...[
          InfoCard(
            title: s.disease,
            value: r['disease'] ?? 'Unknown',
            icon: Icons.coronavirus_outlined,
            valueColor: status == 'Healthy' ? _kGreen : Colors.red[700],
          ),
          InfoCard(
            title: s.severity,
            value: severity,
            icon: Icons.bar_chart,
            valueColor: _severityColor(severity),
          ),
        ],
        InfoCard(
          title: s.damage,
          value: '${damage.toStringAsFixed(2)}%',
          icon: Icons.warning_amber,
        ),
        InfoCard(
          title: s.confidence,
          value: '${confidence.toStringAsFixed(2)}%',
          progress: confidence / 100,
          icon: Icons.show_chart,
        ),
        if (_iotStatus != null)
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const Icon(Icons.water_drop_outlined, color: _kGreen),
              title: Text(s.sprayer),
              subtitle: Text(_iotStatus!),
            ),
          ),
      ],
    );
  }
}
