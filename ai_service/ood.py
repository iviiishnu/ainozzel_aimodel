"""
Crop Scanner — "Looks Like Nothing It Was Trained On" Check
===========================================================
A softmax classifier always picks one of its classes, often confidently,
even for things it never saw (a leaf-print shirt). This check asks a
different question: does the image look like ANY real training leaf?

  * features  = MobileNetV2 backbone output after global average pooling
                (1280 numbers), L2-normalised
  * reference = 32 k-means prototypes per leaf class, fitted on the training
                images (clean + one tractor-camera augmented copy each)
  * score     = 1 − mean cosine similarity to the 3 nearest prototypes
  * threshold = THRESHOLD_PERCENTILE of the score over the field-simulated
                validation leaves → ~1% of real leaves are rejected

Above the threshold → "Uncertain", never sprayed.

Measured on the old 8-class model with 600 non-leaf images it had never
seen (leaf-print fabric, photo prints, skin, soil …): rejects 93% of them
while keeping 99% of real leaves. Softmax confidence alone: 18%.

Files (written by train_model.py, or `python ood.py` for the current model):
    models/ood_prototypes.bin   float32 little-endian, count × dim
    models/ood_stats.json       dim, count, k, threshold, class names
Both are copied into the Flutter app; lib/services/tflite_service.dart does
the same maths.
"""

import json
import os

import numpy as np

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(BASE_DIR, "models")
OOD_JSON_PATH = os.path.join(MODEL_DIR, "ood_stats.json")
OOD_BIN_PATH = os.path.join(MODEL_DIR, "ood_prototypes.bin")

PROTOS_PER_CLASS = 32
K_NEAREST = 3
THRESHOLD_PERCENTILE = 99.0
NOT_LEAF_CLASS = "Not_Leaf"   # never used as a reference: it is the opposite


def feature_layer(model):
    """The global-average-pooled backbone output of a train_model.py model."""
    import tensorflow as tf
    for layer in model.layers:
        if isinstance(layer, tf.keras.layers.GlobalAveragePooling2D):
            return layer.output
    raise ValueError("Model has no GlobalAveragePooling2D layer")


def feature_model(model):
    """Keras model → model returning [class probs, backbone features]."""
    import tensorflow as tf
    return tf.keras.Model(model.inputs, [model.output, feature_layer(model)])


def _normalize(f):
    f = np.asarray(f, np.float32)
    return f / np.maximum(np.linalg.norm(f, axis=-1, keepdims=True), 1e-8)


def scores(features, prototypes, k=K_NEAREST):
    """Unfamiliarity score per image: 1 − mean cosine sim to the k nearest prototypes."""
    sim = _normalize(features) @ prototypes.T
    return 1.0 - np.sort(sim, axis=-1)[:, -k:].mean(axis=-1)


def fit(train_feats, train_labels, val_feats, val_labels, class_names):
    """
    train_feats/labels: training images (clean + augmented) → prototypes.
    val_feats/labels:   field-simulated validation images → threshold.
    Not_Leaf images are left out of both.
    """
    from sklearn.cluster import KMeans

    skip = class_names.index(NOT_LEAF_CLASS) if NOT_LEAF_CLASS in class_names else -1
    f = _normalize(train_feats)
    protos = []
    for c in range(len(class_names)):
        if c == skip:
            continue
        x = f[train_labels == c]
        km = KMeans(min(PROTOS_PER_CLASS, len(x)), n_init=3, random_state=0).fit(x)
        protos.append(km.cluster_centers_)
    protos = _normalize(np.concatenate(protos))
    s = scores(val_feats[val_labels != skip], protos)
    return protos, float(np.percentile(s, THRESHOLD_PERCENTILE))


def save(prototypes, threshold, class_names):
    prototypes.astype("<f4").tofile(OOD_BIN_PATH)
    with open(OOD_JSON_PATH, "w") as fh:
        json.dump({"dim": int(prototypes.shape[1]), "count": int(prototypes.shape[0]),
                   "k": K_NEAREST, "threshold": threshold,
                   "percentile": THRESHOLD_PERCENTILE,
                   "class_names": list(class_names)}, fh, indent=2)
    print(f"OOD prototypes saved to {OOD_BIN_PATH} ({prototypes.shape[0]}×"
          f"{prototypes.shape[1]}), threshold {threshold:.4f}")


def load(class_names=None):
    """Returns (prototypes, threshold, k), or None when missing / for another model."""
    if not (os.path.exists(OOD_JSON_PATH) and os.path.exists(OOD_BIN_PATH)):
        return None
    with open(OOD_JSON_PATH) as fh:
        meta = json.load(fh)
    if class_names is not None and meta["class_names"] != list(class_names):
        print(f"WARNING: {OOD_JSON_PATH} is for classes {meta['class_names']}, not this "
              "model — unfamiliar-image check disabled. Run python ood.py.")
        return None
    protos = np.fromfile(OOD_BIN_PATH, "<f4").reshape(meta["count"], meta["dim"])
    return protos, float(meta["threshold"]), int(meta["k"])


def compute_and_save(model, images, labels, train_idx, val_idx, class_names, to_input):
    """
    images: RGB uint8 array (as loaded by train_model.py); to_input: image →
    model input. Prototypes from clean + one field-augmented copy of every
    training image; threshold from the field-simulated validation set.
    """
    from field_augment import field_augment
    from preprocessing import crop_to_leaf
    import cv2

    def camera(img, rng):   # what the live app feeds the model
        bgr = crop_to_leaf(cv2.cvtColor(field_augment(img, rng), cv2.COLOR_RGB2BGR))
        return to_input(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))

    fm = feature_model(model)

    def features(idx, make):
        # In chunks: stacking every image as float32 at once needs ~13 GB.
        out = []
        for s in range(0, len(idx), 512):
            x = np.stack([make(images[i]) for i in idx[s:s + 512]])
            out.append(fm.predict(x, batch_size=32, verbose=0)[1])
        return np.concatenate(out)

    rng = np.random.default_rng(99)
    train_f = np.concatenate([features(train_idx, to_input),
                              features(train_idx, lambda im: camera(im, rng))])
    rng = np.random.default_rng(1234)
    val_f = features(val_idx, lambda im: camera(im, rng))
    protos, thr = fit(train_f, np.r_[labels[train_idx], labels[train_idx]],
                      val_f, labels[val_idx], class_names)
    save(protos, thr, class_names)
    return protos, thr


if __name__ == "__main__":
    # Recompute for models/crop_model_best.h5 on the saved split (no retraining).
    import cv2
    import tensorflow as tf

    with open(os.path.join(MODEL_DIR, "class_names.json")) as fh:
        names = json.load(fh)
    with open(os.path.join(MODEL_DIR, "split.json")) as fh:
        split = json.load(fh)
    paths = split["train"] + split["val"]

    def load_img(p):
        img = cv2.imread(os.path.join(BASE_DIR, "images", p))
        return cv2.resize(cv2.cvtColor(img, cv2.COLOR_BGR2RGB), (256, 256),
                          interpolation=cv2.INTER_AREA)

    imgs = np.stack([load_img(p) for p in paths])
    labs = np.array([names.index(p.replace("\\", "/").split("/")[0]) for p in paths])
    n_train = len(split["train"])
    compute_and_save(
        tf.keras.models.load_model(os.path.join(MODEL_DIR, "crop_model_best.h5"),
                                   compile=False),
        imgs, labs, np.arange(n_train), np.arange(n_train, len(paths)), names,
        lambda rgb: cv2.resize(rgb, (224, 224)).astype(np.float32) / 255.0)
