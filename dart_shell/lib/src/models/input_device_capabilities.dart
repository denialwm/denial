const double touchpadScrollSpeedFactorMinimum = 0.05;
const double touchpadScrollSpeedFactorMaximum = 5.0;
const double touchpadScrollSpeedFactorDefault = 1.0;
const double touchpadScrollingLayoutSwipeSpeedFactorMinimum = 0.25;
const double touchpadScrollingLayoutSwipeSpeedFactorMaximum = 4.0;
const double touchpadScrollingLayoutSwipeSpeedFactorDefault = 1.0;
const double mouseSpeedMinimum = -1.0;
const double mouseSpeedMaximum = 1.0;
const double mouseSpeedDefault = 0.0;

class DenialInputDeviceCapabilities {
  const DenialInputDeviceCapabilities({
    required this.revision,
    required this.hasMouse,
    required this.mouseSpeed,
    required this.hasTouchpad,
    required this.tapToClickEnabled,
    required this.naturalScrollEnabled,
    required this.scrollSpeedFactor,
    required this.scrollingLayoutSwipeSpeedFactor,
  });

  const DenialInputDeviceCapabilities.none()
    : revision = 0,
      hasMouse = false,
      mouseSpeed = mouseSpeedDefault,
      hasTouchpad = false,
      tapToClickEnabled = true,
      naturalScrollEnabled = false,
      scrollSpeedFactor = touchpadScrollSpeedFactorDefault,
      scrollingLayoutSwipeSpeedFactor =
          touchpadScrollingLayoutSwipeSpeedFactorDefault;

  final int revision;
  final bool hasMouse;
  final double mouseSpeed;
  final bool hasTouchpad;
  final bool tapToClickEnabled;
  final bool naturalScrollEnabled;
  final double scrollSpeedFactor;
  final double scrollingLayoutSwipeSpeedFactor;

  factory DenialInputDeviceCapabilities.fromJson(Map<String, Object?> json) {
    return DenialInputDeviceCapabilities(
      revision: json['revision'] as int? ?? 0,
      hasMouse: json['has_mouse'] as bool? ?? false,
      mouseSpeed:
          (json['mouse_speed'] as num?)?.toDouble() ?? mouseSpeedDefault,
      hasTouchpad: json['has_touchpad'] as bool? ?? false,
      tapToClickEnabled: json['tap_to_click_enabled'] as bool? ?? true,
      naturalScrollEnabled: json['natural_scroll_enabled'] as bool? ?? false,
      scrollSpeedFactor:
          (json['scroll_speed_factor'] as num?)?.toDouble() ??
          touchpadScrollSpeedFactorDefault,
      scrollingLayoutSwipeSpeedFactor:
          (json['scrolling_layout_swipe_speed_factor'] as num?)?.toDouble() ??
          touchpadScrollingLayoutSwipeSpeedFactorDefault,
    );
  }

  Map<String, Object> toApplyJson() => <String, Object>{
    'tapToClickEnabled': tapToClickEnabled,
    'naturalScrollEnabled': naturalScrollEnabled,
    'scrollSpeedFactor': scrollSpeedFactor,
    'scrollingLayoutSwipeSpeedFactor': scrollingLayoutSwipeSpeedFactor,
  };

  Map<String, Object> mouseToApplyJson() => <String, Object>{
    'speed': mouseSpeed,
  };

  DenialInputDeviceCapabilities copyWith({
    int? revision,
    bool? hasMouse,
    double? mouseSpeed,
    bool? hasTouchpad,
    bool? tapToClickEnabled,
    bool? naturalScrollEnabled,
    double? scrollSpeedFactor,
    double? scrollingLayoutSwipeSpeedFactor,
  }) {
    return DenialInputDeviceCapabilities(
      revision: revision ?? this.revision,
      hasMouse: hasMouse ?? this.hasMouse,
      mouseSpeed: mouseSpeed ?? this.mouseSpeed,
      hasTouchpad: hasTouchpad ?? this.hasTouchpad,
      tapToClickEnabled: tapToClickEnabled ?? this.tapToClickEnabled,
      naturalScrollEnabled: naturalScrollEnabled ?? this.naturalScrollEnabled,
      scrollSpeedFactor: scrollSpeedFactor ?? this.scrollSpeedFactor,
      scrollingLayoutSwipeSpeedFactor:
          scrollingLayoutSwipeSpeedFactor ??
          this.scrollingLayoutSwipeSpeedFactor,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DenialInputDeviceCapabilities &&
            revision == other.revision &&
            hasMouse == other.hasMouse &&
            mouseSpeed == other.mouseSpeed &&
            hasTouchpad == other.hasTouchpad &&
            tapToClickEnabled == other.tapToClickEnabled &&
            naturalScrollEnabled == other.naturalScrollEnabled &&
            scrollSpeedFactor == other.scrollSpeedFactor &&
            scrollingLayoutSwipeSpeedFactor ==
                other.scrollingLayoutSwipeSpeedFactor;
  }

  @override
  int get hashCode => Object.hash(
    revision,
    hasMouse,
    mouseSpeed,
    hasTouchpad,
    tapToClickEnabled,
    naturalScrollEnabled,
    scrollSpeedFactor,
    scrollingLayoutSwipeSpeedFactor,
  );
}
