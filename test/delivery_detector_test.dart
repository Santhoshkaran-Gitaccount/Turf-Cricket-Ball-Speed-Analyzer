import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/core/formatters.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/delivery_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/delivery.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/tracking.dart';

import 'support/synthetic_frames.dart';

// Each test builds its own harness; OpenCV memory is released when it ends.
DetectorHarness _harness({int fps = 120, BallType ballType = BallType.tennis, int ballLuma = 230}) {
  final h = DetectorHarness(fps: fps, ballType: ballType, ballLuma: ballLuma);
  addTearDown(h.dispose);
  return h;
}

void main() {
  group('speed calculation', () {
    test('matches the spec example: 20.12 m in 0.55 s is 132 km/h', () {
      expect(DeliveryMeasurement.calculateSpeedKmh(20.12, const Duration(milliseconds: 550)), 132);
    });

    test('rounds to the nearest whole number', () {
      // 20 m in 0.5 s = 144.0; in 0.51 s = 141.18; in 0.505 s = 142.57.
      expect(DeliveryMeasurement.calculateSpeedKmh(20, const Duration(milliseconds: 500)), 144);
      expect(DeliveryMeasurement.calculateSpeedKmh(20, const Duration(milliseconds: 510)), 141);
      expect(DeliveryMeasurement.calculateSpeedKmh(20, const Duration(microseconds: 505000)), 143);
    });

    test('session stats show whole km/h', () {
      expect(formatSpeed(131.6), '132 km/h');
      expect(formatSpeed(null), '–');
    });
  });

  group('delivery detection', () {
    test('detects release, travel and completion for a ball bowled down the pitch', () {
      final h = _harness();
      h.empty(5);
      // 0.5 s from release to the batsman area.
      h.ball(0.22, 0.62, 60);
      h.empty(20);

      expect(h.events.whereType<ReleaseDetected>(), hasLength(1));
      expect(h.events.whereType<BallTravelling>().length, greaterThan(30));
      expect(h.deliveries, hasLength(1));

      final delivery = h.deliveries.single;
      expect(delivery.end, DeliveryEnd.batsmanArea);
      expect(delivery.travelTime.inMilliseconds, closeTo(500, 20));
      // 20.12 m in 0.5 s.
      expect(delivery.speedKmh, closeTo(145, 6));
    });

    test('completes at the stumps when the ball is tracked all the way', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.93, 60);
      h.empty(5);

      expect(h.deliveries.single.end, DeliveryEnd.stumps);
    });

    test('works when the sensor image is upside down', () {
      final h = _harness()..detector.rotationDegrees = 180;
      h.empty(5);
      h.ball(0.22, 0.62, 60, flip: true);
      h.empty(20);

      expect(h.deliveries, hasLength(1));
    });

    test('works with the phone in portrait', () {
      final h = _harness()..detector.rotationDegrees = 90;
      h.empty(5);
      // The same flight as the landscape test, seen by a phone turned upright:
      // in the sensor image the ball now moves across the middle row, and the
      // flight covers less of the image since portrait sees more above and below.
      const imageAspect = 640 / 360;
      for (var i = 0; i <= 60; i++) {
        final referenceY = 0.22 + 0.40 * i / 60;
        final uprightY = 0.5 + (referenceY - 0.5) / imageAspect;
        h.frame(syntheticPixels(balls: [(uprightY, 0.5)]));
      }
      h.empty(20);

      expect(h.deliveries, hasLength(1));
      expect(h.deliveries.single.speedKmh, closeTo(145, 6));
    });

    test('ignores a static scene and whole-frame brightness changes', () {
      final h = _harness();
      h.empty(30);
      h.empty(30, brightness: 60);
      h.empty(30);

      expect(h.events.where((e) => e is! CameraSteadinessChanged), isEmpty);
    });

    test('ignores movement that never leaves the bowler end', () {
      final h = _harness();
      h.empty(5);
      // Bowler's arm coming down after release: short and stays above the pitch.
      h.ball(0.15, 0.30, 12);
      h.empty(20);

      expect(h.events, isEmpty);
    });

    test('ignores a ball moving away from the batsman', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.62, 0.22, 60);
      h.empty(20);

      expect(h.deliveries, isEmpty);
      expect(h.events.whereType<ReleaseDetected>(), isEmpty);
    });

    test('counts consecutive deliveries separately', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 60);
      h.empty(250); // cooldown between deliveries
      h.ball(0.22, 0.62, 80);
      h.empty(20);

      expect(h.deliveries, hasLength(2));
      expect(h.deliveries[1].speedKmh, lessThan(h.deliveries[0].speedKmh));
    });
  });

  group('occlusion', () {
    test('keeps tracking through a few hidden frames at 60 FPS', () {
      final h = _harness(fps: 60);
      h.empty(5);
      // 0.5 s flight with the ball hidden for 4 frames mid-pitch.
      h.ball(0.22, 0.62, 30, hidden: {16, 17, 18, 19});
      h.empty(20);

      expect(h.invalid, isEmpty);
      expect(h.deliveries, hasLength(1));
      expect(h.deliveries.single.travelTime.inMilliseconds, closeTo(500, 40));
    });
  });

  group('invalid deliveries', () {
    test('camera loses tracking when the ball vanishes mid-pitch', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.46, 40);
      h.empty(20);

      expect(h.events.whereType<ReleaseDetected>(), hasLength(1));
      expect(h.invalid, [InvalidReason.trackingLost]);
      expect(h.deliveries, isEmpty);
    });

    test('camera loses tracking when the camera moves during the delivery', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 60, brightness: {45: 60});
      h.empty(20);

      expect(h.invalid, [InvalidReason.trackingLost]);
      expect(h.deliveries, isEmpty);
    });

    test('pitch not fully visible when the view goes dark during the delivery', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 60, brightness: {45: -50});
      h.empty(20);

      expect(h.invalid, [InvalidReason.pitchNotVisible]);
    });

    test('ball not detected when it is seen in too few frames', () {
      final h = _harness();
      h.empty(5);
      // Slow ball, visible in only one frame in five after the first few.
      h.ball(0.22, 0.62, 120, hidden: {for (var i = 10; i <= 120; i++) if (i % 5 != 0) i});
      h.empty(20);

      expect(h.invalid, [InvalidReason.ballNotDetected]);
    });

    test('multiple balls visible when two come down the pitch together', () {
      final h = _harness();
      h.empty(5);
      for (var i = 0; i <= 70; i++) {
        final a = 0.22 + 0.40 * i / 60;
        final b = 0.22 + 0.40 * (i - 10) / 60;
        h.frame(syntheticPixels(balls: [
          if (i <= 60) (0.50, a),
          if (i >= 10) (0.45, b),
        ]));
      }
      h.empty(20);

      expect(h.invalid, contains(InvalidReason.multipleBalls));
      expect(h.deliveries, isEmpty);
    });

    test('duration out of range for an impossibly fast delivery', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 20); // 0.17 s
      h.empty(20);

      expect(h.invalid, [InvalidReason.durationOutOfRange]);
    });

    test('duration out of range for a delivery that takes too long', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 400); // 3.3 s
      h.empty(20);

      expect(h.invalid, [InvalidReason.durationOutOfRange]);
    });
  });

  group('ball type', () {
    // A red leather ball is only a little brighter than the turf.
    const lowContrast = background + 24;

    test('leather ball setting picks up a low-contrast ball', () {
      final h = _harness(ballType: BallType.leather, ballLuma: lowContrast);
      h.empty(5);
      h.ball(0.22, 0.62, 60);
      h.empty(20);

      expect(h.deliveries, hasLength(1));
    });

    test('tennis ball setting ignores the same faint movement', () {
      final h = _harness(ballType: BallType.tennis, ballLuma: lowContrast);
      h.empty(5);
      h.ball(0.22, 0.62, 60);
      h.empty(20);

      expect(h.events, isEmpty);
    });
  });

  // Found on a real phone: a handheld camera in a room reported 18 "deliveries".
  group('false detections', () {
    test('random movement in view is never a delivery', () {
      final h = _harness();
      final random = Random(3);
      (double, double) somewhere() => (0.42 + random.nextDouble() * 0.16, 0.15 + random.nextDouble() * 0.75);
      h.empty(5);
      for (var i = 0; i < 400; i++) {
        h.frame(syntheticPixels(balls: [somewhere(), somewhere()]));
      }
      h.empty(20);

      expect(h.deliveries, isEmpty);
      expect(h.invalid, isEmpty, reason: 'noise must not be recorded as invalid deliveries either');
    });

    test('a waving hand is not a ball', () {
      final h = _harness();
      h.empty(5);
      // Sweeps across while bobbing up and down, like a hand in front of the lens.
      for (var i = 0; i <= 80; i++) {
        final t = i / 80;
        h.frame(syntheticPixels(balls: [(0.44 + 0.12 * t, 0.25 + 0.3 * t + 0.08 * sin(t * 4 * pi))]));
      }
      h.empty(20);

      expect(h.deliveries, isEmpty);
      expect(h.invalid, isEmpty);
    });

    test('nothing is looked for until the camera has been still for a second', () {
      final h = _harness();
      h.empty(5);
      h.empty(1, brightness: 60); // the camera jolts
      h.ball(0.22, 0.62, 60);
      h.empty(20);
      expect(h.deliveries, isEmpty);

      h.empty(150); // steady again
      h.ball(0.22, 0.62, 60);
      h.empty(20);
      expect(h.deliveries, hasLength(1));
      // One jolt (or an exposure jump) on a fixed tripod is not reported as the camera moving.
      expect(h.events.whereType<CameraSteadinessChanged>(), isEmpty);
    });

    test('reports the camera moving only while the movement keeps going', () {
      final h = _harness();
      h.empty(5);
      // Handheld or a wobbling tripod: the whole view changes frame after frame.
      for (var i = 0; i < 60; i++) {
        h.empty(1, brightness: i.isEven ? 60 : 0);
      }
      expect(h.events.whereType<CameraSteadinessChanged>().map((e) => e.steady), [false]);

      h.empty(150);
      expect(h.events.whereType<CameraSteadinessChanged>().map((e) => e.steady), [false, true]);
    });

    test('a busy scene on a fixed camera is not reported as the camera moving', () {
      final h = _harness();
      final random = Random(5);
      h.empty(5);
      // Players, shadows and grass: many small moving patches in every frame.
      for (var i = 0; i < 240; i++) {
        h.frame(syntheticPixels(balls: [
          for (var b = 0; b < 10; b++) (0.42 + random.nextDouble() * 0.16, 0.15 + random.nextDouble() * 0.75),
        ]));
      }
      h.empty(20);

      expect(h.events.whereType<CameraSteadinessChanged>(), isEmpty);
      expect(h.deliveries, isEmpty);
    });

    test('measures a delivery at 30 FPS', () {
      final h = _harness(fps: 30);
      h.empty(5);
      h.ball(0.22, 0.62, 15); // 0.5 s
      h.empty(20);

      expect(h.deliveries, hasLength(1));
      expect(h.deliveries.single.speedKmh, closeTo(145, 15));
    });

    test('a speed above 165 km/h is out of range', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 50); // 20.12 m in 0.42 s = 174 km/h
      h.empty(20);

      expect(h.deliveries, isEmpty);
      expect(h.invalid, [InvalidReason.durationOutOfRange]);
    });
  });
}
