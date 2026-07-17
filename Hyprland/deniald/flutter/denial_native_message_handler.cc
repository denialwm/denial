// Copyright 2026 The Denial Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/denial_native_message_handler.h"

#include <string>
#include <utility>

namespace flutter {

bool SetDenialNativeMessageHandler(DenialBinaryMessenger* messenger,
                                   const char* channel,
                                   DenialNativeMessageCallback callback,
                                   void* user_data) {
  if (!messenger || !channel) {
    return false;
  }

  const std::string registration_channel(channel);
  if (!callback) {
    messenger->SetMessageHandler(registration_channel, nullptr);
    return true;
  }

  // Construct the callback before registering it. Moving a channel string in
  // one function argument while reading it as another argument can register an
  // empty key because argument evaluation order is not defined left-to-right.
  const std::string callback_channel = registration_channel;
  BinaryMessageHandler handler =
      [callback, user_data, callback_channel](const uint8_t* message,
                                               size_t size,
                                               BinaryReply reply) {
        callback(callback_channel.c_str(), message, size, user_data);
        if (reply) {
          reply(nullptr, 0);
        }
      };
  messenger->SetMessageHandler(registration_channel, std::move(handler));
  return true;
}

}  // namespace flutter
