# Ball detection model (optional)

Put a TensorFlow Lite model here named `ball_detector.tflite` and the app uses it
to find the ball. Without it, the app uses OpenCV motion detection. To train
one, see `ml/README.md`.

The app reads the model once when tracking starts. If the model fails to load,
the camera screen says so and detection falls back to OpenCV.

## Model contract

**Input:** one tensor, shape `[1, H, W, C]`.

- Any `H` and `W`. The watched part of the camera frame (the pitch and the
  release area above it) is cropped from the brightness (Y) plane and
  letterboxed to fit: scaled evenly, padded at the right and bottom with grey 114.
- `C` is 1 or 3. For 3, the grayscale value is copied into each channel.
- Type is `float32` (values 0–1) or `uint8` (values 0–255).

**Output:** tensor 0, type `float32`, either:

- `[1, N, 5]`: each row is `(cx, cy, w, h, score)`, or
- `[1, 5, N]`: the same fields for all boxes in turn, as YOLO exports it.

Boxes are normalized to 0–1 of the input image (boxes in input pixels are also
accepted), in sensor orientation. Boxes with `score` under 0.5 are ignored and
overlapping boxes are merged.

Detections are passed to the same tracker as the motion detector, so release,
travel, completion and invalid-delivery rules stay the same.
