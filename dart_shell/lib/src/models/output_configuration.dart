import 'dart:ui';

enum DenialOutputTransform {
  normal('normal'),
  rotate90('90'),
  rotate180('180'),
  rotate270('270'),
  flipped('flipped'),
  flipped90('flipped-90'),
  flipped180('flipped-180'),
  flipped270('flipped-270');

  const DenialOutputTransform(this.wireName);

  final String wireName;

  bool get swapsAxes => switch (this) {
    rotate90 || rotate270 || flipped90 || flipped270 => true,
    _ => false,
  };

  static DenialOutputTransform fromWire(Object? value) {
    return values.firstWhere(
      (transform) => transform.wireName == value,
      orElse: () => throw FormatException('Unknown output transform: $value'),
    );
  }
}

class DenialOutputMode {
  const DenialOutputMode({
    required this.width,
    required this.height,
    required this.refreshMillihz,
    required this.preferred,
  });

  factory DenialOutputMode.fromJson(Map<String, Object?> json) {
    return DenialOutputMode(
      width: _positiveInt(json, 'width'),
      height: _positiveInt(json, 'height'),
      refreshMillihz: _positiveInt(json, 'refresh_millihz'),
      preferred: _bool(json, 'preferred'),
    );
  }

  final int width;
  final int height;
  final int refreshMillihz;
  final bool preferred;

  double get refreshHz => refreshMillihz / 1000;

  Map<String, Object> toApplyJson() => <String, Object>{
    'width': width,
    'height': height,
    'refresh_millihz': refreshMillihz,
  };

  @override
  bool operator ==(Object other) {
    return other is DenialOutputMode &&
        width == other.width &&
        height == other.height &&
        refreshMillihz == other.refreshMillihz;
  }

  @override
  int get hashCode => Object.hash(width, height, refreshMillihz);
}

class DenialOutputCapabilities {
  const DenialOutputCapabilities({
    required this.apply,
    required this.position,
    required this.mode,
    required this.scale,
    required this.transform,
    required this.persistent,
  });

  factory DenialOutputCapabilities.fromJson(Map<String, Object?> json) {
    return DenialOutputCapabilities(
      apply: _bool(json, 'apply'),
      position: _bool(json, 'position'),
      mode: _bool(json, 'mode'),
      scale: _bool(json, 'scale'),
      transform: _bool(json, 'transform'),
      persistent: _bool(json, 'persistent'),
    );
  }

  final bool apply;
  final bool position;
  final bool mode;
  final bool scale;
  final bool transform;
  final bool persistent;
}

class DenialOutput {
  const DenialOutput({
    required this.name,
    required this.description,
    required this.connected,
    required this.enabled,
    required this.powered,
    required this.x,
    required this.y,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.scale,
    required this.transform,
    required this.adaptiveSync,
    required this.currentMode,
    required this.modes,
  });

  factory DenialOutput.fromJson(Map<String, Object?> json) {
    final modes = _list(json, 'modes')
        .map((mode) => DenialOutputMode.fromJson(_map(mode, 'output mode')))
        .toList(growable: false);
    final currentMode = json['current_mode'];
    return DenialOutput(
      name: _string(json, 'name'),
      description: _string(json, 'description'),
      connected: _bool(json, 'connected'),
      enabled: _bool(json, 'enabled'),
      powered: _bool(json, 'powered'),
      x: _int(json, 'x'),
      y: _int(json, 'y'),
      logicalWidth: _positiveInt(json, 'logical_width'),
      logicalHeight: _positiveInt(json, 'logical_height'),
      scale: _positiveDouble(json, 'scale'),
      transform: DenialOutputTransform.fromWire(json['transform']),
      adaptiveSync: _bool(json, 'adaptive_sync'),
      currentMode: currentMode == null
          ? null
          : DenialOutputMode.fromJson(_map(currentMode, 'current output mode')),
      modes: List<DenialOutputMode>.unmodifiable(modes),
    );
  }

  final String name;
  final String description;
  final bool connected;
  final bool enabled;
  final bool powered;
  final int x;
  final int y;
  final int logicalWidth;
  final int logicalHeight;
  final double scale;
  final DenialOutputTransform transform;
  final bool adaptiveSync;
  final DenialOutputMode? currentMode;
  final List<DenialOutputMode> modes;

  DenialOutputMode get effectiveMode {
    final selected = currentMode;
    if (selected != null) {
      return selected;
    }
    if (modes.isEmpty) {
      throw StateError('$name has no selectable display modes');
    }
    return modes.first;
  }

  Size get draftLogicalSize {
    final selected = effectiveMode;
    final width = transform.swapsAxes ? selected.height : selected.width;
    final height = transform.swapsAxes ? selected.width : selected.height;
    return Size(width / scale, height / scale);
  }

  DenialOutput copyWith({
    int? x,
    int? y,
    double? scale,
    DenialOutputTransform? transform,
    DenialOutputMode? currentMode,
  }) {
    final nextMode = currentMode ?? this.currentMode ?? effectiveMode;
    final nextScale = scale ?? this.scale;
    final nextTransform = transform ?? this.transform;
    final width = nextTransform.swapsAxes ? nextMode.height : nextMode.width;
    final height = nextTransform.swapsAxes ? nextMode.width : nextMode.height;
    return DenialOutput(
      name: name,
      description: description,
      connected: connected,
      enabled: enabled,
      powered: powered,
      x: x ?? this.x,
      y: y ?? this.y,
      logicalWidth: (width / nextScale).round().clamp(1, 0x7fffffff),
      logicalHeight: (height / nextScale).round().clamp(1, 0x7fffffff),
      scale: nextScale,
      transform: nextTransform,
      adaptiveSync: adaptiveSync,
      currentMode: nextMode,
      modes: modes,
    );
  }

  Map<String, Object> toApplyJson() => <String, Object>{
    'name': name,
    'enabled': enabled,
    'powered': enabled && powered,
    'x': x,
    'y': y,
    'mode': effectiveMode.toApplyJson(),
    'scale': scale,
    'transform': transform.wireName,
    'adaptive_sync': adaptiveSync,
  };
}

class DenialOutputConfiguration {
  const DenialOutputConfiguration({
    required this.serial,
    required this.capabilities,
    required this.outputs,
    this.pendingConfirmation,
  });

  factory DenialOutputConfiguration.fromJson(Map<String, Object?> json) {
    return DenialOutputConfiguration(
      serial: _positiveInt(json, 'serial'),
      capabilities: DenialOutputCapabilities.fromJson(
        _map(json['capabilities'], 'output capabilities'),
      ),
      outputs: List<DenialOutput>.unmodifiable(
        _list(
          json,
          'outputs',
        ).map((output) => DenialOutput.fromJson(_map(output, 'output'))),
      ),
      pendingConfirmation: json['pending_confirmation'] == null
          ? null
          : DenialOutputConfirmation.fromJson(
              _map(json['pending_confirmation'], 'output confirmation'),
            ),
    );
  }

  final int serial;
  final DenialOutputCapabilities capabilities;
  final List<DenialOutput> outputs;
  final DenialOutputConfirmation? pendingConfirmation;
}

class DenialOutputConfirmation {
  const DenialOutputConfirmation({
    required this.token,
    required this.deadlineUnixMilliseconds,
  });

  factory DenialOutputConfirmation.fromJson(Map<String, Object?> json) {
    return DenialOutputConfirmation(
      token: _positiveInt(json, 'token'),
      deadlineUnixMilliseconds: _positiveInt(
        json,
        'deadline_unix_milliseconds',
      ),
    );
  }

  final int token;
  final int deadlineUnixMilliseconds;
}

Map<String, Object?> _map(Object? value, String label) {
  if (value case Map<String, Object?> map) {
    return map;
  }
  throw FormatException('Invalid $label');
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value case List<Object?> list) {
    return list;
  }
  throw FormatException('Invalid $key');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value case String text when text.isNotEmpty) {
    return text;
  }
  throw FormatException('Invalid $key');
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value case bool flag) {
    return flag;
  }
  throw FormatException('Invalid $key');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value case int number) {
    return number;
  }
  throw FormatException('Invalid $key');
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = _int(json, key);
  if (value > 0) {
    return value;
  }
  throw FormatException('Invalid $key');
}

double _positiveDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value case num number) {
    final result = number.toDouble();
    if (result.isFinite && result > 0) {
      return result;
    }
  }
  throw FormatException('Invalid $key');
}
