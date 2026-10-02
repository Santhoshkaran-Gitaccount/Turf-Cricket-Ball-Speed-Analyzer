import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/detection/detection_worker.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/delivery_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/tracking.dart';

import 'support/synthetic_frames.dart';

/// Section 14 performance requirements. Timings run on the test machine, so
/// they show the pipeline has headroom; phones must still be checked on device.
void main() {
  group('tracking performance', () {
    test('processes a 720p frame well within the 120 FPS budget', () {
      final h = DetectorHarness(width: 1280, height: 720);
      addTearDown(h.dispose);
      final frames = [
        for (var i = 0; i < 120; i++)
          syntheticPixels(width: 1280, height: 720, balls: [(0.5, 0.22 + 0.4 * i / 120)]),
      ];

      // Warm up native code and caches before timing.
      for (final f in frames.take(10)) {
        h.frame(f);
      }
      final watch = Stopwatch()..start();
      for (final f in frames.skip(10)) {
        h.frame(f);
      }
      final perFrameMs = watch.elapsedMicroseconds / 1000 / (frames.length - 10);

      printOnFailure('Average per-frame processing: ${perFrameMs.toStringAsFixed(2)} ms');
      expect(perFrameMs, lessThan(1000 / 120));
    });
  });

  group('accuracy target: within ±5 km/h', () {
    const pitch = 20.12;

    for (final fps in [60, 120]) {
      for (final kmh in [60, 90, 120, 150]) {
        test('$kmh km/h at $fps FPS', () {
          // Frames of flight for this speed, and the speed they really give.
          final frames = (pitch / (kmh / 3.6) * fps).round();
          final trueKmh = pitch / (frames / fps) * 3.6;

          final h = DetectorHarness(fps: fps, jitterMicros: 1500);
          addTearDown(h.dispose);
          h.empty(5);
          // The ball stops at the batsman end, as when it hits the pads.
          h.ball(0.22, 0.62, frames, stopAtEnd: true, framesAfter: 30);

          final measured = h.deliveries.single.speedKmh;
          expect((measured - trueKmh).abs(), lessThanOrEqualTo(5),
              reason: 'measured $measured km/h, true ${trueKmh.toStringAsFixed(1)} km/h');
        });
      }
    }

    test('ball lost behind the batsman at 120 FPS', () {
      const fps = 120;
      for (final kmh in [80, 120, 150]) {
        final frames = (pitch / (kmh / 3.6) * fps).round();
        final trueKmh = pitch / (frames / fps) * 3.6;

        final h = DetectorHarness(fps: fps);
        addTearDown(h.dispose);
        h.empty(5);
        h.ball(0.22, 0.62, frames, framesAfter: 30);

        final measured = h.deliveries.single.speedKmh;
        expect((measured - trueKmh).abs(), lessThanOrEqualTo(5),
            reason: '$kmh km/h: measured $measured, true ${trueKmh.toStringAsFixed(1)}');
      }
    });
  });

  group('detection time', () {
    test('speed result arrives within 2 seconds of delivery completion', () async {
      final messages = StreamController<DetectorMessage>.broadcast();
      final worker = await DetectionWorker.spawn(
        const DetectorConfig(pitchLengthMeters: 20.12, ballType: BallType.tennis),
        messages.add,
      );
      addTearDown(() async {
        await worker.dispose();
        await messages.close();
      });

      const fps = 120;
      var index = 0;
      final completed = messages.stream
          .where((m) => m is DetectorEvent && m.event is DeliveryCompleted)
          .first;

      // Sends one frame and waits for it to be processed, like a camera
      // delivering frames no faster than they are handled.
      Future<void> send(List<(double, double)> balls) async {
        final processed = messages.stream.firstWhere((m) => m is FrameProcessed);
        worker.process(
          LumaFrame(
            bytes: syntheticPixels(balls: balls),
            width: 640,
            height: 360,
            bytesPerRow: 640,
            timestampMicros: (index++ * 1e6 / fps).round(),
          ),
          rotationDegrees: 0,
          screenAspect: null,
        );
        await processed;
      }

      for (var i = 0; i < 5; i++) {
        await send(const []);
      }
      for (var i = 0; i <= 60; i++) {
        await send([(0.5, 0.22 + 0.40 * i / 60)]);
      }

      // The ball has reached the batsman and disappeared: the delivery is complete.
      final sinceCompletion = Stopwatch()..start();
      var done = false;
      unawaited(completed.then((_) => done = true));
      while (!done && sinceCompletion.elapsed < const Duration(seconds: 3)) {
        await send(const []);
        await Future<void>.delayed(const Duration(milliseconds: 1000 ~/ fps));
      }

      expect(done, isTrue);
      printOnFailure('Result after ${sinceCompletion.elapsedMilliseconds} ms');
      expect(sinceCompletion.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('drops frames instead of queueing when the worker is busy', () async {
      final worker = await DetectionWorker.spawn(
        const DetectorConfig(pitchLengthMeters: 20.12, ballType: BallType.tennis),
        (_) {},
      );
      addTearDown(worker.dispose);

      // A burst far faster than any camera, without waiting for results.
      for (var i = 0; i < 50; i++) {
        worker.process(
          LumaFrame(
            bytes: syntheticPixels(width: 1280, height: 720),
            width: 1280,
            height: 720,
            bytesPerRow: 1280,
            timestampMicros: i * 8333,
          ),
          rotationDegrees: 0,
          screenAspect: null,
        );
      }

      // At most two frames wait at a time, so results never lag behind the camera.
      expect(worker.droppedFrames, greaterThanOrEqualTo(48));
    });
  });

  test('speed formula keeps 132 km/h for the spec example', () {
    expect(DeliveryMeasurement.calculateSpeedKmh(20.12, const Duration(milliseconds: 550)), 132);
  });
}
