// chatcore -- the parts of the Lisa chat endpoint (chat.cpp) that need no Arduino: turning a model's reply into text a
// Lisa can show, the conversation history, the two APIs' request bodies, and the chat:// URL. Host tests are in test/.
// Written with an AI assistant.
#pragma once
#include <string>
#include <vector>

namespace chatcore {

// UTF-8 to plain ASCII for the Lisa: curly quotes, dashes, ellipsis, bullets and Latin-1 accents become their plain
// forms, anything else non-ASCII (emoji, other scripts) is dropped; markdown markers (** __ ` leading #, leading "* ")
// are removed; every line ending becomes \n; runs of blank lines shrink to one; the result is trimmed.
std::string asciify(const std::string &utf8);

std::string jsonEscape(const std::string &s);   // the inside of a JSON string, quotes not included

struct Turn { bool user; std::string text; };

class History {
public:
    void add(bool user, const std::string &text) { t.push_back({user, text}); }
    void popLast() { if (!t.empty()) t.pop_back(); }
    void clear() { t.clear(); }
    size_t size() const { return t.size(); }
    const std::vector<Turn> &turns() const { return t; }
    // Drop the oldest turns until there are at most maxTurns turns and maxBytes bytes of text, then drop any leading
    // assistant turn (both APIs want the conversation to start with the user). The newest turn is always kept.
    void trim(size_t maxTurns, size_t maxBytes);
private:
    std::vector<Turn> t;
};

// The JSON request bodies. system may be empty.
std::string buildClaudeBody(const std::string &model, const std::string &system, const History &h, int maxTokens);
std::string buildOpenAIBody(const std::string &model, const std::string &system, const History &h, int maxTokens);

// "chat://claude", "chat://openai", "chat://" (the default provider), "chat://reset"; case-insensitive, with or without
// a leading "N1:". False for anything else.
struct Target { enum Kind { ANY, CLAUDE, OPENAI, RESET } kind = ANY; };
bool parseTarget(const std::string &url, Target &out);

}  // namespace chatcore
