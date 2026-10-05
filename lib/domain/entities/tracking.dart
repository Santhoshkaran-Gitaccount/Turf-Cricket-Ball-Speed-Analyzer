/// A ball position at one moment, in normalized screen coordinates.
class TrackPoint {
  const TrackPoint(this.timeMicros, this.x, this.y);

  final int timeMicros;
  final double x;
  final double y;
}

/// How a delivery finished.
enum DeliveryEnd {
  /// Tracked all the way to the batting stumps.
  stumps('Reached stumps'),

  /// Lost in the batsman area: hit the bat, pads or keeper, or left the frame.
  batsmanArea('Reached batsman area');

  const DeliveryEnd(this.label);
  final String label;
}

/// What the detector measured for one valid delivery, before the user saves it.
class DeliveryMeasurement {
  const DeliveryMeasurement({
    required this.path,
    required this.end,
    required this.speedKmh,
    this._travelTime,
  });

  /// Tracked ball positions from release to completion.
  final List<TrackPoint> path;
  final DeliveryEnd end;

  /// Average speed over the pitch, as measured.
  final int speedKmh;

  final Duration? _travelTime;

  /// Speed guns and TV show the speed at release, the fastest point. A ball
  /// loses roughly a tenth of its speed to the air and the bounce before it
  /// reaches the stumps, so release speed is about this much above the average.
  static const releaseSpeedFactor = 1.12;

  /// Speed (km/h) = pitch length ÷ travel time × 3.6, rounded to the nearest
  /// whole number. Travel time runs from release to completion detection.
  static int calculateSpeedKmh(double pitchLengthMeters, Duration travelTime) =>
      (pitchLengthMeters / (travelTime.inMicroseconds / 1e6) * 3.6).round();

  /// Time from release to completion that the speed was calculated from.
  Duration get travelTime =>
      _travelTime ?? Duration(microseconds: path.last.timeMicros - path.first.timeMicros);

  /// An estimate of the speed at release, comparable with a speed gun; it is
  /// not measured directly.
  int get estimatedReleaseKmh => (speedKmh * releaseSpeedFactor).round();
}
