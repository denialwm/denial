/// Managed platform state, snapshots and semantic controller operations.
/// Implementation reducers, indexes and reconciliation helpers remain private.
/// Plugin-owned notifier lifetimes are available from lifecycle.dart.
library;

export 'package:denial_sdk/system.dart' show GpuLoad, LoadSeries;

export 'src/models/system_telemetry.dart' show SystemTelemetrySnapshot;
export 'src/state/app_audio.dart'
    show AppAudioController, AppAudioState, appAudioProvider;
export 'src/state/audio_devices.dart'
    show AudioDevicesController, AudioDevicesState, audioDevicesProvider;
export 'src/state/authentication.dart'
    show
        AuthenticationController,
        AuthenticationPrompt,
        AuthenticationState,
        authenticationProvider,
        authenticationServiceProvider;
export 'src/state/bluetooth.dart'
    show BluetoothController, BluetoothState, bluetoothProvider;
export 'src/state/clipboard_history_controller.dart'
    show
        ClipboardHistoryController,
        ClipboardHistoryViewState,
        clipboardHistoryProvider;
export 'src/state/cursor_theme.dart'
    show
        CursorThemeCatalogController,
        availableShellCursorThemesProvider,
        cursorThemeCatalogProvider,
        cursorThemeRepositoryProvider,
        resolveShellCursorTheme,
        shellCursorThemeProvider;
export 'src/state/desktop_notifications.dart'
    show
        DesktopNotificationsController,
        desktopNotificationLoggerProvider,
        desktopNotificationsProvider;
export 'src/state/desktop_notifications_state.dart'
    show
        DesktopNotificationGroup,
        DesktopNotificationRecord,
        DesktopNotificationsState;
export 'src/state/desktop_power_modes.dart'
    show
        DesktopPowerModesController,
        DesktopPowerModesState,
        desktopPowerModesProvider;
export 'src/state/desktop_window_close_effect.dart'
    show DesktopWindowCloseEffect;
export 'src/state/display_brightness.dart'
    show DisplayBrightnessController, displayBrightnessProvider;
export 'src/state/display_brightness_model.dart' show DisplayBrightnessState;
export 'src/state/display_layout.dart'
    show DisplayLayoutController, displayLayoutProvider;
export 'src/state/fingerprint_scene.dart'
    show FingerprintScene, FingerprintSceneController, fingerprintSceneProvider;
export 'src/state/input_device_capabilities.dart'
    show
        InputDeviceCapabilitiesController,
        InputDeviceCapabilitiesState,
        inputDeviceCapabilitiesProvider;
export 'src/state/keyboard_configuration.dart'
    show
        KeyboardConfigurationController,
        KeyboardConfigurationState,
        keyboardConfigurationProvider;
export 'src/state/lock_frame.dart'
    show LockFrameRequest, lockFrameRequestProvider;
export 'src/state/network_connectivity.dart'
    show
        NetworkConnectivityController,
        NetworkConnectivityState,
        networkConnectivityProvider;
export 'src/state/output_configuration.dart'
    show
        OutputConfigurationController,
        OutputConfigurationState,
        outputConfigurationProvider;
export 'src/state/screen_recording.dart'
    show
        ScreenRecordingController,
        ScreenRecordingState,
        screenRecordingProvider;
export 'src/state/screenshot_selection.dart'
    show
        ScreenshotSelectionController,
        ScreenshotSelectionPhase,
        ScreenshotSelectionSession,
        screenshotSelectionProvider;
export 'src/state/session_power.dart'
    show
        SessionActionAvailability,
        SessionActionPermission,
        SessionPowerAction,
        SessionPowerController,
        SessionPowerState,
        SessionRuntimeBackend,
        sessionLogoutWatchdogProvider,
        sessionPowerErrorMessage,
        sessionPowerProvider,
        sessionRuntimeBackendProvider;
export 'src/state/shell_controller.dart'
    show ShellController, shellControllerProvider;
export 'src/platform/denial_bridge_provider.dart' show denialBridgeProvider;
export 'src/state/shell_fonts.dart'
    show availableShellFontFamiliesProvider, shellFontCatalogProvider;
export 'src/state/shell_state.dart' show ShellState;
export 'src/state/shortcut_configuration.dart'
    show
        ShortcutConfigurationController,
        ShortcutConfigurationState,
        shortcutConfigurationProvider;
export 'src/state/suspend_modes.dart' show suspendModeCapabilitiesProvider;
export 'src/state/system_status.dart'
    show
        BatteryController,
        SystemTelemetryController,
        batteryProvider,
        batteryServiceProvider,
        clockLocaleProvider,
        clockProvider,
        cpuUsageProvider,
        effectivePowerStatusProvider,
        gpuUsageProvider,
        powerStatusProvider;
export 'src/state/system_tray.dart'
    show
        SystemTrayController,
        statusNotifierServiceProvider,
        systemTrayProvider;
export 'src/state/ui_development.dart'
    show
        UiDevelopmentController,
        UiWorkspaceSetupException,
        UiWorkspaceSetupService,
        uiDevelopmentProvider,
        uiWorkspaceSetupProvider;
export 'src/state/upower.dart'
    show UPowerController, UPowerState, upowerProvider;
