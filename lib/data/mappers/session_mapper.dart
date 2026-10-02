import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';

/// Converts entities to and from the plain maps kept in local storage.
abstract final class SessionMapper {
  /// Session fields only; deliveries are stored separately.
  static Map<String, Object?> sessionToMap(Session session) => {
        'id': session.id,
        'name': session.name,
        'pitch_length': session.pitchLengthMeters,
        'ball_type': session.ballType.name,
        'start_time': session.startTime.millisecondsSinceEpoch,
        'end_time': session.endTime?.millisecondsSinceEpoch,
      };

  static Session sessionFromMap(Map<Object?, Object?> map, {List<Delivery>? deliveries}) {
    final end = map['end_time'] as int?;
    return Session(
      id: map['id']! as String,
      name: map['name']! as String,
      pitchLengthMeters: (map['pitch_length']! as num).toDouble(),
      ballType: BallType.values.byName(map['ball_type']! as String),
      startTime: DateTime.fromMillisecondsSinceEpoch(map['start_time']! as int),
      endTime: end == null ? null : DateTime.fromMillisecondsSinceEpoch(end),
      deliveries: deliveries,
    );
  }

  static Map<String, Object?> deliveryToMap(Delivery delivery) => {
        'id': delivery.id,
        'session_id': delivery.sessionId,
        'ball_number': delivery.ballNumber,
        'speed_kmh': delivery.speedKmh,
        'timestamp': delivery.timestamp.millisecondsSinceEpoch,
        'is_valid': delivery.isValid,
        'invalid_reason': delivery.invalidReason?.name,
      };

  static Delivery deliveryFromMap(Map<Object?, Object?> map) {
    final reason = map['invalid_reason'] as String?;
    return Delivery(
      id: map['id']! as String,
      sessionId: map['session_id']! as String,
      ballNumber: map['ball_number']! as int,
      speedKmh: map['speed_kmh'] as int?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']! as int),
      invalidReason: reason == null ? null : InvalidReason.values.byName(reason),
    );
  }
}
