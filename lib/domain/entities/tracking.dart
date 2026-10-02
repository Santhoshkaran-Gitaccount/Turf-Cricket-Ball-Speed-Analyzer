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
  const DeliveryMeasurement({required this.path, required this.end, required this.speedKmh});

  /// Tracked ball positions from release to completion.
  final List<TrackPoint> path;
  final DeliveryEnd end;
  final int speedKmh;

  /// Speed (km/h) = pitch length ÷ travel time × 3.6, rounded to the nearest
  /// whole number. Travel time runs from release to completion detection.
  static int calculateSpeedKmh(double pitchLengthMeters, Duration travelTime) =>
      (pitchLengthMeters / (travelTime.inMicroseconds / 1e6) * 3.6).round();

  Duration get travelTime =>
      Duration(microseconds: path.last.timeMicros - path.first.timeMicros);
}
