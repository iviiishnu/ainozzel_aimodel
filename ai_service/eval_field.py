"""
Field test: runs the TFLite model the app ships on field_test/ (PlantDoc real
field photos the model never trained on) with the app's own decision rules,
and reports per class and per crop.

    python eval_field.py                                   # models/
    python eval_field.py --model-dir models/backup_x      # an older model

--model-dir must hold crop_model_float16.tflite, class_names.json and,
optionally, ood_stats.json + ood_prototypes.bin from the same training run.

"Spray correct" is what matters on the tractor: a diseased leaf is sprayed
and a healthy one is not. It works even when the model has no class for the
exact disease, so old and new models compare fairly.
"""

import argparse
import json
import os
import re
from collections import defaultdict

import cv2
import numpy as np
import tensorflow as tf

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Same as the app (lib/config.dart) and the server (.env defaults).
CONFIDENCE_THRESHOLD = 0.50
SPRAY_CONFIDENCE = 0.60
MAX_HEALTHY_PROB = 0.10
HEALTHY, NOT_LEAF = "Healthy", "Not_Leaf"


def load_model(model_dir):
    interp = tf.lite.Interpreter(os.path.join(model_dir, "crop_model_float16.tflite"))
    interp.allocate_tensors()
    with open(os.path.join(model_dir, "class_names.json")) as fh:
        names = json.load(fh)
    outs = interp.get_output_details()
    probs_out = next(o for o in outs if o["shape"][-1] == len(names))
    feats_out = next((o for o in outs if o is not probs_out), None)

    ood = None
    stats = os.path.join(model_dir, "ood_stats.json")
    if feats_out is not None and os.path.exists(stats):
        with open(stats) as fh:
            meta = json.load(fh)
        if meta["class_names"] == names:
            protos = np.fromfile(os.path.join(model_dir, "ood_prototypes.bin"), "<f4"
                                 ).reshape(meta["count"], meta["dim"])
            ood = (protos, float(meta["threshold"]), int(meta["k"]))
    return interp, names, probs_out, feats_out, ood


def predict(interp, probs_out, feats_out, path):
    img = cv2.cvtColor(cv2.imread(path), cv2.COLOR_BGR2RGB)
    img = cv2.resize(img, (224, 224), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    interp.set_tensor(interp.get_input_details()[0]["index"], img[None])
    interp.invoke()
    probs = interp.get_tensor(probs_out["index"])[0]
    feats = interp.get_tensor(feats_out["index"])[0] if feats_out else None
    return probs, feats


def decide(probs, feats, names, ood):
    """→ (top class, app decision: Spray / Healthy / NotLeaf / Uncertain)."""
    top = names[int(np.argmax(probs))]
    conf = float(np.max(probs))
    if top == NOT_LEAF:
        return top, "NotLeaf"
    if ood is not None:
        protos, thr, k = ood
        f = feats / max(np.linalg.norm(feats), 1e-8)
        if 1.0 - np.sort(f @ protos.T)[-k:].mean() > thr:
            return top, "Uncertain"
    if conf < CONFIDENCE_THRESHOLD:
        return top, "Uncertain"
    if top == HEALTHY:
        return top, "Healthy"
    p_healthy = float(probs[names.index(HEALTHY)]) if HEALTHY in names else 0.0
    if conf >= SPRAY_CONFIDENCE and p_healthy < MAX_HEALTHY_PROB:
        return top, "Spray"
    return top, "Uncertain"


def crop_of(filename):
    m = re.match(r"pd_([A-Za-z]+)", filename)
    c = m.group(1).lower() if m else "?"
    return {"bell": "pepper", "soyabean": "soybean"}.get(c, c)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", default=os.path.join(BASE_DIR, "models"))
    ap.add_argument("--test-dir", default=os.path.join(BASE_DIR, "field_test"))
    args = ap.parse_args()

    interp, names, probs_out, feats_out, ood = load_model(args.model_dir)
    print(f"Model: {args.model_dir}\nClasses: {names}\n"
          f"Unfamiliar check: {'on' if ood else 'off'}\n")

    by_class = defaultdict(lambda: defaultdict(int))
    by_crop = defaultdict(lambda: defaultdict(int))
    total = defaultdict(int)
    for true in sorted(os.listdir(args.test_dir)):
        folder = os.path.join(args.test_dir, true)
        for f in sorted(os.listdir(folder)):
            probs, feats = predict(interp, probs_out, feats_out, os.path.join(folder, f))
            top, decision = decide(probs, feats, names, ood)
            diseased = true not in (HEALTHY, NOT_LEAF)
            spray_ok = (decision == "Spray") if diseased else (decision != "Spray")
            for d in (by_class[true], by_crop[crop_of(f)], total):
                d["n"] += 1
                d["top1"] += top == true
                d["spray_ok"] += spray_ok
                d["uncertain"] += decision == "Uncertain"
                d["missed"] += diseased and decision != "Spray"
                d["false_spray"] += (not diseased) and decision == "Spray"

    def row(label, d):
        n = d["n"]
        return (f"{label:20s} {n:5d}   {100 * d['top1'] / n:5.1f}%   {100 * d['spray_ok'] / n:5.1f}%"
                f"   {100 * d['uncertain'] / n:5.1f}%")

    head = f"{'':20s} {'n':>5s}   {'class':>6s}   {'spray':>6s}   {'uncert':>6s}"
    print("Per true class   (class = exact disease right, spray = right spray decision)")
    print(head)
    for c, d in sorted(by_class.items()):
        print(row(c, d) + ("" if c in names else "   (no such class in this model)"))
    print("\nPer crop")
    print(head)
    for c, d in sorted(by_crop.items()):
        print(row(c, d))
    print("\n" + row("ALL", total))
    dis = sum(d["n"] for c, d in by_class.items() if c not in (HEALTHY, NOT_LEAF))
    hea = by_class[HEALTHY]["n"] if HEALTHY in by_class else 0
    if dis:
        print(f"Diseased leaves not sprayed: {100 * total['missed'] / dis:.1f}%")
    if hea:
        print(f"Healthy leaves sprayed:      {100 * total['false_spray'] / hea:.1f}%")


if __name__ == "__main__":
    main()
