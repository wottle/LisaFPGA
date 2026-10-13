// wifisetup -- see wifisetup.h. Written with an AI assistant.
#include "wifisetup.h"
#include "config.h"
#include <WiFi.h>
#include <DNSServer.h>
#include <Preferences.h>

namespace wifisetup {

static Preferences nvs;
static DNSServer dns;
static bool ap = false;
static uint32_t bootMs = 0;          // when we started trying the saved network
static uint32_t lastRetryMs = 0;     // last look for the saved network while in setup
static uint32_t joinedAtMs = 0;      // when a join completed while the setup network was up (0 = not pending)
static uint32_t buttonDownMs = 0;
static bool wasUp = false;           // connected at the previous poll()

enum JoinState { IDLE, JOINING, JOINED, FAILED };
static JoinState joinState = IDLE;
static String joinSsid, joinPass;
static uint32_t joinStartMs = 0;

static void say(const char *s) { Serial.printf("[setup] %s\r\n", s); }

void startAP(const char *why) {
    if (ap) return;
    // Stop hunting for an absent network: that hops channels and drops the phone (poll() scans for it every few
    // minutes instead). If we are connected (AT+WSETUP), stay connected: the setup network shares its channel.
    if (WiFi.status() != WL_CONNECTED) WiFi.disconnect();
    WiFi.mode(WIFI_AP_STA);
    if (!WiFi.softAP(SETUP_AP_SSID, SETUP_AP_PASS)) say("softAP() FAILED: the setup network is not up");
    dns.start(53, "*", WiFi.softAPIP());             // every name resolves to us: phones then show the setup page
    ap = true;
    lastRetryMs = millis();
    Serial.printf("[setup] %s: setup network \"%s\" is up at http://%s/setup\r\n", why, SETUP_AP_SSID,
                  WiFi.softAPIP().toString().c_str());
}

static void stopAP() {
    if (!ap) return;
    dns.stop();
    WiFi.softAPdisconnect(true);
    WiFi.mode(WIFI_STA);
    ap = false;
    joinedAtMs = 0;
    say("setup network is off");
}

bool apActive() { return ap; }

void begin() {
    nvs.begin(NVS_NAMESPACE, false);
    pinMode(SETUP_RESET_PIN, INPUT_PULLUP);
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    String ssid = nvs.getString("ssid", "");
    bootMs = millis();
    if (!ssid.length()) { startAP("no network saved"); return; }
    String pass = nvs.getString("pass", "");
    WiFi.begin(ssid.c_str(), pass.length() ? pass.c_str() : nullptr);
    Serial.printf("[setup] joining %s\r\n", ssid.c_str());
}

void factoryReset(const char *why) {
    nvs.remove("ssid");
    nvs.remove("pass");
    nvs.remove("webpass");
    WiFi.disconnect();
    joinState = IDLE;
    stopAP();
    startAP(why);
}

void requestJoin(const String &ssid, const String &pass) {
    joinSsid = ssid;
    joinPass = pass;
    joinState = JOINING;
    joinStartMs = millis();
    // The setup network stays up meanwhile; the radio may hop to the new network's channel, briefly dropping the phone
    WiFi.disconnect();
    WiFi.begin(ssid.c_str(), pass.length() ? pass.c_str() : nullptr);
    Serial.printf("[setup] joining %s (from the setup page)\r\n", ssid.c_str());
}

void joined() {
    joinState = JOINED;
    if (ap) joinedAtMs = millis();
}

String statusJson() {
    const char *st = joinState == JOINING ? "joining" : joinState == JOINED ? "joined" : joinState == FAILED ? "failed" : "idle";
    bool up = WiFi.status() == WL_CONNECTED;
    String o = String("{\"state\":\"") + st + "\",\"connected\":" + (up ? "true" : "false") + ",\"ssid\":\"";
    for (char c : (up ? WiFi.SSID() : joinSsid)) { if (c == '"' || c == '\\') o += '\\'; if ((uint8_t)c >= 0x20) o += c; }
    o += "\",\"ip\":\"" + (up ? WiFi.localIP().toString() : String("")) + "\",\"mdns\":\"" MDNS_NAME ".local\"}";
    return o;
}

void poll() {
    uint32_t now = millis();

    // B button held: start over
    if (digitalRead(SETUP_RESET_PIN) == LOW) {
        if (!buttonDownMs) buttonDownMs = now ? now : 1;
        else if (now - buttonDownMs >= SETUP_RESET_HOLD_MS) {
            buttonDownMs = 0;
            factoryReset("B button held");
            while (digitalRead(SETUP_RESET_PIN) == LOW) delay(10);   // don't repeat while it's still held
        }
    } else {
        buttonDownMs = 0;
    }

    bool up = WiFi.status() == WL_CONNECTED;

    // A join requested from the setup page
    if (joinState == JOINING) {
        if (up && WiFi.SSID() == joinSsid) {
            nvs.putString("ssid", joinSsid);
            nvs.putString("pass", joinPass);
            Serial.printf("[setup] joined %s, address %s\r\n", joinSsid.c_str(), WiFi.localIP().toString().c_str());
            joined();
        } else if (now - joinStartMs > 20000) {
            joinState = FAILED;
            say("join failed (wrong password, or out of range?)");
        }
    }

    // Saved network not joined in time: offer setup
    if (!ap && !up && joinState != JOINING && now - bootMs > SETUP_JOIN_GRACE_MS) startAP("saved network not found");

    // In setup because the saved network vanished: look for it now and then, and rejoin if it's back
    if (ap && !up && joinState != JOINING && now - lastRetryMs > SETUP_RETRY_MS) {
        lastRetryMs = now;
        String ssid = nvs.getString("ssid", "");
        if (ssid.length()) {
            int n = WiFi.scanNetworks();                  // a few seconds; the phone may briefly drop off the AP
            for (int i = 0; i < n; i++) {
                if (WiFi.SSID(i) == ssid) {
                    String pass = nvs.getString("pass", "");
                    WiFi.begin(ssid.c_str(), pass.length() ? pass.c_str() : nullptr);
                    Serial.printf("[setup] %s is back: rejoining\r\n", ssid.c_str());
                    break;
                }
            }
            WiFi.scanDelete();
        }
    }
    if (ap && up && !wasUp && !joinedAtMs) joinedAtMs = now;   // (re)connected while the setup network was up
    wasUp = up;

    // Joined while the setup network was up: let the phone read the result, then turn the setup network off
    if (ap && up && joinedAtMs && now - joinedAtMs > SETUP_AP_LINGER_MS) stopAP();
}

}  // namespace wifisetup
