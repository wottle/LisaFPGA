// ota -- see ota.h. Written with an AI assistant.
#include "ota.h"
#include "config.h"
#include <Update.h>
#include <Preferences.h>
#include <esp_ota_ops.h>

// The tag every image of this firmware carries, followed by its version. An upload must contain it.
#define TAG_PREFIX "LISANET-WIFI-FW/"
extern const char FW_TAG[] __attribute__((used)) = TAG_PREFIX LISANET_WIFI_VERSION;

// Keep a new image "pending verify" past boot (the core would otherwise mark it good at once): see poll()
extern "C" bool verifyRollbackLater() { return true; }

namespace ota {

static Preferences nvs;
static String err, newVer;
static bool active = false;
static uint32_t restartAt = 0;

// Streaming search for TAG_PREFIX across upload chunks (KMP), then the version string after it
static const char *const NEEDLE = TAG_PREFIX;
static const int NLEN = sizeof(TAG_PREFIX) - 1;
static int fail[NLEN];
static int matched;
static bool found, readingVer;

static bool pendingVerify() {
    esp_ota_img_states_t st;
    const esp_partition_t *run = esp_ota_get_running_partition();
    return run && esp_ota_get_state_partition(run, &st) == ESP_OK && st == ESP_OTA_IMG_PENDING_VERIFY;
}

void begin() {
    nvs.begin(NVS_NAMESPACE, false);
    const esp_partition_t *run = esp_ota_get_running_partition();
    Serial.printf("[ota] %s, running from %s%s\r\n", FW_TAG, run ? run->label : "?",   // also keeps FW_TAG linked in
                  pendingVerify() ? ", new image: kept if it runs for 20 s" : "");
    fail[0] = 0;
    for (int i = 1, k = 0; i < NLEN; i++) {
        while (k && NEEDLE[i] != NEEDLE[k]) k = fail[k - 1];
        if (NEEDLE[i] == NEEDLE[k]) k++;
        fail[i] = k;
    }
}

void poll() {
    static bool checked = false;
    if (!checked && millis() > KEEP_AFTER_MS) {
        checked = true;
        if (pendingVerify()) {
            esp_ota_mark_app_valid_cancel_rollback();
            Serial.println("[ota] new image has run for 20 s: kept");
        }
    }
#ifdef LISANET_TEST_CRASH
    // Test build only (-DLISANET_TEST_CRASH): crash before the image is kept, to prove the bootloader rolls back
    if (millis() > 5000) { Serial.println("[ota] LISANET_TEST_CRASH: crashing on purpose"); Serial.flush(); ::abort(); }
#endif
    if (restartAt && (int32_t)(millis() - restartAt) >= 0) {
        Serial.println("[ota] restarting");
        Serial.flush();
        ESP.restart();
    }
}

String infoJson() {
    const esp_partition_t *run = esp_ota_get_running_partition();
    String prev = nvs.getString("prevver", "");
    bool can = Update.canRollBack();
    String j = "{\"version\":\"" LISANET_WIFI_VERSION "\",\"notes\":\"" LISANET_WIFI_NOTES "\",\"slot\":\"";
    j += run ? run->label : "?";
    j += "\",\"pending\":";
    j += pendingVerify() ? "true" : "false";
    j += ",\"canRollBack\":";
    j += can ? "true" : "false";
    j += ",\"prev\":\"" + (can ? prev : String("")) + "\"}";
    return j;
}

bool start(size_t size) {
    err = ""; newVer = ""; matched = 0; found = false; readingVer = false; active = false;
    if (pendingVerify()) { err = "This firmware is still on trial: wait 20 s after a restart, then try again"; return false; }
    if (size == 0) { err = "Empty upload"; return false; }
    if (!Update.begin(size, U_FLASH)) {
        err = String("Can't start the update: ") + Update.errorString();
        if (Update.getError() == UPDATE_ERROR_SIZE) err = "Too big for a firmware slot (was that the .merged.bin?)";
        return false;
    }
    active = true;
    Serial.printf("[ota] receiving %u bytes\r\n", (unsigned)size);
    return true;
}

void write(const uint8_t *data, size_t n) {
    if (!active) return;
    for (size_t i = 0; i < n && !(found && !readingVer); i++) {
        char c = data[i];
        if (readingVer) {
            if (c >= 0x21 && c <= 0x7E && newVer.length() < 15) { newVer += c; continue; }
            readingVer = false;
            // The search string itself is in the image too, followed by a NUL: only a tag with a version counts
            if (c != 0 || !newVer.length()) { found = false; newVer = ""; }
            matched = 0;
            continue;
        }
        while (matched && c != NEEDLE[matched]) matched = fail[matched - 1];
        if (c == NEEDLE[matched]) matched++;
        if (matched == NLEN) { found = true; readingVer = true; }
    }
    if (Update.write((uint8_t *)data, n) != n) {
        err = String("Write failed: ") + Update.errorString();
        Update.abort();
        active = false;
    }
}

bool finish() {
    if (!active) { if (!err.length()) err = "No update in progress"; return false; }
    active = false;
    if (!found) {
        Update.abort();                                    // the slot is never made bootable
        err = "That is not LisaNet WiFi board firmware (use lisanet_wifi.ino.bin)";
        return false;
    }
    if (!Update.end(false)) {                              // checks the image and sets it as the boot slot
        err = String("The image failed its check: ") + Update.errorString();
        return false;
    }
    nvs.putString("prevver", LISANET_WIFI_VERSION);
    Serial.printf("[ota] installed %s; restarting into it\r\n", newVer.c_str());
    return true;
}

void abort() {
    if (active) Update.abort();
    active = false;
    if (!err.length()) err = "Upload interrupted";
}

const String &error() { return err; }
const String &newVersion() { return newVer; }

bool rollBack() {
    if (!Update.canRollBack()) { err = "No previous firmware to go back to"; return false; }
    if (!Update.rollBack()) { err = "Roll back failed"; return false; }
    nvs.putString("prevver", LISANET_WIFI_VERSION);
    return true;
}

void restartSoon() { restartAt = millis() + 1000; if (!restartAt) restartAt = 1; }

}  // namespace ota
