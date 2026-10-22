/// Centralized localization strings for the app.
/// Keyed by language code (matching the codes in home_screen.dart).
/// Usage:
///   final s = AppStrings.of(LanguageState.selected.value ?? 'English');
///   s.gallery  // → 'Gallery' or 'ಗ್ಯಾಲರಿ' etc.
class AppStrings {
  final String appBarTitle;
  final String aiCropAnalyzer;
  final String noImageSelected;
  final String chooseHint;
  final String gallery;
  final String camera;
  final String liveCamera;
  final String analyzing;
  final String noImageCaptured;
  final String onDeviceTflite;
  final String serverInference;
  final String serverFallback;
  final String disease;
  final String severity;
  final String damage;
  final String confidence;
  final String sprayer;
  final String motorRunning;
  final String motorStopped;
  final String motorUnavailable;
  final String retakeHint;
  final String settings;
  final String selectLanguage;
  final String pleaseSelectLanguage;

  const AppStrings({
    required this.appBarTitle,
    required this.aiCropAnalyzer,
    required this.noImageSelected,
    required this.chooseHint,
    required this.gallery,
    required this.camera,
    required this.liveCamera,
    required this.analyzing,
    required this.noImageCaptured,
    required this.onDeviceTflite,
    required this.serverInference,
    required this.serverFallback,
    required this.disease,
    required this.severity,
    required this.damage,
    required this.confidence,
    required this.sprayer,
    required this.motorRunning,
    required this.motorStopped,
    required this.motorUnavailable,
    required this.retakeHint,
    required this.settings,
    required this.selectLanguage,
    required this.pleaseSelectLanguage,
  });

  // ── English ───────────────────────────────────────────────────────────────
  static const AppStrings _english = AppStrings(
    appBarTitle: 'Crop Analyzer',
    aiCropAnalyzer: 'AI CROP ANALYZER',
    noImageSelected: 'No image selected',
    chooseHint:
        'Choose a photo from Gallery, or open Camera or Live Camera to take the photo.',
    gallery: 'Gallery',
    camera: 'Camera',
    liveCamera: 'Live Camera',
    analyzing: 'Analyzing…',
    noImageCaptured: 'No image captured',
    onDeviceTflite: 'On-device TFLite',
    serverInference: 'Server',
    serverFallback: 'Server (fallback)',
    disease: 'Disease',
    severity: 'Severity',
    damage: 'Damage',
    confidence: 'Confidence',
    sprayer: 'Sprayer',
    motorRunning: 'Motor running',
    motorStopped: 'Motor stopped',
    motorUnavailable: 'Motor status unavailable',
    retakeHint: 'Low confidence — retake the photo.',
    settings: 'Settings',
    selectLanguage: 'Select Language',
    pleaseSelectLanguage: 'Please select a language to continue',
  );

  // ── Hindi ─────────────────────────────────────────────────────────────────
  static const AppStrings _hindi = AppStrings(
    appBarTitle: 'फसल विश्लेषक',
    aiCropAnalyzer: 'AI फसल विश्लेषक',
    noImageSelected: 'कोई छवि नहीं चुनी गई',
    chooseHint:
        'गैलरी से फ़ोटो चुनें, या कैमरा या लाइव कैमरा खोलें।',
    gallery: 'गैलरी',
    camera: 'कैमरा',
    liveCamera: 'लाइव कैमरा',
    analyzing: 'विश्लेषण हो रहा है…',
    noImageCaptured: 'कोई छवि नहीं ली गई',
    onDeviceTflite: 'ऑन-डिवाइस TFLite',
    serverInference: 'सर्वर',
    serverFallback: 'सर्वर (फ़ॉलबैक)',
    disease: 'रोग',
    severity: 'गंभीरता',
    damage: 'क्षति',
    confidence: 'आत्मविश्वास',
    sprayer: 'स्प्रेयर',
    motorRunning: 'मोटर चल रही है',
    motorStopped: 'मोटर बंद है',
    motorUnavailable: 'मोटर स्थिति अनुपलब्ध',
    retakeHint: 'कम आत्मविश्वास — फ़ोटो फिर से लें।',
    settings: 'सेटिंग्स',
    selectLanguage: 'भाषा चुनें',
    pleaseSelectLanguage: 'जारी रखने के लिए भाषा चुनें',
  );

  // ── Kannada ───────────────────────────────────────────────────────────────
  static const AppStrings _kannada = AppStrings(
    appBarTitle: 'ಬೆಳೆ ವಿಶ್ಲೇಷಕ',
    aiCropAnalyzer: 'AI ಬೆಳೆ ವಿಶ್ಲೇಷಕ',
    noImageSelected: 'ಯಾವುದೇ ಚಿತ್ರ ಆಯ್ಕೆ ಮಾಡಿಲ್ಲ',
    chooseHint:
        'ಗ್ಯಾಲರಿಯಿಂದ ಫೋಟೋ ಆರಿಸಿ, ಅಥವಾ ಕ್ಯಾಮೆರಾ ಅಥವಾ ಲೈವ್ ಕ್ಯಾಮೆರಾ ತೆರೆಯಿರಿ.',
    gallery: 'ಗ್ಯಾಲರಿ',
    camera: 'ಕ್ಯಾಮೆರಾ',
    liveCamera: 'ಲೈವ್ ಕ್ಯಾಮೆರಾ',
    analyzing: 'ವಿಶ್ಲೇಷಿಸಲಾಗುತ್ತಿದೆ…',
    noImageCaptured: 'ಯಾವುದೇ ಚಿತ್ರ ತೆಗೆಯಲಾಗಿಲ್ಲ',
    onDeviceTflite: 'ಆನ್-ಡಿವೈಸ್ TFLite',
    serverInference: 'ಸರ್ವರ್',
    serverFallback: 'ಸರ್ವರ್ (ಫಾಲ್‌ಬ್ಯಾಕ್)',
    disease: 'ರೋಗ',
    severity: 'ತೀವ್ರತೆ',
    damage: 'ಹಾನಿ',
    confidence: 'ವಿಶ್ವಾಸಾರ್ಹತೆ',
    sprayer: 'ಸ್ಪ್ರೇಯರ್',
    motorRunning: 'ಮೋಟಾರ್ ಚಾಲನೆಯಲ್ಲಿದೆ',
    motorStopped: 'ಮೋಟಾರ್ ನಿಂತಿದೆ',
    motorUnavailable: 'ಮೋಟಾರ್ ಸ್ಥಿತಿ ಲಭ್ಯವಿಲ್ಲ',
    retakeHint: 'ಕಡಿಮೆ ವಿಶ್ವಾಸಾರ್ಹತೆ — ಫೋಟೋ ಮತ್ತೆ ತೆಗೆಯಿರಿ.',
    settings: 'ಸೆಟ್ಟಿಂಗ್‌ಗಳು',
    selectLanguage: 'ಭಾಷೆ ಆಯ್ಕೆ ಮಾಡಿ',
    pleaseSelectLanguage: 'ಮುಂದುವರಿಯಲು ಭಾಷೆ ಆಯ್ಕೆ ಮಾಡಿ',
  );

  // ── Telugu ────────────────────────────────────────────────────────────────
  static const AppStrings _telugu = AppStrings(
    appBarTitle: 'పంట విశ్లేషకుడు',
    aiCropAnalyzer: 'AI పంట విశ్లేషకుడు',
    noImageSelected: 'చిత్రం ఎంచుకోబడలేదు',
    chooseHint:
        'గ్యాలరీ నుండి ఫోటో ఎంచుకోండి, లేదా కెమెరా లేదా లైవ్ కెమెరా తెరవండి.',
    gallery: 'గ్యాలరీ',
    camera: 'కెమెరా',
    liveCamera: 'లైవ్ కెమెరా',
    analyzing: 'విశ్లేషిస్తోంది…',
    noImageCaptured: 'చిత్రం తీయబడలేదు',
    onDeviceTflite: 'ఆన్-డివైస్ TFLite',
    serverInference: 'సర్వర్',
    serverFallback: 'సర్వర్ (ఫాల్‌బ్యాక్)',
    disease: 'వ్యాధి',
    severity: 'తీవ్రత',
    damage: 'నష్టం',
    confidence: 'విశ్వాసం',
    sprayer: 'స్ప్రేయర్',
    motorRunning: 'మోటారు నడుస్తోంది',
    motorStopped: 'మోటారు ఆగింది',
    motorUnavailable: 'మోటారు స్థితి అందుబాటులో లేదు',
    retakeHint: 'తక్కువ విశ్వాసం — ఫోటో మళ్ళీ తీయండి.',
    settings: 'సెట్టింగులు',
    selectLanguage: 'భాష ఎంచుకోండి',
    pleaseSelectLanguage: 'కొనసాగించడానికి భాష ఎంచుకోండి',
  );

  // ── Tamil ─────────────────────────────────────────────────────────────────
  static const AppStrings _tamil = AppStrings(
    appBarTitle: 'பயிர் பகுப்பாய்வி',
    aiCropAnalyzer: 'AI பயிர் பகுப்பாய்வி',
    noImageSelected: 'படம் தேர்ந்தெடுக்கப்படவில்லை',
    chooseHint:
        'கேலரியிலிருந்து புகைப்படம் தேர்ந்தெடுக்கவும், அல்லது கேமரா திறக்கவும்.',
    gallery: 'கேலரி',
    camera: 'கேமரா',
    liveCamera: 'நேரலை கேமரா',
    analyzing: 'பகுப்பாய்வு செய்கிறது…',
    noImageCaptured: 'படம் எடுக்கப்படவில்லை',
    onDeviceTflite: 'சாதனத்தில் TFLite',
    serverInference: 'சர்வர்',
    serverFallback: 'சர்வர் (பின்னடைவு)',
    disease: 'நோய்',
    severity: 'தீவிரம்',
    damage: 'சேதம்',
    confidence: 'நம்பிக்கை',
    sprayer: 'தெளிப்பி',
    motorRunning: 'மோட்டார் இயங்குகிறது',
    motorStopped: 'மோட்டார் நிறுத்தப்பட்டது',
    motorUnavailable: 'மோட்டார் நிலை கிடைக்கவில்லை',
    retakeHint: 'குறைந்த நம்பிக்கை — படம் மீண்டும் எடுக்கவும்.',
    settings: 'அமைப்புகள்',
    selectLanguage: 'மொழியை தேர்ந்தெடுக்கவும்',
    pleaseSelectLanguage: 'தொடர மொழியை தேர்ந்தெடுக்கவும்',
  );

  static const Map<String, AppStrings> _map = {
    'English': _english,
    'Hindi': _hindi,
    'Kannada': _kannada,
    'Telugu': _telugu,
    'Tamil': _tamil,
  };

  /// Returns strings for [lang], falling back to English if not found.
  static AppStrings of(String? lang) => _map[lang] ?? _english;
}
