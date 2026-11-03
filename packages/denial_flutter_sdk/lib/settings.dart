/// Public Denial settings APIs.
library;

export 'src/settings/input_deck_settings.dart' show InputDeckSettings;

export 'src/settings/color_format.dart'
    show formatOpaqueColorHex, opaqueColorRgb, parseOpaqueColorHex;
export 'src/settings/fingerprint/fingerprint_service.dart'
    show
        FingerprintSettingsSession,
        fingerprintDeviceProvider,
        fingerprintNames,
        fingerprintSessionProvider;
export 'src/settings/lock_pin/lock_pin_service.dart'
    show
        LockPinOutcome,
        LockPinService,
        isValidLockPin,
        lockPinLengthProvider,
        lockPinMaxLength,
        lockPinMinLength,
        lockPinServiceProvider;
export 'src/settings/permissions/app_permissions.dart'
    show
        AppPermission,
        AppPermissionAnswer,
        AppPermissionAnswers,
        AppPermissionsService,
        appPermissionsProvider,
        appPermissionsServiceProvider;
export 'src/settings/monitor_arrangement.dart'
    show
        MonitorArrangementGeometry,
        arrangeMonitorLikeNwgDisplays,
        centerMonitorCanvasPan,
        denialMaxOutputCoordinate,
        denialMinMonitorViewScale,
        denialMonitorWorkspaceSize,
        fitMonitorCanvasScale,
        nwgDisplaysMaxViewScale,
        nwgDisplaysMinViewScale,
        nwgDisplaysScaledSnapThreshold,
        nwgDisplaysSnapThreshold,
        nwgDisplaysViewScale,
        panMonitorCanvasForZoom;
export 'src/settings/settings_controller.dart'
    show
        ShellSettingsController,
        ShellSettingsSyncPhase,
        ShellSettingsSyncStatus,
        ShellSettingsSyncStatusController,
        settingsStoreProvider,
        shellSettingsProvider,
        shellSettingsSyncStatusProvider;
export 'src/settings/settings_store.dart'
    show
        DenialSettingsDocumentTransport,
        NativeSettingsStore,
        SettingsDocumentTransport,
        SettingsDocumentUpdateSource,
        SettingsStore;
export 'src/settings/shell_settings.dart'
    show
        ClipboardTrayEdge,
        DesktopColorSchemePreference,
        DesktopWindowLayout,
        MinimizedWindowPlacement,
        ScrollingLayoutWheelUpDirection,
        ShellAccentSource,
        ShellAnimationSettings,
        ShellAppearanceSettings,
        ShellApplicationEnvironmentSettings,
        ShellLayoutSettings,
        ShellLocalePreference,
        ShellLocalizationSettings,
        ShellLockScreenSettings,
        ShellOverlaySettings,
        ShellOverlaySurface,
        ShellPowerSettings,
        ShellSettings,
        WorkspaceSwitchingOrientation,
        applicationEnvironmentMaximumDesktopFileIdBytes,
        applicationEnvironmentMaximumNameBytes,
        applicationEnvironmentMaximumValueBytes,
        clipboardTrayDefaultExtent,
        clipboardTrayMaximumExtent,
        clipboardTrayMinimumExtent,
        defaultWorkspaceCount,
        denialDefaultBrightness,
        isValidApplicationEnvironmentDesktopFileId,
        isValidApplicationEnvironmentVariableName,
        launcherOverlayMinimumHeight,
        maximumWorkspaceCount,
        minimumWorkspaceCount,
        scrollingLayoutWheelSpeedDefault,
        scrollingLayoutWheelSpeedMaximum,
        scrollingLayoutWheelSpeedMinimum;
export 'src/settings/rotation_lock.dart'
    show RotationLockController, RotationLockState, rotationLockProvider;
