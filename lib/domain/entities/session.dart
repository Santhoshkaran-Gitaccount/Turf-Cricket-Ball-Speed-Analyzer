import 'dart:math';

import 'package:uuid/uuid.dart';

import 'delivery.dart';
import 'tracking.dart';

enum BallType {
  tennis('Tennis Ball', 'Tennis'),
  leather('Leather Ball', 'Leather'),
  synthetic('Synthetic Ball', 'Synthetic');

  const BallType(this.label, this.shortLabel);
  final String label;

  /// For tight spaces such as the ball type picker.
  final String shortLabel;
}

abstract final class PitchLength {
  static const double minMeters = 10;
  static const double maxMeters = 25;

  /// Preset lengths offered in session setup. 20.12 m is a full 22-yard pitch.
  static const List<double> presets = [16, 18, 20.12];

  static bool isValid(double meters) => meters >= minMeters && meters <= maxMeters;
}

class Session {
  Session({
    String? id,
    required this.name,
    required this.pitchLengthMeters,
    required this.ballType,
    DateTime? startTime,
    this.endTime,
    List<Delivery>? deliveries,
  })  : id = id ?? const Uuid().v4(),
        startTime = startTime ?? DateTime.now(),
        deliveries = deliveries ?? [];

  final String id;
  final String name;
  final double pitchLengthMeters;
  final BallType ballType;
  final DateTime startTime;
  DateTime? endTime;

  /// Every recorded delivery, valid and invalid, in the order bowled.
  final List<Delivery> deliveries;

  Duration get duration => (endTime ?? DateTime.now()).difference(startTime);

  Iterable<Delivery> get validDeliveries => deliveries.where((d) => d.isValid);

  int get totalDeliveries => deliveries.length;
  int get validCount => validDeliveries.length;
  int get invalidCount => totalDeliveries - validCount;

  /// Ball numbers run across valid and invalid deliveries alike.
  int get nextBallNumber => deliveries.length + 1;

  // Statistics use valid deliveries only.
  Iterable<int> get _speeds => validDeliveries.map((d) => d.speedKmh!);

  int? get fastestKmh => _speeds.isEmpty ? null : _speeds.reduce(max);

  int? get slowestKmh => _speeds.isEmpty ? null : _speeds.reduce(min);

  double? get averageKmh => _speeds.isEmpty ? null : _speeds.reduce((a, b) => a + b) / validCount;

  int? get lastKmh => _speeds.isEmpty ? null : _speeds.last;

  /// Fastest and average speed as they would be once a delivery at
  /// [pendingKmh] is saved.
  ({int fastest, double average}) statsWith(int pendingKmh) {
    final speeds = [..._speeds, pendingKmh];
    return (
      fastest: speeds.reduce(max),
      average: speeds.reduce((a, b) => a + b) / speeds.length,
    );
  }

  Delivery recordValid(DeliveryMeasurement measurement, {DateTime? at}) =>
      _record(Delivery(
        sessionId: id,
        ballNumber: nextBallNumber,
        timestamp: at ?? DateTime.now(),
        speedKmh: measurement.speedKmh,
      ));

  Delivery recordInvalid(InvalidReason reason, {DateTime? at}) => _record(Delivery(
        sessionId: id,
        ballNumber: nextBallNumber,
        timestamp: at ?? DateTime.now(),
        invalidReason: reason,
      ));

  Delivery _record(Delivery delivery) {
    deliveries.add(delivery);
    return delivery;
  }
}
