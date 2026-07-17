// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_JSON_CHANNEL_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_JSON_CHANNEL_H_

#include <rapidjson/document.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "flutter/denial_binary_messenger.h"

namespace flutter {

std::vector<uint8_t> EncodeJsonMessage(const rapidjson::Document& message);

class JsonMethodCall {
 public:
  JsonMethodCall(std::string method_name,
                 std::unique_ptr<rapidjson::Document> arguments);

  JsonMethodCall(const JsonMethodCall&) = delete;
  JsonMethodCall& operator=(const JsonMethodCall&) = delete;

  const std::string& method_name() const { return method_name_; }
  const rapidjson::Document* arguments() const { return arguments_.get(); }

 private:
  std::string method_name_;
  std::unique_ptr<rapidjson::Document> arguments_;
};

class JsonMethodResult {
 public:
  explicit JsonMethodResult(BinaryReply reply);
  ~JsonMethodResult();

  JsonMethodResult(const JsonMethodResult&) = delete;
  JsonMethodResult& operator=(const JsonMethodResult&) = delete;

  void Success(const rapidjson::Document& result);
  void Success();
  void Error(const std::string& code, const std::string& message);
  void NotImplemented();

 private:
  void SendResponse(const std::vector<uint8_t>* data);

  BinaryReply reply_;
};

using JsonMethodCallHandler =
    std::function<void(const JsonMethodCall& call,
                       std::unique_ptr<JsonMethodResult> result)>;

class JsonMethodChannel {
 public:
  JsonMethodChannel(DenialBinaryMessenger* messenger, std::string name);

  JsonMethodChannel(const JsonMethodChannel&) = delete;
  JsonMethodChannel& operator=(const JsonMethodChannel&) = delete;

  void InvokeMethod(const std::string& method,
                    std::unique_ptr<rapidjson::Document> arguments) const;
  void SetMethodCallHandler(JsonMethodCallHandler handler) const;

 private:
  DenialBinaryMessenger* messenger_;
  std::string name_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_JSON_CHANNEL_H_
