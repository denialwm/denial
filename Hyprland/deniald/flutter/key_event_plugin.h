// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_KEY_EVENT_PLUGIN_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_KEY_EVENT_PLUGIN_H_

#include <xkbcommon/xkbcommon.h>

#include <string>
#include <string_view>

#include "flutter/denial_binary_messenger.h"

namespace flutter {

class KeyEventPlugin {
 public:
  explicit KeyEventPlugin(DenialBinaryMessenger* messenger);
  ~KeyEventPlugin();

  bool OnKeymap(const char* keymap, size_t size);

  void OnKey(uint32_t keycode, bool pressed);

  void OnModifiers(uint32_t mods_depressed,
                   uint32_t mods_latched,
                   uint32_t mods_locked,
                   uint32_t group);

  uint32_t GetCodePoint(uint32_t keycode) const;

  bool IsTextInputSuppressed(uint32_t code_point) const;

 private:
  void SendKeyEvent(uint32_t keycode,
                    uint32_t unicode,
                    uint32_t modifiers,
                    bool pressed);
  void OnModifiers(uint32_t keycode, bool pressed);
  bool InstallKeymap(std::string_view keymap);

  DenialBinaryMessenger* messenger_ = nullptr;
  const std::string channel_name_ = "flutter/keyevent";
  xkb_context* xkb_context_ = nullptr;
  xkb_state* xkb_state_ = nullptr;
  xkb_keymap* xkb_keymap_ = nullptr;
  xkb_mod_mask_t xkb_mods_mask_ = 0;
  xkb_mod_mask_t text_suppression_mask_ = 0;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_PLUGINS_KEY_EVENT_PLUGIN_H_
