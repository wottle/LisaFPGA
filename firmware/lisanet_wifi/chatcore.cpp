// chatcore -- see chatcore.h. Written with an AI assistant.
#include "chatcore.h"
#include <cctype>
#include <cstdint>
#include <cstdio>

namespace chatcore {

// One code point to ASCII: appends 0 or more characters
static void mapCodePoint(uint32_t cp, std::string &out) {
    if (cp < 0x80) { out += (char)cp; return; }
    switch (cp) {
        case 0x2018: case 0x2019: case 0x201A: case 0x2032: out += '\''; return;
        case 0x201C: case 0x201D: case 0x201E: case 0x2033: out += '"'; return;
        case 0x2010: case 0x2011: case 0x2012: case 0x2013: case 0x2014: case 0x2015: case 0x2212: out += '-'; return;
        case 0x2026: out += "..."; return;
        case 0x2022: case 0x25CF: case 0x25E6: case 0x2023: case 0x00B7: out += '-'; return;
        case 0x00A0: case 0x2002: case 0x2003: case 0x2009: case 0x202F: out += ' '; return;
        case 0x00D7: out += 'x'; return;
        case 0x2192: out += "->"; return;
        case 0x2190: out += "<-"; return;
        case 0x00A9: out += "(c)"; return;
        case 0x00B0: out += " deg"; return;
        case 0x00C6: out += "AE"; return;  case 0x00E6: out += "ae"; return;
        case 0x00DF: out += "ss"; return;
        default: break;
    }
    // Latin-1 letters with accents: the base letter
    static const char *LATIN1 = "AAAAAA?CEEEEIIII?NOOOOO?OUUUUY??aaaaaa?ceeeeiiii?nooooo?ouuuuy?y";   // U+00C0..U+00FF
    if (cp >= 0xC0 && cp <= 0xFF) {
        char c = LATIN1[cp - 0xC0];
        if (c != '?') out += c;
    }
    // everything else is dropped
}

static std::string decodeToAscii(const std::string &s) {
    std::string out;
    size_t i = 0, n = s.size();
    while (i < n) {
        uint8_t c = (uint8_t)s[i];
        if (c < 0x80) { mapCodePoint(c, out); i++; continue; }
        int len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 0;
        if (len == 0 || i + len > n) { i++; continue; }          // a stray or truncated byte
        uint32_t cp = len == 2 ? (c & 0x1F) : len == 3 ? (c & 0x0F) : (c & 0x07);
        bool ok = true;
        for (int k = 1; k < len; k++) {
            uint8_t cc = (uint8_t)s[i + k];
            if ((cc & 0xC0) != 0x80) { ok = false; break; }
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (!ok) { i++; continue; }
        mapCodePoint(cp, out);
        i += len;
    }
    return out;
}

static bool replaceAllIn(std::string &s, const char *from, const char *to) {
    bool any = false;
    size_t fl = std::string(from).size(), tl = std::string(to).size();
    for (size_t p = 0; (p = s.find(from, p)) != std::string::npos; p += tl) { s.replace(p, fl, to); any = true; }
    return any;
}

std::string asciify(const std::string &utf8) {
    std::string s = decodeToAscii(utf8);
    replaceAllIn(s, "\r\n", "\n");
    for (auto &c : s) if (c == '\r') c = '\n';
    for (auto &c : s) if (c == '\t') c = ' ';
    std::string t;
    for (char c : s) if (c == '\n' || (uint8_t)c >= 0x20) { if ((uint8_t)c != 0x7F) t += c; }
    s = t;
    replaceAllIn(s, "**", "");
    replaceAllIn(s, "__", "");
    replaceAllIn(s, "`", "");

    // line by line: leading # marks, "* " bullets, trailing blanks; then squeeze blank runs
    std::string out;
    int blanks = 0;
    size_t pos = 0;
    while (pos <= s.size()) {
        size_t e = s.find('\n', pos);
        if (e == std::string::npos) e = s.size();
        std::string line = s.substr(pos, e - pos);
        pos = e + 1;
        size_t a = 0;
        while (a < line.size() && line[a] == ' ') a++;
        size_t h = a;
        while (h < line.size() && line[h] == '#') h++;
        if (h > a && h < line.size() && line[h] == ' ') line = line.substr(h + 1);
        else if (a + 1 < line.size() && line[a] == '*' && line[a + 1] == ' ') line = line.substr(0, a) + "- " + line.substr(a + 2);
        while (!line.empty() && line.back() == ' ') line.pop_back();
        if (line.empty()) { blanks++; continue; }
        if (!out.empty()) out += blanks ? "\n\n" : "\n";
        blanks = 0;
        out += line;
    }
    // leading spaces of the first line
    size_t f = 0;
    while (f < out.size() && out[f] == ' ') f++;
    return out.substr(f);
}

std::string jsonEscape(const std::string &s) {
    std::string o;
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
                else o += (char)c;
        }
    }
    return o;
}

void History::trim(size_t maxTurns, size_t maxBytes) {
    auto bytes = [&]() { size_t n = 0; for (auto &x : t) n += x.text.size(); return n; };
    while (t.size() > 1 && (t.size() > maxTurns || bytes() > maxBytes)) t.erase(t.begin());
    while (t.size() > 1 && !t.front().user) t.erase(t.begin());
}

static std::string messagesJson(const History &h, bool withSystem, const std::string &system) {
    std::string m = "[";
    bool first = true;
    if (withSystem && !system.empty()) {
        m += "{\"role\":\"system\",\"content\":\"" + jsonEscape(system) + "\"}";
        first = false;
    }
    for (auto &x : h.turns()) {
        if (!first) m += ",";
        first = false;
        m += std::string("{\"role\":\"") + (x.user ? "user" : "assistant") + "\",\"content\":\"" + jsonEscape(x.text) + "\"}";
    }
    return m + "]";
}

std::string buildClaudeBody(const std::string &model, const std::string &system, const History &h, int maxTokens) {
    std::string b = "{\"model\":\"" + jsonEscape(model) + "\",\"max_tokens\":" + std::to_string(maxTokens);
    if (!system.empty()) b += ",\"system\":\"" + jsonEscape(system) + "\"";
    return b + ",\"messages\":" + messagesJson(h, false, "") + "}";
}

std::string buildOpenAIBody(const std::string &model, const std::string &system, const History &h, int maxTokens) {
    return "{\"model\":\"" + jsonEscape(model) + "\",\"max_completion_tokens\":" + std::to_string(maxTokens) +
           ",\"messages\":" + messagesJson(h, true, system) + "}";
}

bool parseTarget(const std::string &url, Target &out) {
    std::string s;
    for (char c : url) s += (char)tolower((unsigned char)c);
    size_t colon = s.find(':');
    if (colon != std::string::npos && colon <= 3 && s.compare(0, 1, "n") == 0 && s.compare(colon + 1, 7, "chat://") == 0)
        s = s.substr(colon + 1);
    if (s.compare(0, 7, "chat://") != 0) return false;
    std::string rest = s.substr(7);
    while (!rest.empty() && rest.back() == '/') rest.pop_back();
    if (rest.empty()) out.kind = Target::ANY;
    else if (rest == "claude") out.kind = Target::CLAUDE;
    else if (rest == "openai") out.kind = Target::OPENAI;
    else if (rest == "reset") out.kind = Target::RESET;
    else return false;
    return true;
}

}  // namespace chatcore
