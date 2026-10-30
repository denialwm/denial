import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../models/power_button_action.dart';
import '../../models/suspend_mode.dart';
import '../../models/ui_development.dart';
import '../ui_development_protocol.dart';
import 'context.dart';
import 'control_client.dart' show DenialOutputControlException;

final class BridgeSessionClient {
  BridgeSessionClient(this._context);

  final BridgeContext _context;
  static const String _hapticsChannel = 'denial/haptics';
  static const String _idlePolicyChannel = 'denial/idle_policy';
  static const String _displayPowerChannel = 'denial/display_power';
  static const String _systemCommandChannel = 'denial/system_command';
  static const String ambientDisplayChannel = 'denial/ambient_display';
  static const int _ambientEnter = 1;
  static const int _ambientLeave = 2;
  static const int _ambientReady = 1;
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
  static const int _launchDesktopApplicationCommand = 1;
  static const int _takeScreenshotCommand = 2;
  static const int _logoutCommand = 3;
  static const int _screenshotPreparedCommand = 4;
  static const int _cancelScreenshotCommand = 5;
  static const int _systemCommandHeaderBytes = 1 + 8 + 4;
  static const int _maxSystemCommandBytes = 64 * 1024;
  static const int _maxSystemCommandArguments = 64;
  static const int _maxSystemCommandArgumentBytes = 4096;
  final StreamController<DenialUiDevelopmentState> _uiDevelopmentStates =
      StreamController<DenialUiDevelopmentState>.broadcast(sync: true);
  final StreamController<bool> _ambientDisplay =
      StreamController<bool>.broadcast(sync: true);
  final DenialUiDevelopmentProtocol _uiDevelopmentProtocol =
      DenialUiDevelopmentProtocol();

  /// Configures the compositor-owned lock, DPMS, and suspend idle policy.
  void setIdlePolicy({
    required PowerButtonAction powerButtonAction,
    required bool lockEnabled,
    required Duration lockTimeout,
    required bool dpmsEnabled,
    required Duration dpmsTimeout,
    required bool suspendEnabled,
    required Duration suspendTimeout,
    required SuspendMode suspendMode,
    Duration? lockAfterScreenOff,
  }) {
    final lockMilliseconds = lockTimeout.inMilliseconds;
    final dpmsMilliseconds = dpmsTimeout.inMilliseconds;
    final suspendMilliseconds = suspendTimeout.inMilliseconds;
    if (lockMilliseconds <= 0 ||
        dpmsMilliseconds <= 0 ||
        suspendMilliseconds <= 0 ||
        lockMilliseconds > suspendMilliseconds ||
        dpmsMilliseconds > suspendMilliseconds) {
      return;
    }
    final screenOffMilliseconds = lockAfterScreenOff?.inMilliseconds ?? 0;
    if (screenOffMilliseconds < 0 || screenOffMilliseconds > 0xffffffff) {
      return;
    }
    final flags =
        (lockEnabled ? 1 : 0) |
        (dpmsEnabled ? 2 : 0) |
        (suspendEnabled ? 4 : 0) |
        (lockAfterScreenOff != null ? 8 : 0);
    final data = ByteData(32)
      ..setUint8(0, 4)
      ..setUint8(1, flags)
      ..setUint8(2, suspendMode.wireValue)
      ..setUint8(3, powerButtonAction.wireValue)
      ..setUint32(4, screenOffMilliseconds, Endian.little)
      ..setUint64(8, lockMilliseconds, Endian.little)
      ..setUint64(16, dpmsMilliseconds, Endian.little)
      ..setUint64(24, suspendMilliseconds, Endian.little);
    _context.platform
        .send(_idlePolicyChannel, data)
        ?.catchError((Object _) => null);
  }

  /// Requests compositor-owned DPMS-off for every currently powered output.
  /// The next physical input wakes outputs through the native idle policy.
  void requestDpmsOff() => _sendDisplayPower(1);

  /// Lights the dark outputs as an input would; the idle timeout starts
  /// again.
  void requestDisplayOn() => _sendDisplayPower(2);

  void _sendDisplayPower(int command) {
    final data = ByteData(1)..setUint8(0, command);
    _context.platform
        .send(_displayPowerChannel, data)
        ?.catchError((Object _) => null);
  }

  /// True when the panel is about to keep only the always-on picture lit,
  /// false when it lights up again.
  Stream<bool> get ambientDisplay => _ambientDisplay.stream;

  /// The last of [ambientDisplay], for a lock screen that starts after it.
  bool get ambientDisplayActive => _ambientDisplayActive;
  bool _ambientDisplayActive = false;

  Future<ByteData?> handleAmbientDisplay(ByteData? data) async {
    if (data == null || data.lengthInBytes != 1 || _ambientDisplay.isClosed) {
      return null;
    }
    switch (data.getUint8(0)) {
      case _ambientEnter:
        _ambientDisplayActive = true;
        _ambientDisplay.add(true);
      case _ambientLeave:
        _ambientDisplayActive = false;
        _ambientDisplay.add(false);
    }
    return null;
  }

  /// The always-on picture is on screen: deniald may turn the output off.
  void ambientDisplayReady() {
    final data = ByteData(1)..setUint8(0, _ambientReady);
    _context.platform
        .send(ambientDisplayChannel, data)
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
    if (!_context.useControlSocket) {
      return _sendUiDevelopmentCommandToPlatform(
        command,
        workspace: workspace,
        autoReload: autoReload,
      );
    }
    final requestId = _context.platform.nextRequestId();
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
      _context.control
          .request(
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
    final requestId = _context.platform.nextRequestId();
    final bytes = _uiDevelopmentProtocol.encodeCommand(
      command: command,
      requestId: requestId,
      workspace: workspace,
      autoReload: autoReload,
    );
    if (bytes == null) return 0;
    _context.platform
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

  bool launchDesktopApplication(
    String desktopFileId,
    List<String> argv, {
    int? launchRequestId,
  }) {
    if (desktopFileId.isEmpty ||
        !desktopFileId.endsWith('.desktop') ||
        desktopFileId.contains('/') ||
        desktopFileId.contains('\u0000') ||
        argv.isEmpty) {
      return false;
    }
    return _sendSystemCommand(
      _launchDesktopApplicationCommand,
      argv: <String>[desktopFileId, ...argv],
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

  /// Publishes the shell's fully resolved accent to deniald. Standalone
  /// Denial clients deliberately cannot author compositor theme state.
  void publishThemeAccent(int argb) {
    if (_context.useControlSocket) {
      return;
    }
    final bytes = _context.codec.encodeThemeAccent(argb);
    if (bytes != null) {
      _context.sendWire(bytes);
    }
  }

  /// Read mapped desktop-background metadata without starting the shell scene.

  Future<Map<String, Object?>> getWallpaperStatus() =>
      _context.control.request('wallpaper.status');

  Future<void> openWallpaperSelector() async {
    try {
      await _context.control.request('shell.wallpaper.open');
    } on DenialOutputControlException catch (error) {
      throw StateError(error.message);
    }
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

    _context.platform
        .send(_systemCommandChannel, data)
        ?.catchError((Object _) => null);
    return true;
  }

  void prewarmHaptics() {
    _context.platform.send(_hapticsChannel, _hapticPrewarmData);
  }

  void sendHapticTap() {
    _context.platform.send(_hapticsChannel, _hapticTapData);
  }

  Stream<DenialUiDevelopmentState> get uiDevelopmentStates =>
      _uiDevelopmentStates.stream;

  Future<ByteData?> handleDevelopmentState(ByteData? data) async {
    final state = _uiDevelopmentProtocol.decodeState(data);
    if (state != null && !_uiDevelopmentStates.isClosed) {
      _uiDevelopmentStates.add(state);
    }
    return null;
  }

  void dispose() {
    unawaited(_uiDevelopmentStates.close());
    unawaited(_ambientDisplay.close());
  }
}
