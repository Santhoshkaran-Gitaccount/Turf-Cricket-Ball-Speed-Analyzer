import 'package:hive_ce/hive_ce.dart';

/// The stumps tapped on the last setup, remembered so a phone left on its
/// tripod in the same place starts straight away next time. Tapping again
/// (after Reset) replaces them.
class PitchSetupStore {
  static const _boxName = 'pitch_setup';
  static const _key = 'stumps';

  /// The batting and bowling stumps taps, in reference coordinates, if saved.
  static Future<((double, double), (double, double))?> load() async {
    try {
      final box = await Hive.openBox<Map>(_boxName);
      final saved = box.get(_key);
      if (saved == null) return null;
      double at(String name) => (saved[name]! as num).toDouble();
      return ((at('bx'), at('by')), (at('fx'), at('fy')));
    } catch (_) {
      // Missing or unreadable: the stumps are tapped again.
      return null;
    }
  }

  static Future<void> save((double, double) batting, (double, double) bowling) async {
    try {
      final box = await Hive.openBox<Map>(_boxName);
      await box.put(_key, {'bx': batting.$1, 'by': batting.$2, 'fx': bowling.$1, 'fy': bowling.$2});
    } catch (_) {
      // Not remembering only means tapping again next time.
    }
  }

  static Future<void> forget() async {
    try {
      final box = await Hive.openBox<Map>(_boxName);
      await box.delete(_key);
    } catch (_) {}
  }
}
