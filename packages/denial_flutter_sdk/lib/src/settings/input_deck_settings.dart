/// Remembered per-connector opt-in. Runtime availability remains native-owned.
class InputDeckSettings {
  const InputDeckSettings({
    this.outputName = '',
    this.enabled = false,
    this.keyboardHeight = 0.48,
    this.touchpadWidth = 0.62,
    this.touchpadHeight = 1,
    this.pointerSpeed = 1.5,
    this.naturalScroll = true,
    this.showCpu = false,
    this.showGpu = false,
  });

  final String outputName;
  final bool enabled;
  final double keyboardHeight;
  final double touchpadWidth;
  final double touchpadHeight;
  final double pointerSpeed;
  final bool naturalScroll;
  final bool showCpu;
  final bool showGpu;

  /// Resolves preference into a request; native code validates it again.
  String? desiredOutput({
    required Iterable<String> touchOutputs,
    required bool available,
    bool locked = false,
  }) => enabled && available && !locked && touchOutputs.contains(outputName)
      ? outputName
      : null;

  factory InputDeckSettings.fromJson(Object? value) {
    final json = value is Map ? value : const {};
    const defaults = InputDeckSettings();
    final output = json['outputName'];
    return InputDeckSettings(
      outputName:
          output is String && output.length <= 256 && !output.contains('\u0000')
          ? output
          : '',
      enabled: json['enabled'] == true,
      keyboardHeight: _number(
        json['keyboardHeight'],
        defaults.keyboardHeight,
        0.3,
        0.65,
      ),
      touchpadWidth: _number(
        json['touchpadWidth'],
        defaults.touchpadWidth,
        0.35,
        1,
      ),
      touchpadHeight: _number(
        json['touchpadHeight'],
        defaults.touchpadHeight,
        0.35,
        1,
      ),
      pointerSpeed: _number(
        json['pointerSpeed'],
        defaults.pointerSpeed,
        0.25,
        4,
      ),
      naturalScroll: json['naturalScroll'] is bool
          ? json['naturalScroll'] as bool
          : true,
      showCpu: json['showCpu'] == true,
      showGpu: json['showGpu'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'outputName': outputName,
    'enabled': enabled,
    'keyboardHeight': keyboardHeight,
    'touchpadWidth': touchpadWidth,
    'touchpadHeight': touchpadHeight,
    'pointerSpeed': pointerSpeed,
    'naturalScroll': naturalScroll,
    'showCpu': showCpu,
    'showGpu': showGpu,
  };

  InputDeckSettings copyWith({
    String? outputName,
    bool? enabled,
    double? keyboardHeight,
    double? touchpadWidth,
    double? touchpadHeight,
    double? pointerSpeed,
    bool? naturalScroll,
    bool? showCpu,
    bool? showGpu,
  }) => InputDeckSettings.fromJson({
    ...toJson(),
    'outputName': ?outputName,
    'enabled': ?enabled,
    'keyboardHeight': ?keyboardHeight,
    'touchpadWidth': ?touchpadWidth,
    'touchpadHeight': ?touchpadHeight,
    'pointerSpeed': ?pointerSpeed,
    'naturalScroll': ?naturalScroll,
    'showCpu': ?showCpu,
    'showGpu': ?showGpu,
  });

  @override
  bool operator ==(Object other) =>
      other is InputDeckSettings &&
      outputName == other.outputName &&
      enabled == other.enabled &&
      keyboardHeight == other.keyboardHeight &&
      touchpadWidth == other.touchpadWidth &&
      touchpadHeight == other.touchpadHeight &&
      pointerSpeed == other.pointerSpeed &&
      naturalScroll == other.naturalScroll &&
      showCpu == other.showCpu &&
      showGpu == other.showGpu;
  @override
  int get hashCode => Object.hash(
    outputName,
    enabled,
    keyboardHeight,
    touchpadWidth,
    touchpadHeight,
    pointerSpeed,
    naturalScroll,
    showCpu,
    showGpu,
  );
}

double _number(
  Object? value,
  double fallback,
  double minimum,
  double maximum,
) => value is num && value.isFinite
    ? value.toDouble().clamp(minimum, maximum)
    : fallback;
