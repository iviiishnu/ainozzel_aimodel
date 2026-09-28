/*
 * AI Nozzle — ESP32 / ESP32-S3 + Blynk + 2 pumps on an active-LOW relay module
 *
 * The app writes the leaf damage % to V4. The board then sprays automatically:
 *   damage >= SPRAY_MIN_DAMAGE (Medium)  -> pump 1
 *   damage >= BOTH_PUMPS_DAMAGE (High)   -> pump 1 + pump 2
 * for a time that grows with the damage, then switches the pumps off.
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
#include <BlynkSimpleEsp32.h>

/******************** RELAY PINS ********************/
#if CONFIG_IDF_TARGET_ESP32S3
// ESP32-S3: GPIO25 does not exist and GPIO26–32 are wired to flash/PSRAM.
#define PUMP1_RELAY 4
#define PUMP2_RELAY 5
#else
#define PUMP1_RELAY 26
#define PUMP2_RELAY 25
#endif

#define RELAY_ON  LOW    // active-LOW relay module
#define RELAY_OFF HIGH

/******************** SPRAY SETTINGS ********************/
// Must match the app thresholds (AppConfig.damageMedium / damageHigh).
#define SPRAY_MIN_DAMAGE   15
#define BOTH_PUMPS_DAMAGE  35

// Spray duration by damage band (ms)
#define SPRAY_MS_MEDIUM    3000   // 15–24 %
#define SPRAY_MS_MEDIUM2   5000   // 25–34 %
#define SPRAY_MS_HIGH      7000   // 35–49 %
#define SPRAY_MS_SEVERE   10000   // ≥ 50 %

#define COOLDOWN_MS        5000   // min gap between automatic sprays
#define MANUAL_MAX_MS     60000   // a manual pump auto-stops after this
#define RECONNECT_MS      10000

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
  if (damage < 25) return SPRAY_MS_MEDIUM;
  if (damage < 35) return SPRAY_MS_MEDIUM2;
  if (damage < 50) return SPRAY_MS_HIGH;
  return SPRAY_MS_SEVERE;
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

  if (damage < SPRAY_MIN_DAMAGE) {
    Serial.println("Below spray threshold — no spray");
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

  bool both = damage >= BOTH_PUMPS_DAMAGE;
  unsigned long duration = sprayDurationFor(damage);
  Serial.printf("===== AUTO SPRAY: %s for %lu ms =====\n",
                both ? "pump 1 + 2" : "pump 1", duration);
  setPumps(true, both);
  enterMode(AUTO_SPRAY, duration);
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
  // Drive the pins HIGH before enabling them as outputs so the
  // active-LOW relays don't click on at boot.
  digitalWrite(PUMP1_RELAY, RELAY_OFF);
  digitalWrite(PUMP2_RELAY, RELAY_OFF);
  pinMode(PUMP1_RELAY, OUTPUT);
  pinMode(PUMP2_RELAY, OUTPUT);

  Serial.begin(115200);
  delay(1000);
  Serial.println("\n===== AI NOZZLE STARTING =====");
  Serial.printf("Relay pins: pump1=GPIO%d pump2=GPIO%d\n", PUMP1_RELAY, PUMP2_RELAY);

  // Full-power WiFi start-up draws a current spike that browns out boards
  // on weak supplies, so connect at reduced TX power.
  WiFi.mode(WIFI_STA);
  WiFi.setTxPower(WIFI_POWER_8_5dBm);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  WiFi.setTxPower(WIFI_POWER_8_5dBm);

  Serial.printf("Connecting to WiFi \"%s\"", WIFI_SSID);
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) {
    delay(500);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\n[OK] WiFi connected. IP %s  RSSI %d dBm\n",
                  WiFi.localIP().toString().c_str(), WiFi.RSSI());
  } else {
    Serial.println("\n[ERROR] WiFi failed — will keep retrying");
  }

  Blynk.config(BLYNK_AUTH_TOKEN);
  if (WiFi.status() == WL_CONNECTED && !Blynk.connect(10000)) {
    Serial.println("[ERROR] Blynk failed — check token / network allows internet");
  }
}

/******************** LOOP (non-blocking) ********************/
void loop() {
  if (Blynk.connected()) {
    Blynk.run();
  } else {
    // Failsafe: never leave a pump running while offline.
    if (pump1On || pump2On) {
      Serial.println("[WARN] Offline — stopping pumps");
      stopAll();
    }
    if (millis() - lastReconnectTry > RECONNECT_MS) {
      lastReconnectTry = millis();
      if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[WARN] WiFi down, reconnecting");
        WiFi.reconnect();
      } else {
        Serial.println("[WARN] Blynk down, reconnecting");
        Blynk.connect(3000);
      }
    }
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
