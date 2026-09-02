enum SuspendMode { systemDefault, s2idle, shallow, deep }

extension SuspendModeKernelValue on SuspendMode {
  String? get kernelValue => switch (this) {
    SuspendMode.systemDefault => null,
    SuspendMode.s2idle => 's2idle',
    SuspendMode.shallow => 'shallow',
    SuspendMode.deep => 'deep',
  };

  int get wireValue => switch (this) {
    SuspendMode.systemDefault => 0,
    SuspendMode.s2idle => 1,
    SuspendMode.shallow => 2,
    SuspendMode.deep => 3,
  };

  static SuspendMode? fromKernelValue(String value) => switch (value) {
    's2idle' => SuspendMode.s2idle,
    'shallow' => SuspendMode.shallow,
    'deep' => SuspendMode.deep,
    _ => null,
  };
}

class SuspendModeCapabilities {
  const SuspendModeCapabilities({
    required this.supported,
    required this.current,
  });

  const SuspendModeCapabilities.unavailable()
    : supported = const <SuspendMode>[],
      current = null;

  factory SuspendModeCapabilities.parse(String memSleep) {
    final supported = <SuspendMode>[];
    SuspendMode? current;
    for (final rawToken in memSleep.trim().split(RegExp(r'\s+'))) {
      if (rawToken.isEmpty) {
        continue;
      }
      final selected = rawToken.startsWith('[') && rawToken.endsWith(']');
      final token = selected
          ? rawToken.substring(1, rawToken.length - 1)
          : rawToken;
      final mode = SuspendModeKernelValue.fromKernelValue(token);
      if (mode == null || supported.contains(mode)) {
        continue;
      }
      supported.add(mode);
      if (selected) {
        current = mode;
      }
    }
    return SuspendModeCapabilities(
      supported: List<SuspendMode>.unmodifiable(supported),
      current: current ?? (supported.length == 1 ? supported.single : null),
    );
  }

  final List<SuspendMode> supported;
  final SuspendMode? current;

  bool get canSelect => supported.length > 1;

  SuspendMode effectiveSelection(SuspendMode preferred) {
    if (preferred != SuspendMode.systemDefault &&
        supported.contains(preferred)) {
      return preferred;
    }
    final active = current;
    if (active != null && supported.contains(active)) {
      return active;
    }
    return supported.isEmpty ? SuspendMode.systemDefault : supported.first;
  }
}
