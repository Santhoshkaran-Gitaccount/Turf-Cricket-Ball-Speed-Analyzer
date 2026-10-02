import 'package:flutter/foundation.dart';

import '../../domain/detection/pitch_geometry.dart';
import '../../domain/entities/tracking.dart';

enum TrackingStatus { idle, tracking, paused }

/// Setting the pitch up by tapping the two sets of stumps.
enum SetupStep { tapBatting, tapBowling, done }

const _unset = Object();

@immutable
class TrackingState {
  const TrackingState({
    this.status = TrackingStatus.idle,
    this.ballInFlight = false,
    this.pitchVisible = true,
    this.cameraSteady = true,
    this.usingModel = false,
    this.measuredFps,
    this.processingMs,
    this.pending,
    this.pendingAt,
    this.notice,
    this.revision = 0,
    this.pitch,
    this.battingTap,
  });

  final TrackingStatus status;
  final bool ballInFlight;
  final bool pitchVisible;

  /// False while the camera is moving; no delivery is looked for until it settles.
  final bool cameraSteady;

  /// True when the TensorFlow Lite model is detecting the ball.
  final bool usingModel;

  /// Frames per second actually processed, once measured.
  final double? measuredFps;

  /// Average time to process one frame, once measured.
  final double? processingMs;

  /// A valid delivery waiting for the user to save or discard it.
  final DeliveryMeasurement? pending;

  /// When the pending delivery was bowled; saving can happen up to 5 s later.
  final DateTime? pendingAt;

  /// Short message to show, e.g. why a delivery was invalid.
  final String? notice;

  /// Bumped whenever the session's deliveries change, so the stats rebuild.
  final int revision;

  /// The pitch fitted to the user's taps; null until both stumps are tapped,
  /// when the standard guide is used.
  final PitchGeometry? pitch;

  /// The batting stumps tap, while waiting for the bowling stumps tap.
  final (double, double)? battingTap;

  SetupStep get setupStep => pitch != null
      ? SetupStep.done
      : battingTap != null
          ? SetupStep.tapBowling
          : SetupStep.tapBatting;

  PitchGeometry get geometry => pitch ?? PitchGeometry.standard;

  TrackingState copyWith({
    TrackingStatus? status,
    bool? ballInFlight,
    bool? pitchVisible,
    bool? cameraSteady,
    bool? usingModel,
    Object? measuredFps = _unset,
    Object? processingMs = _unset,
    Object? pending = _unset,
    Object? pendingAt = _unset,
    Object? notice = _unset,
    int? revision,
    Object? pitch = _unset,
    Object? battingTap = _unset,
  }) {
    return TrackingState(
      status: status ?? this.status,
      ballInFlight: ballInFlight ?? this.ballInFlight,
      pitchVisible: pitchVisible ?? this.pitchVisible,
      cameraSteady: cameraSteady ?? this.cameraSteady,
      usingModel: usingModel ?? this.usingModel,
      measuredFps: identical(measuredFps, _unset) ? this.measuredFps : measuredFps as double?,
      processingMs: identical(processingMs, _unset) ? this.processingMs : processingMs as double?,
      pending: identical(pending, _unset) ? this.pending : pending as DeliveryMeasurement?,
      pendingAt: identical(pendingAt, _unset) ? this.pendingAt : pendingAt as DateTime?,
      notice: identical(notice, _unset) ? this.notice : notice as String?,
      revision: revision ?? this.revision,
      pitch: identical(pitch, _unset) ? this.pitch : pitch as PitchGeometry?,
      battingTap: identical(battingTap, _unset) ? this.battingTap : battingTap as (double, double)?,
    );
  }
}
