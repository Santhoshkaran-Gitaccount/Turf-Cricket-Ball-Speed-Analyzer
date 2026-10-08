import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories/session_repository.dart';

/// Stands in for a repository that is still opening, so the first screen can
/// show straight away instead of waiting for storage. Every call waits for it.
class DeferredSessionRepository implements SessionRepository {
  DeferredSessionRepository(this._opening);

  final Future<SessionRepository> _opening;

  @override
  Future<void> saveSession(Session session) async => (await _opening).saveSession(session);

  @override
  Future<void> saveDelivery(Delivery delivery) async => (await _opening).saveDelivery(delivery);

  @override
  Future<Session?> loadSession(String id) async => (await _opening).loadSession(id);

  @override
  Future<List<Session>> loadSessions() async => (await _opening).loadSessions();
}
