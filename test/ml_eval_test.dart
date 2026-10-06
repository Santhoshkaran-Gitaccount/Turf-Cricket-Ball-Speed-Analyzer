import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/data/detection/opencv_motion_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/delivery_detector.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/delivery_tracker.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/detection/frame.dart';
import 'package:turf_cricket_ball_speed_analyzer/domain/entities/session.dart';

/// Measures speeds on deliveries rendered by ml/eval_deliveries.py, with the
/// ball model's detections and with OpenCV motion detection, against the true
/// speed. Runs only when BALL_EVAL_DIR points at that script's output:
///
///   python ml/eval_deliveries.py --model ball_detector.tflite --out eval
///   BALL_EVAL_DIR=eval flutter test test/ml_eval_test.dart
void main() {
  final dir = Platform.environment['BALL_EVAL_DIR'];

  test('speed accuracy on rendered deliveries', () {
    final deliveries = (jsonDecode(File('$dir/deliveries.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
    final rows = <String>[];
    final modelErrors = <double>[];
    final motionErrors = <double>[];
    var modelMissed = 0, motionMissed = 0;

    for (final d in deliveries) {
      final trueKmh = (d['true_kmh'] as num).toDouble();
      final pitch = (d['pitch'] as num).toDouble();
      final stamps = (d['timestamps'] as List).cast<int>();

      int? model;
      final detections = d['detections'] as List?;
      if (detections != null) {
        final tracker = DeliveryTracker(
          pitchLengthMeters: pitch,
          onEvent: (e) => model ??= e is DeliveryCompleted ? e.measurement.speedKmh : null,
        );
        for (var i = 0; i < stamps.length; i++) {
          tracker.update([
            for (final b in (detections[i] as List).cast<List>())
              MotionBlob((b[0] as num).toDouble(), (b[1] as num).toDouble(), b[2] as int, radius: (b[3] as num).toDouble()),
          ], stamps[i]);
        }
      }

      int? motion;
      final width = d['width'] as int, height = d['height'] as int;
      final frames = File('$dir/${d['name']}.bin').readAsBytesSync();
      final detector = DeliveryDetector(
        ballDetector: OpenCvMotionDetector.forBallType(switch (d['ball']) {
          'leather' => BallType.leather,
          'tennis' => BallType.tennis,
          _ => BallType.synthetic,
        }),
        pitchLengthMeters: pitch,
        onEvent: (e) => motion ??= e is DeliveryCompleted ? e.measurement.speedKmh : null,
      );
      for (var i = 0; i < stamps.length; i++) {
        detector.process(LumaFrame(
          bytes: Uint8List.sublistView(frames, i * width * height, (i + 1) * width * height),
          width: width,
          height: height,
          bytesPerRow: width,
          timestampMicros: stamps[i],
        ));
      }
      detector.dispose();

      String show(int? kmh, List<double> errors, void Function() missed) {
        if (kmh == null) {
          missed();
          return 'missed';
        }
        errors.add(kmh - trueKmh);
        return '$kmh (${kmh - trueKmh >= 0 ? '+' : ''}${(kmh - trueKmh).toStringAsFixed(1)})';
      }

      rows.add('${(d['name'] as String).padRight(24)} true ${trueKmh.toStringAsFixed(1).padLeft(6)}   '
          'model ${(detections == null ? '-' : show(model, modelErrors, () => modelMissed++)).padRight(14)} '
          'opencv ${show(motion, motionErrors, () => motionMissed++)}');
    }

    String summary(String name, List<double> errors, int missed) {
      if (errors.isEmpty) return '$name: no deliveries measured, $missed missed';
      final abs = errors.map((e) => e.abs()).toList()..sort();
      final mean = abs.reduce((a, b) => a + b) / abs.length;
      return '$name: ${errors.length} measured, $missed missed, mean error ${mean.toStringAsFixed(1)} km/h, '
          'worst ${abs.last.toStringAsFixed(1)} km/h, within 3 km/h ${abs.where((e) => e <= 3).length}/${abs.length}';
    }

    // ignore: avoid_print
    print([...rows, '', summary('model', modelErrors, modelMissed), summary('opencv', motionErrors, motionMissed)].join('\n'));
  }, skip: dir == null ? 'Set BALL_EVAL_DIR to the output of ml/eval_deliveries.py' : false, timeout: const Timeout(Duration(minutes: 20)));
}
