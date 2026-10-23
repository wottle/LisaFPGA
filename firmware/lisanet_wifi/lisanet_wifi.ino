// LisaNet WiFi board firmware for a Seeed XIAO ESP32S3 on the LisaFPGA board's J21 header. Written with an AI assistant.
// See config.h for the wiring. Build: arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3 firmware/lisanet_wifi
#include <WiFi.h>
#include "config.h"
#include "sdlink.h"
#include "atmodem.h"
#include "web.h"
#include "wifisetup.h"
#include "ota.h"
#include "fujinet.h"
#include "chat.h"

static HardwareSerial LinkPort(1);   // to ESFloppy's SD server
static HardwareSerial LisaPort(2);   // the Lisa's Serial A (the modem), or Serial B (FujiNet): the FPGA routes one

void setup() {
    Serial.begin(115200);
    Serial.setTxTimeoutMs(0);         // never block if nothing is reading the USB console
    delay(200);
    Serial.println("\r\n[lisanet] LisaNet WiFi board " LISANET_WIFI_VERSION);
    ota::begin();

    sdlink::begin(LinkPort, LINK_RX_PIN, LINK_TX_PIN, LINK_BAUD);
    atmodem::begin(LisaPort);
    chat::begin();
    fujinet::begin(LisaPort);         // takes the port over from the modem while the FPGA has Serial B on it
    wifisetup::begin();               // starts WiFi (the web server needs it up first), joining the saved network or
                                      // bringing up the setup network
    web::begin();
}

void loop() {
    atmodem::poll();
    fujinet::poll();
    chat::poll();
    web::poll();
    wifisetup::poll();
    ota::poll();
    delay(1);
}
