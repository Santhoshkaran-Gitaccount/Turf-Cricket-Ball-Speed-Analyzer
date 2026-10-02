import 'frame.dart';

/// Finds ball candidates in camera frames.
///
/// Implementations live in the data layer: an OpenCV motion detector, and a
/// TensorFlow Lite object detector used when a trained model is available.
abstract interface class BallDetector {
  BallDetection detect(LumaFrame frame, FrameLayout layout);

  /// Forgets previous frames, e.g. when tracking restarts.
  void reset();

  /// Frees native resources.
  void dispose();
}
