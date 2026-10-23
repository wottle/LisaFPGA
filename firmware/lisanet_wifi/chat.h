// chat -- an AI chat endpoint for Lisa programs: the Lisa opens chat://claude or chat://openai on a network unit
// (fujinet.cpp), writes a question as plain text and reads the answer back as plain ASCII. This module holds the API
// keys and settings (NVS), the conversation history, and makes the HTTPS call on a task of its own, because a model can
// take half a minute and the main loop must keep answering the Lisa meanwhile. Written with an AI assistant.
#pragma once
#include <Arduino.h>
#include <string>

namespace chat {

enum State { IDLE, RUNNING, REPLY };   // REPLY: an answer (or an error written as text) is waiting for takeReply()

void begin();
void poll();                           // from loop(): when the task has finished, update the history and go to REPLY

State state();

// Start a question. kind: 0 default provider, 1 Claude, 2 OpenAI (chatcore::Target::Kind order is not used here).
// remember: add it to the conversation (the Lisa); false for the web page's one-off test. Returns false only when a
// question is already running or an unread answer is waiting; a missing key is an answer ("[error: ...]"), not a failure.
bool start(int kind, const std::string &prompt, bool remember);
std::string takeReply();               // the waiting answer; state goes back to IDLE
void resetHistory();                   // chat://reset: forget the conversation (both providers)

String infoJson();                     // settings and state, never the keys: {"provider","claudeKey":bool,...}
bool setConfig(const String &name, const String &value, String &err);   // provider claudeKey openaiKey claudeModel
                                       // openaiModel maxTokens turns system verify; kept in NVS at once

}  // namespace chat
