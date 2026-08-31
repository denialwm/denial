import 'dart:convert';
import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:flutter/widgets.dart';

import 'package:denial_wire_protocol/denial_denial.wire_generated.dart'
    as generated;
import '../input/input_layout.dart';
import '../models/display_layout.dart';
import '../models/denial_drag_icon.dart';
import '../models/denial_cursor_state.dart';
import '../models/desktop_notification.dart' as model;
import '../models/input_device_capabilities.dart';
import '../models/keyboard_configuration.dart';
import '../models/shortcut_configuration.dart';
import '../models/system_tray_item.dart' as tray_model;
import '../models/denial_window.dart';
import '../models/denial_window_event.dart';

export 'package:denial_wire_protocol/denial_denial.wire_generated.dart';

part 'denial_wire_aligned_builders.dart';

const int denialWireVersion = 1;
const int denialWireMaxBytes = 1024 * 1024;
const int denialWireMaxWindows = 4096;
const int denialWireMaxRegions = 8192;
const int denialWireMaxSurfaces = 32768;
const int denialWireMaxStringLength = 4096;
const int denialWireMaxNotificationActions = 16;
const int denialWireMaxNotificationImageBytes = 512 * 1024;
const int denialWireMaxTrayIconBytes = 512 * 1024;
const int denialWireMaxLocalAppIdBytes = 256;
const int denialWireMaxLocalWindowTitleBytes = 1024;
const int denialWireMaxSettingsDocumentBytes = 256 * 1024;
const int _maxShortcutBindings = 256;
const int _maxShortcutInputs = 256;
const int _maxShortcutCommandArguments = 64;

const String denialWireToNativeChannel = 'denial/wire/to_native';
const String denialWireToFlutterChannel = 'denial/wire/to_flutter';

const int _inputLayoutKeyboardCapture = 1 << 0;
const int _inputLayoutExclusiveShell = 1 << 1;
const int _inputLayoutObserveClientPointerPresses = 1 << 2;
const int _inputWindowVisible = 1 << 0;
const int _inputWindowHitTestDisabled = 1 << 1;
const int _inputWindowGeometryLocked = 1 << 2;
const int _keyboardCtrl = 1 << 0;
const int _keyboardPressed = 1 << 1;
const int _keyboardReleased = 1 << 2;
const int _placementPacketBytes = 80;
const int _dragIconPacketBytes = 128;

enum DenialKeyboardKeyPhase { tap, pressed, released }

bool isDenialPlacementPacket(ByteData? data) {
  return data != null &&
      data.lengthInBytes >= 4 &&
      data.getUint8(0) == 0x44 &&
      data.getUint8(1) == 0x45 &&
      data.getUint8(2) == 0x4e &&
      data.getUint8(3) == 0x50;
}

bool isDenialDragIconPacket(ByteData? data) {
  return data != null &&
      data.lengthInBytes >= 4 &&
      data.getUint8(0) == 0x44 &&
      data.getUint8(1) == 0x45 &&
      data.getUint8(2) == 0x4e &&
      data.getUint8(3) == 0x44;
}

class DenialDecodedEnvelope {
  const DenialDecodedEnvelope({
    required this.sequence,
    required this.requestId,
    required this.payloadType,
    required this.payload,
  });

  final int sequence;
  final int requestId;
  final generated.PayloadTypeId payloadType;
  final Object payload;
}

class DenialWireCodec {
  int _nextSequence = 1;
  int _lastPlacementSequence = 0;
  int _lastDragIconSequence = 0;
  int rejectedStructuredMessages = 0;
  int rejectedPlacementPackets = 0;
  int rejectedDragIconPackets = 0;

  Uint8List? encodeThemeAccent(int argb) {
    if (argb < 0 || argb > 0xffffffff) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.ThemeState,
      generated.ThemeStateObjectBuilder(accentSrgb: argb & 0x00ffffff),
    );
  }

  Uint8List? encodeInputLayout(InputLayoutSnapshot snapshot) {
    if (snapshot.shellRegions.length > denialWireMaxRegions ||
        snapshot.softwareKeyboardRegions.length > denialWireMaxRegions ||
        snapshot.windows.length > denialWireMaxRegions ||
        snapshot.visibleSurfaceIds.length > denialWireMaxSurfaces ||
        snapshot.visibleSurfaceIds.any((surfaceId) => surfaceId <= 0)) {
      return null;
    }

    final shellRegions = <generated.WireRectObjectBuilder>[];
    for (final rect in snapshot.shellRegions) {
      if (!_validRect(rect)) {
        return null;
      }
      shellRegions.add(_rectBuilder(rect));
    }

    final softwareKeyboardRegions = <generated.WireRectObjectBuilder>[];
    for (final rect in snapshot.softwareKeyboardRegions) {
      if (!_validRect(rect)) {
        return null;
      }
      softwareKeyboardRegions.add(_rectBuilder(rect));
    }

    final orderedWindows = _inputWindowsAreOrdered(snapshot.windows)
        ? snapshot.windows
        : (snapshot.windows.toList(growable: false)
            ..sort(_compareInputWindows));
    final windows = <generated.InputWindowRegionObjectBuilder>[];
    for (final window in orderedWindows) {
      if (window.window.objectId <= 0 ||
          window.targetSurfaceId <= 0 ||
          window.window.windowId <= 0 ||
          !_validRect(window.rect) ||
          !_validRect(window.sourceRect)) {
        return null;
      }
      var flags = 0;
      if (window.visible) {
        flags |= _inputWindowVisible;
      }
      // Preserve the JSON protocol's safe default: a missing input flag means
      // the visible client is hit-testable. Only explicit opt-out sets a bit.
      if (!window.hitTest) {
        flags |= _inputWindowHitTestDisabled;
      }
      if (window.geometryLocked) {
        flags |= _inputWindowGeometryLocked;
      }
      windows.add(
        generated.InputWindowRegionObjectBuilder(
          objectId: window.window.objectId,
          surfaceId: window.targetSurfaceId,
          windowId: window.window.windowId,
          rect: _rectBuilder(window.rect),
          sourceRect: _rectBuilder(window.sourceRect),
          z: window.z,
          flags: flags,
        ),
      );
    }

    var flags = 0;
    if (snapshot.keyboardCapture) {
      flags |= _inputLayoutKeyboardCapture;
    }
    if (snapshot.exclusiveShellMode) {
      flags |= _inputLayoutExclusiveShell;
    }
    if (snapshot.observeClientPointerPresses) {
      flags |= _inputLayoutObserveClientPointerPresses;
    }

    return _encodeEnvelope(
      generated.PayloadTypeId.InputLayout,
      _AlignedInputLayoutObjectBuilder(
        epoch: snapshot.epoch,
        flags: flags,
        shellRegions: shellRegions,
        windows: windows,
        visibleSurfaceIds: snapshot.visibleSurfaceIds,
        softwareKeyboardRegions: softwareKeyboardRegions,
      ),
    );
  }

  Uint8List encodeWindowRequest(
    generated.WindowRequestKind kind, {
    int requestId = 0,
    int windowId = 0,
    Rect? geometry,
    String? appId,
    String? title,
    generated.SystemBarSide? systemBarSide,
    List<int>? systemBarMonitorIds,
    int flags = 0,
  }) {
    return _encodeEnvelope(
      generated.PayloadTypeId.WindowRequest,
      generated.WindowRequestObjectBuilder(
        kind: kind,
        windowId: windowId,
        geometry: geometry == null ? null : _rectBuilder(geometry),
        appId: appId,
        title: title,
        systemBarSide: systemBarSide,
        systemBarMonitorIds: systemBarMonitorIds,
        flags: flags,
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeSystemBarConfiguration({
    required int requestId,
    required SystemBarSide side,
    required List<int> monitorIds,
  }) {
    if (requestId <= 0 ||
        side == SystemBarSide.hidden ||
        monitorIds.isEmpty ||
        monitorIds.length > denialWireMaxWindows ||
        monitorIds.any((monitorId) => monitorId < 0) ||
        monitorIds.toSet().length != monitorIds.length) {
      return null;
    }
    final wireSide = switch (side) {
      SystemBarSide.left => generated.SystemBarSide.Left,
      SystemBarSide.right => generated.SystemBarSide.Right,
      SystemBarSide.top => generated.SystemBarSide.Top,
      SystemBarSide.bottom => generated.SystemBarSide.Bottom,
      SystemBarSide.hidden => throw StateError(
        'hidden system bar is not configurable',
      ),
    };
    return _encodeEnvelope(
      generated.PayloadTypeId.WindowRequest,
      _AlignedSystemBarRequestObjectBuilder(
        side: wireSide,
        monitorIds: List<int>.unmodifiable(monitorIds),
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeCreateLocalWindow({
    required String appId,
    required String title,
    required Rect geometry,
  }) {
    final appIdBytes = utf8.encode(appId);
    final titleBytes = utf8.encode(title);
    if (appIdBytes.isEmpty ||
        appIdBytes.length > denialWireMaxLocalAppIdBytes ||
        titleBytes.isEmpty ||
        titleBytes.length > denialWireMaxLocalWindowTitleBytes ||
        appId.contains('\u0000') ||
        title.contains('\u0000') ||
        !_validWindowGeometry(geometry)) {
      return null;
    }
    return encodeWindowRequest(
      generated.WindowRequestKind.CreateLocalWindow,
      geometry: geometry,
      appId: appId,
      title: title,
    );
  }

  Uint8List encodeKeyboardText(String text) {
    return _encodeEnvelope(
      generated.PayloadTypeId.KeyboardCommand,
      generated.KeyboardCommandObjectBuilder(
        kind: generated.KeyboardCommandKind.Text,
        text: text,
      ),
    );
  }

  Uint8List encodeKeyboardKey(
    String key, {
    bool ctrl = false,
    DenialKeyboardKeyPhase phase = DenialKeyboardKeyPhase.tap,
  }) {
    final phaseFlag = switch (phase) {
      DenialKeyboardKeyPhase.tap => 0,
      DenialKeyboardKeyPhase.pressed => _keyboardPressed,
      DenialKeyboardKeyPhase.released => _keyboardReleased,
    };
    return _encodeEnvelope(
      generated.PayloadTypeId.KeyboardCommand,
      generated.KeyboardCommandObjectBuilder(
        kind: generated.KeyboardCommandKind.Key,
        key: key,
        flags: (ctrl ? _keyboardCtrl : 0) | phaseFlag,
      ),
    );
  }

  Uint8List encodeSettingsRead(
    generated.SettingsRequestKind kind, {
    required int requestId,
  }) {
    if (requestId <= 0 ||
        (kind != generated.SettingsRequestKind.ReadDocument &&
            kind != generated.SettingsRequestKind.ReadKeyboard &&
            kind != generated.SettingsRequestKind.ReadInputDevices)) {
      throw ArgumentError('invalid settings read request');
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(kind: kind),
      requestId: requestId,
    );
  }

  Uint8List? encodeSettingsDocumentWrite({
    required int requestId,
    required int expectedRevision,
    required String document,
  }) {
    final bytes = utf8.encode(document);
    if (requestId <= 0 ||
        expectedRevision <= 0 ||
        bytes.isEmpty ||
        bytes.length > denialWireMaxSettingsDocumentBytes ||
        bytes.contains(0)) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: generated.SettingsRequestKind.WriteDocument,
        expectedRevision: expectedRevision,
        document: document,
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeKeyboardConfiguration({
    required int requestId,
    required DenialKeyboardConfiguration configuration,
  }) {
    if (requestId <= 0 ||
        configuration.revision <= 0 ||
        configuration.layouts.isEmpty ||
        configuration.layouts.length > 8 ||
        configuration.options.length > 32 ||
        configuration.repeatDelayMs < 100 ||
        configuration.repeatDelayMs > 5000 ||
        configuration.repeatRateHz < 0 ||
        configuration.repeatRateHz > 100) {
      return null;
    }
    final layouts = <generated.KeyboardLayoutObjectBuilder>[];
    for (final layout in configuration.layouts) {
      if (!_validXkbName(layout.layout, emptyAllowed: false) ||
          !_validXkbName(layout.variant, emptyAllowed: true)) {
        return null;
      }
      layouts.add(
        generated.KeyboardLayoutObjectBuilder(
          layout: layout.layout,
          variant: layout.variant,
        ),
      );
    }
    if (configuration.options.any((option) => !_validXkbOption(option)) ||
        configuration.options.toSet().length != configuration.options.length) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: generated.SettingsRequestKind.ConfigureKeyboard,
        expectedRevision: configuration.revision,
        keyboard: generated.KeyboardConfigurationObjectBuilder(
          layouts: layouts,
          options: configuration.options,
          repeatDelayMs: configuration.repeatDelayMs,
          repeatRateHz: configuration.repeatRateHz,
          activeLayout: 0,
        ),
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeTouchpadConfiguration({
    required int requestId,
    required DenialInputDeviceCapabilities capabilities,
  }) {
    if (requestId <= 0 ||
        capabilities.revision <= 0 ||
        !capabilities.scrollSpeedFactor.isFinite ||
        capabilities.scrollSpeedFactor < touchpadScrollSpeedFactorMinimum ||
        capabilities.scrollSpeedFactor > touchpadScrollSpeedFactorMaximum) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: generated.SettingsRequestKind.ConfigureTouchpad,
        expectedRevision: capabilities.revision,
        touchpad: generated.TouchpadConfigurationObjectBuilder(
          tapToClickEnabled: capabilities.tapToClickEnabled,
          naturalScrollEnabled: capabilities.naturalScrollEnabled,
          scrollSpeedFactor: capabilities.scrollSpeedFactor,
        ),
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeMouseConfiguration({
    required int requestId,
    required DenialInputDeviceCapabilities capabilities,
  }) {
    if (requestId <= 0 ||
        capabilities.revision <= 0 ||
        !capabilities.mouseSpeed.isFinite ||
        capabilities.mouseSpeed < mouseSpeedMinimum ||
        capabilities.mouseSpeed > mouseSpeedMaximum) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: generated.SettingsRequestKind.ConfigureMouse,
        expectedRevision: capabilities.revision,
        mouse: generated.MouseConfigurationObjectBuilder(
          speed: capabilities.mouseSpeed,
        ),
      ),
      requestId: requestId,
    );
  }

  Uint8List encodeShortcutRead({required int requestId}) {
    if (requestId <= 0) {
      throw ArgumentError('invalid shortcut read request');
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: generated.SettingsRequestKind.ReadShortcuts,
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeShortcutValidation({
    required int requestId,
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) {
    if (requestId <= 0 ||
        !_validShortcutBindingWire(shortcut, emptyShortcutAllowed: true) ||
        (existingShortcut != null &&
            !_validShortcutWireString(existingShortcut))) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: generated.SettingsRequestKind.ValidateShortcut,
        shortcut: _shortcutBindingBuilder(shortcut),
        existingShortcut: existingShortcut,
      ),
      requestId: requestId,
    );
  }

  Uint8List? encodeShortcutMutation({
    required generated.SettingsRequestKind kind,
    required int requestId,
    required int expectedRevision,
    DenialShortcutBinding? shortcut,
    String? existingShortcut,
  }) {
    final shapeIsValid = switch (kind) {
      generated.SettingsRequestKind.AddShortcut =>
        shortcut != null && existingShortcut == null,
      generated.SettingsRequestKind.UpdateShortcut =>
        shortcut != null && existingShortcut != null,
      generated.SettingsRequestKind.RemoveShortcut =>
        shortcut == null && existingShortcut != null,
      generated.SettingsRequestKind.RestoreShortcuts =>
        shortcut == null && existingShortcut == null,
      _ => false,
    };
    if (!shapeIsValid ||
        requestId <= 0 ||
        expectedRevision <= 0 ||
        (shortcut != null &&
            !_validShortcutBindingWire(shortcut, emptyShortcutAllowed: true)) ||
        (existingShortcut != null &&
            !_validShortcutWireString(existingShortcut))) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.SettingsRequest,
      generated.SettingsRequestObjectBuilder(
        kind: kind,
        expectedRevision: expectedRevision,
        shortcut: shortcut == null ? null : _shortcutBindingBuilder(shortcut),
        existingShortcut: existingShortcut,
      ),
      requestId: requestId,
    );
  }

  DenialInputDeviceCapabilities? decodeInputDeviceCapabilities(
    generated.SettingsResponse response,
  ) {
    final inputDevices = response.inputDevices;
    final touchpad = inputDevices?.touchpad;
    final mouse = inputDevices?.mouse;
    final scrollSpeedFactor = touchpad?.scrollSpeedFactor;
    final mouseSpeed = mouse?.speed;
    if (!response.success ||
        response.kind != generated.SettingsResponseKind.InputDevices ||
        response.revision <= 0 ||
        inputDevices == null ||
        touchpad == null ||
        mouse == null ||
        scrollSpeedFactor == null ||
        mouseSpeed == null ||
        !scrollSpeedFactor.isFinite ||
        scrollSpeedFactor < touchpadScrollSpeedFactorMinimum ||
        scrollSpeedFactor > touchpadScrollSpeedFactorMaximum ||
        !mouseSpeed.isFinite ||
        mouseSpeed < mouseSpeedMinimum ||
        mouseSpeed > mouseSpeedMaximum) {
      rejectedStructuredMessages += 1;
      return null;
    }
    return DenialInputDeviceCapabilities(
      revision: response.revision,
      hasMouse: inputDevices.hasMouse,
      mouseSpeed: mouseSpeed,
      hasTouchpad: inputDevices.hasTouchpad,
      tapToClickEnabled: touchpad.tapToClickEnabled,
      naturalScrollEnabled: touchpad.naturalScrollEnabled,
      scrollSpeedFactor: scrollSpeedFactor,
    );
  }

  DenialKeyboardConfiguration? decodeKeyboardConfiguration(
    generated.SettingsResponse response,
  ) {
    final keyboard = response.keyboard;
    final sourceLayouts = keyboard?.layouts;
    final sourceOptions = keyboard?.options;
    if (response.kind != generated.SettingsResponseKind.Keyboard ||
        response.revision <= 0 ||
        keyboard == null ||
        sourceLayouts == null ||
        sourceLayouts.isEmpty ||
        sourceLayouts.length > 8 ||
        sourceOptions == null ||
        sourceOptions.length > 32 ||
        keyboard.activeLayout < 0 ||
        keyboard.activeLayout >= sourceLayouts.length ||
        keyboard.repeatDelayMs < 100 ||
        keyboard.repeatDelayMs > 5000 ||
        keyboard.repeatRateHz < 0 ||
        keyboard.repeatRateHz > 100) {
      rejectedStructuredMessages += 1;
      return null;
    }
    final layouts = <DenialKeyboardLayout>[];
    for (final source in sourceLayouts) {
      final layout = source.layout ?? '';
      final variant = source.variant ?? '';
      final displayName = source.displayName ?? '';
      if (!_validXkbName(layout, emptyAllowed: false) ||
          !_validXkbName(variant, emptyAllowed: true) ||
          utf8.encode(displayName).length > denialWireMaxStringLength) {
        rejectedStructuredMessages += 1;
        return null;
      }
      layouts.add(
        DenialKeyboardLayout(
          layout: layout,
          variant: variant,
          displayName: displayName,
        ),
      );
    }
    if (sourceOptions.any((option) => !_validXkbOption(option)) ||
        sourceOptions.toSet().length != sourceOptions.length) {
      rejectedStructuredMessages += 1;
      return null;
    }
    return DenialKeyboardConfiguration(
      revision: response.revision,
      layouts: List<DenialKeyboardLayout>.unmodifiable(layouts),
      options: List<String>.unmodifiable(sourceOptions),
      repeatDelayMs: keyboard.repeatDelayMs,
      repeatRateHz: keyboard.repeatRateHz,
      activeLayout: keyboard.activeLayout,
    );
  }

  DenialShortcutConfiguration? decodeShortcutConfiguration(
    generated.SettingsResponse response,
  ) {
    final configuration = response.shortcuts;
    final sourceShortcuts = configuration?.shortcuts;
    final sourceActions = configuration?.supportedActions;
    final sourceInputs = configuration?.supportedInputs;
    if (response.kind != generated.SettingsResponseKind.Shortcuts ||
        response.revision <= 0 ||
        configuration == null ||
        sourceShortcuts == null ||
        sourceShortcuts.length > _maxShortcutBindings ||
        sourceActions == null ||
        sourceActions.isEmpty ||
        sourceActions.length > DenialShortcutAction.values.length ||
        sourceInputs == null ||
        sourceInputs.length > _maxShortcutInputs) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final shortcuts = <DenialShortcutBinding>[];
    final shortcutIdentities = <String>{};
    for (final source in sourceShortcuts) {
      final binding = _decodeShortcutBinding(source);
      if (binding == null || !shortcutIdentities.add(binding.shortcut)) {
        rejectedStructuredMessages += 1;
        return null;
      }
      shortcuts.add(binding);
    }

    final actions = sourceActions.map(_shortcutActionFromWire).toList();
    if (actions.toSet().length != actions.length) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final inputs = <DenialShortcutInput>[];
    final inputIdentities = <String>{};
    for (final source in sourceInputs) {
      final canonical = source.canonical;
      final aliases = source.aliases;
      if (canonical == null ||
          !_validShortcutWireString(canonical) ||
          aliases == null ||
          aliases.any((alias) => !_validShortcutWireString(alias)) ||
          aliases.toSet().length != aliases.length ||
          !inputIdentities.add(canonical)) {
        rejectedStructuredMessages += 1;
        return null;
      }
      inputs.add(
        DenialShortcutInput(
          canonical: canonical,
          kind: _shortcutInputKindFromWire(source.kind),
          category: _shortcutInputCategoryFromWire(source.category),
          aliases: aliases,
        ),
      );
    }

    return DenialShortcutConfiguration(
      revision: response.revision,
      shortcuts: shortcuts,
      supportedActions: actions,
      supportedInputs: inputs,
    );
  }

  DenialShortcutValidation? decodeShortcutValidation(
    generated.SettingsResponse response,
  ) {
    final validation = response.shortcutValidation;
    if (!response.success ||
        response.kind != generated.SettingsResponseKind.ShortcutValidation ||
        response.revision <= 0 ||
        validation == null) {
      rejectedStructuredMessages += 1;
      return null;
    }
    final canonical = validation.canonical;
    final conflict = validation.conflict == null
        ? null
        : _decodeShortcutBinding(validation.conflict!);
    final error = validation.error;
    final kind = switch (validation.kind) {
      generated.ShortcutValidationKind.Valid =>
        DenialShortcutValidationKind.valid,
      generated.ShortcutValidationKind.Conflict =>
        DenialShortcutValidationKind.conflict,
      generated.ShortcutValidationKind.Invalid =>
        DenialShortcutValidationKind.invalid,
    };
    final shapeIsValid = switch (kind) {
      DenialShortcutValidationKind.valid =>
        canonical != null && conflict == null && error == null,
      DenialShortcutValidationKind.conflict =>
        canonical != null && conflict != null && error == null,
      DenialShortcutValidationKind.invalid =>
        canonical == null &&
            conflict == null &&
            error != null &&
            _validShortcutWireString(error),
    };
    if (!shapeIsValid ||
        (canonical != null && !_validShortcutWireString(canonical))) {
      rejectedStructuredMessages += 1;
      return null;
    }
    return DenialShortcutValidation(
      revision: response.revision,
      kind: kind,
      canonical: canonical,
      conflict: conflict,
      error: error,
    );
  }

  Uint8List? encodeNotificationCommand(
    generated.DesktopNotificationCommandKind kind,
    int notificationId, {
    String? actionKey,
  }) {
    if (notificationId <= 0 || notificationId > 0xffffffff) {
      return null;
    }
    final invokesNamedAction =
        kind == generated.DesktopNotificationCommandKind.InvokeAction;
    if (invokesNamedAction) {
      if (actionKey == null ||
          actionKey.isEmpty ||
          utf8.encode(actionKey).length > denialWireMaxStringLength) {
        return null;
      }
    } else if (actionKey != null && actionKey.isNotEmpty) {
      return null;
    }

    return _encodeEnvelope(
      generated.PayloadTypeId.DesktopNotificationCommand,
      generated.DesktopNotificationCommandObjectBuilder(
        kind: kind,
        notificationId: notificationId,
        actionKey: invokesNamedAction ? actionKey : null,
      ),
    );
  }

  Uint8List? encodeXEmbedTrayCommand(
    generated.XembedTrayCommandKind kind,
    int windowId,
    Offset position,
  ) {
    if (windowId <= 0 ||
        windowId > 0xffffffff ||
        !position.dx.isFinite ||
        !position.dy.isFinite) {
      return null;
    }
    final x = position.dx.round();
    final y = position.dy.round();
    if (x < -0x80000000 ||
        x > 0x7fffffff ||
        y < -0x80000000 ||
        y > 0x7fffffff) {
      return null;
    }
    return _encodeEnvelope(
      generated.PayloadTypeId.XEmbedTrayCommand,
      generated.XembedTrayCommandObjectBuilder(
        kind: kind,
        windowId: windowId,
        x: x,
        y: y,
      ),
    );
  }

  tray_model.XEmbedTrayEvent? decodeXEmbedTrayEvent(
    generated.XembedTrayEvent event,
  ) {
    if (event.windowId <= 0) {
      rejectedStructuredMessages += 1;
      return null;
    }
    final kind = switch (event.kind) {
      generated.XembedTrayEventKind.Added =>
        tray_model.XEmbedTrayEventKind.added,
      generated.XembedTrayEventKind.Updated =>
        tray_model.XEmbedTrayEventKind.updated,
      generated.XembedTrayEventKind.Removed =>
        tray_model.XEmbedTrayEventKind.removed,
    };
    if (kind == tray_model.XEmbedTrayEventKind.removed) {
      if (event.icon != null) {
        rejectedStructuredMessages += 1;
        return null;
      }
      return tray_model.XEmbedTrayEvent(kind: kind, windowId: event.windowId);
    }
    final icon = event.icon;
    final rgba = icon?.rgba;
    if (icon == null ||
        icon.windowId != event.windowId ||
        icon.width <= 0 ||
        icon.height <= 0 ||
        icon.width > 512 ||
        icon.height > 512 ||
        (icon.title?.length ?? 0) > denialWireMaxStringLength ||
        rgba == null ||
        rgba.length != icon.width * icon.height * 4 ||
        rgba.length > denialWireMaxTrayIconBytes) {
      rejectedStructuredMessages += 1;
      return null;
    }
    return tray_model.XEmbedTrayEvent(
      kind: kind,
      windowId: event.windowId,
      item: tray_model.SystemTrayItem(
        id: 'xembed:${event.windowId}',
        source: tray_model.SystemTrayItemSource.xEmbed,
        title: icon.title ?? 'X11 tray icon',
        status: tray_model.SystemTrayStatus.active,
        iconName: '',
        iconThemePath: '',
        iconPixmap: tray_model.SystemTrayIconPixmap(
          width: icon.width,
          height: icon.height,
          rgba: Uint8List.fromList(rgba),
        ),
        menuAvailable: true,
        primaryOpensMenu: false,
      ),
    );
  }

  DenialCursorState? decodeCursorState(generated.CursorState state) {
    final hotspot = state.hotspot;
    final shape = state.shape?.trim().toLowerCase() ?? '';
    final sourceLayers = state.surfaces ?? const <generated.SurfaceLayer>[];
    if (state.epoch <= 0 ||
        hotspot == null ||
        !hotspot.x.isFinite ||
        !hotspot.y.isFinite ||
        sourceLayers.length > denialWireMaxSurfaces) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final kind = switch (state.kind) {
      generated.CursorStateKind.Hidden => DenialCursorStateKind.hidden,
      generated.CursorStateKind.Named => DenialCursorStateKind.named,
      generated.CursorStateKind.Surface => DenialCursorStateKind.surface,
    };
    if ((kind == DenialCursorStateKind.named &&
            (shape.isEmpty || shape.length > denialWireMaxStringLength)) ||
        (kind != DenialCursorStateKind.named && shape.isNotEmpty) ||
        (kind != DenialCursorStateKind.surface && sourceLayers.isNotEmpty)) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final identities = <int>{};
    final layers = <DenialSurfaceLayer>[];
    var lastCompositionOrder = -1;
    for (var index = 0; index < sourceLayers.length; index += 1) {
      final layer = sourceLayers[index];
      final isRoot = index == 0;
      if (!_validSurfaceLayer(layer) ||
          layer.transform > 7 ||
          layer.scale120 <= 0 ||
          !identities.add(layer.surfaceId) ||
          layer.popupRootSurfaceId != 0 ||
          layer.compositionOrder < lastCompositionOrder ||
          (isRoot &&
              (layer.role != generated.SurfaceRole.Root ||
                  layer.parentSurfaceId != 0)) ||
          (!isRoot &&
              (layer.role != generated.SurfaceRole.Subsurface ||
                  layer.parentSurfaceId <= 0 ||
                  !identities.contains(layer.parentSurfaceId)))) {
        rejectedStructuredMessages += 1;
        return null;
      }
      lastCompositionOrder = layer.compositionOrder;
      layers.add(_decodeSurfaceLayer(layer));
    }
    return DenialCursorState(
      epoch: state.epoch,
      kind: kind,
      shape: shape,
      hotspot: Offset(hotspot.x, hotspot.y),
      surfaceLayers: List<DenialSurfaceLayer>.unmodifiable(layers),
    );
  }

  DenialDecodedEnvelope? decodeStructured(ByteData? data) {
    if (data == null ||
        data.lengthInBytes < 12 ||
        data.lengthInBytes > denialWireMaxBytes) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final bytes = Uint8List.view(
      data.buffer,
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes[4] != 0x44 ||
        bytes[5] != 0x45 ||
        bytes[6] != 0x4e ||
        bytes[7] != 0x57) {
      rejectedStructuredMessages += 1;
      return null;
    }

    try {
      final envelope = generated.Envelope(bytes);
      final payloadType = envelope.payloadType;
      final payload = envelope.payload;
      if (envelope.protocolVersion != denialWireVersion ||
          envelope.sequence <= 0 ||
          payloadType == null ||
          payloadType == generated.PayloadTypeId.NONE ||
          payload == null ||
          !_nativePayloadType(payloadType)) {
        rejectedStructuredMessages += 1;
        return null;
      }
      return DenialDecodedEnvelope(
        sequence: envelope.sequence,
        requestId: envelope.requestId,
        payloadType: payloadType,
        payload: payload as Object,
      );
    } on Object {
      rejectedStructuredMessages += 1;
      return null;
    }
  }

  DenialWindowPlacementEvent? decodePlacement(ByteData? data) {
    if (data == null || data.lengthInBytes != _placementPacketBytes) {
      rejectedPlacementPackets += 1;
      return null;
    }

    try {
      if (data.getUint8(0) != 0x44 ||
          data.getUint8(1) != 0x45 ||
          data.getUint8(2) != 0x4e ||
          data.getUint8(3) != 0x50 ||
          data.getUint16(4, Endian.little) != denialWireVersion ||
          data.getUint16(6, Endian.little) != 2 ||
          data.getUint32(8, Endian.little) != _placementPacketBytes ||
          data.getUint16(46, Endian.little) != 0) {
        rejectedPlacementPackets += 1;
        return null;
      }

      final sequence = data.getUint64(12, Endian.little);
      final windowId = data.getUint64(20, Endian.little);
      final monitorId = data.getInt64(28, Endian.little);
      final workspaceId = data.getInt64(36, Endian.little);
      final rawPhase = data.getUint8(44);
      final rawChange = data.getUint8(45);
      final x = data.getFloat64(48, Endian.little);
      final y = data.getFloat64(56, Endian.little);
      final width = data.getFloat64(64, Endian.little);
      final height = data.getFloat64(72, Endian.little);
      if (sequence <= _lastPlacementSequence ||
          windowId <= 0 ||
          monitorId < 0 ||
          workspaceId == -1 ||
          rawPhase > 2 ||
          rawChange > 2 ||
          !x.isFinite ||
          !y.isFinite ||
          !width.isFinite ||
          !height.isFinite ||
          width < 1.0 ||
          height < 1.0) {
        rejectedPlacementPackets += 1;
        return null;
      }
      _lastPlacementSequence = sequence;
      return DenialWindowPlacementEvent(
        sequence: sequence,
        windowId: windowId,
        contentRect: Rect.fromLTWH(x, y, width, height),
        monitorId: monitorId,
        workspaceId: workspaceId,
        phase: DenialWindowPlacementPhase.values[rawPhase],
        change: DenialWindowPlacementChange.values[rawChange],
      );
    } on Object {
      rejectedPlacementPackets += 1;
      return null;
    }
  }

  DenialDragIconUpdate? decodeDragIcon(ByteData? data) {
    if (data == null || data.lengthInBytes != _dragIconPacketBytes) {
      rejectedDragIconPackets += 1;
      return null;
    }

    try {
      if (data.getUint8(0) != 0x44 ||
          data.getUint8(1) != 0x45 ||
          data.getUint8(2) != 0x4e ||
          data.getUint8(3) != 0x44 ||
          data.getUint16(4, Endian.little) != denialWireVersion ||
          data.getUint16(6, Endian.little) != 3 ||
          data.getUint32(8, Endian.little) != _dragIconPacketBytes ||
          data.getUint32(24, Endian.little) != 0 ||
          data.getUint32(60, Endian.little) != 0) {
        rejectedDragIconPackets += 1;
        return null;
      }

      final sequence = data.getUint64(12, Endian.little);
      final flags = data.getUint32(20, Endian.little);
      if (sequence <= _lastDragIconSequence || (flags & ~1) != 0) {
        rejectedDragIconPackets += 1;
        return null;
      }

      if ((flags & 1) == 0) {
        _lastDragIconSequence = sequence;
        return DenialDragIconUpdate(sequence: sequence, icon: null);
      }

      final surfaceId = data.getUint64(28, Endian.little);
      final textureId = data.getUint64(36, Endian.little);
      final width = data.getUint32(44, Endian.little);
      final height = data.getUint32(48, Endian.little);
      final transform = data.getUint32(52, Endian.little);
      final scale120 = data.getUint32(56, Endian.little);
      final offsetX = data.getFloat64(64, Endian.little);
      final offsetY = data.getFloat64(72, Endian.little);
      final surfaceWidth = data.getFloat64(80, Endian.little);
      final surfaceHeight = data.getFloat64(88, Endian.little);
      final sourceX = data.getFloat64(96, Endian.little);
      final sourceY = data.getFloat64(104, Endian.little);
      final sourceWidth = data.getFloat64(112, Endian.little);
      final sourceHeight = data.getFloat64(120, Endian.little);
      if (surfaceId <= 0 ||
          textureId <= 0 ||
          textureId > 0x7fffffffffffffff ||
          width <= 0 ||
          height <= 0 ||
          transform > 7 ||
          scale120 <= 0 ||
          !offsetX.isFinite ||
          !offsetY.isFinite ||
          !surfaceWidth.isFinite ||
          !surfaceHeight.isFinite ||
          !sourceX.isFinite ||
          !sourceY.isFinite ||
          !sourceWidth.isFinite ||
          !sourceHeight.isFinite ||
          surfaceWidth <= 0 ||
          surfaceHeight <= 0 ||
          sourceX < 0 ||
          sourceY < 0 ||
          sourceWidth <= 0 ||
          sourceHeight <= 0 ||
          sourceX + sourceWidth > width ||
          sourceY + sourceHeight > height) {
        rejectedDragIconPackets += 1;
        return null;
      }

      _lastDragIconSequence = sequence;
      final layer = DenialSurfaceLayer(
        surfaceId: surfaceId,
        parentSurfaceId: 0,
        popupRootSurfaceId: 0,
        role: DenialSurfaceRole.root,
        textureId: textureId,
        width: width,
        height: height,
        surfaceX: 0,
        surfaceY: 0,
        surfaceWidth: surfaceWidth,
        surfaceHeight: surfaceHeight,
        textureSourceX: sourceX,
        textureSourceY: sourceY,
        textureSourceWidth: sourceWidth,
        textureSourceHeight: sourceHeight,
        transform: transform,
        scale120: scale120,
        compositionOrder: 0,
      );
      return DenialDragIconUpdate(
        sequence: sequence,
        icon: DenialDragIcon(
          sequence: sequence,
          surfaceId: surfaceId,
          offset: Offset(offsetX, offsetY),
          size: Size(surfaceWidth, surfaceHeight),
          layer: layer,
        ),
      );
    } on Object {
      rejectedDragIconPackets += 1;
      return null;
    }
  }

  model.DesktopNotificationEvent? decodeNotificationEvent(
    generated.DesktopNotificationEvent event,
  ) {
    if (event.notificationId <= 0) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final kind = switch (event.kind) {
      generated.DesktopNotificationEventKind.Added =>
        model.DesktopNotificationEventKind.added,
      generated.DesktopNotificationEventKind.Replaced =>
        model.DesktopNotificationEventKind.replaced,
      generated.DesktopNotificationEventKind.Closed =>
        model.DesktopNotificationEventKind.closed,
    };
    if (kind == model.DesktopNotificationEventKind.closed) {
      if (event.closeReason < 1 || event.closeReason > 4) {
        rejectedStructuredMessages += 1;
        return null;
      }
      return model.DesktopNotificationEvent(
        kind: kind,
        notificationId: event.notificationId,
        closeReason: event.closeReason,
      );
    }

    final source = event.notification;
    if (source == null || source.id != event.notificationId) {
      rejectedStructuredMessages += 1;
      return null;
    }
    final strings = <String>[
      source.sender ?? '',
      source.appName ?? '',
      source.appIcon ?? '',
      source.summary ?? '',
      source.body ?? '',
      source.category ?? '',
      source.desktopEntry ?? '',
      source.imagePath ?? '',
      source.soundName ?? '',
      source.soundFile ?? '',
    ];
    final sourceActions =
        source.actions ?? const <generated.DesktopNotificationAction>[];
    if (strings.any((value) => value.length > denialWireMaxStringLength) ||
        sourceActions.length > denialWireMaxNotificationActions) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final actions = <model.DesktopNotificationAction>[];
    for (final action in sourceActions) {
      final key = action.key ?? '';
      final label = action.label ?? '';
      if (key.length > denialWireMaxStringLength ||
          label.length > denialWireMaxStringLength) {
        rejectedStructuredMessages += 1;
        return null;
      }
      actions.add(model.DesktopNotificationAction(key: key, label: label));
    }

    model.DesktopNotificationImageData? image;
    final sourceImage = source.imageData;
    if (sourceImage != null) {
      final data = sourceImage.data ?? const <int>[];
      final expectedChannels = sourceImage.hasAlpha ? 4 : 3;
      final requiredBytes = sourceImage.rowStride * sourceImage.height;
      if (sourceImage.width <= 0 ||
          sourceImage.height <= 0 ||
          sourceImage.width > 4096 ||
          sourceImage.height > 4096 ||
          sourceImage.bitsPerSample != 8 ||
          sourceImage.channels != expectedChannels ||
          sourceImage.rowStride < sourceImage.width * sourceImage.channels ||
          requiredBytes <= 0 ||
          requiredBytes > denialWireMaxNotificationImageBytes ||
          data.length != requiredBytes) {
        rejectedStructuredMessages += 1;
        return null;
      }
      image = model.DesktopNotificationImageData(
        width: sourceImage.width,
        height: sourceImage.height,
        rowStride: sourceImage.rowStride,
        hasAlpha: sourceImage.hasAlpha,
        bitsPerSample: sourceImage.bitsPerSample,
        channels: sourceImage.channels,
        data: Uint8List.fromList(data),
      );
    }

    return model.DesktopNotificationEvent(
      kind: kind,
      notificationId: event.notificationId,
      closeReason: 0,
      notification: model.DesktopNotification(
        id: source.id,
        sender: source.sender ?? '',
        appName: source.appName ?? '',
        appIcon: source.appIcon ?? '',
        summary: source.summary ?? '',
        body: source.body ?? '',
        actions: List<model.DesktopNotificationAction>.unmodifiable(actions),
        urgency: switch (source.urgency) {
          generated.DesktopNotificationUrgency.Low =>
            model.DesktopNotificationUrgency.low,
          generated.DesktopNotificationUrgency.Normal =>
            model.DesktopNotificationUrgency.normal,
          generated.DesktopNotificationUrgency.Critical =>
            model.DesktopNotificationUrgency.critical,
        },
        category: source.category ?? '',
        desktopEntry: source.desktopEntry ?? '',
        imagePath: source.imagePath ?? '',
        imageData: image,
        resident: source.resident,
        transient: source.transient,
        suppressSound: source.suppressSound,
        actionIcons: source.actionIcons,
        soundName: source.soundName ?? '',
        soundFile: source.soundFile ?? '',
        x: source.x,
        y: source.y,
        hasPosition: source.hasPosition,
        progress: source.progress,
        hasProgress: source.hasProgress,
        expireTimeoutMs: source.expireTimeoutMs,
      ),
    );
  }

  List<DenialWindow>? decodeWindows(generated.WindowSnapshot snapshot) {
    final source = snapshot.windows ?? const <generated.Window>[];
    final restoredSource = snapshot.restoredWindowIds ?? const <int>[];
    final restoredWindowIds = <int>{};
    if (source.length > denialWireMaxWindows ||
        restoredSource.length > source.length ||
        restoredSource.any(
          (windowId) => windowId <= 0 || !restoredWindowIds.add(windowId),
        )) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final windows = <DenialWindow>[];
    final windowIds = <int>{};
    var surfaceCount = 0;
    for (final window in source) {
      final title = window.title ?? '';
      final appId = window.appId ?? '';
      if (window.objectId <= 0 ||
          window.surfaceId <= 0 ||
          window.windowId <= 0 ||
          !windowIds.add(window.windowId) ||
          window.width <= 0 ||
          window.height <= 0 ||
          title.length > denialWireMaxStringLength ||
          appId.length > denialWireMaxStringLength ||
          !_finiteWindow(window)) {
        rejectedStructuredMessages += 1;
        return null;
      }
      final sourceLayers = window.surfaces ?? const <generated.SurfaceLayer>[];
      final contentKind = switch (window.contentKind) {
        generated.WindowContentKind.SurfaceTree =>
          DenialWindowContentKind.surfaceTree,
        generated.WindowContentKind.LocalFlutter =>
          DenialWindowContentKind.localFlutter,
      };
      if (contentKind == DenialWindowContentKind.localFlutter &&
          (window.textureId != 0 || sourceLayers.isNotEmpty)) {
        rejectedStructuredMessages += 1;
        return null;
      }
      surfaceCount += sourceLayers.length;
      if (surfaceCount > denialWireMaxSurfaces) {
        rejectedStructuredMessages += 1;
        return null;
      }
      final surfaceIds = <int>{};
      final layers = <DenialSurfaceLayer>[];
      var lastCompositionOrder = -1;
      for (final layer in sourceLayers) {
        if (!_validSurfaceLayer(layer) ||
            !surfaceIds.add(layer.surfaceId) ||
            layer.compositionOrder < lastCompositionOrder) {
          rejectedStructuredMessages += 1;
          return null;
        }
        lastCompositionOrder = layer.compositionOrder;
        layers.add(
          DenialSurfaceLayer(
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
          ),
        );
      }
      windows.add(
        DenialWindow(
          objectId: window.objectId,
          objectKind: window.objectKind == generated.ObjectKind.Surface
              ? 'surface'
              : 'root_surface',
          surfaceId: window.surfaceId,
          windowId: window.windowId,
          textureId: window.textureId,
          title: title,
          appId: appId,
          width: window.width,
          height: window.height,
          surfaceX: window.surfaceX,
          surfaceY: window.surfaceY,
          surfaceWidth: window.surfaceWidth,
          surfaceHeight: window.surfaceHeight,
          textureSourceX: window.textureSourceX,
          textureSourceY: window.textureSourceY,
          textureSourceWidth: window.textureSourceWidth,
          textureSourceHeight: window.textureSourceHeight,
          geometryX: window.geometryX,
          geometryY: window.geometryY,
          geometryWidth: window.geometryWidth,
          geometryHeight: window.geometryHeight,
          monitorId: window.monitorId,
          transform: window.transform,
          scale120: window.scale120,
          pinned: window.pinned,
          suppressAnimations: window.suppressAnimations,
          restoredAcrossFlutterRestart: restoredWindowIds.contains(
            window.windowId,
          ),
          serverSideDecorated: window.serverSideDecorated,
          opacity: window.opacity,
          statusColorArgb: window.hasStatusColor
              ? window.statusColorArgb
              : null,
          contentX: window.contentX,
          contentY: window.contentY,
          contentWidth: window.contentWidth,
          contentHeight: window.contentHeight,
          surfaceLayers: List<DenialSurfaceLayer>.unmodifiable(layers),
          contentKind: contentKind,
          opacityClass: switch (window.opacityClass) {
            generated.WindowOpacityClass.BorderAlphaOnly =>
              DenialWindowOpacityClass.borderAlphaOnly,
            generated.WindowOpacityClass.FullyOpaque =>
              DenialWindowOpacityClass.fullyOpaque,
            generated.WindowOpacityClass.ContentTranslucent =>
              DenialWindowOpacityClass.contentTranslucent,
          },
        ),
      );
    }
    if (!windowIds.containsAll(restoredWindowIds)) {
      rejectedStructuredMessages += 1;
      return null;
    }
    return List<DenialWindow>.unmodifiable(windows);
  }

  DisplayLayout? decodeDisplayLayout(generated.DisplayLayout layout) {
    final origin = layout.globalOrigin;
    final logicalSize = layout.logicalSize;
    final pixelSize = layout.pixelSize;
    final sourceOutputs = layout.outputs ?? const <generated.DisplayOutput>[];
    if (origin == null ||
        logicalSize == null ||
        pixelSize == null ||
        sourceOutputs.length > denialWireMaxWindows ||
        !origin.x.isFinite ||
        !origin.y.isFinite ||
        !logicalSize.width.isFinite ||
        !logicalSize.height.isFinite ||
        !pixelSize.width.isFinite ||
        !pixelSize.height.isFinite ||
        !layout.engineScale.isFinite ||
        logicalSize.width <= 0.0 ||
        logicalSize.height <= 0.0 ||
        pixelSize.width <= 0.0 ||
        pixelSize.height <= 0.0 ||
        layout.engineScale <= 0.0 ||
        !layout.systemBarThickness.isFinite ||
        layout.systemBarThickness < 0.0 ||
        !layout.maximizePadding.isFinite ||
        layout.maximizePadding < 0.0) {
      rejectedStructuredMessages += 1;
      return null;
    }

    final outputs = <DisplayOutput>[];
    final outputIds = <int>{};
    for (final output in sourceOutputs) {
      final rect = output.logicalRect;
      final outputPixels = output.pixelSize;
      final name = output.name ?? '';
      if (rect == null ||
          outputPixels == null ||
          name.length > denialWireMaxStringLength ||
          !rect.x.isFinite ||
          !rect.y.isFinite ||
          !rect.width.isFinite ||
          !rect.height.isFinite ||
          !outputPixels.width.isFinite ||
          !outputPixels.height.isFinite ||
          !output.scale.isFinite ||
          !output.refreshRate.isFinite ||
          rect.width <= 0.0 ||
          rect.height <= 0.0 ||
          outputPixels.width <= 0.0 ||
          outputPixels.height <= 0.0 ||
          output.scale <= 0.0 ||
          output.refreshRate <= 0.0 ||
          output.monitorId < 0 ||
          !outputIds.add(output.monitorId)) {
        rejectedStructuredMessages += 1;
        return null;
      }
      outputs.add(
        DisplayOutput(
          monitorId: output.monitorId,
          name: name,
          logicalRect: Rect.fromLTWH(rect.x, rect.y, rect.width, rect.height),
          pixelSize: Size(outputPixels.width, outputPixels.height),
          scale: output.scale,
          refreshRate: output.refreshRate,
        ),
      );
    }

    final encodedMonitorIds = layout.systemBarMonitorIds;
    final systemBarMonitorIds =
        encodedMonitorIds == null || encodedMonitorIds.isEmpty
        ? layout.systemBarMonitorId < 0
              ? const <int>[]
              : <int>[layout.systemBarMonitorId]
        : List<int>.of(encodedMonitorIds);
    if (systemBarMonitorIds.length > outputs.length ||
        systemBarMonitorIds.any(
          (monitorId) => !outputIds.contains(monitorId),
        ) ||
        systemBarMonitorIds.toSet().length != systemBarMonitorIds.length) {
      rejectedStructuredMessages += 1;
      return null;
    }

    return DisplayLayout(
      epoch: layout.epoch,
      globalOrigin: Offset(origin.x, origin.y),
      logicalSize: Size(logicalSize.width, logicalSize.height),
      pixelSize: Size(pixelSize.width, pixelSize.height),
      engineScale: layout.engineScale,
      tickerMonitorId: layout.tickerMonitorId,
      systemBarMonitorId: layout.systemBarMonitorId,
      systemBarMonitorIds: List<int>.unmodifiable(systemBarMonitorIds),
      systemBarSide: switch (layout.systemBarSide) {
        generated.SystemBarSide.Right => SystemBarSide.right,
        generated.SystemBarSide.Top => SystemBarSide.top,
        generated.SystemBarSide.Bottom => SystemBarSide.bottom,
        generated.SystemBarSide.Hidden => SystemBarSide.hidden,
        generated.SystemBarSide.Left => SystemBarSide.left,
      },
      systemBarThickness: layout.systemBarThickness,
      maximizePadding: layout.maximizePadding,
      outputs: List<DisplayOutput>.unmodifiable(outputs),
    );
  }

  Uint8List _encodeEnvelope(
    generated.PayloadTypeId payloadType,
    fb.ObjectBuilder payload, {
    int requestId = 0,
  }) {
    final bytes = generated.EnvelopeObjectBuilder(
      protocolVersion: denialWireVersion,
      sequence: _takeSequence(),
      requestId: requestId,
      payloadType: payloadType,
      payload: payload,
    ).toBytes('DENW');
    if (bytes.length > denialWireMaxBytes) {
      throw StateError('Denial wire message exceeds 1 MiB');
    }
    return bytes;
  }

  int _takeSequence() {
    final sequence = _nextSequence;
    _nextSequence = sequence >= 0x7ffffffffffffffe ? 1 : sequence + 1;
    return sequence;
  }
}
