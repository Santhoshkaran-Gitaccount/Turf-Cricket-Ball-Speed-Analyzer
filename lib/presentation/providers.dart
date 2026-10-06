import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/device_motion.dart';
import '../data/repositories/in_memory_session_repository.dart';
import '../domain/repositories/session_repository.dart';
import '../domain/usecases/session_usecases.dart';

/// Where sessions are stored. `main` overrides this with the Hive repository;
/// the in-memory default serves tests.
final sessionRepositoryProvider = Provider<SessionRepository>((ref) => InMemorySessionRepository());

final startSessionProvider = Provider((ref) => StartSession(ref.watch(sessionRepositoryProvider)));
final recordValidDeliveryProvider =
    Provider((ref) => RecordValidDelivery(ref.watch(sessionRepositoryProvider)));
final recordInvalidDeliveryProvider =
    Provider((ref) => RecordInvalidDelivery(ref.watch(sessionRepositoryProvider)));
final endSessionProvider = Provider((ref) => EndSession(ref.watch(sessionRepositoryProvider)));

/// Every stored session with its deliveries, newest first. Reloaded each time
/// the history screen opens.
final sessionHistoryProvider =
    FutureProvider.autoDispose((ref) => ref.watch(sessionRepositoryProvider).loadSessions());

/// Asset path of the optional TensorFlow Lite ball detection model.
const ballModelAsset = 'assets/models/ball_detector.tflite';

/// The TensorFlow Lite model bytes, or null when no model is bundled, in
/// which case detection falls back to OpenCV motion detection.
/// Whether the phone is turning, from its gyroscope.
final deviceMotionProvider = Provider.autoDispose<DeviceMotion>((ref) {
  final motion = DeviceMotion();
  ref.onDispose(motion.dispose);
  return motion;
});

final ballModelProvider = FutureProvider<Uint8List?>((ref) async {
  try {
    final data = await rootBundle.load(ballModelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
});
