import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// Tells from the gyroscope whether the phone is turning, so frames taken
/// while it moves are not searched for a ball.
///
/// Turning at [movingRadiansPerSecond] moves the view by about half a pixel
/// a frame at 720p and 30 FPS: enough to make edges in the scene show up as
/// motion. A phone on a tripod reads far below it.
class DeviceMotion {
  DeviceMotion({this._gyroscope});

  static const movingRadiansPerSecond = 0.03;

  /// The phone counts as moving for this long after the last fast reading,
  /// covering the frames already on their way.
  static const _hold = Duration(milliseconds: 200);

  final Stream<GyroscopeEvent>? _gyroscope;
  final _clock = Stopwatch()..start();
  Duration? _lastMoving;
  StreamSubscription<GyroscopeEvent>? _subscription;

  /// The sensor is started on the first question, i.e. with the first frame.
  bool get moving {
    _subscription ??= _listen();
    return _lastMoving != null && _clock.elapsed - _lastMoving! < _hold;
  }

  StreamSubscription<GyroscopeEvent> _listen() =>
      // Without a gyroscope (or in tests) the phone is taken as still, and the
      // detector's own whole-view check still catches jolts. The plugin sets
      // the sampling rate without waiting for the result, so a missing sensor
      // is reported as an error in this zone rather than on the stream.
      runZonedGuarded(
        () => (_gyroscope ?? gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval))
            .listen(_onGyroscope, onError: (_) {}),
        (_, _) {},
      )!;

  void _onGyroscope(GyroscopeEvent event) {
    if (sqrt(event.x * event.x + event.y * event.y + event.z * event.z) > movingRadiansPerSecond) {
      _lastMoving = _clock.elapsed;
    }
  }

  void dispose() => _subscription?.cancel();
}
