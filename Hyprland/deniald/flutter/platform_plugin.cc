// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/platform_plugin.h"

#include <string_view>

namespace flutter {

namespace {
constexpr char kChannelName[] = "flutter/platform";

constexpr char kGetClipboardDataMethod[] = "Clipboard.getData";
constexpr char kSetClipboardDataMethod[] = "Clipboard.setData";
constexpr char kSystemNavigatorPopMethod[] = "SystemNavigator.pop";

constexpr char kTextPlainFormat[] = "text/plain";
constexpr char kTextKey[] = "text";

constexpr char kUnknownClipboardFormatError[] =
    "Unknown clipboard format error";
}  // namespace

PlatformPlugin::PlatformPlugin(DenialBinaryMessenger* messenger)
    : channel_(std::make_unique<JsonMethodChannel>(messenger, kChannelName)) {
  channel_->SetMethodCallHandler(
      [this](const JsonMethodCall& call,
             std::unique_ptr<JsonMethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });
}

void PlatformPlugin::HandleMethodCall(
    const JsonMethodCall& method_call,
    std::unique_ptr<JsonMethodResult> result) {
  const std::string& method = method_call.method_name();

  if (method == kGetClipboardDataMethod) {
    const auto* format = method_call.arguments();
    if (!format || !format->IsString() ||
        std::string_view(format->GetString(), format->GetStringLength()) !=
            kTextPlainFormat) {
      result->Error(kUnknownClipboardFormatError,
                    "Clipboard API only supports text.");
      return;
    }

    rapidjson::Document document;
    document.SetObject();
    rapidjson::Document::AllocatorType& allocator = document.GetAllocator();
    rapidjson::Value text(clipboard_data_.data(), clipboard_data_.size(),
                          allocator);
    document.AddMember(rapidjson::Value(kTextKey, allocator), text, allocator);
    result->Success(document);
  } else if (method == kSetClipboardDataMethod) {
    const auto* document = method_call.arguments();
    if (!document || !document->IsObject()) {
      result->Error(kUnknownClipboardFormatError,
                    "Clipboard data must be an object.");
      return;
    }
    const auto text = document->FindMember(kTextKey);
    if (text == document->MemberEnd() || !text->value.IsString()) {
      result->Error(kUnknownClipboardFormatError,
                    "Missing text to store on clipboard.");
      return;
    }
    clipboard_data_.assign(text->value.GetString(),
                           text->value.GetStringLength());
    result->Success();
  } else if (method == kSystemNavigatorPopMethod) {
    // The compositor owns the process lifecycle; a Flutter route cannot exit
    // the embedded runtime.
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace flutter
