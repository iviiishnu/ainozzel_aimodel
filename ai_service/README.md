# ML Server — `ai_service`

Flask API (served by Waitress on **port 5010**). It classifies a leaf image into 7 disease classes and estimates the damage %.

## Requirements

- Python **3.11**
- Packages in [`requirements.txt`](requirements.txt): TensorFlow 2.21, Keras 3.15, OpenCV, Flask, Waitress, SciPy, scikit-learn, …

> The models were saved with **Keras 3**, so TensorFlow ≥ 2.16 is required. TF 2.15 cannot load them.

## Setup

```powershell
cd ai_service
py -3.11 -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
copy .env.example .env          # optional — port, thresholds, model path
```
Linux/macOS: `python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt`

## Run

```powershell
.\.venv\Scripts\python farm_app.py
curl.exe http://127.0.0.1:5010/health
curl.exe -F "file=@leaf.jpg" http://127.0.0.1:5010/api/crop/analyze
```

## Files

| File | Purpose |
|---|---|
| `farm_app.py` | HTTP API: `/health`, `/api/crop/analyze` |
| `inference.py` | Model loading, test-time augmentation (5 variants), confidence threshold, damage % |
| `preprocessing.py` | Leaf check, letterbox resize, CLAHE, TTA variants |
| `train_model.py` | Trains MobileNetV2 (transfer learning, 224×224) on `images/` |
| `field_augment.py` | Tractor-camera augmentation (blur, lighting, noise) used during training |
| `make_not_leaf.py` | Fills `images/Not_Leaf/` with synthetic non-leaf images (leaf-print fabric, skin, soil …) |
| `ood.py` | Unfamiliar-image check: rejects frames that look like no training leaf (`models/ood_*`) |
| `live_test.py` | Live USB-webcam test on the PC: shows what Live Scan would decide, and saves real Not_Leaf frames (keys N / B) |
| `evalute_model.py` | Per-class accuracy and confusion matrix |
| `convert_tflite.py` | `.h5` → `.tflite` (`--mode float32 / float16 / int8`) |
| `tools/` | Dataset split and alternative training scripts |
| `models/` | `crop_model_float16.tflite`, `class_names.json`, `split.json`, training curve |

**Model loading order:** `models/crop_model_best.h5` → `new_model.h5` → `crop_model_float16.tflite`.
The `.h5` files are not in the repo, so a fresh clone uses the float16 TFLite model. That's the same model the app ships.

## Dataset

The training images are **not included** in this repository. To retrain, put them in `ai_service/images/` with one folder per class:

```
ai_service/images/
├── Anthracnose/
├── Bacterial_Leaf_Spot/
├── Black_rot/
├── Downy_Mildew/
├── Healthy/
├── Mosaic_Disease/
├── Not_Leaf/        ← anything that is NOT a crop leaf (see below)
├── Powdery_Mildew/
└── Rust/
```

### Not_Leaf — stop spraying shirts, hands and soil

Without this class the model has to call *everything* a leaf: a shirt with a
leaf print came out as a disease and was sprayed. `python make_not_leaf.py`
writes 600 synthetic negatives (`synthetic_*.jpg`: leaf-print and photo-print
fabric, flower prints, plaid, skin, soil, walls).

**Add real photos too.** Synthetic images only get part of the way. Save 200+
frames from the actual camera of things that are not crop leaves — printed
shirts, hands, the tractor, bare soil, leaf pictures on paper or a phone — into
`images/Not_Leaf/` with any name not starting with `synthetic_` (re-running
`make_not_leaf.py` keeps them), then retrain.

The quickest way is the live test tool with the USB camera plugged into the PC:

```powershell
.\.venv\Scripts\python live_test.py      # --camera 1 if the wrong camera opens
```

Hold the shirt (or hand, printed leaf …) in front of the camera. Whenever it
says **Diseased** or **Healthy** for something that isn't a leaf, press **B**
(saves 20 frames as `images/Not_Leaf/real_*.jpg`) and move it around: closer,
further, folded, different light. Also save frames where it is already
rejected, so the model keeps rejecting them. Aim for 200+ frames from several
shirts, then retrain.

The original set had about 1,630 images (Anthracnose 39, Bacterial Leaf Spot 622, Black rot 201, Downy Mildew 79, Mosaic 110, Powdery Mildew 382, Rust 198), collected from public leaf-disease datasets.

```powershell
.\.venv\Scripts\python make_not_leaf.py               # synthetic Not_Leaf images (once)
.\.venv\Scripts\python train_model.py                 # → models/crop_model_best.h5, class_names.json, ood_*
.\.venv\Scripts\python evalute_model.py
.\.venv\Scripts\python convert_tflite.py --mode float16
copy models\crop_model_float16.tflite, models\class_names.json, models\ood_stats.json, models\ood_prototypes.bin ..\flutter_app\assets\models\
```

All four files must come from the same training run — the app turns the
unfamiliar-image check off (and logs a warning) if `ood_stats.json` doesn't
match the model.

## Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `ML_HOST` / `ML_PORT` | `0.0.0.0` / `5010` | Bind address |
| `MODEL_PATH` | auto | Force a specific model file |
| `CONFIDENCE_THRESHOLD` | `0.50` | Below this → `"Uncertain"` |
| `SPRAY_CONFIDENCE` / `MAX_HEALTHY_PROB` | `0.60` / `0.10` | Spray only if disease ≥ this and Healthy < this; otherwise `"Uncertain"` (no spray) |
| `NOT_LEAF_CLASS` | `Not_Leaf` | Predicted → `"status": "NotLeaf"` (no spray). Images unlike any training leaf (`models/ood_*`) → `"Uncertain"` |
| `DAMAGE_MEDIUM` / `DAMAGE_HIGH` | `15` / `35` | Severity bands (keep in sync with the app and firmware) |
| `TTA_VARIANTS` | `5` | Test-time augmentation passes |
