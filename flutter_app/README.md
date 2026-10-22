# Crop Scanner — Flutter Tablet App

An Android app that scans leaves with the tablet camera or a USB/OTG webcam, detects the disease, and sends the damage % to the ESP32 sprayer through Blynk.

## Requirements

- Flutter **3.41+** (Dart 3.11), Android SDK, `adb`
- Android tablet with Android 8.0+ (`minSdk 26`), OTG support for a USB webcam
- Packages in [`pubspec.yaml`](pubspec.yaml): `tflite_flutter`, `uvccamera`, `image_picker`, `http`, `shared_preferences`, `permission_handler`, …

## Setup

```powershell
flutter pub get
copy config\app_config.example.json config\app_config.json
```

Edit `config/app_config.json`:

| Key | Example |
|---|---|
| `BACKEND_URL` | `http://192.168.1.20:8000` (PC running the Spring backend) |
| `BLYNK_SERVER` | `blynk.cloud` (or your region, e.g. `blr1.blynk.cloud`) |
| `BLYNK_AUTH_TOKEN` | Device auth token from Blynk Console |
| `DAMAGE_MEDIUM` / `DAMAGE_HIGH` | `15` / `35` |

## Run on a tablet (wireless debugging)

```powershell
$env:ADB_MDNS = "0"; adb kill-server
adb pair <tablet-ip>:<pair-port> <code>      # first time
adb connect <tablet-ip>:<port>
flutter run --release -d <tablet-ip>:<port> --dart-define-from-file=config/app_config.json
```

Build an APK:
```powershell
flutter build apk --release --dart-define-from-file=config/app_config.json
```

## Notes

- **Inference:** on-device TFLite (`assets/models/crop_model_float16.tflite`) by default, or server mode with the top-right toggle. Each mode falls back to the other on failure.
- **⚙ Settings:** change the backend URL, Blynk token and live-scan interval without rebuilding. **Test connections** checks both.
- `targetSdk` is kept at **27** on purpose, because the USB camera library needs the legacy storage behaviour. The `lint` block in `android/app/build.gradle.kts` lets release builds pass with it.
