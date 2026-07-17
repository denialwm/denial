// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/denial_json_channel.h"

#include <cassert>
#include <iostream>
#include <utility>

#include "rapidjson/error/en.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"

namespace flutter {

namespace {

constexpr char kMessageMethodKey[] = "method";
constexpr char kMessageArgumentsKey[] = "args";

std::unique_ptr<rapidjson::Document> DecodeJsonMessage(const uint8_t* message,
                                                       size_t size) {
  if (!message || size == 0) {
    return nullptr;
  }
  auto document = std::make_unique<rapidjson::Document>();
  const rapidjson::ParseResult result =
      document->Parse(reinterpret_cast<const char*>(message), size);
  if (result.IsError()) {
    std::cerr << "Unable to parse JSON platform message: "
              << rapidjson::GetParseError_En(result.Code()) << '\n';
    return nullptr;
  }
  return document;
}

std::unique_ptr<rapidjson::Document> ExtractElement(
    rapidjson::Document* document,
    rapidjson::Value* subtree) {
  auto extracted = std::make_unique<rapidjson::Document>();
  document->Swap(*subtree);
  extracted->Swap(*document);
  return extracted;
}

std::unique_ptr<JsonMethodCall> DecodeJsonMethodCall(const uint8_t* message,
                                                     size_t size) {
  auto document = DecodeJsonMessage(message, size);
  if (!document || !document->IsObject()) {
    return nullptr;
  }

  const auto method = document->FindMember(kMessageMethodKey);
  if (method == document->MemberEnd() || !method->value.IsString()) {
    return nullptr;
  }
  std::string method_name(method->value.GetString(),
                          method->value.GetStringLength());

  std::unique_ptr<rapidjson::Document> arguments;
  const auto args = document->FindMember(kMessageArgumentsKey);
  if (args != document->MemberEnd()) {
    arguments = ExtractElement(document.get(), &args->value);
  }
  return std::make_unique<JsonMethodCall>(std::move(method_name),
                                          std::move(arguments));
}

std::vector<uint8_t> EncodeJsonMethodCall(const JsonMethodCall& call) {
  rapidjson::Document message(rapidjson::kObjectType);
  auto& allocator = message.GetAllocator();
  rapidjson::Value method(call.method_name().c_str(), allocator);
  rapidjson::Value arguments;
  if (call.arguments()) {
    arguments.CopyFrom(*call.arguments(), allocator);
  }
  message.AddMember(kMessageMethodKey, method, allocator);
  message.AddMember(kMessageArgumentsKey, arguments, allocator);
  return EncodeJsonMessage(message);
}

std::vector<uint8_t> EncodeJsonSuccessEnvelope(
    const rapidjson::Document* result) {
  rapidjson::Document envelope(rapidjson::kArrayType);
  rapidjson::Value result_value;
  if (result) {
    result_value.CopyFrom(*result, envelope.GetAllocator());
  }
  envelope.PushBack(result_value, envelope.GetAllocator());
  return EncodeJsonMessage(envelope);
}

std::vector<uint8_t> EncodeJsonErrorEnvelope(const std::string& code,
                                             const std::string& message) {
  rapidjson::Document envelope(rapidjson::kArrayType);
  auto& allocator = envelope.GetAllocator();
  envelope.PushBack(rapidjson::Value(code.c_str(), allocator), allocator);
  envelope.PushBack(rapidjson::Value(message.c_str(), allocator), allocator);
  envelope.PushBack(rapidjson::Value(), allocator);
  return EncodeJsonMessage(envelope);
}

}  // namespace

std::vector<uint8_t> EncodeJsonMessage(const rapidjson::Document& message) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  message.Accept(writer);
  const auto* start = reinterpret_cast<const uint8_t*>(buffer.GetString());
  return std::vector<uint8_t>(start, start + buffer.GetSize());
}

JsonMethodCall::JsonMethodCall(std::string method_name,
                               std::unique_ptr<rapidjson::Document> arguments)
    : method_name_(std::move(method_name)), arguments_(std::move(arguments)) {}

JsonMethodResult::JsonMethodResult(BinaryReply reply)
    : reply_(std::move(reply)) {
  assert(reply_);
}

JsonMethodResult::~JsonMethodResult() {
  if (reply_) {
    std::cerr << "Warning: Failed to respond to a JSON platform method.\n";
  }
}

void JsonMethodResult::Success(const rapidjson::Document& result) {
  const auto response = EncodeJsonSuccessEnvelope(&result);
  SendResponse(&response);
}

void JsonMethodResult::Success() {
  const auto response = EncodeJsonSuccessEnvelope(nullptr);
  SendResponse(&response);
}

void JsonMethodResult::Error(const std::string& code,
                             const std::string& message) {
  const auto response = EncodeJsonErrorEnvelope(code, message);
  SendResponse(&response);
}

void JsonMethodResult::NotImplemented() {
  SendResponse(nullptr);
}

void JsonMethodResult::SendResponse(const std::vector<uint8_t>* data) {
  if (!reply_) {
    std::cerr << "Error: JSON platform method result was already completed.\n";
    return;
  }

  const auto* message = data && !data->empty() ? data->data() : nullptr;
  const size_t size = data ? data->size() : 0;
  reply_(message, size);
  reply_ = nullptr;
}

JsonMethodChannel::JsonMethodChannel(DenialBinaryMessenger* messenger,
                                     std::string name)
    : messenger_(messenger), name_(std::move(name)) {}

void JsonMethodChannel::InvokeMethod(
    const std::string& method,
    std::unique_ptr<rapidjson::Document> arguments) const {
  const JsonMethodCall call(method, std::move(arguments));
  const auto message = EncodeJsonMethodCall(call);
  messenger_->Send(name_, message.data(), message.size());
}

void JsonMethodChannel::SetMethodCallHandler(
    JsonMethodCallHandler handler) const {
  const std::string channel_name = name_;
  messenger_->SetMessageHandler(
      name_, [handler = std::move(handler), channel_name](
                 const uint8_t* message, size_t size, BinaryReply reply) {
        auto result = std::make_unique<JsonMethodResult>(std::move(reply));
        auto call = DecodeJsonMethodCall(message, size);
        if (!call) {
          std::cerr << "Unable to decode JSON method on channel "
                    << channel_name << '\n';
          result->NotImplemented();
          return;
        }
        handler(*call, std::move(result));
      });
}

}  // namespace flutter
