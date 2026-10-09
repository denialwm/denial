/// Managed system services and their public value types.
/// Read shared providers inside SDK bootstrap to preserve service ownership.
/// Backend construction/injection lives in service_backends.dart; reusable
/// isolate workers live in workers.dart. Protocol parsers remain private.
library;

export 'package:denial_sdk/system.dart'
    show MprisPlaybackState, MprisPlaybackStatus;

export 'src/models/audio.dart'
    show AppAudioStream, AudioLevelState, AudioOutputDevice;
export 'src/models/logind.dart'
    show
        LogindAction,
        LogindActionUnavailableException,
        LogindCapability,
        LogindInhibitor,
        LogindSnapshot;
export 'src/models/notification_policy.dart'
    show NotificationPolicy, NotificationPreviewMode;
export 'src/models/power_profile.dart' show PowerProfile;
export 'src/models/upower.dart'
    show
        UPowerBattery,
        UPowerBatteryState,
        UPowerBatteryTechnology,
        UPowerSnapshot,
        UPowerWarningLevel;
export 'src/services/audio_service.dart'
    show AudioService, audioServiceProvider;
export 'src/services/authentication_service.dart' show AuthenticationService;
export 'src/services/battery_notification_service.dart'
    show
        BatteryNotification,
        BatteryNotificationSink,
        batteryNotificationSinkProvider;
export 'src/services/battery_service.dart' show BatteryService;
export 'src/services/bluetooth_backend.dart'
    show
        BluetoothDeviceInfo,
        BluetoothPairingRequest,
        BluetoothPairingRequestKind,
        BluetoothSnapshot;
export 'src/services/bluetooth_service.dart' show bluetoothServiceProvider;
export 'src/services/brightness_service.dart'
    show BrightnessService, brightnessServiceProvider;
export 'src/services/clipboard_history_service.dart'
    show ClipboardHistoryService, clipboardHistoryServiceProvider;
export 'src/services/cpu_usage_service.dart' show cpuUsageServiceProvider;
export 'src/services/desktop_power_modes_service.dart'
    show
        DesktopPboProfile,
        DesktopPowerModesService,
        DesktopPowerModesSnapshot,
        desktopPowerModesServiceProvider;
export 'src/services/gpu_usage_service.dart' show gpuUsageServiceProvider;
export 'src/services/haptics_service.dart'
    show HapticsService, hapticsServiceProvider;
export 'src/services/lact_client.dart'
    show
        LactAmdPerformanceSnapshot,
        LactPerformancePreset,
        LactRequestSender,
        LactService;
export 'src/services/lact_service.dart' show lactServiceProvider;
export 'src/services/linux_cpu_usage.dart' show CpuSample, CpuUsageService;
export 'src/services/linux_gpu_usage.dart' show GpuSample, GpuUsageService;
export 'src/services/logind_service.dart' show logindServiceProvider;
export 'src/services/media_player_backend.dart' show MediaPlayerService;
export 'src/services/media_player_service.dart'
    show mediaPlaybackProvider, mediaPlayerServiceProvider;
export 'src/services/mobile_network_service.dart'
    show
        MobileNetworkService,
        MobileNetworkSnapshot,
        MobileSimPresence,
        mobileNetworkProvider,
        mobileNetworkServiceProvider;
export 'src/services/network_backend.dart'
    show
        NetworkConnectivityStatus,
        NetworkPermission,
        NetworkSnapshot,
        SavedWifiConnectionInfo,
        WifiNetwork,
        WifiSecurity;
export 'src/services/network_service.dart' show networkServiceProvider;
export 'src/services/notification_policy_repository.dart'
    show NotificationPolicyRepository, NotificationPolicyStore;
export 'src/services/power_profile_service.dart'
    show PowerProfileService, powerProfileServiceProvider;
export 'src/services/power_status_service.dart'
    show PowerStatusService, powerStatusServiceProvider;
export 'src/services/status_notifier_service.dart' show StatusNotifierService;
export 'src/services/system_actions_service.dart'
    show SystemActionsService, systemActionsServiceProvider;
export 'src/services/upower_service.dart' show upowerServiceProvider;
