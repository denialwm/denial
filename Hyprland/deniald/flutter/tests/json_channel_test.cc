// Copyright 2026 The Denial Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <rapidjson/document.h>

#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "flutter/denial_json_channel.h"

namespace {

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
  }
  return condition;
}

class FakeMessenger final : public flutter::DenialBinaryMessenger {
 public:
  void Send(const std::string& channel,
            const uint8_t* message,
            size_t size,
            flutter::BinaryReply) const override {
    sent_channel = channel;
    sent_message.assign(message, message + size);
  }

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler new_handler) override {
    handler_channel = channel;
    handler = std::move(new_handler);
  }

  mutable std::string sent_channel;
  mutable std::vector<uint8_t> sent_message;
  std::string handler_channel;
  flutter::BinaryMessageHandler handler;
};

}  // namespace

int main() {
  FakeMessenger messenger;
  flutter::JsonMethodChannel channel(&messenger, "denial/test");

  auto arguments =
      std::make_unique<rapidjson::Document>(rapidjson::kObjectType);
  arguments->AddMember("value", 42, arguments->GetAllocator());
  channel.InvokeMethod("ping", std::move(arguments));

  rapidjson::Document sent;
  sent.Parse(reinterpret_cast<const char*>(messenger.sent_message.data()),
             messenger.sent_message.size());
  if (!Expect(messenger.sent_channel == "denial/test",
              "outgoing message used the wrong channel") ||
      !Expect(sent.IsObject(), "outgoing method call is not JSON") ||
      !Expect(sent.HasMember("method") && sent["method"].IsString() &&
                  std::string(sent["method"].GetString()) == "ping",
              "outgoing method name was not preserved") ||
      !Expect(sent.HasMember("args") && sent["args"].IsObject() &&
                  sent["args"].HasMember("value") &&
                  sent["args"]["value"].GetInt() == 42,
              "outgoing method arguments were not preserved")) {
    return 1;
  }

  bool handled = false;
  channel.SetMethodCallHandler(
      [&handled](const flutter::JsonMethodCall& call,
                 std::unique_ptr<flutter::JsonMethodResult> result) {
        handled = call.method_name() == "pong" && call.arguments() &&
                  call.arguments()->IsString() &&
                  std::string(call.arguments()->GetString()) == "ready";
        result->Success();
      });

  constexpr char kIncoming[] = R"({"method":"pong","args":"ready"})";
  std::vector<uint8_t> reply;
  messenger.handler(reinterpret_cast<const uint8_t*>(kIncoming),
                    sizeof(kIncoming) - 1,
                    [&reply](const uint8_t* data, size_t size) {
                      if (data) {
                        reply.assign(data, data + size);
                      }
                    });

  const std::string reply_text(reply.begin(), reply.end());
  if (!Expect(messenger.handler_channel == "denial/test",
              "incoming handler used the wrong channel") ||
      !Expect(handled, "incoming JSON method was not decoded") ||
      !Expect(reply_text == "[null]",
              "successful JSON method reply was encoded incorrectly")) {
    return 1;
  }

  return 0;
}
