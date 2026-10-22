/*
 * Single pump test on relay 1 — no WiFi, no Blynk.
 *
 * Wiring (relay in SERIES with the pump, one supply wire through the relay):
 *   Pump supply +  -> Relay 1 COM
 *   Relay 1 NO     -> Pump +        (or NC, see PUMP_ON_NC)
 *   Pump -         -> Pump supply -
 * Never put the relay contacts across the pump's own + and - wires.
 *
 * Serial Monitor (115200 baud, line ending "Newline"):
 *   on        pump on (stops by itself after MAX_RUN_MS)
 *   off       pump off
 *   t <sec>   run for <sec> seconds, e.g. "t 5"
 *   a         auto cycle: on ON_MS, off OFF_MS, repeat ("off" stops it)
 *   ?         help and state
 */

/******************** RELAY 1 PIN ********************/
#if CONFIG_IDF_TARGET_ESP32S3
#define PUMP_RELAY 15
#else
#define PUMP_RELAY 26
#endif

// 1 = relay energises on HIGH, 0 = on LOW
#define RELAY_ACTIVE_HIGH 1

// 0 = pump on the NO contact: relay energised -> pump runs (recommended,
//     the pump stays off while the board boots, resets or loses power)
// 1 = pump on the NC contact: relay energised -> pump stops, so the pump
//     RUNS whenever the relay is idle, including at boot and on power loss
#define PUMP_ON_NC 0

/******************** TIMING ********************/
#define MAX_RUN_MS  60000   // safety limit for "on" / "t"
#define ON_MS        3000   // auto cycle
#define OFF_MS       5000

/******************** STATE ********************/
bool pumpOn = false;
bool autoMode = false;
unsigned long phaseStart = 0;
unsigned long runLimit = 0;   // ms the current run may last
String line;

void setPump(bool on) {
  pumpOn = on;
  bool energise = PUMP_ON_NC ? !on : on;
  bool level = RELAY_ACTIVE_HIGH ? energise : !energise;
  digitalWrite(PUMP_RELAY, level ? HIGH : LOW);
  phaseStart = millis();
  Serial.printf("[%7lu ms] Pump %s (relay %s)\n", millis(),
                on ? "ON" : "off", energise ? "energised" : "idle");
}

void printHelp() {
  Serial.printf("Relay 1 = GPIO%d, pump on %s contact\n",
                PUMP_RELAY, PUMP_ON_NC ? "NC" : "NO");
  Serial.println("Commands: on | off | t <sec> | a (auto cycle) | ?");
  Serial.printf("State: pump %s%s\n", pumpOn ? "ON" : "off",
                autoMode ? " (auto cycle)" : "");
}

void handleLine(String cmd) {
  cmd.trim();
  cmd.toLowerCase();
  if (cmd.length() == 0) return;

  if (cmd == "on") {
    autoMode = false;
    runLimit = MAX_RUN_MS;
    setPump(true);
  } else if (cmd == "off") {
    autoMode = false;
    setPump(false);
  } else if (cmd.startsWith("t")) {
    long sec = cmd.substring(1).toInt();
    if (sec <= 0 || sec * 1000L > MAX_RUN_MS) {
      Serial.printf("Use t 1..%d\n", MAX_RUN_MS / 1000);
      return;
    }
    autoMode = false;
    runLimit = sec * 1000UL;
    Serial.printf("Running for %ld s\n", sec);
    setPump(true);
  } else if (cmd == "a") {
    autoMode = true;
    Serial.printf("Auto cycle: %d ms on, %d ms off\n", ON_MS, OFF_MS);
    setPump(true);
  } else if (cmd == "?") {
    printHelp();
  } else {
    Serial.printf("Unknown command \"%s\" - type ? for help\n", cmd.c_str());
  }
}

void setup() {
  // Drive the "pump off" level before enabling the output so nothing
  // runs during boot.
  bool offEnergise = PUMP_ON_NC ? true : false;
  bool offLevel = RELAY_ACTIVE_HIGH ? offEnergise : !offEnergise;
  digitalWrite(PUMP_RELAY, offLevel ? HIGH : LOW);
  pinMode(PUMP_RELAY, OUTPUT);

  Serial.begin(115200);
  delay(500);
  Serial.println("\n===== SINGLE PUMP TEST (relay 1) =====");
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

  unsigned long elapsed = millis() - phaseStart;
  if (autoMode) {
    if (pumpOn && elapsed >= ON_MS) setPump(false);
    else if (!pumpOn && elapsed >= OFF_MS) setPump(true);
  } else if (pumpOn && elapsed >= runLimit) {
    Serial.println("Run time reached");
    setPump(false);
  }
}
