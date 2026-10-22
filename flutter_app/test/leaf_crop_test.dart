import 'package:flutter_app/services/leaf_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _frame(int w, int h, {required int lx, required int ly, required int size}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(90, 70, 50)); // soil
  img.fillRect(im,
      x1: lx, y1: ly, x2: lx + size - 1, y2: ly + size - 1,
      color: img.ColorRgb8(50, 150, 50)); // leaf
  return im;
}

void main() {
  test('wide webcam frame is cropped to a square around the leaf', () {
    final c = LeafCrop.apply(_frame(1280, 720, lx: 800, ly: 200, size: 300));
    expect(c.width, c.height);
    expect(c.width, greaterThanOrEqualTo(300));
    expect(c.width, lessThan(720));
    // the leaf centre (950, 350) is the crop's green centre
    expect(c.getPixel(c.width ~/ 2, c.height ~/ 2).g, 150);
  });

  test('square close-up filled by the leaf is left unchanged', () {
    final im = _frame(256, 256, lx: 10, ly: 10, size: 236);
    expect(identical(LeafCrop.apply(im), im), isTrue);
  });

  test('no green → centre square', () {
    final im = img.Image(width: 1280, height: 720);
    img.fill(im, color: img.ColorRgb8(90, 70, 50));
    final c = LeafCrop.apply(im);
    expect((c.width, c.height), (720, 720));
  });
}
