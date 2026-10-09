import 'dart:async';

import 'package:flutter/services.dart';

import '../input/input_layout.dart';
import '../models/denial_cursor_state.dart';
import '../models/denial_drag_icon.dart';
import '../models/denial_pet.dart';
import '../models/denial_window.dart';
import '../models/denial_window_event.dart';
import '../models/denial_window_snapshot.dart';
import '../models/desktop_notification.dart';
import '../models/display_layout.dart';
import '../models/input_device_capabilities.dart';
import '../models/keyboard_configuration.dart';
import '../models/output_configuration.dart';
import '../models/power_button_action.dart';
import '../models/shortcut_configuration.dart';
import '../models/suspend_mode.dart';
import '../models/system_tray_item.dart';
import '../models/ui_development.dart';
import 'bridge/audio_client.dart';
import 'bridge/brightness_client.dart';
import 'bridge/configuration_client.dart';
import 'bridge/context.dart';
import 'bridge/displays_client.dart';
import 'bridge/events_client.dart';
import 'bridge/input_client.dart';
import 'bridge/platform_transport.dart';
import 'bridge/session_client.dart';
import 'bridge/settings_document_client.dart';
import 'bridge/windows_client.dart';
import 'denial_bridge_models.dart';
import 'denial_wire.dart' as wire;
import 'ui_development_protocol.dart';

export 'denial_bridge_models.dart';
export 'bridge/control_client.dart' show DenialOutputControlException;

/// One shared, connected platform client. Window subscriptions are optional.
class DenialBridge {
  DenialBridge({this.useControlSocket = false, this.controlSocketPath}) {
    final messenger = ServicesBinding.instance.defaultBinaryMessenger;
    final platform = BridgePlatformTransport(
      messenger.send,
      messenger.setMessageHandler,
    );
    _context = BridgeContext(
      platform,
      useControlSocket: useControlSocket,
      controlSocketPath: controlSocketPath,
    );
    _settingsDocument = BridgeSettingsDocumentClient(_context);
    _configuration = BridgeConfigurationClient(_context);
    _windows = BridgeWindowsClient(_context);
    _displays = BridgeDisplaysClient(_context);
    _input = BridgeInputClient(_context);
    _brightness = BridgeBrightnessClient(_context);
    _audio = BridgeAudioClient(_context);
    _session = BridgeSessionClient(_context);
    _events = BridgeEventsClient(
      _context,
      _windows,
      _displays,
      _settingsDocument,
      _configuration,
    );

    platform.bind({
      wire.denialWireToFlutterChannel: _events.handleMessage,
      'denial/audio_state': _audio.handleState,
      'denial/audio_streams_state': _audio.handleStreams,
      'denial/audio_devices_state': _audio.handleDevices,
      'denial/brightness_state': _brightness.handleBrightnessState,
      'denial/software_dimming_state': _brightness.handleSoftwareDimmingState,
      denialUiDevelopmentStateChannel: _session.handleDevelopmentState,
    });
  }
  final bool useControlSocket;
  final String? controlSocketPath;
  late final BridgeContext _context;
  late final BridgeSettingsDocumentClient _settingsDocument;
  late final BridgeConfigurationClient _configuration;
  late final BridgeWindowsClient _windows;
  late final BridgeDisplaysClient _displays;
  late final BridgeInputClient _input;
  late final BridgeBrightnessClient _brightness;
  late final BridgeAudioClient _audio;
  late final BridgeSessionClient _session;
  late final BridgeEventsClient _events;

  Stream<DenialWindowEvent> get windowEvents => _windows.windowEvents;

  /// Unsolicited snapshots delivered synchronously with native texture metadata.
  Stream<DenialWindowSnapshot> get windowSnapshots => _windows.windowSnapshots;
  Stream<void> get windowsChanged => _windows.windowsChanged;

  /// Every native activation, including reactivating the already-focused app.
  Stream<int> get windowActivations => _windows.windowActivations;

  Stream<DenialShellActionEvent> get shellActions => _events.shellActions;

  Stream<({int generation, String id, int? monitorId})> get pluginActions =>
      _events.pluginActions;

  void publishPluginActions(
    int generation,
    List<Map<String, Object>> actions,
  ) => _events.publishPluginActions(generation, actions);

  Stream<String> get cursorShapes => _events.cursorShapes;

  Stream<DenialCursorState> get cursorStates => _events.cursorStates;

  Stream<Offset> get cursorPositions => _events.cursorPositions;

  Stream<DenialDragIcon?> get dragIcons => _events.dragIcons;

  Stream<DenialAudioState> get audioStates => _audio.audioStates;

  Stream<List<DenialAudioStream>> get audioStreamStates =>
      _audio.audioStreamStates;

  Stream<List<DenialAudioDevice>> get audioDeviceStates =>
      _audio.audioDeviceStates;

  Stream<DenialBrightnessState> get brightnessStates =>
      _brightness.brightnessStates;

  Stream<DenialSoftwareDimmingState> get softwareDimmingStates =>
      _brightness.softwareDimmingStates;

  Stream<DesktopNotificationEvent> get notificationEvents =>
      _events.notificationEvents;

  Stream<XEmbedTrayEvent> get xembedTrayEvents => _events.xembedTrayEvents;

  Map<int, SystemTrayItem> get xembedTrayItems => _events.xembedTrayItems;

  Stream<DenialUiDevelopmentState> get uiDevelopmentStates =>
      _session.uiDevelopmentStates;

  Stream<DenialKeyboardConfiguration> get keyboardConfigurations =>
      _configuration.keyboardConfigurations;

  Stream<DenialInputDeviceCapabilities> get inputDeviceCapabilities =>
      _configuration.inputDeviceCapabilities;

  Stream<DenialShortcutConfiguration> get shortcutConfigurations =>
      _configuration.shortcutConfigurations;

  Stream<DenialTextInputState> get textInputStates => _events.textInputStates;

  Stream<DenialSettingsDocument> get settingsDocuments =>
      _settingsDocument.settingsDocuments;

  Stream<DisplayLayout> get displayLayouts => _displays.displayLayouts;

  /// Assigns optional window callbacks; native reception starts at construction.
  /// Prefer windowSnapshots, windowsChanged and windowActivations for managed subscriptions.
  void start({
    required VoidCallback onWindowsChanged,
    ValueChanged<DenialWindowSnapshot>? onWindowSnapshot,
    required ValueChanged<int> onWindowActivated,
  }) => _windows.setWindowCallbacks(
    onWindowsChanged: onWindowsChanged,
    onWindowSnapshot: onWindowSnapshot,
    onWindowActivated: onWindowActivated,
  );

  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) =>
      _windows.listWindows(fallback);

  /// Read mapped desktop-background metadata without starting the shell scene.
  Future<Map<String, Object?>> getWallpaperStatus() =>
      _session.getWallpaperStatus();

  Future<DisplayLayout?> getDisplayLayout() => _displays.getDisplayLayout();

  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
    required double systemBarThickness,
    required double maximizePadding,
  }) => _displays.configureSystemBar(
    side: side,
    monitorIds: monitorIds,
    systemBarThickness: systemBarThickness,
    maximizePadding: maximizePadding,
  );

  /// Publishes the shell's fully resolved accent to deniald. Standalone
  /// Denial clients deliberately cannot author compositor theme state.
  void publishThemeAccent(int argb) => _session.publishThemeAccent(argb);

  Future<DenialSettingsDocument> readSettingsDocument() =>
      _settingsDocument.readSettingsDocument();

  Future<void> openWallpaperSelector() => _session.openWallpaperSelector();

  Future<DenialSettingsDocument> writeSettingsDocument({
    required int expectedRevision,
    required String document,
  }) => _settingsDocument.writeSettingsDocument(
    expectedRevision: expectedRevision,
    document: document,
  );

  Future<DenialKeyboardConfiguration> readKeyboardConfiguration() =>
      _configuration.readKeyboardConfiguration();

  Future<DenialInputDeviceCapabilities> readInputDeviceCapabilities() =>
      _configuration.readInputDeviceCapabilities();

  Future<DenialInputDeviceCapabilities> configureTouchpad(
    DenialInputDeviceCapabilities capabilities,
  ) => _configuration.configureTouchpad(capabilities);

  Future<DenialInputDeviceCapabilities> configureMouse(
    DenialInputDeviceCapabilities capabilities,
  ) => _configuration.configureMouse(capabilities);

  Future<DenialKeyboardConfiguration> configureKeyboard(
    DenialKeyboardConfiguration configuration,
  ) => _configuration.configureKeyboard(configuration);

  Future<DenialShortcutConfiguration> readShortcutConfiguration() =>
      _configuration.readShortcutConfiguration();

  Future<DenialShortcutValidation> validateShortcut({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) => _configuration.validateShortcut(
    shortcut: shortcut,
    existingShortcut: existingShortcut,
  );

  Future<DenialShortcutConfiguration> addShortcut({
    required int expectedRevision,
    required DenialShortcutBinding shortcut,
  }) => _configuration.addShortcut(
    expectedRevision: expectedRevision,
    shortcut: shortcut,
  );

  Future<DenialShortcutConfiguration> updateShortcut({
    required int expectedRevision,
    required String existingShortcut,
    required DenialShortcutBinding shortcut,
  }) => _configuration.updateShortcut(
    expectedRevision: expectedRevision,
    existingShortcut: existingShortcut,
    shortcut: shortcut,
  );

  Future<DenialShortcutConfiguration> removeShortcut({
    required int expectedRevision,
    required String shortcut,
  }) => _configuration.removeShortcut(
    expectedRevision: expectedRevision,
    shortcut: shortcut,
  );

  Future<DenialShortcutConfiguration> restoreDefaultShortcuts({
    required int expectedRevision,
  }) => _configuration.restoreDefaultShortcuts(
    expectedRevision: expectedRevision,
  );

  bool publishInputLayout(InputLayoutSnapshot snapshot) =>
      _input.publishInputLayout(snapshot);

  /// Requests a compositor-owned window whose content is built by the
  /// embedded Flutter shell instead of sampled from a client surface.
  bool createLocalWindow({
    required String appId,
    required String title,
    required Rect geometry,
  }) => _windows.createLocalWindow(
    appId: appId,
    title: title,
    geometry: geometry,
  );

  void closeWindow(DenialWindow window) => _windows.closeWindow(window);

  /// Releases the native last-frame texture retained for a finished close
  /// animation. Native also owns a bounded watchdog, so a lost message cannot
  /// leak a client buffer or Flutter texture.
  bool completeWindowClose(int windowId) =>
      _windows.completeWindowClose(windowId);

  bool acknowledgeCursorPresented(int epoch) =>
      _input.acknowledgeCursorPresented(epoch);

  void focusWindow(DenialWindow window) => _windows.focusWindow(window);

  void switchWorkspace({required int monitorId, required int workspaceId}) =>
      _windows.switchWorkspace(monitorId: monitorId, workspaceId: workspaceId);

  /// Names the hold a desktop pet the user drags takes if let go now, or
  /// none. See `ShellPetHolds`.
  void holdPet(int petId, DenialPetHold? hold) => _windows.holdPet(petId, hold);

  /// Tells native how fast a held desktop pet moves on screen, in logical
  /// px/s, its window's animations included. Zero when it stops.
  void carryPet(int petId, Offset velocity) =>
      _windows.carryPet(petId, velocity);

  void moveWindowToWorkspace(
    DenialWindow window, {
    int? monitorId,
    required int workspaceId,
    bool follow = true,
  }) => _windows.moveWindowToWorkspace(
    window,
    monitorId: monitorId,
    workspaceId: workspaceId,
    follow: follow,
  );

  /// Commits an overview drop onto a possibly hidden workspace. [point] is
  /// in that workspace's own scene coordinates.
  void dropWindowOnWorkspace(
    DenialWindow window, {
    required int monitorId,
    required int workspaceId,
    required Offset point,
  }) => _windows.dropWindowOnWorkspace(
    window,
    monitorId: monitorId,
    workspaceId: workspaceId,
    point: point,
  );

  /// Plans [dropWindowOnWorkspace]; a null [point] ends the preview.
  void previewWindowDropOnWorkspace(
    DenialWindow window, {
    required int monitorId,
    required int workspaceId,
    Offset? point,
  }) => _windows.previewWindowDropOnWorkspace(
    window,
    monitorId: monitorId,
    workspaceId: workspaceId,
    point: point,
  );

  void configureWindow(
    DenialWindow window,
    Rect contentRect, {
    bool exact = false,
    bool layoutDrop = false,
  }) => _windows.configureWindow(
    window,
    contentRect,
    exact: exact,
    layoutDrop: layoutDrop,
  );

  void sendKeyboardText(String text) => _input.sendKeyboardText(text);

  void sendKeyboardKey(String key, {bool ctrl = false}) =>
      _input.sendKeyboardKey(key, ctrl: ctrl);

  void dismissKeyboardPanel(int activationSerial) =>
      _input.dismissKeyboardPanel(activationSerial);

  void pressKeyboardKey(String key) => _input.pressKeyboardKey(key);

  void releaseKeyboardKey(String key) => _input.releaseKeyboardKey(key);

  bool requestBrightness({required int monitorId, required String connector}) =>
      _brightness.requestBrightness(monitorId: monitorId, connector: connector);

  Future<double?> readBrightnessLevel({
    required int monitorId,
    required String connector,
  }) => _brightness.readBrightnessLevel(
    monitorId: monitorId,
    connector: connector,
  );

  bool setBrightness({
    required int monitorId,
    required String connector,
    required double level,
  }) => _brightness.setBrightness(
    monitorId: monitorId,
    connector: connector,
    level: level,
  );

  Future<double?> readSoftwareDimmingLevel({required int monitorId}) =>
      _brightness.readSoftwareDimmingLevel(monitorId: monitorId);

  bool setSoftwareDimming({required int monitorId, required double level}) =>
      _brightness.setSoftwareDimming(monitorId: monitorId, level: level);

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
  }) => _session.setIdlePolicy(
    powerButtonAction: powerButtonAction,
    lockEnabled: lockEnabled,
    lockTimeout: lockTimeout,
    dpmsEnabled: dpmsEnabled,
    dpmsTimeout: dpmsTimeout,
    suspendEnabled: suspendEnabled,
    suspendTimeout: suspendTimeout,
    suspendMode: suspendMode,
  );

  /// Requests compositor-owned DPMS-off for every currently powered output.
  /// The next physical input wakes outputs through the native idle policy.
  void requestDpmsOff() => _session.requestDpmsOff();

  int queryUiDevelopmentState() => _session.queryUiDevelopmentState();

  int enableLiveUiDevelopment() => _session.enableLiveUiDevelopment();

  int disableLiveUiDevelopment() => _session.disableLiveUiDevelopment();

  int setUiDevelopmentWorkspace(String workspace) =>
      _session.setUiDevelopmentWorkspace(workspace);

  int hotReloadUi() => _session.hotReloadUi();

  int hotRestartUi() => _session.hotRestartUi();

  int buildAndActivateOptimizedUi() => _session.buildAndActivateOptimizedUi();

  int restoreOfficialUi() => _session.restoreOfficialUi();

  int revertLastWorkingUi() => _session.revertLastWorkingUi();

  int setUiDevelopmentAutoReload(bool enabled) =>
      _session.setUiDevelopmentAutoReload(enabled);

  bool launchApplication(List<String> argv, {int? launchRequestId}) =>
      _session.launchApplication(argv, launchRequestId: launchRequestId);

  bool launchDesktopApplication(
    String desktopFileId,
    List<String> argv, {
    int? launchRequestId,
  }) => _session.launchDesktopApplication(
    desktopFileId,
    argv,
    launchRequestId: launchRequestId,
  );

  bool takeScreenshot() => _session.takeScreenshot();

  bool screenshotPrepared(int requestId) =>
      _session.screenshotPrepared(requestId);

  bool finishScreenshotRegion(int requestId, Rect region) =>
      _session.finishScreenshotRegion(requestId, region);

  bool cancelScreenshot(int requestId) => _session.cancelScreenshot(requestId);

  /// Asks the native compositor to end this graphical session cleanly.
  ///
  /// This is deliberately not a process launch: deniald terminates its own
  /// Wayland loop and executes the normal runtime/compositor teardown path.
  bool requestLogout() => _session.requestLogout();

  Future<DenialOutputConfiguration> readOutputConfiguration() =>
      _displays.readOutputConfiguration();

  Future<DenialOutputConfiguration> applyOutputConfiguration({
    required int serial,
    required List<DenialOutput> outputs,
    required bool persistent,
    String? primaryOutput,
    int? confirmationTimeoutMilliseconds,
  }) => _displays.applyOutputConfiguration(
    serial: serial,
    outputs: outputs,
    persistent: persistent,
    primaryOutput: primaryOutput,
    confirmationTimeoutMilliseconds: confirmationTimeoutMilliseconds,
  );

  Future<void> confirmOutputConfiguration(int token) =>
      _displays.confirmOutputConfiguration(token);

  Future<void> rollbackOutputConfiguration(int token) =>
      _displays.rollbackOutputConfiguration(token);

  bool dismissNotification(int notificationId) =>
      _events.dismissNotification(notificationId);

  bool invokeNotificationAction(int notificationId, String actionKey) =>
      _events.invokeNotificationAction(notificationId, actionKey);

  bool invokeDefaultNotificationAction(int notificationId) =>
      _events.invokeDefaultNotificationAction(notificationId);

  bool invokeXEmbedTrayAction(
    int windowId,
    SystemTrayAction action,
    Offset position,
  ) => _events.invokeXEmbedTrayAction(windowId, action, position);

  void prewarmHaptics() => _session.prewarmHaptics();

  void sendHapticTap() => _session.sendHapticTap();

  Future<double?> readAudioLevel() => _audio.readAudioLevel();

  void setAudioLevel(int percent, {required int requestSerial}) =>
      _audio.setAudioLevel(percent, requestSerial: requestSerial);

  void requestAudioStreams() => _audio.requestAudioStreams();

  void setAudioStreamLevel(int streamId, int percent) =>
      _audio.setAudioStreamLevel(streamId, percent);

  void requestAudioDevices() => _audio.requestAudioDevices();

  void setAudioDevice(String name) => _audio.setAudioDevice(name);

  void dispose() {
    if (_context.platform.isDisposed) return;
    _context.platform.dispose();
    _settingsDocument.dispose();
    _configuration.dispose();
    _windows.dispose();
    _displays.dispose();
    _brightness.dispose();
    _audio.dispose();
    _session.dispose();
    _events.dispose();
  }
}
