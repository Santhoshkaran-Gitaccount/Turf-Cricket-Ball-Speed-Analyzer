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
    final chroma = frame.chroma;
    // Interleaved colour (one plane holding both U and V) is sent once.
    final sharedChroma = chroma != null && identical(chroma.u, chroma.v);
    _toWorker.send(_Frame(
      TransferableTypedData.fromList([
        frame.bytes,
        if (chroma != null) chroma.u,
        if (chroma != null && !sharedChroma) chroma.v,
      ]),
      frame.bytes.length,
      chroma == null
          ? null
          : (
              uLength: chroma.u.length,
              vLength: sharedChroma ? 0 : chroma.v.length,
              rowStride: chroma.rowStride,
              pixelStride: chroma.pixelStride,
              uOffset: chroma.uOffset,
              vOffset: chroma.vOffset,
            ),
      frame.width,
      frame.height,
      frame.bytesPerRow,
      frame.timestampMicros,
      rotationDegrees,
      screenAspect,
      frame.deviceMoving,
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

/// How the colour planes follow the brightness plane in a [_Frame]'s bytes.
/// A [vLength] of 0 means V is in the U plane (interleaved).
typedef _ChromaLayout = ({int uLength, int vLength, int rowStride, int pixelStride, int uOffset, int vOffset});

class _Frame {
  const _Frame(
    this.bytes,
    this.lumaLength,
    this.chroma,
    this.width,
    this.height,
    this.bytesPerRow,
    this.timestampMicros,
    this.rotationDegrees,
    this.screenAspect,
    this.deviceMoving,
  );

  /// The brightness plane, then the colour planes if [chroma] is set.
  final TransferableTypedData bytes;
  final int lumaLength;
  final _ChromaLayout? chroma;
  final int width;
  final int height;
  final int bytesPerRow;
  final int timestampMicros;
  final int rotationDegrees;
  final double? screenAspect;
  final bool deviceMoving;
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

/// The frame [message] carries, its planes viewed in place in the received bytes.
LumaFrame _unpack(_Frame message) {
  final buffer = message.bytes.materialize();
  final luma = buffer.asUint8List(0, message.lumaLength);
  ChromaPlanes? chroma;
  if (message.chroma case final layout?) {
    final u = buffer.asUint8List(message.lumaLength, layout.uLength);
    chroma = ChromaPlanes(
      u: u,
      v: layout.vLength == 0 ? u : buffer.asUint8List(message.lumaLength + layout.uLength, layout.vLength),
      rowStride: layout.rowStride,
      pixelStride: layout.pixelStride,
      uOffset: layout.uOffset,
      vOffset: layout.vOffset,
    );
  }
  return LumaFrame(
    bytes: luma,
    width: message.width,
    height: message.height,
    bytesPerRow: message.bytesPerRow,
    timestampMicros: message.timestampMicros,
    deviceMoving: message.deviceMoving,
    chroma: chroma,
  );
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
            ..process(_unpack(message));
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
