import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
// ignore: unnecessary_import — Float32List is not re-exported by flutter/foundation.dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../config.dart';
import 'damage_estimator.dart';
import 'leaf_crop.dart';
import 'tflite_result.dart';

export 'tflite_result.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS — must match the trained model exactly
// ─────────────────────────────────────────────────────────────────────────────
// Override at build time with --dart-define=MODEL_ASSET=... / CLASS_NAMES_ASSET=...
const String _modelAsset = String.fromEnvironment('MODEL_ASSET',
    defaultValue: 'assets/models/crop_model_float16.tflite');
// Same file as ai_service/models/class_names.json (written by train_model.py)
const String _classNamesAsset = String.fromEnvironment('CLASS_NAMES_ASSET',
    defaultValue: 'assets/models/class_names.json');
const int _inputSize = 224;
// Unfamiliar-image check (ai_service/ood.py): prototypes of real training
// leaves in backbone-feature space. Optional — missing files disable it.
const String _oodStatsAsset = 'assets/models/ood_stats.json';
const String _oodProtosAsset = 'assets/models/ood_prototypes.bin';

/// Output of the background preprocessing step.
class _Prepared {
  final Float32List tensor;
  final double leafFraction;
  final double damagePercent;
  final int prepareMs;
  const _Prepared(this.tensor, this.leafFraction, this.damagePercent, this.prepareMs);
}

/// Raw pixels from the platform image decoder (Live Scan fast path).
class _RawFrame {
  final Uint8List rgba;
  final int width, height;
  final bool swapRedBlue; // USB camera photos have red/blue swapped
  const _RawFrame(this.rgba, this.width, this.height, this.swapRedBlue);
}

/// Background isolate, photo path: decode → fix EXIF rotation → [_prepareImage].
_Prepared _prepare(Uint8List bytes) {
  final sw = Stopwatch()..start();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception('Could not decode image bytes');
  return _prepareImage(img.bakeOrientation(decoded), sw);
}

/// Background isolate, Live Scan path: pixels are already decoded and
/// downscaled by the platform; swapping red/blue is free here (read as BGRA).
_Prepared _prepareRaw(_RawFrame f) {
  final sw = Stopwatch()..start();
  final frame = img.Image.fromBytes(
      width: f.width,
      height: f.height,
      bytes: f.rgba.buffer,
      bytesOffset: f.rgba.offsetInBytes,
      numChannels: 4,
      order: f.swapRedBlue ? img.ChannelOrder.bgra : img.ChannelOrder.rgba);
  return _prepareImage(frame, sw);
}

/// Leaf crop → model tensor (resize 224×224, /255 — same as training and the
/// server) + damage estimate + quality readings.
/// The frame is shrunk with area averaging, like training (cv2.INTER_AREA);
/// plain bilinear sampling at 5× downscale turns sensor noise into speckles
/// the model can read as lesions.
_Prepared _prepareImage(img.Image frame, Stopwatch sw) {
  // Square crop around the leaf: a wide webcam frame squashed to 224×224
  // distorts the leaf and buries it in background.
  final image = LeafCrop.apply(frame);

  final resized = img.copyResize(
    image,
    width: _inputSize,
    height: _inputSize,
    interpolation: img.Interpolation.average,
  );

  final tensor = Float32List(_inputSize * _inputSize * 3);
  int idx = 0;
  for (int y = 0; y < _inputSize; y++) {
    for (int x = 0; x < _inputSize; x++) {
      final pixel = resized.getPixel(x, y);
      tensor[idx++] = pixel.r / 255.0;
      tensor[idx++] = pixel.g / 255.0;
      tensor[idx++] = pixel.b / 255.0;
    }
  }

  // Measured on the 224×224 resize (DamageEstimator works at 224 anyway):
  // saves a second full resize of the crop.
  final damage = DamageEstimator.analyze(resized);
  return _Prepared(tensor, damage.leafFraction, damage.damagePercent,
      sw.elapsedMilliseconds);
}

// ─────────────────────────────────────────────────────────────────────────────
// TFLITE SERVICE
// ─────────────────────────────────────────────────────────────────────────────
class TfliteService {
  static Interpreter? _interpreter;
  static List<String> _classLabels = const [];
  static bool _isLoaded = false;
  // Output tensor indices: the converter may put the two outputs in any order.
  static int _probsOutput = 0;
  static int? _featuresOutput;
  static int _featureDim = 0;
  // Unfamiliar-image check (ood.py); null = disabled.
  static Float32List? _protos; // count × dim, L2-normalised
  static int _protoK = 3;
  static double _oodThreshold = 0;

  static Future<void> loadModel() async {
    if (_isLoaded) return;
    try {
      _classLabels = List<String>.from(
          jsonDecode(await rootBundle.loadString(_classNamesAsset)) as List);
      _interpreter = await Interpreter.fromAsset(_modelAsset);

      debugPrint('✅ TFLite model loaded: $_modelAsset');
      debugPrint('   Input  shape: ${_interpreter!.getInputTensor(0).shape}');
      final outputs = _interpreter!.getOutputTensors();
      _featuresOutput = null;
      for (int i = 0; i < outputs.length; i++) {
        final n = outputs[i].shape.last;
        debugPrint('   Output $i shape: ${outputs[i].shape}');
        if (n == _classLabels.length) {
          _probsOutput = i;
        } else {
          _featuresOutput = i;
          _featureDim = n;
        }
      }
      if (outputs[_probsOutput].shape.last != _classLabels.length) {
        throw StateError('Model outputs ${outputs[_probsOutput].shape.last} classes '
            'but $_classNamesAsset has ${_classLabels.length} labels.');
      }
      await _loadOod();

      _isLoaded = true;
    } catch (e) {
      debugPrint('❌ Failed to load TFLite model: $e');
      rethrow;
    }
  }

  /// Loads ood_stats.json + ood_prototypes.bin if they match this model.
  static Future<void> _loadOod() async {
    _protos = null;
    if (_featuresOutput == null) {
      debugPrint('⚠️ Model has no feature output — unfamiliar-image check off. '
          'Re-run convert_tflite.py.');
      return;
    }
    try {
      final meta = jsonDecode(await rootBundle.loadString(_oodStatsAsset))
          as Map<String, dynamic>;
      final names = List<String>.from(meta['class_names'] as List);
      final dim = meta['dim'] as int, count = meta['count'] as int;
      if (dim != _featureDim || names.join('|') != _classLabels.join('|')) {
        debugPrint('⚠️ $_oodStatsAsset does not match this model — '
            'unfamiliar-image check off.');
        return;
      }
      final bytes = await rootBundle.load(_oodProtosAsset);
      final protos = Float32List(count * dim);
      for (int i = 0; i < protos.length; i++) {
        protos[i] = bytes.getFloat32(i * 4, Endian.little);
      }
      _protos = protos;
      _protoK = meta['k'] as int;
      _oodThreshold = (meta['threshold'] as num).toDouble();
      debugPrint('   Unfamiliar-image check: $count prototypes, '
          'threshold ${_oodThreshold.toStringAsFixed(3)}');
    } catch (e) {
      debugPrint('⚠️ Unfamiliar-image check off: $e');
    }
  }

  /// 1 − mean cosine similarity to the k nearest prototypes (ood.py `scores`).
  static double unfamiliarScore(
      List<double> features, Float32List protos, int k) {
    final dim = features.length;
    double norm = 0;
    for (final v in features) {
      norm += v * v;
    }
    norm = norm > 0 ? 1 / math.sqrt(norm) : 0;
    final count = protos.length ~/ dim;
    final sims = List<double>.filled(count, 0);
    for (int p = 0; p < count; p++) {
      double s = 0;
      final base = p * dim;
      for (int j = 0; j < dim; j++) {
        s += features[j] * protos[base + j];
      }
      sims[p] = s * norm;
    }
    sims.sort();
    final top = math.min(k, count);
    double mean = 0;
    for (int i = count - top; i < count; i++) {
      mean += sims[i];
    }
    return 1 - mean / top;
  }

  static bool get isLoaded => _isLoaded;

  static int get _healthyIndex => _classLabels.indexOf(AppConfig.healthyClass);

  static Future<TfliteResult> predictFromFile(File imageFile) async {
    return predictFromBytes(await imageFile.readAsBytes());
  }

  static void _checkLoaded() {
    if (!_isLoaded || _interpreter == null) {
      throw StateError('Model not loaded. Call TfliteService.loadModel() first.');
    }
  }

  /// Photos (gallery / built-in camera): full decode in Dart, honours EXIF rotation.
  static Future<TfliteResult> predictFromBytes(Uint8List imageBytes) async {
    _checkLoaded();
    final total = Stopwatch()..start();
    final prepared = await compute(_prepare, imageBytes);
    return _run(prepared, 0, total);
  }

  /// Live Scan frames: Android's image decoder shrinks the frame to at most
  /// [maxWidth] while decoding — ~10× faster than decoding a 1080p JPEG in
  /// Dart, and still far more detail than the 224×224 model input needs.
  /// [swapRedBlue] fixes the USB camera's swapped colours at no extra cost;
  static Future<TfliteResult> predictCameraFrame(File frame,
      {required bool swapRedBlue, int maxWidth = 640}) async {
    _checkLoaded();
    final total = Stopwatch()..start();
    final buffer = await ui.ImmutableBuffer.fromUint8List(await frame.readAsBytes());
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec(
        targetWidth: math.min(maxWidth, descriptor.width));
    final image = (await codec.getNextFrame()).image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width, height = image.height;
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (rgba == null) throw Exception('Could not decode camera frame');
    final decodeMs = total.elapsedMilliseconds;

    final prepared = await compute(_prepareRaw,
        _RawFrame(rgba.buffer.asUint8List(), width, height, swapRedBlue));
    return _run(prepared, decodeMs, total);
  }

  static TfliteResult _run(_Prepared prepared, int decodeMs, Stopwatch total) {
    final input = prepared.tensor.reshape([1, _inputSize, _inputSize, 3]);
    final output =
        List.generate(1, (_) => List<double>.filled(_classLabels.length, 0.0));
    final features = _featuresOutput == null
        ? null
        : List.generate(1, (_) => List<double>.filled(_featureDim, 0.0));

    final stopwatch = Stopwatch()..start();
    _interpreter!.runForMultipleInputs([input], {
      _probsOutput: output,
      if (features != null) _featuresOutput!: features,
    });
    stopwatch.stop();

    final List<double> probs = output[0];
    final protos = _protos;
    final unfamiliar = protos == null || features == null
        ? null
        : unfamiliarScore(features[0], protos, _protoK);
    int maxIdx = 0;
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > probs[maxIdx]) maxIdx = i;
    }
    final double maxProb = probs[maxIdx];

    // Most likely disease: best class that is neither Healthy nor Not_Leaf.
    int bestDisease = -1;
    for (int i = 0; i < probs.length; i++) {
      final label = _classLabels[i];
      if (label == AppConfig.healthyClass || label == AppConfig.notLeafClass) {
        continue;
      }
      if (bestDisease < 0 || probs[i] > probs[bestDisease]) bestDisease = i;
    }
    final notLeafIdx = _classLabels.indexOf(AppConfig.notLeafClass);

    final leafDetected = prepared.leafFraction >= DamageEstimator.minLeafFraction;
    final uncertain = maxProb < AppConfig.confidenceThreshold;

    final result = TfliteResult(
      disease: uncertain ? 'Uncertain' : _classLabels[maxIdx],
      confidence: maxProb,
      isUncertain: uncertain,
      healthyProb: _healthyIndex < 0 ? 0.0 : probs[_healthyIndex],
      notLeafProb: notLeafIdx < 0 ? 0.0 : probs[notLeafIdx],
      topClass: _classLabels[maxIdx],
      bestDisease: bestDisease < 0 ? '' : _classLabels[bestDisease],
      bestDiseaseProb: bestDisease < 0 ? 0.0 : probs[bestDisease],
      leafFraction: prepared.leafFraction,
      leafDetected: leafDetected,
      unfamiliarScore: unfamiliar,
      unfamiliarThreshold: unfamiliar == null ? null : _oodThreshold,
      damagePercent: prepared.damagePercent,
      allProbs: probs,
      inferenceMs: stopwatch.elapsedMilliseconds,
      decodeMs: decodeMs,
      prepareMs: prepared.prepareMs,
      totalMs: total.elapsedMilliseconds,
    );
    debugPrint('🔍 $result');
    return result;
  }

  static void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
