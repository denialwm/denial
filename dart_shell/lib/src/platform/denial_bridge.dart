import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../input/input_layout.dart';
import '../models/denial_drag_icon.dart';
import '../models/desktop_notification.dart';
import '../models/display_layout.dart';
import '../models/input_device_capabilities.dart';
import '../models/keyboard_configuration.dart';
import '../models/output_configuration.dart';
import '../models/shortcut_configuration.dart';
import '../models/system_tray_item.dart';
import '../models/denial_window.dart';
import '../models/denial_window_event.dart';
import '../models/denial_window_snapshot.dart';
import '../models/ui_development.dart';
import 'denial_wire.dart' as wire;
import 'ui_development_protocol.dart';

enum DenialShellAction {
  applications,
  overview,
  windowSwitcherNext,
  windowSwitcherEnd,
  clipboard,
  screenshotPrepare,
  screenshotTextureReady,
  screenshotDone,
  clientPointerPressed,
  wallpaper,
}

class DenialShellActionEvent {
  const DenialShellActionEvent({
    required this.action,
    required this.monitorId,
    required this.requestId,
    required this.textureId,
  });

  final DenialShellAction action;
  final int? monitorId;
  final int requestId;
  final int? textureId;
}

class DenialAudioState {
  const DenialAudioState({
    required this.level,
    required this.requestSerial,
    this.completesRead = false,
  });

  final double level;
  final int requestSerial;

  /// Whether this update satisfied an explicit state read from Dart.
  ///
  /// Reconciliation reads update controls but should not look like a fresh
  /// hardware-key interaction to transient shell surfaces.
  final bool completesRead;
}

class DenialAudioStream {
  const DenialAudioStream({
    required this.id,
    required this.name,
    required this.level,
    required this.muted,
  });

  final int id;
  final String name;
  final double level;
  final bool muted;
}

class DenialBrightnessState {
  const DenialBrightnessState({required this.monitorId, required this.level});

  final int monitorId;
  final double level;
}

class DenialTextInputState {
  const DenialTextInputState({
    required this.active,
    required this.inputPanelVisible,
    required this.legacy,
    required this.contentHint,
    required this.contentPurpose,
  });

  final bool active;
  final bool inputPanelVisible;
  final bool legacy;
  final int contentHint;
  final int contentPurpose;
}

class DenialSettingsDocument {
  const DenialSettingsDocument({required this.revision, required this.json});

  final int revision;
  final String json;
}

class DenialBridge {
  static const String _hapticsChannel = 'denial/haptics';
  static const String _audioChannel = 'denial/audio';
  static const String _brightnessChannel = 'denial/brightness';
  static const String _idlePolicyChannel = 'denial/idle_policy';
  static const String _displayPowerChannel = 'denial/display_power';
  static const String _systemCommandChannel = 'denial/system_command';
  static const String _windowCloseCompleteChannel =
      'denial/window_close_complete';
  static const String _audioStateChannel = 'denial/audio_state';
  static const String _audioStreamsStateChannel = 'denial/audio_streams_state';
  static const String _brightnessStateChannel = 'denial/brightness_state';
  static final Uint8List _hapticPrewarmPayload = Uint8List.fromList(const <int>[
    0,
  ]);
  static final Uint8List _hapticTapPayload = Uint8List.fromList(const <int>[1]);
  static final ByteData _hapticPrewarmData = ByteData.sublistView(
    _hapticPrewarmPayload,
  );
  static final ByteData _hapticTapData = ByteData.sublistView(
    _hapticTapPayload,
  );
  static const int _launchApplicationCommand = 0;
  static const int _takeScreenshotCommand = 2;
  static const int _logoutCommand = 3;
  static const int _screenshotPreparedCommand = 4;
  static const int _cancelScreenshotCommand = 5;
  static const int _systemCommandHeaderBytes = 1 + 8 + 4;
  static const int _maxSystemCommandBytes = 64 * 1024;
  static const int _maxSystemCommandArguments = 64;
  static const int _maxSystemCommandArgumentBytes = 4096;
  static const int _maxOutputControlBytes = 256 * 1024;
  static const Duration _outputControlTimeout = Duration(seconds: 20);

  DenialBridge({this.useControlSocket = false, this.controlSocketPath}) {
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _audioStateChannel,
      _handleAudioStateMessage,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _audioStreamsStateChannel,
      _handleAudioStreamsStateMessage,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _brightnessStateChannel,
      _handleBrightnessStateMessage,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      denialUiDevelopmentStateChannel,
      _handleUiDevelopmentStateMessage,
    );
  }

  final bool useControlSocket;
  final String? controlSocketPath;

  final Map<int, Completer<DenialWindowSnapshot>> _pendingWindowRequests = {};
  final Map<int, Completer<DisplayLayout?>> _pendingDisplayRequests = {};
  final Map<int, Completer<DenialSettingsDocument>>
  _pendingSettingsDocumentRequests = {};
  final Map<int, Completer<DenialKeyboardConfiguration>>
  _pendingKeyboardSettingsRequests = {};
  final Map<int, Completer<DenialInputDeviceCapabilities>>
  _pendingInputDeviceRequests = {};
  final Map<int, Completer<DenialShortcutConfiguration>>
  _pendingShortcutRequests = {};
  final Map<int, Completer<DenialShortcutValidation>>
  _pendingShortcutValidationRequests = {};
  final Set<Completer<double?>> _pendingAudioReads = {};
  final StreamController<DenialWindowEvent> _windowEvents =
      StreamController<DenialWindowEvent>.broadcast(sync: true);
  final StreamController<DenialShellActionEvent> _shellActions =
      StreamController<DenialShellActionEvent>.broadcast(sync: true);
  final StreamController<String> _cursorShapes =
      StreamController<String>.broadcast(sync: true);
  final StreamController<Offset> _cursorPositions =
      StreamController<Offset>.broadcast(sync: true);
  final StreamController<DenialDragIcon?> _dragIcons =
      StreamController<DenialDragIcon?>.broadcast(sync: true);
  final StreamController<DenialAudioState> _audioStates =
      StreamController<DenialAudioState>.broadcast(sync: true);
  final StreamController<List<DenialAudioStream>> _audioStreamStates =
      StreamController<List<DenialAudioStream>>.broadcast(sync: true);
  final StreamController<DenialBrightnessState> _brightnessStates =
      StreamController<DenialBrightnessState>.broadcast(sync: true);
  final StreamController<DesktopNotificationEvent> _notificationEvents =
      StreamController<DesktopNotificationEvent>.broadcast(sync: true);
  final StreamController<XEmbedTrayEvent> _xembedTrayEvents =
      StreamController<XEmbedTrayEvent>.broadcast(sync: true);
  final Map<int, SystemTrayItem> _xembedTrayItems = <int, SystemTrayItem>{};
  final StreamController<DenialUiDevelopmentState> _uiDevelopmentStates =
      StreamController<DenialUiDevelopmentState>.broadcast(sync: true);
  final StreamController<DenialKeyboardConfiguration> _keyboardConfigurations =
      StreamController<DenialKeyboardConfiguration>.broadcast(sync: true);
  final StreamController<DenialInputDeviceCapabilities>
  _inputDeviceCapabilities =
      StreamController<DenialInputDeviceCapabilities>.broadcast(sync: true);
  final StreamController<DenialShortcutConfiguration> _shortcutConfigurations =
      StreamController<DenialShortcutConfiguration>.broadcast(sync: true);
  final StreamController<DenialTextInputState> _textInputStates =
      StreamController<DenialTextInputState>.broadcast(sync: true);
  final StreamController<DenialSettingsDocument> _settingsDocuments =
      StreamController<DenialSettingsDocument>.broadcast(sync: true);
  final StreamController<DisplayLayout> _displayLayouts =
      StreamController<DisplayLayout>.broadcast(sync: true);
  final wire.DenialWireCodec _wireCodec = wire.DenialWireCodec();
  final DenialUiDevelopmentProtocol _uiDevelopmentProtocol =
      DenialUiDevelopmentProtocol();
  int _nextRequestId = 1;
  VoidCallback? _onWindowsChanged;
  ValueChanged<DenialWindowSnapshot>? _onWindowSnapshot;
  ValueChanged<int>? _onWindowActivated;

  Stream<DenialWindowEvent> get windowEvents => _windowEvents.stream;
  Stream<DenialShellActionEvent> get shellActions => _shellActions.stream;
  Stream<String> get cursorShapes => _cursorShapes.stream;
  Stream<Offset> get cursorPositions => _cursorPositions.stream;
  Stream<DenialDragIcon?> get dragIcons => _dragIcons.stream;
  Stream<DenialAudioState> get audioStates => _audioStates.stream;
  Stream<List<DenialAudioStream>> get audioStreamStates =>
      _audioStreamStates.stream;
  Stream<DenialBrightnessState> get brightnessStates =>
      _brightnessStates.stream;
  Stream<DesktopNotificationEvent> get notificationEvents =>
      _notificationEvents.stream;
  Stream<XEmbedTrayEvent> get xembedTrayEvents => _xembedTrayEvents.stream;
  Map<int, SystemTrayItem> get xembedTrayItems =>
      Map<int, SystemTrayItem>.unmodifiable(_xembedTrayItems);
  Stream<DenialUiDevelopmentState> get uiDevelopmentStates =>
      _uiDevelopmentStates.stream;
  Stream<DenialKeyboardConfiguration> get keyboardConfigurations =>
      _keyboardConfigurations.stream;
  Stream<DenialInputDeviceCapabilities> get inputDeviceCapabilities =>
      _inputDeviceCapabilities.stream;
  Stream<DenialShortcutConfiguration> get shortcutConfigurations =>
      _shortcutConfigurations.stream;
  Stream<DenialTextInputState> get textInputStates => _textInputStates.stream;
  Stream<DenialSettingsDocument> get settingsDocuments =>
      _settingsDocuments.stream;
  Stream<DisplayLayout> get displayLayouts => _displayLayouts.stream;

  void start({
    required VoidCallback onWindowsChanged,
    ValueChanged<DenialWindowSnapshot>? onWindowSnapshot,
    required ValueChanged<int> onWindowActivated,
  }) {
    _onWindowsChanged = onWindowsChanged;
    _onWindowSnapshot = onWindowSnapshot;
    _onWindowActivated = onWindowActivated;
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      wire.denialWireToFlutterChannel,
      _handleWireMessage,
    );
  }

  void dispose() {
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      wire.denialWireToFlutterChannel,
      null,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _audioStateChannel,
      null,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _audioStreamsStateChannel,
      null,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _brightnessStateChannel,
      null,
    );
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      denialUiDevelopmentStateChannel,
      null,
    );
    for (final completer in _pendingWindowRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingWindowRequests.clear();
    for (final completer in _pendingDisplayRequests.values) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    _pendingDisplayRequests.clear();
    for (final completer in _pendingSettingsDocumentRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingSettingsDocumentRequests.clear();
    for (final completer in _pendingKeyboardSettingsRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingKeyboardSettingsRequests.clear();
    for (final completer in _pendingInputDeviceRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingInputDeviceRequests.clear();
    for (final completer in _pendingShortcutRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingShortcutRequests.clear();
    for (final completer in _pendingShortcutValidationRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingShortcutValidationRequests.clear();
    for (final completer in _pendingAudioReads) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    _pendingAudioReads.clear();
    _onWindowsChanged = null;
    _onWindowSnapshot = null;
    _onWindowActivated = null;
    unawaited(_windowEvents.close());
    unawaited(_shellActions.close());
    unawaited(_cursorShapes.close());
    unawaited(_cursorPositions.close());
    unawaited(_dragIcons.close());
    unawaited(_audioStates.close());
    unawaited(_audioStreamStates.close());
    unawaited(_brightnessStates.close());
    unawaited(_notificationEvents.close());
    unawaited(_xembedTrayEvents.close());
    unawaited(_uiDevelopmentStates.close());
    unawaited(_keyboardConfigurations.close());
    unawaited(_inputDeviceCapabilities.close());
    unawaited(_shortcutConfigurations.close());
    unawaited(_textInputStates.close());
    unawaited(_settingsDocuments.close());
    unawaited(_displayLayouts.close());
  }

  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) {
    final requestId = _nextRequestId++;
    final completer = Completer<DenialWindowSnapshot>();
    _pendingWindowRequests[requestId] = completer;

    final bytes = _wireCodec.encodeWindowRequest(
      wire.WindowRequestKind.ListWindows,
      requestId: requestId,
    );
    final response = ServicesBinding.instance.defaultBinaryMessenger.send(
      wire.denialWireToNativeChannel,
      ByteData.sublistView(bytes),
    );
    response?.catchError((Object error) {
      final pending = _pendingWindowRequests.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(error);
      }
      return null;
    });

    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingWindowRequests.remove(requestId);
        return DenialWindowSnapshot(sequence: 0, windows: fallback);
      },
    );
  }

  Future<DisplayLayout?> getDisplayLayout() async {
    if (!useControlSocket) {
      return _getDisplayLayoutFromPlatform();
    }
    try {
      final configuration = DenialOutputConfiguration.fromJson(
        await _sendControlRequest('outputs.get'),
      );
      final enabled = configuration.outputs
          .where(
            (output) =>
                output.enabled &&
                output.logicalWidth > 0 &&
                output.logicalHeight > 0,
          )
          .toList(growable: false);
      if (enabled.isEmpty) {
        return null;
      }

      var originX = enabled.first.x.toDouble();
      var originY = enabled.first.y.toDouble();
      var right = originX + enabled.first.logicalWidth;
      var bottom = originY + enabled.first.logicalHeight;
      var engineScale = enabled.first.scale;
      for (final output in enabled.skip(1)) {
        final x = output.x.toDouble();
        final y = output.y.toDouble();
        if (x < originX) originX = x;
        if (y < originY) originY = y;
        final outputRight = x + output.logicalWidth;
        final outputBottom = y + output.logicalHeight;
        if (outputRight > right) right = outputRight;
        if (outputBottom > bottom) bottom = outputBottom;
        if (output.scale > engineScale) engineScale = output.scale;
      }

      final outputs = enabled
          .map((output) {
            final mode = output.effectiveMode;
            final pixelWidth = output.transform.swapsAxes
                ? mode.height
                : mode.width;
            final pixelHeight = output.transform.swapsAxes
                ? mode.width
                : mode.height;
            return DisplayOutput(
              monitorId: output.monitorId,
              name: output.name,
              logicalRect: Rect.fromLTWH(
                output.x - originX,
                output.y - originY,
                output.logicalWidth.toDouble(),
                output.logicalHeight.toDouble(),
              ),
              pixelSize: Size(pixelWidth.toDouble(), pixelHeight.toDouble()),
              scale: output.scale,
              refreshRate: mode.refreshHz,
            );
          })
          .toList(growable: false);
      final primary = outputs.firstWhere(
        (output) => output.name == configuration.primaryOutput,
        orElse: () => outputs.first,
      );
      final logicalSize = Size(right - originX, bottom - originY);
      final layout = DisplayLayout(
        epoch: configuration.serial,
        globalOrigin: Offset(originX, originY),
        logicalSize: logicalSize,
        pixelSize: logicalSize * engineScale,
        engineScale: engineScale,
        tickerMonitorId: primary.monitorId,
        systemBarMonitorId: primary.monitorId,
        systemBarMonitorIds: <int>[primary.monitorId],
        systemBarSide: SystemBarSide.top,
        systemBarThickness: 32.0,
        maximizePadding: 10.0,
        outputs: outputs,
      );
      if (!_displayLayouts.isClosed) {
        _displayLayouts.add(layout);
      }
      return layout;
    } on Object {
      return null;
    }
  }

  Future<DisplayLayout?> _getDisplayLayoutFromPlatform() {
    final requestId = _nextRequestId++;
    final completer = Completer<DisplayLayout?>();
    _pendingDisplayRequests[requestId] = completer;
    _sendWire(
      _wireCodec.encodeWindowRequest(
        wire.WindowRequestKind.GetDisplayLayout,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingDisplayRequests.remove(requestId);
        return null;
      },
    );
  }

  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
  }) {
    final requestId = _nextRequestId++;
    final bytes = _wireCodec.encodeSystemBarConfiguration(
      requestId: requestId,
      side: side,
      monitorIds: monitorIds,
    );
    if (bytes == null) {
      return Future<DisplayLayout?>.value(null);
    }
    final completer = Completer<DisplayLayout?>();
    _pendingDisplayRequests[requestId] = completer;
    _sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingDisplayRequests.remove(requestId);
        return null;
      },
    );
  }

  Future<DenialSettingsDocument> readSettingsDocument() async {
    if (!useControlSocket) return _readSettingsDocumentFromPlatform();
    try {
      return _settingsDocumentFromControl(
        await _sendControlRequest('settings.document.get'),
      );
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  Future<void> openWallpaperSelector() async {
    try {
      await _sendControlRequest('shell.wallpaper.open');
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  Future<DenialSettingsDocument> writeSettingsDocument({
    required int expectedRevision,
    required String document,
  }) async {
    if (expectedRevision <= 0 ||
        document.isEmpty ||
        utf8.encode(document).length >
            wire.denialWireMaxSettingsDocumentBytes) {
      throw ArgumentError('invalid Denial settings document');
    }
    if (!useControlSocket) {
      return _writeSettingsDocumentToPlatform(
        expectedRevision: expectedRevision,
        document: document,
      );
    }
    try {
      return _settingsDocumentFromControl(
        await _sendControlRequest(
          'settings.document.apply',
          parameters: <String, Object>{
            'expected_revision': expectedRevision,
            'document': document,
          },
        ),
      );
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  DenialSettingsDocument _settingsDocumentFromControl(
    Map<String, Object?> result,
  ) {
    final revision = result['revision'];
    final document = result['document'];
    if (revision is! int ||
        revision <= 0 ||
        document is! String ||
        document.isEmpty ||
        utf8.encode(document).length >
            wire.denialWireMaxSettingsDocumentBytes) {
      throw StateError('Denial returned an invalid settings document');
    }
    return DenialSettingsDocument(revision: revision, json: document);
  }

  Future<DenialKeyboardConfiguration> readKeyboardConfiguration() async {
    if (!useControlSocket) return _readKeyboardConfigurationFromPlatform();
    final configuration = DenialKeyboardConfiguration.fromJson(
      await _sendSettingsControlRequest('settings.keyboard.get'),
    );
    _keyboardConfigurations.add(configuration);
    return configuration;
  }

  Future<DenialInputDeviceCapabilities> readInputDeviceCapabilities() async {
    if (!useControlSocket) {
      return _readInputDeviceCapabilitiesFromPlatform();
    }
    final capabilities = DenialInputDeviceCapabilities.fromJson(
      await _sendSettingsControlRequest('settings.input.get'),
    );
    _inputDeviceCapabilities.add(capabilities);
    return capabilities;
  }

  Future<DenialInputDeviceCapabilities> configureTouchpad(
    DenialInputDeviceCapabilities capabilities,
  ) async {
    if (!useControlSocket) {
      return _configureTouchpadThroughPlatform(capabilities);
    }
    final applied = DenialInputDeviceCapabilities.fromJson(
      await _sendSettingsControlRequest(
        'settings.touchpad.apply',
        parameters: <String, Object>{
          'expected_revision': capabilities.revision,
          'touchpad': capabilities.toApplyJson(),
        },
      ),
    );
    _inputDeviceCapabilities.add(applied);
    return applied;
  }

  Future<DenialKeyboardConfiguration> configureKeyboard(
    DenialKeyboardConfiguration configuration,
  ) async {
    if (!useControlSocket) {
      return _configureKeyboardThroughPlatform(configuration);
    }
    final applied = DenialKeyboardConfiguration.fromJson(
      await _sendSettingsControlRequest(
        'settings.keyboard.apply',
        parameters: <String, Object>{
          'expected_revision': configuration.revision,
          'keyboard': configuration.toApplyJson(),
        },
      ),
    );
    _keyboardConfigurations.add(applied);
    return applied;
  }

  Future<DenialShortcutConfiguration> readShortcutConfiguration() async {
    if (!useControlSocket) return _readShortcutsFromPlatform();
    final configuration = DenialShortcutConfiguration.fromJson(
      await _sendSettingsControlRequest('settings.shortcuts.get'),
    );
    _shortcutConfigurations.add(configuration);
    return configuration;
  }

  Future<DenialShortcutValidation> validateShortcut({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) async {
    if (!useControlSocket) {
      return _validateShortcutThroughPlatform(
        shortcut: shortcut,
        existingShortcut: existingShortcut,
      );
    }
    return DenialShortcutValidation.fromJson(
      await _sendSettingsControlRequest(
        'settings.shortcuts.validate',
        parameters: <String, Object>{
          'shortcut': shortcut.toJson(),
          'existing_shortcut': ?existingShortcut,
        },
      ),
    );
  }

  Future<DenialShortcutConfiguration> addShortcut({
    required int expectedRevision,
    required DenialShortcutBinding shortcut,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.AddShortcut,
      expectedRevision: expectedRevision,
      shortcut: shortcut,
    );
  }

  Future<DenialShortcutConfiguration> updateShortcut({
    required int expectedRevision,
    required String existingShortcut,
    required DenialShortcutBinding shortcut,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.UpdateShortcut,
      expectedRevision: expectedRevision,
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
  }

  Future<DenialShortcutConfiguration> removeShortcut({
    required int expectedRevision,
    required String shortcut,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.RemoveShortcut,
      expectedRevision: expectedRevision,
      existingShortcut: shortcut,
    );
  }

  Future<DenialShortcutConfiguration> restoreDefaultShortcuts({
    required int expectedRevision,
  }) {
    return _mutateShortcuts(
      kind: wire.SettingsRequestKind.RestoreShortcuts,
      expectedRevision: expectedRevision,
    );
  }

  Future<DenialShortcutConfiguration> _mutateShortcuts({
    required wire.SettingsRequestKind kind,
    required int expectedRevision,
    DenialShortcutBinding? shortcut,
    String? existingShortcut,
  }) async {
    if (!useControlSocket) {
      return _mutateShortcutsThroughPlatform(
        kind: kind,
        expectedRevision: expectedRevision,
        shortcut: shortcut,
        existingShortcut: existingShortcut,
      );
    }
    final method = switch (kind) {
      wire.SettingsRequestKind.AddShortcut => 'settings.shortcuts.add',
      wire.SettingsRequestKind.UpdateShortcut => 'settings.shortcuts.update',
      wire.SettingsRequestKind.RemoveShortcut => 'settings.shortcuts.remove',
      wire.SettingsRequestKind.RestoreShortcuts => 'settings.shortcuts.restore',
      _ => throw ArgumentError.value(kind, 'kind', 'invalid shortcut mutation'),
    };
    final parameters = <String, Object>{
      'expected_revision': expectedRevision,
      if (shortcut != null) 'shortcut': shortcut.toJson(),
    };
    if (existingShortcut != null) {
      parameters[kind == wire.SettingsRequestKind.RemoveShortcut
              ? 'shortcut'
              : 'existing_shortcut'] =
          existingShortcut;
    }
    final configuration = DenialShortcutConfiguration.fromJson(
      await _sendSettingsControlRequest(method, parameters: parameters),
    );
    _shortcutConfigurations.add(configuration);
    return configuration;
  }

  Future<Map<String, Object?>> _sendSettingsControlRequest(
    String method, {
    Map<String, Object>? parameters,
  }) async {
    try {
      return await _sendControlRequest(method, parameters: parameters);
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
  }

  Future<DenialSettingsDocument> _readSettingsDocumentFromPlatform() {
    final requestId = _nextRequestId++;
    final completer = Completer<DenialSettingsDocument>();
    _pendingSettingsDocumentRequests[requestId] = completer;
    _sendWire(
      _wireCodec.encodeSettingsRead(
        wire.SettingsRequestKind.ReadDocument,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingSettingsDocumentRequests.remove(requestId);
        throw TimeoutException('Denial settings read timed out');
      },
    );
  }

  Future<DenialSettingsDocument> _writeSettingsDocumentToPlatform({
    required int expectedRevision,
    required String document,
  }) {
    final requestId = _nextRequestId++;
    final bytes = _wireCodec.encodeSettingsDocumentWrite(
      requestId: requestId,
      expectedRevision: expectedRevision,
      document: document,
    );
    if (bytes == null) {
      return Future<DenialSettingsDocument>.error(
        ArgumentError('invalid Denial settings document'),
      );
    }
    final completer = Completer<DenialSettingsDocument>();
    _pendingSettingsDocumentRequests[requestId] = completer;
    _sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingSettingsDocumentRequests.remove(requestId);
        throw TimeoutException('Denial settings write timed out');
      },
    );
  }

  Future<DenialKeyboardConfiguration> _readKeyboardConfigurationFromPlatform() {
    final requestId = _nextRequestId++;
    final completer = Completer<DenialKeyboardConfiguration>();
    _pendingKeyboardSettingsRequests[requestId] = completer;
    _sendWire(
      _wireCodec.encodeSettingsRead(
        wire.SettingsRequestKind.ReadKeyboard,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingKeyboardSettingsRequests.remove(requestId);
        throw TimeoutException('Denial keyboard settings read timed out');
      },
    );
  }

  Future<DenialInputDeviceCapabilities>
  _readInputDeviceCapabilitiesFromPlatform() {
    final requestId = _nextRequestId++;
    final completer = Completer<DenialInputDeviceCapabilities>();
    _pendingInputDeviceRequests[requestId] = completer;
    _sendWire(
      _wireCodec.encodeSettingsRead(
        wire.SettingsRequestKind.ReadInputDevices,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingInputDeviceRequests.remove(requestId);
        throw TimeoutException('Denial input device detection timed out');
      },
    );
  }

  Future<DenialInputDeviceCapabilities> _configureTouchpadThroughPlatform(
    DenialInputDeviceCapabilities capabilities,
  ) {
    final requestId = _nextRequestId++;
    final bytes = _wireCodec.encodeTouchpadConfiguration(
      requestId: requestId,
      capabilities: capabilities,
    );
    if (bytes == null) {
      return Future<DenialInputDeviceCapabilities>.error(
        ArgumentError('invalid Denial touchpad configuration'),
      );
    }
    final completer = Completer<DenialInputDeviceCapabilities>();
    _pendingInputDeviceRequests[requestId] = completer;
    _sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingInputDeviceRequests.remove(requestId);
        throw TimeoutException('Denial touchpad settings update timed out');
      },
    );
  }

  Future<DenialKeyboardConfiguration> _configureKeyboardThroughPlatform(
    DenialKeyboardConfiguration configuration,
  ) {
    final requestId = _nextRequestId++;
    final bytes = _wireCodec.encodeKeyboardConfiguration(
      requestId: requestId,
      configuration: configuration,
    );
    if (bytes == null) {
      return Future<DenialKeyboardConfiguration>.error(
        ArgumentError('invalid Denial keyboard configuration'),
      );
    }
    final completer = Completer<DenialKeyboardConfiguration>();
    _pendingKeyboardSettingsRequests[requestId] = completer;
    _sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingKeyboardSettingsRequests.remove(requestId);
        throw TimeoutException('Denial keyboard settings update timed out');
      },
    );
  }

  Future<DenialShortcutConfiguration> _readShortcutsFromPlatform() {
    final requestId = _nextRequestId++;
    final completer = Completer<DenialShortcutConfiguration>();
    _pendingShortcutRequests[requestId] = completer;
    _sendWire(_wireCodec.encodeShortcutRead(requestId: requestId));
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingShortcutRequests.remove(requestId);
        throw TimeoutException('Denial shortcut settings read timed out');
      },
    );
  }

  Future<DenialShortcutValidation> _validateShortcutThroughPlatform({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) {
    final requestId = _nextRequestId++;
    final bytes = _wireCodec.encodeShortcutValidation(
      requestId: requestId,
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
    if (bytes == null) {
      return Future<DenialShortcutValidation>.error(
        ArgumentError('shortcut validation request exceeds wire bounds'),
      );
    }
    final completer = Completer<DenialShortcutValidation>();
    _pendingShortcutValidationRequests[requestId] = completer;
    _sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingShortcutValidationRequests.remove(requestId);
        throw TimeoutException('Denial shortcut validation timed out');
      },
    );
  }

  Future<DenialShortcutConfiguration> _mutateShortcutsThroughPlatform({
    required wire.SettingsRequestKind kind,
    required int expectedRevision,
    DenialShortcutBinding? shortcut,
    String? existingShortcut,
  }) {
    final requestId = _nextRequestId++;
    final bytes = _wireCodec.encodeShortcutMutation(
      kind: kind,
      requestId: requestId,
      expectedRevision: expectedRevision,
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
    if (bytes == null) {
      return Future<DenialShortcutConfiguration>.error(
        ArgumentError('shortcut mutation request exceeds wire bounds'),
      );
    }
    final completer = Completer<DenialShortcutConfiguration>();
    _pendingShortcutRequests[requestId] = completer;
    _sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingShortcutRequests.remove(requestId);
        throw TimeoutException('Denial shortcut update timed out');
      },
    );
  }

  bool publishInputLayout(InputLayoutSnapshot snapshot) {
    final bytes = _wireCodec.encodeInputLayout(snapshot);
    if (bytes == null) {
      return false;
    }
    _sendWire(bytes);
    return true;
  }

  /// Requests a compositor-owned window whose content is built by the
  /// embedded Flutter shell instead of sampled from a client surface.
  bool createLocalWindow({
    required String appId,
    required String title,
    required Rect geometry,
  }) {
    final bytes = _wireCodec.encodeCreateLocalWindow(
      appId: appId,
      title: title,
      geometry: geometry,
    );
    if (bytes == null) {
      return false;
    }
    _sendWire(bytes);
    return true;
  }

  void closeWindow(DenialWindow window) {
    if (window.windowId <= 0) {
      return;
    }

    _sendWire(
      _wireCodec.encodeWindowRequest(
        wire.WindowRequestKind.CloseWindow,
        windowId: window.windowId,
      ),
    );
  }

  /// Releases the native last-frame texture retained for a finished close
  /// animation. Native also owns a bounded watchdog, so a lost message cannot
  /// leak a client buffer or Flutter texture.
  bool completeWindowClose(int windowId) {
    if (windowId <= 0) {
      return false;
    }

    final payload = ByteData(8)..setUint64(0, windowId, Endian.little);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_windowCloseCompleteChannel, payload)
        ?.catchError((Object _) => null);
    return true;
  }

  void focusWindow(DenialWindow window) {
    if (window.windowId <= 0) {
      return;
    }
    _sendWire(
      _wireCodec.encodeWindowRequest(
        wire.WindowRequestKind.FocusWindow,
        windowId: window.windowId,
      ),
    );
  }

  void configureWindow(
    DenialWindow window,
    Rect contentRect, {
    bool exact = false,
  }) {
    if (window.windowId <= 0 ||
        contentRect.width < 1.0 ||
        contentRect.height < 1.0) {
      return;
    }
    final geometry = Rect.fromLTWH(
      contentRect.left.round().clamp(0, 16384).toDouble(),
      contentRect.top.round().clamp(0, 16384).toDouble(),
      contentRect.width.round().clamp(64, 16384).toDouble(),
      contentRect.height.round().clamp(64, 16384).toDouble(),
    );
    _sendWire(
      _wireCodec.encodeWindowRequest(
        wire.WindowRequestKind.ConfigureWindow,
        windowId: window.windowId,
        geometry: geometry,
        flags: exact ? 1 : 0,
      ),
    );
  }

  void sendKeyboardText(String text) {
    if (text.isEmpty) {
      return;
    }

    _sendWire(_wireCodec.encodeKeyboardText(text));
  }

  void sendKeyboardKey(String key, {bool ctrl = false}) {
    if (key.isEmpty) {
      return;
    }

    _sendWire(_wireCodec.encodeKeyboardKey(key, ctrl: ctrl));
  }

  void pressKeyboardKey(String key) {
    if (key.isEmpty) {
      return;
    }

    _sendWire(
      _wireCodec.encodeKeyboardKey(
        key,
        phase: wire.DenialKeyboardKeyPhase.pressed,
      ),
    );
  }

  void releaseKeyboardKey(String key) {
    if (key.isEmpty) {
      return;
    }

    _sendWire(
      _wireCodec.encodeKeyboardKey(
        key,
        phase: wire.DenialKeyboardKeyPhase.released,
      ),
    );
  }

  bool requestBrightness({required int monitorId, required String connector}) {
    if (!_validBrightnessTarget(monitorId, connector)) return false;
    if (!useControlSocket) {
      _sendBrightnessPlatformRequest(
        command: 0,
        monitorId: monitorId,
        connector: connector,
        percent: 0,
      );
      return true;
    }
    unawaited(
      _sendControlRequest(
            'brightness.get',
            parameters: <String, Object>{
              'monitor_id': monitorId,
              'connector': connector,
            },
          )
          .then((result) {
            final returnedMonitor = result['monitor_id'];
            final level = result['level'];
            if (returnedMonitor is int &&
                level is num &&
                !_brightnessStates.isClosed) {
              _brightnessStates.add(
                DenialBrightnessState(
                  monitorId: returnedMonitor,
                  level: level.toDouble().clamp(0.0, 1.0),
                ),
              );
            }
          })
          .catchError((Object _) {
            _sendBrightnessPlatformRequest(
              command: 0,
              monitorId: monitorId,
              connector: connector,
              percent: 0,
            );
          }),
    );
    return true;
  }

  bool setBrightness({
    required int monitorId,
    required String connector,
    required double level,
  }) {
    if (!_validBrightnessTarget(monitorId, connector)) return false;
    final percent = (level.clamp(0.0, 1.0) * 100).round();
    if (!useControlSocket) {
      _sendBrightnessPlatformRequest(
        command: 1,
        monitorId: monitorId,
        connector: connector,
        percent: percent,
      );
      return true;
    }
    unawaited(
      _sendControlRequest(
        'brightness.set',
        parameters: <String, Object>{
          'monitor_id': monitorId,
          'connector': connector,
          'percent': percent,
        },
      ).catchError((Object _) {
        _sendBrightnessPlatformRequest(
          command: 1,
          monitorId: monitorId,
          connector: connector,
          percent: percent,
        );
        return <String, Object?>{};
      }),
    );
    return true;
  }

  bool _validBrightnessTarget(int monitorId, String connector) {
    final connectorBytes = utf8.encode(connector);
    return monitorId >= 0 &&
        connectorBytes.isNotEmpty &&
        connectorBytes.length <= 128 &&
        !connector.contains('\u0000');
  }

  void _sendBrightnessPlatformRequest({
    required int command,
    required int monitorId,
    required String connector,
    required int percent,
  }) {
    final connectorBytes = utf8.encode(connector);
    final data = ByteData(12 + connectorBytes.length)
      ..setUint8(0, command)
      ..setInt64(1, monitorId, Endian.little)
      ..setUint8(9, percent.clamp(0, 100))
      ..setUint16(10, connectorBytes.length, Endian.little);
    data.buffer.asUint8List().setRange(12, data.lengthInBytes, connectorBytes);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_brightnessChannel, data)
        ?.catchError((Object _) => null);
  }

  /// Configures compositor-owned inactivity DPMS. A null timeout disables it.
  void setIdleDpmsTimeout(Duration? timeout) {
    final milliseconds = timeout?.inMilliseconds ?? 0;
    if (milliseconds < 0) {
      return;
    }
    final data = ByteData(8)..setUint64(0, milliseconds, Endian.little);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_idlePolicyChannel, data)
        ?.catchError((Object _) => null);
  }

  /// Requests compositor-owned DPMS-off for every currently powered output.
  /// The next physical input wakes outputs through the native idle policy.
  void requestDpmsOff() {
    final data = ByteData(1)..setUint8(0, 1);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_displayPowerChannel, data)
        ?.catchError((Object _) => null);
  }

  int queryUiDevelopmentState() {
    return _sendUiDevelopmentCommand(DenialUiDevelopmentCommand.query);
  }

  int enableLiveUiDevelopment() {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.enableLiveDevelopment,
    );
  }

  int disableLiveUiDevelopment() {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.disableLiveDevelopment,
    );
  }

  int setUiDevelopmentWorkspace(String workspace) {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.setWorkspace,
      workspace: workspace,
    );
  }

  int hotReloadUi() {
    return _sendUiDevelopmentCommand(DenialUiDevelopmentCommand.hotReload);
  }

  int hotRestartUi() {
    return _sendUiDevelopmentCommand(DenialUiDevelopmentCommand.hotRestart);
  }

  int buildAndActivateOptimizedUi() {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.buildAndActivateOptimized,
    );
  }

  int restoreOfficialUi() {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.restoreOfficial,
    );
  }

  int revertLastWorkingUi() {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.revertLastWorking,
    );
  }

  int setUiDevelopmentAutoReload(bool enabled) {
    return _sendUiDevelopmentCommand(
      DenialUiDevelopmentCommand.setAutoReload,
      autoReload: enabled,
    );
  }

  int _sendUiDevelopmentCommand(
    DenialUiDevelopmentCommand command, {
    String workspace = '',
    bool autoReload = false,
  }) {
    if (!useControlSocket) {
      return _sendUiDevelopmentCommandToPlatform(
        command,
        workspace: workspace,
        autoReload: autoReload,
      );
    }
    final requestId = _nextRequestId++;
    final method = switch (command) {
      DenialUiDevelopmentCommand.query => 'ui.get',
      DenialUiDevelopmentCommand.enableLiveDevelopment => 'ui.live.enable',
      DenialUiDevelopmentCommand.disableLiveDevelopment => 'ui.live.disable',
      DenialUiDevelopmentCommand.setWorkspace => 'ui.workspace.set',
      DenialUiDevelopmentCommand.hotReload => 'ui.reload',
      DenialUiDevelopmentCommand.hotRestart => 'ui.restart',
      DenialUiDevelopmentCommand.buildAndActivateOptimized => 'ui.build',
      DenialUiDevelopmentCommand.restoreOfficial => 'ui.restore',
      DenialUiDevelopmentCommand.revertLastWorking => 'ui.revert',
      DenialUiDevelopmentCommand.setAutoReload => 'ui.auto_reload.set',
    };
    if (command == DenialUiDevelopmentCommand.setWorkspace &&
        (workspace.isEmpty || workspace.contains('\u0000'))) {
      return 0;
    }
    unawaited(
      _sendControlRequest(
            method,
            requestId: requestId,
            parameters: switch (command) {
              DenialUiDevelopmentCommand.setWorkspace => <String, Object>{
                'path': workspace,
              },
              DenialUiDevelopmentCommand.setAutoReload => <String, Object>{
                'enabled': autoReload,
              },
              _ => null,
            },
          )
          .then((result) {
            final state = DenialUiDevelopmentState.fromJson(result);
            if (!_uiDevelopmentStates.isClosed) {
              _uiDevelopmentStates.add(state);
            }
          })
          .catchError((Object _) {}),
    );
    return requestId;
  }

  int _sendUiDevelopmentCommandToPlatform(
    DenialUiDevelopmentCommand command, {
    required String workspace,
    required bool autoReload,
  }) {
    final requestId = _nextRequestId++;
    final bytes = _uiDevelopmentProtocol.encodeCommand(
      command: command,
      requestId: requestId,
      workspace: workspace,
      autoReload: autoReload,
    );
    if (bytes == null) return 0;
    ServicesBinding.instance.defaultBinaryMessenger
        .send(denialUiDevelopmentControlChannel, ByteData.sublistView(bytes))
        ?.catchError((Object _) => null);
    return requestId;
  }

  bool launchApplication(List<String> argv, {int? launchRequestId}) {
    if (argv.isEmpty) {
      return false;
    }
    return _sendSystemCommand(
      _launchApplicationCommand,
      argv: argv,
      requestId: launchRequestId,
    );
  }

  bool takeScreenshot() => _sendSystemCommand(_takeScreenshotCommand);

  bool screenshotPrepared(int requestId) =>
      _sendSystemCommand(_screenshotPreparedCommand, requestId: requestId);

  bool finishScreenshotRegion(int requestId, Rect region) {
    if (requestId <= 0 ||
        region.isEmpty ||
        !region.left.isFinite ||
        !region.top.isFinite ||
        !region.width.isFinite ||
        !region.height.isFinite ||
        region.left < 0 ||
        region.top < 0) {
      return false;
    }
    return _sendSystemCommand(
      _takeScreenshotCommand,
      requestId: requestId,
      argv: <String>[
        region.left.toStringAsFixed(6),
        region.top.toStringAsFixed(6),
        region.width.toStringAsFixed(6),
        region.height.toStringAsFixed(6),
      ],
    );
  }

  bool cancelScreenshot(int requestId) =>
      _sendSystemCommand(_cancelScreenshotCommand, requestId: requestId);

  /// Asks the native compositor to end this graphical session cleanly.
  ///
  /// This is deliberately not a process launch: deniald terminates its own
  /// Wayland loop and executes the normal runtime/compositor teardown path.
  bool requestLogout() => _sendSystemCommand(_logoutCommand);

  Future<DenialOutputConfiguration> readOutputConfiguration() async {
    final result = await _sendControlRequest('outputs.get');
    return DenialOutputConfiguration.fromJson(result);
  }

  Future<DenialOutputConfiguration> applyOutputConfiguration({
    required int serial,
    required List<DenialOutput> outputs,
    required bool persistent,
    String? primaryOutput,
    int? confirmationTimeoutMilliseconds,
  }) async {
    final result = await _sendControlRequest(
      'outputs.apply',
      parameters: <String, Object>{
        'serial': serial,
        'persistent': persistent,
        'primary_output': ?primaryOutput,
        'confirmation_timeout_milliseconds': ?confirmationTimeoutMilliseconds,
        'outputs': <Map<String, Object>>[
          for (final output in outputs) output.toApplyJson(),
        ],
      },
    );
    return DenialOutputConfiguration.fromJson(result);
  }

  Future<void> confirmOutputConfiguration(int token) async {
    await _sendControlRequest(
      'outputs.confirm',
      parameters: <String, Object>{'token': token},
    );
  }

  Future<void> rollbackOutputConfiguration(int token) async {
    await _sendControlRequest(
      'outputs.rollback',
      parameters: <String, Object>{'token': token},
    );
  }

  Future<Map<String, Object?>> _sendControlRequest(
    String method, {
    Map<String, Object>? parameters,
    int? requestId,
  }) async {
    final path = _outputControlSocketPath();
    if (path == null) {
      throw const DenialOutputControlException(
        'unavailable',
        'The Denial output control socket is unavailable.',
      );
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.unixDomainSock) {
      throw const DenialOutputControlException(
        'unavailable',
        'The Denial control socket is not running.',
      );
    }
    final resolvedRequestId = requestId ?? _nextRequestId++;
    final request = jsonEncode(<String, Object>{
      'version': 1,
      'id': resolvedRequestId,
      'method': method,
      'params': ?parameters,
    });
    if (utf8.encode(request).length + 1 > _maxOutputControlBytes) {
      throw const DenialOutputControlException(
        'invalid_request',
        'The output configuration is too large.',
      );
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: _outputControlTimeout,
      );
      socket.add(utf8.encode('$request\n'));
      await socket.flush();
      final responseBytes = <int>[];
      await for (final chunk in socket.timeout(_outputControlTimeout)) {
        responseBytes.addAll(chunk);
        if (responseBytes.length > _maxOutputControlBytes) {
          throw const DenialOutputControlException(
            'invalid_response',
            'The compositor output response is too large.',
          );
        }
      }
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != 1 ||
          decoded['id'] != resolvedRequestId) {
        throw const DenialOutputControlException(
          'invalid_response',
          'The compositor returned an invalid output response.',
        );
      }
      if (decoded['ok'] != true) {
        final error = decoded['error'];
        if (error is Map<String, Object?>) {
          throw DenialOutputControlException(
            error['code'] is String ? error['code']! as String : 'failed',
            error['message'] is String
                ? error['message']! as String
                : 'The compositor rejected the output configuration.',
          );
        }
        throw const DenialOutputControlException(
          'failed',
          'The compositor rejected the output configuration.',
        );
      }
      final result = decoded['result'];
      if (result is Map<String, Object?>) {
        return result;
      }
      throw const DenialOutputControlException(
        'invalid_response',
        'The compositor returned no output configuration.',
      );
    } on DenialOutputControlException {
      rethrow;
    } on Object catch (error) {
      throw DenialOutputControlException(
        'unavailable',
        'Could not reach Denial output control: $error',
      );
    } finally {
      socket?.destroy();
    }
  }

  String? _outputControlSocketPath() {
    final override = controlSocketPath;
    if (override != null) {
      return override.startsWith('/') && !override.contains('\u0000')
          ? override
          : null;
    }
    final environment = Platform.environment;
    final explicit = environment['DENIAL_SOCKET'];
    if (explicit != null &&
        explicit.startsWith('/') &&
        !explicit.contains('\u0000')) {
      return explicit;
    }
    final runtime = environment['XDG_RUNTIME_DIR'];
    if (runtime == null ||
        !runtime.startsWith('/') ||
        runtime.contains('\u0000')) {
      return null;
    }
    return '${runtime.replaceFirst(RegExp(r'/+$'), '')}/denial/control.sock';
  }

  bool _sendSystemCommand(
    int command, {
    List<String> argv = const <String>[],
    int? requestId,
  }) {
    if (argv.length > _maxSystemCommandArguments ||
        (requestId != null && requestId <= 0)) {
      return false;
    }

    final encodedArguments = <List<int>>[];
    var size = _systemCommandHeaderBytes;
    for (final argument in argv) {
      final encoded = utf8.encode(argument);
      if (encoded.isEmpty ||
          encoded.length > _maxSystemCommandArgumentBytes ||
          encoded.contains(0)) {
        return false;
      }
      size += 4 + encoded.length;
      if (size > _maxSystemCommandBytes) {
        return false;
      }
      encodedArguments.add(encoded);
    }

    final data = ByteData(size)
      ..setUint8(0, command)
      ..setUint64(1, requestId ?? 0, Endian.little)
      ..setUint32(9, encodedArguments.length, Endian.little);
    var offset = _systemCommandHeaderBytes;
    final bytes = data.buffer.asUint8List();
    for (final argument in encodedArguments) {
      data.setUint32(offset, argument.length, Endian.little);
      offset += 4;
      bytes.setRange(offset, offset + argument.length, argument);
      offset += argument.length;
    }

    ServicesBinding.instance.defaultBinaryMessenger
        .send(_systemCommandChannel, data)
        ?.catchError((Object _) => null);
    return true;
  }

  bool dismissNotification(int notificationId) {
    return _sendNotificationCommand(
      wire.DesktopNotificationCommandKind.Dismiss,
      notificationId,
    );
  }

  bool invokeNotificationAction(int notificationId, String actionKey) {
    return _sendNotificationCommand(
      wire.DesktopNotificationCommandKind.InvokeAction,
      notificationId,
      actionKey: actionKey,
    );
  }

  bool invokeDefaultNotificationAction(int notificationId) {
    return _sendNotificationCommand(
      wire.DesktopNotificationCommandKind.InvokeDefault,
      notificationId,
    );
  }

  bool invokeXEmbedTrayAction(
    int windowId,
    SystemTrayAction action,
    Offset position,
  ) {
    final kind = switch (action) {
      SystemTrayAction.activate => wire.XembedTrayCommandKind.Activate,
      SystemTrayAction.secondaryActivate =>
        wire.XembedTrayCommandKind.SecondaryActivate,
      SystemTrayAction.contextMenu => wire.XembedTrayCommandKind.ContextMenu,
    };
    final bytes = _wireCodec.encodeXEmbedTrayCommand(kind, windowId, position);
    if (bytes == null) {
      return false;
    }
    _sendWire(bytes);
    return true;
  }

  void prewarmHaptics() {
    ServicesBinding.instance.defaultBinaryMessenger.send(
      _hapticsChannel,
      _hapticPrewarmData,
    );
  }

  void sendHapticTap() {
    ServicesBinding.instance.defaultBinaryMessenger.send(
      _hapticsChannel,
      _hapticTapData,
    );
  }

  Future<double?> readAudioLevel() async {
    if (!useControlSocket) return _readAudioLevelFromPlatform();
    try {
      final result = await _sendControlRequest('audio.get');
      final value = result['level'];
      if (value is! num) return null;
      final level = value.toDouble().clamp(0.0, 1.0);
      final requestSerial = result['request_serial'];
      if (!_audioStates.isClosed) {
        _audioStates.add(
          DenialAudioState(
            level: level,
            requestSerial: requestSerial is int ? requestSerial : 0,
            completesRead: true,
          ),
        );
      }
      return level;
    } on Object {
      return _readAudioLevelFromPlatform();
    }
  }

  Future<double?> _readAudioLevelFromPlatform() {
    final completer = Completer<double?>();
    _pendingAudioReads.add(completer);
    final payload = ByteData(1)..setUint8(0, 0);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_audioChannel, payload)
        ?.catchError((Object _) {
          if (_pendingAudioReads.remove(completer) && !completer.isCompleted) {
            completer.complete(null);
          }
          return null;
        });
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingAudioReads.remove(completer);
        return null;
      },
    );
  }

  void setAudioLevel(int percent, {required int requestSerial}) {
    final resolvedPercent = percent.clamp(0, 100);
    if (!useControlSocket) {
      final payload = ByteData(6)
        ..setUint8(0, 1)
        ..setUint8(1, resolvedPercent)
        ..setUint32(2, requestSerial & 0xffffffff, Endian.little);
      ServicesBinding.instance.defaultBinaryMessenger
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _sendControlRequest(
        'audio.set',
        parameters: <String, Object>{
          'percent': resolvedPercent,
          'request_serial': requestSerial & 0xffffffff,
        },
      ).catchError((Object _) {
        final payload = ByteData(6)
          ..setUint8(0, 1)
          ..setUint8(1, resolvedPercent)
          ..setUint32(2, requestSerial & 0xffffffff, Endian.little);
        ServicesBinding.instance.defaultBinaryMessenger
            .send(_audioChannel, payload)
            ?.catchError((Object _) => null);
        return <String, Object?>{};
      }),
    );
  }

  void requestAudioStreams() {
    if (!useControlSocket) {
      final payload = ByteData(1)..setUint8(0, 2);
      ServicesBinding.instance.defaultBinaryMessenger
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _sendControlRequest('audio.streams.get')
          .then((result) {
            final streams = _audioStreamsFromControl(result);
            if (!_audioStreamStates.isClosed) {
              _audioStreamStates.add(streams);
            }
          })
          .catchError((Object _) {
            final payload = ByteData(1)..setUint8(0, 2);
            ServicesBinding.instance.defaultBinaryMessenger
                .send(_audioChannel, payload)
                ?.catchError((Object _) => null);
          }),
    );
  }

  void setAudioStreamLevel(int streamId, int percent) {
    final resolvedStreamId = streamId & 0xffffffff;
    final resolvedPercent = percent.clamp(0, 100);
    if (!useControlSocket) {
      final payload = ByteData(6)
        ..setUint8(0, 3)
        ..setUint32(1, resolvedStreamId, Endian.little)
        ..setUint8(5, resolvedPercent);
      ServicesBinding.instance.defaultBinaryMessenger
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _sendControlRequest(
        'audio.stream.set',
        parameters: <String, Object>{
          'stream_id': resolvedStreamId,
          'percent': resolvedPercent,
        },
      ).catchError((Object _) {
        final payload = ByteData(6)
          ..setUint8(0, 3)
          ..setUint32(1, resolvedStreamId, Endian.little)
          ..setUint8(5, resolvedPercent);
        ServicesBinding.instance.defaultBinaryMessenger
            .send(_audioChannel, payload)
            ?.catchError((Object _) => null);
        return <String, Object?>{};
      }),
    );
  }

  List<DenialAudioStream> _audioStreamsFromControl(
    Map<String, Object?> result,
  ) {
    final values = result['streams'];
    if (values is! List<Object?>) {
      throw const FormatException('invalid audio streams');
    }
    return List<DenialAudioStream>.unmodifiable(
      values.map((value) {
        if (value is! Map<String, Object?>) {
          throw const FormatException('invalid audio stream');
        }
        final id = value['id'];
        final name = value['name'];
        final level = value['level'];
        final muted = value['muted'];
        if (id is! int || name is! String || level is! num || muted is! bool) {
          throw const FormatException('invalid audio stream');
        }
        return DenialAudioStream(
          id: id,
          name: name,
          level: level.toDouble().clamp(0.0, 1.0),
          muted: muted,
        );
      }),
    );
  }

  void _sendWire(Uint8List bytes) {
    ServicesBinding.instance.defaultBinaryMessenger
        .send(wire.denialWireToNativeChannel, ByteData.sublistView(bytes))
        ?.catchError((Object _) => null);
  }

  bool _sendNotificationCommand(
    wire.DesktopNotificationCommandKind kind,
    int notificationId, {
    String? actionKey,
  }) {
    final bytes = _wireCodec.encodeNotificationCommand(
      kind,
      notificationId,
      actionKey: actionKey,
    );
    if (bytes == null) {
      return false;
    }
    _sendWire(bytes);
    return true;
  }

  Future<ByteData?> _handleAudioStateMessage(ByteData? data) async {
    if (data == null || data.lengthInBytes < 1) {
      return null;
    }

    final level = data.getUint8(0).clamp(0, 100) / 100.0;
    final requestSerial = data.lengthInBytes >= 5
        ? data.getUint32(1, Endian.little)
        : 0;
    final completesRead = _pendingAudioReads.isNotEmpty;
    if (!_audioStates.isClosed) {
      _audioStates.add(
        DenialAudioState(
          level: level,
          requestSerial: requestSerial,
          completesRead: completesRead,
        ),
      );
    }
    final pending = _pendingAudioReads.toList(growable: false);
    _pendingAudioReads.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(level);
      }
    }
    return null;
  }

  Future<ByteData?> _handleAudioStreamsStateMessage(ByteData? data) async {
    if (data == null || data.lengthInBytes < 4) {
      return null;
    }

    final count = data.getUint32(0, Endian.little);
    var offset = 4;
    final streams = <DenialAudioStream>[];
    for (var i = 0; i < count; i += 1) {
      if (offset + 8 > data.lengthInBytes) {
        return null;
      }
      final id = data.getUint32(offset, Endian.little);
      final level = data.getUint8(offset + 4).clamp(0, 100) / 100.0;
      final muted = data.getUint8(offset + 5) != 0;
      final nameLength = data.getUint16(offset + 6, Endian.little);
      offset += 8;
      if (offset + nameLength > data.lengthInBytes) {
        return null;
      }
      final nameBytes = data.buffer.asUint8List(
        data.offsetInBytes + offset,
        nameLength,
      );
      streams.add(
        DenialAudioStream(
          id: id,
          name: utf8.decode(nameBytes, allowMalformed: true),
          level: level,
          muted: muted,
        ),
      );
      offset += nameLength;
    }

    if (!_audioStreamStates.isClosed) {
      _audioStreamStates.add(List<DenialAudioStream>.unmodifiable(streams));
    }
    return null;
  }

  Future<ByteData?> _handleBrightnessStateMessage(ByteData? data) async {
    if (data == null || data.lengthInBytes < 9) {
      return null;
    }

    final monitorId = data.getInt64(0, Endian.little);
    if (monitorId < 0 || _brightnessStates.isClosed) {
      return null;
    }
    _brightnessStates.add(
      DenialBrightnessState(
        monitorId: monitorId,
        level: data.getUint8(8).clamp(0, 100) / 100.0,
      ),
    );
    return null;
  }

  Future<ByteData?> _handleUiDevelopmentStateMessage(ByteData? data) async {
    final state = _uiDevelopmentProtocol.decodeState(data);
    if (state != null && !_uiDevelopmentStates.isClosed) {
      _uiDevelopmentStates.add(state);
    }
    return null;
  }

  Future<ByteData?> _handleWireMessage(ByteData? data) async {
    if (wire.isDenialPlacementPacket(data)) {
      final event = _wireCodec.decodePlacement(data);
      if (event != null && !_windowEvents.isClosed) {
        _windowEvents.add(event);
      }
      return null;
    }

    if (wire.isDenialDragIconPacket(data)) {
      final update = _wireCodec.decodeDragIcon(data);
      if (update != null && !_dragIcons.isClosed) {
        _dragIcons.add(update.icon);
      }
      return null;
    }

    final decoded = _wireCodec.decodeStructured(data);
    if (decoded == null) {
      return null;
    }

    try {
      final payload = decoded.payload;
      if (payload is wire.WindowSnapshot) {
        _completeWindowSnapshot(decoded.sequence, decoded.requestId, payload);
      } else if (payload is wire.DisplayLayout) {
        _completeDisplayLayout(decoded.requestId, payload);
      } else if (payload is wire.WindowResponse) {
        _handleWindowResponse(decoded.sequence, decoded.requestId, payload);
      } else if (payload is wire.WindowEvent) {
        _handleWindowEvent(payload);
      } else if (payload is wire.ShellAction) {
        final action = switch (payload.action) {
          wire.ShellActionKind.Applications => DenialShellAction.applications,
          wire.ShellActionKind.Overview => DenialShellAction.overview,
          wire.ShellActionKind.WindowSwitcherNext =>
            DenialShellAction.windowSwitcherNext,
          wire.ShellActionKind.WindowSwitcherEnd =>
            DenialShellAction.windowSwitcherEnd,
          wire.ShellActionKind.Clipboard => DenialShellAction.clipboard,
          wire.ShellActionKind.ScreenshotRegion =>
            DenialShellAction.screenshotPrepare,
          wire.ShellActionKind.ScreenshotTextureReady =>
            DenialShellAction.screenshotTextureReady,
          wire.ShellActionKind.ScreenshotDone =>
            DenialShellAction.screenshotDone,
          wire.ShellActionKind.ClientPointerPressed =>
            DenialShellAction.clientPointerPressed,
          wire.ShellActionKind.Wallpaper => DenialShellAction.wallpaper,
        };
        if (!_shellActions.isClosed) {
          _shellActions.add(
            DenialShellActionEvent(
              action: action,
              monitorId: payload.hasMonitorId && payload.monitorId >= 0
                  ? payload.monitorId
                  : null,
              requestId: decoded.requestId,
              textureId: payload.textureId > 0 ? payload.textureId : null,
            ),
          );
        }
      } else if (payload is wire.CursorShape) {
        final shape = payload.shape?.trim().toLowerCase();
        if (shape != null && shape.isNotEmpty && !_cursorShapes.isClosed) {
          _cursorShapes.add(shape);
        }
      } else if (payload is wire.CursorPosition) {
        if (payload.x.isFinite &&
            payload.y.isFinite &&
            !_cursorPositions.isClosed) {
          _cursorPositions.add(Offset(payload.x, payload.y));
        }
      } else if (payload is wire.TextInputState) {
        if ((!payload.inputPanelVisible || payload.active) &&
            !_textInputStates.isClosed) {
          _textInputStates.add(
            DenialTextInputState(
              active: payload.active,
              inputPanelVisible: payload.inputPanelVisible,
              legacy: payload.legacy,
              contentHint: payload.contentHint,
              contentPurpose: payload.contentPurpose,
            ),
          );
        }
      } else if (payload is wire.DesktopNotificationEvent) {
        final event = _wireCodec.decodeNotificationEvent(payload);
        if (event != null && !_notificationEvents.isClosed) {
          _notificationEvents.add(event);
        }
      } else if (payload is wire.XembedTrayEvent) {
        final event = _wireCodec.decodeXEmbedTrayEvent(payload);
        if (event != null) {
          if (event.kind == XEmbedTrayEventKind.removed) {
            _xembedTrayItems.remove(event.windowId);
          } else if (event.item case final item?) {
            _xembedTrayItems[event.windowId] = item;
          }
          if (!_xembedTrayEvents.isClosed) {
            _xembedTrayEvents.add(event);
          }
        }
      } else if (payload is wire.SettingsResponse) {
        _handleSettingsResponse(decoded.requestId, payload);
      }
    } on Object {
      _wireCodec.rejectedStructuredMessages += 1;
    }

    return null;
  }

  void _handleSettingsResponse(int requestId, wire.SettingsResponse response) {
    if (response.kind == wire.SettingsResponseKind.Document) {
      final completer = _pendingSettingsDocumentRequests.remove(requestId);
      final document = response.document;
      if (!response.success ||
          response.revision <= 0 ||
          document == null ||
          utf8.encode(document).length >
              wire.denialWireMaxSettingsDocumentBytes) {
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            StateError(response.error ?? 'Denial settings request failed'),
          );
        }
        return;
      }
      final settings = DenialSettingsDocument(
        revision: response.revision,
        json: document,
      );
      if (!_settingsDocuments.isClosed) {
        _settingsDocuments.add(settings);
      }
      if (requestId != 0 && completer != null && !completer.isCompleted) {
        completer.complete(settings);
      }
      return;
    }

    if (response.kind == wire.SettingsResponseKind.Shortcuts) {
      final configuration = _wireCodec.decodeShortcutConfiguration(response);
      final completer = _pendingShortcutRequests.remove(requestId);
      if (configuration != null && !_shortcutConfigurations.isClosed) {
        _shortcutConfigurations.add(configuration);
      }
      if (requestId == 0 || completer == null || completer.isCompleted) {
        return;
      }
      if (!response.success || configuration == null) {
        completer.completeError(
          StateError(response.error ?? 'Denial shortcut request failed'),
        );
      } else {
        completer.complete(configuration);
      }
      return;
    }

    if (response.kind == wire.SettingsResponseKind.ShortcutValidation) {
      final validation = _wireCodec.decodeShortcutValidation(response);
      final completer = _pendingShortcutValidationRequests.remove(requestId);
      if (completer == null || completer.isCompleted) {
        return;
      }
      if (!response.success || validation == null) {
        completer.completeError(
          StateError(response.error ?? 'Denial shortcut validation failed'),
        );
      } else {
        completer.complete(validation);
      }
      return;
    }

    if (response.kind == wire.SettingsResponseKind.InputDevices) {
      final capabilities = _wireCodec.decodeInputDeviceCapabilities(response);
      final completer = _pendingInputDeviceRequests.remove(requestId);
      if (capabilities != null && !_inputDeviceCapabilities.isClosed) {
        _inputDeviceCapabilities.add(capabilities);
      }
      if (requestId == 0 || completer == null || completer.isCompleted) {
        return;
      }
      if (capabilities == null) {
        completer.completeError(
          StateError(response.error ?? 'Denial input device detection failed'),
        );
      } else {
        completer.complete(capabilities);
      }
      return;
    }

    if (response.kind != wire.SettingsResponseKind.Keyboard) {
      return;
    }

    final configuration = _wireCodec.decodeKeyboardConfiguration(response);
    final completer = _pendingKeyboardSettingsRequests.remove(requestId);
    if (configuration != null && !_keyboardConfigurations.isClosed) {
      _keyboardConfigurations.add(configuration);
    }
    if (requestId == 0) {
      return;
    }
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (!response.success || configuration == null) {
      completer.completeError(
        StateError(response.error ?? 'Denial keyboard settings request failed'),
      );
    } else {
      completer.complete(configuration);
    }
  }

  void _handleWindowResponse(
    int sequence,
    int requestId,
    wire.WindowResponse response,
  ) {
    if (!response.success) {
      final windowCompleter = _pendingWindowRequests.remove(requestId);
      if (windowCompleter != null && !windowCompleter.isCompleted) {
        windowCompleter.completeError(
          StateError(response.error ?? 'Denial window request failed'),
        );
      }
      final displayCompleter = _pendingDisplayRequests.remove(requestId);
      if (displayCompleter != null && !displayCompleter.isCompleted) {
        displayCompleter.complete(null);
      }
      return;
    }

    if (response.kind == wire.WindowResponseKind.Windows &&
        response.windows != null) {
      _completeWindowSnapshot(sequence, requestId, response.windows!);
    } else if (response.kind == wire.WindowResponseKind.DisplayLayout &&
        response.displayLayout != null) {
      _completeDisplayLayout(requestId, response.displayLayout!);
    }
  }

  void _handleWindowEvent(wire.WindowEvent event) {
    if (event.kind == wire.WindowEventKind.WindowsChanged) {
      _onWindowsChanged?.call();
      return;
    }
    if (event.windowId <= 0) {
      return;
    }
    if (event.kind == wire.WindowEventKind.Activated) {
      _onWindowActivated?.call(event.windowId);
      return;
    }
    if (event.kind == wire.WindowEventKind.Action && !_windowEvents.isClosed) {
      final action = switch (event.action) {
        wire.WindowActionKind.Minimize => DenialWindowAction.minimize,
        wire.WindowActionKind.Maximize => DenialWindowAction.maximize,
        wire.WindowActionKind.Restore => DenialWindowAction.restore,
        wire.WindowActionKind.ToggleMaximize =>
          DenialWindowAction.toggleMaximize,
        wire.WindowActionKind.ToggleFullscreen =>
          DenialWindowAction.toggleFullscreen,
      };
      _windowEvents.add(
        DenialWindowActionEvent(windowId: event.windowId, action: action),
      );
    }
  }

  void _completeWindowSnapshot(
    int sequence,
    int requestId,
    wire.WindowSnapshot snapshot,
  ) {
    final windows = _wireCodec.decodeWindows(snapshot);
    if (windows == null) {
      return;
    }
    final completer = _pendingWindowRequests.remove(requestId);
    final update = DenialWindowSnapshot(sequence: sequence, windows: windows);
    if (completer != null && !completer.isCompleted) {
      completer.complete(update);
    } else if (requestId == 0) {
      // Native publishes this snapshot before marking the corresponding
      // external-texture frame. Keep this synchronous so metadata and EGLImage
      // advance as one ordered transaction.
      _onWindowSnapshot?.call(update);
    }
  }

  void _completeDisplayLayout(int requestId, wire.DisplayLayout payload) {
    final layout = _wireCodec.decodeDisplayLayout(payload);
    if (layout == null) {
      return;
    }
    final completer = _pendingDisplayRequests.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(layout);
    } else if (requestId == 0 && !_displayLayouts.isClosed) {
      _displayLayouts.add(layout);
    }
  }
}

class DenialOutputControlException implements Exception {
  const DenialOutputControlException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
