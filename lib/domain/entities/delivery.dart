import 'package:uuid/uuid.dart';

/// Why a delivery was marked invalid. Invalid deliveries never count toward
/// session statistics.
enum InvalidReason {
  /// The ball was seen in too few of the frames it was in flight.
  ballNotDetected('Ball not detected'),

  /// The ball was lost mid-pitch, or the camera moved during the delivery.
  trackingLost('Camera lost tracking'),

  /// A second ball was moving down the pitch at the same time.
  multipleBalls('Multiple balls visible'),

  /// The pitch was too dark, too bright or blocked to see the ball.
  pitchNotVisible('Pitch not fully visible'),

  /// Release to completion took too long or too short for a real delivery.
  durationOutOfRange('Delivery duration out of range');

  const InvalidReason(this.label);
  final String label;
}

/// A recorded delivery, valid or invalid.
class Delivery {
  Delivery({
    String? id,
    required this.sessionId,
    required this.ballNumber,
    required this.timestamp,
    this.speedKmh,
    this.invalidReason,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String sessionId;
  final int ballNumber;
  final DateTime timestamp;

  /// Null for invalid deliveries.
  final int? speedKmh;

  /// Null for valid deliveries.
  final InvalidReason? invalidReason;

  bool get isValid => invalidReason == null;
}
