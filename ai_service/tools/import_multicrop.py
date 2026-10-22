"""
Adds many more crops to images/ so the model works beyond tomato + cucumber.

Sources (downloaded into raw_datasets/dl/):
  pv/raw/color/<Crop>___<Disease>/   PlantVillage, 14 crops, lab photos
  plantdoc/train|test/<Plant leaf…>/ PlantDoc, 13 plants, real field photos

Each source disease is mapped to the app's classes by symptom type, so the
spray decision works on any plant. Blights and fungal leaf spots that fit no
existing class go to Leaf_Spot_Blight.

PlantVillage is sampled (PV_DISEASE_CAP / PV_HEALTHY_CAP per source folder)
so every crop is covered without the training set outgrowing RAM. Tomato
photos already in images/ (same PlantVillage UUID) are skipped, so nothing
lands in both train and val.

PlantDoc test/ goes to field_test/, never images/: an honest test on real
field photos the model never trains on.

Usage:
    python tools/import_multicrop.py            # copy
    python tools/import_multicrop.py --dry-run  # show the mapping + counts
"""

import os
import re
import sys
import random
from collections import Counter

import cv2

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGES_DIR = os.path.join(BASE_DIR, "images")
FIELD_TEST_DIR = os.path.join(BASE_DIR, "field_test")
DL_DIR = os.path.join(BASE_DIR, "raw_datasets", "dl")
PV_DIR = os.path.join(DL_DIR, "pv", "raw", "color")
PD_DIR = os.path.join(DL_DIR, "plantdoc")

PV_DISEASE_CAP = 250
PV_HEALTHY_CAP = 150
PV_BLIGHT_CAP = 150     # 13 PlantVillage sources map here; keeps it near the other classes
MAX_SIDE = 512          # PlantDoc photos can be several MB; training loads at 256
IMG_EXTS = (".jpg", ".jpeg", ".png", ".bmp")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

NEW_CLASS = "Leaf_Spot_Blight"


def map_label(folder: str):
    """Source folder name → app class, or None to skip."""
    n = folder.lower().replace("_", " ")
    # Pests / systemic diseases with no visual match to any class.
    if "spider" in n or "haunglongbing" in n or "greening" in n:
        return None
    if "healthy" in n:
        return "Healthy"
    if "rust" in n:
        return "Rust"
    if "powdery" in n:
        return "Powdery_Mildew"
    if "black rot" in n:
        return "Black_rot"
    if "bacterial" in n:
        return "Bacterial_Leaf_Spot"
    if "mosaic" in n or "yellow" in n:          # viral mottling / leaf curl
        return "Mosaic_Disease"
    if any(k in n for k in ("blight", "spot", "scab", "scorch", "mold", "esca", "measles")):
        return NEW_CLASS
    if n.strip().endswith("leaf"):               # PlantDoc: "Apple leaf" = healthy
        return "Healthy"
    return None


def existing_uuids():
    seen = set()
    for root, _, files in os.walk(IMAGES_DIR):
        for f in files:
            m = UUID_RE.search(f.lower())
            if m:
                seen.add(m.group(0))
    return seen


def copy_image(src, dst, dry):
    if dry:
        return True
    img = cv2.imread(src)
    if img is None:                              # PlantDoc has a few broken files
        return False
    h, w = img.shape[:2]
    s = MAX_SIDE / max(h, w)
    if s < 1:
        img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    return cv2.imwrite(dst, img, [cv2.IMWRITE_JPEG_QUALITY, 92])


def slug(s):
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")[:40]


def import_plantvillage(dry, seen, counts, skipped):
    rng = random.Random(42)
    for folder in sorted(os.listdir(PV_DIR)):
        cls = map_label(folder.split("___", 1)[-1])
        if cls is None:
            skipped[f"pv/{folder}"] += 1
            continue
        files = sorted(f for f in os.listdir(os.path.join(PV_DIR, folder))
                       if f.lower().endswith(IMG_EXTS))
        files = [f for f in files
                 if not (UUID_RE.search(f.lower()) and UUID_RE.search(f.lower()).group(0) in seen)]
        rng.shuffle(files)
        cap = {"Healthy": PV_HEALTHY_CAP, NEW_CLASS: PV_BLIGHT_CAP}.get(cls, PV_DISEASE_CAP)
        crop = slug(folder.split("___")[0])
        n = 0
        for f in files[:cap]:
            dst = os.path.join(IMAGES_DIR, cls, f"pv_{crop}_{slug(os.path.splitext(f)[0])}.jpg")
            if copy_image(os.path.join(PV_DIR, folder, f), dst, dry):
                n += 1
        counts[("images", cls, f"pv/{folder}")] = n


def import_plantdoc(dry, counts, skipped):
    for split, out_dir in (("train", IMAGES_DIR), ("test", FIELD_TEST_DIR)):
        split_dir = os.path.join(PD_DIR, split)
        for folder in sorted(os.listdir(split_dir)):
            cls = map_label(folder)
            if cls is None:
                skipped[f"plantdoc/{split}/{folder}"] += 1
                continue
            n = 0
            for i, f in enumerate(sorted(os.listdir(os.path.join(split_dir, folder)))):
                if not f.lower().endswith(IMG_EXTS):
                    continue
                dst = os.path.join(out_dir, cls, f"pd_{slug(folder)}_{i:04d}.jpg")
                if copy_image(os.path.join(split_dir, folder, f), dst, dry):
                    n += 1
            counts[(os.path.basename(out_dir), cls, f"plantdoc/{split}/{folder}")] = n


def main():
    dry = "--dry-run" in sys.argv
    counts, skipped = {}, Counter()
    import_plantvillage(dry, existing_uuids(), counts, skipped)
    import_plantdoc(dry, counts, skipped)

    for (dest, cls, src), n in sorted(counts.items()):
        print(f"{dest:11s} {cls:20s} {n:5d}  <- {src}")
    print("\nSkipped (no matching class):", ", ".join(skipped) or "none")
    totals = Counter()
    for (dest, cls, _), n in counts.items():
        totals[(dest, cls)] += n
    print("\nAdded per class:")
    for (dest, cls), n in sorted(totals.items()):
        print(f"  {dest:11s} {cls:20s} {n}")
    if dry:
        print("\n(dry run — nothing copied)")


if __name__ == "__main__":
    main()
