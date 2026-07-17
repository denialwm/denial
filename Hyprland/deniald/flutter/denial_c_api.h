// Copyright 2026.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_DENIAL_C_API_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_DENIAL_C_API_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DenialEngineHostRef DenialEngineHostRef;

typedef struct {
  double left;
  double top;
  double right;
  double bottom;
} DenialRect;

typedef struct {
  size_t num_rects;
  const DenialRect* rects;
} DenialDamage;

typedef struct {
  uint32_t fbo_id;
  DenialDamage frame_damage;
  DenialDamage buffer_damage;
} DenialPresentInfo;

typedef struct {
  void* user_data;

  bool (*make_current)(void* user_data);
  bool (*clear_current)(void* user_data);
  bool (*present_with_info)(void* user_data, const DenialPresentInfo* info);
  size_t (*populate_existing_damage)(void* user_data,
                                     intptr_t fbo_id,
                                     DenialRect* rects,
                                     size_t max_rects);
  uint32_t (*fbo)(void* user_data);
  bool (*resource_make_current)(void* user_data);
  void* (*gl_proc_resolver)(void* user_data, const char* name);

  bool (*resize)(void* user_data, size_t width_px, size_t height_px);
  void (*bounds)(void* user_data, size_t* width_px, size_t* height_px);
  double (*dpi_scale)(void* user_data);
  int32_t (*frame_rate)(void* user_data);
  uint16_t (*surface_transform)(void* user_data);
} DenialRenderCallbacks;

typedef struct {
  void* runner;
  uint64_t task;
} DenialTask;

typedef struct {
  void* user_data;
  bool (*runs_task_on_current_thread)(void* user_data);
  void (*post_task)(void* user_data,
                    DenialTask task,
                    uint64_t target_time_nanos);
  void (*request_vsync)(void* user_data, intptr_t baton);
} DenialSchedulerCallbacks;

typedef struct {
  const void* egl_image;
  uint64_t stable_id;
  size_t width;
  size_t height;
  void (*release_callback)(void* release_context);
  void* release_context;
} DenialEGLImageDescriptor;

typedef const DenialEGLImageDescriptor* (*DenialEGLImageTextureCallback)(
    size_t width,
    size_t height,
    void* egl_display,
    void* egl_context,
    void* user_data);

typedef struct {
  const uint8_t* buffer;
  size_t width;
  size_t height;
  void (*release_callback)(void* release_context);
  void* release_context;
} DenialPixelBufferDescriptor;

typedef const DenialPixelBufferDescriptor* (*DenialPixelBufferTextureCallback)(
    size_t width,
    size_t height,
    void* user_data);

typedef void (*DenialPlatformMessageCallback)(const char* channel,
                                              const uint8_t* message,
                                              size_t message_size,
                                              void* user_data);

typedef void (*DenialRasterTaskCallback)(void* user_data);

DenialEngineHostRef* denial_engine_host_create(void);
void denial_engine_host_destroy(DenialEngineHostRef* host);

bool denial_engine_host_start(DenialEngineHostRef* host,
                              const char* assets_path,
                              const char* icu_data_path,
                              const char* aot_library_path,
                              const DenialRenderCallbacks* callbacks,
                              const DenialSchedulerCallbacks* scheduler);
void denial_engine_host_stop(DenialEngineHostRef* host);
bool denial_engine_host_running(DenialEngineHostRef* host);
uint64_t denial_engine_host_current_time_nanos(DenialEngineHostRef* host);
bool denial_engine_host_run_task(DenialEngineHostRef* host,
                                 const DenialTask* task);
bool denial_engine_host_on_vsync(DenialEngineHostRef* host,
                                 intptr_t baton,
                                 uint64_t frame_start_time_nanos,
                                 uint64_t frame_target_time_nanos);
bool denial_engine_host_post_raster_task(DenialEngineHostRef* host,
                                         DenialRasterTaskCallback callback,
                                         void* user_data);
int64_t denial_engine_host_register_egl_image_texture(
    DenialEngineHostRef* host,
    DenialEGLImageTextureCallback callback,
    void* user_data);
int64_t denial_engine_host_register_pixel_buffer_texture(
    DenialEngineHostRef* host,
    DenialPixelBufferTextureCallback callback,
    void* user_data);
bool denial_engine_host_mark_external_texture_frame_available(
    DenialEngineHostRef* host,
    int64_t texture_id);
bool denial_engine_host_retire_external_texture_image(DenialEngineHostRef* host,
                                                      int64_t texture_id,
                                                      uint64_t stable_id);
void denial_engine_host_unregister_external_texture(DenialEngineHostRef* host,
                                                    int64_t texture_id);
bool denial_engine_host_send_platform_message(DenialEngineHostRef* host,
                                              const char* channel,
                                              const uint8_t* message,
                                              size_t message_size);
bool denial_engine_host_set_platform_message_handler(
    DenialEngineHostRef* host,
    const char* channel,
    DenialPlatformMessageCallback callback,
    void* user_data);
bool denial_engine_host_touch_down(DenialEngineHostRef* host,
                                   uint32_t time_ms,
                                   int32_t id,
                                   double x_px,
                                   double y_px);
bool denial_engine_host_touch_motion(DenialEngineHostRef* host,
                                     uint32_t time_ms,
                                     int32_t id,
                                     double x_px,
                                     double y_px);
bool denial_engine_host_touch_up(DenialEngineHostRef* host,
                                 uint32_t time_ms,
                                 int32_t id);
bool denial_engine_host_touch_cancel(DenialEngineHostRef* host);
bool denial_engine_host_pointer_move(DenialEngineHostRef* host,
                                     double x_px,
                                     double y_px);
bool denial_engine_host_pointer_down(DenialEngineHostRef* host,
                                     double x_px,
                                     double y_px,
                                     uint64_t button);
bool denial_engine_host_pointer_up(DenialEngineHostRef* host,
                                   double x_px,
                                   double y_px,
                                   uint64_t button);
bool denial_engine_host_pointer_leave(DenialEngineHostRef* host);
bool denial_engine_host_pointer_scroll(DenialEngineHostRef* host,
                                       double x_px,
                                       double y_px,
                                       double delta_x,
                                       double delta_y);
bool denial_engine_host_keymap(DenialEngineHostRef* host,
                               const char* keymap,
                               size_t keymap_size);
bool denial_engine_host_key_modifiers(DenialEngineHostRef* host,
                                      uint32_t depressed,
                                      uint32_t latched,
                                      uint32_t locked,
                                      uint32_t group);
bool denial_engine_host_key_event(DenialEngineHostRef* host,
                                  uint32_t keycode,
                                  bool pressed);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_DENIAL_C_API_H_
