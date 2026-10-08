/// Runs the Riverpod controller against the real background detection worker,
/// feeding frames at camera pace (the controller timestamps them itself).
///
/// Because timing is real, a heavily loaded machine (other test files running
/// alongside) can delay frames enough to miss a delivery; each test gets a retry.
@Retry(2)
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/repositories/in_memory_session_repository.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/providers.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/tracking/tracking_controller.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/tracking/tracking_state.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/device_motion.dart';

import 'support/synthetic_frames.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late InMemorySessionRepository repository;
  late Session session;

  TrackingController controller() => container.read(trackingControllerProvider(session).notifier);
  TrackingState state() => container.read(trackingControllerProvider(session));

  setUp(() async {
    repository = InMemorySessionRepository();
    container = ProviderContainer(overrides: [
      sessionRepositoryProvider.overrideWithValue(repository),
      deviceMotionProvider.overrideWithValue(DeviceMotion(gyroscope: const Stream.empty())),
    ]);
    addTearDown(container.dispose);
    session = await container.read(startSessionProvider)(
      name: 'Nets',
      pitchLengthMeters: 20.12,
      ballType: BallType.tennis,
    );
    // Keep the auto-dispose controller alive for the test.
    container.listen(trackingControllerProvider(session), (_, _) {});
  });

  Future<void> frames(Iterable<List<(double, double)>> balls, {ChromaLayout? colour}) async {
    for (final b in balls) {
      controller().processFrame(
        // With colour, a ball no brighter than the turf: seen only by its colour.
        bytes: syntheticPixels(balls: b, ballLuma: colour == null ? 230 : background),
        width: 640,
        height: 360,
        bytesPerRow: 640,
        rotationDegrees: 0,
        screenAspect: 16 / 9,
        chroma: colour == null ? null : syntheticChroma(balls: b, layout: colour),
      );
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  Future<void> bowl({ChromaLayout? colour}) async {
    // Warm-up: the worker drops frames while OpenCV loads on its first run, so
    // wait until it reports a frame rate, which means it is keeping up.
    for (var i = 0; i < 400 && state().measuredFps == null; i++) {
      await frames([const []], colour: colour);
    }
    await frames([for (var i = 0; i < 10; i++) const []], colour: colour);
    // About 0.65 s down the pitch (~110 km/h). Fewer frames put the ball near
    // the 165 km/h limit, where a millisecond of machine timing decides validity.
    await frames([for (var i = 0; i <= 60; i++) [(0.5, 0.22 + 0.40 * i / 60)]], colour: colour);
    await frames([for (var i = 0; i < 30; i++) const []], colour: colour);
  }

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a detected delivery waits for save, then is stored and counted', () async {
    final notices = <String>[];
    container.listen(trackingControllerProvider(session), (_, next) {
      if (next.notice case final notice?) notices.add(notice);
    });
    await controller().start();
    expect(state().status, TrackingStatus.tracking);

    await bowl();
    await waitFor(() => state().pending != null);
    expect(state().pending, isNotNull);
    expect(notices, contains('Ball detected'), reason: 'the release is announced');
    expect(session.totalDeliveries, 0, reason: 'not counted until saved');

    controller().savePending();
    expect(state().pending, isNull);
    expect(session.validCount, 1);

    final stored = (await repository.loadSession(session.id))!;
    expect(stored.deliveries.single.speedKmh, session.lastKmh);
  });

  for (final layout in [ChromaLayout.androidInterleaved, ChromaLayout.nv12]) {
    test('colour from the camera reaches the detector (${layout.name})', () async {
      await controller().start();
      await bowl(colour: layout);
      await waitFor(() => state().pending != null);

      expect(state().pending, isNotNull, reason: 'the ball is no brighter than the turf, only its colour shows');
    });
  }

  test('a discarded delivery is not stored', () async {
    await controller().start();
    await bowl();
    await waitFor(() => state().pending != null);

    controller().discardPending();

    expect(session.totalDeliveries, 0);
    expect((await repository.loadSession(session.id))!.deliveries, isEmpty);
  });

  test('a new ball while the card is up saves the old one and shows the new card', () async {
    await controller().start();
    await bowl();
    await waitFor(() => state().pending != null);
    final first = state().pending;
    expect(first, isNotNull, reason: 'the first delivery was not detected');

    // Past the cooldown after a delivery, but well before the 5 s auto-save.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(state().pending, same(first), reason: 'the card is still up');
    await bowl();
    await waitFor(() => state().pending != null && !identical(state().pending, first));

    expect(state().pending, isNotNull);
    expect(state().pending, isNot(same(first)), reason: 'the second ball has its own card');
    expect(session.validCount, 1, reason: 'the first ball was saved when the second came in');
    expect(session.nextBallNumber, 2, reason: 'the new card is ball #2');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a delivery saves itself after 5 seconds', () async {
    await controller().start();
    await bowl();
    await waitFor(() => state().pending != null);
    expect(state().pending, isNotNull, reason: 'the delivery was not detected');

    await Future<void>.delayed(TrackingController.autoSaveDelay + const Duration(milliseconds: 200));

    expect(state().pending, isNull);
    expect(session.validCount, 1);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('ending the session saves the pending delivery and the end time', () async {
    await controller().start();
    await bowl();
    await waitFor(() => state().pending != null);

    await controller().end();

    final stored = (await repository.loadSession(session.id))!;
    expect(stored.endTime, isNotNull);
    expect(stored.deliveries, hasLength(1));
  });

  test('restarting saves the pending delivery, keeps the session and detects again', () async {
    controller()
      ..tapStumps(0.5, 0.80)
      ..tapStumps(0.5, 0.32);
    final pitch = state().pitch;
    expect(pitch, isNotNull);
    await controller().start();
    await bowl();
    await waitFor(() => state().pending != null);
    expect(state().pending, isNotNull);

    await controller().restart();
    expect(state().status, TrackingStatus.paused);
    expect(state().pending, isNull);
    expect(session.validCount, 1, reason: 'the card up at the restart is saved');
    expect(state().pitch, pitch, reason: 'the stumps are not tapped again');

    await controller().start();
    expect(state().status, TrackingStatus.tracking);
    await bowl();
    await waitFor(() => state().pending != null);
    expect(state().pending, isNotNull, reason: 'a fresh worker picks up the next ball');
  });

  test('pausing stops frames from being processed', () async {
    await controller().start();
    controller().pause();
    expect(state().status, TrackingStatus.paused);

    await bowl();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(state().pending, isNull);
  });
}
