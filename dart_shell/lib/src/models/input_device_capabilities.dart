class DenialInputDeviceCapabilities {
  const DenialInputDeviceCapabilities({
    required this.revision,
    required this.hasTouchpad,
    required this.tapToClickEnabled,
    required this.naturalScrollEnabled,
  });

  const DenialInputDeviceCapabilities.none()
    : revision = 0,
      hasTouchpad = false,
      tapToClickEnabled = true,
      naturalScrollEnabled = false;

  final int revision;
  final bool hasTouchpad;
  final bool tapToClickEnabled;
  final bool naturalScrollEnabled;

  DenialInputDeviceCapabilities copyWith({
    int? revision,
    bool? hasTouchpad,
    bool? tapToClickEnabled,
    bool? naturalScrollEnabled,
  }) {
    return DenialInputDeviceCapabilities(
      revision: revision ?? this.revision,
      hasTouchpad: hasTouchpad ?? this.hasTouchpad,
      tapToClickEnabled: tapToClickEnabled ?? this.tapToClickEnabled,
      naturalScrollEnabled: naturalScrollEnabled ?? this.naturalScrollEnabled,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DenialInputDeviceCapabilities &&
            revision == other.revision &&
            hasTouchpad == other.hasTouchpad &&
            tapToClickEnabled == other.tapToClickEnabled &&
            naturalScrollEnabled == other.naturalScrollEnabled;
  }

  @override
  int get hashCode => Object.hash(
    revision,
    hasTouchpad,
    tapToClickEnabled,
    naturalScrollEnabled,
  );
}
