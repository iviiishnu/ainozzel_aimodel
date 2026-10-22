import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/language_state.dart';
import 'crop_analyzer_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS YOU MAY WANT TO TWEAK
// ─────────────────────────────────────────────────────────────────────────────
// false -> heading on top, SVCE banner under it   (default)
// true  -> SVCE banner on top, heading under it
const bool kBannerFirst = false;

// ─────────────────────────────────────────────────────────────────────────────
// COLORS
// ─────────────────────────────────────────────────────────────────────────────
class _WelcomeColors {
  static const Color darkTeal = Color(0xFF0B5D5A);
  static const Color green = Color(0xFF2E8B3D);
  static const Color leaf = Color(0xFF5DB36B);
  static const Color orange = Color(0xFFE38000); // accent bar
  static const Color cta = Color(0xFFD9480F); // Start button (contrast colour)
  static const Color ctaHover = Color(0xFFBF3F0B);
  static const Color mintTop = Color(0xFFE8F5E9);
  static const Color mintBottom = Color(0xFFF6FBF4);
  static const Color disabledFill = Color(0xFFCFD8DC);
  static const Color disabledText = Color(0xFF78909C);
  static const Color shadowGreen = Color(0xFF2E7D32); // silhouettes
}

// ─────────────────────────────────────────────────────────────────────────────
// APP-WIDE SELECTED LANGUAGE  — stored in LanguageState.selected (ValueNotifier)
// Import language_state.dart to read it anywhere: LanguageState.selected.value
// ─────────────────────────────────────────────────────────────────────────────

class _LanguageOption {
  final String code;
  final String label;
  final String startLabel; // "Start" in that language
  const _LanguageOption(this.code, this.label, this.startLabel);
}

const List<_LanguageOption> _languages = [
  _LanguageOption('Hindi',   'हिन्दी (Hindi)',    'शुरू करें'),
  _LanguageOption('English', 'English',            'Start'),
  _LanguageOption('Kannada', 'ಕನ್ನಡ (Kannada)',   'ಪ್ರಾರಂಭಿಸಿ'),
  _LanguageOption('Telugu',  'తెలుగు (Telugu)',    'ప్రారంభించు'),
  _LanguageOption('Tamil',   'தமிழ் (Tamil)',      'தொடங்கு'),
];

// ─────────────────────────────────────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceCtrl;

  String? _language; // null -> Start disabled
  bool _buttonHovered = false;

  bool get _canStart => _language != null;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  Widget _reveal(double from, double to, Widget child) {
    final anim = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Interval(from, to, curve: Curves.easeOut),
    );
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.2),
          end: Offset.zero,
        ).animate(anim),
        child: child,
      ),
    );
  }

  void _onStart() {
    if (!_canStart) return;
    LanguageState.selected.value = _language;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CropAnalyzerPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool isDesktop = constraints.maxWidth >= 600;
          final double maxW = constraints.maxWidth;

          final Widget heading = _reveal(0.0, 0.4, _buildHeading(isDesktop));
          final Widget banner = _reveal(0.1, 0.5, _buildBannerCard(isDesktop));

          return Stack(
            children: [
              // ── Background gradient ─────────────────────────────────────
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_WelcomeColors.mintTop, _WelcomeColors.mintBottom],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),

              // ── Faint leaves ────────────────────────────────────────────
              Positioned(
                left: -60,
                top: -50,
                child: Transform.rotate(
                  angle: -0.5,
                  child: Icon(Icons.eco,
                      size: isDesktop ? 260 : 170,
                      color: _WelcomeColors.leaf.withValues(alpha: 0.08)),
                ),
              ),
              Positioned(
                right: isDesktop ? 90 : 10,
                top: isDesktop ? 30 : 16,
                child: Transform.rotate(
                  angle: 0.6,
                  child: Icon(Icons.spa_outlined,
                      size: isDesktop ? 110 : 64,
                      color: _WelcomeColors.leaf.withValues(alpha: 0.07)),
                ),
              ),
              Positioned(
                left: -50,
                bottom: -70,
                child: Transform.rotate(
                  angle: 0.9,
                  child: Icon(Icons.eco,
                      size: isDesktop ? 300 : 190,
                      color: _WelcomeColors.leaf.withValues(alpha: 0.06)),
                ),
              ),
              Positioned(
                right: -60,
                bottom: -70,
                child: Transform.rotate(
                  angle: 2.4,
                  child: Icon(Icons.eco,
                      size: isDesktop ? 320 : 200,
                      color: _WelcomeColors.leaf.withValues(alpha: 0.06)),
                ),
              ),

              // ── Bottom-left: tractor silhouette ─────────────────────────
              Positioned(
                left: isDesktop ? 40 : 10,
                bottom: isDesktop ? 24 : 8,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: Size(isDesktop ? 320 : 150, isDesktop ? 229 : 107),
                    painter: const _TractorPainter(0.14),
                  ),
                ),
              ),

              // ── Bottom-right: farmer silhouette ─────────────────────────
              Positioned(
                right: isDesktop ? 60 : 14,
                bottom: isDesktop ? 24 : 8,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: Size(isDesktop ? 170 : 80, isDesktop ? 298 : 140),
                    painter: const _FarmerPainter(0.14),
                  ),
                ),
              ),

              // ── Main content (top aligned, tight top padding) ───────────
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxW),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          isDesktop ? 20 : 12, // reduced top padding
                          20,
                          24,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (kBannerFirst) ...[
                              banner,
                              SizedBox(height: isDesktop ? 18 : 12),
                              heading,
                            ] else ...[
                              heading,
                              SizedBox(height: isDesktop ? 18 : 12),
                              banner,
                            ],
                            SizedBox(height: isDesktop ? 14 : 10),

                            // Tagline
                            _reveal(0.3, 0.7, _buildTagline(isDesktop)),
                            SizedBox(height: isDesktop ? 26 : 20),

                            // Language dropdown
                            _reveal(0.45, 0.85, _buildLanguageDropdown(isDesktop)),
                            const SizedBox(height: 16),

                            // Start button
                            _reveal(0.6, 1.0, _buildStartButton(isDesktop)),
                          ],
                        ),
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

  // ── Heading: ONE line, smaller ────────────────────────────────────────────
  Widget _buildHeading(bool isDesktop) {
    return Semantics(
      header: true,
      child: Column(
        children: [
          // FittedBox guarantees a single line: it shrinks the text instead
          // of wrapping when the window is narrow.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Welcome to SVCE Crop Analyzer',
              maxLines: 1,
              softWrap: false,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: isDesktop ? 34 : 22,
                fontWeight: FontWeight.w800,
                color: _WelcomeColors.darkTeal,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: isDesktop ? 70 : 52,
            height: 4,
            decoration: BoxDecoration(
              color: _WelcomeColors.orange,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ),
    );
  }

  // ── SVCE banner (smaller card) ────────────────────────────────────────────
  Widget _buildBannerCard(bool isDesktop) {
    return Container(
      width: isDesktop ? 400 : 300,
      height: isDesktop ? 112 : 84,
      padding: EdgeInsets.all(isDesktop ? 12 : 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
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
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: _WelcomeColors.darkTeal,
            ),
          ),
        ),
      ),
    );
  }

  // ── Tagline (smaller) ─────────────────────────────────────────────────────
  Widget _buildTagline(bool isDesktop) {
    return Text(
      'Your smart friend for better farming decisions',
      textAlign: TextAlign.center,
      style: GoogleFonts.poppins(
        fontSize: isDesktop ? 14 : 12,
        color: Colors.grey[600],
      ),
    );
  }

  // ── Language dropdown ─────────────────────────────────────────────────────
  Widget _buildLanguageDropdown(bool isDesktop) {
    final List<String> fallbacks = [
      GoogleFonts.notoSansDevanagari().fontFamily!,
      GoogleFonts.notoSansKannada().fontFamily!,
      GoogleFonts.notoSansTelugu().fontFamily!,
      GoogleFonts.notoSansTamil().fontFamily!,
    ];

    final TextStyle itemStyle = GoogleFonts.poppins(
      fontSize: 16,
      color: Colors.grey[900],
    ).copyWith(fontFamilyFallback: fallbacks);

    final TextStyle hintStyle = GoogleFonts.poppins(
      fontSize: 16,
      color: Colors.grey[600],
    );

    return Semantics(
      label: 'Select language',
      child: Container(
        width: isDesktop ? 320 : 280,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _WelcomeColors.leaf, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _language,
            isExpanded: true,
            borderRadius: BorderRadius.circular(14),
            dropdownColor: Colors.white,
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                size: 22, color: _WelcomeColors.green),
            hint: Row(
              children: [
                const Icon(Icons.language,
                    size: 20, color: _WelcomeColors.green),
                const SizedBox(width: 10),
                Text('Select Language', style: hintStyle),
              ],
            ),
            selectedItemBuilder: (context) => _languages
                .map((l) => Row(
                      children: [
                        const Icon(Icons.language,
                            size: 20, color: _WelcomeColors.green),
                        const SizedBox(width: 10),
                        Text(l.label, style: itemStyle),
                      ],
                    ))
                .toList(),
            items: _languages
                .map((l) => DropdownMenuItem<String>(
                      value: l.code,
                      child: Text(l.label, style: itemStyle),
                    ))
                .toList(),
            onChanged: (value) {
              setState(() => _language = value);
              LanguageState.selected.value = value;
            },
          ),
        ),
      ),
    );
  }

  // ── Start button: disabled until a language is chosen ─────────────────────
  Widget _buildStartButton(bool isDesktop) {
    final bool enabled = _canStart;
    final Color fill = !enabled
        ? _WelcomeColors.disabledFill
        : (_buttonHovered ? _WelcomeColors.ctaHover : _WelcomeColors.cta);
    final Color fg = enabled ? Colors.white : _WelcomeColors.disabledText;

    // Find the translated "Start" label for the selected language
    final String startLabel = _language == null
        ? 'Start'
        : _languages
            .firstWhere((l) => l.code == _language,
                orElse: () => const _LanguageOption('English', 'English', 'Start'))
            .startLabel;

    // Fallback fonts for Indic scripts on the button
    final List<String> fallbacks = [
      GoogleFonts.notoSansDevanagari().fontFamily!,
      GoogleFonts.notoSansKannada().fontFamily!,
      GoogleFonts.notoSansTelugu().fontFamily!,
      GoogleFonts.notoSansTamil().fontFamily!,
    ];

    return Column(
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: startLabel,
          child: MouseRegion(
            cursor:
                enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) {
              if (enabled) setState(() => _buttonHovered = true);
            },
            onExit: (_) => setState(() => _buttonHovered = false),
            child: AnimatedScale(
              scale: enabled && _buttonHovered ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: GestureDetector(
                onTap: enabled ? _onStart : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: isDesktop ? 260 : 220,
                  height: 54,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: enabled
                        ? [
                            BoxShadow(
                              color: _WelcomeColors.cta.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : [],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.agriculture, color: fg, size: 20),
                      const SizedBox(width: 10),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: child,
                        ),
                        child: Text(
                          startLabel,
                          key: ValueKey(startLabel),
                          style: GoogleFonts.poppins(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: fg,
                          ).copyWith(fontFamilyFallback: fallbacks),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: enabled ? 0 : 1,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Please select a language to continue',
              style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TRACTOR SILHOUETTE (design box 140 x 100)
// All parts are drawn opaque inside one layer, then the layer is faded, so
// overlapping parts don't create darker patches.
// ─────────────────────────────────────────────────────────────────────────────
class _TractorPainter extends CustomPainter {
  final double opacity;
  const _TractorPainter(this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.scale(size.width / 140, size.height / 100);

    final fill = Paint()..color = _WelcomeColors.shadowGreen;
    final line = Paint()
      ..color = _WelcomeColors.shadowGreen
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Chassis + hood
    canvas.drawRRect(
        RRect.fromLTRBR(44, 58, 124, 74, const Radius.circular(4)), fill);
    canvas.drawRRect(
        RRect.fromLTRBR(68, 44, 128, 70, const Radius.circular(7)), fill);

    // Exhaust pipe
    canvas.drawRRect(
        RRect.fromLTRBR(110, 26, 115, 46, const Radius.circular(2)), fill);

    // Cabin with window cut-out
    final cabin = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(34, 58)
      ..lineTo(38, 20)
      ..lineTo(70, 20)
      ..lineTo(74, 58)
      ..close()
      ..addRect(const Rect.fromLTWH(43, 25, 24, 20));
    canvas.drawPath(cabin, fill);
    canvas.drawRRect(
        RRect.fromLTRBR(30, 14, 78, 21, const Radius.circular(3)), fill);

    // Wheels
    _wheel(canvas, const Offset(40, 68), 28, 20, 7, fill, line);
    _wheel(canvas, const Offset(112, 80), 16, 11, 4, fill, line);

    // Ground + grass blades
    line
      ..strokeWidth = 2.5
      ..color = _WelcomeColors.shadowGreen;
    canvas.drawLine(const Offset(2, 97.5), const Offset(138, 97.5), line);
    for (final x in [6.0, 12.0, 128.0, 134.0]) {
      canvas.drawLine(Offset(x, 97), Offset(x - 2, 88), line..strokeWidth = 2);
      canvas.drawLine(Offset(x, 97), Offset(x + 3, 89), line);
    }

    canvas.restore();
  }

  void _wheel(Canvas c, Offset o, double r, double inner, double hub,
      Paint fill, Paint line) {
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: o, radius: r))
      ..addOval(Rect.fromCircle(center: o, radius: inner));
    c.drawPath(ring, fill);
    c.drawCircle(o, hub, fill);
    line.strokeWidth = r > 20 ? 3 : 2;
    for (int i = 0; i < 4; i++) {
      final a = i * pi / 2 + pi / 4;
      c.drawLine(o, o + Offset(cos(a), sin(a)) * inner, line);
    }
  }

  @override
  bool shouldRepaint(_TractorPainter old) => old.opacity != opacity;
}

// ─────────────────────────────────────────────────────────────────────────────
// FARMER SILHOUETTE (design box 100 x 175): hat, hoe/spade, boots
// ─────────────────────────────────────────────────────────────────────────────
class _FarmerPainter extends CustomPainter {
  final double opacity;
  const _FarmerPainter(this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.scale(size.width / 100, size.height / 175);

    final fill = Paint()..color = _WelcomeColors.shadowGreen;
    final line = Paint()
      ..color = _WelcomeColors.shadowGreen
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Hat (crown + wide brim)
    canvas.drawRRect(
        RRect.fromLTRBR(37, 10, 63, 25, const Radius.circular(10)), fill);
    canvas.drawOval(Rect.fromCenter(center: const Offset(50, 25), width: 56, height: 8), fill);

    // Head
    canvas.drawCircle(const Offset(50, 37), 11, fill);

    // Torso
    final torso = Path()
      ..moveTo(35, 51)
      ..quadraticBezierTo(50, 44, 65, 51)
      ..lineTo(63, 102)
      ..lineTo(37, 102)
      ..close();
    canvas.drawPath(torso, fill);

    // Legs + boots
    canvas.drawRRect(
        RRect.fromLTRBR(38, 100, 49, 163, const Radius.circular(5)), fill);
    canvas.drawRRect(
        RRect.fromLTRBR(51, 100, 62, 163, const Radius.circular(5)), fill);
    canvas.drawOval(const Rect.fromLTWH(33, 160, 18, 9), fill);
    canvas.drawOval(const Rect.fromLTWH(49, 160, 18, 9), fill);

    // Arms
    line.strokeWidth = 8;
    canvas.drawLine(const Offset(36, 56), const Offset(30, 98), line);
    canvas.drawLine(const Offset(64, 56), const Offset(80, 84), line);

    // Spade / hoe
    line.strokeWidth = 3.5;
    canvas.drawLine(const Offset(84, 50), const Offset(84, 166), line);
    final blade = Path()
      ..moveTo(75, 160)
      ..lineTo(93, 160)
      ..lineTo(84, 173)
      ..close();
    canvas.drawPath(blade, fill);

    // Ground + grass blades
    line.strokeWidth = 2.5;
    canvas.drawLine(const Offset(4, 171), const Offset(98, 171), line);
    for (final x in [8.0, 16.0, 92.0]) {
      canvas.drawLine(Offset(x, 170), Offset(x - 2, 160), line..strokeWidth = 2);
      canvas.drawLine(Offset(x, 170), Offset(x + 3, 161), line);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_FarmerPainter old) => old.opacity != opacity;
}