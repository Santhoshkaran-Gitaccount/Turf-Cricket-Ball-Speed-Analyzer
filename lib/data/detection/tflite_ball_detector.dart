import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import '../../domain/detection/ball_detector.dart';
import '../../domain/detection/frame.dart';
import 'opencv_motion_detector.dart';

/// Finds the ball with an on-device TensorFlow Lite object detection model.
///
/// Model contract (see assets/models/README.md):
/// - input `[1, H, W, C]`, grayscale replicated to C channels (1 or 3),
///   float32 scaled to 0–1 or uint8 0–255;
/// - output `[1, N, 5]` float32 rows of `(cx, cy, w, h, score)`, box
///   coordinates normalized to the input image.
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
  }

  factory TfliteBallDetector.fromModel(Uint8List modelBytes, OpenCvMotionDetector motion) =>
      TfliteBallDetector(Interpreter.fromBuffer(modelBytes), motion);

  final Interpreter _interpreter;
  final OpenCvMotionDetector _motion;
  final double minScore;

  late final int _inputWidth;
  late final int _inputHeight;
  late final int _inputChannels;
  late final bool _inputIsFloat;

  @override
  BallDetection detect(LumaFrame frame, FrameLayout layout) {
    final status = _motion.detect(frame, layout).status;
    if (status != FrameStatus.ok) return BallDetection(status);

    _interpreter.getInputTensor(0).data = _input(frame);
    _interpreter.invoke();
    final output = _interpreter.getOutputTensor(0).data;
    final rows = Float32List.sublistView(Uint8List.fromList(output));

    return BallDetection(status, parseDetections(rows, layout, minScore: minScore));
  }

  /// Nearest-neighbour downscale of the frame to the model's input size.
  Uint8List _input(LumaFrame frame) {
    final bytes = Uint8List(_inputWidth * _inputHeight * _inputChannels);
    var i = 0;
    for (var y = 0; y < _inputHeight; y++) {
      final row = (y * frame.height ~/ _inputHeight) * frame.bytesPerRow;
      for (var x = 0; x < _inputWidth; x++) {
        final luma = frame.bytes[row + x * frame.width ~/ _inputWidth];
        for (var c = 0; c < _inputChannels; c++) {
          bytes[i++] = luma;
        }
      }
    }
    if (!_inputIsFloat) return bytes;
    final floats = Float32List(bytes.length);
    for (var j = 0; j < bytes.length; j++) {
      floats[j] = bytes[j] / 255;
    }
    return floats.buffer.asUint8List();
  }

  /// Turns raw `(cx, cy, w, h, score)` rows into blobs in screen coordinates,
  /// keeping confident detections inside the watched pitch region.
  static List<MotionBlob> parseDetections(Float32List rows, FrameLayout layout, {double minScore = 0.5}) {
    final blobs = <MotionBlob>[];
    const cell = OpenCvMotionDetector.cellSize;
    for (var i = 0; i + 4 < rows.length; i += 5) {
      if (rows[i + 4] < minScore) continue;
      final (x, y) = layout.toReference(rows[i] * layout.width, rows[i + 1] * layout.height);
      if (!layout.geometry.isWatched(x, y)) continue;
      final areaPixels = rows[i + 2] * layout.width * rows[i + 3] * layout.height;
      blobs.add(MotionBlob(x, y, (areaPixels / (cell * cell)).ceil().clamp(1, 1 << 20)));
    }
    return blobs;
  }

  @override
  void reset() => _motion.reset();

  @override
  void dispose() {
    _interpreter.close();
    _motion.dispose();
  }
}
