import 'dart:typed_data';

import 'pitch_geometry.dart';
import 'view_transform.dart';

/// The brightness (Y) plane of one camera frame.
class LumaFrame {
  const LumaFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.timestampMicros,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final int timestampMicros;
}

/// Whether a frame could be used to look for the ball.
enum FrameStatus {
  ok,

  /// Most of the watched region changed at once: the camera moved or the
  /// lighting jumped.
  cameraMoved,

  /// The watched region is too dark (or the lens is covered) to see a ball.
  tooDark,

  /// The watched region is washed out.
  tooBright,
}

/// Something ball-like found in a frame.
class MotionBlob {
  const MotionBlob(this.x, this.y, this.area);

  /// Centre in normalized reference coordinates (see [ViewTransform]).
  final double x;
  final double y;

  /// Size in 4×4-pixel cells.
  final int area;
}

/// What a [BallDetector] found in one frame.
class BallDetection {
  const BallDetection(this.status, [this.blobs = const []]);

  final FrameStatus status;
  final List<MotionBlob> blobs;
}

/// How camera image pixels map to the reference view the pitch zones are
/// defined in (see [ViewTransform]).
///
/// The sensor image arrives in the sensor's own orientation and is rotated by
/// [rotationDegrees] clockwise to be upright on screen. The preview then fills
/// the screen with BoxFit.cover, cropping part of the image.
class FrameLayout {
  const FrameLayout({
    required this.width,
    required this.height,
    this.rotationDegrees = 0,
    this.screenAspect,
    this.geometry = PitchGeometry.standard,
  });

  final int width;
  final int height;

  /// 0, 90, 180 or 270: 0 and 180 in landscape, 90 and 270 in portrait.
  final int rotationDegrees;

  /// Screen width / height. Null means no cropping.
  final double? screenAspect;

  /// Where the pitch is in the reference view.
  final PitchGeometry geometry;

  ViewTransform get view => ViewTransform(
        imageAspect: rotationDegrees % 180 == 0 ? width / height : height / width,
        screenAspect: screenAspect,
      );

  /// Maps an image pixel position to normalized reference coordinates.
  (double, double) toReference(double px, double py) {
    final u = px / width;
    final v = py / height;
    // Clockwise rotation to upright.
    final (uprightU, uprightV) = switch (rotationDegrees) {
      90 => (1 - v, u),
      180 => (1 - u, 1 - v),
      270 => (v, 1 - u),
      _ => (u, v),
    };
    return view.imageToReference(uprightU, uprightV);
  }

  /// One byte per [cellSize]-pixel cell: 255 where the cell's centre is inside
  /// the region watched for the ball, 0 elsewhere.
  Uint8List watchedMask(int cellSize) {
    final gridW = width ~/ cellSize;
    final gridH = height ~/ cellSize;
    final mask = Uint8List(gridW * gridH);
    for (var gy = 0; gy < gridH; gy++) {
      for (var gx = 0; gx < gridW; gx++) {
        final (x, y) = toReference((gx + 0.5) * cellSize, (gy + 0.5) * cellSize);
        if (geometry.isWatched(x, y)) mask[gy * gridW + gx] = 255;
      }
    }
    return mask;
  }

  @override
  bool operator ==(Object other) =>
      other is FrameLayout &&
      other.width == width &&
      other.height == height &&
      other.rotationDegrees == rotationDegrees &&
      other.screenAspect == screenAspect &&
      other.geometry == geometry;

  @override
  int get hashCode => Object.hash(width, height, rotationDegrees, screenAspect, geometry);
}
