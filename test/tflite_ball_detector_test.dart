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
      0.02, 0.4, 0.01, 0.01, 0.95, // well off the pitch at the side: dropped
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

  test('reads YOLO output, which lists each field for all boxes in turn', () {
    // Two boxes as [cx..., cy..., w..., h..., score...].
    final values = Float32List.fromList([0.5, 0.1, 0.3, 0.1, 0.01, 0.01, 0.01, 0.01, 0.9, 0.2]);

    final rows = TfliteBallDetector.transposeChannelsFirst(values, 5);

    expect(rows, Float32List.fromList([0.5, 0.3, 0.01, 0.01, 0.9, 0.1, 0.1, 0.01, 0.01, 0.2]));
  });

  test('places boxes from a model that saw only the watched region', () {
    // The model saw a 200 × 200 px window from (220, 40).
    const window = ModelWindow(220, 40, 200, 200);
    final rows = Float32List.fromList([0.5, 0.36, 0.02, 0.02, 0.9]);

    final blob = TfliteBallDetector.parseDetections(rows, layout, window: window).single;

    expect(blob.x, closeTo(320 / 640, 1e-6));
    expect(blob.y, closeTo((40 + 0.36 * 200) / 360, 1e-6));
  });

  test('normalizes boxes given in input pixels', () {
    final rows = Float32List.fromList([160, 96, 3, 3, 0.9]);

    final blob = TfliteBallDetector.parseDetections(rows, layout, inputSize: (320, 320)).single;

    expect(blob.x, closeTo(0.5, 1e-6));
    expect(blob.y, closeTo(0.3, 1e-6));
  });

  test('keeps one box for a ball the model found several times over', () {
    final rows = Float32List.fromList([
      0.5, 0.3, 0.02, 0.02, 0.8,
      0.501, 0.301, 0.02, 0.02, 0.9, // the same ball, more confident: kept
      0.5, 0.5, 0.02, 0.02, 0.7, // a second ball further down: kept
    ]);

    final blobs = TfliteBallDetector.parseDetections(rows, layout);

    expect(blobs, hasLength(2));
    expect(blobs.first.x, closeTo(0.501, 1e-6));
  });
}
