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

/// One frame with the ball [x] m right of the pitch centre line, [height] m
/// up and [z] m in front of a camera 1 m high, 2 m behind the batting stumps,
/// matching [PitchGeometry.standard].
void _ballAt(DetectorHarness h, double x, double height, double z) {
  final sx = 0.5 + 0.30 * (x / 1.5) * (2 / z);
  final sy = 0.290 + 1.3207 * (1 - height) / z;
  h.frame(syntheticPixels(balls: [if (sx > 0 && sx < 1 && sy > 0 && sy < 1) (sx, sy)]));
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

    test('the phone\'s frame timing wobble does not change the speed', () {
      int speedWith({required int jitterMicros}) {
        final h = DetectorHarness(jitterMicros: jitterMicros);
        addTearDown(h.dispose);
        h.empty(5);
        h.ball(0.22, 0.93, 60);
        h.empty(5);
        return h.deliveries.single.speedKmh;
      }

      expect(speedWith(jitterMicros: 4000), closeTo(speedWith(jitterMicros: 0), 1));
    });

    test('the speed is the same at 30 and 120 FPS', () {
      int speedAt(int fps) {
        final h = DetectorHarness(fps: fps);
        addTearDown(h.dispose);
        h.empty(5);
        // 0.6 s from release to past the stumps, whatever the frame rate.
        h.ball(0.22, 0.93, (0.6 * fps).round());
        h.empty(5);
        return h.deliveries.single.speedKmh;
      }

      expect(speedAt(30), closeTo(speedAt(120), 1));
    });

    test('estimated release speed is a little above the measured average', () {
      const measured = DeliveryMeasurement(path: [], end: DeliveryEnd.stumps, speedKmh: 100);
      expect(measured.estimatedReleaseKmh, 112);
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

    test('a second ball bowled straight after the first is measured too', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.93, 60);
      // Released half a second after the first reached the stumps.
      h.empty(60);
      h.ball(0.22, 0.93, 70);
      h.empty(5);

      expect(h.invalid, isEmpty);
      expect(h.deliveries, hasLength(2));
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

    // Bowled at 120 km/h from 1.2 m in front of the bowling stumps, bouncing
    // and rising to stump height. In the air near the batsman the ball is high
    // on screen, beside the narrow far part of the pitch outline.
    for (final (name, startX, endX, releaseHeight) in [
      ('down the middle', 0.0, 0.0, 2.0),
      ('going wide on the right', 0.0, 1.0, 2.0),
      ('going wide on the left', 0.0, -1.0, 2.0),
      ('at the right edge of the pitch', 0.0, 1.5, 2.0),
      ('round the wicket to the left edge', 0.8, -1.5, 2.0),
      ('from a tall bowler with a high release', 0.0, 0.0, 2.6),
    ]) {
      test('measures a ball $name', () {
        final h = _harness(fps: 60);
        h.empty(70);
        const pitch = 20.12;
        const v = 120 / 3.6;
        const releaseZ = 2 + pitch - 1.2;
        const bounceZ = 2 + 6.0;
        const endZ = 0.6;
        final frames = ((releaseZ - endZ) / v * 60).round();
        for (var i = 0; i <= frames; i++) {
          final z = releaseZ - v * i / 60;
          final x = startX + (endX - startX) * (releaseZ - z) / (releaseZ - endZ);
          final height = z >= bounceZ
              ? releaseHeight * (z - bounceZ) / (releaseZ - bounceZ)
              : 0.8 * (bounceZ - z) / (bounceZ - endZ);
          _ballAt(h, x, height, z);
        }
        h.empty(30);

        expect(h.events.whereType<TrackDiscarded>(), isEmpty);
        expect(h.invalid, isEmpty);
        expect(h.deliveries.single.speedKmh, closeTo(120, 10));
      });
    }

    // Low frame rates come with dim light; the timing is fitted against frame
    // numbers, so the bounce and the ball rising near the batsman do not
    // skew it however few frames there are.
    for (final fps in [20, 30, 60]) {
      test('measures a bouncing ball at $fps FPS', () {
        final h = _harness(fps: fps);
        h.empty(fps + fps ~/ 6);
        const v = 120 / 3.6;
        const releaseZ = 2 + 20.12 - 1.2;
        const bounceZ = 2 + 6.0;
        const endZ = 0.6;
        final frames = ((releaseZ - endZ) / v * fps).round();
        for (var i = 0; i <= frames; i++) {
          final z = releaseZ - v * i / fps;
          final height = z >= bounceZ ? 2.0 * (z - bounceZ) / (releaseZ - bounceZ) : 0.8 * (bounceZ - z) / (bounceZ - endZ);
          _ballAt(h, 0, height, z);
        }
        h.empty(fps);

        expect(h.deliveries.single.speedKmh, closeTo(120, 13));
      });
    }

    // Walked towards the phone with the ball in hand at waist height, as when
    // fetching it: low down near the camera it shows where a ball released at
    // the far end does, and moves down the screen fast.
    for (final (kmh, startZ) in [(5.0, 21.0), (8.0, 8.0)]) {
      test('a ball carried at $kmh km/h from ${startZ.round()} m is not a delivery', () {
        final h = _harness(fps: 30);
        h.empty(40);
        final v = kmh / 3.6;
        for (var i = 0; startZ - v * i / 30 > 0.8; i++) {
          // Bobbing a little with each step.
          final height = 0.85 + (i % 15 < 8 ? 0.03 : -0.03);
          _ballAt(h, 0.3, height, startZ - v * i / 30);
        }
        h.empty(30);

        expect(h.events.whereType<ReleaseDetected>(), isEmpty);
        expect(h.events.whereType<TrackDiscarded>(), isEmpty);
        expect(h.invalid, isEmpty);
        expect(h.deliveries, isEmpty);
      });
    }

    // Thrown back from the batting crease towards the bowler in an arc that
    // lands a few metres down the pitch and bounces on: seen from behind the
    // batting stumps it drops down the screen past the bowler's end, like a
    // ball just bowled.
    for (final (landing, flight) in [(4.0, 0.6), (4.0, 1.5), (6.0, 1.0)]) {
      test('a ball thrown back landing $landing m down the pitch is not a delivery', () {
        final h = _harness(fps: 60);
        h.empty(70);
        const startZ = 3.0;
        const startHeight = 1.5;
        final landZ = 2 + landing;
        final vz = (landZ - startZ) / flight;
        final vy = (4.9 * flight * flight - startHeight) / flight;
        for (var i = 0; i <= (flight * 60).round() + 40; i++) {
          final t = i / 60;
          if (t <= flight) {
            _ballAt(h, 0, startHeight + vy * t - 4.9 * t * t, startZ + vz * t);
          } else {
            final tb = t - flight;
            final up = vy.abs() * 0.4;
            _ballAt(h, 0, max(0.0, up * tb - 4.9 * tb * tb), landZ + vz * 0.6 * tb);
          }
        }
        h.empty(30);

        expect(h.events.whereType<ReleaseDetected>(), isEmpty);
        expect(h.events.whereType<TrackDiscarded>(), isEmpty);
        expect(h.invalid, isEmpty);
        expect(h.deliveries, isEmpty);
      });
    }
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

    test('keeps tracking a ball covered for a fifth of a second down the pitch', () {
      final h = _harness(fps: 60);
      h.empty(5);
      // 0.65 s flight, hidden for 12 frames (0.2 s) before the batsman's end.
      h.ball(0.22, 0.62, 39, hidden: {for (var i = 14; i < 26; i++) i});
      h.empty(20);

      expect(h.invalid, isEmpty);
      expect(h.deliveries, hasLength(1));
    });
  });

  group('invalid deliveries', () {
    test('camera loses tracking when the ball vanishes mid-pitch', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.46, 40);
      // Longer than a ball is waited for down the pitch (0.25 s).
      h.empty(40);

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

    test('an impossibly fast crossing is not counted as a delivery at all', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 20); // 0.17 s
      h.empty(20);

      expect(h.invalid, isEmpty);
      expect(h.deliveries, isEmpty);
      expect(h.events.whereType<TrackDiscarded>().single.tooFast, isTrue);
    });

    test('a slow delivery well above 3 km/h is still counted', () {
      final h = _harness(fps: 30);
      h.empty(5);
      h.ball(0.22, 0.62, 100); // 3.3 s, about 22 km/h on 20.12 m
      h.empty(20);

      expect(h.invalid, isEmpty);
      expect(h.deliveries, hasLength(1));
    });
  });

  group('colour', () {
    // A red leather ball as bright as the turf: no brightness change to see.
    void bowlRedBall(DetectorHarness h, {required bool withColour, ChromaLayout layout = ChromaLayout.planar}) {
      h.empty(5);
      for (var i = 0; i <= 60; i++) {
        final balls = [(0.5, 0.22 + 0.40 * i / 60)];
        h.frame(
          syntheticPixels(balls: balls, ballLuma: background),
          chroma: withColour ? syntheticChroma(balls: balls, layout: layout) : null,
        );
      }
      for (var i = 0; i < 20; i++) {
        h.frame(syntheticPixels(), chroma: withColour ? syntheticChroma(layout: layout) : null);
      }
    }

    for (final layout in ChromaLayout.values) {
      test('a ball as bright as the turf is found by its colour (${layout.name})', () {
        final h = _harness(fps: 120, ballType: BallType.leather);
        bowlRedBall(h, withColour: true, layout: layout);

        expect(h.invalid, isEmpty);
        expect(h.deliveries, hasLength(1));
        expect(h.deliveries.single.speedKmh, closeTo(145, 6));
      });
    }

    test('without colour the same ball is not seen at all', () {
      final h = _harness(fps: 120, ballType: BallType.leather);
      bowlRedBall(h, withColour: false);

      expect(h.events.whereType<ReleaseDetected>(), isEmpty);
    });

    test('a shadow passing changes brightness, not colour, and is still not a ball', () {
      final h = _harness(fps: 60);
      h.empty(5);
      // Something large and dark crossing the pitch, colour unchanged.
      for (var i = 0; i <= 30; i++) {
        h.frame(syntheticPixels(people: [(0.2 + 0.6 * i / 30, 0.5, 0.15, 0.3)]), chroma: syntheticChroma());
      }
      h.empty(20);

      expect(h.events.whereType<ReleaseDetected>(), isEmpty);
      expect(h.deliveries, isEmpty);
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

    test('a tennis ball is still seen in dim light', () {
      // Indoors or at dusk the turf is darker and so is the ball.
      final h = _harness(ballLuma: background - 30 + 24);
      h.empty(5, brightness: -30);
      h.ball(0.22, 0.62, 60, baseBrightness: -30);
      h.empty(20, brightness: -30);

      expect(h.deliveries, hasLength(1));
    });

    test('a ball is still seen through sensor grain or shimmering grass', () {
      final h = _harness();
      h.empty(5, noise: 20);
      h.ball(0.22, 0.62, 60, noise: 20);
      h.empty(20, noise: 20);

      expect(h.deliveries, hasLength(1));
      expect(h.events.whereType<CameraSteadinessChanged>(), isEmpty, reason: 'grain is not camera movement');
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

    test('someone walking down the pitch to the phone is not a ball', () {
      final h = _harness();
      h.empty(5);
      // A person coming towards the camera, with a ball-sized bright spot (a
      // hand, a shoe) moving along with them at the side.
      for (var i = 0; i <= 60; i++) {
        final t = i / 60;
        final y = 0.30 + 0.45 * t;
        // Grows as they come closer, as everything does in perspective.
        final w = 0.04 + 0.08 * t;
        h.frame(syntheticPixels(people: [(0.5, y, w, w * 2.5)], balls: [(0.5 + w / 2 + 0.025, y + 0.02)]));
      }
      h.empty(20);

      expect(h.deliveries, isEmpty);
      expect(h.invalid, isEmpty);
    });

    test('a ball bowled with the bowler still in view is measured', () {
      final h = _harness();
      h.empty(5);
      // The bowler stays at the far end, following through, while the ball flies.
      for (var i = 0; i <= 60; i++) {
        h.frame(syntheticPixels(people: [(0.45 + 0.02 * (i % 6) / 6, 0.16, 0.04, 0.10)], balls: [(0.5, 0.22 + 0.40 * i / 60)]));
      }
      h.empty(20);

      expect(h.deliveries, hasLength(1));
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

    // Found on a real phone: tilting the phone slowly showed "ball in flight".
    // Only edges change, far less than the whole view, and specks in the
    // scene slide down the screen just like a ball. The gyroscope sees the turn.
    for (final (name, dx, dy) in [('tilted up', 0.0, 1.0), ('tilted slowly', 0.0, 0.5), ('moved diagonally', 0.7, 0.7)]) {
      test('a camera $name is not a ball in flight', () {
        final h = _harness();
        for (var i = 0; i < 20; i++) {
          h.frame(texturedPixels());
        }
        for (var i = 0; i <= 120; i++) {
          h.frame(texturedPixels(shiftX: dx * i, shiftY: dy * i), deviceMoving: true);
        }
        for (var i = 0; i < 20; i++) {
          h.frame(texturedPixels(shiftX: dx * 120, shiftY: dy * 120));
        }

        expect(h.events.whereType<ReleaseDetected>(), isEmpty);
        expect(h.deliveries, isEmpty);
        expect(h.invalid, isEmpty);
        expect(h.events.whereType<CameraSteadinessChanged>().map((e) => e.steady).firstOrNull, isFalse);
      });
    }

    test('a ball bowled past markings and specks on a fixed camera is measured', () {
      final h = _harness();
      for (var i = 0; i < 20; i++) {
        h.frame(texturedPixels());
      }
      for (var i = 0; i <= 60; i++) {
        final pixels = texturedPixels();
        final y = 0.22 + 0.40 * i / 60;
        final ball = syntheticPixels(balls: [(0.5, y)]);
        for (var p = 0; p < pixels.length; p++) {
          if (ball[p] != background) pixels[p] = ball[p];
        }
        h.frame(pixels);
      }
      for (var i = 0; i < 20; i++) {
        h.frame(texturedPixels());
      }

      expect(h.deliveries, hasLength(1));
      expect(h.events.whereType<CameraSteadinessChanged>(), isEmpty);
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

    test('a speed above 165 km/h is not counted, e.g. a pitch length set too long', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.62, 50); // 20.12 m in 0.42 s = 174 km/h
      h.empty(20);

      expect(h.deliveries, isEmpty);
      expect(h.invalid, isEmpty);
      expect(h.events.whereType<TrackDiscarded>().single.tooFast, isTrue);
    });

    test('one ball rolling on after an invalid delivery is not counted again', () {
      final h = _harness();
      h.empty(5);
      h.ball(0.22, 0.46, 40); // lost mid-pitch: invalid
      // Within a second the same ball comes down the pitch again, as it rolls on.
      h.empty(30);
      h.ball(0.22, 0.62, 60);
      h.empty(20);

      expect(h.invalid, [InvalidReason.trackingLost], reason: 'one ball, one record');
      expect(h.deliveries, isEmpty);
    });
  });
}
