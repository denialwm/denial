part of 'denial_wire.dart';

// flat_buffers 25.9.23's Dart writeListOfStructs() does not pre-align the
// vector. Without this padding, the trailing fields of one region are read as
// fields of a neighbour, so z/flags migrate between windows. Both wire structs
// are 8-byte aligned and have sizes that are multiples of that alignment.
class _AlignedInputLayoutObjectBuilder extends fb.ObjectBuilder {
  _AlignedInputLayoutObjectBuilder({
    required this.epoch,
    required this.flags,
    required this.shellRegions,
    required this.windows,
    required this.visibleSurfaceIds,
    required this.softwareKeyboardRegions,
  });

  final int epoch;
  final int flags;
  final List<generated.WireRectObjectBuilder> shellRegions;
  final List<generated.InputWindowRegionObjectBuilder> windows;
  final List<int> visibleSurfaceIds;
  final List<generated.WireRectObjectBuilder> softwareKeyboardRegions;

  @override
  int finish(fb.Builder builder) {
    final shellRegionsOffset = _writeAlignedStructVector(builder, shellRegions);
    final windowsOffset = _writeAlignedStructVector(builder, windows);
    final visibleSurfaceIdsOffset = _writeAlignedUint64Vector(
      builder,
      visibleSurfaceIds,
    );
    final softwareKeyboardRegionsOffset = _writeAlignedStructVector(
      builder,
      softwareKeyboardRegions,
    );
    builder.startTable(6);
    builder.addUint64(0, epoch);
    builder.addUint32(1, flags);
    builder.addOffset(2, shellRegionsOffset);
    builder.addOffset(3, windowsOffset);
    builder.addOffset(4, visibleSurfaceIdsOffset);
    builder.addOffset(5, softwareKeyboardRegionsOffset);
    return builder.endTable();
  }

  @override
  Uint8List toBytes([String? fileIdentifier]) {
    final builder = fb.Builder(deduplicateTables: false);
    builder.finish(finish(builder), fileIdentifier);
    return builder.buffer;
  }
}

// flat_buffers 25.9.23 has the same length-prefix alignment bug for generated
// List<int> int64 vectors. Keep the setting request strict-verifier compatible
// instead of weakening native verification for all Flutter messages.
class _AlignedSystemBarRequestObjectBuilder extends fb.ObjectBuilder {
  _AlignedSystemBarRequestObjectBuilder({
    required this.side,
    required this.monitorIds,
  });

  final generated.SystemBarSide side;
  final List<int> monitorIds;

  @override
  int finish(fb.Builder builder) {
    final monitorIdsOffset = _writeAlignedInt64Vector(builder, monitorIds);
    builder.startTable(7);
    builder.addUint8(0, generated.WindowRequestKind.ConfigureSystemBar.value);
    builder.addUint8(5, side.value);
    builder.addOffset(6, monitorIdsOffset);
    return builder.endTable();
  }

  @override
  Uint8List toBytes([String? fileIdentifier]) {
    final builder = fb.Builder(deduplicateTables: false);
    builder.finish(finish(builder), fileIdentifier);
    return builder.buffer;
  }
}

int _writeAlignedStructVector(
  fb.Builder builder,
  List<fb.ObjectBuilder> values,
) {
  builder.pad((-builder.offset) & 7);
  return builder.writeListOfStructs(values);
}

// flat_buffers 25.9.23 aligns writeListUint64()'s 32-bit length prefix rather
// than its first 64-bit element. Build the vector backwards with the public
// scalar API so native verifiers see a specification-compliant alignment.
int _writeAlignedUint64Vector(fb.Builder builder, List<int> values) {
  builder.pad((-builder.offset) & 7);
  for (var index = values.length - 1; index >= 0; index -= 1) {
    builder.putUint64(values[index]);
  }
  return builder.endStructVector(values.length);
}

int _writeAlignedInt64Vector(fb.Builder builder, List<int> values) {
  builder.pad((-builder.offset) & 7);
  for (var index = values.length - 1; index >= 0; index -= 1) {
    builder.putInt64(values[index]);
  }
  return builder.endStructVector(values.length);
}

generated.WireRectObjectBuilder _rectBuilder(Rect rect) {
  return generated.WireRectObjectBuilder(
    x: rect.left,
    y: rect.top,
    width: rect.width,
    height: rect.height,
  );
}

generated.ShortcutBindingObjectBuilder _shortcutBindingBuilder(
  DenialShortcutBinding binding,
) {
  return switch (binding.target) {
    DenialShortcutActionTarget(:final action) =>
      generated.ShortcutBindingObjectBuilder(
        shortcut: binding.shortcut,
        targetType: generated.ShortcutTargetTypeId.ShortcutDenialActionTarget,
        target: generated.ShortcutDenialActionTargetObjectBuilder(
          action: _shortcutActionToWire(action),
        ),
      ),
    DenialShortcutSpawnTarget(:final command, :final desktopFileId) =>
      generated.ShortcutBindingObjectBuilder(
        shortcut: binding.shortcut,
        targetType: generated.ShortcutTargetTypeId.ShortcutSpawnTarget,
        target: generated.ShortcutSpawnTargetObjectBuilder(
          command: command,
          desktopFileId: desktopFileId,
        ),
      ),
    DenialShortcutSpawnShTarget(:final command) =>
      generated.ShortcutBindingObjectBuilder(
        shortcut: binding.shortcut,
        targetType: generated.ShortcutTargetTypeId.ShortcutSpawnShTarget,
        target: generated.ShortcutSpawnShTargetObjectBuilder(command: command),
      ),
  };
}

DenialShortcutBinding? _decodeShortcutBinding(
  generated.ShortcutBinding binding,
) {
  final shortcut = binding.shortcut;
  if (shortcut == null || !_validShortcutWireString(shortcut)) {
    return null;
  }
  final target = binding.target;
  return switch ((binding.targetType, target)) {
    (
      generated.ShortcutTargetTypeId.ShortcutDenialActionTarget,
      generated.ShortcutDenialActionTarget(:final action),
    ) =>
      DenialShortcutBinding(
        shortcut: shortcut,
        target: DenialShortcutActionTarget(_shortcutActionFromWire(action)),
      ),
    (
      generated.ShortcutTargetTypeId.ShortcutSpawnTarget,
      generated.ShortcutSpawnTarget(
        command: final command?,
        desktopFileId: final desktopFileId,
      ),
    )
        when command.isNotEmpty &&
            command.length <= _maxShortcutCommandArguments &&
            command.every(
              (argument) =>
                  _validShortcutWireString(argument, emptyAllowed: true),
            ) &&
            command.first.isNotEmpty &&
            (desktopFileId == null || _validDesktopFileId(desktopFileId)) =>
      DenialShortcutBinding(
        shortcut: shortcut,
        target: DenialShortcutSpawnTarget(
          command,
          desktopFileId: desktopFileId,
        ),
      ),
    (
      generated.ShortcutTargetTypeId.ShortcutSpawnShTarget,
      generated.ShortcutSpawnShTarget(command: final command?),
    )
        when _validShortcutWireString(command) =>
      DenialShortcutBinding(
        shortcut: shortcut,
        target: DenialShortcutSpawnShTarget(command),
      ),
    _ => null,
  };
}

generated.ShortcutActionKind _shortcutActionToWire(
  DenialShortcutAction action,
) {
  return switch (action) {
    DenialShortcutAction.shutdown => generated.ShortcutActionKind.Shutdown,
    DenialShortcutAction.openApplications =>
      generated.ShortcutActionKind.OpenApplications,
    DenialShortcutAction.openDashboard =>
      generated.ShortcutActionKind.OpenDashboard,
    DenialShortcutAction.openOverview =>
      generated.ShortcutActionKind.OpenOverview,
    DenialShortcutAction.toggleVerticalMaximize =>
      generated.ShortcutActionKind.ToggleVerticalMaximize,
    DenialShortcutAction.windowSwitcher =>
      generated.ShortcutActionKind.WindowSwitcher,
    DenialShortcutAction.openClipboard =>
      generated.ShortcutActionKind.OpenClipboard,
    DenialShortcutAction.captureRegion =>
      generated.ShortcutActionKind.CaptureRegion,
    DenialShortcutAction.closeWindow =>
      generated.ShortcutActionKind.CloseWindow,
    DenialShortcutAction.minimizeWindow =>
      generated.ShortcutActionKind.MinimizeWindow,
    DenialShortcutAction.minimizeAllWindows =>
      generated.ShortcutActionKind.MinimizeAllWindows,
    DenialShortcutAction.toggleMaximize =>
      generated.ShortcutActionKind.ToggleMaximize,
    DenialShortcutAction.toggleFullscreen =>
      generated.ShortcutActionKind.ToggleFullscreen,
    DenialShortcutAction.releasePointer =>
      generated.ShortcutActionKind.ReleasePointer,
    DenialShortcutAction.lockScreen => generated.ShortcutActionKind.LockScreen,
    DenialShortcutAction.volumeUp => generated.ShortcutActionKind.VolumeUp,
    DenialShortcutAction.volumeDown => generated.ShortcutActionKind.VolumeDown,
    DenialShortcutAction.volumeMute => generated.ShortcutActionKind.VolumeMute,
    DenialShortcutAction.brightnessUp =>
      generated.ShortcutActionKind.BrightnessUp,
    DenialShortcutAction.brightnessDown =>
      generated.ShortcutActionKind.BrightnessDown,
    DenialShortcutAction.nextKeyboardLayout =>
      generated.ShortcutActionKind.NextKeyboardLayout,
    DenialShortcutAction.previousKeyboardLayout =>
      generated.ShortcutActionKind.PreviousKeyboardLayout,
    DenialShortcutAction.openSettings =>
      generated.ShortcutActionKind.OpenSettings,
    DenialShortcutAction.focusLeft => generated.ShortcutActionKind.FocusLeft,
    DenialShortcutAction.focusRight => generated.ShortcutActionKind.FocusRight,
    DenialShortcutAction.focusUp => generated.ShortcutActionKind.FocusUp,
    DenialShortcutAction.focusDown => generated.ShortcutActionKind.FocusDown,
    DenialShortcutAction.swapLeft => generated.ShortcutActionKind.SwapLeft,
    DenialShortcutAction.swapRight => generated.ShortcutActionKind.SwapRight,
    DenialShortcutAction.swapUp => generated.ShortcutActionKind.SwapUp,
    DenialShortcutAction.swapDown => generated.ShortcutActionKind.SwapDown,
  };
}

DenialShortcutAction _shortcutActionFromWire(
  generated.ShortcutActionKind action,
) {
  return switch (action) {
    generated.ShortcutActionKind.Shutdown => DenialShortcutAction.shutdown,
    generated.ShortcutActionKind.OpenApplications =>
      DenialShortcutAction.openApplications,
    generated.ShortcutActionKind.OpenDashboard =>
      DenialShortcutAction.openDashboard,
    generated.ShortcutActionKind.OpenOverview =>
      DenialShortcutAction.openOverview,
    generated.ShortcutActionKind.ToggleVerticalMaximize =>
      DenialShortcutAction.toggleVerticalMaximize,
    generated.ShortcutActionKind.WindowSwitcher =>
      DenialShortcutAction.windowSwitcher,
    generated.ShortcutActionKind.OpenClipboard =>
      DenialShortcutAction.openClipboard,
    generated.ShortcutActionKind.CaptureRegion =>
      DenialShortcutAction.captureRegion,
    generated.ShortcutActionKind.CloseWindow =>
      DenialShortcutAction.closeWindow,
    generated.ShortcutActionKind.MinimizeWindow =>
      DenialShortcutAction.minimizeWindow,
    generated.ShortcutActionKind.MinimizeAllWindows =>
      DenialShortcutAction.minimizeAllWindows,
    generated.ShortcutActionKind.ToggleMaximize =>
      DenialShortcutAction.toggleMaximize,
    generated.ShortcutActionKind.ToggleFullscreen =>
      DenialShortcutAction.toggleFullscreen,
    generated.ShortcutActionKind.ReleasePointer =>
      DenialShortcutAction.releasePointer,
    generated.ShortcutActionKind.LockScreen => DenialShortcutAction.lockScreen,
    generated.ShortcutActionKind.VolumeUp => DenialShortcutAction.volumeUp,
    generated.ShortcutActionKind.VolumeDown => DenialShortcutAction.volumeDown,
    generated.ShortcutActionKind.VolumeMute => DenialShortcutAction.volumeMute,
    generated.ShortcutActionKind.BrightnessUp =>
      DenialShortcutAction.brightnessUp,
    generated.ShortcutActionKind.BrightnessDown =>
      DenialShortcutAction.brightnessDown,
    generated.ShortcutActionKind.NextKeyboardLayout =>
      DenialShortcutAction.nextKeyboardLayout,
    generated.ShortcutActionKind.PreviousKeyboardLayout =>
      DenialShortcutAction.previousKeyboardLayout,
    generated.ShortcutActionKind.OpenSettings =>
      DenialShortcutAction.openSettings,
    generated.ShortcutActionKind.FocusLeft => DenialShortcutAction.focusLeft,
    generated.ShortcutActionKind.FocusRight => DenialShortcutAction.focusRight,
    generated.ShortcutActionKind.FocusUp => DenialShortcutAction.focusUp,
    generated.ShortcutActionKind.FocusDown => DenialShortcutAction.focusDown,
    generated.ShortcutActionKind.SwapLeft => DenialShortcutAction.swapLeft,
    generated.ShortcutActionKind.SwapRight => DenialShortcutAction.swapRight,
    generated.ShortcutActionKind.SwapUp => DenialShortcutAction.swapUp,
    generated.ShortcutActionKind.SwapDown => DenialShortcutAction.swapDown,
  };
}

DenialShortcutInputKind _shortcutInputKindFromWire(
  generated.ShortcutInputKind kind,
) {
  return switch (kind) {
    generated.ShortcutInputKind.Key => DenialShortcutInputKind.key,
    generated.ShortcutInputKind.Gesture => DenialShortcutInputKind.gesture,
  };
}

DenialShortcutInputCategory _shortcutInputCategoryFromWire(
  generated.ShortcutInputCategory category,
) {
  return switch (category) {
    generated.ShortcutInputCategory.Modifier =>
      DenialShortcutInputCategory.modifier,
    generated.ShortcutInputCategory.Navigation =>
      DenialShortcutInputCategory.navigation,
    generated.ShortcutInputCategory.Editing =>
      DenialShortcutInputCategory.editing,
    generated.ShortcutInputCategory.Punctuation =>
      DenialShortcutInputCategory.punctuation,
    generated.ShortcutInputCategory.$Function =>
      DenialShortcutInputCategory.function,
    generated.ShortcutInputCategory.Media => DenialShortcutInputCategory.media,
    generated.ShortcutInputCategory.Hardware =>
      DenialShortcutInputCategory.hardware,
    generated.ShortcutInputCategory.Special =>
      DenialShortcutInputCategory.special,
    generated.ShortcutInputCategory.Gesture =>
      DenialShortcutInputCategory.gesture,
  };
}

bool _validShortcutWireString(String value, {bool emptyAllowed = false}) {
  final bytes = utf8.encode(value);
  return (emptyAllowed || bytes.isNotEmpty) &&
      bytes.length <= denialWireMaxStringLength &&
      !bytes.contains(0);
}

bool _validDesktopFileId(String value) {
  return _validShortcutWireString(value) &&
      value.endsWith('.desktop') &&
      !value.contains('/');
}

bool _validShortcutBindingWire(
  DenialShortcutBinding binding, {
  bool emptyShortcutAllowed = false,
}) {
  if (!_validShortcutWireString(
    binding.shortcut,
    emptyAllowed: emptyShortcutAllowed,
  )) {
    return false;
  }
  return switch (binding.target) {
    DenialShortcutActionTarget() => true,
    DenialShortcutSpawnTarget(:final command, :final desktopFileId) =>
      command.length <= _maxShortcutCommandArguments &&
          command.every(
            (argument) =>
                _validShortcutWireString(argument, emptyAllowed: true),
          ) &&
          (desktopFileId == null || _validDesktopFileId(desktopFileId)),
    DenialShortcutSpawnShTarget(:final command) => _validShortcutWireString(
      command,
      emptyAllowed: true,
    ),
  };
}

bool _validRect(Rect rect) {
  return rect.left.isFinite &&
      rect.top.isFinite &&
      rect.width.isFinite &&
      rect.height.isFinite &&
      rect.width > 0.0 &&
      rect.height > 0.0;
}

bool _validWindowGeometry(Rect rect) {
  return _validRect(rect) &&
      rect.left >= 0.0 &&
      rect.top >= 0.0 &&
      rect.left <= 16384.0 &&
      rect.top <= 16384.0 &&
      rect.width >= 64.0 &&
      rect.height >= 64.0 &&
      rect.width <= 16384.0 &&
      rect.height <= 16384.0 &&
      rect.right.isFinite &&
      rect.bottom.isFinite &&
      rect.right <= 0x7fffffff &&
      rect.bottom <= 0x7fffffff;
}

bool _nativePayloadType(generated.PayloadTypeId type) {
  return type == generated.PayloadTypeId.WindowSnapshot ||
      type == generated.PayloadTypeId.DisplayLayout ||
      type == generated.PayloadTypeId.WindowResponse ||
      type == generated.PayloadTypeId.WindowEvent ||
      type == generated.PayloadTypeId.ShellAction ||
      type == generated.PayloadTypeId.CursorShape ||
      type == generated.PayloadTypeId.CursorState ||
      type == generated.PayloadTypeId.CursorPosition ||
      type == generated.PayloadTypeId.TextInputState ||
      type == generated.PayloadTypeId.DesktopNotificationEvent ||
      type == generated.PayloadTypeId.SettingsResponse ||
      type == generated.PayloadTypeId.XEmbedTrayEvent;
}

DenialSurfaceLayer _decodeSurfaceLayer(generated.SurfaceLayer layer) {
  return DenialSurfaceLayer(
    surfaceId: layer.surfaceId,
    parentSurfaceId: layer.parentSurfaceId,
    popupRootSurfaceId: layer.popupRootSurfaceId,
    role: switch (layer.role) {
      generated.SurfaceRole.Subsurface => DenialSurfaceRole.subsurface,
      generated.SurfaceRole.Popup => DenialSurfaceRole.popup,
      generated.SurfaceRole.Root => DenialSurfaceRole.root,
    },
    textureId: layer.textureId,
    width: layer.width,
    height: layer.height,
    surfaceX: layer.surfaceX,
    surfaceY: layer.surfaceY,
    surfaceWidth: layer.surfaceWidth,
    surfaceHeight: layer.surfaceHeight,
    textureSourceX: layer.textureSourceX,
    textureSourceY: layer.textureSourceY,
    textureSourceWidth: layer.textureSourceWidth,
    textureSourceHeight: layer.textureSourceHeight,
    transform: layer.transform,
    scale120: layer.scale120,
    compositionOrder: layer.compositionOrder,
    opacity: layer.opacity,
    opaque: layer.opaque,
  );
}

bool _validXkbName(String value, {required bool emptyAllowed}) {
  final bytes = value.codeUnits;
  return (emptyAllowed || bytes.isNotEmpty) &&
      bytes.length <= 64 &&
      bytes.every(
        (byte) =>
            (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x5a) ||
            (byte >= 0x61 && byte <= 0x7a) ||
            byte == 0x5f ||
            byte == 0x2b ||
            byte == 0x2d,
      );
}

bool _validXkbOption(String value) {
  if (value.isEmpty || value.length > 64) {
    return false;
  }
  return _validXkbName(value.replaceAll(':', ''), emptyAllowed: false);
}

bool _finiteWindow(generated.Window window) {
  return window.surfaceX.isFinite &&
      window.surfaceY.isFinite &&
      window.surfaceWidth.isFinite &&
      window.surfaceHeight.isFinite &&
      window.textureSourceX.isFinite &&
      window.textureSourceY.isFinite &&
      window.textureSourceWidth.isFinite &&
      window.textureSourceHeight.isFinite &&
      window.geometryX.isFinite &&
      window.geometryY.isFinite &&
      window.geometryWidth.isFinite &&
      window.geometryHeight.isFinite &&
      window.contentX.isFinite &&
      window.contentY.isFinite &&
      window.contentWidth.isFinite &&
      window.contentHeight.isFinite &&
      window.opacity.isFinite &&
      window.opacity >= 0.0 &&
      window.opacity <= 1.0 &&
      ((window.surfaces?.isEmpty ?? true) ||
          (window.contentWidth > 0.0 && window.contentHeight > 0.0));
}

bool _validSurfaceLayer(generated.SurfaceLayer layer) {
  final hasTexture = layer.textureId > 0;
  return layer.surfaceId > 0 &&
      layer.surfaceX.isFinite &&
      layer.surfaceY.isFinite &&
      layer.surfaceWidth.isFinite &&
      layer.surfaceHeight.isFinite &&
      layer.textureSourceX.isFinite &&
      layer.textureSourceY.isFinite &&
      layer.textureSourceWidth.isFinite &&
      layer.textureSourceHeight.isFinite &&
      layer.opacity.isFinite &&
      layer.opacity >= 0.0 &&
      layer.opacity <= 1.0 &&
      layer.surfaceWidth > 0.0 &&
      layer.surfaceHeight > 0.0 &&
      (!hasTexture ||
          (layer.width > 0 &&
              layer.height > 0 &&
              layer.textureSourceWidth > 0.0 &&
              layer.textureSourceHeight > 0.0));
}

int _compareInputWindows(InputWindowRegion left, InputWindowRegion right) {
  final zOrder = right.z.compareTo(left.z);
  return zOrder != 0
      ? zOrder
      : right.targetSurfaceId.compareTo(left.targetSurfaceId);
}

bool _inputWindowsAreOrdered(List<InputWindowRegion> windows) {
  for (var index = 1; index < windows.length; index += 1) {
    if (_compareInputWindows(windows[index - 1], windows[index]) > 0) {
      return false;
    }
  }
  return true;
}
