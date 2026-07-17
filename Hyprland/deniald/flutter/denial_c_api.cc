// Copyright 2026.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/denial_c_api.h"

#include <atomic>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "flutter/denial_flutter_engine.h"
#include "flutter/denial_flutter_view.h"
#include "flutter/denial_native_message_handler.h"
#include "flutter/denial_render_delegate.h"

namespace {

void ConvertDamage(const FlutterDamage& damage,
                   std::vector<DenialRect>& rects) {
  rects.clear();
  if (!damage.damage) {
    return;
  }

  rects.reserve(damage.num_rects);

  for (size_t i = 0; i < damage.num_rects; ++i) {
    const auto& rect = damage.damage[i];
    DenialRect c_rect = {};
    c_rect.left = rect.left;
    c_rect.top = rect.top;
    c_rect.right = rect.right;
    c_rect.bottom = rect.bottom;
    rects.push_back(c_rect);
  }
}

class CApiRenderDelegate final : public flutter::DenialRenderDelegate {
 public:
  void SetCallbacks(const DenialRenderCallbacks& callbacks) {
    callbacks_ = callbacks;
  }

  bool GLContextMakeCurrent() const override {
    return callbacks_.make_current &&
           callbacks_.make_current(callbacks_.user_data);
  }

  bool GLContextClearCurrent() const override {
    return !callbacks_.clear_current ||
           callbacks_.clear_current(callbacks_.user_data);
  }

  bool GLContextPresentWithInfo(const FlutterPresentInfo* info) const override {
    if (!info || !callbacks_.present_with_info) {
      return false;
    }

    // Present runs on Flutter's raster thread. Reuse these buffers so damage
    // forwarding does not allocate twice on every frame.
    thread_local std::vector<DenialRect> frame_damage;
    thread_local std::vector<DenialRect> buffer_damage;
    ConvertDamage(info->frame_damage, frame_damage);
    ConvertDamage(info->buffer_damage, buffer_damage);
    DenialPresentInfo c_info = {};
    c_info.fbo_id = info->fbo_id;
    c_info.frame_damage.num_rects = frame_damage.size();
    c_info.frame_damage.rects =
        frame_damage.empty() ? nullptr : frame_damage.data();
    c_info.buffer_damage.num_rects = buffer_damage.size();
    c_info.buffer_damage.rects =
        buffer_damage.empty() ? nullptr : buffer_damage.data();

    return callbacks_.present_with_info(callbacks_.user_data, &c_info);
  }

  void PopulateExistingDamage(intptr_t fbo_id,
                              FlutterDamage* existing_damage) const override {
    if (!existing_damage) {
      return;
    }

    existing_damage->struct_size = sizeof(FlutterDamage);
    existing_damage->num_rects = 0;
    existing_damage->damage = nullptr;

    if (!callbacks_.populate_existing_damage) {
      const auto bounds = GetPhysicalWindowBounds();
      auto& rects = existing_damage_[fbo_id];
      FlutterRect rect = {};
      rect.left = 0;
      rect.top = 0;
      rect.right = static_cast<double>(bounds.width > 0 ? bounds.width : 1);
      rect.bottom = static_cast<double>(bounds.height > 0 ? bounds.height : 1);
      rects = {rect};
      existing_damage->num_rects = rects.size();
      existing_damage->damage = rects.data();
      return;
    }

    const size_t count = callbacks_.populate_existing_damage(
        callbacks_.user_data, fbo_id, nullptr, 0);
    auto& rects = existing_damage_[fbo_id];
    rects.clear();
    if (count == 0) {
      return;
    }

    std::vector<DenialRect> c_rects(count);
    const size_t written = callbacks_.populate_existing_damage(
        callbacks_.user_data, fbo_id, c_rects.data(), c_rects.size());
    rects.reserve(written);
    for (size_t i = 0; i < written && i < c_rects.size(); ++i) {
      const auto& rect = c_rects[i];
      FlutterRect flutter_rect = {};
      flutter_rect.left = rect.left;
      flutter_rect.top = rect.top;
      flutter_rect.right = rect.right;
      flutter_rect.bottom = rect.bottom;
      rects.push_back(flutter_rect);
    }

    existing_damage->num_rects = rects.size();
    existing_damage->damage = rects.empty() ? nullptr : rects.data();
  }

  uint32_t GLContextFBO() const override {
    return callbacks_.fbo ? callbacks_.fbo(callbacks_.user_data) : 0;
  }

  bool ResourceContextMakeCurrent() const override {
    return callbacks_.resource_make_current &&
           callbacks_.resource_make_current(callbacks_.user_data);
  }

  void* GlProcResolver(const char* name) const override {
    return callbacks_.gl_proc_resolver
               ? callbacks_.gl_proc_resolver(callbacks_.user_data, name)
               : nullptr;
  }

  bool OnScreenSurfaceResize(size_t width_px, size_t height_px) override {
    return callbacks_.resize &&
           callbacks_.resize(callbacks_.user_data, width_px, height_px);
  }

  flutter::PhysicalWindowBounds GetPhysicalWindowBounds() const override {
    size_t width = 1;
    size_t height = 1;
    if (callbacks_.bounds) {
      callbacks_.bounds(callbacks_.user_data, &width, &height);
    }
    return {width, height};
  }

  double GetDpiScale() const override {
    return callbacks_.dpi_scale ? callbacks_.dpi_scale(callbacks_.user_data)
                                : 1.0;
  }

  int32_t GetFrameRate() const override {
    return callbacks_.frame_rate ? callbacks_.frame_rate(callbacks_.user_data)
                                 : 60000;
  }

  uint16_t GetSurfaceTransform() const override {
    return callbacks_.surface_transform
               ? callbacks_.surface_transform(callbacks_.user_data)
               : 0;
  }

 private:
  DenialRenderCallbacks callbacks_ = {};
  mutable std::unordered_map<intptr_t, std::vector<FlutterRect>>
      existing_damage_;
};

struct CApiEGLImageTextureState {
  DenialEGLImageTextureCallback callback = nullptr;
  void* user_data = nullptr;
  std::atomic_bool retired = false;
};

struct CApiPixelBufferTextureState {
  DenialPixelBufferTextureCallback callback = nullptr;
  void* user_data = nullptr;
  std::atomic_bool retired = false;
};

const flutter::ExternalTextureEGLImageFrame* OnEGLImageTexture(
    size_t width,
    size_t height,
    void* egl_display,
    void* egl_context,
    void* user_data) {
  auto* state = static_cast<CApiEGLImageTextureState*>(user_data);
  if (!state || state->retired.load(std::memory_order_acquire) ||
      !state->callback) {
    return nullptr;
  }

  const DenialEGLImageDescriptor* source = state->callback(
      width, height, egl_display, egl_context, state->user_data);
  if (!source || !source->egl_image) {
    return nullptr;
  }

  thread_local flutter::ExternalTextureEGLImageFrame image;
  image.egl_image = source->egl_image;
  image.stable_id = source->stable_id;
  image.width = source->width;
  image.height = source->height;
  image.release_callback = source->release_callback;
  image.release_context = source->release_context;
  return &image;
}

const flutter::ExternalTexturePixelBufferFrame*
OnPixelBufferTexture(size_t width, size_t height, void* user_data) {
  auto* state = static_cast<CApiPixelBufferTextureState*>(user_data);
  if (!state || state->retired.load(std::memory_order_acquire) ||
      !state->callback) {
    return nullptr;
  }

  const DenialPixelBufferDescriptor* source =
      state->callback(width, height, state->user_data);
  if (!source || !source->buffer) {
    return nullptr;
  }

  thread_local flutter::ExternalTexturePixelBufferFrame buffer;
  buffer.buffer = source->buffer;
  buffer.width = source->width;
  buffer.height = source->height;
  buffer.release_callback = source->release_callback;
  buffer.release_context = source->release_context;
  return &buffer;
}

}  // namespace

struct DenialEngineHostRef {
  CApiRenderDelegate delegate;
  std::unordered_map<int64_t, std::shared_ptr<CApiEGLImageTextureState>>
      egl_image_textures;
  std::unordered_map<int64_t, std::shared_ptr<CApiPixelBufferTextureState>>
      pixel_buffer_textures;
  // Destroy the view first so Flutter's worker threads stop before callback
  // state and the render delegate disappear.
  std::unique_ptr<flutter::DenialFlutterView> view;

  flutter::DenialFlutterEngine* engine() const {
    return view ? view->GetEngine() : nullptr;
  }

  bool running() const {
    const auto* flutter_engine = engine();
    return flutter_engine && flutter_engine->running();
  }

  void ResetEngine() {
    view.reset();
    egl_image_textures.clear();
    pixel_buffer_textures.clear();
  }
};

extern "C" {

DenialEngineHostRef* denial_engine_host_create(void) {
  return new DenialEngineHostRef();
}

void denial_engine_host_destroy(DenialEngineHostRef* host) {
  delete host;
}

bool denial_engine_host_start(DenialEngineHostRef* host,
                              const char* assets_path,
                              const char* icu_data_path,
                              const char* aot_library_path,
                              const DenialRenderCallbacks* callbacks,
                              const DenialSchedulerCallbacks* scheduler) {
  if (!host || !callbacks || !scheduler ||
      !scheduler->runs_task_on_current_thread || !scheduler->post_task ||
      !scheduler->request_vsync) {
    return false;
  }

  host->ResetEngine();
  host->delegate.SetCallbacks(*callbacks);

  const auto scheduler_callbacks = *scheduler;
  flutter::DenialPlatformTaskRunner task_runner;
  task_runner.runs_task_on_current_thread = [scheduler_callbacks] {
    return scheduler_callbacks.runs_task_on_current_thread(
        scheduler_callbacks.user_data);
  };
  task_runner.post_task = [scheduler_callbacks](FlutterTask task,
                                                uint64_t target_time_nanos) {
    DenialTask native_task = {};
    native_task.runner = task.runner;
    native_task.task = task.task;
    scheduler_callbacks.post_task(scheduler_callbacks.user_data, native_task,
                                  target_time_nanos);
  };
  task_runner.identifier =
      reinterpret_cast<size_t>(scheduler_callbacks.user_data);

  host->view = std::make_unique<flutter::DenialFlutterView>(&host->delegate);
  auto engine = std::make_unique<flutter::DenialFlutterEngine>(
      assets_path ? assets_path : "", icu_data_path ? icu_data_path : "",
      aot_library_path ? aot_library_path : "");
  engine->SetPlatformTaskRunner(std::move(task_runner));
  engine->SetVsyncRequestCallback([scheduler_callbacks](intptr_t baton) {
    scheduler_callbacks.request_vsync(scheduler_callbacks.user_data, baton);
  });
  host->view->SetEngine(std::move(engine));

  if (!host->view->CreateRenderSurface() || !host->engine()->Run()) {
    host->ResetEngine();
    return false;
  }

  host->view->SendInitialBounds();
  return true;
}

void denial_engine_host_stop(DenialEngineHostRef* host) {
  if (host) {
    host->ResetEngine();
  }
}

bool denial_engine_host_running(DenialEngineHostRef* host) {
  return host && host->running();
}

uint64_t denial_engine_host_current_time_nanos(DenialEngineHostRef* host) {
  if (!host || !host->engine()) {
    return 0;
  }
  return host->engine()->GetCurrentTimeNanos();
}

bool denial_engine_host_run_task(DenialEngineHostRef* host,
                                 const DenialTask* task) {
  if (!host || !host->engine() || !task) {
    return false;
  }

  FlutterTask flutter_task = {};
  flutter_task.runner = static_cast<FlutterTaskRunner>(task->runner);
  flutter_task.task = task->task;
  return host->engine()->RunPlatformTask(flutter_task);
}

bool denial_engine_host_on_vsync(DenialEngineHostRef* host,
                                 intptr_t baton,
                                 uint64_t frame_start_time_nanos,
                                 uint64_t frame_target_time_nanos) {
  return host && host->engine() &&
         host->engine()->OnVsyncAt(baton, frame_start_time_nanos,
                                   frame_target_time_nanos);
}

bool denial_engine_host_post_raster_task(DenialEngineHostRef* host,
                                         DenialRasterTaskCallback callback,
                                         void* user_data) {
  if (!host || !host->engine() || !callback) {
    return false;
  }

  return host->engine()->PostRasterThreadTask(callback, user_data);
}

int64_t denial_engine_host_register_egl_image_texture(
    DenialEngineHostRef* host,
    DenialEGLImageTextureCallback callback,
    void* user_data) {
  if (!host || !host->engine() || !callback) {
    return -1;
  }

  auto* registrar = host->engine()->texture_registrar();
  if (!registrar) {
    return -1;
  }

  auto state = std::make_shared<CApiEGLImageTextureState>();
  state->callback = callback;
  state->user_data = user_data;

  const int64_t texture_id =
      registrar->RegisterEGLImageTexture(OnEGLImageTexture, state.get());
  if (texture_id < 0) {
    return -1;
  }

  host->egl_image_textures.emplace(texture_id, std::move(state));
  return texture_id;
}

int64_t denial_engine_host_register_pixel_buffer_texture(
    DenialEngineHostRef* host,
    DenialPixelBufferTextureCallback callback,
    void* user_data) {
  if (!host || !host->engine() || !callback) {
    return -1;
  }

  auto* registrar = host->engine()->texture_registrar();
  if (!registrar) {
    return -1;
  }

  auto state = std::make_shared<CApiPixelBufferTextureState>();
  state->callback = callback;
  state->user_data = user_data;

  const int64_t texture_id =
      registrar->RegisterPixelBufferTexture(OnPixelBufferTexture, state.get());
  if (texture_id < 0) {
    return -1;
  }

  host->pixel_buffer_textures.emplace(texture_id, std::move(state));
  return texture_id;
}

bool denial_engine_host_mark_external_texture_frame_available(
    DenialEngineHostRef* host,
    int64_t texture_id) {
  if (!host || !host->engine()) {
    return false;
  }

  auto* registrar = host->engine()->texture_registrar();
  return registrar && registrar->MarkTextureFrameAvailable(texture_id);
}

bool denial_engine_host_retire_external_texture_image(DenialEngineHostRef* host,
                                                      int64_t texture_id,
                                                      uint64_t stable_id) {
  if (!host || !host->engine() || stable_id == 0) {
    return false;
  }

  const auto state = host->egl_image_textures.find(texture_id);
  if (state == host->egl_image_textures.end() || !state->second ||
      state->second->retired.load(std::memory_order_acquire)) {
    return false;
  }

  auto* registrar = host->engine()->texture_registrar();
  return registrar && registrar->RetireTextureFrame(texture_id, stable_id);
}

void denial_engine_host_unregister_external_texture(DenialEngineHostRef* host,
                                                    int64_t texture_id) {
  if (!host) {
    return;
  }

  std::shared_ptr<CApiEGLImageTextureState> retired_egl_state;
  if (auto state = host->egl_image_textures.find(texture_id);
      state != host->egl_image_textures.end() && state->second) {
    retired_egl_state = std::move(state->second);
    host->egl_image_textures.erase(state);
    retired_egl_state->retired.store(true, std::memory_order_release);
  }

  std::shared_ptr<CApiPixelBufferTextureState> retired_pixel_state;
  if (auto state = host->pixel_buffer_textures.find(texture_id);
      state != host->pixel_buffer_textures.end() && state->second) {
    retired_pixel_state = std::move(state->second);
    host->pixel_buffer_textures.erase(state);
    retired_pixel_state->retired.store(true, std::memory_order_release);
  }

  if (!retired_egl_state && !retired_pixel_state) {
    return;
  }

  if (host->engine() && host->engine()->texture_registrar()) {
    // The raster-thread completion keeps the callback state alive until the
    // engine can no longer resolve this texture. Removing it from the host map
    // immediately prevents one leaked state object per destroyed surface.
    host->engine()->texture_registrar()->UnregisterTexture(
        texture_id, [retired_egl_state = std::move(retired_egl_state),
                     retired_pixel_state = std::move(retired_pixel_state)] {});
  }
}

bool denial_engine_host_send_platform_message(DenialEngineHostRef* host,
                                              const char* channel,
                                              const uint8_t* message,
                                              size_t message_size) {
  if (!host || !host->engine() || !channel) {
    return false;
  }

  return host->engine()->SendPlatformMessage(channel, message, message_size);
}

bool denial_engine_host_set_platform_message_handler(
    DenialEngineHostRef* host,
    const char* channel,
    DenialPlatformMessageCallback callback,
    void* user_data) {
  if (!host || !host->engine()) {
    return false;
  }

  return flutter::SetDenialNativeMessageHandler(host->engine(), channel,
                                                callback, user_data);
}

bool denial_engine_host_touch_down(DenialEngineHostRef* host,
                                   uint32_t time_ms,
                                   int32_t id,
                                   double x_px,
                                   double y_px) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnTouchDown(time_ms, id, x_px, y_px);
  return true;
}

bool denial_engine_host_touch_motion(DenialEngineHostRef* host,
                                     uint32_t time_ms,
                                     int32_t id,
                                     double x_px,
                                     double y_px) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnTouchMotion(time_ms, id, x_px, y_px);
  return true;
}

bool denial_engine_host_touch_up(DenialEngineHostRef* host,
                                 uint32_t time_ms,
                                 int32_t id) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnTouchUp(time_ms, id);
  return true;
}

bool denial_engine_host_touch_cancel(DenialEngineHostRef* host) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnTouchCancel();
  return true;
}

bool denial_engine_host_pointer_move(DenialEngineHostRef* host,
                                     double x_px,
                                     double y_px) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnPointerMove(x_px, y_px);
  return true;
}

bool denial_engine_host_pointer_down(DenialEngineHostRef* host,
                                     double x_px,
                                     double y_px,
                                     uint64_t button) {
  if (!host || !host->running() || button == 0) {
    return false;
  }

  host->view->OnPointerDown(x_px, y_px,
                            static_cast<FlutterPointerMouseButtons>(button));
  return true;
}

bool denial_engine_host_pointer_up(DenialEngineHostRef* host,
                                   double x_px,
                                   double y_px,
                                   uint64_t button) {
  if (!host || !host->running() || button == 0) {
    return false;
  }

  host->view->OnPointerUp(x_px, y_px,
                          static_cast<FlutterPointerMouseButtons>(button));
  return true;
}

bool denial_engine_host_pointer_leave(DenialEngineHostRef* host) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnPointerLeave();
  return true;
}

bool denial_engine_host_pointer_scroll(DenialEngineHostRef* host,
                                       double x_px,
                                       double y_px,
                                       double delta_x,
                                       double delta_y) {
  if (!host || !host->running()) {
    return false;
  }

  constexpr int32_t kScrollOffsetMultiplier = 20;
  host->view->OnScroll(x_px, y_px, delta_x, delta_y, kScrollOffsetMultiplier);
  return true;
}

bool denial_engine_host_keymap(DenialEngineHostRef* host,
                               const char* keymap,
                               size_t keymap_size) {
  if (!host || !host->running() || !keymap || keymap_size == 0) {
    return false;
  }

  return host->view->OnKeyMap(keymap, keymap_size);
}

bool denial_engine_host_key_modifiers(DenialEngineHostRef* host,
                                      uint32_t depressed,
                                      uint32_t latched,
                                      uint32_t locked,
                                      uint32_t group) {
  if (!host || !host->running()) {
    return false;
  }

  host->view->OnKeyModifiers(depressed, latched, locked, group);
  return true;
}

bool denial_engine_host_key_event(DenialEngineHostRef* host,
                                  uint32_t keycode,
                                  bool pressed) {
  if (!host || !host->running()) {
    return false;
  }

  // Repeated key-down events intentionally use the same view path. Flutter's
  // keyboard state converts them to repeat events, while TextInputPlugin
  // applies the corresponding repeated edit.
  host->view->OnKey(keycode, pressed);
  return true;
}

}  // extern "C"
