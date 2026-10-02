import 'package:flutter/material.dart';

import '../../domain/detection/pitch_geometry.dart';
import '../../domain/detection/view_transform.dart';

/// Alignment guides drawn over the camera preview from a [PitchGeometry]:
/// the standard guide to line the camera up with, or the pitch fitted to the
/// stumps the user tapped. The camera sits behind the batting stumps, so they
/// appear large near the bottom and the bowling stumps small near the middle.
///
/// Guides are defined in the reference view and mapped through [view], so in
/// portrait they cover the same part of the scene the detector watches.
class PitchGuideOverlay extends StatelessWidget {
  const PitchGuideOverlay({
    super.key,
    required this.color,
    this.geometry = PitchGeometry.standard,
    this.view,
    this.marker,
  });

  final Color color;
  final PitchGeometry geometry;

  /// Null draws the reference view as is (landscape).
  final ViewTransform? view;

  /// A tapped point still waiting for its partner, in reference coordinates.
  final (double, double)? marker;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _PitchGuidePainter(color, geometry, view, marker),
        size: Size.infinite,
      ),
    );
  }
}

class _PitchGuidePainter extends CustomPainter {
  _PitchGuidePainter(this.color, this.geometry, this.view, this.marker);

  final Color color;
  final PitchGeometry geometry;
  final ViewTransform? view;
  final (double, double)? marker;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = color.withValues(alpha: 0.12);

    Offset at(double x, double y) {
      final (sx, sy) = view?.referenceToScreen(x, y) ?? (x, y);
      return Offset(sx * size.width, sy * size.height);
    }

    final g = geometry;
    final corners = [
      at(g.nearCenterX - g.nearHalfWidth, g.nearY),
      at(g.farCenterX - g.farHalfWidth, g.farY),
      at(g.farCenterX + g.farHalfWidth, g.farY),
      at(g.nearCenterX + g.nearHalfWidth, g.nearY),
    ];
    final pitch = Path()..addPolygon(corners, true);
    canvas.drawPath(pitch, fill);
    canvas.drawPath(pitch, line);

    Rect box((double, double, double, double) r) => Rect.fromPoints(at(r.$1, r.$2), at(r.$3, r.$4));
    _drawStumps(canvas, box(g.battingStumps), line, 'Batting stumps');
    _drawStumps(canvas, box(g.bowlingStumps), line, 'Bowling stumps');

    if (marker case (final x, final y)) {
      final centre = at(x, y);
      final ring = Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas
        ..drawCircle(centre, 22, ring)
        ..drawCircle(centre, 4, Paint()..color = Colors.yellowAccent);
    }
  }

  void _drawStumps(Canvas canvas, Rect rect, Paint paint, String label) {
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), paint..strokeWidth = 2);

    final text = TextPainter(
      text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(rect.right + 8, rect.center.dy - text.height / 2));
  }

  @override
  bool shouldRepaint(_PitchGuidePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.geometry != geometry ||
      oldDelegate.marker != marker ||
      oldDelegate.view?.imageAspect != view?.imageAspect ||
      oldDelegate.view?.screenAspect != view?.screenAspect;
}
