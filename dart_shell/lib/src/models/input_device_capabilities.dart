const double touchpadScrollSpeedFactorMinimum = 0.05;
const double touchpadScrollSpeedFactorMaximum = 5.0;
const double touchpadScrollSpeedFactorDefault = 1.0;

class DenialInputDeviceCapabilities {
  const DenialInputDeviceCapabilities({
    required this.revision,
    required this.hasTouchpad,
    required this.tapToClickEnabled,
    required this.naturalScrollEnabled,
    required this.scrollSpeedFactor,
  });

  const DenialInputDeviceCapabilities.none()
    : revision = 0,
      hasTouchpad = false,
      tapToClickEnabled = true,
      naturalScrollEnabled = false,
      scrollSpeedFactor = touchpadScrollSpeedFactorDefault;

  final int revision;
  final bool hasTouchpad;
  final bool tapToClickEnabled;
  final bool naturalScrollEnabled;
  final double scrollSpeedFactor;

  factory DenialInputDeviceCapabilities.fromJson(Map<String, Object?> json) {
    return DenialInputDeviceCapabilities(
      revision: json['revision'] as int? ?? 0,
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

  DenialInputDeviceCapabilities copyWith({
    int? revision,
    bool? hasTouchpad,
    bool? tapToClickEnabled,
    bool? naturalScrollEnabled,
    double? scrollSpeedFactor,
  }) {
    return DenialInputDeviceCapabilities(
      revision: revision ?? this.revision,
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
            hasTouchpad == other.hasTouchpad &&
            tapToClickEnabled == other.tapToClickEnabled &&
            naturalScrollEnabled == other.naturalScrollEnabled &&
            scrollSpeedFactor == other.scrollSpeedFactor;
  }

  @override
  int get hashCode => Object.hash(
    revision,
    hasTouchpad,
    tapToClickEnabled,
    naturalScrollEnabled,
    scrollSpeedFactor,
  );
}
