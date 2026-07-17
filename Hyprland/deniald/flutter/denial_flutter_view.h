// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_VIEW_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_VIEW_H_

#include <array>
#include <memory>
#include <string>
#include <vector>

#include "flutter/denial_flutter_engine.h"
#include "flutter/denial_render_delegate.h"
#include "flutter/embedder.h"
#include "flutter/key_event_plugin.h"
#include "flutter/platform_plugin.h"
#include "flutter/text_input_plugin.h"

namespace flutter {

class DenialFlutterView {
 public:
  explicit DenialFlutterView(DenialRenderDelegate* render_delegate);

  ~DenialFlutterView();

  // Configures the window instance with an instance of a running Flutter
  // engine.
  void SetEngine(std::unique_ptr<DenialFlutterEngine> engine);

  // Creates rendering surface for Flutter engine to draw into.
  // Should be called before calling FlutterEngineRun using this view.
  bool CreateRenderSurface();

  // Returns the FlutterTransformation of this view.
  FlutterTransformation GetRootSurfaceTransformation() const;

  // Returns the engine backing this view.
  DenialFlutterEngine* GetEngine() const;

  // Callbacks for clearing context, settings context and swapping buffers.
  void* ProcResolver(const char* name) const;
  bool MakeCurrent() const;
  bool ClearCurrent() const;
  bool PresentWithInfo(const FlutterPresentInfo* info) const;
  void PopulateExistingDamage(const intptr_t fbo_id,
                              FlutterDamage* existing_damage) const;
  uint32_t GetOnscreenFBO() const;
  bool MakeResourceCurrent() const;

  // Send initial bounds to embedder.  Must occur after engine has initialized.
  void SendInitialBounds();

  void OnPointerMove(double x_px, double y_px);

  void OnPointerDown(double x_px,
                     double y_px,
                     FlutterPointerMouseButtons button);

  void OnPointerUp(double x_px, double y_px, FlutterPointerMouseButtons button);

  void OnPointerLeave();

  void OnTouchDown(uint32_t time, int32_t id, double x, double y);

  void OnTouchUp(uint32_t time, int32_t id);

  void OnTouchMotion(uint32_t time, int32_t id, double x, double y);

  void OnTouchCancel();

  bool OnKeyMap(const char* keymap, size_t size);

  void OnKeyModifiers(uint32_t mods_depressed,
                      uint32_t mods_latched,
                      uint32_t mods_locked,
                      uint32_t group);

  void OnKey(uint32_t key, bool pressed);

  void OnScroll(double x,
                double y,
                double delta_x,
                double delta_y,
                int scroll_offset_multiplier);

 private:
  void UpdateDisplayInfo(double refresh_rate,
                         size_t width_px,
                         size_t height_px,
                         double pixel_ratio);
  // Struct holding the mouse state. The engine doesn't keep track of which
  // mouse buttons have been pressed, so it's the embedding's responsibility.
  struct MouseState {
    // True if the last event sent to Flutter had at least one mouse button.
    bool flutter_state_is_down = false;

    // True if kAdd has been sent to Flutter. Used to determine whether
    // to send a kAdd event before sending an incoming mouse event, since
    // Flutter expects pointers to be added before events are sent for them.
    bool flutter_state_is_added = false;

    // The currently pressed buttons, as represented in FlutterPointerEvent.
    uint64_t buttons = 0;

    // Last physical position sent to Flutter. Pointer removal must retain this
    // position rather than being interpreted as a transition through (0, 0).
    double last_x = 0.0;
    double last_y = 0.0;
  };

  enum class TouchState {
    kInactive,
    kDown,
    kMotion,
  };

  struct TouchPoint {
    int32_t id = -1;
    TouchState state = TouchState::kInactive;
    double x = 0;
    double y = 0;
  };

  TouchPoint* FindTouchPoint(int32_t id);
  TouchPoint* AcquireTouchPoint(int32_t id);
  void ReleaseTouchPoint(TouchPoint* point);
  void ResetTouchPoints();
  size_t CurrentEngineTimeMicros() const;
  size_t NextMouseTimestampMicros();
  size_t NextTouchTimestampMicros(uint32_t time_ms);
  size_t NextSyntheticTouchTimestampMicros();

  // Sends a window metrics update to the Flutter engine using current window
  // dimensions in physical pixels.
  // @param[in] width_px       Physical width of the window.
  // @param[in] height_px      Physical height of the window.
  void SendWindowMetrics(size_t width_px,
                         size_t height_px,
                         double dpiscale) const;

  // Reports a mouse movement to Flutter engine.
  // @param[in] x_px The x coordinate of the pointer event in physical pixels.
  // @param[in] y_px The y coordinate of the pointer event in physical pixels.
  void SendPointerMove(double x_px, double y_px);

  // Reports mouse press to Flutter engine.
  // @param[in] x_px The x coordinate of the pointer event in physical pixels.
  // @param[in] y_px The y coordinate of the pointer event in physical pixels.
  void SendPointerDown(double x_px, double y_px);

  // Reports mouse release to Flutter engine.
  // @param[in] x_px The x coordinate of the pointer event in physical pixels.
  // @param[in] y_px The y coordinate of the pointer event in physical pixels.
  void SendPointerUp(double x_px, double y_px);

  // Reports that the mouse left Denial's Flutter surface.
  void SendPointerLeave();

  // Reports scroll wheel events to Flutter engine.
  void SendScroll(double x,
                  double y,
                  double delta_x,
                  double delta_y,
                  int scroll_offset_multiplier);

  // Sets |event_data|'s phase to either kMove or kHover depending on the
  // current primary mouse button state.
  void SetEventPhaseFromCursorButtonState(
      FlutterPointerEvent* event_data) const;

  // Sends a pointer event to the Flutter engine based on given data.  Since
  // all input messages are passed in physical pixel values, no translation is
  // needed before passing on to engine.
  void SendPointerEventWithData(const FlutterPointerEvent& event_data);

  // Resets the mouse state to its default values.
  void ResetMouseState() { mouse_state_ = MouseState(); }

  // Transforms a physical input position into Flutter surface coordinates.
  // @param[in] x_px The x coordinate of the pointer event in physical pixels.
  // @param[in] y_px The y coordinate of the pointer event in physical pixels.
  std::pair<double, double> GetPointerRotation(double x_px, double y_px) const;

  // The engine associated with this view.
  std::unique_ptr<DenialFlutterEngine> engine_;

  // Keeps track of mouse state in relation to the window.
  MouseState mouse_state_;
  size_t last_mouse_timestamp_micros_ = 0;

  // Handler for keyboard events from window.
  std::unique_ptr<KeyEventPlugin> key_event_handler_;

  // Handler for text input events from window.
  std::unique_ptr<TextInputPlugin> text_input_handler_;

  // Handler for the flutter/platform channel.
  std::unique_ptr<PlatformPlugin> platform_handler_;

  // Owned by the engine host and valid for the view's lifetime.
  DenialRenderDelegate* render_delegate_ = nullptr;

  std::array<TouchPoint, 10> touch_points_;
  size_t last_touch_timestamp_micros_ = 0;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_VIEW_H_
