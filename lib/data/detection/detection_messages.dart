import 'dart:typed_data';

import '../../domain/detection/delivery_detector.dart';
import '../../domain/detection/pitch_geometry.dart';
import '../../domain/entities/session.dart';

/// Settings the detection worker is started with.
class DetectorConfig {
  const DetectorConfig({
    required this.pitchLengthMeters,
    required this.ballType,
    this.geometry = PitchGeometry.standard,
    this.modelBytes,
  });

  final double pitchLengthMeters;
  final BallType ballType;

  /// Where the pitch is at the start; see DetectionWorker.setGeometry.
  final PitchGeometry geometry;

  /// A TensorFlow Lite ball detection model. Without one, OpenCV motion
  /// detection is used.
  final Uint8List? modelBytes;
}

/// Something the detection worker reports back.
sealed class DetectorMessage {
  const DetectorMessage();
}

class DetectorEvent extends DetectorMessage {
  const DetectorEvent(this.event);
  final DeliveryEvent event;
}

class FpsMeasured extends DetectorMessage {
  const FpsMeasured(this.fps);
  final double fps;
}

class PitchVisibilityChanged extends DetectorMessage {
  const PitchVisibilityChanged(this.visible);
  final bool visible;
}

/// Sent once the worker is ready, saying which detector it is using.
class DetectorStarted extends DetectorMessage {
  const DetectorStarted({required this.usingModel, this.modelError});

  /// True when the TensorFlow Lite model is in use, false for OpenCV motion detection.
  final bool usingModel;

  /// Why a supplied model could not be loaded, if it could not.
  final String? modelError;
}

/// Sent after each processed frame, so the sender can limit frames in flight.
class FrameProcessed extends DetectorMessage {
  const FrameProcessed(this.processingMicros);
  final int processingMicros;
}
