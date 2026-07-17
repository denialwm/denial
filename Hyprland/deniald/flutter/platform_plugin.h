// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_PLATFORM_PLUGIN_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_PLATFORM_PLUGIN_H_

#include <memory>
#include <string>

#include "flutter/denial_json_channel.h"

namespace flutter {

class PlatformPlugin {
 public:
  explicit PlatformPlugin(DenialBinaryMessenger* messenger);
  ~PlatformPlugin() = default;

 private:
  // Called when a method is received on |channel_|.
  void HandleMethodCall(const JsonMethodCall& method_call,
                        std::unique_ptr<JsonMethodResult> result);

  // The MethodChannel used for communication with the Flutter engine.
  std::unique_ptr<JsonMethodChannel> channel_;

  std::string clipboard_data_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_PLATFORM_PLUGIN_H_
