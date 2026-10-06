import 'dart:math';
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;
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
  List<(double, double, double, double)> people = const [],
}) {
  final ballSize = (4 * width / 640).round();
  final bytes = Uint8List(width * height)..fillRange(0, width * height, background + brightness);
  // A person: a large patterned patch (centre x, centre y, width, height),
  // like clothing, so all of it changes as it moves, not just its outline.
  for (final (cx, cy, w, h) in people) {
    final left = ((cx - w / 2) * width).round();
    final top = ((cy - h / 2) * height).round();
    for (var row = max(0, top); row < min(height, top + (h * height).round()); row++) {
      for (var col = max(0, left); col < min(width, left + (w * width).round()); col++) {
        bytes[row * width + col] = ((row ~/ 6) + (col ~/ 6)).isEven ? 200 : 110;
      }
    }
  }
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

/// A fixed scene with detail in it (markings, kit bags, specks on the turf),
/// seen from a camera whose view has moved [shiftX], [shiftY] pixels: the
/// scene appears that far the other way, as when the phone is tilted or
/// panned. Fractional shifts blend neighbouring pixels, as a lens does.
Uint8List texturedPixels({int width = 640, int height = 360, double shiftX = 0, double shiftY = 0}) {
  final scene = _texturedScene(width, height);
  if (shiftX == 0 && shiftY == 0) return Uint8List.fromList(scene);
  final src = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, scene);
  final translation = cv.Mat.fromList(2, 3, cv.MatType.CV_64FC1, [1.0, 0.0, shiftX, 0.0, 1.0, shiftY]);
  final dst = cv.warpAffine(src, translation, (width, height), borderMode: cv.BORDER_REFLECT);
  final bytes = Uint8List.fromList(dst.data);
  for (final mat in [src, translation, dst]) {
    mat.dispose();
  }
  return bytes;
}

final _scenes = <(int, int), Uint8List>{};

Uint8List _texturedScene(int width, int height) => _scenes.putIfAbsent((width, height), () {
      final random = Random(21);
      (int, int, int, int, int) patch(int maxW, int maxH, int minLuma, int lumaRange) => (
            random.nextInt(width),
            random.nextInt(height),
            2 + random.nextInt(maxW),
            2 + random.nextInt(maxH),
            minLuma + random.nextInt(lumaRange),
          );
      final patches = [
        // Faint blotches in the turf: too faint to count as motion on their own.
        for (var i = 0; i < 400; i++) patch(40, 40, background - 12, 24),
        // A few specks and markings that stand out.
        for (var i = 0; i < 24; i++) patch(i.isEven ? 4 : 30, 4, 140, 110),
      ];
      final bytes = Uint8List(width * height)..fillRange(0, width * height, background);
      for (final (left, top, w, h, luma) in patches) {
        for (var row = top; row < min(height, top + h); row++) {
          for (var col = left; col < min(width, left + w); col++) {
            bytes[row * width + col] = luma;
          }
        }
      }
      return bytes;
    });

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

  /// [deviceMoving] is what the phone's gyroscope would say.
  void frame(Uint8List bytes, {bool deviceMoving = false}) {
    detector.process(LumaFrame(
      bytes: bytes,
      width: width,
      height: height,
      bytesPerRow: width,
      timestampMicros: (_index++ * 1e6 / fps).round() +
          (jitterMicros == 0 ? 0 : _random.nextInt(2 * jitterMicros + 1) - jitterMicros),
      deviceMoving: deviceMoving,
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
