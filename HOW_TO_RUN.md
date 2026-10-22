# How to Set Up and Run — AI Nozzle

Everything you need to set up the project on a Windows PC and run all parts: the Python ML server, the Spring backend, the Flutter tablet app and the ESP32 two-pump sprayer.

```
Tablet (Flutter app) ──USB/OTG── webcam
   │
   ├─ on-device TFLite model ───────────────┐   (default, works offline)
   └─ HTTP → Spring :8000 → Python ML :5010 ┤   (server mode)
                                            ▼
                               damage %  ──HTTPS──►  Blynk Cloud (V4)
                                                          │
                                                          ▼
                              ESP32 → relays → pump 1 + pump 2 (together)
                              ESP32 → Blynk V5 = pumps running
```

- **PC, tablet:** must be on the **same WiFi**.
- **ESP32:** needs any **2.4 GHz WiFi with internet**. It talks only to Blynk Cloud, never to the PC.

> All commands below are **PowerShell**, run from the project root
> `C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle` unless a `cd` says otherwise.

---

## ⚡ Quick start (every day, once set up)

Open **three PowerShell windows**.

**Window 1: ML server**
```powershell
cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\ai_service
.\.venv\Scripts\python farm_app.py
```

**Window 2: Spring backend**
```powershell
cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\spring_backend\spring_backend_fresh\spring_backend
.\mvnw.cmd spring-boot:run
```
It's ready when the log says `Tomcat started on port 8000`.

**Window 3: check**
```powershell
curl.exe http://localhost:8000/api/crop/health
```
You should see `"status":"ok"` and `"model_loaded":true`.

**ESP32:** power it on. After about 15 s it shows **Online** in Blynk Console.

**Tablet:** open the app → ⚙ Settings → **Test connections**. Both should be OK.

If the PC's IP changed (new WiFi, reconnect), see [Changing networks](#changing-networks).

---

## 1. Install the tools (one time)

| Tool | Version | Used for |
|---|---|---|
| Python | **3.11** | ML server |
| JDK | **17** (e.g. Temurin) | Spring backend. The Maven wrapper is included, so no separate Maven install is needed. |
| Flutter SDK + Android SDK | stable | Tablet app (`flutter`, `adb`) |
| Arduino CLI | latest | ESP32 firmware (installed at `C:\Program Files\Arduino CLI`) |
| USB driver | CH340 | ESP32 board's USB chip (shows as `USB-SERIAL CH340 (COMxx)`) |

Check:
```powershell
python --version; java -version; flutter --version; arduino-cli version
```

---

## 2. Config files (one time)

The secret and local files are git-ignored. Create each one from its example:

| Part | Create | From |
|---|---|---|
| ML server *(optional)* | `ai_service\.env` | `ai_service\.env.example` |
| Flutter app | `flutter_app\config\app_config.json` | `app_config.example.json` |
| ESP32 | `ardunio\ai_nozzle_pumps\secrets.h` | `secrets.example.h` |

```powershell
copy ai_service\.env.example ai_service\.env
copy flutter_app\config\app_config.example.json flutter_app\config\app_config.json
copy ardunio\ai_nozzle_pumps\secrets.example.h ardunio\ai_nozzle_pumps\secrets.h
```

**`app_config.json`**
```json
{
  "BACKEND_URL": "http://<PC-IP>:8000",
  "BLYNK_SERVER": "blynk.cloud",
  "BLYNK_AUTH_TOKEN": "<device auth token from Blynk>",
  "CONFIDENCE_THRESHOLD": "0.50",
  "DAMAGE_MEDIUM": "15",
  "DAMAGE_HIGH": "35"
}
```

**`secrets.h`**
```cpp
#define BLYNK_TEMPLATE_ID   "TMPL..."
#define BLYNK_TEMPLATE_NAME "AI NOZZLE"
#define BLYNK_AUTH_TOKEN    "<device auth token>"
#define WIFI_SSID "<2.4 GHz WiFi name>"
#define WIFI_PASS "<WiFi password>"
```

To find the PC's IP (`<PC-IP>`):
```powershell
ipconfig      # "IPv4 Address" under the Wi-Fi adapter, e.g. 10.42.0.84
```

---

## 3. Python ML server (port 5010)

### Setup (one time)
```powershell
cd ai_service
py -3.11 -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
```

> ⚠️ Always use **`ai_service\.venv`** (TensorFlow 2.21 / Keras 3). The other envs (`.venv-win`, `venv`) and the system Python have TF 2.15, which **cannot load the model**.

### Run
```powershell
cd ai_service
.\.venv\Scripts\python farm_app.py
```
```powershell
curl.exe http://localhost:5010/health
```

### Model files
Loading order: `models\crop_model_best.h5` → `new_model.h5` → `crop_model_float16.tflite`.
The `.h5` files are git-ignored. On a fresh clone the server falls back to the TFLite model, which is fine.

Retrain (optional):
```powershell
.\.venv\Scripts\python make_not_leaf.py
.\.venv\Scripts\python train_model.py
.\.venv\Scripts\python convert_tflite.py --mode float16
copy models\crop_model_float16.tflite, models\class_names.json, models\ood_stats.json, models\ood_prototypes.bin ..\flutter_app\assets\models\
```
Put real photos of non-leaf things the camera sees (printed shirts, hands,
soil) in `images\Not_Leaf\` before retraining — see `ai_service\README.md`.

---

## 4. Spring backend (port 8000)

> The backend lives three folders deep. Running `mvnw.cmd` from `spring_backend\` gives *"not recognized"*.

```powershell
cd spring_backend\spring_backend_fresh\spring_backend
.\mvnw.cmd spring-boot:run
```

It forwards `POST /api/crop/analyze` to `http://127.0.0.1:5010`. To override the defaults:
```powershell
$env:AI_SERVICE_URL = "http://127.0.0.1:5010"; $env:SERVER_PORT = "8000"
.\mvnw.cmd spring-boot:run
```

**Test with a real leaf image** (from the project root):
```powershell
$img = (Get-ChildItem ai_service\images\Rust | Select-Object -First 1).FullName
curl.exe -F "file=@$img" http://localhost:8000/api/crop/analyze
```
The expected result is `"disease":"Rust"` with high confidence.

**Firewall (one time, admin PowerShell).** Without this the tablet can't reach the PC. This matters most on hotspots, which Windows marks as *Public*.
```powershell
New-NetFirewallRule -DisplayName "AI Nozzle backend" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any
```

---

## 5. Blynk Cloud (one time)

1. [blynk.cloud](https://blynk.cloud) → **Developer Zone → My Templates → New template**. Name `AI NOZZLE`, hardware **ESP32**, connection **WiFi**.
2. **Datastreams** → add these **Virtual Pin** datastreams, all type **Integer**:

   | Pin | Name | Min–Max | Written by |
   |---|---|---|---|
   | V0 | Pump 1 manual | 0–1 | dashboard switch |
   | V1 | Pump 2 manual | 0–1 | dashboard switch |
   | V4 | Damage % | 0–100 | **the app** |
   | V5 | Pump status | 0–1 | **the ESP32** |

3. *(Optional)* Dashboard: **Switch** widgets on V0/V1, a **Gauge** on V4, an **LED** on V5.
4. **Devices → New device → From template**. Copy the **Auth Token** into both `secrets.h` and `app_config.json`.
5. Copy `BLYNK_TEMPLATE_ID` / `BLYNK_TEMPLATE_NAME` from the template's *Firmware configuration* into `secrets.h`.

To check from the PC whether the board is online:
```powershell
curl.exe "https://blynk.cloud/external/api/isHardwareConnected?token=<AUTH_TOKEN>"
```
`true` means online.

---

## 6. ESP32 two-pump sprayer

Firmware: **`ardunio\ai_nozzle_pumps\ai_nozzle_pumps.ino`**

### 6.1 Wiring

| | Classic ESP32 (4-relay WROOM-32E board) | ESP32-S3 |
|---|---|---|
| Pump 1 relay | GPIO26 (RLY-1) | GPIO15 |
| Pump 2 relay | GPIO25 (RLY-2) | GPIO16 |

The firmware picks the pins automatically for the board it's compiled for. The relays are **active-HIGH**.

Wire each pump **in series through its relay**:
```
Pump battery +  ──► Relay COM
Relay NO        ──► Pump +
Pump −          ──► Pump battery −
```
- Never connect the relay contacts across the pump's own + and − wires.
- Power the pumps from **their own battery**, not the ESP32. A separate relay module needs a real **5 V** supply and a **shared GND** with the ESP32.

### 6.2 Install the board support (one time)
```powershell
arduino-cli core update-index
arduino-cli core install esp32:esp32
arduino-cli lib install Blynk
```

### 6.3 Flash
Plug the ESP32 in with a **data** USB cable, directly into the laptop (not through a hub), then find its port:
```powershell
arduino-cli board list
# or:
Get-PnpDevice -PresentOnly -Class Ports | Where-Object { $_.InstanceId -notmatch 'BTHENUM' }
```
Look for `USB-SERIAL CH340 (COMxx)`. The number changes between plug-ins (COM18, COM19…). The COM3–COM14 entries are Bluetooth ports; ignore them.

```powershell
arduino-cli compile --upload -p COM19 --fqbn esp32:esp32:esp32:UploadSpeed=115200 ardunio/ai_nozzle_pumps
arduino-cli monitor -p COM19 -c baudrate=115200
```
- `UploadSpeed=115200` is slower but survives a flaky USB cable.
- For an **ESP32-S3**, use `--fqbn esp32:esp32:esp32s3`, adding `:CDCOnBoot=cdc` on its native-USB port.
- Unplug the pump battery while flashing.

A good boot log:
```
===== AI NOZZLE STARTING =====
Relay pins: pump1=GPIO26 pump2=GPIO25
[OK] WiFi connected. IP 10.42.0.98  RSSI -54 dBm
[11858] Certificate OK
[11914] Ready (ping: 54ms).
[OK] Blynk connected
```

### 6.4 How it sprays (settings at the top of the `.ino`)

| Setting | Value | Meaning |
|---|---|---|
| `DAMAGE_MEDIUM` / `DAMAGE_HIGH` | 15 / 35 | Damage bands (same as the app) |
| `SPRAY_MS_LOW` | 1 s | Diseased leaf, minor issue (< 15% damage) |
| `SPRAY_MS_MEDIUM` | 2 s | Moderate issue (15–35%) |
| `SPRAY_MS_HIGH_MIN` / `SPRAY_MS_MAX` | 3 s / 5 s | Severe: grows from 35% up to `FULL_DOSE_DAMAGE` (60%) |
| `COOLDOWN_MS` | 5 s | Minimum gap between auto sprays |
| `MANUAL_MAX_MS` | 60 s | A manual pump (V0/V1) stops by itself |

**Healthy leaves never spray:** the AI model has a `Healthy` class, and the app only sends a damage value to the board when the leaf is classified as **diseased**. Healthy and low-confidence ("Uncertain") results are not sent.

Built-in safety: the relays stay off at boot, scans are ignored while the pumps are busy or cooling down, and both pumps stop if the board goes offline.

### 6.5 Bench tests without WiFi
| Sketch | What it does |
|---|---|
| `single_pump_test` | Relay 1 only. Serial `on`, `off`, `t 5`, `a` |
| `two_relay_test` | Both relays on/off in a cycle |
| `relay_motor_test` | All 4 relays. Serial `1`–`4`, `b`, `0`, `a` |
| `serial_spray_test` | Type a damage % to try the spray rules |

Flash these the same way, e.g. `... ardunio/two_relay_test`. Serial Monitor runs at 115200 baud with the line ending set to **Newline**. Flash `ai_nozzle_pumps` again afterwards.

---

## 7. Flutter tablet app

### Setup (one time)
```powershell
cd flutter_app
flutter pub get
```

### Connect the tablet (wireless debugging)
On the tablet: **Developer options → Wireless debugging → ON**.

```powershell
$env:ADB_MDNS = "0"          # stops adb from adding duplicate "adb-XXXX._adb-tls-connect" entries
adb kill-server
adb pair <tablet-ip>:<pair-port> <6-digit-code>   # "Pair device with pairing code" screen (first time / new network)
adb connect <tablet-ip>:<port>                    # IP & port on the main Wireless debugging screen
adb devices                                       # should show exactly ONE line: <tablet-ip>:<port>  device
```
> `$env:ADB_MDNS = "0"` only applies to the current PowerShell window. Without it, Flutter fails with
> `adb.exe: device 'adb-XXXX' not found`.

### Run / build
```powershell
cd C:\Users\Vishn\Documents\Projects\Ai_server\Ai_nozzel\Ai_Nozzle\flutter_app
flutter run --release -d <tablet-ip>:<port> --dart-define-from-file=config/app_config.json
```
- Run `flutter` from inside `flutter_app\`. Anywhere else you get *"No pubspec.yaml file found"*.
- Always use `--release`. The debug APK is about 200 MB and drops the wireless connection while installing.
- Always pass `--dart-define-from-file`, or the app starts with no backend URL or Blynk token.

To build an APK for sideloading instead:
```powershell
flutter build apk --release --dart-define-from-file=config/app_config.json
# → build\app\outputs\flutter-apk\app-release.apk
```

`targetSdk` is deliberately kept at **27** in `android\app\build.gradle.kts`, because the USB webcam library needs it. The `lint { disable += "ExpiredTargetSdkVersion" }` block next to it lets release builds pass. Don't remove either.

### Using the app
- **⚙ Settings:** backend URL, Blynk server/token, live-scan interval. **Test connections** checks both. Values saved here override `app_config.json`.
- **Top-right toggle:** switches between **on-device** inference (offline) and **server** inference.
- **Camera / Live Camera:** use the USB/OTG webcam. Each result is sent to Blynk V4, which drives the pumps.

---

## 8. End-to-end test

1. `curl.exe http://localhost:8000/api/crop/health` → `ok`
2. Blynk `isHardwareConnected` → `true` (or the device shows Online in Blynk Console)
3. App ⚙ → **Test connections** → Backend OK, Blynk OK
4. Scan a diseased leaf → *Sent NN% to sprayer*
5. If NN ≥ 15: the serial log shows `===== AUTO SPRAY: pump 1 + 2 … =====`, both pumps run, V5 goes 1 → 0, and the app's *Sprayer* card follows.

To fire a test spray **without the app** (both pumps will run, so point the nozzles somewhere safe):
```powershell
curl.exe "https://blynk.cloud/external/api/update?token=<AUTH_TOKEN>&V4=50"
```

### Live Scan

Live Scan always analyses on the tablet (it never waits for the server), about 1–2 s per scan. Camera resolution and the red/blue colour fix for the USB camera are under ⚙ Settings.

---

## Changing networks

When the PC, the tablet or the sprayer moves to a different WiFi:

| What changed | Do this |
|---|---|
| PC's IP | Run `ipconfig`, then update app ⚙ Settings → backend URL (and `app_config.json`) |
| Tablet's network | Run `adb pair` and `adb connect` again (section 7) |
| ESP32's WiFi | Edit `WIFI_SSID` / `WIFI_PASS` in `secrets.h` and flash again (section 6.3) |
| New network is *Public* | Add the firewall rule from section 4 (`-Profile Any`) |

The ESP32 doesn't care about the PC's IP. It only needs internet access.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `.\mvnw.cmd ... not recognized` | Wrong folder. `cd spring_backend\spring_backend_fresh\spring_backend` |
| ML server: Keras / model load error | Wrong Python. Use `ai_service\.venv\Scripts\python` |
| `No pubspec.yaml file found` | Run `flutter` from inside `flutter_app\` |
| `adb.exe: device 'adb-XXXX' not found` | Duplicate mDNS entry. `$env:ADB_MDNS="0"; adb kill-server; adb connect <ip:port>` and pass `-d <ip:port>` |
| `lintVitalRelease` / `ExpiredTargetSdkVersion` | The `lint { }` block in `android\app\build.gradle.kts` is missing. Put it back |
| App: Backend failed | Wrong IP in ⚙ Settings, different WiFi, or port 8000 blocked by the firewall |
| App: Blynk failed | Wrong token, or a different region host (e.g. `blr1.blynk.cloud`) |
| ESP32 log: `reason 201 (NO_AP_FOUND)` | WiFi name not in range, or the network is 5 GHz only. Fix `secrets.h` |
| ESP32 on WiFi but stuck at `Connecting to blynk.cloud:80` | The network/hotspot breaks port 80. The firmware must use `#include <BlynkSimpleEsp32_SSL.h>` (port 443). That's already the default |
| ESP32 goes offline when the pumps start / random resets | The pumps are pulling the ESP32's supply down. Use a separate pump battery with only GND shared |
| No COM port / port vanishes mid-upload | Charge-only or flaky cable, or a hub. Use a data cable directly into the laptop, with `UploadSpeed=115200`. Hold **BOOT** if it still fails |
| Pumps spray too much / too little | Change `SPRAY_MS_LOW` / `SPRAY_MS_MEDIUM` / `SPRAY_MS_HIGH_MIN` / `SPRAY_MS_MAX` and flash again |
| Relay clicks, pump doesn't run | Wiring: COM/NO in series with the pump's battery. The relay module needs 5 V and shared GND |

**Keep the thresholds the same in all three places:** `ai_service\.env` (`DAMAGE_MEDIUM`, `DAMAGE_HIGH`), `flutter_app\config\app_config.json`, and `DAMAGE_MEDIUM` / `DAMAGE_HIGH` in the firmware.

More detail: [README.md](README.md) (architecture and API) · [DEPLOYMENT.md](DEPLOYMENT.md) · [connection_setup.md](connection_setup.md) (older L293D motor wiring).
