// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/key_event_plugin.h"

#include "flutter/denial_json_channel.h"
#include "flutter/keyboard_glfw_util.h"

namespace flutter {

namespace {
constexpr char kKeyCodeKey[] = "keyCode";
constexpr char kKeyMapKey[] = "keymap";
constexpr char kScanCodeKey[] = "scanCode";
constexpr char kModifiersKey[] = "modifiers";
constexpr char kTypeKey[] = "type";
constexpr char kToolkitKey[] = "toolkit";
constexpr char kUnicodeScalarValues[] = "unicodeScalarValues";
constexpr char kLinuxKeyMap[] = "linux";
constexpr char kGLFWKey[] = "glfw";
constexpr char kKeyUp[] = "keyup";
constexpr char kKeyDown[] = "keydown";

}  // namespace

KeyEventPlugin::KeyEventPlugin(DenialBinaryMessenger* messenger)
    : messenger_(messenger),
      xkb_context_(xkb_context_new(XKB_CONTEXT_NO_FLAGS)) {}

KeyEventPlugin::~KeyEventPlugin() {
  if (xkb_state_) {
    xkb_state_unref(xkb_state_);
  }
  if (xkb_keymap_) {
    xkb_keymap_unref(xkb_keymap_);
  }
  if (xkb_context_) {
    xkb_context_unref(xkb_context_);
  }
}

bool KeyEventPlugin::OnKeymap(const char* keymap, size_t size) {
  if (!keymap || size == 0) {
    return false;
  }
  return InstallKeymap(std::string_view(keymap, size));
}

bool KeyEventPlugin::InstallKeymap(std::string_view keymap) {
  if (!xkb_context_ || keymap.empty()) {
    return false;
  }

  auto* new_keymap = xkb_keymap_new_from_buffer(
      xkb_context_, keymap.data(), keymap.size(), XKB_KEYMAP_FORMAT_TEXT_V1,
      XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!new_keymap) {
    return false;
  }

  auto* new_state = xkb_state_new(new_keymap);
  if (!new_state) {
    xkb_keymap_unref(new_keymap);
    return false;
  }

  if (xkb_state_) {
    xkb_state_unref(xkb_state_);
  }
  if (xkb_keymap_) {
    xkb_keymap_unref(xkb_keymap_);
  }
  xkb_keymap_ = new_keymap;
  xkb_state_ = new_state;
  xkb_mods_mask_ = 0;

  text_suppression_mask_ = 0;
  const auto ctrl_index =
      xkb_keymap_mod_get_index(xkb_keymap_, XKB_MOD_NAME_CTRL);
  const auto alt_index =
      xkb_keymap_mod_get_index(xkb_keymap_, XKB_MOD_NAME_ALT);
  if (ctrl_index != XKB_MOD_INVALID && ctrl_index < 32) {
    text_suppression_mask_ |= 1u << ctrl_index;
  }
  if (alt_index != XKB_MOD_INVALID && alt_index < 32) {
    text_suppression_mask_ |= 1u << alt_index;
  }
  return true;
}

uint32_t KeyEventPlugin::GetCodePoint(uint32_t keycode) const {
  if (!xkb_state_) {
    return 0;
  }
  auto sym = xkb_state_key_get_one_sym(xkb_state_, keycode + 8);
  return xkb_keysym_to_utf32(sym);
}

bool KeyEventPlugin::IsTextInputSuppressed(uint32_t code_point) const {
  return code_point && (xkb_mods_mask_ & text_suppression_mask_) != 0;
}

void KeyEventPlugin::OnKey(uint32_t keycode, bool pressed) {
  if (!xkb_keymap_ || !xkb_state_) {
    return;
  }
  // Denial forwards key transitions directly, including modifier keys.
  OnModifiers(keycode, pressed);
  auto unicode = GetCodePoint(keycode);
  auto mods = GetGlfwModifiers(xkb_keymap_, xkb_mods_mask_);
  auto keyscancode = GetGlfwKeycode(keycode);
  SendKeyEvent(keyscancode, unicode, mods, pressed);
}

void KeyEventPlugin::OnModifiers(uint32_t mods_depressed,
                                 uint32_t mods_latched,
                                 uint32_t mods_locked,
                                 uint32_t group) {
  if (!xkb_state_) {
    return;
  }
  xkb_state_update_mask(xkb_state_, mods_depressed, mods_latched, mods_locked,
                        0, 0, group);
  xkb_mods_mask_ =
      xkb_state_serialize_mods(xkb_state_, XKB_STATE_MODS_EFFECTIVE);
}

void KeyEventPlugin::SendKeyEvent(uint32_t keycode,
                                  uint32_t unicode,
                                  uint32_t modifiers,
                                  bool pressed) {
  rapidjson::Document event(rapidjson::kObjectType);
  auto& allocator = event.GetAllocator();
  event.AddMember(kKeyCodeKey, keycode, allocator);
  event.AddMember(kKeyMapKey, kLinuxKeyMap, allocator);
  event.AddMember(kToolkitKey, kGLFWKey, allocator);
  event.AddMember(kScanCodeKey, keycode, allocator);
  event.AddMember(kModifiersKey, modifiers, allocator);
  if (unicode != 0) {
    event.AddMember(kUnicodeScalarValues, unicode, allocator);
  }
  if (pressed) {
    event.AddMember(kTypeKey, kKeyDown, allocator);
  } else {
    event.AddMember(kTypeKey, kKeyUp, allocator);
  }
  const auto message = EncodeJsonMessage(event);
  messenger_->Send(channel_name_, message.data(), message.size());
}

void KeyEventPlugin::OnModifiers(uint32_t keycode, bool pressed) {
  xkb_state_update_key(xkb_state_, keycode + 8,
                       pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
  xkb_mods_mask_ =
      xkb_state_serialize_mods(xkb_state_, XKB_STATE_MODS_EFFECTIVE);
}

}  // namespace flutter
