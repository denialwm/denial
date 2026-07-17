// Copyright 2026 The Denial Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_NATIVE_MESSAGE_HANDLER_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_NATIVE_MESSAGE_HANDLER_H_

#include <cstddef>
#include <cstdint>

#include "flutter/denial_binary_messenger.h"

namespace flutter {

using DenialNativeMessageCallback =
    void (*)(const char* channel,
             const uint8_t* message,
             size_t message_size,
             void* user_data);

// Registers a C-compatible native callback while keeping independent owned
// copies of the messenger key and the channel name reported to the callback.
bool SetDenialNativeMessageHandler(DenialBinaryMessenger* messenger,
                                   const char* channel,
                                   DenialNativeMessageCallback callback,
                                   void* user_data);

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_NATIVE_MESSAGE_HANDLER_H_
