import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Diagnostics written to a file on the phone as well as the device log, so
/// a session played with the phone unplugged can be looked at afterwards:
///
///   adb pull /sdcard/Android/data/com.gokoala.turf_cricket_ball_speed_analyzer/files/speed_log.txt
///
/// Writing never stops tracking: if the file cannot be opened, lines go to
/// the device log only.
class FieldLog {
  FieldLog._();

  static const fileName = 'speed_log.txt';

  /// A file past this size is started afresh.
  static const _maxBytes = 5 * 1024 * 1024;

  static IOSink? _sink;
  static Future<void>? _opening;

  static void write(String message) {
    debugPrint('[speed] $message');
    final line = '${DateTime.now().toIso8601String()} $message\n';
    final sink = _sink;
    if (sink != null) {
      sink.write(line);
      return;
    }
    // Lines written while the file is opening follow once it is open.
    _opening ??= _open();
    unawaited(_opening!.then((_) => _sink?.write(line)));
  }

  static Future<void> _open() async {
    try {
      final dir = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
          await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$fileName');
      final tooBig = await file.exists() && await file.length() > _maxBytes;
      _sink = file.openWrite(mode: tooBig ? FileMode.write : FileMode.append);
    } catch (error) {
      debugPrint('[speed] log file unavailable: $error');
    }
  }
}
