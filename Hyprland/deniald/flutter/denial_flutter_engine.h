// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_ENGINE_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_ENGINE_H_

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>

#include "flutter/denial_binary_messenger.h"
#include "flutter/denial_flutter_texture_registrar.h"
#include "flutter/embedder.h"

namespace flutter {

class DenialFlutterView;

// Platform task scheduling supplied by an embedding event loop. The callbacks
// are configured before the engine starts and remain immutable while it runs.
struct DenialPlatformTaskRunner {
  std::function<bool()> runs_task_on_current_thread;
  std::function<void(FlutterTask, uint64_t)> post_task;
  size_t identifier = 0;
};

class DenialFlutterEngine : public DenialBinaryMessenger {
 public:
  DenialFlutterEngine(std::string assets_path,
                      std::string icu_data_path,
                      std::string aot_library_path);
  ~DenialFlutterEngine() override;

  // Prevent copying.
  DenialFlutterEngine(DenialFlutterEngine const&) = delete;
  DenialFlutterEngine& operator=(DenialFlutterEngine const&) = delete;

  // Starts the engine at Denial's Dart main entrypoint.
  bool Run();

  // Returns true if the engine is currently running.
  bool running() const { return engine_ != nullptr; }

  // Stops the engine. This invalidates the pointer returned by engine().
  //
  // Returns false if stopping the engine fails, or if it was not running.
  bool Stop();

  // Sets the view that is displaying this engine's content.
  void SetView(DenialFlutterView* view);

  // The Denial view displaying this engine's content.
  DenialFlutterView* view() const { return view_; }

  // Configures Flutter to use Denial's platform event loop and deadline timer.
  void SetPlatformTaskRunner(DenialPlatformTaskRunner task_runner);

  // Platform messages and texture registration must originate on that loop.
  bool RunsPlatformTasksOnCurrentThread() const;

  // Receives Flutter's AwaitVSync baton in Denial's compositor scheduler.
  void SetVsyncRequestCallback(std::function<void(intptr_t)> callback);

  DenialFlutterTextureRegistrar* texture_registrar() const {
    return texture_registrar_.get();
  }

  // Informs the engine that the window metrics have changed.
  void SendWindowMetricsEvent(const FlutterWindowMetricsEvent& event);

  // Informs the engine of an incoming pointer event.
  void SendPointerEvent(const FlutterPointerEvent& event);

  // Returns the current time from the same monotonic clock used by the engine.
  uint64_t GetCurrentTimeNanos() const;

  // Sends a Denial bridge message that does not expect a reply.
  bool SendPlatformMessage(const char* channel,
                           const uint8_t* message,
                           size_t message_size);

  // DenialBinaryMessenger implementation used by Denial's system channels.
  void Send(const std::string& channel,
            const uint8_t* message,
            size_t message_size,
            BinaryReply reply = nullptr) const override;
  void SetMessageHandler(const std::string& channel,
                         BinaryMessageHandler handler) override;

  // Sends the given data as the response to an earlier platform message.
  void SendPlatformMessageResponse(
      const FlutterPlatformMessageResponseHandle* handle,
      const uint8_t* data,
      size_t data_length);

  // Callback passed to Flutter engine for notifying window of platform
  // messages.
  void HandlePlatformMessage(const FlutterPlatformMessage*);

  // Attempts to register the texture with the given |texture_id|.
  bool RegisterExternalTexture(int64_t texture_id);

  // Attempts to unregister the texture with the given |texture_id|.
  bool UnregisterExternalTexture(int64_t texture_id);

  // Notifies the engine about a new frame being available for the
  // given |texture_id|.
  bool MarkExternalTextureFrameAvailable(int64_t texture_id);

  // Posts the given callback onto the raster thread.
  bool PostRasterThreadTask(std::function<void()> callback);

  // Posts an already C-compatible callback without allocating a closure
  // wrapper. This is the hot path used by the Denial frame sentinel.
  bool PostRasterThreadTask(VoidCallback callback, void* callback_data);

  // Returns an externally scheduled platform task to the engine on the
  // platform thread at its requested deadline.
  bool RunPlatformTask(const FlutterTask& task);

  // Returns a specific AwaitVSync baton with timestamps already calculated in
  // the Flutter engine clock domain.
  bool OnVsyncAt(intptr_t baton,
                 uint64_t frame_start_time_nanos,
                 uint64_t frame_target_time_nanos);

  // Update display information.
  void UpdateDisplayInfo(FlutterEngineDisplaysUpdateType update_type,
                         const FlutterEngineDisplay* displays,
                         size_t display_count);

 private:
  struct AotDataDeleter {
    void operator()(_FlutterEngineAOTData* aot_data) const;
  };

  // The handle to the embedder.h engine instance.
  FLUTTER_API_SYMBOL(FlutterEngine) engine_ = nullptr;

  FlutterEngineProcTable embedder_api_ = {};

  std::string assets_path_;
  std::string icu_data_path_;
  std::string aot_library_path_;
  std::unique_ptr<_FlutterEngineAOTData, AotDataDeleter> aot_data_;

  // The view displaying the content running in this engine, if any.
  DenialFlutterView* view_ = nullptr;

  // Native platform-loop hooks installed before the engine starts.
  std::optional<DenialPlatformTaskRunner> platform_task_runner_;
  std::function<void(intptr_t)> vsync_request_callback_;

  std::map<std::string, BinaryMessageHandler> message_handlers_;

  // Resolved OpenGL functions used by external texture implementations.
  GlProcs gl_procs_ = {};

  // The texture registrar. It must be destroyed before |gl_procs_| because
  // registered textures retain a reference to those function pointers.
  std::unique_ptr<DenialFlutterTextureRegistrar> texture_registrar_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_ENGINE_H_
