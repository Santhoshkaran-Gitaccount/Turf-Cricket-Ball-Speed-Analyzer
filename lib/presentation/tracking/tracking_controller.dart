import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/detection/detection_worker.dart';
import '../../domain/detection/delivery_detector.dart';
import '../../domain/detection/pitch_geometry.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';
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

  DetectionWorker? _worker;
  Timer? _autoSaveTimer;
  Timer? _noticeTimer;
  final _clock = Stopwatch()..start();
  double? _processingMicrosAverage;

  @override
  TrackingState build() {
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
  }

  void pause() {
    if (state.status != TrackingStatus.tracking) return;
    _worker?.reset();
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
  }) {
    if (state.status != TrackingStatus.tracking) return;
    _worker?.process(
      LumaFrame(
        bytes: bytes,
        width: width,
        height: height,
        bytesPerRow: bytesPerRow,
        timestampMicros: _clock.elapsedMicroseconds,
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
        final processing = _processingMicrosAverage;
        state = state.copyWith(measuredFps: fps, processingMs: processing == null ? null : processing / 1000);
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
      case ReleaseDetected():
        state = state.copyWith(ballInFlight: true);
        // Told by sound too, so the bowler end knows the ball was picked up
        // without looking at the screen. No vibration: it would shake the camera.
        _showNotice('Ball detected');
        unawaited(SystemSound.play(SystemSoundType.click));
      case BallTravelling():
        break;
      case DeliveryCompleted(:final measurement):
        // A new ball before the last one was handled keeps the default: save it.
        savePending();
        _autoSaveTimer = Timer(autoSaveDelay, savePending);
        state = state.copyWith(pending: measurement, pendingAt: DateTime.now(), ballInFlight: false);
      case TrackDiscarded():
        // Not a ball after all; nothing is recorded.
        state = state.copyWith(ballInFlight: false);
      case CameraSteadinessChanged(:final steady):
        state = state.copyWith(cameraSteady: steady);
      case DeliveryInvalid(:final reason):
        _persist(ref.read(recordInvalidDeliveryProvider)(session, reason));
        state = state.copyWith(ballInFlight: false, revision: state.revision + 1);
        _showNotice('Invalid delivery: ${reason.label}');
    }
  }

  /// Storage runs in the background; the session in memory drives the UI.
  void _persist(Future<Delivery> write) {
    unawaited(write.then<void>((_) {}, onError: (Object error) {
      debugPrint('Could not save to local storage: $error');
      if (ref.mounted) _showNotice('Could not save to device storage');
    }));
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    _noticeTimer = Timer(_noticeDuration, () {
      if (ref.mounted) state = state.copyWith(notice: null);
    });
    state = state.copyWith(notice: message);
  }
}
