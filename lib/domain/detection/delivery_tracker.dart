import 'dart:math';

import '../entities/tracking.dart';
import '../entities/delivery.dart';
import 'pitch_geometry.dart';
import 'frame.dart';

sealed class DeliveryEvent {
  const DeliveryEvent();
}

/// The ball has left the bowler's hand. [point] is where and when it was
/// first seen in the release zone.
class ReleaseDetected extends DeliveryEvent {
  const ReleaseDetected(this.point);
  final TrackPoint point;
}

/// The ball moved to a new position along the pitch.
class BallTravelling extends DeliveryEvent {
  const BallTravelling(this.point);
  final TrackPoint point;
}

/// The ball reached the batsman end and the delivery is valid.
class DeliveryCompleted extends DeliveryEvent {
  const DeliveryCompleted(this.measurement);
  final DeliveryMeasurement measurement;
}

/// A delivery was released but cannot be measured reliably.
class DeliveryInvalid extends DeliveryEvent {
  const DeliveryInvalid(this.reason);
  final InvalidReason reason;
}

/// Something was being followed as a ball but turned out not to move like
/// one (hand movement, camera shake, noise). It is not a delivery, valid or
/// invalid, and is not recorded.
class TrackDiscarded extends DeliveryEvent {
  const TrackDiscarded({this.tooFast = false});

  /// It crossed the pitch faster than any ball can be bowled over the
  /// entered pitch length: something else, or a pitch length set longer
  /// than the real distance.
  final bool tooFast;
}

/// The camera started or stopped moving. While it moves, no new delivery is
/// looked for, since everything in view appears to move.
class CameraSteadinessChanged extends DeliveryEvent {
  const CameraSteadinessChanged({required this.steady});
  final bool steady;
}

class _Track {
  _Track(TrackPoint first) : points = [first], maxY = first.y;

  final List<TrackPoint> points;
  double maxY;

  TrackPoint get last => points.last;

  void add(TrackPoint point) {
    points.add(point);
    maxY = max(maxY, point.y);
  }
}

/// Turns per-frame motion blobs into deliveries.
///
/// Candidate tracks start from small blobs in the release zone. A track that
/// gets past [PitchGeometry.inFlightY] is the ball (the bowler's arm and body
/// never reach that far down the screen), which is the release event. It is
/// then followed down the pitch until it reaches the stumps, or disappears
/// inside the batsman area (bat, pads, keeper), which is the completion event.
/// Anything that makes the measurement unreliable along the way marks the
/// delivery invalid instead.
class DeliveryTracker {
  DeliveryTracker({
    required this.pitchLengthMeters,
    required this.onEvent,
    this.geometry = PitchGeometry.standard,
  });

  /// Where the pitch is; replaced when the user taps the stumps.
  PitchGeometry geometry;

  final double pitchLengthMeters;
  final void Function(DeliveryEvent event) onEvent;

  /// The ball may be hidden (by the batsman, or lost against the background)
  /// for up to this many frames and still be followed as the same ball.
  static const _maxOccludedFrames = 5;

  /// Lower bound for the occlusion gap, so a jittery high frame rate does not
  /// make it too short.
  static const _minGapMicros = 60000;
  static const _minPointsInFlight = 4;
  static const _maxCandidates = 12;
  static const _maxSeedArea = 30;
  static const _maxBallArea = 150;
  static const _cooldownAfterDeliveryMicros = 1500000;
  /// As long as after a valid delivery: the same ball bouncing on, rolling or
  /// being picked up must not be taken for further deliveries.
  static const _cooldownAfterInvalidMicros = 1500000;
  static const _minTravelMicros = 200000;
  static const _maxTravelMicros = 3000000;
  static const _minKmh = 15;

  /// A little above the fastest ball ever recorded (161.3 km/h).
  static const _maxKmh = 165;

  /// After the camera moves, wait this long before looking for a new delivery.
  static const _settleMicros = 1000000;

  /// The camera is reported as moving only when whole-view changes keep
  /// coming: at least [_minMovingFrames], and [_minMovingShare] of the frames,
  /// within [_movementWindowMicros]. A single exposure jump or a passing
  /// shadow on a fixed tripod pauses detection briefly but is not reported.
  static const _movementWindowMicros = 500000;
  static const _minMovingFrames = 3;
  static const _minMovingShare = 0.3;

  /// More ball-sized moving patches than this in one frame means the scene is
  /// busy or noisy (players, grass, sensor noise), so no new track is started
  /// from that frame. It says nothing about the camera itself.
  static const _maxBallSizedBlobs = 6;

  /// A ball-sized patch closer than this to something large is part of it.
  static const _isolationMargin = 0.02;

  /// The largest patch that can be the ball at height [y] on screen: a ball
  /// looks small at the far end and grows towards the camera, while a person
  /// at the far end can be as big on screen as a ball beside the camera.
  /// The share of [_maxBallArea] grows with the pitch's width (not its square),
  /// leaving room for motion blur.
  int _maxAreaAt(double y) {
    final share = (geometry.halfWidthAt(y) / geometry.nearHalfWidth).clamp(0.0, 1.0);
    return max(_maxSeedArea, (_maxBallArea * share).round());
  }

  /// After a bounce the ball can rise on screen a little from one frame to
  /// the next; a candidate with a few points already may do the same.
  static const _bounceRise = 0.02;

  /// How much larger than [_maxAreaAt] the ball may grow while followed.
  static const _inFlightAreaGrowth = 4;

  /// The ball must be seen in at least this share of its frames in flight.
  static const _minDetectionRate = 0.5;

  final List<_Track> _candidates = [];
  _Track? _ball;
  int _cooldownUntil = 0;
  int? _lastFrameMicros;
  double _frameIntervalMicros = 1e6 / 60;

  // Per-delivery bookkeeping, reset when a ball is released.
  int _flightFrames = 0;
  int _framesSinceSeen = 0;
  bool _secondBallSeen = false;

  int _unsettledUntil = 0;
  int _movingUntil = 0;
  final List<int> _movedFrameTimes = [];
  bool _steady = true;

  bool get ballInFlight => _ball != null;

  List<TrackPoint> get currentPath => _ball?.points ?? const [];

  /// How long a track can go unseen before it is treated as lost.
  int get _maxGapMicros =>
      max(_minGapMicros, (_frameIntervalMicros * (_maxOccludedFrames + 1)).round());

  void reset() {
    _candidates.clear();
    _ball = null;
    _cooldownUntil = 0;
    _lastFrameMicros = null;
    _unsettledUntil = 0;
    _movingUntil = 0;
    _movedFrameTimes.clear();
    _steady = true;
  }

  void update(List<MotionBlob> blobs, int timeMicros, {FrameStatus status = FrameStatus.ok}) {
    if (_lastFrameMicros case final last?) {
      // Smoothed frame interval, so the occlusion allowance follows the real frame rate.
      _frameIntervalMicros = 0.9 * _frameIntervalMicros + 0.1 * (timeMicros - last);
    }
    _lastFrameMicros = timeMicros;

    // Something large moving down the pitch is a person (often the bowler
    // walking up to the phone), and bits of it (a hand, a shoe, the edge of a
    // shirt) are ball-sized and travel just like a ball. A ball in flight is on
    // its own; only at the bowler's hand is it next to a body. (Near the
    // batsman it is lost a moment early, and still completes in the batsman area.)
    final large = blobs.where((b) => b.area > _maxAreaAt(b.y)).toList();
    bool nextToLarge(MotionBlob b) => large.any((l) {
          final dx = b.x - l.x;
          final dy = b.y - l.y;
          final reach = l.radius + b.radius + _isolationMargin;
          return dx * dx + dy * dy <= reach * reach;
        });
    final unused = [
      for (final b in blobs)
        if (b.area <= _maxAreaAt(b.y) && (geometry.isReleaseZone(b.x, b.y) || !nextToLarge(b))) b,
    ];
    final moved = status == FrameStatus.cameraMoved;
    final noisy = unused.length > _maxBallSizedBlobs;
    if (moved) _unsettledUntil = timeMicros + _settleMicros;
    _updateSteadiness(timeMicros, moved: moved);

    if (timeMicros < _cooldownUntil) return;

    final ball = _ball;
    if (ball != null) {
      switch (status) {
        case FrameStatus.ok:
          break;
        case FrameStatus.cameraMoved:
          _invalid(InvalidReason.trackingLost, timeMicros);
          return;
        case FrameStatus.tooDark || FrameStatus.tooBright:
          _invalid(InvalidReason.pitchNotVisible, timeMicros);
          return;
      }
    } else if (status != FrameStatus.ok || timeMicros < _unsettledUntil) {
      // Nothing new is started until the camera has been still for a moment.
      _candidates.clear();
      return;
    }

    if (ball != null) {
      _flightFrames++;
      // Near the camera the ball is large and smeared by motion blur; once it
      // is being followed, it may be larger than a new track could start from.
      final reachable = [
        ...unused,
        for (final b in blobs)
          if (b.area > _maxAreaAt(b.y) && b.area <= _maxAreaAt(b.y) * _inFlightAreaGrowth) b,
      ];
      final match = _bestMatch(ball, reachable, timeMicros, allowUpward: true);
      if (match != null) {
        unused.remove(match);
        _framesSinceSeen = 0;
        ball.add(TrackPoint(timeMicros, match.x, match.y));
        onEvent(BallTravelling(ball.last));
        if (geometry.reachedStumps(match.y)) {
          _complete(ball, DeliveryEnd.stumps);
          return;
        }
      } else {
        _framesSinceSeen++;
        if (timeMicros - ball.last.timeMicros > _maxGapMicros) {
          if (geometry.isBatsmanZone(ball.maxY)) {
            _complete(ball, DeliveryEnd.batsmanArea);
          } else {
            _invalid(InvalidReason.trackingLost, timeMicros);
          }
          return;
        }
      }
    }

    // Candidates keep running while a ball is in flight, so a second ball
    // coming down the pitch at the same time is noticed.
    for (final track in _candidates) {
      final match = _bestMatch(track, unused, timeMicros, allowUpward: false);
      if (match == null) continue;
      unused.remove(match);
      track.add(TrackPoint(timeMicros, match.x, match.y));

      if (track.points.length >= _minPointsInFlight && track.last.y >= geometry.inFlightY) {
        if (!_movesLikeBall(track.points)) {
          _candidates.remove(track);
          break;
        }
        if (_ball != null) {
          _secondBallSeen = true;
          _candidates.remove(track);
          break;
        }
        _release(track);
        return;
      }
    }

    _candidates.removeWhere((t) => timeMicros - t.last.timeMicros > _maxGapMicros);

    if (noisy) return;
    for (final blob in unused) {
      if (blob.area > _maxSeedArea || !geometry.isReleaseZone(blob.x, blob.y)) continue;
      if (_candidates.length >= _maxCandidates) {
        // Make room by dropping the candidate that has made the least progress.
        _candidates.sort((a, b) => b.maxY.compareTo(a.maxY));
        _candidates.removeLast();
      }
      _candidates.add(_Track(TrackPoint(timeMicros, blob.x, blob.y)));
    }
  }

  void _release(_Track track) {
    _candidates.clear();
    _ball = track;
    // Frames elapsed since the ball was first seen, whether or not it was detected in each.
    _flightFrames =
        ((track.last.timeMicros - track.points.first.timeMicros) / _frameIntervalMicros).round() + 1;
    _framesSinceSeen = 0;
    _secondBallSeen = false;
    onEvent(ReleaseDetected(track.points.first));
    for (final point in track.points.skip(1)) {
      onEvent(BallTravelling(point));
    }
  }

  /// The blob closest to where [track] is expected to be, if any is close enough.
  MotionBlob? _bestMatch(
    _Track track,
    List<MotionBlob> blobs,
    int timeMicros, {
    required bool allowUpward,
  }) {
    final last = track.last;
    final dt = (timeMicros - last.timeMicros) / 1e6;

    var predictedX = last.x;
    var predictedY = last.y;
    var gate = 0.06;
    if (track.points.length >= 2) {
      final previous = track.points[track.points.length - 2];
      final stepDt = (last.timeMicros - previous.timeMicros) / 1e6;
      if (stepDt > 0) {
        final vx = (last.x - previous.x) / stepDt;
        final vy = (last.y - previous.y) / stepDt;
        predictedX += vx * dt;
        predictedY += vy * dt;
        gate = 0.03 + sqrt(vx * vx + vy * vy) * dt;
      }
    }

    MotionBlob? best;
    var bestDistance = gate;
    for (final blob in blobs) {
      if (!allowUpward && blob.y < last.y - (track.points.length >= 3 ? _bounceRise : 0.005)) continue;
      final dx = blob.x - predictedX;
      final dy = blob.y - predictedY;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance <= bestDistance) {
        best = blob;
        bestDistance = distance;
      }
    }
    return best;
  }

  void _complete(_Track track, DeliveryEnd end) {
    final completedAt = track.last.timeMicros;

    if (!_movesLikeBall(track.points)) {
      _discard(completedAt);
      return;
    }

    if (_secondBallSeen) {
      _invalid(InvalidReason.multipleBalls, completedAt);
      return;
    }

    // Duration is checked before detection quality: it is measured directly,
    // and a very slow ball also moves too little per frame to be seen often.
    final travelTime = Duration(microseconds: _travelMicros(track.points, end));
    // Faster than any bowler is not a delivery at all, so it is not recorded;
    // slower than any delivery still is one, recorded as invalid.
    if (travelTime.inMicroseconds < _minTravelMicros) {
      _discard(completedAt, tooFast: true);
      return;
    }
    if (travelTime.inMicroseconds > _maxTravelMicros) {
      _invalid(InvalidReason.durationOutOfRange, completedAt);
      return;
    }

    // Release is at the bowling crease and completion at the batting end, so
    // the ball covered roughly the full pitch length.
    final speedKmh = DeliveryMeasurement.calculateSpeedKmh(pitchLengthMeters, travelTime);
    if (speedKmh > _maxKmh) {
      _discard(completedAt, tooFast: true);
      return;
    }
    if (speedKmh < _minKmh) {
      // For a fixed pitch length an impossible speed is an impossible duration.
      _invalid(InvalidReason.durationOutOfRange, completedAt);
      return;
    }

    // Frames after the ball was last seen are the occlusion allowance, not flight.
    final frames = _flightFrames - _framesSinceSeen;
    if (frames > 0 && track.points.length / frames < _minDetectionRate) {
      _invalid(InvalidReason.ballNotDetected, completedAt);
      return;
    }

    _ball = null;
    _candidates.clear();
    _cooldownUntil = completedAt + _cooldownAfterDeliveryMicros;
    onEvent(DeliveryCompleted(
      DeliveryMeasurement(
        path: List.unmodifiable(track.points),
        end: end,
        speedKmh: speedKmh,
        travelTime: travelTime,
      ),
    ));
  }

  /// Release-to-finish time in microseconds.
  ///
  /// Each frame's time is when the phone handed it over, which wobbles by a
  /// few milliseconds; a smooth fit of time against position down the screen
  /// through every tracked point averages that out. A ball that reached the
  /// stumps is timed where the fit crosses the stumps line, between frames,
  /// rather than at the first frame after it.
  int _travelMicros(List<TrackPoint> points, DeliveryEnd end) {
    final first = points.first;
    final last = points.last;
    final raw = last.timeMicros - first.timeMicros;
    final span = last.y - first.y;
    if (points.length < 5 || span <= 0) return raw;

    // Normal equations for t = c0 + c1·u + c2·u², with u the position scaled to 0–1.
    final m = List.generate(3, (_) => List.filled(3, 0.0));
    final v = List.filled(3, 0.0);
    for (final p in points) {
      final u = (p.y - first.y) / span;
      final powers = [1.0, u, u * u];
      final t = (p.timeMicros - first.timeMicros).toDouble();
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 3; c++) {
          m[r][c] += powers[r] * powers[c];
        }
        v[r] += powers[r] * t;
      }
    }
    final c = _solve3(m, v);
    if (c == null) return raw;
    double timeAt(double y) {
      final u = (y - first.y) / span;
      return c[0] + c[1] * u + c[2] * u * u;
    }

    final endY = end == DeliveryEnd.stumps ? geometry.stumpsLineY : last.y;
    final fitted = timeAt(endY) - timeAt(first.y);
    // The fit only refines the timing; if it disagrees with the frames by
    // more than a couple of frames, the path is unusual and the frames win.
    if (fitted <= 0 || (fitted - raw).abs() > 2 * _frameIntervalMicros) return raw;
    return fitted.round();
  }

  void _invalid(InvalidReason reason, int timeMicros) {
    // Only something that moved like a ball counts as a (failed) delivery.
    final ball = _ball;
    if (ball != null && !_movesLikeBall(ball.points)) {
      _discard(timeMicros);
      return;
    }
    _ball = null;
    _candidates.clear();
    _cooldownUntil = timeMicros + _cooldownAfterInvalidMicros;
    onEvent(DeliveryInvalid(reason));
  }

  void _discard(int timeMicros, {bool tooFast = false}) {
    _ball = null;
    _candidates.clear();
    _cooldownUntil = timeMicros + _cooldownAfterInvalidMicros;
    onEvent(TrackDiscarded(tooFast: tooFast));
  }

  void _updateSteadiness(int timeMicros, {required bool moved}) {
    if (moved) _movedFrameTimes.add(timeMicros);
    _movedFrameTimes.removeWhere((t) => timeMicros - t > _movementWindowMicros);
    final framesInWindow = _movementWindowMicros / _frameIntervalMicros;
    if (moved && _movedFrameTimes.length >= max(_minMovingFrames, _minMovingShare * framesInWindow)) {
      _movingUntil = timeMicros + _settleMicros;
    }
    final steady = timeMicros >= _movingUntil;
    if (steady == _steady) return;
    _steady = steady;
    onEvent(CameraSteadinessChanged(steady: steady));
  }

  /// Whether a path looks like a ball seen from behind the batsman: mostly
  /// moving down the screen, along a nearly straight line. Chains of unrelated
  /// motion (a hand, camera shake, noise) zigzag or wander.
  static bool _movesLikeBall(List<TrackPoint> points) {
    if (points.length < _minPointsInFlight) return false;
    final first = points.first;
    final last = points.last;
    final chordX = last.x - first.x;
    final chordY = last.y - first.y;
    final chord = sqrt(chordX * chordX + chordY * chordY);
    if (chord < 0.05 || chordY <= 0) return false;

    var pathLength = 0.0;
    var downSteps = 0;
    var maxOffset = 0.0;
    for (var i = 1; i < points.length; i++) {
      final dx = points[i].x - points[i - 1].x;
      final dy = points[i].y - points[i - 1].y;
      pathLength += sqrt(dx * dx + dy * dy);
      if (dy >= -0.002) downSteps++;
      // Distance from the straight line between the first and last points.
      final offset = ((points[i].x - first.x) * chordY - (points[i].y - first.y) * chordX).abs() / chord;
      maxOffset = max(maxOffset, offset);
    }

    // On screen a ball moves smoothly over time, speeding up gradually as it
    // nears the camera, so its position fits a gentle curve. Unrelated patches
    // chained together jump back and forth around any such curve.
    final wobble = sqrt(_bounceFitError(points));

    return pathLength / chord <= 1.25 &&
        downSteps / (points.length - 1) >= 0.75 &&
        maxOffset <= 0.02 + 0.08 * chord &&
        wobble <= 0.006 + 0.02 * chord;
  }

  /// Mean squared error of the best fit of the path by a gentle curve, or by
  /// two that meet at one point: a ball that bounces in view changes course
  /// there (seen from behind the stumps it can even rise on screen after the
  /// bounce), and each side of the bounce is smooth.
  static double _bounceFitError(List<TrackPoint> points) {
    double error(List<TrackPoint> ps) => (_curveFitError(ps, (p) => p.x) + _curveFitError(ps, (p) => p.y)) / 2;
    var best = error(points);
    // Each side needs four points, as a curve fits any three exactly.
    for (var k = _minBouncePoints - 1; k <= points.length - _minBouncePoints; k++) {
      final before = points.sublist(0, k + 1);
      final after = points.sublist(k);
      best = min(best, (error(before) * before.length + error(after) * after.length) / (before.length + after.length));
    }
    return best;
  }

  static const _minBouncePoints = 4;

  /// Mean squared error of the best quadratic fit of [coordinate] against time.
  static double _curveFitError(List<TrackPoint> points, double Function(TrackPoint) coordinate) {
    final t0 = points.first.timeMicros;
    final span = max(1, points.last.timeMicros - t0);
    // Normal equations for c0 + c1·t + c2·t², with t scaled to 0–1.
    final m = List.generate(3, (_) => List.filled(3, 0.0));
    final v = List.filled(3, 0.0);
    for (final p in points) {
      final t = (p.timeMicros - t0) / span;
      final powers = [1.0, t, t * t];
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 3; c++) {
          m[r][c] += powers[r] * powers[c];
        }
        v[r] += powers[r] * coordinate(p);
      }
    }
    final coefficients = _solve3(m, v);
    if (coefficients == null) return 0;

    var error = 0.0;
    for (final p in points) {
      final t = (p.timeMicros - t0) / span;
      final fitted = coefficients[0] + coefficients[1] * t + coefficients[2] * t * t;
      error += pow(coordinate(p) - fitted, 2);
    }
    return error / points.length;
  }

  /// Solves a 3×3 linear system by Cramer's rule, or null if it is singular.
  static List<double>? _solve3(List<List<double>> m, List<double> v) {
    double det(List<List<double>> a) =>
        a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
        a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
        a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
    final d = det(m);
    if (d.abs() < 1e-12) return null;
    return [
      for (var col = 0; col < 3; col++)
        det([
          for (var row = 0; row < 3; row++) [for (var c = 0; c < 3; c++) c == col ? v[row] : m[row][c]],
        ]) /
            d,
    ];
  }
}
