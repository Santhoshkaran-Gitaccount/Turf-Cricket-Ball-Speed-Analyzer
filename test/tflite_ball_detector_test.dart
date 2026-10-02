import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/detection/tflite_ball_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/frame.dart';

// No model is bundled yet, so this checks how model output is interpreted.
void main() {
  const layout = FrameLayout(width: 640, height: 360);

  test('keeps confident detections inside the pitch region', () {
    final rows = Float32List.fromList([
      0.5, 0.3, 0.01, 0.01, 0.9, // ball above the bowling end: kept
      0.5, 0.3, 0.01, 0.01, 0.3, // low confidence: dropped
      0.05, 0.9, 0.01, 0.01, 0.95, // off the pitch at the side: dropped
    ]);

    final blobs = TfliteBallDetector.parseDetections(rows, layout);

    expect(blobs, hasLength(1));
    expect(blobs.single.x, closeTo(0.5, 1e-6));
    expect(blobs.single.y, closeTo(0.3, 1e-6));
    // 6.4 × 3.6 px box over 4×4-pixel cells.
    expect(blobs.single.area, 2);
  });

  test('maps boxes through the same screen layout as motion detection', () {
    const flipped = FrameLayout(width: 640, height: 360, rotationDegrees: 180);
    final rows = Float32List.fromList([0.5, 0.7, 0.01, 0.01, 0.9]);

    final blob = TfliteBallDetector.parseDetections(rows, flipped).single;

    expect(blob.y, closeTo(0.3, 1e-6));
  });
}
