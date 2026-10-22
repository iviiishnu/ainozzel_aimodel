"""
Crop Scanner — Training Pipeline (Tractor Camera)
=================================================
Trains MobileNetV2 to recognise leaf diseases in frames from a camera mounted
on a moving tractor, not just clean close-up photos.

What changed vs. the previous version:
  1. Field augmentation (field_augment.py): distance/zoom-out, soil
     backgrounds instead of lab backdrops, motion blur, sun/shade, webcam
     noise + JPEG, any rotation.
  2. Stratified 80/20 split saved to models/split.json, so evaluation is
     always on images the model never trained on.
  3. Two validation sets: clean, and "field" (the same held-out images with
     a fixed field augmentation). Checkpoints are picked on the field set —
     that is what the tractor camera sees.
  4. Fine-tuning unfreezes the top of MobileNetV2 (block_10 onward) while
     keeping every BatchNorm frozen, which is what makes deeper fine-tuning
     stable on a small dataset.

  5. images/Not_Leaf/ (python make_not_leaf.py + your own real photos) gives
     the model a "not a crop leaf" class, so a leaf-print shirt is no longer
     forced into a disease.
  6. Writes models/ood_prototypes.bin + ood_stats.json (see ood.py): rejects
     images that look like no training leaf at all.

Model input is unchanged: RGB, resize (stretch) to 224×224, /255.

Usage:
    python make_not_leaf.py        # once (keeps your real photos)
    python train_model.py
    python convert_tflite.py --mode float16
"""

import os
import json
import numpy as np
import cv2
import tensorflow as tf
from tensorflow.keras import layers, Model, callbacks
from tensorflow.keras.applications import MobileNetV2
import matplotlib
matplotlib.use("Agg")   # works on machines without a display
import matplotlib.pyplot as plt
from sklearn.model_selection import train_test_split
from sklearn.utils.class_weight import compute_class_weight
from concurrent.futures import ThreadPoolExecutor

from field_augment import field_augment
import ood

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
BASE_DIR        = os.path.dirname(os.path.abspath(__file__))
DATASET_DIR     = os.path.join(BASE_DIR, "images")
MODEL_DIR       = os.path.join(BASE_DIR, "models")
MODEL_SAVE_PATH = os.path.join(MODEL_DIR, "crop_model.h5")
BEST_MODEL_PATH = os.path.join(MODEL_DIR, "crop_model_best.h5")
CLASS_JSON_PATH = os.path.join(MODEL_DIR, "class_names.json")
SPLIT_JSON_PATH = os.path.join(MODEL_DIR, "split.json")

os.makedirs(MODEL_DIR, exist_ok=True)

IMG_SIZE   = (224, 224)   # MobileNetV2 pretrained at 224 — do not change
LOAD_SIZE  = (256, 256)   # augment at a bit more than 224, then resize
BATCH_SIZE = 32
SEED       = 42
PHASE1_EPOCHS = 15
PHASE2_EPOCHS = 40
IMG_EXTS = (".jpg", ".jpeg", ".png", ".bmp")

tf.keras.utils.set_random_seed(SEED)

# Training on a laptop CPU: all cores at 100% for hours overheats it and it
# powers off. Cap the threads (TRAIN_THREADS=12 to use everything).
THREADS = int(os.environ.get("TRAIN_THREADS", "6"))
tf.config.threading.set_intra_op_parallelism_threads(THREADS)
tf.config.threading.set_inter_op_parallelism_threads(2)
print(f"CPU threads: {THREADS}")

# Keep Windows from sleeping mid-training.
if os.name == "nt":
    import ctypes
    ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)

# Resume after a crash: per-epoch backups, and phase 1 is skipped once done.
BACKUP_DIR  = os.path.join(MODEL_DIR, "_train_backup")
PHASE1_DONE = os.path.join(BACKUP_DIR, "phase1_done.weights.h5")

# ─────────────────────────────────────────────
# DATA
# ─────────────────────────────────────────────
CLASS_NAMES = sorted(d for d in os.listdir(DATASET_DIR)
                     if os.path.isdir(os.path.join(DATASET_DIR, d)))
NUM_CLASSES = len(CLASS_NAMES)
print(f"Classes ({NUM_CLASSES}): {CLASS_NAMES}")

paths, labels = [], []
for i, cls in enumerate(CLASS_NAMES):
    for f in sorted(os.listdir(os.path.join(DATASET_DIR, cls))):
        if f.lower().endswith(IMG_EXTS):
            paths.append(os.path.join(cls, f))
            labels.append(i)
labels = np.array(labels)

train_idx, val_idx = train_test_split(
    np.arange(len(paths)), test_size=0.2, stratify=labels, random_state=SEED)

with open(CLASS_JSON_PATH, "w") as f:
    json.dump(CLASS_NAMES, f, indent=2)
with open(SPLIT_JSON_PATH, "w") as f:
    json.dump({"train": [paths[i] for i in train_idx],
               "val": [paths[i] for i in val_idx]}, f, indent=1)
print(f"Train {len(train_idx)} / Val {len(val_idx)} — split saved to {SPLIT_JSON_PATH}")


def _load(rel_path):
    img = cv2.imread(os.path.join(DATASET_DIR, rel_path))
    return cv2.resize(cv2.cvtColor(img, cv2.COLOR_BGR2RGB), LOAD_SIZE,
                      interpolation=cv2.INTER_AREA)


print("Loading images into memory…")
with ThreadPoolExecutor(8) as pool:
    images = np.stack(list(pool.map(_load, paths)))


def to_model_input(img_rgb):
    """Same as preprocessing.preprocess_for_inference (minus decode)."""
    return cv2.resize(img_rgb, IMG_SIZE, interpolation=cv2.INTER_LINEAR
                      ).astype(np.float32) / 255.0


def build_val_set(field: bool):
    rng = np.random.default_rng(1234)   # fixed → identical every run
    # float16: half the RAM for the multi-crop set; /255 values lose nothing
    # that matters, and Keras casts to float32 per batch.
    x = np.stack([to_model_input(field_augment(images[i], rng) if field else images[i])
                  .astype(np.float16) for i in val_idx])
    y = tf.keras.utils.to_categorical(labels[val_idx], NUM_CLASSES)
    return x, y


val_clean = build_val_set(field=False)
val_field = build_val_set(field=True)


class FieldSequence(tf.keras.utils.Sequence):
    """Training batches with random tractor-camera augmentation."""

    def __init__(self, idx, clean_fraction=0.15):
        super().__init__(workers=2, use_multiprocessing=False)
        self.idx = np.array(idx)
        self.clean_fraction = clean_fraction
        self.pool = ThreadPoolExecutor(max(2, THREADS // 2))
        self.on_epoch_end()

    def __len__(self):
        return int(np.ceil(len(self.idx) / BATCH_SIZE))

    def on_epoch_end(self):
        np.random.shuffle(self.idx)

    def _one(self, args):
        i, seed = args
        rng = np.random.default_rng(seed)
        img = images[i]
        if rng.random() >= self.clean_fraction:
            img = field_augment(img, rng)
        elif rng.random() < 0.5:
            img = img[:, ::-1]
        return to_model_input(np.ascontiguousarray(img))

    def __getitem__(self, b):
        batch = self.idx[b * BATCH_SIZE:(b + 1) * BATCH_SIZE]
        seeds = np.random.randint(0, 2**31 - 1, len(batch))
        x = np.stack(list(self.pool.map(self._one, zip(batch, seeds))))
        y = tf.keras.utils.to_categorical(labels[batch], NUM_CLASSES)
        return x, y


train_seq = FieldSequence(train_idx)

# ─────────────────────────────────────────────
# CLASS WEIGHTS (capped to prevent extreme bias)
# ─────────────────────────────────────────────
MAX_CLASS_WEIGHT = 3.0
raw_weights = compute_class_weight('balanced', classes=np.arange(NUM_CLASSES),
                                   y=labels[train_idx])
class_weight_dict = {i: min(float(w), MAX_CLASS_WEIGHT) for i, w in enumerate(raw_weights)}
print("Class weights (capped):",
      {CLASS_NAMES[k]: round(v, 2) for k, v in class_weight_dict.items()})


# ─────────────────────────────────────────────
# MODEL
# ─────────────────────────────────────────────
def build_model(num_classes):
    base_model = MobileNetV2(weights='imagenet', include_top=False,
                             input_shape=(*IMG_SIZE, 3))
    base_model.trainable = False

    inputs = tf.keras.Input(shape=(*IMG_SIZE, 3))
    # Model takes [0,1] (what the app feeds it); MobileNetV2 wants [-1,1].
    x = layers.Rescaling(2.0, offset=-1.0)(inputs)
    # training=False keeps BatchNorm in inference mode even when fine-tuning
    x = base_model(x, training=False)
    x = layers.GlobalAveragePooling2D()(x)
    x = layers.Dropout(0.3)(x)
    x = layers.Dense(256)(x)
    x = layers.BatchNormalization()(x)
    x = layers.Activation('relu')(x)
    x = layers.Dropout(0.3)(x)
    outputs = layers.Dense(num_classes, activation='softmax')(x)
    return Model(inputs, outputs), base_model


def make_callbacks(patience, phase):
    return [
        callbacks.BackupAndRestore(os.path.join(BACKUP_DIR, phase)),
        callbacks.EarlyStopping(monitor='val_loss', patience=patience,
                                restore_best_weights=True, verbose=1),
        callbacks.ReduceLROnPlateau(monitor='val_loss', factor=0.5, patience=3,
                                    min_lr=1e-7, verbose=1),
        callbacks.ModelCheckpoint(BEST_MODEL_PATH, monitor='val_accuracy',
                                  save_best_only=True, verbose=1),
    ]


loss = tf.keras.losses.CategoricalCrossentropy(label_smoothing=0.05)

# ── PHASE 1 — head only ──────────────────────
print("\n=== PHASE 1: Training top layers (base frozen) ===")
model, base_model = build_model(NUM_CLASSES)
if os.path.exists(PHASE1_DONE):
    print(f"Phase 1 already finished — loading {PHASE1_DONE}")
    model.load_weights(PHASE1_DONE)
    history1 = None
else:
    model.compile(optimizer=tf.keras.optimizers.Adam(1e-3, clipnorm=1.0),
                  loss=loss, metrics=['accuracy'])
    history1 = model.fit(train_seq, validation_data=val_field, epochs=PHASE1_EPOCHS,
                         class_weight=class_weight_dict,
                         callbacks=make_callbacks(6, "phase1"))
    model.save_weights(PHASE1_DONE)

# ── PHASE 2 — fine-tune top of the base ──────
print("\n=== PHASE 2: Fine-tuning MobileNetV2 from block_10 ===")
base_model.trainable = True
unfreeze = False
for layer in base_model.layers:
    if layer.name.startswith("block_10"):
        unfreeze = True
    layer.trainable = unfreeze and not isinstance(layer, layers.BatchNormalization)
print(f"Trainable base layers: {sum(l.trainable for l in base_model.layers)} "
      f"/ {len(base_model.layers)}")

model.compile(optimizer=tf.keras.optimizers.Adam(3e-5, clipnorm=1.0),
              loss=loss, metrics=['accuracy'])
history2 = model.fit(train_seq, validation_data=val_field, epochs=PHASE2_EPOCHS,
                     class_weight=class_weight_dict, callbacks=make_callbacks(10, "phase2"))

model.save(MODEL_SAVE_PATH)
import shutil
shutil.rmtree(BACKUP_DIR, ignore_errors=True)   # finished — next run starts fresh
print(f"\nFinal model saved to: {MODEL_SAVE_PATH}")

# ─────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────
best = tf.keras.models.load_model(BEST_MODEL_PATH)
for name, (x, y) in (("clean", val_clean), ("field", val_field)):
    pred = best.predict(x, verbose=0).argmax(1)
    true = y.argmax(1)
    print(f"\nBest model — {name} val accuracy: {(pred == true).mean() * 100:.2f}%")
    for i, cls in enumerate(CLASS_NAMES):
        m = true == i
        print(f"   {cls:22s} {(pred[m] == i).mean() * 100:6.1f}%  (n={m.sum()})")

print("\nFitting unfamiliar-image check (ood.py)…")
ood.compute_and_save(best, images, labels, train_idx, val_idx, CLASS_NAMES, to_model_input)


def plot_history(h1, h2):
    h1_acc = h1.history['accuracy'] if h1 else []
    h1_vacc = h1.history['val_accuracy'] if h1 else []
    acc = h1_acc + h2.history['accuracy']
    vacc = h1_vacc + h2.history['val_accuracy']
    epochs = range(1, len(acc) + 1)
    plt.figure(figsize=(10, 5))
    plt.plot(epochs, acc, label='Train Accuracy (augmented)')
    plt.plot(epochs, vacc, label='Val Accuracy (field-simulated)')
    plt.axvline(x=len(h1_acc), color='gray', linestyle='--',
                label='Fine-tune start')
    plt.title('Training Accuracy')
    plt.xlabel('Epoch')
    plt.ylabel('Accuracy')
    plt.ylim([0, 1])
    plt.legend()
    plt.tight_layout()
    curve_path = os.path.join(MODEL_DIR, "training_curve.png")
    plt.savefig(curve_path, dpi=150)
    plt.close()
    print(f"Training curve saved to: {curve_path}")


plot_history(history1, history2)
