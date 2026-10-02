import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/detection/opencv_motion_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/repositories/in_memory_session_repository.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/delivery_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/pitch_geometry.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/view_transform.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/providers.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/tracking/tracking_controller.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/tracking/tracking_state.dart';

import 'support/synthetic_frames.dart';

/// Centres of the stump boxes in the standard guide.
const _standardBatting = (0.5, 0.80);
const _standardBowling = (0.5, 0.32);

void main() {
  group('pitch from tapped stumps', () {
    test('tapping the standard guide boxes gives the standard pitch', () {
      final pitch = PitchGeometry.fromStumps(batting: _standardBatting, bowling: _standardBowling)!;
      const s = PitchGeometry.standard;
      expect(pitch.farY, closeTo(s.farY, 1e-9));
      expect(pitch.nearY, closeTo(s.nearY, 1e-9));
      expect(pitch.nearHalfWidth, closeTo(s.nearHalfWidth, 1e-9));
      expect(pitch.farCenterX, closeTo(0.5, 1e-9));
      expect(pitch.inFlightY, closeTo(s.inFlightY, 1e-9));
    });

    test('the watched zones follow the stumps wherever they are', () {
      // Camera aimed a little to the side and zoomed out: the pitch is off
      // centre and smaller.
      final pitch = PitchGeometry.fromStumps(batting: (0.35, 0.70), bowling: (0.30, 0.34))!;

      // The stump boxes are centred on the taps.
      final (bl, bt, br, bb) = pitch.battingStumps;
      expect((bl + br) / 2, closeTo(0.35, 1e-9));
      expect((bt + bb) / 2, closeTo(0.70, 1e-9));
      final (fl, ft, fr, fb) = pitch.bowlingStumps;
      expect((fl + fr) / 2, closeTo(0.30, 1e-9));
      expect((ft + fb) / 2, closeTo(0.34, 1e-9));

      // Along the pitch is watched; where the standard pitch was is not.
      expect(pitch.isWatched(0.33, 0.5), isTrue);
      expect(pitch.isReleaseZone(0.30, 0.28), isTrue);
      expect(pitch.isReleaseZone(0.5, 0.28), isFalse);
      expect(pitch.scale, lessThan(1));
    });

    test('taps that cannot be a pitch are refused', () {
      // Bowling stumps below the batting stumps.
      expect(PitchGeometry.fromStumps(batting: (0.5, 0.3), bowling: (0.5, 0.8)), isNull);
      // Almost on top of each other.
      expect(PitchGeometry.fromStumps(batting: (0.5, 0.52), bowling: (0.5, 0.5)), isNull);
      // Far off to the side.
      expect(PitchGeometry.fromStumps(batting: (0.9, 0.8), bowling: (0.1, 0.6)), isNull);
    });
  });

  test('a tap maps to the same reference point the guide is drawn at', () {
    final random = Random(2);
    for (final view in const [
      ViewTransform(imageAspect: 9 / 16, screenAspect: 1080 / 2340), // portrait
      ViewTransform(imageAspect: 16 / 9, screenAspect: 2340 / 1080), // landscape
    ]) {
      for (var i = 0; i < 100; i++) {
        final (x, y) = (random.nextDouble(), random.nextDouble());
        final (rx, ry) = view.screenToReference(x, y);
        final (sx, sy) = view.referenceToScreen(rx, ry);
        expect(sx, closeTo(x, 1e-9));
        expect(sy, closeTo(y, 1e-9));
      }
    }
  });

  group('detection follows the tapped pitch', () {
    // A pitch off to the left of the screen, as if the tripod is aimed right of it.
    final offCentre = PitchGeometry.fromStumps(batting: (0.30, 0.80), bowling: (0.30, 0.32))!;

    List<DeliveryEvent> bowlAtX(double x, PitchGeometry geometry) {
      final events = <DeliveryEvent>[];
      final detector = DeliveryDetector(
        ballDetector: OpenCvMotionDetector.forBallType(BallType.tennis),
        pitchLengthMeters: 20.12,
        onEvent: events.add,
      )..geometry = geometry;
      addTearDown(detector.dispose);

      var index = 0;
      void frame(List<(double, double)> balls) => detector.process(LumaFrame(
            bytes: syntheticPixels(balls: balls),
            width: 640,
            height: 360,
            bytesPerRow: 640,
            timestampMicros: (index++ * 1e6 / 120).round(),
          ));
      for (var i = 0; i < 5; i++) {
        frame(const []);
      }
      for (var i = 0; i <= 60; i++) {
        frame([(x, 0.22 + 0.40 * i / 60)]);
      }
      for (var i = 0; i < 20; i++) {
        frame(const []);
      }
      return events;
    }

    test('a ball down the tapped pitch is measured', () {
      expect(bowlAtX(0.30, offCentre).whereType<DeliveryCompleted>(), hasLength(1));
    });

    test('the standard guide would have missed it', () {
      expect(bowlAtX(0.30, PitchGeometry.standard).whereType<DeliveryCompleted>(), isEmpty);
    });
  });

  group('setting up by tapping', () {
    late ProviderContainer container;
    late Session session;
    TrackingController controller() => container.read(trackingControllerProvider(session).notifier);
    TrackingState state() => container.read(trackingControllerProvider(session));

    setUp(() async {
      container = ProviderContainer(
        overrides: [sessionRepositoryProvider.overrideWithValue(InMemorySessionRepository())],
      );
      addTearDown(container.dispose);
      session = await container.read(startSessionProvider)(
        name: 'Nets',
        pitchLengthMeters: 18,
        ballType: BallType.tennis,
      );
      container.listen(trackingControllerProvider(session), (_, _) {});
    });

    test('batting stumps, then bowling stumps, then ready', () {
      expect(state().setupStep, SetupStep.tapBatting);
      expect(state().geometry, PitchGeometry.standard);

      controller().tapStumps(0.4, 0.8);
      expect(state().setupStep, SetupStep.tapBowling);
      expect(state().battingTap, (0.4, 0.8));

      controller().tapStumps(0.42, 0.33);
      expect(state().setupStep, SetupStep.done);
      expect(state().geometry.farCenterX, isNot(0.5));

      // Further taps do nothing until reset.
      final pitch = state().pitch;
      controller().tapStumps(0.1, 0.1);
      expect(state().pitch, same(pitch));

      controller().resetSetup();
      expect(state().setupStep, SetupStep.tapBatting);
      expect(state().geometry, PitchGeometry.standard);
    });

    test('taps that cannot be a pitch start the setup again with a hint', () {
      controller().tapStumps(0.5, 0.3);
      controller().tapStumps(0.5, 0.8); // below the first tap
      expect(state().setupStep, SetupStep.tapBatting);
      expect(state().notice, contains('Tap the batting stumps again'));
    });
  });
}
