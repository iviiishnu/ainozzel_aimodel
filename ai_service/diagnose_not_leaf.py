"""
diagnose_not_leaf.py
====================
Evaluates how well the model handles fake / non-leaf images:
  1. Runs every Not_Leaf image through the full inference pipeline
     (same preprocessing as the live app)
  2. Reports what percentage it correctly rejects vs wrongly accepts
  3. Breaks down failures by sub-type (leaf_print, fabric, skin, soil, …)
  4. Shows confidence distribution for correct vs wrong predictions
  5. Runs a quick check on real leaf images to confirm they still pass through
"""

import os, sys, json, collections
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE_DIR = Path(__file__).parent
sys.path.insert(0, str(BASE_DIR))

# ── Load model & class names ──────────────────────────────────────────────────
from inference import load_keras_model, load_class_names, _build_result
from preprocessing import preprocess_for_inference, load_bgr, crop_to_leaf
import ood

print("Loading model …")
# Force TFLite model (the .h5 has a Keras version mismatch on this machine)
TFLITE_PATH = str(BASE_DIR / "models" / "crop_model_float16.tflite")
model      = load_keras_model(model_path=TFLITE_PATH)
CLASS_NAMES = load_class_names()
NOT_LEAF_IDX = CLASS_NAMES.index("Not_Leaf") if "Not_Leaf" in CLASS_NAMES else -1
HEALTHY_IDX  = CLASS_NAMES.index("Healthy")  if "Healthy"  in CLASS_NAMES else -1

ood_stats = ood.load(CLASS_NAMES)
if ood_stats:
    protos, ood_threshold, k = ood_stats
    print(f"OOD loaded — threshold: {ood_threshold:.4f}")
else:
    print("WARNING: OOD stats missing — unfamiliar-image check is OFF")
    protos = ood_threshold = k = None

# ── Helpers ───────────────────────────────────────────────────────────────────

def run_image(img_path):
    """Returns (predicted_class_idx, confidence, ood_score_or_None, all_probs)."""
    bgr = crop_to_leaf(load_bgr(str(img_path)))
    x   = preprocess_for_inference(bgr)
    probs, feats = model.predict_both(x)
    probs = probs[0]
    feats = feats[0] if feats is not None else None

    idx  = int(np.argmax(probs))
    conf = float(probs[idx])

    ood_score = None
    if ood_stats and feats is not None:
        ood_score = float(ood.scores(feats[None], protos, k)[0])

    return idx, conf, ood_score, probs


def classify_image(img_path):
    """
    Returns a decision matching _build_result logic:
        'not_leaf'  → correctly rejected (Not_Leaf class)
        'uncertain' → rejected by low confidence or OOD check
        'accepted'  → wrongly let through as a real leaf disease/healthy
    """
    idx, conf, ood_score, probs = run_image(img_path)

    if conf < 0.50:
        return "uncertain", idx, conf, ood_score, probs

    if CLASS_NAMES[idx] == "Not_Leaf":
        return "not_leaf", idx, conf, ood_score, probs

    if ood_score is not None and ood_score > ood_threshold:
        return "uncertain_ood", idx, conf, ood_score, probs

    # Healthy prob guard (same as _build_result)
    healthy_prob = float(probs[HEALTHY_IDX]) if HEALTHY_IDX >= 0 else 0.0
    if conf < 0.60 or healthy_prob >= 0.10:
        return "uncertain", idx, conf, ood_score, probs

    return "accepted", idx, conf, ood_score, probs


# ── NOT_LEAF images ───────────────────────────────────────────────────────────
not_leaf_dir = BASE_DIR / "images" / "Not_Leaf"
not_leaf_images = list(not_leaf_dir.glob("*.jpg"))
print(f"\nNot_Leaf images found: {len(not_leaf_images)}")

results_by_subtype = collections.defaultdict(lambda: {"total": 0, "rejected": 0, "wrong": []})
overall = {"total": 0, "rejected": 0, "accepted": [], "ood_blocked": 0}

for img_path in not_leaf_images:
    # subtype = leaf_print, flower_print, photo_print, plain_fabric, skin, soil, wall_sky
    name     = img_path.stem            # e.g. synthetic_leaf_print_0003
    parts    = name.split("_")
    # strip "synthetic_" prefix and trailing index
    subtype  = "_".join(parts[1:-1])    # leaf_print, flower_print, etc.

    decision, pred_idx, conf, ood_score, probs = classify_image(img_path)

    results_by_subtype[subtype]["total"] += 1
    overall["total"] += 1

    if decision in ("not_leaf", "uncertain", "uncertain_ood"):
        results_by_subtype[subtype]["rejected"] += 1
        overall["rejected"] += 1
        if decision == "uncertain_ood":
            overall["ood_blocked"] += 1
    else:
        results_by_subtype[subtype]["wrong"].append({
            "file": img_path.name,
            "predicted": CLASS_NAMES[pred_idx],
            "confidence": round(conf * 100, 1),
            "ood_score": round(ood_score, 4) if ood_score is not None else None,
        })
        overall["accepted"].append((img_path.name, CLASS_NAMES[pred_idx], round(conf * 100, 1)))

# ── Print summary ─────────────────────────────────────────────────────────────
print(f"\n{'='*60}")
print(f"NOT-LEAF REJECTION RATE")
print(f"{'='*60}")
total    = overall["total"]
rejected = overall["rejected"]
accepted = total - rejected
print(f"  Total Not_Leaf images : {total}")
print(f"  Correctly rejected    : {rejected}  ({rejected/total*100:.1f}%)")
print(f"    of which via Not_Leaf class : {rejected - overall['ood_blocked']} "
      f"(classifier said Not_Leaf or low-conf)")
print(f"    of which via OOD check      : {overall['ood_blocked']}")
print(f"  WRONGLY ACCEPTED      : {accepted}  ({accepted/total*100:.1f}%)  ← PROBLEM CASES")

print(f"\n{'─'*60}")
print(f"{'Subtype':<22} {'Total':>7} {'Rejected':>9} {'Rejection%':>11} {'Status':>12}")
print(f"{'─'*60}")
for subtype, data in sorted(results_by_subtype.items()):
    t = data["total"]
    r = data["rejected"]
    pct = r / t * 100 if t else 0
    status = "✅" if pct >= 90 else ("⚠️ " if pct >= 70 else "❌")
    print(f"{subtype:<22} {t:>7} {r:>9} {pct:>10.1f}%  {status}")

if overall["accepted"]:
    print(f"\n{'─'*60}")
    print(f"WRONGLY ACCEPTED IMAGES ({len(overall['accepted'])} total):")
    for fname, pred, conf in overall["accepted"][:30]:
        print(f"  {fname:<45} → {pred:<22} ({conf:.1f}%)")
    if len(overall["accepted"]) > 30:
        print(f"  … and {len(overall['accepted'])-30} more")

# ── Check real leaf images (should NOT be blocked) ────────────────────────────
print(f"\n{'='*60}")
print(f"REAL LEAF FALSE-REJECT RATE (checking Healthy class)")
print(f"{'='*60}")
healthy_dir = BASE_DIR / "images" / "Healthy"
healthy_images = list(healthy_dir.glob("*.jpg"))[:50]   # sample 50

healthy_blocked = 0
for img_path in healthy_images:
    decision, pred_idx, conf, ood_score, probs = classify_image(img_path)
    if decision in ("uncertain", "uncertain_ood", "not_leaf"):
        healthy_blocked += 1

print(f"  Healthy images sampled  : {len(healthy_images)}")
print(f"  Incorrectly blocked     : {healthy_blocked}  ({healthy_blocked/len(healthy_images)*100:.1f}%)")

# ── Confidence histogram ──────────────────────────────────────────────────────
print("\nBuilding confidence histogram for Not_Leaf images …")
confs_rejected = []
confs_accepted = []
for img_path in not_leaf_images:
    _, conf, _, _ = run_image(img_path)
    dec, *_ = classify_image(img_path)
    if dec in ("not_leaf", "uncertain", "uncertain_ood"):
        confs_rejected.append(conf * 100)
    else:
        confs_accepted.append(conf * 100)

fig, ax = plt.subplots(figsize=(8, 4))
ax.hist(confs_rejected, bins=20, color="steelblue", alpha=0.7, label="Rejected (good)")
ax.hist(confs_accepted, bins=20, color="salmon",    alpha=0.9, label="Accepted (bad)")
ax.axvline(50, color="red",   linestyle="--", label="Conf threshold 50%")
ax.axvline(60, color="green", linestyle="--", label="Spray threshold 60%")
ax.set_xlabel("Top prediction confidence (%)")
ax.set_ylabel("Count")
ax.set_title("Not_Leaf image confidence distribution")
ax.legend()
plt.tight_layout()
out = BASE_DIR / "models" / "not_leaf_confidence.png"
plt.savefig(str(out), dpi=150)
print(f"Histogram saved → {out}")

# ── OOD score distribution ────────────────────────────────────────────────────
if ood_stats:
    print("Building OOD score distribution …")
    ood_scores_rejected = []
    ood_scores_accepted = []
    for img_path in not_leaf_images:
        dec, _, _, ood_s, _ = classify_image(img_path)
        if ood_s is not None:
            if dec in ("not_leaf", "uncertain", "uncertain_ood"):
                ood_scores_rejected.append(ood_s)
            else:
                ood_scores_accepted.append(ood_s)

    fig, ax = plt.subplots(figsize=(8, 4))
    ax.hist(ood_scores_rejected, bins=20, color="steelblue", alpha=0.7, label="Rejected (good)")
    ax.hist(ood_scores_accepted, bins=20, color="salmon",    alpha=0.9, label="Accepted (bad)")
    ax.axvline(ood_threshold, color="orange", linestyle="--",
               label=f"OOD threshold {ood_threshold:.3f}")
    ax.set_xlabel("OOD unfamiliarity score")
    ax.set_ylabel("Count")
    ax.set_title("OOD score distribution for Not_Leaf images")
    ax.legend()
    plt.tight_layout()
    out2 = BASE_DIR / "models" / "not_leaf_ood_scores.png"
    plt.savefig(str(out2), dpi=150)
    print(f"OOD histogram saved → {out2}")

print("\nDone.")
