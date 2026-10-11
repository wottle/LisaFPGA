// ---------------------------------------------------------------------------------------------
// esp32_wifi_test -- bench test for the FPGA side of ESP32 WiFi mode (LisaNet). NOT the WiFi firmware.
// See docs/superpowers/specs/2026-10-10-esp32-wifi-mode-design.md.
//
// Runs on the ESFloppy ESP32-S3 in place of ESFloppy (back the flash up first; see README.md here).
// Written with an AI assistant -- do not offer it to the upstream ESFloppy project without saying so.
//
// The FPGA link, on ESFLOPPY_COMM_BUS[5:3]:
//   GPIO37 <- bus[3]  MODE: 1 = WIFI (the on-screen menu's ESP32 MODE)
//   GPIO38 <- bus[4]  the Lisa's Serial A transmit data (SCC channel A TXD), only while MODE = 1
//   GPIO39 -> bus[5]  data to the Lisa's Serial A receive (SCC RXD); the FPGA never drives this line
//
// What it does, reported on the USB console (115200, any terminal):
//   * prints every MODE change, so toggling ESP32 MODE in the menu proves bus[3]
//   * in WIFI mode: bytes from the Lisa are shown (text and hex) and, with echo on, sent straight back, so a
//     terminal on the Lisa sees its own typing return through the ESP32 -- proving bus[4] and bus[5]
//   * characters typed on the console are sent to the Lisa (WIFI mode only)
//   * console commands, typed as a line starting with '!':  !echo  (toggle echo)   !baud <n>   !status
// In FLOPPY mode the FPGA holds bus[4] low, which looks like a continuous break, so input is discarded.
// ---------------------------------------------------------------------------------------------
#include <Arduino.h>

static const int PIN_MODE = 37;
static const int PIN_RX   = 38;
static const int PIN_TX   = 39;

HardwareSerial Lisa(1);

static uint32_t baud = 9600;
static bool     echo_on = true;
static bool     wifi = false;
static uint32_t rx_count = 0, tx_count = 0;
static uint32_t last_status_ms = 0;
static String   cmd;
static bool     in_cmd = false;

static void start_uart() {
    Lisa.end();
    Lisa.begin(baud, SERIAL_8N1, PIN_RX, PIN_TX);
}

static void status() {
    Serial.printf("[status] MODE=%s  baud=%lu  echo=%s  from Lisa=%lu  to Lisa=%lu\r\n",
                  wifi ? "WIFI" : "FLOPPY", (unsigned long)baud, echo_on ? "on" : "off",
                  (unsigned long)rx_count, (unsigned long)tx_count);
}

static void send_to_lisa(const char *s) {
    size_t n = strlen(s);
    Lisa.write((const uint8_t *)s, n);
    tx_count += n;
}

static void run_command(String c) {
    c.trim();
    if (c == "echo") {
        echo_on = !echo_on;
    } else if (c.startsWith("baud ")) {
        uint32_t b = c.substring(5).toInt();
        if (b >= 300 && b <= 921600) { baud = b; start_uart(); }
        else Serial.println("[error] baud must be 300..921600");
    } else if (c != "status") {
        Serial.println("[commands] !echo  !baud <n>  !status");
        return;
    }
    status();
}

void setup() {
    Serial.begin(115200);
    pinMode(PIN_MODE, INPUT);           // driven by the FPGA at all times
    start_uart();
    delay(500);
    Serial.println("\r\n[esp32_wifi_test] LisaNet link test. Toggle ESP32 MODE in the LisaFPGA menu.");
    wifi = digitalRead(PIN_MODE);
    status();
}

void loop() {
    // ---- MODE line: report changes (debounced by requiring two equal reads 2 ms apart) ----
    bool m = digitalRead(PIN_MODE);
    if (m != wifi) {
        delay(2);
        if (digitalRead(PIN_MODE) == m) {
            wifi = m;
            Serial.printf("[mode] %s\r\n", wifi ? "WIFI  (Serial A is now connected to this ESP32)" : "FLOPPY");
            if (wifi) {
                while (Lisa.available()) Lisa.read();  // drop the break/garbage seen while bus[4] was held low
                send_to_lisa("\r\nLISANET LINK TEST: ESP32 is listening. Type and it echoes back.\r\n");
            }
        }
    }

    // ---- From the Lisa ----
    while (Lisa.available()) {
        int c = Lisa.read();
        if (!wifi) continue;                 // FLOPPY mode: bus[4] is held low, not real data
        rx_count++;
        if (c >= 0x20 && c < 0x7F) Serial.printf("[lisa] '%c' %02X\r\n", c, c);
        else                      Serial.printf("[lisa] %02X\r\n", c);
        if (echo_on) { Lisa.write((uint8_t)c); tx_count++; }
    }

    // ---- From the console: '!' starts a command line; anything else goes to the Lisa ----
    while (Serial.available()) {
        char c = Serial.read();
        if (in_cmd) {
            if (c == '\r' || c == '\n') { in_cmd = false; run_command(cmd); cmd = ""; }
            else cmd += c;
        } else if (c == '!') {
            in_cmd = true;
        } else if (wifi) {
            Lisa.write((uint8_t)c);
            tx_count++;
        } else {
            Serial.println("[note] FLOPPY mode: not sent. Select WIFI in the ESP32 MODE menu row.");
        }
    }

    if (millis() - last_status_ms > 10000) { last_status_ms = millis(); status(); }
}
