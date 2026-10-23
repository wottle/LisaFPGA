// Host tests for chatcore (no Arduino needed):
//   g++ -std=c++17 -Wall -I.. test_chatcore.cpp ../chatcore.cpp -o /tmp/test_chatcore && /tmp/test_chatcore
#include "chatcore.h"
#include <cstdio>
#include <string>
using namespace chatcore;

static int failures = 0;
#define CHECK_EQ(got, want) do { std::string g_ = (got), w_ = (want); if (g_ != w_) { \
    printf("FAIL line %d:\n  got:  [%s]\n  want: [%s]\n", __LINE__, g_.c_str(), w_.c_str()); failures++; } } while (0)
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)

int main() {
    // ---- asciify ----
    CHECK_EQ(asciify("plain text"), "plain text");
    CHECK_EQ(asciify("it\xE2\x80\x99s \xE2\x80\x9Cquoted\xE2\x80\x9D"), "it's \"quoted\"");       // curly quotes
    CHECK_EQ(asciify("a\xE2\x80\x93" "b\xE2\x80\x94" "c"), "a-b-c");                               // en and em dash
    CHECK_EQ(asciify("wait\xE2\x80\xA6"), "wait...");
    CHECK_EQ(asciify("caf\xC3\xA9 na\xC3\xAFve"), "cafe naive");                                    // Latin-1 accents
    CHECK_EQ(asciify("smile \xF0\x9F\x98\x80 done"), "smile  done");                               // emoji dropped
    CHECK_EQ(asciify("\xE2\x80\xA2 item"), "- item");                                               // bullet
    CHECK_EQ(asciify("a\r\nb\rc"), "a\nb\nc");                                                      // line ends
    CHECK_EQ(asciify("**bold** and __under__ and `code`"), "bold and under and code");
    CHECK_EQ(asciify("# Title\n## Sub\ntext"), "Title\nSub\ntext");
    CHECK_EQ(asciify("* one\n* two"), "- one\n- two");
    CHECK_EQ(asciify("a\n\n\n\nb"), "a\n\nb");                                                       // blank runs
    CHECK_EQ(asciify("  \n hi \n"), "hi");                                                          // trimmed
    CHECK_EQ(asciify("bad \xC3"), "bad");                                                           // truncated UTF-8
    CHECK_EQ(asciify("tab\there\x01"), "tab here");                                                 // control chars

    // ---- jsonEscape ----
    CHECK_EQ(jsonEscape("a\"b\\c\nd\te"), "a\\\"b\\\\c\\nd\\te");
    CHECK_EQ(jsonEscape(std::string("x\x01y", 3)), "x\\u0001y");

    // ---- History ----
    History h;
    h.add(true, "q1"); h.add(false, "a1"); h.add(true, "q2");
    CHECK(h.size() == 3);
    h.popLast();
    CHECK(h.size() == 2);
    h.clear();
    CHECK(h.size() == 0);

    History t;                                   // trimming: keep the newest turns, always starting on a user turn
    for (int i = 1; i <= 4; i++) { t.add(true, "q" + std::to_string(i)); t.add(false, "a" + std::to_string(i)); }
    t.trim(6, 100000);                           // at most 6 turns
    CHECK(t.size() == 6);
    CHECK(t.turns().front().user);
    CHECK_EQ(t.turns().front().text, "q2");
    History b;                                   // byte cap
    b.add(true, std::string(100, 'x')); b.add(false, std::string(100, 'y')); b.add(true, std::string(100, 'z'));
    b.trim(100, 250);
    CHECK(b.size() == 1);                        // only the newest user turn fits, and it is a user turn
    CHECK_EQ(b.turns().front().text, std::string(100, 'z'));
    History o;                                   // a lone user turn bigger than the cap is kept: it is the question
    o.add(true, std::string(500, 'q'));
    o.trim(100, 50);
    CHECK(o.size() == 1);

    // ---- request bodies ----
    History r;
    r.add(true, "Hi"); r.add(false, "Hello"); r.add(true, "2+2?");
    CHECK_EQ(buildClaudeBody("claude-x", "Be brief.", r, 300),
        "{\"model\":\"claude-x\",\"max_tokens\":300,\"system\":\"Be brief.\",\"messages\":["
        "{\"role\":\"user\",\"content\":\"Hi\"},{\"role\":\"assistant\",\"content\":\"Hello\"},"
        "{\"role\":\"user\",\"content\":\"2+2?\"}]}");
    CHECK_EQ(buildOpenAIBody("gpt-x", "Be brief.", r, 300),
        "{\"model\":\"gpt-x\",\"max_completion_tokens\":300,\"messages\":["
        "{\"role\":\"system\",\"content\":\"Be brief.\"},{\"role\":\"user\",\"content\":\"Hi\"},"
        "{\"role\":\"assistant\",\"content\":\"Hello\"},{\"role\":\"user\",\"content\":\"2+2?\"}]}");
    CHECK(buildOpenAIBody("gpt-x", "", r, 50).find("\"system\"") == std::string::npos);   // no system prompt, no system message
    CHECK_EQ(buildClaudeBody("m", "say \"hi\"", History(), 10),
        "{\"model\":\"m\",\"max_tokens\":10,\"system\":\"say \\\"hi\\\"\",\"messages\":[]}");

    // ---- parseTarget: chat://claude, chat://openai, chat://, chat://reset ----
    Target tg;
    CHECK(parseTarget("chat://claude", tg) && tg.kind == Target::CLAUDE);
    CHECK(parseTarget("CHAT://OpenAI", tg) && tg.kind == Target::OPENAI);
    CHECK(parseTarget("chat://", tg) && tg.kind == Target::ANY);
    CHECK(parseTarget("chat://reset", tg) && tg.kind == Target::RESET);
    CHECK(parseTarget("N1:chat://claude", tg) && tg.kind == Target::CLAUDE);
    CHECK(!parseTarget("chat://bogus", tg));
    CHECK(!parseTarget("http://claude", tg));

    if (failures) { printf("%d FAILED\n", failures); return 1; }
    printf("all chatcore tests passed\n");
    return 0;
}
