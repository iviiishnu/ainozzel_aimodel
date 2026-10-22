# 🌿 AI Nozzle — Crop Disease Detection + Automatic Spraying

A tablet camera scans crop leaves. An AI model detects the disease and estimates leaf damage, and an ESP32 runs two spray pumps through relays to dose the plant in proportion to the damage.

**Stack:** Flutter (Android tablet) · Python / TensorFlow (ML server) · Spring Boot (API gateway) · ESP32 + Blynk IoT

> 📘 **Step-by-step setup and run guide: [HOW_TO_RUN.md](HOW_TO_RUN.md)**

> ℹ️ This repository ships **without the training dataset** (`ai_service/images/`). The trained models are included, so everything runs out of the box. See [ai_service/README.md](ai_service/README.md#dataset) to retrain.

---

## How it works

```
Tablet (Flutter app) ──USB/OTG── webcam
   │
   ├─ on-device TFLite model ───────────────┐   (default, works offline)
   └─ HTTP → Spring :8000 → Python ML :5010 ┤   (server mode, auto-fallback)
                                            ▼
                     disease, confidence, damage %  ──HTTPS──►  Blynk Cloud (V4)
                                                                     │
                                                                     ▼
                                         ESP32 → relays → pump 1 + pump 2
                                         ESP32 → Blynk V5 = pumps running → app
```

1. The app captures a leaf, either as a single photo or by live auto-scan from the USB webcam.
2. The leaf is classified **on the tablet** (TFLite) or by the **ML server** through the Spring backend.
3. The damage % is sent to Blynk virtual pin **V4**.
4. The ESP32 receives V4. At **15% damage or more** it runs both pumps together. The spray volume grows with damage, from 5 mL up to 25 mL at 60% damage or more.
5. The ESP32 reports its pump status on **V5**, and the app shows it.

**Disease classes (7):** Anthracnose · Bacterial Leaf Spot · Black Rot · Downy Mildew · Mosaic Disease · Powdery Mildew · Rust

| Damage % | Severity | Spray |
|---|---|---|
| < 15 | Low | none |
| 15 – 34 | Medium | yes, volume scales with damage |
| ≥ 35 | High | yes, full volume from 60% |

---

## Repository layout

```
├── HOW_TO_RUN.md            ← setup and run guide (start here)
├── ai_service/              ← Python ML server (Flask/Waitress :5010), training scripts, models
│   ├── requirements.txt
│   └── README.md
├── spring_backend/spring_backend_fresh/spring_backend/
│   ├── pom.xml              ← Spring Boot 3.5 / Java 17 API gateway (:8000)
│   └── README.md
├── flutter_app/             ← Android tablet app (Flutter)
│   ├── pubspec.yaml
│   └── README.md
├── ardunio/                 ← ESP32 firmware (Arduino)
│   ├── ai_nozzle_pumps/     ← ★ main firmware: Blynk + 2 relay pumps
│   ├── *_test/              ← bench-test sketches (no WiFi)
│   └── README.md
├── DEPLOYMENT.md            ← Blynk + deployment notes
├── connection_setup.md      ← wiring for the older L293D motor version
└── .vscode/tasks.json       ← one-click tasks (start backend, run app, flash ESP32)
```

---

## Requirements

| Part | Requirements file | Tooling |
|---|---|---|
| ML server | [`ai_service/requirements.txt`](ai_service/requirements.txt) | Python **3.11** (TensorFlow 2.21, Keras 3) |
| Backend | [`pom.xml`](spring_backend/spring_backend_fresh/spring_backend/pom.xml) | JDK **17** (Maven wrapper included) |
| App | [`flutter_app/pubspec.yaml`](flutter_app/pubspec.yaml) | Flutter **3.41+** / Dart 3.11, Android SDK |
| Firmware | [`ardunio/README.md`](ardunio/README.md#requirements) | Arduino CLI / IDE, **esp32 core 3.3.x**, **Blynk 1.3.x** |

---

## Quick start

Once everything is set up (see [HOW_TO_RUN.md](HOW_TO_RUN.md)), run:

```powershell
# Terminal 1 — ML server
cd ai_service
.\.venv\Scripts\python farm_app.py

# Terminal 2 — Spring backend
cd spring_backend\spring_backend_fresh\spring_backend
.\mvnw.cmd spring-boot:run
```

Then power on the ESP32 and open the app on the tablet.
(Linux/macOS: `.venv/bin/python farm_app.py` and `./mvnw spring-boot:run`.)

Health check: `curl http://localhost:8000/api/crop/health` → `"status":"ok"`.

---

## Configuration and secrets

No credentials are committed. Each part reads them from a git-ignored local file created from an example:

| Part | Create | From |
|---|---|---|
| ML server *(optional)* | `ai_service/.env` | `ai_service/.env.example` |
| Flutter app | `flutter_app/config/app_config.json` | `app_config.example.json` |
| ESP32 | `ardunio/ai_nozzle_pumps/secrets.h` | `secrets.example.h` |

---

## API

**`POST /api/crop/analyze`** takes `multipart/form-data` with a `file` field (jpg/jpeg/png/webp, max 10 MB). It's available on Spring `:8000` and directly on the ML server `:5010`.

```json
{
  "crop": "Rust",
  "status": "Diseased",
  "disease": "Rust",
  "confidence_percent": 97.46,
  "damage_percent": 8.86,
  "severity": "Low",
  "spray_recommended": false,
  "frames_averaged": 5,
  "all_class_probs": { "Rust": 97.46, "Black_rot": 2.45, "...": 0.0 }
}
```

If confidence is below 50%, the response has `"status": "Uncertain"` and a message asking for a clearer photo.

| Endpoint | Description |
|---|---|
| `GET /api/crop/health` (Spring) | Backend + ML server status |
| `GET /health` (ML server) | Model loaded, class list |

### Blynk virtual pins

| Pin | Direction | Meaning |
|---|---|---|
| V0 | dashboard → ESP32 | Pump 1 manual (0/1) |
| V1 | dashboard → ESP32 | Pump 2 manual (0/1) |
| V4 | app → ESP32 | Damage % (0–100) |
| V5 | ESP32 → app | Pumps running (0/1) |
