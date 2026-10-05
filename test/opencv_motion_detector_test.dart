import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/detection/opencv_motion_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/frame.dart';

import 'support/synthetic_frames.dart';

void main() {
  const layout = FrameLayout(width: 640, height: 360);

  test('a fast ball is found where it is now, not also where it was', () {
    final detector = OpenCvMotionDetector();
    addTearDown(detector.dispose);
    var time = 0;
    BallDetection detect(List<(double, double)> balls) => detector.detect(
          LumaFrame(bytes: syntheticPixels(balls: balls), width: 640, height: 360, bytesPerRow: 640, timestampMicros: time += 16667),
          layout,
        );

    detect(const []);
    detect(const []);
    detect(const [(0.5, 0.40)]);
    // Moved further than its own size since the last frame.
    final blobs = detect(const [(0.5, 0.50)]).blobs;

    expect(blobs, hasLength(1), reason: 'the spot the ball just left is not a second ball');
    expect(blobs.single.y, closeTo(0.50, 0.02));
  });
}
