/*
 * Two relays together — no WiFi, no Blynk.
 *
 * Switches relay 1 and relay 2 ON at the same time for ON_MS, then both
 * OFF for OFF_MS, and repeats.
 *
 * 4-relay ESP32-WROOM-32E board: RLY-1 IO26, RLY-2 IO25 (energise on HIGH).
 * ESP32-S3 bench board:          relay 1 GPIO15, relay 2 GPIO16.
 *
 * Serial Monitor (115200 baud) — optional:
 *   b  both on (stops the cycle)    0  both off (stops the cycle)
 *   a  back to the automatic cycle
 */

#if CONFIG_IDF_TARGET_ESP32S3
#define RELAY1 15
#define RELAY2 16
#else
#define RELAY1 26
#define RELAY2 25
#endif

#define RELAY_ACTIVE_HIGH 1

#if RELAY_ACTIVE_HIGH
#define RELAY_ON  HIGH
#define RELAY_OFF LOW
#else
#define RELAY_ON  LOW
#define RELAY_OFF HIGH
#endif

#define ON_MS   3000
#define OFF_MS  3000

bool relaysOn = false;
bool autoMode = true;
unsigned long phaseStart = 0;

void setBoth(bool on) {
  relaysOn = on;
  digitalWrite(RELAY1, on ? RELAY_ON : RELAY_OFF);
  digitalWrite(RELAY2, on ? RELAY_ON : RELAY_OFF);
  phaseStart = millis();
  Serial.printf("[%7lu ms] Relay 1 + Relay 2 %s\n", millis(), on ? "ON" : "off");
}

void setup() {
  // Set the OFF level before enabling the outputs so nothing clicks at boot.
  digitalWrite(RELAY1, RELAY_OFF);
  digitalWrite(RELAY2, RELAY_OFF);
  pinMode(RELAY1, OUTPUT);
  pinMode(RELAY2, OUTPUT);

  Serial.begin(115200);
  delay(500);
  Serial.println("\n===== TWO RELAYS TOGETHER =====");
  Serial.printf("Relay 1 = GPIO%d, Relay 2 = GPIO%d\n", RELAY1, RELAY2);
  Serial.printf("Cycle: both ON %d ms, both OFF %d ms. Keys: b on, 0 off, a auto\n",
                ON_MS, OFF_MS);
  setBoth(true);
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == 'b' || c == 'B') { autoMode = false; setBoth(true); }
    else if (c == '0')        { autoMode = false; setBoth(false); }
    else if (c == 'a' || c == 'A') { autoMode = true; setBoth(true); }
  }

  if (autoMode && millis() - phaseStart >= (relaysOn ? ON_MS : OFF_MS)) {
    setBoth(!relaysOn);
  }
}
