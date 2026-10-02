/// Maps between the upright camera image, the screen, and the reference view
/// that [PitchGeometry] is defined in.
///
/// The reference view is the screen as it looks with the phone held in
/// landscape. The detector works in reference coordinates, so pitch zones and
/// tracking limits are the same whichever way the phone is held. In portrait
/// the camera sees the same scene with its long side vertical: less to either
/// side, more above and below.
///
/// Every mapping here is linear per axis, so rectangles stay rectangles and
/// straight lines stay straight.
class ViewTransform {
  const ViewTransform({required this.imageAspect, this.screenAspect});

  /// Upright camera image width / height; below 1 when the phone is in portrait.
  final double imageAspect;

  /// Screen width / height. Null means the screen shows the whole image.
  final double? screenAspect;

  bool get portrait => imageAspect < 1;

  double get _landscapeImageAspect => portrait ? 1 / imageAspect : imageAspect;

  /// The same screen turned to landscape.
  double get _landscapeScreenAspect {
    final screen = screenAspect ?? imageAspect;
    return portrait ? 1 / screen : screen;
  }

  /// Upright image coordinates (0–1) to reference coordinates.
  (double, double) imageToReference(double u, double v) {
    if (portrait) (u, v) = _portraitToLandscapeImage(u, v);
    return _cover(u, v, _landscapeImageAspect, _landscapeScreenAspect);
  }

  /// Reference coordinates to coordinates on the current screen, for drawing.
  (double, double) referenceToScreen(double x, double y) {
    if (!portrait) return (x, y);
    final ia = _landscapeImageAspect;
    final (u, v) = _uncover(x, y, ia, _landscapeScreenAspect);
    final (pu, pv) = (0.5 + (u - 0.5) * ia, 0.5 + (v - 0.5) / ia);
    return _cover(pu, pv, imageAspect, screenAspect ?? imageAspect);
  }

  /// Coordinates on the current screen to reference coordinates, e.g. for a tap.
  (double, double) screenToReference(double x, double y) {
    if (!portrait) return (x, y);
    final (pu, pv) = _uncover(x, y, imageAspect, screenAspect ?? imageAspect);
    return imageToReference(pu, pv);
  }

  /// Coordinates on the current screen to upright image coordinates, e.g. to
  /// point the camera's focus at a tap.
  (double, double) screenToImage(double x, double y) =>
      _uncover(x, y, imageAspect, screenAspect ?? imageAspect);

  /// A scene direction keeps its angle from the centre; in portrait the image's
  /// width spans the camera's narrow field of view and its height the wide one.
  (double, double) _portraitToLandscapeImage(double u, double v) {
    final ia = _landscapeImageAspect;
    return (0.5 + (u - 0.5) / ia, 0.5 + (v - 0.5) * ia);
  }

  /// Image to screen coordinates when the image fills the screen with
  /// BoxFit.cover, cropping whichever dimension overflows.
  static (double, double) _cover(double u, double v, double imageAspect, double screenAspect) {
    if (screenAspect >= imageAspect) {
      // Screen is wider: the top and bottom of the image are cropped.
      return (u, 0.5 + (v - 0.5) * screenAspect / imageAspect);
    }
    // Screen is narrower: the sides of the image are cropped.
    return (0.5 + (u - 0.5) * imageAspect / screenAspect, v);
  }

  static (double, double) _uncover(double x, double y, double imageAspect, double screenAspect) {
    if (screenAspect >= imageAspect) return (x, 0.5 + (y - 0.5) * imageAspect / screenAspect);
    return (0.5 + (x - 0.5) * screenAspect / imageAspect, y);
  }
}
