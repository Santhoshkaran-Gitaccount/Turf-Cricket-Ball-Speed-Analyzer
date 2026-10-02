import '../entities/delivery.dart';
import '../entities/session.dart';

/// Stores sessions and their deliveries on the device (offline-first, no cloud sync).
abstract interface class SessionRepository {
  /// Inserts the session, or updates it if it is already stored. Its
  /// deliveries are stored separately with [saveDelivery].
  Future<void> saveSession(Session session);

  Future<void> saveDelivery(Delivery delivery);

  /// A stored session with its deliveries in ball order, or null.
  Future<Session?> loadSession(String id);

  /// All stored sessions with their deliveries, newest first.
  Future<List<Session>> loadSessions();
}
