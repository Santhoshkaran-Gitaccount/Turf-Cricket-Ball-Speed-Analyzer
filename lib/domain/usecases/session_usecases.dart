import '../entities/delivery.dart';
import '../entities/session.dart';
import '../entities/tracking.dart';
import '../repositories/session_repository.dart';

/// Creates a session and stores it straight away, so it survives the app
/// closing mid-way.
class StartSession {
  const StartSession(this._repository);
  final SessionRepository _repository;

  Future<Session> call({
    required String name,
    required double pitchLengthMeters,
    required BallType ballType,
  }) async {
    final session = Session(name: name, pitchLengthMeters: pitchLengthMeters, ballType: ballType);
    await _repository.saveSession(session);
    return session;
  }
}

/// Adds a valid delivery to the session and stores it.
class RecordValidDelivery {
  const RecordValidDelivery(this._repository);
  final SessionRepository _repository;

  Future<Delivery> call(Session session, DeliveryMeasurement measurement, {DateTime? at}) async {
    final delivery = session.recordValid(measurement, at: at);
    await _repository.saveDelivery(delivery);
    return delivery;
  }
}

/// Adds an invalid delivery to the session and stores it. It is kept for the
/// record but never counts toward statistics.
class RecordInvalidDelivery {
  const RecordInvalidDelivery(this._repository);
  final SessionRepository _repository;

  Future<Delivery> call(Session session, InvalidReason reason, {DateTime? at}) async {
    final delivery = session.recordInvalid(reason, at: at);
    await _repository.saveDelivery(delivery);
    return delivery;
  }
}

class EndSession {
  const EndSession(this._repository);
  final SessionRepository _repository;

  Future<void> call(Session session) async {
    session.endTime = DateTime.now();
    await _repository.saveSession(session);
  }
}
