import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/device_motion.dart';

void main() {
  GyroscopeEvent turning(double radiansPerSecond) => GyroscopeEvent(0, radiansPerSecond, 0, DateTime.now());

  test('a phone on a tripod is still; turning it is moving, for a moment after', () async {
    final gyroscope = StreamController<GyroscopeEvent>();
    final motion = DeviceMotion(gyroscope: gyroscope.stream);
    addTearDown(motion.dispose);
    expect(motion.moving, isFalse); // starts listening

    gyroscope.add(turning(0.005)); // sensor noise on a tripod
    await pumpEventQueue();
    expect(motion.moving, isFalse);

    gyroscope.add(turning(0.1)); // a slow tilt
    await pumpEventQueue();
    expect(motion.moving, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(motion.moving, isFalse);
  });

  test('no gyroscope means still', () async {
    final motion = DeviceMotion(gyroscope: Stream.error(UnsupportedError('no gyroscope')));
    addTearDown(motion.dispose);
    expect(motion.moving, isFalse);
    await pumpEventQueue();
    expect(motion.moving, isFalse);
  });
}
