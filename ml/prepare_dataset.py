"""Builds a YOLO dataset for the ball detector.

Sources:
  --public DIR   A dataset exported from Roboflow in YOLO format (data.yaml,
                 train/valid/test folders). Boxes of any class with "ball" in
                 its name become class 0; other classes are dropped.
  --videos DIR   Phone videos of bowling, filmed from behind the batting
                 stumps as the app is used. The ball is found and labelled
                 automatically (see autolabel_video).

Every image is converted to grey (copied to 3 channels), because the app gives
the model only the camera's brightness plane.

Output (--out): images/{train,val}, labels/{train,val}, data.yaml, and
preview/ with labelled samples to check the automatic labels by eye.
"""

import argparse
import random
import shutil
from pathlib import Path

import cv2
import numpy as np
import yaml

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".bmp"}
VIDEO_EXTS = {".mp4", ".mov", ".avi", ".mkv", ".3gp"}

# Video frames are processed at this width; boxes are saved normalized.
WORK_WIDTH = 640

# A moving patch this size (in work pixels) can be the ball, blur included.
MIN_BLOB_AREA = 3
MAX_BLOB_AREA = 600

# A frame where more than this share of pixels changed is camera shake or a
# lighting jump; nothing in it is labelled.
MAX_FOREGROUND_SHARE = 0.15

# Linking blobs into a ball's path.
LINK_GATE = 45  # work pixels between frames, beyond the predicted position
MIN_TRACK_POINTS = 6
MIN_TRACK_TRAVEL = 60  # work pixels from first to last point
MIN_STRAIGHTNESS = 0.8  # straight-line distance / path length

# Boxes are at least this size (work pixels), so tiny far balls still get a
# box the model can learn from.
MIN_BOX = 6

# At most this many frames without a ball per frame with one.
NEGATIVE_RATIO = 0.3


def to_grey3(image):
    grey = image if image.ndim == 2 else cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return cv2.merge([grey, grey, grey])


def save_sample(out, split, name, image, boxes):
    """boxes: list of (cx, cy, w, h) normalized to the image."""
    (out / "images" / split).mkdir(parents=True, exist_ok=True)
    (out / "labels" / split).mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out / "images" / split / f"{name}.jpg"), to_grey3(image), [cv2.IMWRITE_JPEG_QUALITY, 92])
    with open(out / "labels" / split / f"{name}.txt", "w") as f:
        for cx, cy, w, h in boxes:
            f.write(f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}\n")


# --- Public datasets -------------------------------------------------------


def import_public(root: Path, out: Path, prefix: str):
    spec = yaml.safe_load((root / "data.yaml").read_text())
    names = spec["names"]
    if isinstance(names, dict):
        names = [names[k] for k in sorted(names)]
    ball_classes = {i for i, n in enumerate(names) if "ball" in str(n).lower()}
    if not ball_classes:
        print(f"  {root.name}: no class named like 'ball' in {names}; skipped")
        return 0

    count = 0
    for split_dir, split in [("train", "train"), ("valid", "val"), ("test", "val")]:
        images = root / split_dir / "images"
        if not images.is_dir():
            continue
        for image_path in images.iterdir():
            if image_path.suffix.lower() not in IMAGE_EXTS:
                continue
            image = cv2.imread(str(image_path))
            if image is None:
                continue
            boxes = []
            label_path = root / split_dir / "labels" / (image_path.stem + ".txt")
            if label_path.exists():
                for line in label_path.read_text().splitlines():
                    parts = line.split()
                    # Polygon labels (segmentation exports) become their bounding box.
                    if len(parts) < 5 or int(float(parts[0])) not in ball_classes:
                        continue
                    coords = list(map(float, parts[1:]))
                    if len(coords) == 4:
                        boxes.append(tuple(coords))
                    else:
                        xs, ys = coords[0::2], coords[1::2]
                        boxes.append(((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, max(xs) - min(xs), max(ys) - min(ys)))
            save_sample(out, split, f"{prefix}_{count:06d}", image, boxes)
            count += 1
    print(f"  {root.name}: {count} images")
    return count


# --- Automatic labels from videos -----------------------------------------


def find_blobs(foreground):
    count, _, stats, centroids = cv2.connectedComponentsWithStats(foreground, connectivity=8)
    blobs = []
    for i in range(1, count):
        x, y, w, h, area = stats[i]
        if not MIN_BLOB_AREA <= area <= MAX_BLOB_AREA:
            continue
        # A ball is round, or a short streak when blurred: not a long thin line.
        if max(w, h) > 6 * max(1, min(w, h)):
            continue
        blobs.append((float(centroids[i][0]), float(centroids[i][1]), int(x), int(y), int(w), int(h)))
    return blobs


def link_tracks(frames_blobs):
    """Greedy nearest-neighbour linking with constant-velocity prediction.
    Returns tracks as lists of (frame_index, blob)."""
    finished, active = [], []
    for index, blobs in enumerate(frames_blobs):
        unused = list(blobs)
        still_active = []
        for track in active:
            last_index, last = track[-1]
            if index - last_index > 3:
                finished.append(track)
                continue
            px, py = last[0], last[1]
            if len(track) >= 2:
                prev_index, prev = track[-2]
                steps = (index - last_index) / max(1, last_index - prev_index)
                px += (last[0] - prev[0]) * steps
                py += (last[1] - prev[1]) * steps
            best, best_d = None, LINK_GATE
            for blob in unused:
                d = np.hypot(blob[0] - px, blob[1] - py)
                if d < best_d:
                    best, best_d = blob, d
            if best is not None:
                unused.remove(best)
                track.append((index, best))
            still_active.append(track)
        active = still_active + [[(index, b)] for b in unused]
    return finished + active


def is_ball_track(track):
    if len(track) < MIN_TRACK_POINTS:
        return False
    points = np.array([(b[0], b[1]) for _, b in track])
    travel = np.hypot(*(points[-1] - points[0]))
    path = np.sum(np.hypot(*np.diff(points, axis=0).T))
    return travel >= MIN_TRACK_TRAVEL and travel / max(path, 1e-6) >= MIN_STRAIGHTNESS


def autolabel_video(video_path: Path):
    """Yields (frame, boxes) for every frame, boxes normalized; frames with
    camera shake are skipped."""
    capture = cv2.VideoCapture(str(video_path))
    subtractor = cv2.createBackgroundSubtractorMOG2(history=120, varThreshold=20, detectShadows=False)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    frames, frames_blobs, usable = [], [], []
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        scale = WORK_WIDTH / frame.shape[1]
        small = cv2.resize(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        foreground = subtractor.apply(small)
        foreground = cv2.morphologyEx(foreground, cv2.MORPH_OPEN, kernel)
        steady = np.count_nonzero(foreground) <= MAX_FOREGROUND_SHARE * foreground.size
        frames.append(frame)
        frames_blobs.append(find_blobs(foreground) if steady else [])
        usable.append(steady and len(frames) > 30)  # the background model needs a moment
    capture.release()
    if not frames:
        return

    work_h = frames[0].shape[0] * WORK_WIDTH / frames[0].shape[1]
    boxes_by_frame = {}
    for track in link_tracks(frames_blobs):
        if not is_ball_track(track):
            continue
        for index, (_, _, x, y, w, h) in track:
            w, h = max(w, MIN_BOX), max(h, MIN_BOX)
            cx, cy = x + w / 2, y + h / 2
            boxes_by_frame.setdefault(index, []).append((cx / WORK_WIDTH, cy / work_h, w / WORK_WIDTH, h / work_h))

    for index, frame in enumerate(frames):
        if usable[index]:
            yield frame, boxes_by_frame.get(index, [])


def zoom_crop(frame, boxes, rng):
    """A crop around the pitch's middle, like the region the app gives the
    model, with the boxes moved into it."""
    h, w = frame.shape[:2]
    cw, ch = int(w * rng.uniform(0.35, 0.6)), int(h * rng.uniform(0.6, 0.95))
    left = int(np.clip(w / 2 - cw / 2 + rng.uniform(-0.1, 0.1) * w, 0, w - cw))
    top = int(np.clip(h * rng.uniform(0, 0.2), 0, h - ch))
    crop = frame[top : top + ch, left : left + cw]
    moved = []
    for cx, cy, bw, bh in boxes:
        x, y = cx * w - left, cy * h - top
        if 0 <= x < cw and 0 <= y < ch:
            moved.append((x / cw, y / ch, bw * w / cw, bh * h / ch))
    return crop, moved


def import_videos(videos: Path, out: Path, rng: random.Random, val_share: float):
    paths = sorted(p for p in videos.rglob("*") if p.suffix.lower() in VIDEO_EXTS)
    if not paths:
        print(f"  no videos in {videos}")
        return 0
    rng.shuffle(paths)
    # Whole videos go to validation, so the model is checked on footage it never saw.
    val_count = max(1, round(len(paths) * val_share)) if len(paths) > 1 else 0
    total = 0
    for n, path in enumerate(paths):
        split = "val" if n < val_count else "train"
        positives = negatives = 0
        samples = list(autolabel_video(path))
        with_ball = [s for s in samples if s[1]]
        without = [s for s in samples if not s[1]]
        rng.shuffle(without)
        without = without[: int(len(with_ball) * NEGATIVE_RATIO) + 1]
        for i, (frame, boxes) in enumerate(with_ball + without):
            name = f"vid_{path.stem}_{i:05d}"
            save_sample(out, split, name, frame, boxes)
            crop, moved = zoom_crop(frame, boxes, rng)
            save_sample(out, split, name + "_crop", crop, moved)
            positives += bool(boxes)
            negatives += not boxes
        print(f"  {path.name}: {positives} frames with the ball, {negatives} without ({split})")
        total += positives + negatives
    return total


def ensure_val(out: Path, rng: random.Random, share: float):
    """Training needs a validation set; with a single video and no public
    validation images, part of the training images are moved there."""
    val = out / "images" / "val"
    if val.is_dir() and any(val.iterdir()):
        return
    train = sorted((out / "images" / "train").glob("*.jpg"))
    # A frame and its zoomed crop move together, so neither is seen in training.
    stems = sorted({p.stem.removesuffix("_crop") for p in train})
    rng.shuffle(stems)
    moving = set(stems[: max(1, round(len(stems) * share))])
    for split in ("images", "labels"):
        (out / split / "val").mkdir(parents=True, exist_ok=True)
    for image in train:
        if image.stem.removesuffix("_crop") in moving:
            image.rename(val / image.name)
            label = out / "labels" / "train" / (image.stem + ".txt")
            label.rename(out / "labels" / "val" / label.name)


def write_previews(out: Path, count=40):
    preview = out / "preview"
    preview.mkdir(exist_ok=True)
    labelled = [p for p in (out / "labels" / "train").glob("*.txt") if p.read_text().strip()]
    for label in random.Random(1).sample(labelled, min(count, len(labelled))):
        image = cv2.imread(str(out / "images" / "train" / (label.stem + ".jpg")))
        h, w = image.shape[:2]
        for line in label.read_text().splitlines():
            _, cx, cy, bw, bh = map(float, line.split())
            x0, y0 = int((cx - bw / 2) * w), int((cy - bh / 2) * h)
            x1, y1 = int((cx + bw / 2) * w), int((cy + bh / 2) * h)
            cv2.rectangle(image, (x0 - 3, y0 - 3), (x1 + 3, y1 + 3), (0, 0, 255), 2)
        cv2.imwrite(str(preview / (label.stem + ".jpg")), image)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--public", type=Path, action="append", default=[])
    parser.add_argument("--videos", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--val-share", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    if args.out.exists():
        shutil.rmtree(args.out)
    rng = random.Random(args.seed)
    total = 0
    for i, root in enumerate(args.public):
        total += import_public(root, args.out, f"pub{i}")
    if args.videos:
        total += import_videos(args.videos, args.out, rng, args.val_share)
    if total == 0:
        raise SystemExit("No images found.")

    (args.out / "data.yaml").write_text(
        yaml.safe_dump({"path": str(args.out.resolve()), "train": "images/train", "val": "images/val", "names": {0: "ball"}})
    )
    ensure_val(args.out, rng, args.val_share)
    write_previews(args.out)
    for split in ("train", "val"):
        n = len(list((args.out / "images" / split).glob("*.jpg")))
        print(f"{split}: {n} images")


if __name__ == "__main__":
    main()
