// chat -- see chat.h. Written with an AI assistant.
#include "chat.h"
#include "chatcore.h"
#include "config.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <Preferences.h>
#include <atomic>
#include "cJSON.h"

namespace chat {

static const int CLAUDE = 1, OPENAI = 2;
static const size_t MAX_RESPONSE = 48 * 1024;     // the most of a reply's JSON we will hold (no PSRAM in this build)
static const size_t HISTORY_BYTES = 6000;
static const uint32_t HTTP_TIMEOUT_MS = 70000;    // per read; a model may think for a while before the first byte

static Preferences nvs;
static String keyClaude, keyOpenai, modelClaude, modelOpenai, systemPrompt, defaultProvider;
static int maxTokens = 600, historyTurns = 12;

static const char *DEFAULT_SYSTEM =
    "You are chatting with someone at an Apple Lisa computer from 1983 with a small black-and-white text screen. "
    "Reply in plain ASCII text only: no markdown, no tables, no emoji. Keep replies short and conversational unless "
    "asked for detail.";

static chatcore::History hist[3];                 // [1] Claude, [2] OpenAI
static std::atomic<int> st{IDLE};                 // IDLE, RUNNING (task works), FINISHED (task done, poll() not yet), REPLY
static const int FINISHED = 100;
static String lastNote;                           // the last request's outcome, for the web page

struct Job {                                      // handed to the task; the task writes ok and text, then st = FINISHED
    int provider = 0;
    bool remember = false;
    std::string url, body;
    String key, model;
    bool ok = false;
    std::string text;
};
static Job job;
static std::string replyText;

void begin() {
    nvs.begin("chat", false);
    keyClaude = nvs.getString("ckey", "");
    keyOpenai = nvs.getString("okey", "");
    modelClaude = nvs.getString("cmodel", "claude-sonnet-5-5");
    modelOpenai = nvs.getString("omodel", "gpt-4o-mini");
    defaultProvider = nvs.getString("prov", "claude");
    systemPrompt = nvs.getString("sys", DEFAULT_SYSTEM);
    maxTokens = nvs.getInt("maxtok", 600);
    historyTurns = nvs.getInt("turns", 12);
}

State state() {
    int s = st;
    return s == RUNNING || s == FINISHED ? RUNNING : (State)s;
}

// ---- The call ------------------------------------------------------------------------------------
static std::string shorten(std::string s, size_t n) { if (s.size() > n) s = s.substr(0, n - 3) + "..."; return s; }

// The text of a reply, or "" with err filled. Claude: content[] items of type text. OpenAI: choices[0].message.content.
static bool extractReply(int provider, const String &json, std::string &text, std::string &err) {
    cJSON *root = cJSON_Parse(json.c_str());
    if (!root) { err = "the reply was not JSON"; return false; }
    bool ok = false;
    if (provider == CLAUDE) {
        cJSON *c = cJSON_GetObjectItemCaseSensitive(root, "content");
        cJSON *it;
        cJSON_ArrayForEach(it, c) {
            cJSON *t = cJSON_GetObjectItemCaseSensitive(it, "text");
            if (cJSON_IsString(t)) { text += t->valuestring; ok = true; }
        }
    } else {
        cJSON *ch = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(root, "choices"), 0);
        cJSON *msg = cJSON_GetObjectItemCaseSensitive(ch, "message");
        cJSON *c = cJSON_GetObjectItemCaseSensitive(msg, "content");
        if (!cJSON_IsString(c)) c = cJSON_GetObjectItemCaseSensitive(msg, "refusal");
        if (cJSON_IsString(c)) { text = c->valuestring; ok = true; }
    }
    cJSON_Delete(root);
    if (!ok) err = "the reply had no text";
    return ok;
}

static std::string apiErrorMessage(const String &json) {      // {"error":{"message":"..."}} in both APIs
    std::string m;
    cJSON *root = cJSON_Parse(json.c_str());
    if (root) {
        cJSON *e = cJSON_GetObjectItemCaseSensitive(root, "error");
        cJSON *msg = cJSON_GetObjectItemCaseSensitive(e, "message");
        if (cJSON_IsString(msg)) m = msg->valuestring;
        cJSON_Delete(root);
    }
    return m;
}

// A sink for HTTPClient::writeToStream (which also decodes chunked bodies) that refuses bytes past a cap, so a reply with
// no Content-Length cannot fill the heap
class CapSink : public Stream {
public:
    String body;
    bool over = false;
    size_t write(uint8_t c) override { return write(&c, 1); }
    size_t write(const uint8_t *b, size_t n) override {
        if (body.length() + n > MAX_RESPONSE) { over = true; return 0; }
        body.concat((const char *)b, n);
        return n;
    }
    int available() override { return 0; }
    int read() override { return -1; }
    int peek() override { return -1; }
};

static void chatTask(void *) {
    Job &j = job;
    WiFiClientSecure client;
    client.setInsecure();                                       // no certificate store here, as in fujinet.cpp
    HTTPClient http;
    http.setTimeout(HTTP_TIMEOUT_MS);
    http.setReuse(false);
    String err;
    if (!http.begin(client, j.url.c_str())) err = "could not start the request";
    else {
        http.addHeader("Content-Type", "application/json");
        if (j.provider == CLAUDE) {
            http.addHeader("x-api-key", j.key);
            http.addHeader("anthropic-version", "2023-06-01");
        } else {
            http.addHeader("Authorization", "Bearer " + j.key);
        }
        int code = http.POST((uint8_t *)j.body.data(), j.body.size());
        if (code <= 0) err = String("no connection (") + http.errorToString(code) + ")";
        else if (http.getSize() > (int)MAX_RESPONSE) err = "the reply was too large";
        else {
            CapSink sink;
            http.writeToStream(&sink);
            String resp = sink.body;
            if (sink.over) err = "the reply was too large";
            else if (code >= 200 && code < 300) {
                std::string text, why;
                if (extractReply(j.provider, resp, text, why)) { j.ok = true; j.text = chatcore::asciify(text); }
                else err = why.c_str();
                if (j.ok && j.text.empty()) { j.ok = false; err = "the reply was empty"; }
            } else {
                std::string m = apiErrorMessage(resp);
                err = String("HTTP ") + code + (m.empty() ? "" : String(": ") + chatcore::asciify(m).c_str());
                if (code == 401 || code == 403) err = String("HTTP ") + code + ", check the API key";
            }
        }
        http.end();
    }
    if (!j.ok) j.text = std::string("[error: ") + shorten(err.c_str(), 160) + "]";
    st = FINISHED;
    vTaskDelete(nullptr);
}

bool start(int kind, const std::string &prompt, bool remember) {
    if (st != IDLE) return false;
    int provider = kind == CLAUDE || kind == OPENAI ? kind : (defaultProvider == "openai" ? OPENAI : CLAUDE);
    const String &key = provider == CLAUDE ? keyClaude : keyOpenai;
    const char *name = provider == CLAUDE ? "Claude" : "OpenAI";
    if (!key.length()) {
        replyText = std::string("[error: no ") + name + " API key set. Open http://" MDNS_NAME ".local/ and enter it under Chat.]";
        st = REPLY;
        return true;
    }
    if (WiFi.status() != WL_CONNECTED) { replyText = "[error: the WiFi board is not connected to a network]"; st = REPLY; return true; }

    chatcore::History h = remember ? hist[provider] : chatcore::History();
    h.add(true, prompt);
    h.trim(historyTurns, HISTORY_BYTES);
    const String &model = provider == CLAUDE ? modelClaude : modelOpenai;
    job = Job();
    job.provider = provider;
    job.remember = remember;
    job.key = key;
    job.model = model;
    job.url = provider == CLAUDE ? "https://api.anthropic.com/v1/messages" : "https://api.openai.com/v1/chat/completions";
    job.body = provider == CLAUDE ? chatcore::buildClaudeBody(model.c_str(), systemPrompt.c_str(), h, maxTokens)
                                  : chatcore::buildOpenAIBody(model.c_str(), systemPrompt.c_str(), h, maxTokens);
    if (remember) hist[provider] = h;                           // the question stays; poll() adds the answer or drops it
    st = RUNNING;
    if (xTaskCreate(chatTask, "chat", 24 * 1024, nullptr, 1, nullptr) != pdPASS) {
        if (remember) hist[provider].popLast();
        replyText = "[error: out of memory for the chat task]";
        st = REPLY;
    }
    return true;
}

void poll() {
    if (st != FINISHED) return;
    if (job.remember) {
        if (job.ok) hist[job.provider].add(false, job.text);
        else hist[job.provider].popLast();
    }
    lastNote = job.ok ? String("ok, ") + (unsigned)job.text.size() + " characters" : String(job.text.c_str());
    replyText = job.text;
    st = REPLY;
}

std::string takeReply() {
    if (st != REPLY) return "";
    std::string r = replyText;
    replyText.clear();
    st = IDLE;
    return r;
}

void resetHistory() { hist[CLAUDE].clear(); hist[OPENAI].clear(); }

// ---- Settings ------------------------------------------------------------------------------------
static String jesc(const String &s) {
    String o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if ((uint8_t)c < 0x20) o += ' ';
        else o += c;
    }
    return o;
}

String infoJson() {
    String o = "{\"provider\":\"" + defaultProvider + "\",\"claudeKey\":" + (keyClaude.length() ? "true" : "false") +
               ",\"openaiKey\":" + (keyOpenai.length() ? "true" : "false") + ",\"claudeModel\":\"" + jesc(modelClaude) +
               "\",\"openaiModel\":\"" + jesc(modelOpenai) + "\",\"maxTokens\":" + maxTokens + ",\"turns\":" + historyTurns +
               ",\"system\":\"" + jesc(systemPrompt) + "\",\"state\":\"" +
               (state() == IDLE ? "idle" : state() == RUNNING ? "running" : "reply") + "\",\"claudeTurns\":" +
               (unsigned)hist[CLAUDE].size() + ",\"openaiTurns\":" + (unsigned)hist[OPENAI].size() + ",\"last\":\"" +
               jesc(lastNote) + "\"}";
    return o;
}

bool setConfig(const String &name, const String &raw, String &err) {
    String v = raw;
    v.trim();
    if (name == "provider") {
        if (v != "claude" && v != "openai") { err = "provider is claude or openai"; return false; }
        defaultProvider = v; nvs.putString("prov", v);
    } else if (name == "claudeKey" || name == "openaiKey") {
        if (v.length() > 200) { err = "that key is too long"; return false; }
        if (name == "claudeKey") { keyClaude = v; nvs.putString("ckey", v); hist[CLAUDE].clear(); }
        else { keyOpenai = v; nvs.putString("okey", v); hist[OPENAI].clear(); }
    } else if (name == "claudeModel" || name == "openaiModel") {
        if (!v.length() || v.length() > 80) { err = "give a model name"; return false; }
        if (name == "claudeModel") { modelClaude = v; nvs.putString("cmodel", v); hist[CLAUDE].clear(); }
        else { modelOpenai = v; nvs.putString("omodel", v); hist[OPENAI].clear(); }
    } else if (name == "maxTokens") {
        long n = v.toInt();
        if (n < 16 || n > 4000) { err = "max tokens is 16 to 4000"; return false; }
        maxTokens = n; nvs.putInt("maxtok", maxTokens);
    } else if (name == "turns") {
        long n = v.toInt();
        if (n < 2 || n > 40) { err = "history is 2 to 40 turns"; return false; }
        historyTurns = n; nvs.putInt("turns", historyTurns);
    } else if (name == "system") {
        if (v.length() > 600) { err = "the system prompt is limited to 600 characters"; return false; }
        systemPrompt = v; nvs.putString("sys", v);
    } else { err = "unknown setting"; return false; }
    return true;
}

}  // namespace chat
