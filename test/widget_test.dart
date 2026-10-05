import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:turf_cricket_ball_speed_analyzer/app.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/repositories/in_memory_session_repository.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/delivery.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/tracking.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/providers.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/screens/session_summary_screen.dart';
import 'package:turf_cricket_ball_speed_analyzer/presentation/widgets/delivery_result_card.dart';

void main() {
  testWidgets('Home screen shows app title', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: BallSpeedApp()));

    expect(find.text('Ball Speed Analyzer'), findsOneWidget);
    expect(find.text('Start Session'), findsOneWidget);
  });

  testWidgets('Session setup validates name and custom pitch length', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: BallSpeedApp()));
    await tester.tap(find.text('Start Session'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Custom Length'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).last, '30');
    await tester.tap(find.text('Open Camera'));
    await tester.pump();

    expect(find.text('Enter a session name'), findsOneWidget);
    expect(find.text('Must be between 10 and 25 meters'), findsOneWidget);
  });

  testWidgets('Session setup fits a portrait phone screen without scrolling', (tester) async {
    // Samsung Galaxy A15: 1080 × 2340 pixels, held upright.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: BallSpeedApp()));
    await tester.tap(find.text('Start Session'));
    await tester.pumpAndSettle();

    // Layout overflows would have failed the test by now.
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final button = tester.getRect(find.text('Open Camera'));
    expect(button.bottom, lessThan(screen.height));
    expect(tester.getRect(find.text('Synthetic')).bottom, lessThan(screen.height));
  });

  testWidgets('Session summary shows details, statistics and every delivery', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.reset);

    DeliveryMeasurement measured(int kmh) =>
        DeliveryMeasurement(path: const [], end: DeliveryEnd.stumps, speedKmh: kmh);
    final session = Session(
      name: 'Turf Match',
      pitchLengthMeters: 18,
      ballType: BallType.tennis,
      startTime: DateTime(2026, 9, 29, 18, 0),
      endTime: DateTime(2026, 9, 29, 18, 42, 7),
    )
      ..recordValid(measured(121), at: DateTime(2026, 9, 29, 18, 5, 9))
      ..recordInvalid(InvalidReason.trackingLost, at: DateTime(2026, 9, 29, 18, 6))
      ..recordValid(measured(97), at: DateTime(2026, 9, 29, 18, 7));

    await tester.pumpWidget(MaterialApp(home: SessionSummaryScreen(session: session)));

    for (final text in [
      'Turf Match', '29 Sep 2026', '42m 07s', '18 m', // details
      '121 km/h', '97 km/h', '109 km/h', // fastest, slowest, average
      'Ball #1', 'Ball #2', 'Ball #3', 'Invalid', 'Camera lost tracking', '18:05:09',
    ]) {
      expect(find.text(text), findsWidgets, reason: text);
    }
  });

  testWidgets('Result card shows measured speed, estimated release speed and travel time', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeliveryResultCard(
          delivery: const DeliveryMeasurement(
            path: [],
            end: DeliveryEnd.stumps,
            speedKmh: 120,
            travelTime: Duration(milliseconds: 604),
          ),
          ballNumber: 3,
          stats: (fastest: 120, average: 110),
          autoSaveDelay: const Duration(seconds: 5),
          onSave: () {},
          onDiscard: () {},
        ),
      ),
    ));

    expect(find.text('120 km/h'), findsWidgets);
    expect(find.text('Release ≈ 134 km/h (est.)'), findsOneWidget);
    expect(find.text('0.60 s  •  Reached stumps'), findsOneWidget);
  });

  testWidgets('History lists past sessions, newest first, and opens a summary', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.reset);

    final repository = InMemorySessionRepository();
    final older = Session(
      name: 'Morning Nets',
      pitchLengthMeters: 18,
      ballType: BallType.tennis,
      startTime: DateTime(2026, 9, 28, 7, 0),
    );
    final newer = Session(
      name: 'Evening Match',
      pitchLengthMeters: 20.12,
      ballType: BallType.leather,
      startTime: DateTime(2026, 9, 29, 18, 0),
    );
    final delivery = newer.recordValid(
      const DeliveryMeasurement(path: [], end: DeliveryEnd.stumps, speedKmh: 118),
      at: DateTime(2026, 9, 29, 18, 5),
    );
    await repository.saveSession(older);
    await repository.saveSession(newer);
    await repository.saveDelivery(delivery);

    await tester.pumpWidget(ProviderScope(
      overrides: [sessionRepositoryProvider.overrideWithValue(repository)],
      child: const BallSpeedApp(),
    ));
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('Evening Match')).dy, lessThan(tester.getTopLeft(find.text('Morning Nets')).dy));
    expect(find.text('118 km/h'), findsOneWidget);

    await tester.tap(find.text('Evening Match'));
    await tester.pumpAndSettle();
    expect(find.text('Session Summary'), findsOneWidget);
    expect(find.text('Ball #1'), findsOneWidget);
  });
}
