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
    container = ProviderContainer(overrides: [sessionRepositoryProvider.overrideWithValue(repository)]);
    addTearDown(container.dispose);
    session = await container.read(startSessionProvider)(
      name: 'Nets',
      pitchLengthMeters: 20.12,
      ballType: BallType.tennis,
    );
    // Keep the auto-dispose controller alive for the test.
    container.listen(trackingControllerProvider(session), (_, _) {});
  });

  Future<void> frames(Iterable<List<(double, double)>> balls) async {
    for (final b in balls) {
      controller().processFrame(
        bytes: syntheticPixels(balls: b),
        width: 640,
        height: 360,
        bytesPerRow: 640,
        rotationDegrees: 0,
        screenAspect: 16 / 9,
      );
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  Future<void> bowl() async {
    // Warm-up: the worker drops frames while OpenCV loads on its first run, so
    // wait until it reports a frame rate, which means it is keeping up.
    for (var i = 0; i < 400 && state().measuredFps == null; i++) {
      await frames([const []]);
    }
    await frames([for (var i = 0; i < 10; i++) const []]);
    // About 0.65 s down the pitch (~110 km/h). Fewer frames put the ball near
    // the 165 km/h limit, where a millisecond of machine timing decides validity.
    await frames([for (var i = 0; i <= 60; i++) [(0.5, 0.22 + 0.40 * i / 60)]]);
    await frames([for (var i = 0; i < 30; i++) const []]);
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

  test('a discarded delivery is not stored', () async {
    await controller().start();
    await bowl();
    await waitFor(() => state().pending != null);

    controller().discardPending();

    expect(session.totalDeliveries, 0);
    expect((await repository.loadSession(session.id))!.deliveries, isEmpty);
  });

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

  test('pausing stops frames from being processed', () async {
    await controller().start();
    controller().pause();
    expect(state().status, TrackingStatus.paused);

    await bowl();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(state().pending, isNull);
  });
}
