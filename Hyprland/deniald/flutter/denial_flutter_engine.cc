// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/denial_flutter_engine.h"

#include <iostream>
#include <memory>
#include <utility>

#include "flutter/denial_flutter_error.h"
#include "flutter/denial_flutter_view.h"

namespace flutter {

namespace {

// Creates and returns a FlutterRendererConfig that renders to the view (if any)
// of a DenialFlutterEngine, which should be the user_data received by the
// render callbacks.
FlutterRendererConfig GetRendererConfig() {
  FlutterRendererConfig config = {};
  config.type = kOpenGL;
  config.open_gl.struct_size = sizeof(config.open_gl);
  config.open_gl.make_current = [](void* user_data) -> bool {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->view()) {
      return false;
    }
    return host->view()->MakeCurrent();
  };
  config.open_gl.clear_current = [](void* user_data) -> bool {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->view()) {
      return false;
    }
    return host->view()->ClearCurrent();
  };
  config.open_gl.fbo_reset_after_present = true;
  config.open_gl.present_with_info =
      [](void* user_data, const FlutterPresentInfo* info) -> bool {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->view()) {
      return false;
    }
    return host->view()->PresentWithInfo(info);
  };
  config.open_gl.populate_existing_damage =
      [](void* user_data, const intptr_t fbo_id,
         FlutterDamage* existing_damage) -> void {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (host->view()) {
      host->view()->PopulateExistingDamage(fbo_id, existing_damage);
    }
  };
  config.open_gl.fbo_with_frame_info_callback =
      [](void* user_data, const FlutterFrameInfo* frame_info) -> uint32_t {
    (void)frame_info;
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->view()) {
      return 0;
    }
    return host->view()->GetOnscreenFBO();
  };
  config.open_gl.gl_proc_resolver = [](void* user_data,
                                       const char* name) -> void* {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->view()) {
      return nullptr;
    }
    return host->view()->ProcResolver(name);
  };
  config.open_gl.make_resource_current = [](void* user_data) -> bool {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->view()) {
      return false;
    }
    return host->view()->MakeResourceCurrent();
  };
  config.open_gl.gl_external_texture_frame_callback =
      [](void* user_data, int64_t texture_id, size_t width, size_t height,
         FlutterOpenGLTexture* texture) -> bool {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (!host->texture_registrar()) {
      return false;
    }
    return host->texture_registrar()->PopulateTexture(texture_id, width, height,
                                                      texture);
  };
  config.open_gl.surface_transformation =
      [](void* user_data) -> FlutterTransformation {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    return host->view()->GetRootSurfaceTransformation();
  };
  return config;
}

}  // namespace

DenialFlutterEngine::DenialFlutterEngine(std::string assets_path,
                                         std::string icu_data_path,
                                         std::string aot_library_path)
    : assets_path_(std::move(assets_path)),
      icu_data_path_(std::move(icu_data_path)),
      aot_library_path_(std::move(aot_library_path)),
      aot_data_(nullptr) {
  embedder_api_.struct_size = sizeof(FlutterEngineProcTable);
  FlutterEngineGetProcAddresses(&embedder_api_);

  DenialFlutterTextureRegistrar::ResolveGlFunctions(gl_procs_);
  texture_registrar_ =
      std::make_unique<DenialFlutterTextureRegistrar>(this, gl_procs_);
}

DenialFlutterEngine::~DenialFlutterEngine() {
  Stop();
}

void DenialFlutterEngine::AotDataDeleter::operator()(
    _FlutterEngineAOTData* aot_data) const {
  FlutterEngineCollectAOTData(aot_data);
}

void DenialFlutterEngine::SetPlatformTaskRunner(
    DenialPlatformTaskRunner task_runner) {
  platform_task_runner_ = std::move(task_runner);
}

bool DenialFlutterEngine::RunsPlatformTasksOnCurrentThread() const {
  return platform_task_runner_ &&
         platform_task_runner_->runs_task_on_current_thread &&
         platform_task_runner_->runs_task_on_current_thread();
}

void DenialFlutterEngine::SetVsyncRequestCallback(
    std::function<void(intptr_t)> callback) {
  vsync_request_callback_ = std::move(callback);
}

bool DenialFlutterEngine::Run() {
  if (!platform_task_runner_ ||
      !platform_task_runner_->runs_task_on_current_thread ||
      !platform_task_runner_->post_task || !vsync_request_callback_) {
    DENIAL_FLUTTER_ERROR
        << "Denial platform scheduling callbacks are incomplete.";
    return false;
  }
  if (assets_path_.empty() || icu_data_path_.empty()) {
    DENIAL_FLUTTER_ERROR << "Missing Flutter assets or ICU path.";
    return false;
  }
  if (embedder_api_.RunsAOTCompiledDartCode()) {
    if (aot_library_path_.empty()) {
      DENIAL_FLUTTER_ERROR << "Missing Flutter AOT library path.";
      return false;
    }

    FlutterEngineAOTDataSource source = {};
    source.type = kFlutterEngineAOTDataSourceTypeElfPath;
    source.elf_path = aot_library_path_.c_str();
    FlutterEngineAOTData data = nullptr;
    if (embedder_api_.CreateAOTData(&source, &data) != kSuccess) {
      DENIAL_FLUTTER_ERROR << "Failed to load AOT data from: "
                           << aot_library_path_;
      return false;
    }
    aot_data_.reset(data);
    if (!aot_data_) {
      DENIAL_FLUTTER_ERROR << "Unable to start engine without AOT data.";
      return false;
    }
  }

  const char* argv[] = {"deniald"};

  // Configure task runners.
  FlutterTaskRunnerDescription platform_task_runner = {};
  platform_task_runner.struct_size = sizeof(FlutterTaskRunnerDescription);
  platform_task_runner.user_data = this;
  platform_task_runner.runs_task_on_current_thread_callback =
      [](void* user_data) -> bool {
    return static_cast<DenialFlutterEngine*>(user_data)
        ->RunsPlatformTasksOnCurrentThread();
  };
  platform_task_runner.post_task_callback = [](FlutterTask task,
                                               uint64_t target_time_nanos,
                                               void* user_data) -> void {
    auto* engine = static_cast<DenialFlutterEngine*>(user_data);
    engine->platform_task_runner_->post_task(task, target_time_nanos);
  };
  platform_task_runner.identifier = platform_task_runner_->identifier;
  FlutterCustomTaskRunners custom_task_runners = {};
  custom_task_runners.struct_size = sizeof(FlutterCustomTaskRunners);
  custom_task_runners.platform_task_runner = &platform_task_runner;

  FlutterProjectArgs args = {};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = assets_path_.c_str();
  args.icu_data_path = icu_data_path_.c_str();
  args.command_line_argc = 1;
  args.command_line_argv = argv;
  args.platform_message_callback =
      [](const FlutterPlatformMessage* engine_message,
         void* user_data) -> void {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    return host->HandlePlatformMessage(engine_message);
  };
  args.vsync_callback = [](void* user_data, intptr_t baton) -> void {
    auto host = static_cast<DenialFlutterEngine*>(user_data);
    if (host->vsync_request_callback_) {
      host->vsync_request_callback_(baton);
    }
  };
  args.custom_task_runners = &custom_task_runners;

  if (aot_data_) {
    args.aot_data = aot_data_.get();
  }
  args.log_message_callback = [](const char* tag, const char* message, void*) {
    if (tag && *tag) {
      std::cout << tag << ": ";
    }
    std::cout << (message ? message : "") << '\n';
  };

  auto renderer_config = GetRendererConfig();
  auto result = embedder_api_.Run(FLUTTER_ENGINE_VERSION, &renderer_config,
                                  &args, this, &engine_);
  if (result != kSuccess || engine_ == nullptr) {
    DENIAL_FLUTTER_ERROR << "Failed to start Flutter engine: error " << result;
    return false;
  }

  return true;
}

bool DenialFlutterEngine::Stop() {
  if (engine_) {
    FlutterEngineResult result = embedder_api_.Shutdown(engine_);
    engine_ = nullptr;
    return (result == kSuccess);
  }
  return false;
}

void DenialFlutterEngine::SetView(DenialFlutterView* view) {
  view_ = view;
}

void DenialFlutterEngine::SendWindowMetricsEvent(
    const FlutterWindowMetricsEvent& event) {
  if (engine_) {
    embedder_api_.SendWindowMetricsEvent(engine_, &event);
  }
}

void DenialFlutterEngine::SendPointerEvent(const FlutterPointerEvent& event) {
  if (engine_) {
    embedder_api_.SendPointerEvent(engine_, &event, 1);
  }
}

uint64_t DenialFlutterEngine::GetCurrentTimeNanos() const {
  return embedder_api_.GetCurrentTime();
}

bool DenialFlutterEngine::SendPlatformMessage(const char* channel,
                                              const uint8_t* message,
                                              size_t message_size) {
  if (!engine_ || !channel || !RunsPlatformTasksOnCurrentThread()) {
    return false;
  }

  FlutterPlatformMessage platform_message = {
      sizeof(FlutterPlatformMessage), channel, message, message_size, nullptr,
  };
  return embedder_api_.SendPlatformMessage(engine_, &platform_message) ==
         kSuccess;
}

void DenialFlutterEngine::Send(const std::string& channel,
                               const uint8_t* message,
                               size_t message_size,
                               BinaryReply reply) const {
  if (!engine_ || channel.empty() || !RunsPlatformTasksOnCurrentThread()) {
    return;
  }

  std::unique_ptr<BinaryReply> reply_context;
  FlutterPlatformMessageResponseHandle* response_handle = nullptr;
  if (reply) {
    reply_context = std::make_unique<BinaryReply>(std::move(reply));
    const auto result = embedder_api_.PlatformMessageCreateResponseHandle(
        engine_,
        [](const uint8_t* data, size_t size, void* user_data) {
          std::unique_ptr<BinaryReply> callback(
              static_cast<BinaryReply*>(user_data));
          (*callback)(data, size);
        },
        reply_context.get(), &response_handle);
    if (result != kSuccess) {
      DENIAL_FLUTTER_ERROR << "Failed to create response handle.";
      return;
    }
  }

  const FlutterPlatformMessage platform_message = {
      sizeof(FlutterPlatformMessage), channel.c_str(), message, message_size,
      response_handle};
  const auto result =
      embedder_api_.SendPlatformMessage(engine_, &platform_message);
  if (response_handle) {
    embedder_api_.PlatformMessageReleaseResponseHandle(engine_,
                                                       response_handle);
  }
  if (result == kSuccess) {
    reply_context.release();
  }
}

void DenialFlutterEngine::SetMessageHandler(const std::string& channel,
                                            BinaryMessageHandler handler) {
  if (!handler) {
    message_handlers_.erase(channel);
    return;
  }
  message_handlers_[channel] = std::move(handler);
}

void DenialFlutterEngine::SendPlatformMessageResponse(
    const FlutterPlatformMessageResponseHandle* handle,
    const uint8_t* data,
    size_t data_length) {
  embedder_api_.SendPlatformMessageResponse(engine_, handle, data, data_length);
}

void DenialFlutterEngine::HandlePlatformMessage(
    const FlutterPlatformMessage* engine_message) {
  if (!engine_message || !engine_message->channel ||
      engine_message->struct_size != sizeof(FlutterPlatformMessage)) {
    DENIAL_FLUTTER_ERROR << "Invalid Flutter platform message received.";
    return;
  }

  const auto handler = message_handlers_.find(engine_message->channel);
  if (handler == message_handlers_.end()) {
    if (engine_message->response_handle) {
      SendPlatformMessageResponse(engine_message->response_handle, nullptr, 0);
    }
    return;
  }

  BinaryReply reply = [](const uint8_t*, size_t) {};
  if (engine_message->response_handle) {
    struct ReplyState {
      const FlutterPlatformMessageResponseHandle* handle;
    };
    auto reply_state = std::make_shared<ReplyState>(
        ReplyState{engine_message->response_handle});
    reply = [this, reply_state](const uint8_t* data, size_t size) {
      const auto* handle = std::exchange(reply_state->handle, nullptr);
      if (!handle) {
        DENIAL_FLUTTER_ERROR << "Platform message response was already sent.";
        return;
      }
      SendPlatformMessageResponse(handle, data, size);
    };
  }
  handler->second(engine_message->message, engine_message->message_size,
                  std::move(reply));
}

bool DenialFlutterEngine::RegisterExternalTexture(int64_t texture_id) {
  return engine_ && (embedder_api_.RegisterExternalTexture(
                         engine_, texture_id) == kSuccess);
}

bool DenialFlutterEngine::UnregisterExternalTexture(int64_t texture_id) {
  return engine_ && (embedder_api_.UnregisterExternalTexture(
                         engine_, texture_id) == kSuccess);
}

bool DenialFlutterEngine::MarkExternalTextureFrameAvailable(
    int64_t texture_id) {
  // FlutterEngineMarkExternalTextureFrameAvailable already schedules
  // Engine::ScheduleFrame(false): a texture-only frame that reuses the last
  // layer tree. Calling ScheduleFrame() again upgrades that pending request to
  // a full shell rebuild and defeats the engine's built-in demand coalescing.
  return engine_ && embedder_api_.MarkExternalTextureFrameAvailable(
                        engine_, texture_id) == kSuccess;
}

bool DenialFlutterEngine::PostRasterThreadTask(std::function<void()> callback) {
  if (!engine_ || !callback) {
    return false;
  }
  auto owned_callback =
      std::make_unique<std::function<void()>>(std::move(callback));
  if (embedder_api_.PostRenderThreadTask(
          engine_,
          [](void* opaque) {
            std::unique_ptr<std::function<void()>> callback(
                static_cast<std::function<void()>*>(opaque));
            (*callback)();
          },
          owned_callback.get()) == kSuccess) {
    owned_callback.release();
    return true;
  }
  return false;
}

bool DenialFlutterEngine::PostRasterThreadTask(VoidCallback callback,
                                               void* callback_data) {
  return engine_ && callback &&
         embedder_api_.PostRenderThreadTask(engine_, callback, callback_data) ==
             kSuccess;
}

bool DenialFlutterEngine::RunPlatformTask(const FlutterTask& task) {
  return engine_ && embedder_api_.RunTask(engine_, &task) == kSuccess;
}

bool DenialFlutterEngine::OnVsyncAt(intptr_t baton,
                                    uint64_t frame_start_time_nanos,
                                    uint64_t frame_target_time_nanos) {
  return engine_ &&
         embedder_api_.OnVsync(engine_, baton, frame_start_time_nanos,
                               frame_target_time_nanos) == kSuccess;
}

void DenialFlutterEngine::UpdateDisplayInfo(
    FlutterEngineDisplaysUpdateType update_type,
    const FlutterEngineDisplay* displays,
    size_t display_count) {
  if (engine_) {
    embedder_api_.NotifyDisplayUpdate(engine_, update_type, displays,
                                      display_count);
  }
}

}  // namespace flutter
