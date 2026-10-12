import 'dart:math';

/// Where the pitch sits in the reference view (see ViewTransform), in
/// normalized coordinates (0–1, origin top-left).
///
/// The alignment guides are drawn from this and delivery detection watches the
/// same zones, so what the user lines up is what the detector sees.
///
/// [standard] models a phone about 2 m behind the batting stumps at roughly
/// waist height: the pitch narrows about 10x from the batting end to the
/// bowling end, and anything at the bowler's end appears above [farY]. Tapping
/// the two sets of stumps on screen fits it to the real pitch
/// ([PitchGeometry.fromStumps]).
class PitchGeometry {
  const PitchGeometry._({
    required this.farY,
    required this.nearY,
    required this.farHalfWidth,
    required this.nearHalfWidth,
    required this.releaseTopY,
    required this.releaseHalfWidth,
    required this.batsmanZoneTopY,
    required this.farCenterX,
    required this.nearCenterX,
    required this.scale,
  });

  static const standard = PitchGeometry._(
    farY: 0.35,
    nearY: 0.95,
    farHalfWidth: 0.03,
    nearHalfWidth: 0.30,
    releaseTopY: 0.10,
    // Wide enough for a bowler going round the wicket or wide of the crease.
    releaseHalfWidth: 0.16,
    batsmanZoneTopY: 0.47,
    farCenterX: 0.5,
    nearCenterX: 0.5,
    scale: 1,
  );

  // Size of the stump boxes in the standard view, relative to their base.
  static const _nearStumpsHeight = 0.30;
  static const _nearStumpsHalfWidth = 0.0225;
  static const _farStumpsHeight = 0.06;
  static const _farStumpsHalfWidth = 0.008;

  /// Fits the standard pitch to where the user tapped the middle of the
  /// batting stumps (near, lower on screen) and the bowling stumps (far).
  ///
  /// The whole shape is stretched and shifted so both stump boxes land on the
  /// taps, and the pitch runs along the line between them. Returns null if the
  /// taps cannot be a pitch seen from behind the batting stumps.
  static PitchGeometry? fromStumps({
    required (double, double) batting,
    required (double, double) bowling,
  }) {
    final (bx, by) = batting;
    final (fx, fy) = bowling;
    const s = standard;
    final standardNear = s.nearY - _nearStumpsHeight / 2;
    final standardFar = s.farY - _farStumpsHeight / 2;

    final scale = (by - fy) / (standardNear - standardFar);
    // Bowling stumps must be clearly above the batting stumps, and roughly
    // above them rather than off to one side.
    if (scale < 0.25 || scale > 2.5) return null;
    if ((bx - fx).abs() > (by - fy) * 1.5) return null;

    double y(double standardY) => by + (standardY - standardNear) * scale;
    final farY = y(s.farY);
    final nearY = y(s.nearY);
    // Pitch centre line through both taps.
    double centerAt(double atY) => fx + (bx - fx) * (atY - fy) / (by - fy);

    return PitchGeometry._(
      farY: farY,
      nearY: nearY,
      farHalfWidth: s.farHalfWidth * scale,
      nearHalfWidth: s.nearHalfWidth * scale,
      releaseTopY: y(s.releaseTopY),
      releaseHalfWidth: s.releaseHalfWidth * scale,
      batsmanZoneTopY: y(s.batsmanZoneTopY),
      farCenterX: centerAt(farY),
      nearCenterX: centerAt(nearY),
      scale: scale,
    );
  }

  /// Base of the bowling stumps.
  final double farY;

  /// Base of the batting stumps.
  final double nearY;

  final double farHalfWidth;
  final double nearHalfWidth;

  /// The release zone is a corridor above the bowling stumps, where the ball
  /// leaves the bowler's hand.
  final double releaseTopY;
  final double releaseHalfWidth;

  /// Top of the batsman / keeper area at the near end.
  final double batsmanZoneTopY;

  /// Pitch centre line at the bowling and batting ends.
  final double farCenterX;
  final double nearCenterX;

  /// How much larger than [standard] the pitch appears.
  final double scale;

  double get releaseBottomY => farY + 0.07 * scale;

  /// A ball bowled leaves the hand about 2 m up, nearly three times the
  /// height of the stumps, so seen at the bowler's end it rises above this
  /// line, one and a half stump heights over the bowling stumps' base. A
  /// ball carried at waist height (walked down the pitch, or moved about
  /// near the phone) stays below it: low down near the camera it shows on
  /// screen where a ball released at the far end does, but never this high.
  double get releaseHeightY => farY - _farStumpsHeight * scale * 1.5;

  /// A ball tracked past this line has left the bowler's end. The bowler's
  /// body never gets this far down the screen, so it confirms a real delivery.
  double get inFlightY => farY + 0.10 * scale;

  double _along(double y) => (y - farY) / (nearY - farY);

  double centerXAt(double y) => farCenterX + (nearCenterX - farCenterX) * _along(y);

  double halfWidthAt(double y) => farHalfWidth + (nearHalfWidth - farHalfWidth) * _along(y);

  /// The region watched for the ball: the release corridor, then the air above
  /// the pitch widening toward the batsman.
  ///
  /// The pitch outline is where the ground is; a ball in the air near the
  /// batsman is higher on screen than the ground beneath it, where the pitch
  /// looks narrow, so a ball going wide there would leave the outline. The
  /// watched width therefore reaches the full width of the batting end by
  /// [batsmanZoneTopY].
  ///
  /// It reaches twice as far either side as the pitch does, so a ball going
  /// well wide, or a pitch tapped a little off, is still seen.
  bool isWatched(double x, double y) {
    if (y < releaseTopY) return isAboveReleaseZone(x, y);
    if (y > watchedBottomY) return false;
    return (x - centerXAt(y)).abs() <= watchedHalfWidthAt(y);
  }

  /// Lowest point on screen watched for the ball, just below the batting stumps.
  double get watchedBottomY => nearY + 0.12 * scale;

  /// Half the width of the watched region at height [y], from the top of the
  /// release corridor down to [watchedBottomY].
  double watchedHalfWidthAt(double y) {
    if (y < farY) return releaseHalfWidth;
    final towardBatsman = ((y - farY) / (batsmanZoneTopY - farY)).clamp(0.0, 1.0);
    final airHalfWidth = releaseHalfWidth + (nearHalfWidth * _watchedWidening - releaseHalfWidth) * towardBatsman;
    return max(airHalfWidth, halfWidthAt(y) * _watchedWidening);
  }

  static const _watchedWidening = 2.0;

  bool isReleaseZone(double x, double y) =>
      y >= releaseTopY && y <= releaseBottomY && (x - centerXAt(y)).abs() <= releaseHalfWidth;

  /// The corridor above the release zone, higher than a bowler releases the
  /// ball. A ball seen here first and dropping down the pitch was thrown in
  /// from elsewhere (back from the batsman's end), not bowled.
  bool isAboveReleaseZone(double x, double y) => y < releaseTopY && (x - centerXAt(y)).abs() <= releaseHalfWidth;

  bool isBatsmanZone(double y) => y >= batsmanZoneTopY;

  /// The line a ball crosses on reaching the batting stumps.
  double get stumpsLineY => nearY - 0.05 * scale;

  bool reachedStumps(double y) => y >= stumpsLineY;

  /// Outline of the batting stumps, as (left, top, right, bottom).
  (double, double, double, double) get battingStumps =>
      _stumps(nearY, _nearStumpsHeight * scale, _nearStumpsHalfWidth * scale);

  /// Outline of the bowling stumps, as (left, top, right, bottom).
  (double, double, double, double) get bowlingStumps =>
      _stumps(farY, _farStumpsHeight * scale, _farStumpsHalfWidth * scale);

  /// Stumps standing on [baseY], centred on the pitch line at half their
  /// height, which is where the user taps them.
  (double, double, double, double) _stumps(double baseY, double height, double halfWidth) {
    final x = centerXAt(baseY - height / 2);
    return (x - halfWidth, baseY - height, x + halfWidth, baseY);
  }

  @override
  bool operator ==(Object other) =>
      other is PitchGeometry &&
      other.farY == farY &&
      other.nearY == nearY &&
      other.farHalfWidth == farHalfWidth &&
      other.nearHalfWidth == nearHalfWidth &&
      other.releaseTopY == releaseTopY &&
      other.releaseHalfWidth == releaseHalfWidth &&
      other.batsmanZoneTopY == batsmanZoneTopY &&
      other.farCenterX == farCenterX &&
      other.nearCenterX == nearCenterX &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(
        farY,
        nearY,
        farHalfWidth,
        nearHalfWidth,
        releaseTopY,
        releaseHalfWidth,
        batsmanZoneTopY,
        farCenterX,
        nearCenterX,
        scale,
      );
}
