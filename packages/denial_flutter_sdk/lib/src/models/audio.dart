class AudioLevelState {
  const AudioLevelState({
    required this.level,
    required this.requestSerial,
    this.muted = false,
    this.limitReached = false,
    this.fromKey = false,
    this.completesRead = false,
  });

  final double level;
  final int requestSerial;
  final bool muted;
  final bool limitReached;
  final bool fromKey;

  /// Whether this update satisfied an explicit state read from Dart.
  ///
  /// Reconciliation reads update controls but should not look like a fresh
  /// hardware-key interaction to transient shell surfaces.
  final bool completesRead;
}

class AppAudioStream {
  const AppAudioStream({
    required this.id,
    required this.name,
    required this.level,
    required this.muted,
  });

  final int id;
  final String name;
  final double level;
  final bool muted;

  AppAudioStream copyWith({double? level, bool? muted}) {
    if ((level == null || level == this.level) &&
        (muted == null || muted == this.muted)) {
      return this;
    }
    return AppAudioStream(
      id: id,
      name: name,
      level: level ?? this.level,
      muted: muted ?? this.muted,
    );
  }
}

class AudioOutputDevice {
  const AudioOutputDevice({
    required this.name,
    required this.description,
    required this.active,
    required this.available,
  });

  final String name;
  final String description;
  final bool active;
  final bool available;
}
