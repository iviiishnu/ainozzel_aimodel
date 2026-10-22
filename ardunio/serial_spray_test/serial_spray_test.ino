/*
 * Wired spray test — no WiFi, no Blynk.
 *
 * Same spray rules as ai_nozzle_pumps, but the damage % is typed in the
 * Serial Monitor (115200 baud, line ending "Newline") instead of coming
 * from the app via Blynk V4.
 *
 * Commands:
 *   0–100   damage %  -> auto spray by the rules below
 *   p1      toggle pump 1 (manual)
 *   p2      toggle pump 2 (manual)
 *   s       stop everything
 *   ?       show rules and state
 *
 * Rules (keep in sync with ai_nozzle_pumps / AppConfig):
 *   < 15 %   no spray
 *   15–24 %  pump 1, 3 s        25–34 %  pump 1, 5 s
 *   35–49 %  pump 1 + 2, 7 s    >= 50 %  pump 1 + 2, 10 s
 */

/******************** RELAY PINS ********************/
#if CONFIG_IDF_TARGET_ESP32S3
#define PUMP1_RELAY 15
#define PUMP2_RELAY 16
#else
#define PUMP1_RELAY 26
#define PUMP2_RELAY 25
#endif

#define RELAY_ACTIVE_HIGH 1

#if RELAY_ACTIVE_HIGH
#define RELAY_ON  HIGH
#define RELAY_OFF LOW
#else
#define RELAY_ON  LOW
#define RELAY_OFF HIGH
#endif

/******************** SPRAY SETTINGS ********************/
#define SPRAY_MIN_DAMAGE   15
#define BOTH_PUMPS_DAMAGE  35

#define SPRAY_MS_MEDIUM    3000   // 15–24 %
#define SPRAY_MS_MEDIUM2   5000   // 25–34 %
#define SPRAY_MS_HIGH      7000   // 35–49 %
#define SPRAY_MS_SEVERE   10000   // ≥ 50 %

#define COOLDOWN_MS        5000
#define MANUAL_MAX_MS     60000

/******************** STATE ********************/
enum Mode { IDLE, AUTO_SPRAY, MANUAL };

Mode mode = IDLE;
unsigned long modeStart = 0;
unsigned long modeDuration = 0;
unsigned long lastSprayEnd = 0;
bool hasSprayed = false;
bool pump1On = false;
bool pump2On = false;
String line;

void setPumps(bool p1, bool p2) {
  pump1On = p1;
  pump2On = p2;
  digitalWrite(PUMP1_RELAY, p1 ? RELAY_ON : RELAY_OFF);
  digitalWrite(PUMP2_RELAY, p2 ? RELAY_ON : RELAY_OFF);
  Serial.printf("Pumps: 1=%s 2=%s\n", p1 ? "ON" : "off", p2 ? "ON" : "off");
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

void printHelp() {
  Serial.println("Type a damage % (0-100) and press Enter.");
  Serial.println("  <15 none | 15-24 P1 3s | 25-34 P1 5s | 35-49 P1+P2 7s | >=50 P1+P2 10s");
  Serial.println("  p1 / p2 toggle a pump, s stop, ? help");
  Serial.printf("State: %s  pump1=%s pump2=%s\n",
                mode == IDLE ? "IDLE" : mode == AUTO_SPRAY ? "AUTO_SPRAY" : "MANUAL",
                pump1On ? "ON" : "off", pump2On ? "ON" : "off");
}

void handleDamage(int damage) {
  Serial.printf("Damage received: %d%%\n", damage);

  if (damage < SPRAY_MIN_DAMAGE) {
    Serial.println("Below spray threshold - no spray");
    return;
  }
  if (mode != IDLE) {
    Serial.println("Pumps busy - ignoring");
    return;
  }
  if (hasSprayed && millis() - lastSprayEnd < COOLDOWN_MS) {
    Serial.printf("Cooldown - ignoring (%lu ms left)\n",
                  COOLDOWN_MS - (millis() - lastSprayEnd));
    return;
  }

  bool both = damage >= BOTH_PUMPS_DAMAGE;
  unsigned long duration = sprayDurationFor(damage);
  Serial.printf("===== AUTO SPRAY: %s for %lu ms =====\n",
                both ? "pump 1 + 2" : "pump 1", duration);
  setPumps(true, both);
  enterMode(AUTO_SPRAY, duration);
}

void toggleManual(int pump) {
  bool p1 = mode == MANUAL && pump1On;
  bool p2 = mode == MANUAL && pump2On;
  if (pump == 1) p1 = !p1; else p2 = !p2;
  setPumps(p1, p2);
  if (p1 || p2) enterMode(MANUAL, MANUAL_MAX_MS);
  else enterMode(IDLE, 0);
}

void handleLine(String cmd) {
  cmd.trim();
  cmd.toLowerCase();
  if (cmd.length() == 0) return;

  if (cmd == "s") { stopAll(); Serial.println("Stopped"); return; }
  if (cmd == "?") { printHelp(); return; }
  if (cmd == "p1") { toggleManual(1); return; }
  if (cmd == "p2") { toggleManual(2); return; }

  for (unsigned int i = 0; i < cmd.length(); i++) {
    if (!isDigit(cmd[i])) {
      Serial.printf("Unknown command \"%s\" - type ? for help\n", cmd.c_str());
      return;
    }
  }
  handleDamage(constrain(cmd.toInt(), 0, 100));
}

void setup() {
  // Set the OFF level before enabling the pins as outputs so the
  // relays don't click on at boot.
  digitalWrite(PUMP1_RELAY, RELAY_OFF);
  digitalWrite(PUMP2_RELAY, RELAY_OFF);
  pinMode(PUMP1_RELAY, OUTPUT);
  pinMode(PUMP2_RELAY, OUTPUT);

  Serial.begin(115200);
  delay(500);
  Serial.println("\n===== WIRED SPRAY TEST (no WiFi) =====");
  Serial.printf("Relay pins: pump1=GPIO%d pump2=GPIO%d\n", PUMP1_RELAY, PUMP2_RELAY);
  printHelp();
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      handleLine(line);
      line = "";
    } else if (line.length() < 16) {
      line += c;
    }
  }

  if (mode != IDLE && millis() - modeStart >= modeDuration) {
    Serial.println(mode == AUTO_SPRAY ? "===== SPRAY COMPLETE =====" : "Manual run timed out");
    stopAll();
  }
}
