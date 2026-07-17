// Copyright 2026 The Denial Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <cstdint>
#include <iostream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "flutter/denial_native_message_handler.h"

namespace {

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
  }
  return condition;
}

class FakeMessenger final : public flutter::DenialBinaryMessenger {
 public:
  void Send(const std::string&,
            const uint8_t*,
            size_t,
            flutter::BinaryReply) const override {}

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {
    if (handler) {
      handlers[channel] = std::move(handler);
    } else {
      handlers.erase(channel);
    }
  }

  std::unordered_map<std::string, flutter::BinaryMessageHandler> handlers;
};

struct CallbackState {
  std::string channel;
  std::vector<uint8_t> message;
  size_t calls = 0;
};

void RecordMessage(const char* channel,
                   const uint8_t* message,
                   size_t size,
                   void* user_data) {
  auto* state = static_cast<CallbackState*>(user_data);
  state->channel = channel ? channel : "";
  state->message.assign(message, message + size);
  ++state->calls;
}

}  // namespace

int main() {
  constexpr char kWireChannel[] = "denial/wire/to_native";
  constexpr char kCommandChannel[] = "denial/system_command";
  FakeMessenger messenger;
  CallbackState wire_state;
  CallbackState command_state;

  if (!Expect(flutter::SetDenialNativeMessageHandler(
                  &messenger, kWireChannel, RecordMessage, &wire_state),
              "wire handler registration failed") ||
      !Expect(flutter::SetDenialNativeMessageHandler(
                  &messenger, kCommandChannel, RecordMessage, &command_state),
              "command handler registration failed") ||
      !Expect(messenger.handlers.size() == 2,
              "distinct native channels overwrote one another") ||
      !Expect(messenger.handlers.count(kWireChannel) == 1,
              "wire handler was registered under the wrong key") ||
      !Expect(messenger.handlers.count(kCommandChannel) == 1,
              "command handler was registered under the wrong key")) {
    return 1;
  }

  const std::vector<uint8_t> wire_message = {1, 2, 3};
  bool wire_reply_called = false;
  messenger.handlers.at(kWireChannel)(
      wire_message.data(), wire_message.size(),
      [&wire_reply_called](const uint8_t* data, size_t size) {
        wire_reply_called = data == nullptr && size == 0;
      });

  const std::vector<uint8_t> command_message = {9, 8};
  bool command_reply_called = false;
  messenger.handlers.at(kCommandChannel)(
      command_message.data(), command_message.size(),
      [&command_reply_called](const uint8_t* data, size_t size) {
        command_reply_called = data == nullptr && size == 0;
      });

  if (!Expect(wire_state.channel == kWireChannel,
              "wire callback received the wrong channel") ||
      !Expect(wire_state.message == wire_message && wire_state.calls == 1,
              "wire callback received the wrong payload") ||
      !Expect(command_state.channel == kCommandChannel,
              "command callback received the wrong channel") ||
      !Expect(command_state.message == command_message &&
                  command_state.calls == 1,
              "command callback received the wrong payload") ||
      !Expect(wire_reply_called && command_reply_called,
              "native callback did not complete its platform reply")) {
    return 1;
  }

  if (!Expect(flutter::SetDenialNativeMessageHandler(
                  &messenger, kWireChannel, nullptr, nullptr),
              "wire handler removal failed") ||
      !Expect(messenger.handlers.count(kWireChannel) == 0,
              "wire handler remained registered") ||
      !Expect(messenger.handlers.count(kCommandChannel) == 1,
              "removing one handler affected another channel")) {
    return 1;
  }

  return 0;
}
