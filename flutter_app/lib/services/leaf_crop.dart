import 'package:image/image.dart' as img;

import 'damage_estimator.dart';

/// Square crop around the leaf, so a wide 16:9 webcam frame looks like the
/// training photos (square, leaf filling the frame) instead of being squashed
/// with lots of background. The leaf is found by its green tissue; with too
/// little green (e.g. a fully browned leaf) it falls back to the centre square.
///
/// Dart port of ai_service/preprocessing.py `crop_to_leaf` — keep both in sync.
/// Measured on simulated 1280×720 webcam frames: 63% → 85% correct.
class LeafCrop {
  LeafCrop._();

  static const int workWidth = 160; // leaf is located on a frame this wide
  static const double minGreen = 0.02; // green share needed to trust the box
  static const double margin = 1.15; // box side × this
  static const double minSide = 0.30; // never tighter than this × short side
  static const double fullSide = 0.80; // box ≥ this × short side → whole side
  static const double squareRatio = 1.40; // square-ish close-up → no crop

  static img.Image apply(img.Image image) {
    final w0 = image.width, h0 = image.height;
    final short = w0 < h0 ? w0 : h0;
    final scale = workWidth / w0;
    final sh = (h0 * scale).round().clamp(1, 100000);
    final small = img.copyResize(image,
        width: workWidth, height: sh, interpolation: img.Interpolation.average);

    var green = List<bool>.filled(workWidth * sh, false);
    for (final p in small) {
      final (h, s, v) = DamageEstimator.toHsv(p.r.toInt(), p.g.toInt(), p.b.toInt());
      green[p.y * workWidth + p.x] = s >= DamageEstimator.leafMinSat &&
          v >= DamageEstimator.leafMinVal &&
          h >= DamageEstimator.healthyHueMin &&
          h <= DamageEstimator.healthyHueMax;
    }
    green = _open3x3(green, workWidth, sh);

    final xs = <int>[], ys = <int>[];
    for (int i = 0; i < green.length; i++) {
      if (green[i]) {
        xs.add(i % workWidth);
        ys.add(i ~/ workWidth);
      }
    }

    double side, cx, cy;
    if (xs.length < minGreen * green.length) {
      side = short.toDouble();
      cx = w0 / 2;
      cy = h0 / 2;
    } else {
      // 2nd–98th percentile: ignores stray green specks in the background
      final x0 = _percentile(xs, 2) / scale, x1 = _percentile(xs, 98) / scale;
      final y0 = _percentile(ys, 2) / scale, y1 = _percentile(ys, 98) / scale;
      side = ((x1 - x0) > (y1 - y0) ? (x1 - x0) : (y1 - y0)) * margin;
      side = side.clamp(minSide * short, short.toDouble());
      if (side >= fullSide * short) side = short.toDouble();
      cx = (x0 + x1) / 2;
      cy = (y0 + y1) / 2;
    }

    final longSide = w0 > h0 ? w0 : h0;
    if (side >= short && longSide <= squareRatio * short) return image;

    final s = side.toInt();
    final x = (cx - s / 2).clamp(0, w0 - s).toInt();
    final y = (cy - s / 2).clamp(0, h0 - s).toInt();
    return img.copyCrop(image, x: x, y: y, width: s, height: s);
  }

  /// Linear-interpolated percentile, like numpy's default.
  static double _percentile(List<int> values, double q) {
    final sorted = List<int>.from(values)..sort();
    final pos = (sorted.length - 1) * q / 100;
    final lo = pos.floor(), hi = pos.ceil();
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  /// Morphological opening with a 3×3 square (erode then dilate), like
  /// cv2.morphologyEx(MORPH_OPEN): removes isolated green specks.
  static List<bool> _open3x3(List<bool> m, int w, int h) =>
      _morph(_morph(m, w, h, erode: true), w, h, erode: false);

  static List<bool> _morph(List<bool> m, int w, int h, {required bool erode}) {
    final out = List<bool>.filled(m.length, false);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        bool v = erode;
        for (int dy = -1; dy <= 1 && v == erode; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final nx = x + dx, ny = y + dy;
            // Out-of-frame neighbours don't count (OpenCV's default border).
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            if (m[ny * w + nx] != erode) {
              v = !erode;
              break;
            }
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }
}
