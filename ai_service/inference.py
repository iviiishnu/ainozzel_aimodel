"""
Crop Scanner — Inference Engine
================================
Handles all prediction logic: model loading, confidence thresholding,
damage estimation, and multi-frame (TTA) prediction.

Separated from farm_app.py so it can be tested independently.

All tunables can be overridden with environment variables (see .env.example).
"""

import os
import json
import threading
from functools import lru_cache

import numpy as np

from preprocessing import (
    preprocess_for_inference,
    generate_tta_variants,
    aggregate_predictions,
    estimate_damage_percent,
    load_bgr,
    crop_to_leaf,
)
import ood

# ─────────────────────────────────────────────
# CONFIG (env-overridable)
# ─────────────────────────────────────────────
BASE_DIR        = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR       = os.getenv("MODEL_DIR", os.path.join(BASE_DIR, "models"))
MODEL_PATH      = os.getenv("MODEL_PATH")  # optional explicit model file
CLASS_JSON_PATH = os.getenv("CLASS_NAMES_PATH", os.path.join(MODEL_DIR, "class_names.json"))

# Below this confidence → "Uncertain" (no spray)
CONFIDENCE_THRESHOLD = float(os.getenv("CONFIDENCE_THRESHOLD", "0.50"))

# Class the model predicts for a leaf with no disease → never spray.
HEALTHY_CLASS = os.getenv("HEALTHY_CLASS", "Healthy")

# Class for "this is not a crop leaf" (shirts, hands, soil …) → never spray.
NOT_LEAF_CLASS = os.getenv("NOT_LEAF_CLASS", "Not_Leaf")

# A disease is only sprayed when the model is at least SPRAY_CONFIDENCE sure
# of it AND gives the healthy class less than MAX_HEALTHY_PROB. Real camera
# leaves look different from the dataset photos; together these cut healthy
# leaf sprays ~5x on the field-simulated validation set.
SPRAY_CONFIDENCE = float(os.getenv("SPRAY_CONFIDENCE", "0.60"))
MAX_HEALTHY_PROB = float(os.getenv("MAX_HEALTHY_PROB", "0.10"))

# How a leaf is judged diseased:
#   confidence - the top class must be a disease with >= SPRAY_CONFIDENCE and
#                Healthy < MAX_HEALTHY_PROB (above). Similar diseases split the
#                model's confidence, so real disease is often filtered out
#                (field photos: 29% of diseased leaves missed).
#   score      - spray when the model's probability that the leaf is ANY disease,
#                1 - P(Healthy) - P(Not_Leaf), is >= SPRAY_SCORE. Which disease
#                it is no longer matters for the spray decision. Field photos at
#                0.7: 15% missed, 15% healthy sprayed (confidence: 29% / 9%).
# The unfamiliar-image check and Not_Leaf class still apply in both modes.
SPRAY_RULE  = os.getenv("SPRAY_RULE", "confidence").strip().lower()
SPRAY_SCORE = float(os.getenv("SPRAY_SCORE", "0.70"))
if SPRAY_RULE not in ("confidence", "score"):
    raise RuntimeError(f"SPRAY_RULE must be 'confidence' or 'score', not {SPRAY_RULE!r}")

# Leaf pre-check (preprocessing.is_leaf_present). It only measures how much of
# the frame is green/brown plant colour, so dark or necrotic leaves (e.g.
# Anthracnose: 17% of validation leaves fall under the threshold) look like
# "no leaf". Below LEAF_HARD_FRACTION the frame is rejected outright (blank
# wall, sky, lens cap); between that and MIN_LEAF_FRACTION the classifier gets
# the final say, but only a confident Diseased/Healthy answer overrides the
# pre-check - Not_Leaf, Uncertain and unfamiliar results stay rejected.
LEAF_HARD_FRACTION = float(os.getenv("LEAF_HARD_FRACTION", "0.02"))
LEAF_OVERRIDE_CONFIDENCE = float(os.getenv("LEAF_OVERRIDE_CONFIDENCE", "0.85"))

# Damage severity bands (percent of leaf tissue that is not green).
# Only decide how LONG a diseased leaf is sprayed (the ESP32 maps
# Low → short burst, Medium → ~2 s, High → longer); whether to spray at all
# comes from the classifier. Mirrored in flutter_app/lib/config.dart and the
# ESP32 firmware.
DAMAGE_MEDIUM = float(os.getenv("DAMAGE_MEDIUM", "15"))  # ≥ → Medium
DAMAGE_HIGH   = float(os.getenv("DAMAGE_HIGH", "35"))    # ≥ → High

# Model file search order when MODEL_PATH is not set
_MODEL_CANDIDATES = ("crop_model_best.h5", "new_model.h5", "crop_model_float16.tflite")


# ─────────────────────────────────────────────
# MODEL LOADER
# ─────────────────────────────────────────────
class TFLiteModel:
    """
    Minimal wrapper giving a TFLite interpreter the same interface as
    KerasModel, so the rest of the inference code works unchanged when no .h5
    model is available.

    convert_tflite.py exports two outputs (class probs + backbone features);
    they are told apart by size, since the converter may reorder them. Older
    single-output models still work (no features → OOD check skipped).
    """

    def __init__(self, model_path: str):
        import tensorflow as tf

        self._interpreter = tf.lite.Interpreter(model_path=model_path)
        self._interpreter.allocate_tensors()
        self._input = self._interpreter.get_input_details()[0]
        outs = sorted(self._interpreter.get_output_details(), key=lambda o: o["shape"][-1])
        self._probs = outs[0]
        self._feats = outs[-1] if len(outs) > 1 else None
        self.input_shape = (None, *self._input["shape"][1:])
        # Interpreter is not thread-safe; the server handles requests on threads.
        self._lock = threading.Lock()

    def predict_both(self, x):
        """Returns (class probs, backbone features or None)."""
        probs, feats = [], []
        with self._lock:
            for sample in np.asarray(x, dtype=np.float32):
                self._interpreter.set_tensor(self._input["index"], sample[None])
                self._interpreter.invoke()
                probs.append(self._interpreter.get_tensor(self._probs["index"])[0])
                if self._feats is not None:
                    feats.append(self._interpreter.get_tensor(self._feats["index"])[0])
        return np.stack(probs), (np.stack(feats) if feats else None)

    def predict(self, x, verbose=0):
        return self.predict_both(x)[0]


class KerasModel:
    """Keras model that also returns the backbone features (ood.py)."""

    def __init__(self, model):
        self._model = ood.feature_model(model)
        self.input_shape = model.input_shape

    def predict_both(self, x):
        probs, feats = self._model.predict(x, verbose=0)
        return probs, feats

    def predict(self, x, verbose=0):
        return self.predict_both(x)[0]


def _resolve_model_path() -> str:
    if MODEL_PATH:
        return MODEL_PATH
    for name in _MODEL_CANDIDATES:
        path = os.path.join(MODEL_DIR, name)
        if os.path.exists(path):
            return path
    raise RuntimeError(
        f"No model found in {MODEL_DIR} (looked for {', '.join(_MODEL_CANDIDATES)}). "
        "Run train_model.py or set MODEL_PATH."
    )


def load_keras_model(model_path: str = None):
    """
    Loads a Keras .h5 or TFLite model and runs a warm-up inference.

    Returns:
        Model with `input_shape` and `predict(x, verbose=0)`.
    """
    model_path = model_path or _resolve_model_path()
    if not os.path.exists(model_path):
        raise RuntimeError(f"Model file not found: {model_path}")

    try:
        if model_path.endswith(".tflite"):
            model = TFLiteModel(model_path)
        else:
            import keras
            model = KerasModel(keras.saving.load_model(model_path, compile=False))
        print(f"Model loaded: {model_path}")
        print(f"Input shape: {model.input_shape}")

        # Warm-up so the first real request is fast
        dummy = np.zeros((1, *model.input_shape[1:]), dtype=np.float32)
        model.predict(dummy, verbose=0)
        return model

    except Exception as e:
        raise RuntimeError(f"Failed to load model from {model_path}: {e}")


def load_class_names() -> list:
    """Loads class names from class_names.json."""
    if not os.path.exists(CLASS_JSON_PATH):
        raise RuntimeError(f"Class names file not found: {CLASS_JSON_PATH}")
    with open(CLASS_JSON_PATH, "r") as f:
        names = json.load(f)
    if HEALTHY_CLASS not in names:
        print(f"WARNING: no '{HEALTHY_CLASS}' class — every confident "
              "prediction will be treated as diseased and sprayed.")
    if NOT_LEAF_CLASS not in names:
        print(f"WARNING: no '{NOT_LEAF_CLASS}' class — non-leaf objects (e.g. a "
              "leaf-print shirt) rely only on the unfamiliar-image check.")
    print(f"Loaded {len(names)} class names from {CLASS_JSON_PATH}")
    return names


@lru_cache(maxsize=4)
def _ood_stats(class_names: tuple):
    stats = ood.load(list(class_names))
    if stats is None:
        print("WARNING: no OOD stats for this model — unfamiliar-image check off.")
    return stats


def unfamiliar_score(features, class_names: list):
    """(score, threshold) from ood.py, or None when unavailable."""
    stats = _ood_stats(tuple(class_names))
    if stats is None or features is None:
        return None
    protos, threshold, k = stats
    features = np.asarray(features, np.float32)
    if protos.shape[1] != features.shape[-1]:
        return None
    return float(ood.scores(features[None], protos, k)[0]), threshold


# ─────────────────────────────────────────────
# SEVERITY
# ─────────────────────────────────────────────
def get_severity_label(damage_percent: float) -> str:
    """Maps damage percentage to a human-readable severity label."""
    if damage_percent < DAMAGE_MEDIUM:
        return "Low"
    if damage_percent < DAMAGE_HIGH:
        return "Medium"
    return "High"


# ─────────────────────────────────────────────
# CORE PREDICTION FUNCTIONS
# ─────────────────────────────────────────────
def predict_single(model, img_input, class_names: list) -> dict:
    """Single-image prediction with confidence thresholding."""
    img_bgr = crop_to_leaf(load_bgr(img_input))
    preds, feats = model.predict_both(preprocess_for_inference(img_bgr))
    return _build_result(preds[0], None if feats is None else feats[0],
                         class_names, img_bgr, n_frames=1)


def predict_with_tta(model, img_input, class_names: list, n_variants: int = 5) -> dict:
    """
    Test-Time Augmentation prediction: averages softmax outputs over
    n_variants mildly augmented copies of the image.
    """
    img_bgr = crop_to_leaf(load_bgr(img_input))
    variants = generate_tta_variants(img_bgr, n_variants=n_variants)
    # One batched forward pass instead of one model call per variant.
    probs, feats = model.predict_both(np.concatenate(variants, axis=0))
    avg_preds = aggregate_predictions(list(probs))
    # The OOD threshold was set on single un-augmented frames → use the original.
    return _build_result(avg_preds, None if feats is None else feats[0],
                         class_names, img_bgr, n_frames=len(variants))


def leaf_gate_passes(leaf_frac: float, result: dict, threshold: float) -> bool:
    """
    Decides whether an image counts as "a leaf is present".

    leaf_frac is preprocessing.leaf_fraction(); threshold is the normal
    MIN_LEAF_FRACTION. Enough plant colour always passes. Below LEAF_HARD_FRACTION
    never passes. In between, only a confident Diseased/Healthy classification
    passes, so dark diseased leaves are kept while fabric, walls and skin
    (Not_Leaf / Uncertain / unfamiliar) are still rejected.
    """
    if leaf_frac >= threshold:
        return True
    if leaf_frac < LEAF_HARD_FRACTION:
        return False
    return (result.get("status") in ("Diseased", "Healthy")
            and result.get("confidence_percent", 0.0) >= LEAF_OVERRIDE_CONFIDENCE * 100)


def spray_score(preds: np.ndarray, class_names: list) -> float:
    """Probability that the image is a diseased leaf: 1 - P(Healthy) - P(Not_Leaf)."""
    p = 0.0
    for name in (HEALTHY_CLASS, NOT_LEAF_CLASS):
        if name in class_names:
            p += float(preds[class_names.index(name)])
    return max(0.0, 1.0 - p)


def _best_disease(preds: np.ndarray, class_names: list) -> int:
    """Index of the most likely disease class (Healthy and Not_Leaf excluded)."""
    best, best_p = -1, -1.0
    for i, name in enumerate(class_names):
        if name not in (HEALTHY_CLASS, NOT_LEAF_CLASS) and preds[i] > best_p:
            best, best_p = i, float(preds[i])
    return best


def _build_result(preds: np.ndarray, features, class_names: list,
                  img_bgr: np.ndarray, n_frames: int) -> dict:
    """Builds the standardized result dictionary."""
    idx = int(np.argmax(preds))
    confidence = float(preds[idx])
    all_probs = {
        label: round(float(prob) * 100, 2)
        for label, prob in zip(class_names, preds)
    }

    # Damage is measured from the pixels, so it stays valid even when the
    # classifier can't name the disease (e.g. a dead/dried leaf, which is
    # not one of the trained classes).
    damage_percent = estimate_damage_percent(img_bgr)

    if SPRAY_RULE == "score" and class_names[idx] != NOT_LEAF_CLASS:
        score = spray_score(preds, class_names)
        unfamiliar = unfamiliar_score(features, class_names)
        if score >= SPRAY_SCORE and (unfamiliar is None or unfamiliar[0] <= unfamiliar[1]):
            d = _best_disease(preds, class_names)
            return {
                "crop": class_names[d],
                "status": "Diseased",
                "disease": class_names[d],
                "confidence_percent": round(float(preds[d]) * 100, 2),
                "spray_score_percent": round(score * 100, 2),
                "damage_percent": damage_percent,
                "severity": get_severity_label(damage_percent),
                "spray_recommended": True,
                "all_class_probs": all_probs,
                "frames_averaged": n_frames,
            }

    if confidence < CONFIDENCE_THRESHOLD:
        return {
            "crop": "Unknown",
            "status": "Uncertain",
            "disease": "Uncertain",
            "confidence_percent": round(confidence * 100, 2),
            "damage_percent": damage_percent,
            "severity": get_severity_label(damage_percent),
            # Not sure it is diseased → don't spray (a healthy leaf in odd
            # light is the usual cause).
            "spray_recommended": False,
            "message": (
                f"Disease not recognised ({confidence*100:.1f}% confidence) — "
                "not spraying."
            ),
            "all_class_probs": all_probs,
            "frames_averaged": n_frames,
        }

    if class_names[idx] == NOT_LEAF_CLASS:
        return {
            "crop": "Unknown",
            "status": "NotLeaf",
            "disease": "None",
            "confidence_percent": round(confidence * 100, 2),
            "damage_percent": 0.0,
            "severity": "None",
            "spray_recommended": False,
            "message": "Not a crop leaf — not spraying.",
            "all_class_probs": all_probs,
            "frames_averaged": n_frames,
        }

    # Doesn't resemble any training leaf (printed fabric, unknown object …):
    # whatever class won above is a guess.
    unfamiliar = unfamiliar_score(features, class_names)
    if unfamiliar is not None and unfamiliar[0] > unfamiliar[1]:
        return {
            "crop": "Unknown",
            "status": "Uncertain",
            "disease": "Uncertain",
            "confidence_percent": round(confidence * 100, 2),
            "damage_percent": damage_percent,
            "severity": get_severity_label(damage_percent),
            "spray_recommended": False,
            "message": (
                f"Doesn't look like a crop leaf the model knows (unfamiliar "
                f"{unfamiliar[0]:.2f} > {unfamiliar[1]:.2f}) — not spraying."
            ),
            "unfamiliar_score": round(unfamiliar[0], 4),
            "all_class_probs": all_probs,
            "frames_averaged": n_frames,
        }

    if class_names[idx] == HEALTHY_CLASS:
        return {
            "crop": class_names[idx],
            "status": "Healthy",
            "disease": "None",
            "confidence_percent": round(confidence * 100, 2),
            # Leftover non-green pixels on a healthy leaf are soil, stems or
            # shadow, not damage.
            "damage_percent": 0.0,
            "severity": "None",
            "spray_recommended": False,
            "message": "Leaf is healthy — no spray.",
            "all_class_probs": all_probs,
            "frames_averaged": n_frames,
        }

    healthy_prob = (float(preds[class_names.index(HEALTHY_CLASS)])
                    if HEALTHY_CLASS in class_names else 0.0)
    if (SPRAY_RULE == "score" or confidence < SPRAY_CONFIDENCE
            or healthy_prob >= MAX_HEALTHY_PROB):
        return {
            "crop": "Unknown",
            "status": "Uncertain",
            "disease": "Uncertain",
            "confidence_percent": round(confidence * 100, 2),
            "damage_percent": damage_percent,
            "severity": get_severity_label(damage_percent),
            "spray_recommended": False,
            "message": (
                f"Possibly {class_names[idx]} ({confidence*100:.1f}%, healthy "
                f"{healthy_prob*100:.1f}%) — not sure, not spraying."
            ),
            "all_class_probs": all_probs,
            "frames_averaged": n_frames,
        }

    return {
        "crop": class_names[idx],
        "status": "Diseased",
        "disease": class_names[idx],
        "confidence_percent": round(confidence * 100, 2),
        "damage_percent": damage_percent,
        "severity": get_severity_label(damage_percent),
        # Any recognised disease is sprayed; damage only sets the duration.
        "spray_recommended": True,
        "all_class_probs": all_probs,
        "frames_averaged": n_frames,
    }
