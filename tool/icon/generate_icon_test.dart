// Draws the app logo in the app theme's colours and writes it to assets/icon/.
//
// Run with: flutter test tool/icon/generate_icon_test.dart
// then:     dart run flutter_launcher_icons && dart run flutter_native_splash:create
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turf_cricket_ball_speed_analyzer/app.dart';

const _size = 1024.0;

void main() {
  testWidgets('generate app logo', (tester) async {
    final colors = BallSpeedApp.colorScheme;

    await tester.runAsync(() async {
      Directory('assets/icon').createSync(recursive: true);
      // Launcher icon for iOS and older Android: logo on the theme background.
      await _write('assets/icon/app_icon.png', colors, background: true, scale: 1.2);
      // Android adaptive icon and splash: launchers show the centre ~2/3, so
      // this fills most of that.
      await _write('assets/icon/app_icon_foreground.png', colors, background: false, scale: 0.85);
      // In-app logo on a transparent background.
      await _write('assets/icon/logo.png', colors, background: false, scale: 1);
    });

    // The native config (pubspec.yaml) must use these exact background colours.
    String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    // ignore: avoid_print
    print('surface: ${hex(colors.surface)}  primary: ${hex(colors.primary)}');
  });
}

Future<void> _write(String path, ColorScheme colors, {required bool background, required double scale}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _size, _size));
  if (background) _paintBackground(canvas, colors);
  canvas
    ..translate(_size / 2, _size / 2)
    ..scale(scale)
    ..translate(-_size / 2, -_size / 2);
  _paintLogo(canvas, colors);

  final image = await recorder.endRecording().toImage(_size.toInt(), _size.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
}

void _paintBackground(Canvas canvas, ColorScheme colors) {
  canvas.drawRect(const Rect.fromLTWH(0, 0, _size, _size), Paint()..color = colors.surface);
}

/// A flat cricket ball in flight: one colour, a simple seam and three speed
/// lines, so it stays clear at launcher-icon size.
void _paintLogo(Canvas canvas, ColorScheme colors) {
  const ballCenter = Offset(663, 512);
  const ballRadius = 230.0;

  // Speed lines, longest in the middle.
  final line = Paint()
    ..strokeCap = StrokeCap.round
    ..color = colors.primary;
  for (final (dy, length, width, alpha) in [
    (-120.0, 150.0, 40.0, 0.45),
    (0.0, 230.0, 48.0, 1.0),
    (120.0, 150.0, 40.0, 0.45),
  ]) {
    final right = ballCenter.dx - sqrt(ballRadius * ballRadius - dy * dy) - 48;
    canvas.drawLine(
      Offset(right - length, ballCenter.dy + dy),
      Offset(right, ballCenter.dy + dy),
      line
        ..strokeWidth = width
        ..color = colors.primary.withValues(alpha: alpha),
    );
  }

  // The ball.
  canvas.drawCircle(ballCenter, ballRadius, Paint()..color = colors.primary);

  // Seam: two parallel curves in the background colour.
  final ballRect = Rect.fromCircle(center: ballCenter, radius: ballRadius);
  final seam = Paint()
    ..color = colors.surface
    ..style = PaintingStyle.stroke
    ..strokeWidth = 18
    ..strokeCap = StrokeCap.round;
  canvas
    ..save()
    ..clipPath(Path()..addOval(ballRect))
    ..translate(ballCenter.dx, ballCenter.dy)
    ..rotate(-0.55);
  for (final offset in [-30.0, 30.0]) {
    canvas.drawPath(
      Path()
        ..moveTo(offset - 80, -ballRadius - 20)
        ..quadraticBezierTo(offset + 70, 0, offset - 80, ballRadius + 20),
      seam,
    );
  }
  canvas.restore();
}
