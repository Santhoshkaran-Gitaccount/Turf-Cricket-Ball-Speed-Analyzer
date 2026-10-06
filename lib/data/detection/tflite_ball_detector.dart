import 'dart:math';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import '../../domain/detection/ball_detector.dart';
import '../../domain/detection/frame.dart';
import 'opencv_motion_detector.dart';

/// Where the model's input image sits in the camera frame: the model sees
/// the box from ([left], [top]) spanning [width] × [height] frame pixels
/// (padding included), scaled to its input size.
class ModelWindow {
  const ModelWindow(this.left, this.top, this.width, this.height);

  /// The whole frame, stretched to the model's input.
  factory ModelWindow.fullFrame(FrameLayout layout) =>
      ModelWindow(0, 0, layout.width.toDouble(), layout.height.toDouble());

  final double left;
  final double top;
  final double width;
  final double height;
}

/// Finds the ball with an on-device TensorFlow Lite object detection model.
///
/// Model contract (see assets/models/README.md):
/// - input `[1, H, W, C]`, grayscale replicated to C channels (1 or 3),
///   float32 scaled to 0–1 or uint8 0–255;
/// - output `[1, N, 5]` rows of `(cx, cy, w, h, score)`, or `[1, 5, N]` as
///   exported by YOLO, float32, boxes normalized to the input image (pixel
///   boxes are recognised and normalized).
///
/// Only the watched part of the frame is given to the model, letterboxed to
/// its input: a ball at the far end is a few pixels across, and shrinking the
/// whole frame would leave nothing of it.
///
/// Frame status (too dark, camera moved) still comes from [OpenCvMotionDetector],
/// since a single frame cannot show that the camera moved.
class TfliteBallDetector implements BallDetector {
  TfliteBallDetector(this._interpreter, this._motion, {this.minScore = 0.5}) {
    final input = _interpreter.getInputTensor(0);
    final [_, height, width, channels] = input.shape;
    _inputHeight = height;
    _inputWidth = width;
    _inputChannels = channels;
    _inputIsFloat = input.type == TensorType.float32;
    final outputShape = _interpreter.getOutputTensor(0).shape;
    _channelsFirst = outputShape.length == 3 && outputShape[1] == 5 && outputShape[2] != 5;
  }

  factory TfliteBallDetector.fromModel(Uint8List modelBytes, OpenCvMotionDetector motion) =>
      TfliteBallDetector(Interpreter.fromBuffer(modelBytes, options: InterpreterOptions()..threads = 4), motion);

  final Interpreter _interpreter;
  final OpenCvMotionDetector _motion;
  final double minScore;

  late final int _inputWidth;
  late final int _inputHeight;
  late final int _inputChannels;
  late final bool _inputIsFloat;
  late final bool _channelsFirst;

  /// Grey used for letterbox padding, as in YOLO training.
  static const _padLuma = 114;

  /// Overlapping boxes above this intersection-over-union are one ball.
  static const _nmsIou = 0.45;

  FrameLayout? _layout;
  (int, int, int, int)? _crop;

  @override
  BallDetection detect(LumaFrame frame, FrameLayout layout) {
    final status = _motion.detect(frame, layout).status;
    if (status != FrameStatus.ok) return BallDetection(status);

    if (layout != _layout) {
      _layout = layout;
      _crop = watchedBounds(layout, OpenCvMotionDetector.cellSize);
    }
    final crop = _crop;
    if (crop == null) return BallDetection(status);

    final (input, window) = _input(frame, crop);
    _interpreter.getInputTensor(0).data = input;
    _interpreter.invoke();
    final output = Float32List.sublistView(Uint8List.fromList(_interpreter.getOutputTensor(0).data));
    final rows = _channelsFirst ? transposeChannelsFirst(output, 5) : output;
    return BallDetection(
      status,
      parseDetections(rows, layout, minScore: minScore, window: window, inputSize: (_inputWidth, _inputHeight)),
    );
  }

  /// Pixel bounds (left, top, right, bottom) of the watched region, or null
  /// if nothing is watched.
  static (int, int, int, int)? watchedBounds(FrameLayout layout, int cellSize) {
    final mask = layout.watchedMask(cellSize);
    final gridW = layout.width ~/ cellSize;
    final gridH = layout.height ~/ cellSize;
    var minX = gridW, minY = gridH, maxX = -1, maxY = -1;
    for (var gy = 0; gy < gridH; gy++) {
      for (var gx = 0; gx < gridW; gx++) {
        if (mask[gy * gridW + gx] == 0) continue;
        minX = min(minX, gx);
        maxX = max(maxX, gx);
        minY = min(minY, gy);
        maxY = max(maxY, gy);
      }
    }
    if (maxX < 0) return null;
    return (minX * cellSize, minY * cellSize, (maxX + 1) * cellSize, (maxY + 1) * cellSize);
  }

  /// The watched region, letterboxed (scaled evenly, padded at the right and
  /// bottom) to the model's input, and where that input lies in the frame.
  (Uint8List, ModelWindow) _input(LumaFrame frame, (int, int, int, int) crop) {
    final (left, top, right, bottom) = crop;
    final scale = min(_inputWidth / (right - left), _inputHeight / (bottom - top));
    final bytes = Uint8List(_inputWidth * _inputHeight * _inputChannels)..fillRange(0, _inputWidth * _inputHeight * _inputChannels, _padLuma);
    final usedW = min(_inputWidth, ((right - left) * scale).floor());
    final usedH = min(_inputHeight, ((bottom - top) * scale).floor());
    for (var y = 0; y < usedH; y++) {
      final row = (top + y / scale).floor().clamp(0, frame.height - 1) * frame.bytesPerRow;
      var i = y * _inputWidth * _inputChannels;
      for (var x = 0; x < usedW; x++) {
        final luma = frame.bytes[row + (left + x / scale).floor().clamp(0, frame.width - 1)];
        for (var c = 0; c < _inputChannels; c++) {
          bytes[i++] = luma;
        }
      }
    }
    final window = ModelWindow(left.toDouble(), top.toDouble(), _inputWidth / scale, _inputHeight / scale);
    if (!_inputIsFloat) return (bytes, window);
    final floats = Float32List(bytes.length);
    for (var j = 0; j < bytes.length; j++) {
      floats[j] = bytes[j] / 255;
    }
    return (floats.buffer.asUint8List(), window);
  }

  /// YOLO exports `[1, 5, N]`: all cx, then all cy, and so on. Returns `[N, 5]` rows.
  static Float32List transposeChannelsFirst(Float32List values, int channels) {
    final n = values.length ~/ channels;
    final rows = Float32List(values.length);
    for (var c = 0; c < channels; c++) {
      for (var i = 0; i < n; i++) {
        rows[i * channels + c] = values[c * n + i];
      }
    }
    return rows;
  }

  /// Turns raw `(cx, cy, w, h, score)` rows into blobs in screen coordinates,
  /// keeping confident detections inside the watched pitch region and one
  /// box per ball. [window] places the model's input in the frame; by default
  /// it is the whole frame. Boxes given in input pixels rather than 0–1 are
  /// normalized by [inputSize].
  static List<MotionBlob> parseDetections(
    Float32List rows,
    FrameLayout layout, {
    double minScore = 0.5,
    ModelWindow? window,
    (int, int) inputSize = (1, 1),
  }) {
    final w = window ?? ModelWindow.fullFrame(layout);
    // Boxes in frame pixels: (left, top, right, bottom, score).
    final boxes = <(double, double, double, double, double)>[];
    for (var i = 0; i + 4 < rows.length; i += 5) {
      final score = rows[i + 4];
      if (score < minScore) continue;
      var (cx, cy, bw, bh) = (rows[i], rows[i + 1], rows[i + 2], rows[i + 3]);
      if (cx > 1.5 || cy > 1.5) {
        final (inputW, inputH) = inputSize;
        (cx, cy, bw, bh) = (cx / inputW, cy / inputH, bw / inputW, bh / inputH);
      }
      final x = w.left + cx * w.width;
      final y = w.top + cy * w.height;
      boxes.add((x - bw * w.width / 2, y - bh * w.height / 2, x + bw * w.width / 2, y + bh * w.height / 2, score));
    }
    boxes.sort((a, b) => b.$5.compareTo(a.$5));

    final kept = <(double, double, double, double, double)>[];
    for (final box in boxes) {
      if (kept.every((k) => _iou(k, box) <= _nmsIou)) kept.add(box);
    }

    final blobs = <MotionBlob>[];
    const cell = OpenCvMotionDetector.cellSize;
    for (final (l, t, r, b, _) in kept) {
      final (x, y) = layout.toReference((l + r) / 2, (t + b) / 2);
      if (!layout.geometry.isWatched(x, y)) continue;
      final (x0, y0) = layout.toReference(l, t);
      final (x1, y1) = layout.toReference(r, b);
      final radius = sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) / 2;
      blobs.add(MotionBlob(x, y, ((r - l) * (b - t) / (cell * cell)).ceil().clamp(1, 1 << 20), radius: radius));
    }
    return blobs;
  }

  static double _iou((double, double, double, double, double) a, (double, double, double, double, double) b) {
    final iw = min(a.$3, b.$3) - max(a.$1, b.$1);
    final ih = min(a.$4, b.$4) - max(a.$2, b.$2);
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    return inter / ((a.$3 - a.$1) * (a.$4 - a.$2) + (b.$3 - b.$1) * (b.$4 - b.$2) - inter);
  }

  @override
  void reset() => _motion.reset();

  @override
  void dispose() {
    _interpreter.close();
    _motion.dispose();
  }
}
