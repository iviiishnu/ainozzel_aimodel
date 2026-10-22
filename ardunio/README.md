# ESP32 Firmware — `ardunio`

## Requirements

| Item | Version |
|---|---|
| Board | ESP32 (classic, e.g. 4-relay ESP32-WROOM-32E board) or ESP32-S3 |
| Arduino core | **esp32 by Espressif 3.3.x** (tested 3.3.12) |
| Library | **Blynk 1.3.x** (tested 1.3.2) |
| Tool | Arduino CLI or Arduino IDE 2 |
| USB driver | CH340 (or CP210x, depending on the board) |

```powershell
arduino-cli core update-index
arduino-cli core install esp32:esp32
arduino-cli lib install Blynk
```

## Sketches

| Folder | Purpose |
|---|---|
| **`ai_nozzle_pumps/`** | ★ **Main firmware.** Blynk + 2 relay pumps, damage-scaled spraying |
| `single_pump_test/` | Relay 1 only, controlled from Serial (no WiFi) |
| `two_relay_test/` | Both relays on/off in a cycle (no WiFi) |
| `relay_motor_test/` | All 4 relays, controlled from Serial (no WiFi) |
| `serial_spray_test/` | Type a damage % in Serial to try the spray rules (no WiFi) |
| `esp32_motor_control/` | Older version: L293D + 12 V DC motor nozzle (see `../connection_setup.md`) |

## Flash the main firmware

```powershell
copy ardunio\ai_nozzle_pumps\secrets.example.h ardunio\ai_nozzle_pumps\secrets.h
# edit secrets.h → Blynk template ID/name, auth token, 2.4 GHz WiFi name/password

arduino-cli board list                                    # find the COM port
arduino-cli compile --upload -p COM19 --fqbn esp32:esp32:esp32:UploadSpeed=115200 ardunio/ai_nozzle_pumps
arduino-cli monitor -p COM19 -c baudrate=115200
```
For an ESP32-S3, use `--fqbn esp32:esp32:esp32s3`.

The expected log ends with `[OK] Blynk connected`.

## Wiring

| | Classic ESP32 | ESP32-S3 |
|---|---|---|
| Pump 1 relay | GPIO26 | GPIO15 |
| Pump 2 relay | GPIO25 | GPIO16 |

The relays are active-HIGH. Wire each pump in series through its relay: battery **+** → relay **COM**, **NO** → pump **+**, pump **−** → battery **−**. Power the pumps from their own battery, with GND shared with the ESP32.

## Behaviour (`ai_nozzle_pumps.ino`)

- **V4 (damage %):** the app only sends it for leaves the AI model calls **diseased** — healthy or unsure leaves are never sent, so the pumps never run for them. Both pumps then run together: **1 s** for a minor issue (< 15% damage), **2 s** for moderate (15–35%), **3–5 s** for severe (35% → 60%+). Tune with `SPRAY_MS_LOW` / `SPRAY_MS_MEDIUM` / `SPRAY_MS_HIGH_MIN` / `SPRAY_MS_MAX`.
- **V0 / V1:** manual pump 1 / pump 2, each with a 60 s auto-stop.
- **V5:** 1 while the pumps are running.
- **Safety:** relays stay off at boot, a 5 s cooldown applies between sprays, scans are ignored while busy, and all pumps stop if Blynk goes offline.
- Connects to Blynk over **TLS (port 443)**, because some hotspots and mobile networks break plain port 80.
