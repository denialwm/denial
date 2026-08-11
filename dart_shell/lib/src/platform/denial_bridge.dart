import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../input/input_layout.dart';
import '../models/denial_drag_icon.dart';
import '../models/desktop_notification.dart';
import '../models/display_layout.dart';
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

class DenialBridge {
  static const String _hapticsChannel = 'denial/haptics';
  static const String _audioChannel = 'denial/audio';
  static const String _brightnessChannel = 'denial/brightness';
  static const String _idlePolicyChannel = 'denial/idle_policy';
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

  DenialBridge() {
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

  final Map<int, Completer<DenialWindowSnapshot>> _pendingWindowRequests = {};
  final Map<int, Completer<DisplayLayout?>> _pendingDisplayRequests = {};
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
  final StreamController<DenialUiDevelopmentState> _uiDevelopmentStates =
      StreamController<DenialUiDevelopmentState>.broadcast(sync: true);
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
  Stream<DenialUiDevelopmentState> get uiDevelopmentStates =>
      _uiDevelopmentStates.stream;

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
    unawaited(_uiDevelopmentStates.close());
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

  Future<DisplayLayout?> getDisplayLayout() {
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

  void configureWindow(DenialWindow window, Rect contentRect) {
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

  bool requestBrightness({required int monitorId, required String connector}) {
    return _sendBrightnessRequest(
      command: 0,
      monitorId: monitorId,
      connector: connector,
      percent: 0,
    );
  }

  bool setBrightness({
    required int monitorId,
    required String connector,
    required double level,
  }) {
    return _sendBrightnessRequest(
      command: 1,
      monitorId: monitorId,
      connector: connector,
      percent: (level.clamp(0.0, 1.0) * 100).round(),
    );
  }

  bool _sendBrightnessRequest({
    required int command,
    required int monitorId,
    required String connector,
    required int percent,
  }) {
    final connectorBytes = utf8.encode(connector);
    if (monitorId < 0 ||
        connectorBytes.isEmpty ||
        connectorBytes.length > 128 ||
        connector.contains('\u0000')) {
      return false;
    }
    final data = ByteData(12 + connectorBytes.length)
      ..setUint8(0, command)
      ..setInt64(1, monitorId, Endian.little)
      ..setUint8(9, percent.clamp(0, 100))
      ..setUint16(10, connectorBytes.length, Endian.little);
    data.buffer.asUint8List().setRange(12, data.lengthInBytes, connectorBytes);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_brightnessChannel, data)
        ?.catchError((Object _) => null);
    return true;
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
    final requestId = _nextRequestId++;
    final bytes = _uiDevelopmentProtocol.encodeCommand(
      command: command,
      requestId: requestId,
      workspace: workspace,
      autoReload: autoReload,
    );
    if (bytes == null) {
      return 0;
    }
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

  Future<double?> readAudioLevel() {
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
    final payload = ByteData(6)
      ..setUint8(0, 1)
      ..setUint8(1, percent.clamp(0, 100))
      ..setUint32(2, requestSerial & 0xffffffff, Endian.little);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_audioChannel, payload)
        ?.catchError((Object _) => null);
  }

  void requestAudioStreams() {
    final payload = ByteData(1)..setUint8(0, 2);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_audioChannel, payload)
        ?.catchError((Object _) => null);
  }

  void setAudioStreamLevel(int streamId, int percent) {
    final payload = ByteData(6)
      ..setUint8(0, 3)
      ..setUint32(1, streamId & 0xffffffff, Endian.little)
      ..setUint8(5, percent.clamp(0, 100));
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_audioChannel, payload)
        ?.catchError((Object _) => null);
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
      } else if (payload is wire.DesktopNotificationEvent) {
        final event = _wireCodec.decodeNotificationEvent(payload);
        if (event != null && !_notificationEvents.isClosed) {
          _notificationEvents.add(event);
        }
      }
    } on Object {
      _wireCodec.rejectedStructuredMessages += 1;
    }

    return null;
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
    }
  }
}
