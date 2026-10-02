import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../domain/detection/ball_detector.dart';
import '../../domain/detection/delivery_detector.dart';
import '../../domain/detection/pitch_geometry.dart';
import 'detection_messages.dart';
import 'opencv_motion_detector.dart';
import 'tflite_ball_detector.dart';

/// Runs delivery detection on a background isolate, so frame processing at
/// 30–120 FPS never competes with the UI for time.
class DetectionWorker {
  DetectionWorker._(this._isolate, this._toWorker, this._fromWorker, this._stopped);

  /// Frames sent but not yet processed. Past this, new frames are dropped
  /// rather than queued, so results never fall behind the camera.
  static const _maxFramesInFlight = 2;

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final Completer<void> _stopped;
  int _inFlight = 0;

  /// Frames skipped because the worker was still busy.
  int droppedFrames = 0;

  static Future<DetectionWorker> spawn(
    DetectorConfig config,
    void Function(DetectorMessage message) onMessage,
  ) async {
    final fromWorker = ReceivePort();
    final ready = Completer<SendPort>();
    final stopped = Completer<void>();
    DetectionWorker? worker;

    fromWorker.listen((message) {
      switch (message) {
        case SendPort port:
          ready.complete(port);
        case _Stopped():
          if (!stopped.isCompleted) stopped.complete();
        case FrameProcessed():
          worker?._inFlight--;
          onMessage(message);
        case DetectorMessage():
          onMessage(message);
        case [final error, final stack]:
          // Uncaught error in the worker isolate.
          debugPrint('Detection worker error: $error\n$stack');
      }
    });

    final isolate = await Isolate.spawn(
      _run,
      (fromWorker.sendPort, config),
      onError: fromWorker.sendPort,
      debugName: 'delivery-detection',
    );
    return worker = DetectionWorker._(isolate, await ready.future, fromWorker, stopped);
  }

  /// Sends a frame for processing. Returns false if it was dropped.
  bool process(LumaFrame frame, {required int rotationDegrees, required double? screenAspect}) {
    if (_inFlight >= _maxFramesInFlight) {
      droppedFrames++;
      return false;
    }
    _inFlight++;
    _toWorker.send(_Frame(
      TransferableTypedData.fromList([frame.bytes]),
      frame.width,
      frame.height,
      frame.bytesPerRow,
      frame.timestampMicros,
      rotationDegrees,
      screenAspect,
    ));
    return true;
  }

  /// Forgets any delivery in progress, e.g. when tracking is paused.
  void reset() => _toWorker.send(const _Reset());

  /// Watches a different part of the view, after the user taps the stumps.
  void setGeometry(PitchGeometry geometry) => _toWorker.send(_SetGeometry(geometry));

  Future<void> dispose() async {
    _toWorker.send(const _Stop());
    // Give the worker a moment to free native memory before forcing it down.
    await _stopped.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    _isolate.kill(priority: Isolate.immediate);
    _fromWorker.close();
  }
}

class _Frame {
  const _Frame(
    this.bytes,
    this.width,
    this.height,
    this.bytesPerRow,
    this.timestampMicros,
    this.rotationDegrees,
    this.screenAspect,
  );

  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final int timestampMicros;
  final int rotationDegrees;
  final double? screenAspect;
}

class _Reset {
  const _Reset();
}

class _SetGeometry {
  const _SetGeometry(this.geometry);
  final PitchGeometry geometry;
}

class _Stop {
  const _Stop();
}

class _Stopped {
  const _Stopped();
}

void _run((SendPort, DetectorConfig) args) {
  final (toMain, config) = args;
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);

  final (ballDetector, started) = _createBallDetector(config);
  toMain.send(started);

  final detector = DeliveryDetector(
    ballDetector: ballDetector,
    pitchLengthMeters: config.pitchLengthMeters,
    onEvent: (event) => toMain.send(DetectorEvent(event)),
    onFpsMeasured: (fps) => toMain.send(FpsMeasured(fps)),
    onPitchVisibilityChanged: (visible) => toMain.send(PitchVisibilityChanged(visible)),
  )..geometry = config.geometry;
  final clock = Stopwatch()..start();

  inbox.listen((message) {
    switch (message) {
      case _Frame():
        final start = clock.elapsedMicroseconds;
        try {
          detector
            ..rotationDegrees = message.rotationDegrees
            ..screenAspect = message.screenAspect
            ..process(LumaFrame(
              bytes: message.bytes.materialize().asUint8List(),
              width: message.width,
              height: message.height,
              bytesPerRow: message.bytesPerRow,
              timestampMicros: message.timestampMicros,
            ));
        } catch (error, stack) {
          // One bad frame must not stop detection.
          debugPrint('Frame processing failed: $error\n$stack');
        }
        toMain.send(FrameProcessed(clock.elapsedMicroseconds - start));
      case _Reset():
        detector.reset();
      case _SetGeometry(:final geometry):
        detector.geometry = geometry;
      case _Stop():
        detector.dispose();
        inbox.close();
        Isolate.exit(toMain, const _Stopped());
    }
  });
}

/// Uses the TensorFlow Lite model when one is supplied and loads, otherwise
/// OpenCV motion detection.
(BallDetector, DetectorStarted) _createBallDetector(DetectorConfig config) {
  final motion = OpenCvMotionDetector.forBallType(config.ballType);
  final model = config.modelBytes;
  if (model == null) return (motion, const DetectorStarted(usingModel: false));
  try {
    return (TfliteBallDetector.fromModel(model, motion), const DetectorStarted(usingModel: true));
  } catch (error) {
    return (motion, DetectorStarted(usingModel: false, modelError: '$error'));
  }
}
