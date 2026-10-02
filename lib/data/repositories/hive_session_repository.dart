import 'package:hive_ce/hive_ce.dart';

import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories/session_repository.dart';
import '../mappers/session_mapper.dart';

/// Stores sessions and deliveries in two Hive boxes on the device, keyed by id.
class HiveSessionRepository implements SessionRepository {
  HiveSessionRepository._(this._sessions, this._deliveries);

  static const sessionsBox = 'sessions';
  static const deliveriesBox = 'deliveries';

  final Box<Map> _sessions;
  final Box<Map> _deliveries;

  /// Opens the boxes. Hive must be initialised first (`Hive.initFlutter()`
  /// in the app, `Hive.init(path)` in tests).
  static Future<HiveSessionRepository> open() async => HiveSessionRepository._(
        await Hive.openBox<Map>(sessionsBox),
        await Hive.openBox<Map>(deliveriesBox),
      );

  Future<void> close() async {
    await _sessions.close();
    await _deliveries.close();
  }

  @override
  Future<void> saveSession(Session session) =>
      _sessions.put(session.id, SessionMapper.sessionToMap(session));

  @override
  Future<void> saveDelivery(Delivery delivery) =>
      _deliveries.put(delivery.id, SessionMapper.deliveryToMap(delivery));

  @override
  Future<Session?> loadSession(String id) async {
    final map = _sessions.get(id);
    return map == null ? null : _build(map, _deliveriesBySession()[id] ?? []);
  }

  @override
  Future<List<Session>> loadSessions() async {
    final bySession = _deliveriesBySession();
    return _sessions.values.map((map) => _build(map, bySession[map['id']] ?? [])).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
  }

  Map<String, List<Delivery>> _deliveriesBySession() {
    final grouped = <String, List<Delivery>>{};
    for (final map in _deliveries.values) {
      final delivery = SessionMapper.deliveryFromMap(map);
      (grouped[delivery.sessionId] ??= []).add(delivery);
    }
    return grouped;
  }

  Session _build(Map map, List<Delivery> deliveries) => SessionMapper.sessionFromMap(
        map,
        deliveries: deliveries..sort((a, b) => a.ballNumber.compareTo(b.ballNumber)),
      );
}
