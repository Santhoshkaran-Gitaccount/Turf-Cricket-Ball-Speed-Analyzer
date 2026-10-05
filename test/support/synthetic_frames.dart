import 'dart:math';
import 'dart:typed_data';

import 'package:turf_cricket_ball_speed_analyzer/data/detection/opencv_motion_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/delivery_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/delivery.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/tracking.dart';

const background = 60;

final _noiseRandom = Random(11);

/// A grey frame with square "balls" of [ballLuma] centred at normalized positions.
/// [noise] adds random grain of up to ± that much to every background pixel,
/// like a camera sensor in low light or sunlit grass.
Uint8List syntheticPixels({
  int width = 640,
  int height = 360,
  List<(double, double)> balls = const [],
  int ballLuma = 230,
  int brightness = 0,
  int noise = 0,
  bool flip = false,
}) {
  final ballSize = (4 * width / 640).round();
  final bytes = Uint8List(width * height)..fillRange(0, width * height, background + brightness);
  if (noise > 0) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (bytes[i] + _noiseRandom.nextInt(2 * noise + 1) - noise).clamp(0, 255);
    }
  }
  for (final (x, y) in balls) {
    var px = (x * width).round();
    var py = (y * height).round();
    if (flip) {
      px = width - px;
      py = height - py;
    }
    for (var dy = 0; dy < ballSize; dy++) {
      for (var dx = 0; dx < ballSize; dx++) {
        final row = py - ballSize ~/ 2 + dy;
        final col = px - ballSize ~/ 2 + dx;
        if (row >= 0 && row < height && col >= 0 && col < width) bytes[row * width + col] = ballLuma;
      }
    }
  }
  return bytes;
}

/// Drives a [DeliveryDetector] backed by OpenCV with synthetic frames.
class DetectorHarness {
  DetectorHarness({
    this.fps = 120,
    BallType ballType = BallType.tennis,
    this.ballLuma = 230,
    this.width = 640,
    this.height = 360,
    double pitchLengthMeters = 20.12,
    this.jitterMicros = 0,
  }) {
    detector = DeliveryDetector(
      ballDetector: OpenCvMotionDetector.forBallType(ballType),
      pitchLengthMeters: pitchLengthMeters,
      onEvent: events.add,
    );
  }

  final int fps;
  final int ballLuma;
  final int width;
  final int height;

  /// Random error added to each frame timestamp, like a real camera's timing.
  final int jitterMicros;
  final _random = Random(7);
  final events = <DeliveryEvent>[];
  late final DeliveryDetector detector;
  var _index = 0;

  void frame(Uint8List bytes) {
    detector.process(LumaFrame(
      bytes: bytes,
      width: width,
      height: height,
      bytesPerRow: width,
      timestampMicros: (_index++ * 1e6 / fps).round() +
          (jitterMicros == 0 ? 0 : _random.nextInt(2 * jitterMicros + 1) - jitterMicros),
    ));
  }

  /// Moves a ball in a straight line over [frames] frames. Frames listed in
  /// [hidden] have no ball in them, as if something is in front of it. With
  /// [stopAtEnd] the ball stays where it finished, as if it hit the pads, for
  /// [framesAfter] more frames.
  void ball(
    double fromY,
    double toY,
    int frames, {
    bool flip = false,
    Set<int> hidden = const {},
    Map<int, int> brightness = const {},
    int baseBrightness = 0,
    int noise = 0,
    bool stopAtEnd = false,
    int framesAfter = 0,
  }) {
    for (var i = 0; i <= frames; i++) {
      final y = fromY + (toY - fromY) * i / frames;
      frame(syntheticPixels(
        width: width,
        height: height,
        balls: hidden.contains(i) ? const [] : [(0.5, y)],
        ballLuma: ballLuma,
        brightness: brightness[i] ?? baseBrightness,
        noise: noise,
        flip: flip,
      ));
    }
    for (var i = 0; i < framesAfter; i++) {
      frame(syntheticPixels(
        width: width,
        height: height,
        balls: stopAtEnd ? [(0.5, toY)] : const [],
        ballLuma: ballLuma,
      ));
    }
  }

  void empty(int frames, {int brightness = 0, int noise = 0}) {
    for (var i = 0; i < frames; i++) {
      frame(syntheticPixels(width: width, height: height, brightness: brightness, noise: noise));
    }
  }

  List<DeliveryMeasurement> get deliveries =>
      [for (final e in events) if (e is DeliveryCompleted) e.measurement];

  List<InvalidReason> get invalid => [for (final e in events) if (e is DeliveryInvalid) e.reason];

  void dispose() => detector.dispose();
}
