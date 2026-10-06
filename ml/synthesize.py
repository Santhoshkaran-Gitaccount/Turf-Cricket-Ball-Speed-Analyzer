"""Generates synthetic training images of cricket balls in flight.

Two kinds of image, both grey (the app gives the model only brightness):

- Turf scenes as the app sees them from behind the batting stumps: a pitch in
  perspective with creases and stumps, turf texture, nets, floodlight falloff
  and people, with a ball somewhere along its flight. Only the watched region
  around the pitch is kept, as the app crops it.
- Real photos (COCO128) with balls pasted in, for varied backgrounds and
  clutter.

Balls are tennis (bright), leather (dark red, close to turf in brightness,
with a highlight) and synthetic (white or pink), drawn with shading and the
motion blur of a fast ball at 30–120 FPS. Some images have no ball.

Usage:
  python ml/synthesize.py --out synth --count 3000 [--backgrounds coco128/images/train2017]
"""

import argparse
import math
import random
from pathlib import Path

import cv2
import numpy as np

W, H = 1280, 720


def turf_scene(rng):
    """A grey scene of a turf pitch seen from behind the batting stumps.
    Returns the image and the pitch geometry used to place the ball."""
    turf = rng.uniform(70, 125)
    img = np.full((H, W), turf, np.float32)

    # Background above the far end: wall, building or night sky.
    horizon = int(H * rng.uniform(0.12, 0.32))
    img[:horizon] = rng.uniform(15, 200)
    # Large soft blotches and fine grain in the turf.
    blotches = cv2.resize(rng_normal(rng, (H // 40, W // 40), 1), (W, H), interpolation=cv2.INTER_CUBIC)
    img[horizon:] += blotches[horizon:] * rng.uniform(3, 10)
    img += rng_normal(rng, (H, W), rng.uniform(1, 5))

    # Pitch strip in perspective: narrow at the far end, wide near the camera.
    far_y = horizon + rng.uniform(0.04, 0.12) * H
    near_y = H * rng.uniform(0.92, 1.05)
    cx_far = W / 2 + rng.uniform(-0.05, 0.05) * W
    cx_near = W / 2 + rng.uniform(-0.08, 0.08) * W
    half_far = rng.uniform(0.012, 0.03) * W
    half_near = half_far * rng.uniform(6, 11)
    strip = rng.uniform(-25, 30)
    pts = np.array([[cx_far - half_far, far_y], [cx_far + half_far, far_y], [cx_near + half_near, near_y], [cx_near - half_near, near_y]], np.int32)
    mask = np.zeros((H, W), np.uint8)
    cv2.fillPoly(mask, [pts], 255)
    img[mask > 0] += strip

    def at(t):  # point on the pitch centre line, t = 0 far end, 1 near end
        y = far_y + (near_y - far_y) * t
        return cx_far + (cx_near - cx_far) * t, y, half_far + (half_near - half_far) * t

    # Crease lines and stumps at both ends.
    line = rng.uniform(170, 245)
    for t in (0.03, 0.97):
        x, y, half = at(t)
        cv2.line(img, (int(x - half * 1.3), int(y)), (int(x + half * 1.3), int(y)), line, max(1, int(half * 0.04)))
    for t, height in ((0.02, rng.uniform(0.04, 0.07)), (0.98, rng.uniform(0.25, 0.4))):
        x, y, half = at(t)
        stump = rng.uniform(150, 240)
        for k in (-1, 0, 1):
            sx = int(x + k * half * 0.09)
            cv2.line(img, (sx, int(y)), (sx, int(y - height * H)), stump, max(1, int(half * 0.03)))

    # Nets around a box-cricket turf.
    if rng.random() < 0.5:
        net = rng.uniform(-30, 40)
        step = rng.integers(12, 30)
        for x in range(0, W, step):
            cv2.line(img, (x, 0), (x, horizon), float(img[0, 0] + net), 1)
        for y in range(0, horizon, step):
            cv2.line(img, (0, y), (W, y), float(img[0, 0] + net), 1)

    # People: the bowler at the far end, fielders, a keeper or batter near the camera.
    for _ in range(rng.integers(0, 4)):
        t = rng.uniform(-0.05, 1.0)
        x, y, half = at(max(0.0, t))
        x += rng.uniform(-3, 3) * half
        scale = 0.05 + 0.6 * max(0.0, t)
        h = scale * H
        shade = rng.uniform(20, 230)
        cv2.ellipse(img, (int(x), int(y - h * 0.55)), (int(h * 0.12), int(h * 0.4)), 0, 0, 360, shade, -1)
        cv2.circle(img, (int(x), int(y - h * 0.97)), int(h * 0.07), rng.uniform(20, 200), -1)

    # Floodlights: brighter in one area, darker at the edges.
    if rng.random() < 0.6:
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        lx, ly = rng.uniform(0, W), rng.uniform(-H * 0.5, H * 0.5)
        falloff = np.exp(-((xx - lx) ** 2 + (yy - ly) ** 2) / (2 * (rng.uniform(0.4, 1.2) * W) ** 2))
        img = img * (rng.uniform(0.5, 0.8) + rng.uniform(0.2, 0.6) * falloff)

    return img, at, far_y


def rng_normal(rng, shape, sigma):
    return rng.normal(0, sigma, shape).astype(np.float32)


BALLS = {
    # (body brightness range, highlight strength)
    "tennis": ((170, 235), 0.15),
    "leather": ((45, 95), 0.6),
    "white": ((205, 250), 0.1),
    "pink": ((130, 175), 0.3),
}


def draw_ball(img, x, y, radius, kind, rng, blur_dx, blur_dy):
    """Draws a shaded ball blurred along (blur_dx, blur_dy) pixels. Returns its
    bounding box (x0, y0, x1, y1)."""
    (lo, hi), highlight = BALLS[kind]
    body = rng.uniform(lo, hi)
    pad = int(radius + abs(blur_dx) + abs(blur_dy) + 4)
    size = 2 * pad + 1
    ss = 4  # supersampling for sub-pixel balls
    big = np.zeros((size * ss, size * ss), np.float32)
    alpha = np.zeros_like(big)
    steps = max(1, int(math.hypot(blur_dx, blur_dy) * 2))
    yy, xx = np.mgrid[0 : size * ss, 0 : size * ss].astype(np.float32) / ss - pad
    for s in range(steps):
        f = s / steps - 0.5 if steps > 1 else 0
        dx, dy = blur_dx * f, blur_dy * f
        d2 = ((xx - dx) ** 2 + (yy - dy) ** 2) / max(radius, 0.5) ** 2
        disc = (d2 <= 1).astype(np.float32)
        # Light from above: brighter top, a small highlight.
        shade = body * (1 - 0.25 * (yy - dy) / max(radius, 0.5)) + 255 * highlight * np.exp(-(((xx - dx + radius * 0.3) ** 2 + (yy - dy + radius * 0.35) ** 2) / max(radius * 0.25, 0.4) ** 2))
        big += disc * shade
        alpha += disc
    alpha /= steps
    big = np.where(alpha > 0, big / np.maximum(alpha * steps, 1e-6), 0)
    small_alpha = cv2.resize(alpha, (size, size), interpolation=cv2.INTER_AREA)
    small_ball = cv2.resize(big * alpha, (size, size), interpolation=cv2.INTER_AREA) / np.maximum(small_alpha, 1e-6)

    x0, y0 = int(round(x)) - pad, int(round(y)) - pad
    sx0, sy0 = max(0, -x0), max(0, -y0)
    ex, ey = min(size, img.shape[1] - x0), min(size, img.shape[0] - y0)
    if ex <= sx0 or ey <= sy0:
        return None
    region = img[y0 + sy0 : y0 + ey, x0 + sx0 : x0 + ex]
    a = small_alpha[sy0:ey, sx0:ex]
    region[:] = region * (1 - a) + small_ball[sy0:ey, sx0:ex] * a

    ys, xs = np.nonzero(small_alpha > 0.15)
    if len(xs) == 0:
        return None
    return (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1)


def finish(img, rng):
    """Camera noise, brightness and JPEG artefacts; returns uint8."""
    img = img * rng.uniform(0.6, 1.3) + rng.uniform(-25, 25)
    img += rng_normal(rng, img.shape, rng.uniform(0.5, 6))
    img = np.clip(img, 0, 255).astype(np.uint8)
    if rng.random() < 0.3:
        img = cv2.GaussianBlur(img, (3, 3), rng.uniform(0.3, 1.0))
    ok, jpg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(55, 95))])
    return cv2.imdecode(jpg, cv2.IMREAD_GRAYSCALE)


def turf_sample(rng):
    img, at, far_y = turf_scene(rng)
    boxes = []
    if rng.random() < 0.88:
        kind = rng.choice(list(BALLS))
        t = rng.uniform(-0.12, 0.95)  # negative: still near the bowler's hand, above the far end
        x, y, half = at(max(0.0, t))
        if t < 0:
            y = far_y + t * H * 0.8
        x += rng.uniform(-0.6, 0.6) * half
        y -= rng.uniform(0, 0.12) * H * (1 - max(0.0, t))  # ball above the pitch, in the air
        radius = 1.2 + 14 * max(0.0, t) ** 1.6 * rng.uniform(0.8, 1.2)
        # Screen speed grows towards the camera; frame rates 30–120 FPS.
        streak = (6 + 90 * max(0.0, t) ** 2) * rng.uniform(0.3, 1.2) * (30 / rng.choice([30, 60, 120]))
        angle = math.radians(rng.uniform(70, 110))
        box = draw_ball(img, x, y, radius, kind, rng, streak * math.cos(angle) * 0.3, streak * math.sin(angle))
        if box:
            boxes.append(box)
    img = finish(img, rng)

    # The watched region, as the app crops it: the pitch and the air above it.
    cw, ch = int(W * rng.uniform(0.3, 0.6)), int(H * rng.uniform(0.75, 1.0))
    left = int(np.clip(W / 2 - cw / 2 + rng.uniform(-0.05, 0.05) * W, 0, W - cw))
    top = int(np.clip(far_y - rng.uniform(0.1, 0.25) * H, 0, H - ch))
    crop = img[top : top + ch, left : left + cw]
    return crop, [(x0 - left, y0 - top, x1 - left, y1 - top) for x0, y0, x1, y1 in boxes]


def photo_sample(rng, background):
    img = background.astype(np.float32)
    boxes = []
    for _ in range(rng.integers(0, 3)):
        kind = rng.choice(list(BALLS))
        radius = rng.uniform(1.5, 18)
        x, y = rng.uniform(0, img.shape[1]), rng.uniform(0, img.shape[0])
        streak = rng.uniform(0, 5) * radius
        angle = rng.uniform(0, 2 * math.pi)
        box = draw_ball(img, x, y, radius, kind, rng, streak * math.cos(angle), streak * math.sin(angle))
        if box:
            boxes.append(box)
    return finish(img, rng), boxes


def save(out, split, name, img, boxes):
    h, w = img.shape[:2]
    (out / "images" / split).mkdir(parents=True, exist_ok=True)
    (out / "labels" / split).mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out / "images" / split / f"{name}.jpg"), cv2.merge([img, img, img]))
    with open(out / "labels" / split / f"{name}.txt", "w") as f:
        for x0, y0, x1, y1 in boxes:
            x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
            if x1 - x0 < 1 or y1 - y0 < 1:
                continue
            # At least 4 px, so the smallest balls still give the model a box to learn.
            bw, bh = max(4, x1 - x0), max(4, y1 - y0)
            f.write(f"0 {(x0 + x1) / 2 / w:.6f} {(y0 + y1) / 2 / h:.6f} {bw / w:.6f} {bh / h:.6f}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--count", type=int, default=3000)
    parser.add_argument("--backgrounds", type=Path, help="folder of real photos to paste balls into")
    parser.add_argument("--photo-share", type=float, default=0.3)
    parser.add_argument("--val-share", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    photos = sorted(p for p in args.backgrounds.rglob("*.jpg")) if args.backgrounds else []
    for i in range(args.count):
        split = "val" if i < args.count * args.val_share else "train"
        if photos and rng.random() < args.photo_share:
            bg = cv2.imread(str(photos[rng.integers(len(photos))]), cv2.IMREAD_GRAYSCALE)
            img, boxes = photo_sample(rng, bg)
        else:
            img, boxes = turf_sample(rng)
        save(args.out, split, f"synth_{i:05d}", img, boxes)
        if (i + 1) % 500 == 0:
            print(f"{i + 1}/{args.count}")

    (args.out / "data.yaml").write_text(f"path: {args.out.resolve().as_posix()}\ntrain: images/train\nval: images/val\nnames:\n  0: ball\n")


if __name__ == "__main__":
    main()
