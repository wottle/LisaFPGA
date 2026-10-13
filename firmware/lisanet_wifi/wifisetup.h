// wifisetup -- getting the WiFi board onto a network without a terminal. Written with an AI assistant.
//
// With no saved network, or when the saved one can't be joined for SETUP_JOIN_GRACE_MS, the board brings up its own
// WPA2 network SETUP_AP_SSID (password SETUP_AP_PASS, fixed and documented) with a captive setup page: pick a network,
// give its password and the web page password, and the board joins it and turns the setup network off.
// While the setup network is up because the saved network vanished, it looks for that network every few minutes and
// rejoins by itself if it comes back. AT+WSETUP brings the setup network up on demand, keeping what is saved. Holding
// the XIAO's B button for SETUP_RESET_HOLD_MS forgets the network AND the web password and starts setup from scratch.
#pragma once
#include <Arduino.h>

#define SETUP_AP_SSID        "LisaNet-Setup"
#define SETUP_AP_PASS        "lisanet-setup"     // WPA2 needs 8+ characters; public, so only a speed bump
#define SETUP_JOIN_GRACE_MS  60000               // how long to try the saved network before offering setup
#define SETUP_RETRY_MS       180000              // while in setup, how often to look for the saved network
#define SETUP_AP_LINGER_MS   60000               // after joining, keep the setup network up this long for the phone
#define SETUP_RESET_PIN      0                   // the XIAO's B (BOOT) button, active low
#define SETUP_RESET_HOLD_MS  5000

namespace wifisetup {
void begin();
void poll();                                      // call from loop()
bool apActive();
void factoryReset(const char *why);               // forget network + web password, start the setup network
void startAP(const char *why);                    // bring up the setup network, keeping what is saved (AT+WSETUP)
// Join a network from the setup page. Runs in the background; status() reports progress. Saved only once joined.
void requestJoin(const String &ssid, const String &pass);
String statusJson();                              // {"state":"idle|joining|joined|failed","ssid":..,"ip":..}
void joined();                                    // a join made elsewhere (AT+WJOIN) succeeded
}
