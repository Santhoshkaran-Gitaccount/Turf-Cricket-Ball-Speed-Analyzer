"""Renders deliveries with a known speed and runs a ball detector model on them
exactly as the app does, for test/ml_eval_test.dart to measure speeds from.

Each delivery is filmed by a pinhole camera matched to the app's standard pitch
view (PitchGeometry.standard): 2 m behind the batting stumps at 1.2 m height,
landscape, bowling stumps' base at 0.35 of the screen height and batting
stumps' base at 0.95. The ball leaves the hand 2.1 m up at the bowling crease,
bounces, and passes the batting stumps at a little under stump height. Ground
speed is constant, so the true speed is pitch length / time between creases.

Output in --out:
  deliveries.json  per delivery: ball type, frame rate, true speed, frame
                   timestamps, and the model's detections per frame in the
                   app's reference coordinates (x, y, area in 4x4 cells, radius)
  <name>.bin       the raw grey frames, for running the app's OpenCV detector

Usage:
  python ml/eval_deliveries.py --model ball_detector.tflite --out eval
"""

import argparse
import json
import math
from pathlib import Path

import cv2
import numpy as np

from synthesize import BALLS, draw_ball, rng_normal

W, H = 1280, 720
CAMERA_BACK = 2.0  # metres behind the batting stumps
CAMERA_HEIGHT = 1.2
FAR_Y, NEAR_Y = 0.35 * H, 0.95 * H
BALL_RADIUS = 0.036  # metres

# PitchGeometry.standard, for the app's watched region.
STD = dict(far_y=0.35, near_y=0.95, far_half=0.03, near_half=0.30, release_top=0.10, release_half=0.08)
CELL = 4


class Camera:
    def __init__(self, pitch):
        far_z = CAMERA_BACK + pitch
        # Ground points: y = horizon + f * height / z, fitted to both stumps.
        self.f = (NEAR_Y - FAR_Y) / (CAMERA_HEIGHT * (1 / CAMERA_BACK - 1 / far_z))
        self.horizon = NEAR_Y - self.f * CAMERA_HEIGHT / CAMERA_BACK

    def project(self, x, z, height):
        return W / 2 + self.f * x / z, self.horizon + self.f * (CAMERA_HEIGHT - height) / z


def is_watched(x, y):
    s = STD
    if y < s["release_top"] or y > s["near_y"] + 0.05:
        return False
    along = (y - s["far_y"]) / (s["near_y"] - s["far_y"])
    width = s["far_half"] + (s["near_half"] - s["far_half"]) * along
    half = s["release_half"] if y < s["far_y"] else max(s["release_half"], width * 1.2)
    return abs(x - 0.5) <= half


def watched_bounds():
    xs, ys = [], []
    for gy in range(H // CELL):
        for gx in range(W // CELL):
            if is_watched((gx + 0.5) * CELL / W, (gy + 0.5) * CELL / H):
                xs.append(gx)
                ys.append(gy)
    return min(xs) * CELL, min(ys) * CELL, (max(xs) + 1) * CELL, (max(ys) + 1) * CELL


def scene(cam, rng):
    """The still turf, drawn through the same camera."""
    img = np.full((H, W), rng.uniform(75, 115), np.float32)
    img[: int(cam.horizon)] = rng.uniform(20, 180)
    blotches = cv2.resize(rng_normal(rng, (H // 40, W // 40), 1), (W, H), interpolation=cv2.INTER_CUBIC)
    img += blotches * rng.uniform(3, 8)
    img += rng_normal(rng, (H, W), 2)
    half = 1.5
    far_z = cam.f * CAMERA_HEIGHT / (FAR_Y - cam.horizon)
    corners = [cam.project(-half, far_z, 0), cam.project(half, far_z, 0), cam.project(half, CAMERA_BACK - 0.5, 0), cam.project(-half, CAMERA_BACK - 0.5, 0)]
    mask = np.zeros((H, W), np.uint8)
    cv2.fillPoly(mask, [np.array(corners, np.int32)], 255)
    img[mask > 0] += rng.uniform(-20, 25)
    for z, height in ((far_z, 0.71), (CAMERA_BACK, 0.71)):
        for k in (-0.11, 0, 0.11):
            x0, y0 = cam.project(k, z, 0)
            x1, y1 = cam.project(k, z, height)
            cv2.line(img, (int(x0), int(y0)), (int(x1), int(y1)), 210, max(1, int(cam.f * 0.03 / z)))
    return img


def render_delivery(cam, pitch, kmh, kind, fps, rng):
    """Frames (uint8) and timestamps (µs) of one delivery, plus the true speed."""
    v = kmh / 3.6
    background = scene(cam, rng)
    release_z = CAMERA_BACK + pitch
    bounce_z = CAMERA_BACK + rng.uniform(3, 8)
    end_z = 0.6  # past the stumps, near the keeper
    lateral = rng.uniform(-0.15, 0.15)
    drift = rng.uniform(-0.3, 0.3)
    exposure = 0.5 / fps
    shade = rng.uniform(0.8, 1.15)

    def ball_at(t):
        z = release_z - v * t
        if z >= bounce_z:  # falling from the hand to the bounce
            k = (release_z - z) / (release_z - bounce_z)
            height = 2.1 * (1 - k ** 1.6)
        else:  # rising off the pitch towards the batsman
            k = (bounce_z - z) / (bounce_z - end_z)
            height = 0.9 * math.sin(min(1.0, k) * math.pi * 0.45)
        x = lateral + drift * (release_z - z) / pitch
        return x, z, max(height, BALL_RADIUS)

    lead = int(rng.integers(25, 40))  # still frames before the release
    # The release happens part-way between two frames.
    phase = rng.uniform(0, 1)
    flight = (release_z - end_z) / v
    frames, stamps = [], []
    n = lead + int((flight + 0.8) * fps)
    for i in range(n):
        t = (i - lead - phase) / fps
        img = background.copy()
        if 0 <= t <= flight:
            x, z, height = ball_at(t)
            px, py = cam.project(x, z, height)
            x2, z2, h2 = ball_at(min(flight, t + exposure))
            qx, qy = cam.project(x2, z2, h2)
            radius = cam.f * BALL_RADIUS / z
            draw_ball(img, (px + qx) / 2, (py + qy) / 2, radius, kind, rng, qx - px, qy - py)
        img = np.clip(img * shade + rng_normal(rng, (H, W), 2.5), 0, 255).astype(np.uint8)
        frames.append(img)
        stamps.append(int(round(i * 1e6 / fps + rng.uniform(-1500, 1500))))
    true_kmh = pitch / (pitch / v) * 3.6
    return frames, stamps, true_kmh


class Detector:
    """The app's TfliteBallDetector, in Python."""

    def __init__(self, model):
        try:
            from ai_edge_litert.interpreter import Interpreter
        except ImportError:
            from tensorflow.lite import Interpreter
        self.it = Interpreter(model_path=str(model), num_threads=2)
        self.it.allocate_tensors()
        inp = self.it.get_input_details()[0]
        _, self.ih, self.iw, self.ic = inp["shape"]
        self.input_index = inp["index"]
        self.float_input = inp["dtype"] == np.float32
        out = self.it.get_output_details()[0]
        self.output_index = out["index"]
        shape = out["shape"]
        self.channels_first = len(shape) == 3 and shape[1] == 5 and shape[2] != 5
        self.bounds = watched_bounds()

    def detect(self, frame, min_score=0.5, iou=0.45):
        left, top, right, bottom = self.bounds
        scale = min(self.iw / (right - left), self.ih / (bottom - top))
        image = np.full((self.ih, self.iw), 114, np.uint8)
        used_w, used_h = min(self.iw, int((right - left) * scale)), min(self.ih, int((bottom - top) * scale))
        rows = np.clip(np.floor(top + np.arange(used_h) / scale).astype(int), 0, H - 1)
        cols = np.clip(np.floor(left + np.arange(used_w) / scale).astype(int), 0, W - 1)
        image[:used_h, :used_w] = frame[np.ix_(rows, cols)]
        x = np.repeat(image[None, :, :, None], self.ic, axis=3)
        x = (x.astype(np.float32) / 255) if self.float_input else x
        self.it.set_tensor(self.input_index, x)
        self.it.invoke()
        out = self.it.get_tensor(self.output_index)[0]
        rows5 = out.T if self.channels_first else out
        win_w, win_h = self.iw / scale, self.ih / scale
        boxes = []
        for cx, cy, bw, bh, score in rows5:
            if score < min_score:
                continue
            if cx > 1.5 or cy > 1.5:
                cx, cy, bw, bh = cx / self.iw, cy / self.ih, bw / self.iw, bh / self.ih
            fx, fy = left + cx * win_w, top + cy * win_h
            boxes.append((fx - bw * win_w / 2, fy - bh * win_h / 2, fx + bw * win_w / 2, fy + bh * win_h / 2, float(score)))
        boxes.sort(key=lambda b: -b[4])
        kept = []
        for b in boxes:
            if all(_iou(b, k) <= iou for k in kept):
                kept.append(b)
        blobs = []
        for l, t, r, btm, _ in kept:
            x, y = (l + r) / 2 / W, (t + btm) / 2 / H
            if not is_watched(x, y):
                continue
            area = max(1, math.ceil((r - l) * (btm - t) / (CELL * CELL)))
            radius = math.hypot((r - l) / W, (btm - t) / H) / 2
            blobs.append([x, y, area, radius])
        return blobs


def _iou(a, b):
    iw = min(a[2], b[2]) - max(a[0], b[0])
    ih = min(a[3], b[3]) - max(a[1], b[1])
    if iw <= 0 or ih <= 0:
        return 0
    inter = iw * ih
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--pitch", type=float, default=20.12)
    parser.add_argument("--speeds", default="60,90,120,145")
    parser.add_argument("--fps", default="30,60")
    parser.add_argument("--balls", default="tennis,leather,white")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    cam = Camera(args.pitch)
    detector = Detector(args.model) if args.model else None
    deliveries = []
    for fps in map(int, args.fps.split(",")):
        for kind in args.balls.split(","):
            assert kind in BALLS, kind
            for kmh in map(float, args.speeds.split(",")):
                frames, stamps, true_kmh = render_delivery(cam, args.pitch, kmh, kind, fps, rng)
                name = f"{kind}_{int(kmh)}kmh_{fps}fps"
                np.concatenate([f.ravel() for f in frames]).tofile(args.out / f"{name}.bin")
                detections = [detector.detect(f) for f in frames] if detector else None
                deliveries.append(dict(name=name, ball=kind, fps=fps, true_kmh=true_kmh, pitch=args.pitch,
                                       width=W, height=H, timestamps=stamps, detections=detections))
                seen = sum(1 for d in detections if d) if detections else "-"
                print(f"{name}: {len(frames)} frames, model saw a ball in {seen}")
    (args.out / "deliveries.json").write_text(json.dumps(deliveries))


if __name__ == "__main__":
    main()
