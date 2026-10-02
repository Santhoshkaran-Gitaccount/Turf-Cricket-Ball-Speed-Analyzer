import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories/session_repository.dart';
import '../mappers/session_mapper.dart';

/// Keeps data for the life of the app only. Used by default and in tests.
class InMemorySessionRepository implements SessionRepository {
  // Stored as maps, like the real store, so loads return fresh entities.
  final Map<String, Map<String, Object?>> _sessions = {};
  final Map<String, Map<String, Object?>> _deliveries = {};

  @override
  Future<void> saveSession(Session session) async =>
      _sessions[session.id] = SessionMapper.sessionToMap(session);

  @override
  Future<void> saveDelivery(Delivery delivery) async =>
      _deliveries[delivery.id] = SessionMapper.deliveryToMap(delivery);

  @override
  Future<Session?> loadSession(String id) async {
    final map = _sessions[id];
    return map == null ? null : _build(map);
  }

  @override
  Future<List<Session>> loadSessions() async =>
      _sessions.values.map(_build).toList()..sort((a, b) => b.startTime.compareTo(a.startTime));

  Session _build(Map<String, Object?> map) {
    final deliveries = _deliveries.values
        .where((d) => d['session_id'] == map['id'])
        .map(SessionMapper.deliveryFromMap)
        .toList()
      ..sort((a, b) => a.ballNumber.compareTo(b.ballNumber));
    return SessionMapper.sessionFromMap(map, deliveries: deliveries);
  }
}
