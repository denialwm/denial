#ifndef DENIAL_NATIVE_APP_PLUGIN_V1_H
#define DENIAL_NATIVE_APP_PLUGIN_V1_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DENIAL_NATIVE_APP_ABI_MAJOR 1u
#define DENIAL_NATIVE_APP_ABI_MINOR 2u
#define DENIAL_NATIVE_APP_MAX_PLANES 4u

enum denial_native_app_create_flag_v1 {
  /* Allocate/configure targets, but never publish this surface to the shell. */
  DENIAL_NATIVE_APP_CREATE_HEADLESS_V1 = 1u << 31,
};

enum denial_native_app_event_kind_v1 {
  DENIAL_NATIVE_APP_CREATE_WINDOW_V1 = 1,
  DENIAL_NATIVE_APP_BIND_WINDOW_IDENTITY_V1 = 2,
  DENIAL_NATIVE_APP_DESTROY_WINDOW_V1 = 3,
  DENIAL_NATIVE_APP_PRESENT_V1 = 6,
  DENIAL_NATIVE_APP_SET_CONTENT_STATE_V1 = 7,
  DENIAL_NATIVE_APP_SET_FRAME_RATE_V1 = 8,
};

enum denial_native_app_command_kind_v1 {
  DENIAL_NATIVE_APP_CONFIGURE_V1 = 1,
  DENIAL_NATIVE_APP_VISIBILITY_V1 = 2,
  DENIAL_NATIVE_APP_CLOSE_V1 = 3,
  DENIAL_NATIVE_APP_INPUT_V1 = 4,
  DENIAL_NATIVE_APP_MATERIALIZE_RELEASE_V1 = 5,
  DENIAL_NATIVE_APP_COMPLETE_RELEASE_V1 = 6,
  DENIAL_NATIVE_APP_DISCARD_RELEASE_V1 = 7,
  DENIAL_NATIVE_APP_PRESENTED_V1 = 8,
  DENIAL_NATIVE_APP_FORMAT_FEEDBACK_V1 = 9,
  DENIAL_NATIVE_APP_REGISTER_RENDER_TARGET_V1 = 10,
  DENIAL_NATIVE_APP_UNREGISTER_RENDER_TARGET_V1 = 11,
};

enum denial_native_app_input_kind_v1 {
  DENIAL_NATIVE_APP_INPUT_TOUCH_V1 = 1,
  DENIAL_NATIVE_APP_INPUT_KEY_V1 = 2,
  DENIAL_NATIVE_APP_INPUT_NAVIGATION_V1 = 3,
};

enum denial_native_app_touch_action_v1 {
  DENIAL_NATIVE_APP_TOUCH_DOWN_V1 = 0,
  DENIAL_NATIVE_APP_TOUCH_MOTION_V1 = 1,
  DENIAL_NATIVE_APP_TOUCH_UP_V1 = 2,
  DENIAL_NATIVE_APP_TOUCH_CANCEL_V1 = 3,
};

enum denial_native_app_key_action_v1 {
  DENIAL_NATIVE_APP_KEY_DOWN_V1 = 0,
  DENIAL_NATIVE_APP_KEY_UP_V1 = 1,
};

enum denial_native_app_navigation_action_v1 {
  DENIAL_NATIVE_APP_NAVIGATION_BACK_V1 = 0,
  DENIAL_NATIVE_APP_NAVIGATION_HOME_V1 = 1,
  DENIAL_NATIVE_APP_NAVIGATION_OVERVIEW_V1 = 2,
};

struct denial_native_app_host_v1 {
  uint32_t struct_size;
  uint32_t abi_major;
  uint32_t abi_minor;
  int32_t drm_fd;
};

struct denial_native_app_damage_v1 {
  uint32_t x;
  uint32_t y;
  uint32_t width;
  uint32_t height;
};

struct denial_native_app_format_v1 {
  uint32_t format;
  uint64_t modifier;
};

struct denial_native_app_event_v1 {
  uint32_t struct_size;
  uint32_t kind;
  uint64_t object_id;
  uint64_t identity;
  uint64_t buffer_id;
  uint64_t frame_id;
  uint64_t serial;
  uint32_t flags;
  uint32_t width;
  uint32_t height;
  uint32_t format;
  uint32_t plane_count;
  uint64_t modifier;
  int32_t plane_fds[DENIAL_NATIVE_APP_MAX_PLANES];
  uint32_t plane_offsets[DENIAL_NATIVE_APP_MAX_PLANES];
  uint32_t plane_strides[DENIAL_NATIVE_APP_MAX_PLANES];
  int32_t acquire_fence_fd;
  const uint8_t *text_ptr;
  size_t text_len;
  const uint8_t *app_id_ptr;
  size_t app_id_len;
  const struct denial_native_app_damage_v1 *damage_ptr;
  size_t damage_count;
};

struct denial_native_app_command_v1 {
  uint32_t struct_size;
  uint32_t kind;
  uint64_t object_id;
  uint64_t frame_id;
  uint64_t serial;
  uint64_t timestamp_nanos;
  uint64_t refresh_period_nanos;
  uint64_t sequence;
  uint32_t flags;
  uint32_t width;
  uint32_t height;
  uint32_t scale_numerator;
  uint32_t scale_denominator;
  uint32_t transform;
  uint32_t refresh_millihz;
  uint32_t focused;
  int32_t descriptor;
  uint32_t input_kind;
  uint32_t input_action;
  uint32_t input_code;
  int32_t input_x_fixed;
  int32_t input_y_fixed;
  uint32_t input_value;
  const struct denial_native_app_format_v1 *formats_ptr;
  size_t format_count;
  uint64_t buffer_id;
  uint32_t format;
  uint32_t plane_count;
  uint64_t modifier;
  int32_t plane_fds[DENIAL_NATIVE_APP_MAX_PLANES];
  uint32_t plane_offsets[DENIAL_NATIVE_APP_MAX_PLANES];
  uint32_t plane_strides[DENIAL_NATIVE_APP_MAX_PLANES];
};

typedef int32_t (*denial_native_app_next_event_v1_fn)(
    void *context, struct denial_native_app_event_v1 *event);
typedef int32_t (*denial_native_app_command_v1_fn)(
    void *context, const struct denial_native_app_command_v1 *command);
typedef void (*denial_native_app_shutdown_v1_fn)(void *context);

struct denial_native_app_plugin_v1 {
  uint32_t struct_size;
  uint32_t abi_major;
  uint32_t abi_minor;
  const char *name_ptr;
  size_t name_len;
  void *context;
  int32_t poll_fd;
  denial_native_app_next_event_v1_fn next_event;
  denial_native_app_command_v1_fn command;
  denial_native_app_shutdown_v1_fn shutdown;
};

typedef int32_t (*denial_native_app_plugin_entry_v1_fn)(
    const struct denial_native_app_host_v1 *host,
    struct denial_native_app_plugin_v1 *plugin);

int32_t denial_native_app_plugin_v1(
    const struct denial_native_app_host_v1 *host,
    struct denial_native_app_plugin_v1 *plugin);

#ifdef __cplusplus
}
#endif

#endif
