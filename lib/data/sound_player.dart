import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Tells a bowler with nobody at the phone what happened, by sound: a beep
/// when the ball is picked up and the result spoken when it is in.
///
/// The system click is not used: on Android it follows the "touch sounds"
/// setting and is often silent.
class SoundPlayer {
  static const _beepAsset = 'sounds/ball_detected.wav';

  AudioPlayer? _player;
  Future<void>? _loading;
  FlutterTts? _tts;

  /// Loads the beep and starts the speech engine ahead of the first ball:
  /// loaded on first use, the beep came too late to match the ball.
  void warmUp() {
    _guard(() => _loadBeep());
    _guard(() async => _tts ??= FlutterTts());
  }

  Future<void> _loadBeep() => _loading ??= () async {
        // Low latency mode keeps the short sound decoded in memory.
        final player = _player = AudioPlayer();
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setPlayerMode(PlayerMode.lowLatency);
        await player.setSource(AssetSource(_beepAsset));
      }();

  void ballDetected() => _guard(() async {
        await _loadBeep();
        final player = _player!;
        await player.stop();
        await player.resume();
      });

  /// Speaks [text], cutting off anything still being said.
  void say(String text) => _guard(() async {
        final tts = _tts ??= FlutterTts();
        await tts.stop();
        await tts.speak(text);
      });

  void dispose() {
    _guard(() async => _player?.dispose());
    _guard(() async => _tts?.stop());
  }

  /// A missing plugin (tests) or a busy audio output must never stop tracking.
  void _guard(Future<void> Function() play) {
    runZonedGuarded(() => unawaited(play().catchError((Object _) {})), (_, _) {});
  }
}
