part of 'status_notifier_service.dart';

class _PendingStatusNotifierRefresh {
  bool full = false;
  final Set<String> properties = <String>{};
}

class _StatusNotifierRegistration {
  const _StatusNotifierRegistration({
    required this.busName,
    required this.path,
    required this.owner,
  });

  final String busName;
  final String path;
  final String owner;

  String get id => 'status-notifier:$busName:$path';

  String get address => '$busName$path';

  _StatusNotifierRegistration withOwner(String value) =>
      _StatusNotifierRegistration(busName: busName, path: path, owner: value);
}

_StatusNotifierRegistration? _parseRegistration(
  String value, {
  required String? sender,
}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 4096) {
    return null;
  }
  if (trimmed.startsWith('/')) {
    if (sender == null || sender.isEmpty) {
      return null;
    }
    try {
      DBusObjectPath(trimmed);
      return _StatusNotifierRegistration(
        busName: sender,
        path: trimmed,
        owner: sender,
      );
    } on Object {
      return null;
    }
  }
  final slash = trimmed.indexOf('/');
  final busName = slash < 0 ? trimmed : trimmed.substring(0, slash);
  final path = slash < 0 ? '/StatusNotifierItem' : trimmed.substring(slash);
  try {
    if (!_isValidBusName(busName)) {
      return null;
    }
    DBusObjectPath(path);
    return _StatusNotifierRegistration(busName: busName, path: path, owner: '');
  } on Object {
    return null;
  }
}

bool _isValidBusName(String value) {
  if (value.isEmpty || value.length > 255) {
    return false;
  }
  final unique = value.startsWith(':');
  final body = unique ? value.substring(1) : value;
  final parts = body.split('.');
  if (parts.length < 2 || parts.any((part) => part.isEmpty)) {
    return false;
  }
  final segment = unique
      ? RegExp(r'^[A-Za-z0-9_-]+$')
      : RegExp(r'^[A-Za-z_-][A-Za-z0-9_-]*$');
  return parts.every(segment.hasMatch);
}

String _string(DBusValue? value, {String fallback = ''}) {
  try {
    return value?.asString() ?? fallback;
  } on Object {
    return fallback;
  }
}

String? _objectPath(DBusValue? value) {
  try {
    return value?.asObjectPath().value;
  } on Object {
    return null;
  }
}

bool _boolean(DBusValue? value) {
  try {
    return value?.asBoolean() ?? false;
  } on Object {
    return false;
  }
}

String _boundedText(String value, int maxLength) {
  final normalized = value.replaceAll('\u0000', '').trim();
  return normalized.length <= maxLength
      ? normalized
      : normalized.substring(0, maxLength);
}

SystemTrayStatus _status(String value) => switch (value.toLowerCase()) {
  'passive' => SystemTrayStatus.passive,
  'needsattention' => SystemTrayStatus.needsAttention,
  _ => SystemTrayStatus.active,
};

int _statusPriority(SystemTrayStatus status) => switch (status) {
  SystemTrayStatus.needsAttention => 0,
  SystemTrayStatus.active => 1,
  SystemTrayStatus.passive => 2,
};

SystemTrayIconPixmap? _bestPixmap(DBusValue? value) {
  if (value == null || value.signature != DBusSignature('a(iiay)')) {
    return null;
  }
  _StatusNotifierPixmapCandidate? best;
  for (final entry in value.asArray().take(32)) {
    try {
      final tuple = entry.asStruct();
      if (tuple.length != 3 || tuple[2].signature != DBusSignature('ay')) {
        continue;
      }
      final width = tuple[0].asInt32();
      final height = tuple[1].asInt32();
      final byteCount = width * height * 4;
      if (width <= 0 ||
          height <= 0 ||
          width > _StatusNotifierLimits.maxInputDimension ||
          height > _StatusNotifierLimits.maxInputDimension ||
          byteCount > _StatusNotifierLimits.maxInputIconBytes ||
          tuple[2].asArray().length != byteCount) {
        continue;
      }
      final candidate = _StatusNotifierPixmapCandidate(
        width: width,
        height: height,
        bytes: tuple[2].asArray(),
      );
      if (best == null || candidate.score < best.score) {
        best = candidate;
      }
    } on Object {
      continue;
    }
  }
  return best?.decode();
}

class _StatusNotifierPixmapCandidate {
  const _StatusNotifierPixmapCandidate({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;
  final List<DBusValue> bytes;

  int get score {
    final extent = width > height ? width : height;
    final delta = extent - _StatusNotifierLimits.preferredIconDimension;
    return delta >= 0
        ? delta
        : -delta + _StatusNotifierLimits.maxInputDimension;
  }

  SystemTrayIconPixmap decode() {
    final longest = width > height ? width : height;
    final outputScale = longest <= _StatusNotifierLimits.maxOutputDimension
        ? 1.0
        : _StatusNotifierLimits.maxOutputDimension / longest;
    final outputWidth = (width * outputScale).round().clamp(
      1,
      _StatusNotifierLimits.maxOutputDimension,
    );
    final outputHeight = (height * outputScale).round().clamp(
      1,
      _StatusNotifierLimits.maxOutputDimension,
    );
    final rgba = Uint8List(outputWidth * outputHeight * 4);
    for (var outputY = 0; outputY < outputHeight; outputY += 1) {
      final sourceY = outputY * height ~/ outputHeight;
      for (var outputX = 0; outputX < outputWidth; outputX += 1) {
        final sourceX = outputX * width ~/ outputWidth;
        final sourceOffset = (sourceY * width + sourceX) * 4;
        final outputOffset = (outputY * outputWidth + outputX) * 4;
        final alpha = bytes[sourceOffset].asByte();
        rgba[outputOffset] = _premultiplyChannel(
          bytes[sourceOffset + 1].asByte(),
          alpha,
        );
        rgba[outputOffset + 1] = _premultiplyChannel(
          bytes[sourceOffset + 2].asByte(),
          alpha,
        );
        rgba[outputOffset + 2] = _premultiplyChannel(
          bytes[sourceOffset + 3].asByte(),
          alpha,
        );
        rgba[outputOffset + 3] = alpha;
      }
    }
    return SystemTrayIconPixmap(
      width: outputWidth,
      height: outputHeight,
      rgba: rgba,
    );
  }
}

int _premultiplyChannel(int channel, int alpha) {
  return (channel * alpha + 127) ~/ 255;
}

class _MenuBudget {
  _MenuBudget(this.remaining);

  int remaining;
}

SystemTrayMenuEntry? _parseMenuEntry(
  DBusValue value, {
  required _MenuBudget budget,
  required int depth,
}) {
  if (budget.remaining <= 0 ||
      depth > _StatusNotifierDbusBackend._maxMenuDepth) {
    return null;
  }
  try {
    final fields = value.asStruct();
    if (fields.length != 3) {
      return null;
    }
    final id = fields[0].asInt32();
    final properties = fields[1].asStringVariantDict();
    final children = <SystemTrayMenuEntry>[];
    if (depth < _StatusNotifierDbusBackend._maxMenuDepth) {
      for (final child in fields[2].asArray()) {
        if (budget.remaining <= 0) {
          break;
        }
        final parsed = _parseMenuEntry(
          child.asVariant(),
          budget: budget,
          depth: depth + 1,
        );
        if (parsed != null) {
          children.add(parsed);
        }
      }
    }
    budget.remaining -= 1;
    final type = _string(properties['type']);
    final toggleType = switch (_string(properties['toggle-type'])) {
      'checkmark' => SystemTrayMenuToggleType.checkmark,
      'radio' => SystemTrayMenuToggleType.radio,
      _ => SystemTrayMenuToggleType.none,
    };
    return SystemTrayMenuEntry(
      id: id,
      label: _menuLabel(_boundedText(_string(properties['label']), 512)),
      enabled: properties.containsKey('enabled')
          ? _boolean(properties['enabled'])
          : true,
      visible: properties.containsKey('visible')
          ? _boolean(properties['visible'])
          : true,
      separator: type == 'separator',
      toggleType: toggleType,
      toggleState: _int32(properties['toggle-state']),
      destructive: _string(properties['disposition']) == 'warning',
      children: List<SystemTrayMenuEntry>.unmodifiable(children),
    );
  } on Object {
    return null;
  }
}

int _int32(DBusValue? value) {
  try {
    return value?.asInt32() ?? 0;
  } on Object {
    return 0;
  }
}

String _menuLabel(String value) {
  final output = StringBuffer();
  for (var index = 0; index < value.length; index += 1) {
    final character = value[index];
    if (character != '_') {
      output.write(character);
      continue;
    }
    if (index + 1 < value.length && value[index + 1] == '_') {
      output.write('_');
      index += 1;
    }
  }
  return output.toString();
}

abstract final class _StatusNotifierLimits {
  static const int preferredIconDimension = 24;
  static const int maxInputDimension = 512;
  static const int maxInputIconBytes =
      maxInputDimension * maxInputDimension * 4;
  static const int maxOutputDimension = 64;
}

@visibleForTesting
SystemTrayIconPixmap? decodeStatusNotifierPixmapForTesting(DBusValue value) =>
    _bestPixmap(value);

@visibleForTesting
Set<String> statusNotifierPropertiesForSignalForTesting(String signal) =>
    Set<String>.unmodifiable(_itemSignalProperties[signal] ?? const <String>{});
