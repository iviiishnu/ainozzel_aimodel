"""
Crop Scanner — Synthetic "Not_Leaf" Images
==========================================
The classifier used to know only Healthy + 7 diseases, so anything the camera
saw — a shirt with a leaf print, a hand, bare soil — was forced into one of
those classes. A leaf-print shirt came out as a disease and was sprayed.

This script fills images/Not_Leaf/ with synthetic negatives so the model
learns a "this is not a real leaf" class:

  * leaf-print fabric   flat cartoon leaves (outlines, veins, dots) tiled on a
                        fabric colour, with weave texture and wrinkles
  * photo-print fabric  posterised leaf photos tiled on fabric (train split
                        only, so validation never sees its own leaves)
  * flower prints, plain / striped / plaid fabric, skin, soil, walls, sky

Synthetic images only get the model part of the way. Add REAL photos of what
your camera sees that is not a crop leaf (shirts, hands, the tractor, soil,
printed leaf pictures) to images/Not_Leaf/ too — any filename not starting
with "synthetic_" is kept when this script is re-run.

Usage:
    python make_not_leaf.py            # 600 images
    python make_not_leaf.py --n 1000
"""

import argparse
import json
import os

import cv2
import numpy as np

from field_augment import _field_background, _lighting, _sensor, _motion_blur

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATASET_DIR = os.path.join(BASE_DIR, "images")
OUT_DIR = os.path.join(DATASET_DIR, "Not_Leaf")
SPLIT_JSON = os.path.join(BASE_DIR, "models", "split.json")
SIZE = 256
PREFIX = "synthetic_"

# Fabric base colours (RGB): white, black, navy, beige, grey, pink, maroon,
# sky blue, mustard, olive, mint, cream … including greens, so "green" alone
# never means "leaf".
_FABRIC = np.array([
    [245, 245, 240], [25, 25, 30], [30, 40, 80], [215, 195, 160], [130, 130, 135],
    [235, 170, 185], [110, 30, 45], [150, 195, 230], [210, 170, 50], [95, 105, 55],
    [170, 225, 195], [250, 240, 215], [60, 120, 70], [200, 80, 60], [90, 60, 120],
])
# Print greens: cartoon leaves are flat and usually more saturated than real ones.
_PRINT_GREENS = np.array([
    [40, 140, 60], [80, 170, 70], [20, 100, 50], [120, 190, 80], [30, 120, 100],
    [150, 200, 60], [60, 90, 40], [100, 150, 40], [200, 210, 70], [20, 160, 120],
])
_SKIN = np.array([[230, 190, 160], [200, 150, 115], [165, 115, 80], [120, 80, 55],
                  [90, 60, 40], [240, 205, 180]])


def _jitter(c, rng, amt=20):
    return tuple(int(v) for v in np.clip(c + rng.normal(0, amt, 3), 0, 255))


def _pick(arr, rng):
    return arr[rng.integers(len(arr))]


# ─────────────────────────────────────────────
# FABRIC SURFACE
# ─────────────────────────────────────────────
def _weave(img, rng):
    """Fine thread pattern + fibre noise, as a phone/webcam sees cloth up close."""
    h, w = img.shape[:2]
    p = rng.uniform(2.0, 5.0)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    a = rng.uniform(0, np.pi)
    u = np.cos(a) * xx + np.sin(a) * yy
    v = -np.sin(a) * xx + np.cos(a) * yy
    pat = np.sin(2 * np.pi * u / p) * np.sin(2 * np.pi * v / p)
    fib = rng.normal(0, 1, (h, w)).astype(np.float32)
    shade = 1 + pat * rng.uniform(0.03, 0.10) + fib * rng.uniform(0.01, 0.04)
    return np.clip(img * shade[..., None], 0, 255).astype(np.uint8)


def _wrinkle(img, rng):
    """Folds: smooth geometric warp + soft shading along the folds."""
    h, w = img.shape[:2]
    cells = int(rng.integers(3, 7))
    dx = cv2.resize(rng.normal(0, 1, (cells, cells)).astype(np.float32), (w, h),
                    interpolation=cv2.INTER_CUBIC) * rng.uniform(2, 10)
    dy = cv2.resize(rng.normal(0, 1, (cells, cells)).astype(np.float32), (w, h),
                    interpolation=cv2.INTER_CUBIC) * rng.uniform(2, 10)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    out = cv2.remap(img, xx + dx, yy + dy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
    shade = 1 + cv2.resize(rng.normal(0, 1, (cells, cells)).astype(np.float32), (w, h),
                           interpolation=cv2.INTER_CUBIC) * rng.uniform(0.05, 0.22)
    return np.clip(out * shade[..., None], 0, 255).astype(np.uint8)


def _fabric_bg(rng, h=SIZE, w=SIZE):
    img = np.empty((h, w, 3), np.uint8)
    img[:] = _jitter(_pick(_FABRIC, rng), rng, 15)
    r = rng.random()
    if r < 0.15:   # stripes
        c2 = _jitter(_pick(_FABRIC, rng), rng, 15)
        period = int(rng.integers(8, 40))
        for x in range(0, w * 2, period):
            cv2.line(img, (x, 0), (x - h, h), c2, max(1, period // 3))
    elif r < 0.25:  # polka dots
        c2 = _jitter(_pick(_FABRIC, rng), rng, 15)
        step = int(rng.integers(14, 40))
        for y in range(0, h, step):
            for x in range((y // step % 2) * step // 2, w, step):
                cv2.circle(img, (x, y), max(2, step // 6), c2, -1, cv2.LINE_AA)
    return img


# ─────────────────────────────────────────────
# LEAF SHAPES (cartoon / print style)
# ─────────────────────────────────────────────
def _leaf_polygon(rng, kind):
    """Leaf outline in a unit frame: base at (0,0), tip at (1,0)."""
    t = np.linspace(0, 1, 60)
    if kind == "ovate":
        half = rng.uniform(0.25, 0.45) * np.sin(np.pi * t) ** rng.uniform(0.6, 1.0)
    elif kind == "lance":
        half = rng.uniform(0.08, 0.18) * np.sin(np.pi * t) ** 0.8
    elif kind == "lobed":      # monstera / oak-ish notches
        n = int(rng.integers(3, 7))
        half = (rng.uniform(0.3, 0.5) * np.sin(np.pi * t)
                * (0.75 + 0.25 * np.abs(np.sin(n * np.pi * t))))
    else:                      # heart
        half = rng.uniform(0.3, 0.45) * np.sin(np.pi * t) ** 0.5 * (1 - 0.4 * t)
    top = np.stack([t, half], 1)
    bot = np.stack([t[::-1], -half[::-1]], 1)
    return np.concatenate([top, bot])


def _draw_leaf(img, rng, cx, cy, length, angle, fill, outline, vein):
    kind = rng.choice(["ovate", "lance", "lobed", "heart"])
    pts = _leaf_polygon(rng, kind) - [0.5, 0]
    rot = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
    poly = (pts @ rot.T) * length + [cx, cy]
    cv2.fillPoly(img, [poly.astype(np.int32)], fill, cv2.LINE_AA)
    if outline is not None:
        cv2.polylines(img, [poly.astype(np.int32)], True, outline,
                      int(rng.integers(1, 4)), cv2.LINE_AA)
    if vein is not None:
        base = np.array([-0.5, 0]) @ rot.T * length + [cx, cy]
        tip = np.array([0.45, 0]) @ rot.T * length + [cx, cy]
        cv2.line(img, tuple(base.astype(int)), tuple(tip.astype(int)), vein, 1, cv2.LINE_AA)
        for s in np.linspace(-0.35, 0.3, int(rng.integers(3, 7))):
            for side in (-1, 1):
                a = np.array([s, 0]) @ rot.T * length + [cx, cy]
                b = np.array([s + 0.12, side * 0.18]) @ rot.T * length + [cx, cy]
                cv2.line(img, tuple(a.astype(int)), tuple(b.astype(int)), vein, 1, cv2.LINE_AA)
    if rng.random() < 0.3:     # decorative dots — read as "lesions" by the old model
        dot = _jitter(_pick(_FABRIC, rng), rng, 30)
        for _ in range(int(rng.integers(3, 12))):
            p = (pts[rng.integers(len(pts))] * rng.uniform(0.2, 0.8)) @ rot.T * length + [cx, cy]
            cv2.circle(img, tuple(p.astype(int)), int(rng.integers(1, 5)), dot, -1, cv2.LINE_AA)


def leaf_print(rng):
    img = _fabric_bg(rng)
    n_cols = int(rng.integers(1, 6))
    step = SIZE / n_cols
    outline = _jitter([20, 40, 20], rng, 15) if rng.random() < 0.6 else None
    vein = (_jitter([230, 240, 200], rng, 20) if rng.random() < 0.5
            else _jitter([20, 50, 25], rng, 15)) if rng.random() < 0.7 else None
    palette = [_jitter(_pick(_PRINT_GREENS, rng), rng, 15) for _ in range(rng.integers(1, 4))]
    for gy in range(n_cols + 1):
        for gx in range(n_cols + 1):
            if rng.random() < 0.15:
                continue
            cx = (gx + rng.uniform(-0.3, 0.3) + (gy % 2) * 0.5) * step
            cy = (gy + rng.uniform(-0.3, 0.3)) * step
            _draw_leaf(img, rng, cx, cy, step * rng.uniform(0.7, 1.4),
                       rng.uniform(0, 2 * np.pi), palette[rng.integers(len(palette))],
                       outline, vein)
    return img


def flower_print(rng):
    img = _fabric_bg(rng)
    for _ in range(int(rng.integers(3, 14))):
        cx, cy = rng.uniform(0, SIZE, 2)
        r = rng.uniform(10, 45)
        if rng.random() < 0.6:
            _draw_leaf(img, rng, cx + r, cy, r * 1.6, rng.uniform(0, 6.3),
                       _jitter(_pick(_PRINT_GREENS, rng), rng), None, None)
        petal = _jitter([rng.integers(150, 255), rng.integers(30, 200), rng.integers(30, 200)], rng)
        for k in range(int(rng.integers(5, 9))):
            a = 2 * np.pi * k / 7 + rng.uniform(-0.2, 0.2)
            cv2.circle(img, (int(cx + np.cos(a) * r * 0.6), int(cy + np.sin(a) * r * 0.6)),
                       int(r * 0.45), petal, -1, cv2.LINE_AA)
        cv2.circle(img, (int(cx), int(cy)), int(r * 0.3), _jitter([230, 190, 40], rng), -1,
                   cv2.LINE_AA)
    return img


def photo_print(rng, leaf_paths):
    """Posterised leaf photos tiled on cloth — a photographic leaf-print shirt."""
    img = _fabric_bg(rng)
    # ≥ 3×3 tiles: a repeating pattern, not one big leaf that looks like a real close-up
    n = int(rng.integers(3, 6))
    step = SIZE // n
    levels = int(rng.integers(3, 7))
    for gy in range(n):
        for gx in range(n):
            if rng.random() < 0.2:
                continue
            leaf = cv2.imread(leaf_paths[rng.integers(len(leaf_paths))])
            leaf = cv2.cvtColor(cv2.resize(leaf, (step, step), interpolation=cv2.INTER_AREA),
                                cv2.COLOR_BGR2RGB)
            q = 256 // levels
            leaf = (leaf // q * q + q // 2).astype(np.uint8)        # flat print colours
            hsv = cv2.cvtColor(leaf, cv2.COLOR_RGB2HSV)
            mask = (hsv[..., 1] > 50).astype(np.uint8)              # drop the photo backdrop
            mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))[..., None]
            tile = img[gy * step:(gy + 1) * step, gx * step:(gx + 1) * step]
            img[gy * step:(gy + 1) * step, gx * step:(gx + 1) * step] = \
                tile * (1 - mask) + leaf * mask
    return img


def plain_fabric(rng):
    img = _fabric_bg(rng)
    if rng.random() < 0.5:     # plaid
        c = _jitter(_pick(_FABRIC, rng), rng)
        step = int(rng.integers(16, 60))
        overlay = img.copy()
        for k in range(0, SIZE, step):
            cv2.rectangle(overlay, (k, 0), (k + step // 3, SIZE), c, -1)
            cv2.rectangle(overlay, (0, k), (SIZE, k + step // 3), c, -1)
        img = cv2.addWeighted(img, 0.5, overlay, 0.5, 0)
    return img


def skin(rng):
    """Hand / arm filling the frame: smooth skin tone, soft shading, knuckle creases."""
    img = np.empty((SIZE, SIZE, 3), np.float32)
    img[:] = _jitter(_pick(_SKIN, rng), rng, 12)
    shade = cv2.resize(rng.normal(0, 1, (4, 4)).astype(np.float32), (SIZE, SIZE),
                       interpolation=cv2.INTER_CUBIC)
    img *= (1 + shade * 0.12)[..., None]
    for _ in range(int(rng.integers(2, 8))):
        y = int(rng.uniform(0, SIZE))
        cv2.line(img, (0, y), (SIZE, y + int(rng.normal(0, 30))),
                 tuple(float(v) * 0.8 for v in img[min(y, SIZE - 1), 0]), 1, cv2.LINE_AA)
    if rng.random() < 0.5:     # background behind fingers
        bg = _fabric_bg(rng).astype(np.float32)
        mask = np.zeros((SIZE, SIZE), np.uint8)
        for k in range(int(rng.integers(2, 5))):
            x = int(rng.uniform(0, SIZE))
            cv2.line(mask, (x, SIZE), (x + int(rng.normal(0, 40)), int(rng.uniform(0, 120))),
                     255, int(rng.integers(30, 60)))
        m = cv2.GaussianBlur(mask, (9, 9), 0)[..., None] / 255.0
        img = img * m + bg * (1 - m)
    return np.clip(img, 0, 255).astype(np.uint8)


def soil(rng):
    return _field_background(SIZE, SIZE, rng)


def wall_sky(rng):
    c1 = np.array(_jitter(_pick(_FABRIC, rng), rng, 25), np.float32)
    c2 = np.array(_jitter(_pick(_FABRIC, rng), rng, 25), np.float32)
    t = np.linspace(0, 1, SIZE, dtype=np.float32)[:, None, None]
    img = c1 * (1 - t) + c2 * t + rng.normal(0, 4, (SIZE, SIZE, 3))
    return np.clip(img, 0, 255).astype(np.uint8)


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def _camera(img, rng):
    """Same kind of degradations the live USB camera adds."""
    if rng.random() < 0.6:
        img = _weave(img, rng)
    if rng.random() < 0.6:
        img = _wrinkle(img, rng)
    if rng.random() < 0.3:
        img = _motion_blur(img, rng)
    elif rng.random() < 0.3:
        img = cv2.GaussianBlur(img, (0, 0), rng.uniform(0.5, 1.5))
    img = _lighting(img, rng)
    return _sensor(img, rng)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=600)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)

    os.makedirs(OUT_DIR, exist_ok=True)
    for f in os.listdir(OUT_DIR):           # keep real photos, refresh synthetic ones
        if f.startswith(PREFIX):
            os.remove(os.path.join(OUT_DIR, f))

    # Leaf photos for photo prints: training split only (and never Not_Leaf).
    if os.path.exists(SPLIT_JSON):
        with open(SPLIT_JSON) as f:
            train = json.load(f)["train"]
    else:
        train = [os.path.join(c, f) for c in os.listdir(DATASET_DIR) if c != "Not_Leaf"
                 for f in os.listdir(os.path.join(DATASET_DIR, c))]
    leaf_paths = [os.path.join(DATASET_DIR, p) for p in train
                  if not p.replace("\\", "/").startswith("Not_Leaf/")]

    makers = [(leaf_print, 0.40), (photo_print, 0.15), (flower_print, 0.10),
              (plain_fabric, 0.10), (skin, 0.10), (soil, 0.10), (wall_sky, 0.05)]
    fns, weights = zip(*makers)
    counts = {}
    for i in range(args.n):
        fn = fns[rng.choice(len(fns), p=np.array(weights) / sum(weights))]
        img = fn(rng, leaf_paths) if fn is photo_print else fn(rng)
        img = _camera(img, rng)
        cv2.imwrite(os.path.join(OUT_DIR, f"{PREFIX}{fn.__name__}_{i:04d}.jpg"),
                    cv2.cvtColor(img, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 92])
        counts[fn.__name__] = counts.get(fn.__name__, 0) + 1
    print(f"Wrote {args.n} images to {OUT_DIR}: {counts}")


if __name__ == "__main__":
    main()
