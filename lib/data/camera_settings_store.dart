import 'package:camera/camera.dart';
import 'package:hive_ce/hive_ce.dart';

/// The camera setting measured to give the highest frame rate on this phone,
/// remembered so the camera opens straight away next time instead of trying
/// every setting again.
class CameraSettingsStore {
  static const _boxName = 'camera_settings';

  /// Remembered (resolution, requested FPS, measured FPS) for [cameraName], if any.
  static Future<(ResolutionPreset, int, double)?> load(String cameraName) async {
    try {
      final box = await Hive.openBox<Map>(_boxName);
      final saved = box.get(cameraName);
      if (saved == null) return null;
      return (
        ResolutionPreset.values.byName(saved['preset']! as String),
        saved['fps']! as int,
        (saved['measured']! as num).toDouble(),
      );
    } catch (_) {
      // Missing or unreadable: the camera is measured again.
      return null;
    }
  }

  static Future<void> save(String cameraName, (ResolutionPreset, int) config, double measuredFps) async {
    try {
      final box = await Hive.openBox<Map>(_boxName);
      await box.put(cameraName, {'preset': config.$1.name, 'fps': config.$2, 'measured': measuredFps});
    } catch (_) {
      // Not remembering only means measuring again next time.
    }
  }

  static Future<void> forget(String cameraName) async {
    try {
      final box = await Hive.openBox<Map>(_boxName);
      await box.delete(cameraName);
    } catch (_) {}
  }
}
