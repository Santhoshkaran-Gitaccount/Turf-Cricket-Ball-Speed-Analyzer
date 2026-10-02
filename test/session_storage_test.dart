import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/repositories/hive_session_repository.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/repositories/in_memory_session_repository.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/delivery.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/tracking.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/repositories/session_repository.dart';

DeliveryMeasurement _measured(int kmh) =>
    DeliveryMeasurement(path: const [TrackPoint(0, 0.5, 0.2)], end: DeliveryEnd.stumps, speedKmh: kmh);

Session _session() => Session(
      name: 'Evening Practice',
      pitchLengthMeters: 20.12,
      ballType: BallType.leather,
      startTime: DateTime(2026, 9, 29, 18, 30),
    );

void main() {
  group('session statistics', () {
    test('count valid and invalid deliveries, stats from valid only', () {
      final session = _session()
        ..recordValid(_measured(120))
        ..recordInvalid(InvalidReason.trackingLost)
        ..recordValid(_measured(135))
        ..recordValid(_measured(98))
        ..recordInvalid(InvalidReason.multipleBalls);

      expect(session.totalDeliveries, 5);
      expect(session.validCount, 3);
      expect(session.invalidCount, 2);
      expect(session.fastestKmh, 135);
      expect(session.slowestKmh, 98);
      expect(session.averageKmh, closeTo(117.67, 0.01));
      expect(session.lastKmh, 98);
    });

    test('ball numbers run in order across valid and invalid deliveries', () {
      final session = _session()
        ..recordValid(_measured(120))
        ..recordInvalid(InvalidReason.ballNotDetected)
        ..recordValid(_measured(110));

      expect(session.deliveries.map((d) => d.ballNumber), [1, 2, 3]);
      expect(session.nextBallNumber, 4);
      expect(session.deliveries[1].speedKmh, isNull);
      expect(session.deliveries[1].isValid, isFalse);
    });

    test('no stats before any valid delivery', () {
      final session = _session()..recordInvalid(InvalidReason.pitchNotVisible);

      expect(session.fastestKmh, isNull);
      expect(session.slowestKmh, isNull);
      expect(session.averageKmh, isNull);
    });

    test('preview includes the pending delivery without saving it', () {
      final session = _session()
        ..recordValid(_measured(100))
        ..recordValid(_measured(120));

      final stats = session.statsWith(140);
      expect(stats.fastest, 140);
      expect(stats.average, 120);
      expect(session.totalDeliveries, 2);
    });
  });

  // Same checks against both stores, so the in-memory one used in tests
  // behaves like Hive on the phone.
  final stores = <String, Future<SessionRepository> Function()>{
    'in-memory': () async => InMemorySessionRepository(),
    'hive': () async {
      final dir = await Directory.systemTemp.createTemp('ball_speed_hive_');
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });
      Hive.init(dir.path);
      return HiveSessionRepository.open();
    },
  };

  for (final MapEntry(key: name, value: create) in stores.entries) {
    group('$name storage', () {
      late SessionRepository repo;
      setUp(() async => repo = await create());

      test('stores every session and delivery field', () async {
        final session = _session();
        await repo.saveSession(session);
        await repo.saveDelivery(session.recordValid(_measured(128), at: DateTime(2026, 9, 29, 18, 31, 5)));
        await repo.saveDelivery(
            session.recordInvalid(InvalidReason.durationOutOfRange, at: DateTime(2026, 9, 29, 18, 32)));
        session.endTime = DateTime(2026, 9, 29, 19, 0);
        await repo.saveSession(session);

        final loaded = (await repo.loadSession(session.id))!;
        expect(loaded.id, session.id);
        expect(loaded.name, 'Evening Practice');
        expect(loaded.pitchLengthMeters, 20.12);
        expect(loaded.ballType, BallType.leather);
        expect(loaded.startTime, DateTime(2026, 9, 29, 18, 30));
        expect(loaded.endTime, DateTime(2026, 9, 29, 19, 0));

        expect(loaded.deliveries, hasLength(2));
        final [valid, invalid] = loaded.deliveries;
        expect(valid.id, session.deliveries[0].id);
        expect(valid.sessionId, session.id);
        expect(valid.ballNumber, 1);
        expect(valid.speedKmh, 128);
        expect(valid.timestamp, DateTime(2026, 9, 29, 18, 31, 5));
        expect(valid.isValid, isTrue);
        expect(invalid.ballNumber, 2);
        expect(invalid.speedKmh, isNull);
        expect(invalid.isValid, isFalse);
        expect(invalid.invalidReason, InvalidReason.durationOutOfRange);
      });

      test('updating a session keeps its deliveries', () async {
        final session = _session();
        await repo.saveSession(session);
        await repo.saveDelivery(session.recordValid(_measured(120)));
        session.endTime = DateTime(2026, 9, 29, 19, 0);
        await repo.saveSession(session);

        expect((await repo.loadSession(session.id))!.deliveries, hasLength(1));
      });

      test('lists sessions newest first, each with only its own deliveries', () async {
        final older = Session(
          name: 'Morning',
          pitchLengthMeters: 18,
          ballType: BallType.tennis,
          startTime: DateTime(2026, 9, 28, 7),
        );
        final newer = _session();
        for (final s in [older, newer]) {
          await repo.saveSession(s);
        }
        await repo.saveDelivery(older.recordValid(_measured(90)));
        await repo.saveDelivery(newer.recordValid(_measured(130)));
        await repo.saveDelivery(newer.recordValid(_measured(125)));

        final sessions = await repo.loadSessions();
        expect(sessions.map((s) => s.name), ['Evening Practice', 'Morning']);
        expect(sessions[0].deliveries, hasLength(2));
        expect(sessions[1].deliveries.single.speedKmh, 90);
      });

      test('unknown session loads as null', () async {
        expect(await repo.loadSession('missing'), isNull);
      });
    });
  }

  test('hive data survives closing and reopening, as after an app restart', () async {
    final dir = await Directory.systemTemp.createTemp('ball_speed_hive_');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);

    final first = await HiveSessionRepository.open();
    final session = _session();
    await first.saveSession(session);
    await first.saveDelivery(session.recordValid(_measured(131)));
    await first.close();

    final reopened = await HiveSessionRepository.open();
    final loaded = (await reopened.loadSession(session.id))!;
    expect(loaded.name, 'Evening Practice');
    expect(loaded.deliveries.single.speedKmh, 131);
    await reopened.close();
  });
}
