/// Public platform value types. Service backend contracts are available from
/// service_backends.dart.
library;

export 'package:denial_sdk/system.dart'
    show GpuLoad, LoadSeries, MprisPlaybackState, MprisPlaybackStatus;
export 'package:denial_sdk/windows.dart' show DenialWindowAction;

export 'panels.dart' show PanelEdge;
export 'src/models/app_launch_request.dart' show AppLaunchRequest;
export 'src/models/audio.dart'
    show AppAudioStream, AudioLevelState, AudioOutputDevice;
export 'src/models/clipboard_history.dart'
    show
        ClipboardHistoryContentKind,
        ClipboardHistoryData,
        ClipboardHistoryEntry,
        ClipboardHistoryException,
        ClipboardHistoryOrigin,
        ClipboardHistorySnapshot;
export 'src/models/denial_cursor_state.dart'
    show DenialCursorState, DenialCursorStateKind;
export 'src/models/denial_drag_icon.dart'
    show DenialDragIcon, DenialDragIconUpdate;
export 'src/models/denial_window.dart'
    show
        DenialSurfaceLayer,
        DenialSurfaceRole,
        DenialWindow,
        DenialWindowContentKind,
        DenialWindowOpacityClass;
export 'src/models/denial_pet.dart'
    show DenialPet, DenialPetHold, DenialWindowHold;
export 'src/models/denial_window_event.dart'
    show
        DenialWindowActionEvent,
        DenialWindowEvent,
        DenialWindowPlacementChange,
        DenialWindowPlacementEvent,
        DenialWindowPlacementPhase;
export 'src/models/denial_window_snapshot.dart' show DenialWindowSnapshot;
export 'src/models/desktop_notification.dart'
    show
        DesktopNotification,
        DesktopNotificationAction,
        DesktopNotificationEvent,
        DesktopNotificationEventKind,
        DesktopNotificationImageData,
        DesktopNotificationUrgency;
export 'src/models/display_layout.dart'
    show DisplayLayout, DisplayOutput, SystemBarSide;
export 'src/models/input_device_capabilities.dart'
    show
        DenialInputDeviceCapabilities,
        mouseSpeedDefault,
        mouseSpeedMaximum,
        mouseSpeedMinimum,
        touchpadScrollSpeedFactorDefault,
        touchpadScrollSpeedFactorMaximum,
        touchpadScrollSpeedFactorMinimum,
        touchpadScrollingLayoutSwipeSpeedFactorDefault,
        touchpadScrollingLayoutSwipeSpeedFactorMaximum,
        touchpadScrollingLayoutSwipeSpeedFactorMinimum;
export 'src/models/keyboard_configuration.dart'
    show DenialKeyboardConfiguration, DenialKeyboardLayout;
export 'src/models/logind.dart'
    show
        LogindAction,
        LogindActionUnavailableException,
        LogindCapability,
        LogindInhibitor,
        LogindSnapshot;
export 'src/models/notification_policy.dart'
    show NotificationPolicy, NotificationPreviewMode;
export 'src/models/output_configuration.dart'
    show
        DenialOutput,
        DenialOutputCapabilities,
        DenialOutputConfiguration,
        DenialOutputConfirmation,
        DenialOutputMode,
        DenialOutputTransform,
        DenialScrollingLayoutAxis,
        canonicalizeOutputScale,
        outputScaleBase;
export 'src/models/power_button_action.dart'
    show PowerButtonAction, PowerButtonActionWireValue;
export 'src/models/power_profile.dart' show PowerProfile;
export 'src/models/shell_clock_info.dart' show ShellClockInfo;
export 'src/models/shell_popup_placement.dart'
    show ShellPopupAnchor, ShellPopupPlacement;
export 'src/models/shell_power_status.dart'
    show
        ShellChargeProtocol,
        ShellPowerStatus,
        ShellThermalReading,
        ShellThermalSensor;
export 'src/models/shortcut_configuration.dart'
    show
        DenialShortcutAction,
        DenialShortcutActionTarget,
        DenialShortcutBinding,
        DenialShortcutConfiguration,
        DenialShortcutInput,
        DenialShortcutInputCategory,
        DenialShortcutInputKind,
        DenialShortcutPluginActionTarget,
        DenialShortcutSpawnShTarget,
        DenialShortcutSpawnTarget,
        DenialShortcutTarget,
        DenialShortcutValidation,
        DenialShortcutValidationKind,
        PluginActionDescriptor;
export 'src/models/surface_occlusion.dart'
    show SurfaceBounds, canDrawInteriorSurfaceLayers, unoccludedSurfaceLayers;
export 'src/models/suspend_mode.dart'
    show SuspendMode, SuspendModeCapabilities, SuspendModeKernelValue;
export 'src/models/system_telemetry.dart' show SystemTelemetrySnapshot;
export 'src/models/system_tray_item.dart'
    show
        SystemTrayAction,
        SystemTrayIconPixmap,
        SystemTrayItem,
        SystemTrayItemSource,
        SystemTrayMenuEntry,
        SystemTrayMenuToggleType,
        SystemTrayStatus,
        XEmbedTrayEvent,
        XEmbedTrayEventKind;
export 'src/models/ui_development.dart'
    show
        DenialUiDevelopmentOperation,
        DenialUiDevelopmentState,
        DenialUiDiagnostic,
        DenialUiDiagnosticSeverity,
        DenialUiRuntimeMode;
export 'src/models/upower.dart'
    show
        UPowerBattery,
        UPowerBatteryState,
        UPowerBatteryTechnology,
        UPowerSnapshot,
        UPowerWarningLevel;
