/*
 * Relay + motor bench test — no WiFi, no Blynk.
 *
 * For the 4-relay ESP32-WROOM-32E board (RLY-1 IO26, RLY-2 IO25,
 * RLY-3 IO33, RLY-4 IO32; relays energise on HIGH).
 *
 * AUTO mode (default) repeats:
 *   RLY-1 on 3 s -> off 2 s -> RLY-2 on 3 s -> off 2 s -> both on 3 s -> off 3 s
 *
 * Serial Monitor (115200 baud) commands:
 *   1  toggle RLY-1 (pump 1)       2  toggle RLY-2 (pump 2)
 *   3  toggle RLY-3                4  toggle RLY-4
 *   b  both pumps on               0  everything off
 *   a  back to AUTO mode           any command above switches to MANUAL
 */

#define RELAY_ACTIVE_HIGH 1

#if RELAY_ACTIVE_HIGH
#define RELAY_ON  HIGH
#define RELAY_OFF LOW
#else
#define RELAY_ON  LOW
#define RELAY_OFF HIGH
#endif

#if CONFIG_IDF_TARGET_ESP32S3
// ESP32-S3: GPIO26–37 are wired to flash/PSRAM. Pumps match ai_nozzle_pumps.
const int RELAY_PINS[] = {15, 16, 17, 18};   // RLY-1 .. RLY-4
#else
const int RELAY_PINS[] = {26, 25, 33, 32};   // RLY-1 .. RLY-4
#endif
const int RELAY_COUNT = 4;

bool relayOn[RELAY_COUNT] = {false, false, false, false};
bool autoMode = true;
int step = 0;
unsigned long stepStart = 0;

void setRelay(int i, bool on) {
  relayOn[i] = on;
  digitalWrite(RELAY_PINS[i], on ? RELAY_ON : RELAY_OFF);
}

void printState(const char *why) {
  Serial.printf("[%7lu ms] %-14s RLY-1=%s  RLY-2=%s  RLY-3=%s  RLY-4=%s\n",
                millis(), why,
                relayOn[0] ? "ON " : "off", relayOn[1] ? "ON " : "off",
                relayOn[2] ? "ON " : "off", relayOn[3] ? "ON " : "off");
}

void allOff() {
  for (int i = 0; i < RELAY_COUNT; i++) setRelay(i, false);
}

// AUTO sequence: {pump1, pump2, duration ms, label}
struct Step { bool p1, p2; unsigned long ms; const char *label; };
const Step SEQUENCE[] = {
  {true,  false, 3000, "PUMP 1 only"},
  {false, false, 2000, "off"},
  {false, true,  3000, "PUMP 2 only"},
  {false, false, 2000, "off"},
  {true,  true,  3000, "BOTH pumps"},
  {false, false, 3000, "off"},
};
const int STEP_COUNT = sizeof(SEQUENCE) / sizeof(SEQUENCE[0]);

void startStep(int s) {
  step = s;
  stepStart = millis();
  setRelay(0, SEQUENCE[s].p1);
  setRelay(1, SEQUENCE[s].p2);
  printState(SEQUENCE[s].label);
}

void setup() {
  // Set the OFF level before enabling outputs so nothing clicks on at boot.
  for (int i = 0; i < RELAY_COUNT; i++) {
    digitalWrite(RELAY_PINS[i], RELAY_OFF);
    pinMode(RELAY_PINS[i], OUTPUT);
  }

  Serial.begin(115200);
  delay(500);
  Serial.println("\n===== RELAY / MOTOR TEST (no WiFi) =====");
  Serial.printf("Relay pins: RLY-1=GPIO%d RLY-2=GPIO%d RLY-3=GPIO%d RLY-4=GPIO%d\n",
                RELAY_PINS[0], RELAY_PINS[1], RELAY_PINS[2], RELAY_PINS[3]);
  Serial.println("AUTO: pump1 3s, pump2 3s, both 3s, repeat");
  Serial.println("Keys: 1/2/3/4 toggle relay, b both pumps, 0 all off, a auto");
  startStep(0);
}

void handleCommand(char c) {
  switch (c) {
    case '1': case '2': case '3': case '4': {
      int i = c - '1';
      autoMode = false;
      setRelay(i, !relayOn[i]);
      printState("MANUAL toggle");
      break;
    }
    case 'b': case 'B':
      autoMode = false;
      allOff();
      setRelay(0, true);
      setRelay(1, true);
      printState("MANUAL both");
      break;
    case '0':
      autoMode = false;
      allOff();
      printState("MANUAL all off");
      break;
    case 'a': case 'A':
      autoMode = true;
      allOff();
      Serial.println("Back to AUTO");
      startStep(0);
      break;
    default:
      break;   // ignore newlines etc.
  }
}

void loop() {
  while (Serial.available()) handleCommand(Serial.read());

  if (autoMode && millis() - stepStart >= SEQUENCE[step].ms) {
    startStep((step + 1) % STEP_COUNT);
  }
}
