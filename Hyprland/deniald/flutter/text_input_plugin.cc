// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/text_input_plugin.h"

#include <linux/input-event-codes.h>

namespace flutter {

namespace {
constexpr char kChannelName[] = "flutter/textinput";

constexpr char kSetEditingStateMethod[] = "TextInput.setEditingState";
constexpr char kClearClientMethod[] = "TextInput.clearClient";
constexpr char kSetClientMethod[] = "TextInput.setClient";
constexpr char kShowMethod[] = "TextInput.show";
constexpr char kHideMethod[] = "TextInput.hide";

constexpr char kMultilineInputType[] = "TextInputType.multiline";

constexpr char kUpdateEditingStateMethod[] =
    "TextInputClient.updateEditingState";
constexpr char kPerformActionMethod[] = "TextInputClient.performAction";

constexpr char kTextInputAction[] = "inputAction";
constexpr char kTextInputType[] = "inputType";
constexpr char kTextInputTypeName[] = "name";
constexpr char kComposingBaseKey[] = "composingBase";
constexpr char kComposingExtentKey[] = "composingExtent";
constexpr char kSelectionAffinityKey[] = "selectionAffinity";
constexpr char kAffinityDownstream[] = "TextAffinity.downstream";
constexpr char kSelectionBaseKey[] = "selectionBase";
constexpr char kSelectionExtentKey[] = "selectionExtent";
constexpr char kSelectionIsDirectionalKey[] = "selectionIsDirectional";
constexpr char kTextKey[] = "text";

constexpr char kBadArgumentError[] = "Bad Arguments";
constexpr char kInternalConsistencyError[] = "Internal Consistency Error";
}  // namespace

void TextInputPlugin::OnKeyPressed(uint32_t keycode, uint32_t code_point) {
  if (!active_model_) {
    return;
  }

  bool changed = false;
  switch (keycode) {
    case KEY_LEFT:
      changed = active_model_->MoveCursorBack();
      break;
    case KEY_RIGHT:
      changed = active_model_->MoveCursorForward();
      break;
    case KEY_END:
      changed = active_model_->MoveCursorToEnd();
      break;
    case KEY_HOME:
      changed = active_model_->MoveCursorToBeginning();
      break;
    case KEY_BACKSPACE:
      changed = active_model_->Backspace();
      break;
    case KEY_DELETE:
      changed = active_model_->Delete();
      break;
    case KEY_ENTER:
      EnterPressed(active_model_.get());
      break;
    default:
      if (code_point) {
        active_model_->AddCodePoint(code_point);
        changed = true;
      }
      break;
  }
  if (changed) {
    SendStateUpdate(*active_model_);
  }
}

TextInputPlugin::TextInputPlugin(DenialBinaryMessenger* messenger)
    : channel_(std::make_unique<JsonMethodChannel>(messenger, kChannelName)) {
  channel_->SetMethodCallHandler(
      [this](const JsonMethodCall& call,
             std::unique_ptr<JsonMethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });
}

void TextInputPlugin::HandleMethodCall(
    const JsonMethodCall& method_call,
    std::unique_ptr<JsonMethodResult> result) {
  const std::string& method = method_call.method_name();

  if (method == kShowMethod || method == kHideMethod) {
    // Denial currently has no native on-screen keyboard; the embedded shell
    // handles physical keyboard input directly.
  } else if (method == kClearClientMethod) {
    active_model_.reset();
  } else if (method == kSetClientMethod) {
    if (!method_call.arguments() || !method_call.arguments()->IsArray() ||
        method_call.arguments()->Size() < 2) {
      result->Error(kBadArgumentError, "Method invoked without args");
      return;
    }
    const rapidjson::Document& args = *method_call.arguments();

    const rapidjson::Value& client_id_json = args[0];
    const rapidjson::Value& client_config = args[1];
    if (!client_id_json.IsInt()) {
      result->Error(kBadArgumentError, "Could not set client, ID is invalid.");
      return;
    }
    if (!client_config.IsObject()) {
      result->Error(kBadArgumentError,
                    "Could not set client, missing arguments.");
      return;
    }
    client_id_ = client_id_json.GetInt();
    input_action_.clear();
    const auto input_action_json = client_config.FindMember(kTextInputAction);
    if (input_action_json != client_config.MemberEnd() &&
        input_action_json->value.IsString()) {
      input_action_ = input_action_json->value.GetString();
    }
    input_type_.clear();
    const auto input_type_info_json = client_config.FindMember(kTextInputType);
    if (input_type_info_json != client_config.MemberEnd() &&
        input_type_info_json->value.IsObject()) {
      const auto input_type_json =
          input_type_info_json->value.FindMember(kTextInputTypeName);
      if (input_type_json != input_type_info_json->value.MemberEnd() &&
          input_type_json->value.IsString()) {
        input_type_ = input_type_json->value.GetString();
      }
    }
    active_model_ = std::make_unique<TextInputModel>();
  } else if (method == kSetEditingStateMethod) {
    if (!method_call.arguments() || !method_call.arguments()->IsObject()) {
      result->Error(kBadArgumentError, "Method invoked without args");
      return;
    }
    const rapidjson::Document& args = *method_call.arguments();

    if (!active_model_) {
      result->Error(
          kInternalConsistencyError,
          "Set editing state has been invoked, but no client is set.");
      return;
    }
    const auto text = args.FindMember(kTextKey);
    if (text == args.MemberEnd() || !text->value.IsString()) {
      result->Error(kBadArgumentError,
                    "Set editing state has been invoked, but without text.");
      return;
    }
    const auto selection_base = args.FindMember(kSelectionBaseKey);
    const auto selection_extent = args.FindMember(kSelectionExtentKey);
    if (selection_base == args.MemberEnd() || !selection_base->value.IsInt() ||
        selection_extent == args.MemberEnd() ||
        !selection_extent->value.IsInt()) {
      result->Error(kInternalConsistencyError,
                    "Selection base/extent values invalid.");
      return;
    }
    // Flutter uses -1/-1 for invalid; translate that to 0/0 for the model.
    int base = selection_base->value.GetInt();
    int extent = selection_extent->value.GetInt();
    if (base == -1 && extent == -1) {
      base = extent = 0;
    }
    active_model_->SetText(text->value.GetString());
    active_model_->SetSelection(TextRange(base, extent));
  } else {
    result->NotImplemented();
    return;
  }
  // All error conditions return early, so if nothing has gone wrong indicate
  // success.
  result->Success();
}

void TextInputPlugin::SendStateUpdate(const TextInputModel& model) {
  auto args = std::make_unique<rapidjson::Document>(rapidjson::kArrayType);
  auto& allocator = args->GetAllocator();
  args->PushBack(client_id_, allocator);

  TextRange selection = model.selection();
  rapidjson::Value editing_state(rapidjson::kObjectType);
  editing_state.AddMember(kComposingBaseKey, -1, allocator);
  editing_state.AddMember(kComposingExtentKey, -1, allocator);
  editing_state.AddMember(kSelectionAffinityKey, kAffinityDownstream,
                          allocator);
  editing_state.AddMember(kSelectionBaseKey, selection.base(), allocator);
  editing_state.AddMember(kSelectionExtentKey, selection.extent(), allocator);
  editing_state.AddMember(kSelectionIsDirectionalKey, false, allocator);
  editing_state.AddMember(
      kTextKey, rapidjson::Value(model.GetText(), allocator).Move(), allocator);
  args->PushBack(editing_state, allocator);

  channel_->InvokeMethod(kUpdateEditingStateMethod, std::move(args));
}

void TextInputPlugin::EnterPressed(TextInputModel* model) {
  if (input_type_ == kMultilineInputType) {
    model->AddCodePoint('\n');
    SendStateUpdate(*model);
  }
  auto args = std::make_unique<rapidjson::Document>(rapidjson::kArrayType);
  auto& allocator = args->GetAllocator();
  args->PushBack(client_id_, allocator);
  args->PushBack(rapidjson::Value(input_action_, allocator).Move(), allocator);

  channel_->InvokeMethod(kPerformActionMethod, std::move(args));
}

}  // namespace flutter
