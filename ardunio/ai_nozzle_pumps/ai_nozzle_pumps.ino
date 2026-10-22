/*
 * AI Nozzle — ESP32 / ESP32-S3 + Blynk + 2 pumps on relays (polarity: RELAY_ACTIVE_HIGH)
 *
 * The app writes the leaf damage % to V4 ONLY for leaves the AI model calls
 * diseased (healthy / unsure leaves are never sent). The board then runs
 * pump 1 + pump 2 together for a time set by the damage:
 *   damage <  DAMAGE_MEDIUM (minor issue)   -> SPRAY_MS_LOW    (1 s)
 *   damage <  DAMAGE_HIGH   (moderate)      -> SPRAY_MS_MEDIUM (2 s)
 *   damage >= DAMAGE_HIGH   (severe)        -> SPRAY_MS_HIGH_MIN … SPRAY_MS_MAX
 *   damage <= 0                             -> no spray
 * (Pump 2 can be left unwired — its relay just clicks with no load.)
 *
 * Credentials live in secrets.h (not committed) — copy secrets.example.h.
 *
 * Blynk datastreams (Integer):
 *   V0 pump 1 manual  (switch, 0/1)
 *   V1 pump 2 manual  (switch, 0/1)
 *   V4 damage %       (0–100, written by the app)
 *   V5 pump status    (0/1, written by this board)
 */

#include "secrets.h"   // BLYNK_TEMPLATE_ID, BLYNK_TEMPLATE_NAME, BLYNK_AUTH_TOKEN, WIFI_SSID, WIFI_PASS

#define BLYNK_PRINT Serial

#include <WiFi.h>
#include <BlynkSimpleEsp32_SSL.h>   // TLS on 443: plain port 80 is broken by some hotspot/carrier proxies
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"   // brownout register (DISABLE_BROWNOUT)

/******************** RELAY PINS ********************/
#if CONFIG_IDF_TARGET_ESP32S3
// ESP32-S3: GPIO25 does not exist and GPIO26–32 are wired to flash/PSRAM.
#define PUMP1_RELAY 15
#define PUMP2_RELAY 16
#else
#define PUMP1_RELAY 26
#define PUMP2_RELAY 25
#endif

// 1 = relay energises on HIGH (ESP32 boards with onboard relays, e.g. the
//     4-relay ESP32-WROOM-32E board: RLY-1 IO26, RLY-2 IO25, RLY-3 IO33, RLY-4 IO32)
// 0 = relay energises on LOW (typical separate opto-isolated relay modules)
#define RELAY_ACTIVE_HIGH 1

#if RELAY_ACTIVE_HIGH
#define RELAY_ON  HIGH
#define RELAY_OFF LOW
#else
#define RELAY_ON  LOW
#define RELAY_OFF HIGH
#endif

/******************** SPRAY SETTINGS ********************/
// Damage bands — must match the app (AppConfig.damageMedium / damageHigh).
// The app decides WHETHER to spray (only diseased leaves); these only decide
// for HOW LONG.
#define DAMAGE_MEDIUM      15
#define DAMAGE_HIGH        35
#define FULL_DOSE_DAMAGE   60     // longest spray from here up

#define SPRAY_MS_LOW       1000   // minor issue: short burst (pump primes in ~1 s)
#define SPRAY_MS_MEDIUM    2000   // moderate issue
#define SPRAY_MS_HIGH_MIN  3000   // severe: grows from this …
#define SPRAY_MS_MAX       5000   // … to this at FULL_DOSE_DAMAGE (hard cap)

// Pump 2 starts this long after pump 1. Two motors starting at the same
// instant draw a combined inrush spike that sags the supply and stalls one.
#define PUMP_STAGGER_MS     300

#define COOLDOWN_MS        5000   // min gap between automatic sprays
#define MANUAL_MAX_MS     60000   // a manual pump auto-stops after this
#define RECONNECT_MS      10000

/******************** RUNNING WITHOUT A LAPTOP ********************/
// Offline this long (no WiFi or no Blynk) → reboot and start clean. Recovers
// from a stuck WiFi stack, a router/hotspot that came up after the board, etc.
#define OFFLINE_RESTART_MS  180000UL   // 3 min

// Status LED so you can see what the board is doing with no serial monitor:
//   fast blink (5/s)   joining WiFi
//   slow blink (1/s)   WiFi OK, connecting to Blynk
//   steady on          online in Blynk — ready to spray
//   off                pumps running (LED shares the supply; keeps it simple)
// Classic ESP32 dev boards have a blue LED on GPIO2. Set -1 for none
// (e.g. ESP32-S3 boards, whose LED is an addressable RGB on GPIO48).
#if CONFIG_IDF_TARGET_ESP32S3
#define STATUS_LED -1
#else
#define STATUS_LED 2
#endif

// Bench debugging only: 1 keeps the board running through the WiFi start-up
// current spike on a weak USB supply so the serial log can be read.
// Leave at 0 for real use — a browned-out chip can misbehave.
#define DISABLE_BROWNOUT 0

/******************** POWER ********************/
// WiFi start-up and transmit bursts pull large current spikes that brown
// out boards on weak supplies. These trade speed and range for lower draw.
#define CPU_MHZ              80                 // 80 is the minimum with WiFi (default 240)
#define WIFI_TX_POWER        WIFI_POWER_2dBm    // short range (~5–10 m); raise to
                                                // WIFI_POWER_8_5dBm / 11dBm if the signal is weak
#define WIFI_START_DELAY_MS  1500               // let the supply settle before the radio starts

/******************** STATE ********************/
enum Mode { IDLE, AUTO_SPRAY, MANUAL };

Mode mode = IDLE;
unsigned long modeStart = 0;
unsigned long modeDuration = 0;
unsigned long lastSprayEnd = 0;
bool hasSprayed = false;
bool pump1On = false;
bool pump2On = false;
int lastReportedStatus = -1;
unsigned long lastReconnectTry = 0;
unsigned long lastOnline = 0;   // last time Blynk was connected (or boot)

// Known networks: tried in turn until one connects. WIFI_SSID2 (optional in
// secrets.h) lets the same firmware join home WiFi on the bench and the
// phone hotspot in the field.
const char* const WIFI_SSIDS[] = {WIFI_SSID
#ifdef WIFI_SSID2
  , WIFI_SSID2
#endif
};
const char* const WIFI_PASSES[] = {WIFI_PASS
#ifdef WIFI_SSID2
  , WIFI_PASS2
#endif
};
const int WIFI_COUNT = sizeof(WIFI_SSIDS) / sizeof(WIFI_SSIDS[0]);
int wifiIndex = 0;

/// Starts joining network [wifiIndex] at reduced TX power (non-blocking).
void beginWifi() {
  Serial.printf("[WiFi] trying \"%s\"\n", WIFI_SSIDS[wifiIndex]);
  WiFi.disconnect();
  WiFi.begin(WIFI_SSIDS[wifiIndex], WIFI_PASSES[wifiIndex]);
  WiFi.setTxPower(WIFI_TX_POWER);   // after begin(), before the handshake peaks
}

void nextWifi() {
  wifiIndex = (wifiIndex + 1) % WIFI_COUNT;
  beginWifi();
}

/******************** STATUS LED ********************/
void updateStatusLed() {
#if STATUS_LED >= 0
  bool on;
  if (pump1On || pump2On)                  on = false;
  else if (Blynk.connected())              on = true;
  else if (WiFi.status() == WL_CONNECTED)  on = (millis() / 500) % 2;   // 1 Hz
  else                                     on = (millis() / 100) % 2;   // 5 Hz
  digitalWrite(STATUS_LED, on ? HIGH : LOW);
#endif
}

/// Waits [ms] while keeping the status LED blinking.
void waitBlinking(unsigned long ms) {
  unsigned long start = millis();
  while (millis() - start < ms) {
    updateStatusLed();
    delay(20);
  }
}

/******************** PUMP OUTPUTS ********************/
void reportStatus() {
  int running = (pump1On || pump2On) ? 1 : 0;
  if (running != lastReportedStatus && Blynk.connected()) {
    Blynk.virtualWrite(V5, running);
    lastReportedStatus = running;
  }
}

void setPumps(bool p1, bool p2) {
  pump1On = p1;
  pump2On = p2;
  digitalWrite(PUMP1_RELAY, p1 ? RELAY_ON : RELAY_OFF);
  digitalWrite(PUMP2_RELAY, p2 ? RELAY_ON : RELAY_OFF);
  Serial.printf("Pumps: 1=%s 2=%s\n", p1 ? "ON" : "off", p2 ? "ON" : "off");
  reportStatus();
}

void enterMode(Mode next, unsigned long durationMs) {
  mode = next;
  modeStart = millis();
  modeDuration = durationMs;
}

void stopAll() {
  if (mode == AUTO_SPRAY) {
    lastSprayEnd = millis();
    hasSprayed = true;
  }
  setPumps(false, false);
  enterMode(IDLE, 0);
}

unsigned long sprayDurationFor(int damage) {
  if (damage < DAMAGE_MEDIUM) return SPRAY_MS_LOW;
  if (damage < DAMAGE_HIGH)   return SPRAY_MS_MEDIUM;
  float t = (float)(damage - DAMAGE_HIGH) / (FULL_DOSE_DAMAGE - DAMAGE_HIGH);
  t = constrain(t, 0.0f, 1.0f);
  return SPRAY_MS_HIGH_MIN + (unsigned long)(t * (SPRAY_MS_MAX - SPRAY_MS_HIGH_MIN));
}

/******************** MANUAL CONTROLS ********************/
void manualChanged() {
  if (pump1On || pump2On) {
    enterMode(MANUAL, MANUAL_MAX_MS);
  } else {
    enterMode(IDLE, 0);
  }
}

BLYNK_WRITE(V0) {
  setPumps(param.asInt() == 1, mode == MANUAL && pump2On);
  manualChanged();
}

BLYNK_WRITE(V1) {
  setPumps(mode == MANUAL && pump1On, param.asInt() == 1);
  manualChanged();
}

/******************** AI DAMAGE INPUT ********************/
BLYNK_WRITE(V4) {
  int damage = param.asInt();
  Serial.printf("Damage received: %d%%\n", damage);

  if (damage <= 0) {
    Serial.println("No damage — no spray");
    return;
  }
  if (mode != IDLE) {
    Serial.println("Pumps busy — ignoring");
    return;
  } 
  if (hasSprayed && millis() - lastSprayEnd < COOLDOWN_MS) {
    Serial.println("Cooldown — ignoring");
    return;
  }

  unsigned long duration = sprayDurationFor(damage);
  Serial.printf("===== AUTO SPRAY: pump 1 + 2 for %lu ms =====\n", duration);
  // Pump 2 joins after PUMP_STAGGER_MS (see loop); extend so it still gets
  // the full duration.
  setPumps(true, false);
  enterMode(AUTO_SPRAY, duration + PUMP_STAGGER_MS);
}

BLYNK_CONNECTED() {
  Serial.println("[OK] Blynk connected");
  // Manual switches start off after (re)connecting; publish the real state.
  Blynk.virtualWrite(V0, 0);
  Blynk.virtualWrite(V1, 0);
  lastReportedStatus = -1;
  reportStatus();
}

/******************** SETUP ********************/
void setup() {
  // Set the OFF level before enabling the pins as outputs so the
  // relays don't click on at boot.
  digitalWrite(PUMP1_RELAY, RELAY_OFF);
  digitalWrite(PUMP2_RELAY, RELAY_OFF);
  pinMode(PUMP1_RELAY, OUTPUT);
  pinMode(PUMP2_RELAY, OUTPUT);
#if STATUS_LED >= 0
  pinMode(STATUS_LED, OUTPUT);
#endif

  // Lower the CPU clock before anything else to cut the baseline current.
  setCpuFrequencyMhz(CPU_MHZ);

  Serial.begin(115200);
  delay(1000);
  Serial.println("\n===== AI NOZZLE STARTING =====");
  Serial.printf("Relay pins: pump1=GPIO%d pump2=GPIO%d\n", PUMP1_RELAY, PUMP2_RELAY);
  Serial.printf("CPU %lu MHz, WiFi TX power %.1f dBm\n",
                getCpuFrequencyMhz(), (int)WIFI_TX_POWER / 4.0);

#if DISABLE_BROWNOUT
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);
  Serial.println("[WARN] Brownout detector disabled (bench debug)");
#endif

  // Say why WiFi dropped (wrong password, AP not found, handshake timeout…).
  WiFi.onEvent([](WiFiEvent_t, WiFiEventInfo_t info) {
    uint8_t reason = info.wifi_sta_disconnected.reason;
    Serial.printf("\n[WiFi] disconnected, reason %u (%s)\n", reason,
                  WiFi.disconnectReasonName((wifi_err_reason_t)reason));
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);

  // Full-power WiFi start-up draws a current spike that browns out boards
  // on weak supplies, so start late and connect at reduced TX power.
  waitBlinking(WIFI_START_DELAY_MS);
  Serial.println("Starting WiFi radio...");
  WiFi.mode(WIFI_STA);
  WiFi.setTxPower(WIFI_TX_POWER);
  WiFi.setSleep(true);   // modem sleep between beacons
  // ~10 s per known network, twice round, then carry on and let loop() retry.
  for (int attempt = 0; attempt < 2 * WIFI_COUNT && WiFi.status() != WL_CONNECTED; attempt++) {
    if (attempt == 0) beginWifi(); else nextWifi();
    for (int i = 0; i < 20 && WiFi.status() != WL_CONNECTED; i++) {
      waitBlinking(500);
      Serial.print(".");
    }
    Serial.println();
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\n[OK] WiFi \"%s\" connected. IP %s  RSSI %d dBm\n",
                  WiFi.SSID().c_str(), WiFi.localIP().toString().c_str(), WiFi.RSSI());
  } else {
    Serial.println("\n[ERROR] WiFi failed — will keep retrying");
  }

  Blynk.config(BLYNK_AUTH_TOKEN);
  if (WiFi.status() == WL_CONNECTED && !Blynk.connect(10000)) {
    Serial.println("[ERROR] Blynk failed — check token / network allows internet");
  }
  lastOnline = millis();
}

/******************** LOOP (non-blocking) ********************/
void loop() {
  updateStatusLed();
  if (Blynk.connected()) {
    Blynk.run();
    lastOnline = millis();
  } else {
    if (millis() - lastOnline > OFFLINE_RESTART_MS) {
      Serial.println("[WARN] Offline for 3 min — restarting");
      setPumps(false, false);
      delay(200);
      ESP.restart();
    }
    // Failsafe: never leave a pump running while offline.
    if (pump1On || pump2On) {
      Serial.println("[WARN] Offline — stopping pumps");
      stopAll();
    }
    if (millis() - lastReconnectTry > RECONNECT_MS) {
      lastReconnectTry = millis();
      if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[WARN] WiFi down, reconnecting");
        nextWifi();   // with one network this simply retries it
      } else {
        Serial.println("[WARN] Blynk down, reconnecting");
        Blynk.connect(3000);
      }
    }
  }

  // Staggered start: bring pump 2 in once pump 1's inrush has passed.
  if (mode == AUTO_SPRAY && !pump2On && millis() - modeStart >= PUMP_STAGGER_MS) {
    setPumps(true, true);
  }

  if (mode != IDLE && millis() - modeStart >= modeDuration) {
    Serial.println(mode == AUTO_SPRAY ? "===== SPRAY COMPLETE =====" : "Manual run timed out");
    stopAll();
    if (Blynk.connected()) {
      Blynk.virtualWrite(V0, 0);
      Blynk.virtualWrite(V1, 0);
    }
  }
}
