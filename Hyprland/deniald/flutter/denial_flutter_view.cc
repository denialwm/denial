// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/denial_flutter_view.h"

#include <cmath>
#include <cstring>

namespace flutter {

namespace {
constexpr int kMicrosecondsPerMillisecond = 1000;
constexpr int kNanosecondsPerMicrosecond = 1000;
constexpr FlutterViewId kImplicitViewId = 0;
constexpr int64_t kWaylandTimeWrapMilliseconds = 1LL << 32;
constexpr int64_t kWaylandTimeHalfWrapMilliseconds = 1LL << 31;
constexpr int64_t kMaxReasonableTouchClockDeltaMilliseconds = 60000;
constexpr char kMouseCursorChannel[] = "flutter/mousecursor";
constexpr char kActivateSystemCursorMethod[] = "activateSystemCursor";

// Denial renders its own Flutter cursor. Decode only the method-name prefix of
// this StandardMethodCodec channel, then acknowledge the native cursor request.
void InstallMouseCursorHandler(DenialBinaryMessenger* messenger) {
  messenger->SetMessageHandler(kMouseCursorChannel, [](const uint8_t* message,
                                                       size_t size,
                                                       BinaryReply reply) {
    constexpr uint8_t kStandardCodecString = 7;
    constexpr size_t kMethodLength = sizeof(kActivateSystemCursorMethod) - 1;
    const bool is_activation =
        message && size >= kMethodLength + 2 &&
        message[0] == kStandardCodecString && message[1] == kMethodLength &&
        std::memcmp(message + 2, kActivateSystemCursorMethod, kMethodLength) ==
            0;

    if (!reply) {
      return;
    }
    if (!is_activation) {
      reply(nullptr, 0);
      return;
    }

    // StandardMethodCodec success flag followed by a null result.
    constexpr uint8_t kSuccess[] = {0, 0};
    reply(kSuccess, sizeof(kSuccess));
  });
}

int64_t WaylandTimeDeltaMilliseconds(uint32_t event_time_ms,
                                     uint32_t engine_time_ms) {
  int64_t delta = static_cast<int64_t>(event_time_ms) -
                  static_cast<int64_t>(engine_time_ms);
  if (delta > kWaylandTimeHalfWrapMilliseconds) {
    delta -= kWaylandTimeWrapMilliseconds;
  } else if (delta < -kWaylandTimeHalfWrapMilliseconds) {
    delta += kWaylandTimeWrapMilliseconds;
  }
  return delta;
}

inline FlutterTransformation FlutterTransformationIdentity() {
  FlutterTransformation transformation = {};
  transformation.scaleX = 1;
  transformation.skewX = 0;
  transformation.transX = 0;
  transformation.skewY = 0;
  transformation.scaleY = 1;
  transformation.transY = 0;
  transformation.pers0 = 0;
  transformation.pers1 = 0;
  transformation.pers2 = 1;
  return transformation;
}

inline FlutterTransformation FlutterTransformationMake(
    uint16_t transform,
    PhysicalWindowBounds bounds) {
  FlutterTransformation transformation = FlutterTransformationIdentity();

  switch (transform) {
    case 1:
      transformation.scaleX = 0;
      transformation.skewX = -1;
      transformation.skewY = 1;
      transformation.scaleY = 0;
      transformation.transX = bounds.height;
      break;
    case 2:
      transformation.scaleX = -1;
      transformation.scaleY = -1;
      transformation.transX = bounds.width;
      transformation.transY = bounds.height;
      break;
    case 3:
      transformation.scaleX = 0;
      transformation.skewX = 1;
      transformation.skewY = -1;
      transformation.scaleY = 0;
      transformation.transY = bounds.width;
      break;
    case 4:
      transformation.scaleX = -1;
      transformation.transX = bounds.width;
      break;
    case 5:
      transformation.scaleY = -1;
      transformation.transY = bounds.height;
      break;
    default:
      break;
  }

  return transformation;
}

}  // namespace

DenialFlutterView::DenialFlutterView(DenialRenderDelegate* render_delegate)
    : render_delegate_(render_delegate) {}

DenialFlutterView::~DenialFlutterView() {
  if (engine_) {
    engine_->Stop();
  }
}

void DenialFlutterView::SetEngine(std::unique_ptr<DenialFlutterEngine> engine) {
  engine_ = std::move(engine);

  engine_->SetView(this);

  DenialBinaryMessenger* internal_plugin_messenger = engine_.get();

  // Set up internal channels.
  // These channels are part of Denial's embedded platform implementation.
  key_event_handler_ =
      std::make_unique<KeyEventPlugin>(internal_plugin_messenger);
  text_input_handler_ =
      std::make_unique<TextInputPlugin>(internal_plugin_messenger);
  platform_handler_ =
      std::make_unique<PlatformPlugin>(internal_plugin_messenger);
  InstallMouseCursorHandler(internal_plugin_messenger);
}

void DenialFlutterView::OnPointerMove(double x_px, double y_px) {
  auto trimmed_xy = GetPointerRotation(x_px, y_px);
  SendPointerMove(trimmed_xy.first, trimmed_xy.second);
}

void DenialFlutterView::OnPointerDown(
    double x_px,
    double y_px,
    FlutterPointerMouseButtons flutter_button) {
  if (flutter_button != 0) {
    uint64_t mouse_buttons = mouse_state_.buttons | flutter_button;
    auto trimmed_xy = GetPointerRotation(x_px, y_px);
    mouse_state_.buttons = mouse_buttons;
    SendPointerDown(trimmed_xy.first, trimmed_xy.second);
  }
}

void DenialFlutterView::OnPointerUp(double x_px,
                                    double y_px,
                                    FlutterPointerMouseButtons flutter_button) {
  if (flutter_button != 0) {
    auto trimmed_xy = GetPointerRotation(x_px, y_px);
    uint64_t mouse_buttons = mouse_state_.buttons & ~flutter_button;
    mouse_state_.buttons = mouse_buttons;
    SendPointerUp(trimmed_xy.first, trimmed_xy.second);
  }
}

void DenialFlutterView::OnPointerLeave() {
  SendPointerLeave();
}

void DenialFlutterView::OnTouchDown(uint32_t time,
                                    int32_t id,
                                    double x,
                                    double y) {
  // Increase device-id to avoid
  // "FML_DCHECK(states_.find(pointer_data.device) == states_.end());"
  // exception in flutter/engine.
  // This is because "device-id = 0" is used for mouse inputs.
  // See engine/lib/ui/window/pointer_data_packet_converter.cc
  id += 1;

  auto trimmed_xy = GetPointerRotation(x, y);
  auto* point = AcquireTouchPoint(id);
  if (!point) {
    return;
  }
  point->state = TouchState::kDown;
  point->x = trimmed_xy.first;
  point->y = trimmed_xy.second;
  const auto timestamp = NextTouchTimestampMicros(time);

  FlutterPointerEvent event = {
      .struct_size = sizeof(event),
      .phase = FlutterPointerPhase::kDown,
      .timestamp = timestamp,
      .x = point->x,
      .y = point->y,
      .device = id,
      .signal_kind = kFlutterPointerSignalKindNone,
      .scroll_delta_x = 0,
      .scroll_delta_y = 0,
      .device_kind = kFlutterPointerDeviceKindTouch,
      .buttons = 0,
      .view_id = kImplicitViewId,
  };
  engine_->SendPointerEvent(event);
}

void DenialFlutterView::OnTouchUp(uint32_t time, int32_t id) {
  // Increase device-id to avoid
  // "FML_DCHECK(states_.find(pointer_data.device) == states_.end());"
  // exception in flutter/engine.
  // This is because "device-id = 0" is used for mouse inputs.
  // See engine/lib/ui/window/pointer_data_packet_converter.cc
  id += 1;

  auto* point = FindTouchPoint(id);
  if (!point) {
    return;
  }

  // Makes sure we have an existing touch pointer in down state to
  // avoid "FML_DCHECK(iter != states_.end())" exception in flutter/engine.
  // See engine/lib/ui/window/pointer_data_packet_converter.cc
  if (point->state != TouchState::kDown &&
      point->state != TouchState::kMotion) {
    return;
  }
  const auto timestamp = NextTouchTimestampMicros(time);

  FlutterPointerEvent event = {
      .struct_size = sizeof(event),
      .phase = FlutterPointerPhase::kUp,
      .timestamp = timestamp,
      .x = point->x,
      .y = point->y,
      .device = id,
      .signal_kind = kFlutterPointerSignalKindNone,
      .scroll_delta_x = 0,
      .scroll_delta_y = 0,
      .device_kind = kFlutterPointerDeviceKindTouch,
      .buttons = 0,
      .view_id = kImplicitViewId,
  };
  engine_->SendPointerEvent(event);
  ReleaseTouchPoint(point);
}

void DenialFlutterView::OnTouchMotion(uint32_t time,
                                      int32_t id,
                                      double x,
                                      double y) {
  // Increase device-id to avoid
  // "FML_DCHECK(states_.find(pointer_data.device) == states_.end());"
  // exception in flutter/engine.
  // This is because "device-id = 0" is used for mouse inputs.
  // See engine/lib/ui/window/pointer_data_packet_converter.cc
  id += 1;

  auto trimmed_xy = GetPointerRotation(x, y);
  auto* point = FindTouchPoint(id);
  if (!point) {
    return;
  }

  // Makes sure we have an existing touch pointer in down state to
  // avoid "FML_DCHECK(iter != states_.end())" exception in flutter/engine.
  // See engine/lib/ui/window/pointer_data_packet_converter.cc
  if (point->state != TouchState::kDown &&
      point->state != TouchState::kMotion) {
    return;
  }
  point->state = TouchState::kMotion;
  point->x = trimmed_xy.first;
  point->y = trimmed_xy.second;
  const auto timestamp = NextTouchTimestampMicros(time);

  FlutterPointerEvent event = {
      .struct_size = sizeof(event),
      .phase = FlutterPointerPhase::kMove,
      .timestamp = timestamp,
      .x = point->x,
      .y = point->y,
      .device = id,
      .signal_kind = kFlutterPointerSignalKindNone,
      .scroll_delta_x = 0,
      .scroll_delta_y = 0,
      .device_kind = kFlutterPointerDeviceKindTouch,
      .buttons = 0,
      .view_id = kImplicitViewId,
  };
  engine_->SendPointerEvent(event);
}

void DenialFlutterView::OnTouchCancel() {
  for (auto& point : touch_points_) {
    if (point.state != TouchState::kDown &&
        point.state != TouchState::kMotion) {
      continue;
    }

    FlutterPointerEvent event = {
        .struct_size = sizeof(event),
        .phase = FlutterPointerPhase::kCancel,
        .timestamp = NextSyntheticTouchTimestampMicros(),
        .x = point.x,
        .y = point.y,
        .device = point.id,
        .signal_kind = kFlutterPointerSignalKindNone,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .device_kind = kFlutterPointerDeviceKindTouch,
        .buttons = 0,
        .view_id = kImplicitViewId,
    };
    engine_->SendPointerEvent(event);
  }
  ResetTouchPoints();
}

bool DenialFlutterView::OnKeyMap(const char* keymap, size_t size) {
  return key_event_handler_->OnKeymap(keymap, size);
}

void DenialFlutterView::OnKey(uint32_t key, bool pressed) {
  key_event_handler_->OnKey(key, pressed);
  const auto code_point = key_event_handler_->GetCodePoint(key);
  if (pressed) {
    if (!key_event_handler_->IsTextInputSuppressed(code_point)) {
      text_input_handler_->OnKeyPressed(key, code_point);
    }
  }
}

void DenialFlutterView::OnKeyModifiers(uint32_t mods_depressed,
                                       uint32_t mods_latched,
                                       uint32_t mods_locked,
                                       uint32_t group) {
  key_event_handler_->OnModifiers(mods_depressed, mods_latched, mods_locked,
                                  group);
}

void DenialFlutterView::OnScroll(double x,
                                 double y,
                                 double delta_x,
                                 double delta_y,
                                 int scroll_offset_multiplier) {
  auto trimmed_xy = GetPointerRotation(x, y);
  SendScroll(trimmed_xy.first, trimmed_xy.second, delta_x, delta_y,
             scroll_offset_multiplier);
}

DenialFlutterView::TouchPoint* DenialFlutterView::FindTouchPoint(int32_t id) {
  for (auto& point : touch_points_) {
    if (point.state != TouchState::kInactive && point.id == id) {
      return &point;
    }
  }
  return nullptr;
}

DenialFlutterView::TouchPoint* DenialFlutterView::AcquireTouchPoint(
    int32_t id) {
  if (auto* point = FindTouchPoint(id)) {
    return point;
  }
  for (auto& point : touch_points_) {
    if (point.state == TouchState::kInactive) {
      point.id = id;
      return &point;
    }
  }
  return nullptr;
}

void DenialFlutterView::ReleaseTouchPoint(TouchPoint* point) {
  if (!point) {
    return;
  }

  *point = TouchPoint{};
}

void DenialFlutterView::ResetTouchPoints() {
  for (auto& point : touch_points_) {
    ReleaseTouchPoint(&point);
  }
}

size_t DenialFlutterView::CurrentEngineTimeMicros() const {
  if (!engine_) {
    return 0;
  }
  return static_cast<size_t>(engine_->GetCurrentTimeNanos() /
                             kNanosecondsPerMicrosecond);
}

size_t DenialFlutterView::NextMouseTimestampMicros() {
  size_t timestamp = CurrentEngineTimeMicros();
  if (timestamp <= last_mouse_timestamp_micros_) {
    timestamp = last_mouse_timestamp_micros_ + 1;
  }
  last_mouse_timestamp_micros_ = timestamp;
  return timestamp;
}

size_t DenialFlutterView::NextTouchTimestampMicros(uint32_t time_ms) {
  size_t timestamp = static_cast<size_t>(time_ms) * kMicrosecondsPerMillisecond;

  const size_t engine_now_micros = CurrentEngineTimeMicros();
  if (engine_now_micros != 0) {
    timestamp = engine_now_micros;
    const uint32_t engine_now_millis =
        static_cast<uint32_t>(engine_now_micros / kMicrosecondsPerMillisecond);
    const int64_t delta_millis =
        WaylandTimeDeltaMilliseconds(time_ms, engine_now_millis);

    if (delta_millis >= -kMaxReasonableTouchClockDeltaMilliseconds &&
        delta_millis <= kMaxReasonableTouchClockDeltaMilliseconds) {
      const int64_t candidate_micros =
          static_cast<int64_t>(engine_now_micros) +
          (delta_millis * kMicrosecondsPerMillisecond);
      if (candidate_micros > 0 &&
          static_cast<size_t>(candidate_micros) <= engine_now_micros) {
        timestamp = static_cast<size_t>(candidate_micros);
      }
    }
  }

  if (timestamp <= last_touch_timestamp_micros_) {
    timestamp = last_touch_timestamp_micros_ + 1;
  }
  last_touch_timestamp_micros_ = timestamp;
  return timestamp;
}

size_t DenialFlutterView::NextSyntheticTouchTimestampMicros() {
  size_t timestamp = CurrentEngineTimeMicros();
  if (timestamp <= last_touch_timestamp_micros_) {
    timestamp = last_touch_timestamp_micros_ + 1;
  }
  last_touch_timestamp_micros_ = timestamp;
  return last_touch_timestamp_micros_;
}

// Sends new size information to FlutterEngine.
void DenialFlutterView::SendWindowMetrics(size_t width_px,
                                          size_t height_px,
                                          double pixel_ratio) const {
  FlutterWindowMetricsEvent event = {};
  event.struct_size = sizeof(event);
  event.width = width_px;
  event.height = height_px;
  event.pixel_ratio = pixel_ratio;
  engine_->SendWindowMetricsEvent(event);
}

void DenialFlutterView::SendInitialBounds() {
  PhysicalWindowBounds bounds = render_delegate_->GetPhysicalWindowBounds();
  UpdateDisplayInfo(render_delegate_->GetFrameRate() / 1000.0, bounds.width,
                    bounds.height, render_delegate_->GetDpiScale());
  SendWindowMetrics(bounds.width, bounds.height,
                    render_delegate_->GetDpiScale());
}

// Sets |event_data|'s phase to either kMove or kHover depending on the current
// primary mouse button state.
void DenialFlutterView::SetEventPhaseFromCursorButtonState(
    FlutterPointerEvent* event_data) const {
  // For details about this logic, see FlutterPointerPhase in the embedder.h
  // file.
  if (mouse_state_.buttons == 0) {
    event_data->phase = mouse_state_.flutter_state_is_down
                            ? FlutterPointerPhase::kUp
                            : FlutterPointerPhase::kHover;
  } else {
    event_data->phase = mouse_state_.flutter_state_is_down
                            ? FlutterPointerPhase::kMove
                            : FlutterPointerPhase::kDown;
  }
}

void DenialFlutterView::SendPointerMove(double x_px, double y_px) {
  FlutterPointerEvent event = {};
  event.x = x_px;
  event.y = y_px;
  SetEventPhaseFromCursorButtonState(&event);
  SendPointerEventWithData(event);
}

void DenialFlutterView::SendPointerDown(double x_px, double y_px) {
  FlutterPointerEvent event = {};
  SetEventPhaseFromCursorButtonState(&event);
  event.x = x_px;
  event.y = y_px;
  SendPointerEventWithData(event);
  mouse_state_.flutter_state_is_down = true;
}

void DenialFlutterView::SendPointerUp(double x_px, double y_px) {
  FlutterPointerEvent event = {};
  SetEventPhaseFromCursorButtonState(&event);
  event.x = x_px;
  event.y = y_px;
  SendPointerEventWithData(event);
  if (event.phase == FlutterPointerPhase::kUp) {
    mouse_state_.flutter_state_is_down = false;
  }
}

void DenialFlutterView::SendPointerLeave() {
  if (!mouse_state_.flutter_state_is_added) {
    return;
  }

  FlutterPointerEvent event = {};
  event.phase = FlutterPointerPhase::kRemove;
  event.x = mouse_state_.last_x;
  event.y = mouse_state_.last_y;
  SendPointerEventWithData(event);
}

void DenialFlutterView::SendScroll(double x,
                                   double y,
                                   double delta_x,
                                   double delta_y,
                                   int scroll_offset_multiplier) {
  FlutterPointerEvent event = {};
  SetEventPhaseFromCursorButtonState(&event);
  event.signal_kind = FlutterPointerSignalKind::kFlutterPointerSignalKindScroll;
  event.x = x;
  event.y = y;
  event.scroll_delta_x = delta_x * scroll_offset_multiplier;
  event.scroll_delta_y = delta_y * scroll_offset_multiplier;
  SendPointerEventWithData(event);
}

void DenialFlutterView::SendPointerEventWithData(
    const FlutterPointerEvent& event_data) {
  if (event_data.phase != FlutterPointerPhase::kRemove) {
    mouse_state_.last_x = event_data.x;
    mouse_state_.last_y = event_data.y;
  }

  // If sending anything other than an add, and the pointer isn't already added,
  // synthesize an add to satisfy Flutter's expectations about events.
  if (!mouse_state_.flutter_state_is_added &&
      event_data.phase != FlutterPointerPhase::kAdd) {
    FlutterPointerEvent event = {};
    event.phase = FlutterPointerPhase::kAdd;
    event.x = event_data.x;
    event.y = event_data.y;
    event.buttons = 0;
    SendPointerEventWithData(event);
  }
  // Don't double-add (e.g., if events are delivered out of order, so an add has
  // already been synthesized).
  if (mouse_state_.flutter_state_is_added &&
      event_data.phase == FlutterPointerPhase::kAdd) {
    return;
  }

  FlutterPointerEvent event = event_data;
  event.device_kind = kFlutterPointerDeviceKindMouse;
  event.buttons = mouse_state_.buttons;
  event.view_id = kImplicitViewId;

  // Set metadata that's always the same regardless of the event.
  event.struct_size = sizeof(event);
  // FlutterPointerEvent requires FlutterEngineGetCurrentTime's clock domain.
  // Wall-clock timestamps break gesture duration and velocity calculations.
  event.timestamp = NextMouseTimestampMicros();

  engine_->SendPointerEvent(event);

  if (event_data.phase == FlutterPointerPhase::kAdd) {
    mouse_state_.flutter_state_is_added = true;
  } else if (event_data.phase == FlutterPointerPhase::kRemove) {
    mouse_state_.flutter_state_is_added = false;
    ResetMouseState();
  }
}

void* DenialFlutterView::ProcResolver(const char* name) const {
  return render_delegate_->GlProcResolver(name);
}

bool DenialFlutterView::MakeCurrent() const {
  return render_delegate_->GLContextMakeCurrent();
}

bool DenialFlutterView::ClearCurrent() const {
  return render_delegate_->GLContextClearCurrent();
}

bool DenialFlutterView::PresentWithInfo(const FlutterPresentInfo* info) const {
  return render_delegate_->GLContextPresentWithInfo(info);
}

void DenialFlutterView::PopulateExistingDamage(
    const intptr_t fbo_id,
    FlutterDamage* existing_damage) const {
  render_delegate_->PopulateExistingDamage(fbo_id, existing_damage);
}

uint32_t DenialFlutterView::GetOnscreenFBO() const {
  return render_delegate_->GLContextFBO();
}

bool DenialFlutterView::MakeResourceCurrent() const {
  return render_delegate_->ResourceContextMakeCurrent();
}

bool DenialFlutterView::CreateRenderSurface() {
  PhysicalWindowBounds bounds = render_delegate_->GetPhysicalWindowBounds();
  return render_delegate_->OnScreenSurfaceResize(bounds.width, bounds.height);
}

DenialFlutterEngine* DenialFlutterView::GetEngine() const {
  return engine_.get();
}

FlutterTransformation DenialFlutterView::GetRootSurfaceTransformation() const {
  auto transform = render_delegate_->GetSurfaceTransform();
  auto bounds = render_delegate_->GetPhysicalWindowBounds();
  return FlutterTransformationMake(transform, bounds);
}

std::pair<double, double> DenialFlutterView::GetPointerRotation(
    double x_px,
    double y_px) const {
  auto transform = render_delegate_->GetSurfaceTransform();
  auto bounds = render_delegate_->GetPhysicalWindowBounds();
  std::pair<double, double> res = {x_px, y_px};

  if (transform == 1) {
    res.first = y_px;
    res.second = bounds.height - x_px;
  } else if (transform == 2) {
    res.first = bounds.width - x_px;
    res.second = bounds.height - y_px;
  } else if (transform == 3) {
    res.first = bounds.width - y_px;
    res.second = x_px;
  } else if (transform == 4) {
    res.first = bounds.width - x_px;
  } else if (transform == 5) {
    res.second = bounds.height - y_px;
  }
  return res;
}

void DenialFlutterView::UpdateDisplayInfo(double refresh_rate,
                                          size_t width_px,
                                          size_t height_px,
                                          double pixel_ratio) {
  const FlutterEngineDisplaysUpdateType update_type =
      kFlutterEngineDisplaysUpdateTypeStartup;
  const FlutterEngineDisplay displays = {
      .struct_size = sizeof(FlutterEngineDisplay),
      .display_id = 0,
      .single_display = true,
      .refresh_rate = refresh_rate,
      .width = width_px,
      .height = height_px,
      .device_pixel_ratio = pixel_ratio,
  };
  const size_t display_count = 1;
  engine_->UpdateDisplayInfo(update_type, &displays, display_count);
}

}  // namespace flutter
