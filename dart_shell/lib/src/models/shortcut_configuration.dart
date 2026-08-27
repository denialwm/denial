enum DenialShortcutAction {
  shutdown,
  openApplications,
  openOverview,
  toggleVerticalMaximize,
  windowSwitcher,
  openClipboard,
  captureRegion,
  closeWindow,
  minimizeWindow,
  toggleMaximize,
  toggleFullscreen,
  releasePointer,
  lockScreen,
  volumeUp,
  volumeDown,
  volumeMute,
  brightnessUp,
  brightnessDown,
  nextKeyboardLayout,
  previousKeyboardLayout,
  openSettings,
}

enum DenialShortcutInputKind { key, gesture }

enum DenialShortcutInputCategory {
  modifier,
  navigation,
  editing,
  punctuation,
  function,
  media,
  hardware,
  special,
  gesture,
}

enum DenialShortcutValidationKind { valid, conflict, invalid }

sealed class DenialShortcutTarget {
  const DenialShortcutTarget();

  factory DenialShortcutTarget.fromJson(Map<String, Object?> json) {
    return switch (json['type']) {
      'denialAction' => DenialShortcutActionTarget(
        DenialShortcutAction.values.byName(json['action'] as String),
      ),
      'spawn' => DenialShortcutSpawnTarget(
        (json['command'] as List<Object?>).whereType<String>().toList(),
        desktopFileId: json['desktopFileId'] as String?,
      ),
      'spawnSh' => DenialShortcutSpawnShTarget(json['command'] as String),
      _ => throw const FormatException('invalid shortcut target'),
    };
  }

  Map<String, Object> toJson();
}

class DenialShortcutActionTarget extends DenialShortcutTarget {
  const DenialShortcutActionTarget(this.action);

  final DenialShortcutAction action;

  @override
  Map<String, Object> toJson() => <String, Object>{
    'type': 'denialAction',
    'action': action.name,
  };
}

class DenialShortcutSpawnTarget extends DenialShortcutTarget {
  DenialShortcutSpawnTarget(List<String> command, {this.desktopFileId})
    : command = List<String>.unmodifiable(command);

  final List<String> command;
  final String? desktopFileId;

  @override
  Map<String, Object> toJson() => <String, Object>{
    'type': 'spawn',
    'command': command,
    if (desktopFileId != null) 'desktopFileId': desktopFileId!,
  };
}

class DenialShortcutSpawnShTarget extends DenialShortcutTarget {
  const DenialShortcutSpawnShTarget(this.command);

  final String command;

  @override
  Map<String, Object> toJson() => <String, Object>{
    'type': 'spawnSh',
    'command': command,
  };
}

class DenialShortcutBinding {
  const DenialShortcutBinding({required this.shortcut, required this.target});

  /// Canonical shortcut text is the binding's unique identity.
  final String shortcut;
  final DenialShortcutTarget target;

  factory DenialShortcutBinding.fromJson(Map<String, Object?> json) {
    return DenialShortcutBinding(
      shortcut: json['shortcut'] as String,
      target: DenialShortcutTarget.fromJson(
        (json['target'] as Map<Object?, Object?>).cast<String, Object?>(),
      ),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'shortcut': shortcut,
    'target': target.toJson(),
  };
}

class DenialShortcutInput {
  DenialShortcutInput({
    required this.canonical,
    required this.kind,
    required this.category,
    required List<String> aliases,
  }) : aliases = List<String>.unmodifiable(aliases);

  final String canonical;
  final DenialShortcutInputKind kind;
  final DenialShortcutInputCategory category;
  final List<String> aliases;

  factory DenialShortcutInput.fromJson(Map<String, Object?> json) {
    return DenialShortcutInput(
      canonical: json['canonical'] as String,
      kind: DenialShortcutInputKind.values.byName(json['kind'] as String),
      category: DenialShortcutInputCategory.values.byName(
        json['category'] as String,
      ),
      aliases: (json['aliases'] as List<Object?>).whereType<String>().toList(),
    );
  }
}

class DenialShortcutConfiguration {
  DenialShortcutConfiguration({
    required this.revision,
    required List<DenialShortcutBinding> shortcuts,
    required List<DenialShortcutAction> supportedActions,
    required List<DenialShortcutInput> supportedInputs,
  }) : shortcuts = List<DenialShortcutBinding>.unmodifiable(shortcuts),
       supportedActions = List<DenialShortcutAction>.unmodifiable(
         supportedActions,
       ),
       supportedInputs = List<DenialShortcutInput>.unmodifiable(
         supportedInputs,
       );

  final int revision;
  final List<DenialShortcutBinding> shortcuts;
  final List<DenialShortcutAction> supportedActions;
  final List<DenialShortcutInput> supportedInputs;

  factory DenialShortcutConfiguration.fromJson(Map<String, Object?> json) {
    return DenialShortcutConfiguration(
      revision: json['revision'] as int? ?? 0,
      shortcuts: (json['shortcuts'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map<String, Object?>>()
          .map(DenialShortcutBinding.fromJson)
          .toList(growable: false),
      supportedActions:
          (json['supported_actions'] as List<Object?>? ?? const <Object?>[])
              .whereType<String>()
              .map(DenialShortcutAction.values.byName)
              .toList(growable: false),
      supportedInputs:
          (json['supported_inputs'] as List<Object?>? ?? const <Object?>[])
              .whereType<Map<String, Object?>>()
              .map(DenialShortcutInput.fromJson)
              .toList(growable: false),
    );
  }
}

class DenialShortcutValidation {
  const DenialShortcutValidation({
    required this.revision,
    required this.kind,
    this.canonical,
    this.conflict,
    this.error,
  });

  final int revision;
  final DenialShortcutValidationKind kind;
  final String? canonical;
  final DenialShortcutBinding? conflict;
  final String? error;

  bool get isValid => kind == DenialShortcutValidationKind.valid;

  factory DenialShortcutValidation.fromJson(Map<String, Object?> json) {
    final conflict = json['conflict'];
    return DenialShortcutValidation(
      revision: json['revision'] as int? ?? 0,
      kind: DenialShortcutValidationKind.values.byName(json['kind'] as String),
      canonical: json['canonical'] as String?,
      conflict: conflict is Map<String, Object?>
          ? DenialShortcutBinding.fromJson(conflict)
          : null,
      error: json['error'] as String?,
    );
  }
}
