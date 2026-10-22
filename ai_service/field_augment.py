"""
Crop Scanner — Tractor-Camera Augmentation
==========================================
The dataset is close-up leaf photos (mostly plain lab backgrounds). A camera
bolted to a tractor sees something different:

  * the leaf is further away → smaller in the frame, with soil/grass around it
  * the tractor moves        → horizontal motion blur, slight defocus
  * outdoor light            → harsh sun, shade, colour casts
  * cheap USB webcam         → sensor noise, heavy JPEG compression
  * top-down view            → leaves appear at any rotation

`field_augment` turns a clean training image into a plausible tractor frame,
so the model learns the disease, not the lab background. Output stays a
plain RGB uint8 image — the model input (resize 224 → /255) is unchanged,
so preprocessing.py and the Flutter app need no changes.
"""

import cv2
import numpy as np

from preprocessing import _leaf_masks


# ─────────────────────────────────────────────
# FIELD BACKGROUNDS
# ─────────────────────────────────────────────
# Soil / dry grass / shadow tones (RGB). Green is deliberately excluded:
# a green background would read as "healthy leaf" to the damage estimator.
_BG_TONES = np.array([
    [110, 80, 55], [140, 105, 70], [90, 65, 45], [160, 130, 95],
    [70, 55, 40], [120, 110, 90], [45, 40, 35], [175, 160, 130],
], dtype=np.float32)


def _field_background(h: int, w: int, rng: np.random.Generator) -> np.ndarray:
    """Blotchy soil-like texture: two noise octaves around a random tone."""
    tone = _BG_TONES[rng.integers(len(_BG_TONES))]
    bg = np.empty((h, w, 3), np.float32)
    bg[:] = tone * rng.uniform(0.8, 1.2)
    for cells, amp in ((rng.integers(4, 10), 35.0), (rng.integers(20, 60), 18.0)):
        noise = rng.normal(0, 1, (cells, cells, 1)).astype(np.float32)
        bg += cv2.resize(noise, (w, h), interpolation=cv2.INTER_CUBIC)[..., None] * amp
    bg += rng.normal(0, 6, bg.shape).astype(np.float32)  # grit
    return np.clip(bg, 0, 255).astype(np.uint8)


def _replace_background(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Swaps a plain lab background for field texture, using the leaf mask."""
    leaf, _ = _leaf_masks(cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
    frac = leaf.mean()
    if frac < 0.15 or frac > 0.92:  # mask unreliable → leave image alone
        return img
    h, w = img.shape[:2]
    mask = cv2.resize(leaf.astype(np.uint8) * 255, (w, h), interpolation=cv2.INTER_NEAREST)
    # Close holes (lesions are brown/black and may fall outside the mask)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8), iterations=2)
    mask = cv2.GaussianBlur(mask, (7, 7), 0).astype(np.float32)[..., None] / 255.0
    bg = _field_background(h, w, rng)
    return (img * mask + bg * (1 - mask)).astype(np.uint8)


# ─────────────────────────────────────────────
# GEOMETRY
# ─────────────────────────────────────────────
def _rotate_scale(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Any rotation (top-down view) plus zoom out (distance) or in (close pass)."""
    h, w = img.shape[:2]
    angle = rng.uniform(0, 360)
    scale = rng.uniform(0.55, 1.15)
    m = cv2.getRotationMatrix2D((w / 2, h / 2), angle, scale)
    m[:, 2] += rng.uniform(-0.12, 0.12, 2) * (w, h)
    bg = _field_background(h, w, rng)
    out = cv2.warpAffine(img, m, (w, h), flags=cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
    valid = cv2.warpAffine(np.full((h, w), 255, np.uint8), m, (w, h),
                           flags=cv2.INTER_NEAREST, borderValue=0)
    return np.where(valid[..., None] > 0, out, bg)


# ─────────────────────────────────────────────
# PHOTOMETRIC / SENSOR
# ─────────────────────────────────────────────
def _motion_blur(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    k = int(rng.integers(3, 12))
    kernel = np.zeros((k, k), np.float32)
    kernel[k // 2, :] = 1.0 / k
    angle = rng.uniform(-20, 20)  # mostly along the direction of travel
    rot = cv2.getRotationMatrix2D((k / 2 - 0.5, k / 2 - 0.5), angle, 1.0)
    kernel = cv2.warpAffine(kernel, rot, (k, k))
    kernel /= max(kernel.sum(), 1e-6)
    return cv2.filter2D(img, -1, kernel)


def _lighting(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    x = img.astype(np.float32)
    # brightness / contrast (midday sun ↔ overcast)
    x = (x - 128) * rng.uniform(0.7, 1.3) + 128 + rng.uniform(-40, 40)
    # colour cast (evening warmth, cheap white balance)
    x *= rng.uniform(0.88, 1.12, 3)
    # saturation
    grey = x.mean(axis=2, keepdims=True)
    x = grey + (x - grey) * rng.uniform(0.7, 1.3)
    # uneven light: a soft shadow / sun gradient across the frame
    if rng.random() < 0.4:
        h, w = img.shape[:2]
        gx, gy = np.meshgrid(np.linspace(-1, 1, w), np.linspace(-1, 1, h))
        a = rng.uniform(0, 2 * np.pi)
        grad = (np.cos(a) * gx + np.sin(a) * gy)[..., None]
        x *= 1 + grad * rng.uniform(0.15, 0.4)
    return np.clip(x, 0, 255).astype(np.uint8)


def _sensor(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    if rng.random() < 0.5:
        noise = rng.normal(0, rng.uniform(2, 10), img.shape)
        img = np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8)
    if rng.random() < 0.6:
        q = int(rng.integers(30, 85))
        ok, enc = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])
        if ok:
            img = cv2.imdecode(enc, cv2.IMREAD_UNCHANGED)
    return img


# ─────────────────────────────────────────────
# PUBLIC
# ─────────────────────────────────────────────
def field_augment(img_rgb: np.ndarray, rng: np.random.Generator,
                  strength: float = 1.0) -> np.ndarray:
    """
    Random tractor-camera transform of an RGB uint8 image.
    strength ∈ [0, 1] scales how often each effect is applied.
    """
    img = img_rgb
    p = lambda base: rng.random() < base * strength  # noqa: E731

    if p(0.5):
        img = _replace_background(img, rng)
    if rng.random() < 0.5:
        img = img[:, ::-1]
    if rng.random() < 0.5:
        img = img[::-1]
    img = np.ascontiguousarray(img)
    if p(0.85):
        img = _rotate_scale(img, rng)
    if p(0.45):
        img = _motion_blur(img, rng)
    elif p(0.2):
        img = cv2.GaussianBlur(img, (0, 0), rng.uniform(0.6, 1.6))
    if p(0.9):
        img = _lighting(img, rng)
    if p(0.8):
        img = _sensor(img, rng)
    return img
