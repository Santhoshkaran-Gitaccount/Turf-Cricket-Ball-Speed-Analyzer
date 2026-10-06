# Ball detector training

The app finds the ball with OpenCV motion detection, or with a TensorFlow Lite
model when `assets/models/ball_detector.tflite` exists. This folder trains that
model.

- `prepare_dataset.py` builds a YOLO dataset from public Roboflow datasets and
  your own videos, labelling the ball in the videos automatically.
- `train_ball_detector.ipynb` runs on Google Colab's free GPU: it downloads the
  public datasets, builds the dataset, trains YOLO11n and exports
  `ball_detector.tflite`.

## 1. Film bowling at your turf

The model learns your turf's light and background from these videos, so they
matter most.

- Phone on a tripod behind the batting stumps, exactly as when using the app.
- Highest frame rate the camera app offers (60 FPS if available).
- 10–15 minutes in total: 50 or more deliveries. Mix tennis and leather balls,
  daylight and floodlights if you play in both.
- Keep the phone still. Short clips (one per over) are fine.

## 2. Train on Colab

1. In Google Drive, create a folder `BallSpeedAI` and put in it:
   - `prepare_dataset.py` from this folder,
   - a folder `videos` with the clips.
2. Open `train_ball_detector.ipynb` in Colab (colab.research.google.com →
   Upload), choose *Runtime → Change runtime type → T4 GPU*.
3. Paste a free Roboflow API key (roboflow.com → Settings → API Keys) in the
   first cell. Without one only your videos are used.
4. *Runtime → Run all*. Check the label previews it shows: each red box should
   be on the ball.
5. When it finishes, `BallSpeedAI/ball_detector.tflite` is on Drive. The
   notebook prints precision and recall on footage it did not train on.

## 3. Use it in the app

Copy `ball_detector.tflite` to `assets/models/` and rebuild. The camera screen
shows whether the model loaded; if it fails, the app falls back to OpenCV.

## Running locally

```
pip install opencv-python-headless numpy pyyaml
python ml/prepare_dataset.py --videos path/to/videos --public path/to/roboflow_export --out dataset
```
