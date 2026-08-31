const double touchpadScrollSpeedFactorMinimum = 0.05;
const double touchpadScrollSpeedFactorMaximum = 5.0;
const double touchpadScrollSpeedFactorDefault = 1.0;
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
  });

  const DenialInputDeviceCapabilities.none()
    : revision = 0,
      hasMouse = false,
      mouseSpeed = mouseSpeedDefault,
      hasTouchpad = false,
      tapToClickEnabled = true,
      naturalScrollEnabled = false,
      scrollSpeedFactor = touchpadScrollSpeedFactorDefault;

  final int revision;
  final bool hasMouse;
  final double mouseSpeed;
  final bool hasTouchpad;
  final bool tapToClickEnabled;
  final bool naturalScrollEnabled;
  final double scrollSpeedFactor;

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
    );
  }

  Map<String, Object> toApplyJson() => <String, Object>{
    'tapToClickEnabled': tapToClickEnabled,
    'naturalScrollEnabled': naturalScrollEnabled,
    'scrollSpeedFactor': scrollSpeedFactor,
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
  }) {
    return DenialInputDeviceCapabilities(
      revision: revision ?? this.revision,
      hasMouse: hasMouse ?? this.hasMouse,
      mouseSpeed: mouseSpeed ?? this.mouseSpeed,
      hasTouchpad: hasTouchpad ?? this.hasTouchpad,
      tapToClickEnabled: tapToClickEnabled ?? this.tapToClickEnabled,
      naturalScrollEnabled: naturalScrollEnabled ?? this.naturalScrollEnabled,
      scrollSpeedFactor: scrollSpeedFactor ?? this.scrollSpeedFactor,
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
            scrollSpeedFactor == other.scrollSpeedFactor;
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
  );
}
