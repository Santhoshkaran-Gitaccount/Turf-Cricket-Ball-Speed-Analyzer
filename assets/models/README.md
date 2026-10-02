# Ball detection model (optional)

Put a TensorFlow Lite model here named `ball_detector.tflite` and the app uses it
to find the ball. Without it, the app uses OpenCV motion detection.

The app reads the model once when tracking starts. If the model fails to load,
the camera screen says so and detection falls back to OpenCV.

## Model contract

**Input:** one tensor, shape `[1, H, W, C]`.

- Any `H` and `W`. The camera frame's brightness (Y) plane is scaled to fit.
- `C` is 1 or 3. For 3, the grayscale value is copied into each channel.
- Type is `float32` (values 0–1) or `uint8` (values 0–255).

**Output:** tensor 0, shape `[1, N, 5]`, type `float32`. Each row is
`(cx, cy, w, h, score)`:

- `cx`, `cy`, `w`, `h` are normalized to 0–1 of the input image, in sensor orientation.
- Rows with `score` under 0.5 are ignored.

Detections are passed to the same tracker as the motion detector, so release,
travel, completion and invalid-delivery rules stay the same.
