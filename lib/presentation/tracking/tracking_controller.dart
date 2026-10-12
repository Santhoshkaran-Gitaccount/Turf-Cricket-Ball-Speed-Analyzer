import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/detection/detection_worker.dart';
import '../../data/field_log.dart';
import '../../data/pitch_setup_store.dart';
import '../../domain/detection/delivery_detector.dart';
import '../../domain/detection/pitch_geometry.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tracking.dart';
import '../providers.dart';
import 'tracking_state.dart';

final trackingControllerProvider =
    NotifierProvider.autoDispose.family<TrackingController, TrackingState, Session>(TrackingController.new);

/// Runs a session on the camera screen: starts and pauses detection, turns
/// detector events into deliveries, and saves them.
class TrackingController extends Notifier<TrackingState> {
  TrackingController(this.session);
  final Session session;

  static const autoSaveDelay = Duration(seconds: 5);
  static const _noticeDuration = Duration(seconds: 3);

  /// What became of a ball that gave no result card stays up longer, so it
  /// can be read from behind the bowler's arm.
  static const _resultNoticeDuration = Duration(seconds: 5);

  DetectionWorker? _worker;
  Timer? _autoSaveTimer;
  Timer? _noticeTimer;
  final _clock = Stopwatch()..start();
  double? _processingMicrosAverage;

  /// Per-second frame counts wobble by a few frames (frame timing, the odd
  /// frame dropped while the detector is busy), so the shown rate is averaged
  /// over a few seconds. The first second after starting is left out: the
  /// camera is still settling, and it reads low.
  int _fpsReadings = 0;

  // Field diagnostics, written to the device log and a file on the phone (see
  // FieldLog) in every build mode: what the camera delivers against what is
  // processed, and what became of each ball picked up, with its path on screen.
  int _cameraFrames = 0;
  int _droppedAtLastLog = 0;
  final List<TrackPoint> _loggedPath = [];

  void _log(String message) => FieldLog.write(message);

  String _pathSummary() {
    final path = _loggedPath;
    if (path.isEmpty) return 'no path';
    final first = path.first;
    final last = path.last;
    final maxY = path.map((p) => p.y).reduce((a, b) => a > b ? a : b);
    String at(TrackPoint p) => '(${p.x.toStringAsFixed(3)}, ${p.y.toStringAsFixed(3)})';
    return 'points ${path.length}, ${(last.timeMicros - first.timeMicros) ~/ 1000} ms, '
        'from ${at(first)} to ${at(last)}, lowest y ${maxY.toStringAsFixed(3)}';
  }

  @override
  TrackingState build() {
    // Kept for as long as the session's camera screen is open.
    ref.watch(deviceMotionProvider);
    ref.watch(soundPlayerProvider);
    ref.onDispose(() {
      _autoSaveTimer?.cancel();
      _noticeTimer?.cancel();
      _worker?.dispose();
    });
    return const TrackingState();
  }

  Future<void> start() async {
    final DetectionWorker worker;
    try {
      worker = _worker ??
          await DetectionWorker.spawn(
            DetectorConfig(
              pitchLengthMeters: session.pitchLengthMeters,
              ballType: session.ballType,
              geometry: state.geometry,
              modelBytes: await ref.read(ballModelProvider.future),
            ),
            _onMessage,
          );
    } catch (error) {
      if (ref.mounted) _showNotice('Could not start detection: $error');
      return;
    }
    if (!ref.mounted) {
      // The screen closed while the worker was starting.
      if (_worker == null) unawaited(worker.dispose());
      return;
    }
    _worker = worker..reset();
    state = state.copyWith(
      status: TrackingStatus.tracking,
      ballInFlight: false,
      pitchVisible: true,
      cameraSteady: true,
      measuredFps: null,
    );
    _fpsReadings = 0;
    _log('tracking started: pitch ${session.pitchLengthMeters} m, ball ${session.ballType.name}, '
        'pitch ${state.pitch == null ? 'standard guide' : 'set from stumps'}');
  }

  void pause() {
    if (state.status != TrackingStatus.tracking) return;
    _worker?.reset();
    _log('tracking paused');
    state = state.copyWith(
      status: TrackingStatus.paused,
      ballInFlight: false,
      pitchVisible: true,
      cameraSteady: true,
    );
  }

  /// Forgets the previous frame and any candidate tracks, e.g. after the
  /// camera's exposure changed, so the brightness jump is not taken for motion.
  void resetDetection() {
    if (state.status != TrackingStatus.tracking || state.ballInFlight) return;
    _worker?.reset();
  }

  /// Hands one camera frame's brightness plane to the detector.
  void processFrame({
    required Uint8List bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    required int rotationDegrees,
    required double screenAspect,
    ChromaPlanes? chroma,
  }) {
    if (state.status != TrackingStatus.tracking) return;
    _cameraFrames++;
    _worker?.process(
      LumaFrame(
        bytes: bytes,
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        timestampMicros: _clock.elapsedMicroseconds,
        deviceMoving: ref.read(deviceMotionProvider).moving,
        chroma: chroma,
      ),
      rotationDegrees: rotationDegrees,
      screenAspect: screenAspect,
    );
  }

  /// A tap on the camera view, in reference coordinates, while setting the
  /// pitch up: first the batting stumps, then the bowling stumps.
  void tapStumps(double x, double y) {
    if (state.status == TrackingStatus.tracking) return;
    switch (state.setupStep) {
      case SetupStep.tapBatting:
        state = state.copyWith(battingTap: (x, y));
      case SetupStep.tapBowling:
        final pitch = PitchGeometry.fromStumps(batting: state.battingTap!, bowling: (x, y));
        if (pitch == null) {
          state = state.copyWith(battingTap: null);
          _showNotice('Those taps do not look like a pitch. Tap the batting stumps again.');
          return;
        }
        _worker?.setGeometry(pitch);
        unawaited(PitchSetupStore.save(state.battingTap!, (x, y)));
        _log('pitch set: batting stumps base y ${pitch.nearY.toStringAsFixed(3)}, '
            'bowling stumps base y ${pitch.farY.toStringAsFixed(3)}, scale ${pitch.scale.toStringAsFixed(2)}');
        state = state.copyWith(pitch: pitch, battingTap: null);
      case SetupStep.done:
        break;
    }
  }

  /// Forgets the tapped pitch and goes back to the standard guide.
  void resetSetup() {
    if (state.status == TrackingStatus.tracking) return;
    _worker?.setGeometry(PitchGeometry.standard);
    state = state.copyWith(pitch: null, battingTap: null);
    unawaited(PitchSetupStore.forget());
  }

  /// Uses the stumps tapped last time, if any, so a phone left in the same
  /// place needs no setup. Reset taps them again.
  Future<void> restoreSavedPitch() async {
    final saved = await PitchSetupStore.load();
    if (saved == null || !ref.mounted || state.pitch != null || state.battingTap != null) return;
    final (batting, bowling) = saved;
    final pitch = PitchGeometry.fromStumps(batting: batting, bowling: bowling);
    if (pitch == null) return;
    _worker?.setGeometry(pitch);
    state = state.copyWith(pitch: pitch);
    _log('pitch restored from the last setup');
  }

  void savePending() {
    _autoSaveTimer?.cancel();
    final pending = state.pending;
    if (pending == null) return;
    _persist(ref.read(recordValidDeliveryProvider)(session, pending, at: state.pendingAt));
    state = state.copyWith(pending: null, pendingAt: null, revision: state.revision + 1);
  }

  void discardPending() {
    _autoSaveTimer?.cancel();
    state = state.copyWith(pending: null, pendingAt: null);
  }

  /// Starts detection afresh after something got stuck, keeping the session
  /// (pitch length, ball type, deliveries so far) and the stumps tapped: any
  /// pending delivery is saved, the detection worker is shut down, and the
  /// next start opens a new one.
  Future<void> restart() async {
    pause();
    savePending();
    final worker = _worker;
    _worker = null;
    await worker?.dispose();
    _log('detection restarted');
  }

  /// Stops detection, saves any pending delivery (the default) and closes the session.
  Future<void> end() async {
    pause();
    savePending();
    await _worker?.dispose();
    _worker = null;
    await ref.read(endSessionProvider)(session).catchError((Object error) {
      debugPrint('Could not save session end: $error');
    });
  }

  void _onMessage(DetectorMessage message) {
    if (!ref.mounted) return;
    switch (message) {
      case DetectorStarted(:final usingModel, :final modelError):
        state = state.copyWith(usingModel: usingModel);
        if (modelError != null) _showNotice('Ball model could not load; using motion detection');
      case FpsMeasured(:final fps):
        final dropped = _worker?.droppedFrames ?? 0;
        final processingMs = (_processingMicrosAverage ?? 0) / 1000;
        _log('camera frames $_cameraFrames/s, processed ${fps.toStringAsFixed(1)}/s, '
            'dropped ${dropped - _droppedAtLastLog}, processing ${processingMs.toStringAsFixed(1)} ms/frame');
        _cameraFrames = 0;
        _droppedAtLastLog = dropped;
        if (_fpsReadings++ == 0) break;
        final previous = state.measuredFps;
        final smoothed = previous == null ? fps : previous * 0.7 + fps * 0.3;
        final processing = _processingMicrosAverage;
        state = state.copyWith(measuredFps: smoothed, processingMs: processing == null ? null : processing / 1000);
      case PitchVisibilityChanged(:final visible):
        state = state.copyWith(pitchVisible: visible);
      case FrameProcessed(:final processingMicros):
        // Smoothed; published with the FPS once a second rather than per frame.
        final average = _processingMicrosAverage;
        _processingMicrosAverage = average == null ? processingMicros.toDouble() : average * 0.95 + processingMicros * 0.05;
      case DetectorEvent(:final event):
        _onDeliveryEvent(event);
    }
  }

  void _onDeliveryEvent(DeliveryEvent event) {
    switch (event) {
      case ReleaseDetected(:final point):
        _loggedPath
          ..clear()
          ..add(point);
      case BallTravelling(:final point):
        _loggedPath.add(point);
      case DeliveryCompleted(:final measurement):
        _log('COUNTED ${measurement.speedKmh} km/h, end ${measurement.end.name}, '
            '${measurement.travelTime.inMilliseconds} ms; ${_pathSummary()}');
      case TrackDiscarded(:final tooFast):
        _log('DISCARDED${tooFast ? ' (too fast)' : ''}; ${_pathSummary()}');
      case DeliveryInvalid(:final reason):
        _log('INVALID ${reason.name}; ${_pathSummary()}');
      case CameraSteadinessChanged(:final steady):
        _log(steady ? 'camera steady' : 'camera MOVING');
    }
    switch (event) {
      case ReleaseDetected():
        state = state.copyWith(ballInFlight: true);
        // Told by sound too, so the bowler end knows the ball was picked up
        // without looking at the screen. No vibration: it would shake the camera.
        _showNotice('Ball detected');
        ref.read(soundPlayerProvider).ballDetected();
      case BallTravelling():
        break;
      case DeliveryCompleted(:final measurement):
        // A new ball before the last one was handled keeps the default: save it.
        savePending();
        _autoSaveTimer = Timer(autoSaveDelay, savePending);
        state = state.copyWith(pending: measurement, pendingAt: DateTime.now(), ballInFlight: false);
        ref.read(soundPlayerProvider).say('${measurement.speedKmh} kilometres per hour');
      case TrackDiscarded(tooFast: true):
        // Faster than any bowler: not a ball, so nothing is recorded. "Ball
        // detected" was already shown, so say what became of it.
        state = state.copyWith(ballInFlight: false);
        _showNotice(
          'Not counted: too fast for ${formatPitchLength(session.pitchLengthMeters)}. Check the pitch length.',
          duration: _resultNoticeDuration,
        );
        ref.read(soundPlayerProvider).say('Not counted. Too fast');
      case TrackDiscarded():
        // It was announced as a ball, so it was bowled: like in a real over,
        // it takes a ball number, as an invalid delivery.
        _recordInvalid(InvalidReason.ballLost);
      case CameraSteadinessChanged(:final steady):
        state = state.copyWith(cameraSteady: steady);
      case DeliveryInvalid(:final reason):
        _recordInvalid(reason);
    }
  }

  void _recordInvalid(InvalidReason reason) {
    // A valid ball still on its card came first, so it is numbered first.
    savePending();
    _persist(ref.read(recordInvalidDeliveryProvider)(session, reason));
    state = state.copyWith(ballInFlight: false, revision: state.revision + 1);
    _showNotice('Invalid delivery: ${reason.label}', duration: _resultNoticeDuration);
    ref.read(soundPlayerProvider).say('Invalid. ${reason.label}');
  }

  /// Storage runs in the background; the session in memory drives the UI.
  void _persist(Future<Delivery> write) {
    unawaited(write.then<void>((_) {}, onError: (Object error) {
      debugPrint('Could not save to local storage: $error');
      if (ref.mounted) _showNotice('Could not save to device storage');
    }));
  }

  void _showNotice(String message, {Duration duration = _noticeDuration}) {
    _noticeTimer?.cancel();
    _noticeTimer = Timer(duration, () {
      if (ref.mounted) state = state.copyWith(notice: null);
    });
    state = state.copyWith(notice: message);
  }
}
