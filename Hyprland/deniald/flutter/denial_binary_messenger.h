// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_BINARY_MESSENGER_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_BINARY_MESSENGER_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace flutter {

using BinaryReply =
    std::function<void(const uint8_t* reply, size_t reply_size)>;

using BinaryMessageHandler = std::function<
    void(const uint8_t* message, size_t message_size, BinaryReply reply)>;

// The binary channel boundary implemented by DenialFlutterEngine and used by
// Denial's retained Flutter system-channel handlers.
class DenialBinaryMessenger {
 public:
  virtual ~DenialBinaryMessenger() = default;

  virtual void Send(const std::string& channel,
                    const uint8_t* message,
                    size_t message_size,
                    BinaryReply reply = nullptr) const = 0;

  virtual void SetMessageHandler(const std::string& channel,
                                 BinaryMessageHandler handler) = 0;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_BINARY_MESSENGER_H_
