import '../entities/tracking.dart';
import 'ball_detector.dart';
import 'delivery_tracker.dart';
import 'frame.dart';
import 'pitch_geometry.dart';

export 'delivery_tracker.dart'
    show
        DeliveryEvent,
        ReleaseDetected,
        BallTravelling,
        DeliveryCompleted,
        DeliveryInvalid,
        TrackDiscarded,
        CameraSteadinessChanged;
export 'frame.dart' show LumaFrame;

/// Detects deliveries from a stream of camera frames with no manual input.
class DeliveryDetector {
  DeliveryDetector({
    required this._ballDetector,
    required double pitchLengthMeters,
    required void Function(DeliveryEvent event) onEvent,
    this.onFpsMeasured,
    this.onPitchVisibilityChanged,
  }) : _tracker = DeliveryTracker(pitchLengthMeters: pitchLengthMeters, onEvent: onEvent);

  final BallDetector _ballDetector;
  final DeliveryTracker _tracker;

  /// Called about once a second with the frame rate actually being processed,
  /// which can be lower than the rate requested from the camera.
  final void Function(double fps)? onFpsMeasured;

  /// Called when the pitch stops or starts being visible (too dark, too
  /// bright or blocked), so the user can fix the camera before bowling.
  final void Function(bool visible)? onPitchVisibilityChanged;

  /// Clockwise rotation that makes the sensor image upright on screen.
  int rotationDegrees = 0;

  /// Screen width / height, which decides how much of the image is visible.
  double? screenAspect;

  /// Where the pitch is. Changing it restarts detection with the new zones.
  PitchGeometry get geometry => _tracker.geometry;
  set geometry(PitchGeometry value) {
    if (value == _tracker.geometry) return;
    _tracker
      ..geometry = value
      ..reset();
  }

  FrameLayout? _layout;
  bool _pitchVisible = true;
  int? _fpsWindowStart;
  int _fpsFrames = 0;

  bool get ballInFlight => _tracker.ballInFlight;
  List<TrackPoint> get currentPath => _tracker.currentPath;

  void process(LumaFrame frame) {
    _measureFps(frame.timestampMicros);

    final layout = FrameLayout(
      width: frame.width,
      height: frame.height,
      rotationDegrees: rotationDegrees,
      screenAspect: screenAspect,
      geometry: _tracker.geometry,
    );
    // Keep one instance while nothing changes so detectors can cache per layout.
    if (layout != _layout) _layout = layout;

    final detected = _ballDetector.detect(frame, _layout!);
    // A phone turned slowly changes only the edges in view, and specks in the
    // scene then slide down the screen like a ball. The motion sensors notice
    // the turn whatever is in view.
    final detection = frame.deviceMoving ? const BallDetection(FrameStatus.cameraMoved) : detected;
    _tracker.update(detection.blobs, frame.timestampMicros, status: detection.status);

    final visible = detection.status != FrameStatus.tooDark && detection.status != FrameStatus.tooBright;
    if (visible != _pitchVisible) {
      _pitchVisible = visible;
      onPitchVisibilityChanged?.call(visible);
    }
  }

  void reset() {
    _ballDetector.reset();
    _tracker.reset();
    _fpsWindowStart = null;
    _fpsFrames = 0;
    _pitchVisible = true;
  }

  void dispose() => _ballDetector.dispose();

  void _measureFps(int timeMicros) {
    final start = _fpsWindowStart ??= timeMicros;
    _fpsFrames++;
    final elapsed = timeMicros - start;
    if (elapsed >= 1000000) {
      onFpsMeasured?.call((_fpsFrames - 1) * 1e6 / elapsed);
      _fpsWindowStart = timeMicros;
      _fpsFrames = 1;
    }
  }
}
