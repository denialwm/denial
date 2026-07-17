// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_TEXT_INPUT_PLUGIN_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_TEXT_INPUT_PLUGIN_H_

#include <cstdint>
#include <memory>
#include <string>

#include "flutter/denial_json_channel.h"
#include "flutter/text_input_model.h"

namespace flutter {

class TextInputPlugin {
 public:
  explicit TextInputPlugin(DenialBinaryMessenger* messenger);
  ~TextInputPlugin() = default;

  void OnKeyPressed(uint32_t keycode, uint32_t code_point);

 private:
  // Sends the current state of the given model to the Flutter engine.
  void SendStateUpdate(const TextInputModel& model);

  // Sends an action triggered by the Enter key to the Flutter engine.
  void EnterPressed(TextInputModel* model);

  // Called when a method is received on |channel_|.
  void HandleMethodCall(const JsonMethodCall& method_call,
                        std::unique_ptr<JsonMethodResult> result);

  // The MethodChannel used for communication with the Flutter engine.
  std::unique_ptr<JsonMethodChannel> channel_;

  // The active client id.
  int client_id_ = 0;

  // The active model. nullptr if not set.
  std::unique_ptr<TextInputModel> active_model_;

  // Keyboard type of the client. See available options:
  // https://docs.flutter.io/flutter/services/TextInputType-class.html
  std::string input_type_;

  // An action requested by the user on the input client. See available options:
  // https://docs.flutter.io/flutter/services/TextInputAction-class.html
  std::string input_action_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_TEXT_INPUT_PLUGIN_H_
