import 'dart:ffi' as ffi;
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../domain/detection/ball_detector.dart';
import '../../domain/detection/frame.dart';
import '../../domain/entities/session.dart';

/// Finds moving patches inside the watched pitch region with OpenCV: the
/// frame is differenced against the previous one, thresholded, pooled onto a
/// coarse grid and split into connected blobs. All pixel work runs natively.
///
/// Only the bounding box of the watched region is processed, and every
/// intermediate image is allocated once and reused, which roughly halves the
/// time per frame compared with processing whole frames into fresh images.
class OpenCvMotionDetector implements BallDetector {
  OpenCvMotionDetector({this.diffThreshold = 30, this.maxMovingFraction = 0.2});

  /// How much a pixel's brightness must change to count as motion. A tennis
  /// ball is bright against turf; a red leather ball is close to the turf's
  /// brightness, so it needs a more sensitive threshold to be seen at all.
  factory OpenCvMotionDetector.forBallType(BallType ballType) => OpenCvMotionDetector(
        diffThreshold: switch (ballType) {
          BallType.tennis => 30,
          BallType.synthetic => 25,
          BallType.leather => 18,
        },
      );

  final int diffThreshold;

  /// If more than this fraction of the watched region changes at once, the
  /// frame is skipped: that is an exposure change or camera shake, not a ball.
  final double maxMovingFraction;

  /// Grid cell size in pixels. A cell counts as moving if any pixel in it moved.
  static const cellSize = 4;

  /// Average brightness of the watched region outside which the pitch is
  /// considered not visible.
  static const _minMeanLuma = 25.0;
  static const _maxMeanLuma = 235.0;

  /// Below this average brightness the scene is dim: a ball reflects less
  /// light, so its brightness change is smaller and the threshold is lowered
  /// in proportion, down to [_minDimScale] of [diffThreshold].
  static const _dimLuma = 50.0;
  static const _minDimScale = 0.6;

  /// Nearly everything in view is still, so the average frame-to-frame change
  /// is the scene's noise (sensor grain in low light, shimmer on sunlit grass).
  /// The threshold is kept this many times above it, so noise is not motion.
  static const _noiseMultiplier = 4.0;

  FrameLayout? _layout;

  /// Bounding box of the watched region, in pixels and in grid cells.
  cv.Rect? _roi;
  int _roiCellX = 0;
  int _roiCellY = 0;
  (int, int) _roiGridSize = (0, 0);
  cv.Mat? _mask;
  int _watchedCells = 0;

  // Two native frame buffers used in turn, so the previous frame stays valid
  // without copying it.
  final List<ffi.Pointer<ffi.Uint8>> _buffers = [];
  int _bufferBytes = 0;
  int _current = 0;
  cv.Mat? _previous;

  /// Slowly updated picture of the still scene, for removing ghosts.
  cv.Mat? _background;

  /// Share of each new frame blended into [_background]: it follows about
  /// the last 20 frames.
  static const _backgroundRate = 0.05;

  // Reused outputs.
  final _small = cv.Mat.empty();
  final _diff = cv.Mat.empty();
  final _changed = cv.Mat.empty();
  final _backgroundDiff = cv.Mat.empty();
  final _foreground = cv.Mat.empty();
  final _pooled = cv.Mat.empty();
  final _anyChanged = cv.Mat.empty();
  final _moving = cv.Mat.empty();
  final _labels = cv.Mat.empty();
  final _stats = cv.Mat.empty();
  final _centroids = cv.Mat.empty();

  @override
  BallDetection detect(LumaFrame frame, FrameLayout layout) {
    if (layout != _layout) _configure(layout, frame);
    final roi = _roi;
    if (roi == null) return const BallDetection(FrameStatus.ok);

    final full = _wrap(frame);
    final luma = full.region(roi);
    full.dispose();

    cv.resize(luma, _roiGridSize, dst: _small, interpolation: cv.INTER_AREA);
    final mean = cv.mean(_small, mask: _mask).val1;
    final status = mean < _minMeanLuma
        ? FrameStatus.tooDark
        : mean > _maxMeanLuma
            ? FrameStatus.tooBright
            : FrameStatus.ok;

    final previous = _previous;
    _previous = luma;
    _current = 1 - _current;
    if (previous == null) return BallDetection(status);

    try {
      if (status != FrameStatus.ok) return BallDetection(status);

      cv.absDiff(luma, previous, dst: _diff);
      final baseThreshold = diffThreshold * (mean / _dimLuma).clamp(_minDimScale, 1.0);
      cv.threshold(_diff, baseThreshold, 255, cv.THRESH_BINARY, dst: _changed);
      // Whole-view change is judged per pixel, before the noise allowance:
      // a camera jolt or a lighting jump changes most pixels, while grain
      // changes only a few here and there.
      if (cv.countNonZero(_changed) > maxMovingFraction * roi.width * roi.height) {
        // The old background no longer matches the view; start a new one.
        _background?.dispose();
        _background = luma.clone();
        return const BallDetection(FrameStatus.cameraMoved);
      }
      final noiseFloor = cv.mean(_diff).val1 * _noiseMultiplier;
      final threshold = max(baseThreshold, noiseFloor);
      if (threshold > baseThreshold) {
        cv.threshold(_diff, threshold, 255, cv.THRESH_BINARY, dst: _changed);
      }
      _removeGhosts(luma, threshold);
      // Area pooling keeps a cell non-zero if any one of its pixels changed.
      cv.resize(_changed, _roiGridSize, dst: _pooled, interpolation: cv.INTER_AREA);
      cv.threshold(_pooled, 0, 255, cv.THRESH_BINARY, dst: _anyChanged);
      cv.bitwiseAND(_anyChanged, _mask!, dst: _moving);

      final movingCells = cv.countNonZero(_moving);
      if (movingCells > maxMovingFraction * _watchedCells) return const BallDetection(FrameStatus.cameraMoved);
      if (movingCells == 0) return const BallDetection(FrameStatus.ok);

      return BallDetection(FrameStatus.ok, _blobs(layout));
    } finally {
      previous.dispose();
    }
  }

  /// Frame differencing marks both where a moving ball is now and where it
  /// was a frame ago; the second is a "ghost" that shows only background.
  /// Keeping just the pixels that also differ from a slowly updated picture
  /// of the background leaves the ball where it is now.
  void _removeGhosts(cv.Mat luma, double threshold) {
    final background = _background;
    if (background == null) {
      _background = luma.clone();
      return;
    }
    cv.absDiff(luma, background, dst: _backgroundDiff);
    cv.threshold(_backgroundDiff, threshold, 255, cv.THRESH_BINARY, dst: _foreground);
    cv.bitwiseAND(_changed, _foreground, dst: _changed);
    // A ball crosses any one spot in a frame or two, so it barely enters the
    // background, while a bowler standing still or a slow change of light does.
    cv.addWeighted(background, 1 - _backgroundRate, luma, _backgroundRate, 0, dst: background);
  }

  List<MotionBlob> _blobs(FrameLayout layout) {
    final count = cv.connectedComponentsWithStats(
      _moving,
      _labels,
      _stats,
      _centroids,
      8,
      cv.MatType.CV_32S,
      cv.CCL_DEFAULT,
    );

    final blobs = <MotionBlob>[];
    // Label 0 is the background.
    for (var i = 1; i < count; i++) {
      final (x, y) = layout.toReference(
        (_roiCellX + _centroids.at<double>(i, 0) + 0.5) * cellSize,
        (_roiCellY + _centroids.at<double>(i, 1) + 0.5) * cellSize,
      );
      blobs.add(MotionBlob(x, y, _stats.at<int>(i, cv.CC_STAT_AREA)));
    }
    return blobs;
  }

  void _configure(FrameLayout layout, LumaFrame frame) {
    _layout = layout;
    final gridW = layout.width ~/ cellSize;
    final gridH = layout.height ~/ cellSize;
    final mask = layout.watchedMask(cellSize);

    // Bounding box of the watched cells.
    var minX = gridW, minY = gridH, maxX = -1, maxY = -1;
    for (var gy = 0; gy < gridH; gy++) {
      for (var gx = 0; gx < gridW; gx++) {
        if (mask[gy * gridW + gx] == 0) continue;
        if (gx < minX) minX = gx;
        if (gx > maxX) maxX = gx;
        if (gy < minY) minY = gy;
        if (gy > maxY) maxY = gy;
      }
    }

    _mask?.dispose();
    _mask = null;
    _roi = null;
    if (maxX >= 0) {
      final cols = maxX - minX + 1;
      final rows = maxY - minY + 1;
      _roiCellX = minX;
      _roiCellY = minY;
      _roiGridSize = (cols, rows);
      _roi = cv.Rect(minX * cellSize, minY * cellSize, cols * cellSize, rows * cellSize);
      _mask = cv.Mat.fromList(rows, cols, cv.MatType.CV_8UC1, [
        for (var gy = minY; gy <= maxY; gy++) ...mask.sublist(gy * gridW + minX, gy * gridW + maxX + 1),
      ]);
      _watchedCells = mask.where((b) => b != 0).length;
    }

    final bytes = frame.bytesPerRow * frame.height;
    if (bytes != _bufferBytes) {
      _freeBuffers();
      _buffers.addAll([calloc<ffi.Uint8>(bytes), calloc<ffi.Uint8>(bytes)]);
      _bufferBytes = bytes;
    }
    reset();
  }

  /// Copies the frame into the next native buffer and wraps it as a Mat.
  cv.Mat _wrap(LumaFrame frame) {
    final buffer = _buffers[_current];
    buffer.asTypedList(_bufferBytes).setRange(0, frame.bytes.length, frame.bytes);
    return cv.Mat.fromBuffer(frame.height, frame.bytesPerRow, cv.MatType.CV_8UC1, buffer.cast());
  }

  @override
  void reset() {
    _previous?.dispose();
    _previous = null;
    _background?.dispose();
    _background = null;
  }

  void _freeBuffers() {
    reset();
    for (final buffer in _buffers) {
      calloc.free(buffer);
    }
    _buffers.clear();
    _bufferBytes = 0;
  }

  @override
  void dispose() {
    _freeBuffers();
    _mask?.dispose();
    _mask = null;
    _layout = null;
    for (final mat in [_small, _diff, _changed, _backgroundDiff, _foreground, _pooled, _anyChanged, _moving, _labels, _stats, _centroids]) {
      mat.dispose();
    }
  }
}
