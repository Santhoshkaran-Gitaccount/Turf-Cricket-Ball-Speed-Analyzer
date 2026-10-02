import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/frame.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/view_transform.dart';

/// Image to screen with BoxFit.cover, written out independently of the code under test.
(double, double) coverDirect(double u, double v, double imageAspect, double screenAspect) =>
    screenAspect >= imageAspect
        ? (u, 0.5 + (v - 0.5) * screenAspect / imageAspect)
        : (0.5 + (u - 0.5) * imageAspect / screenAspect, v);

void main() {
  const image = 16 / 9;
  const phone = 2340 / 1080;

  test('in landscape the reference view is the screen', () {
    const view = ViewTransform(imageAspect: image, screenAspect: phone);
    expect(view.referenceToScreen(0.3, 0.7), (0.3, 0.7));
    final (x, y) = view.imageToReference(0.3, 0.7);
    final (dx, dy) = coverDirect(0.3, 0.7, image, phone);
    expect(x, closeTo(dx, 1e-12));
    expect(y, closeTo(dy, 1e-12));
  });

  test('in portrait, guides are drawn exactly where the detector looks', () {
    // Whatever image point the detector maps to a reference position, the
    // guide for that reference position must be drawn over that same point.
    const view = ViewTransform(imageAspect: 1 / image, screenAspect: 1 / phone);
    final random = Random(1);
    for (var i = 0; i < 200; i++) {
      final u = random.nextDouble();
      final v = random.nextDouble();
      final (rx, ry) = view.imageToReference(u, v);
      final (sx, sy) = view.referenceToScreen(rx, ry);
      final (dx, dy) = coverDirect(u, v, 1 / image, 1 / phone);
      expect(sx, closeTo(dx, 1e-9));
      expect(sy, closeTo(dy, 1e-9));
    }
  });

  test('in portrait the camera sees less to the sides and more above and below', () {
    const view = ViewTransform(imageAspect: 1 / image);
    // The portrait image's left and right edges are well inside the landscape view.
    expect(view.imageToReference(0, 0.5).$1, greaterThan(0.2));
    expect(view.imageToReference(1, 0.5).$1, lessThan(0.8));
    // Its top and bottom reach beyond it.
    expect(view.imageToReference(0.5, 0).$2, lessThan(0));
    expect(view.imageToReference(0.5, 1).$2, greaterThan(1));
    // The centre stays the centre.
    expect(view.imageToReference(0.5, 0.5), (0.5, 0.5));
  });

  test('frame layout rotates sensor pixels upright for each orientation', () {
    // A pixel near the sensor image's top-left corner.
    const px = 64.0, py = 36.0; // 10% across, 10% down a 640×360 frame
    (double, double) upright(int degrees) {
      final layout = FrameLayout(width: 640, height: 360, rotationDegrees: degrees);
      final (x, y) = layout.toReference(px, py);
      // Undo the portrait mapping so the result is plain upright image coordinates.
      if (degrees % 180 == 0) return (x, y);
      return (0.5 + (x - 0.5) * image, 0.5 + (y - 0.5) / image);
    }

    (double, double) rounded((double, double) p) =>
        ((p.$1 * 100).roundToDouble() / 100, (p.$2 * 100).roundToDouble() / 100);

    expect(rounded(upright(0)), (0.1, 0.1));
    expect(rounded(upright(180)), (0.9, 0.9));
    // Turned a quarter clockwise, the top-left ends up top-right.
    expect(rounded(upright(90)), (0.9, 0.1));
    expect(rounded(upright(270)), (0.1, 0.9));
  });
}
