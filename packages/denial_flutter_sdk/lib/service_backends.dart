/// Advanced service backend contracts and explicit backend construction.
/// Use these when supplying provider overrides or standalone service clients.
/// Ordinary shell features use shared providers from state.dart and
/// system_services.dart. Creating a backend transfers disposal to its owner.
library;

export 'src/models/logind.dart'
    show
        LogindAction,
        LogindActionUnavailableException,
        LogindBackend,
        LogindCapability,
        LogindInhibitor,
        LogindSnapshot;
export 'src/models/upower.dart'
    show
        UPowerBattery,
        UPowerBatteryState,
        UPowerBatteryTechnology,
        UPowerSnapshot,
        UPowerWarningLevel;
export 'src/platform/authentication_protocol.dart'
    show
        AuthenticationPacket,
        AuthenticationPacketKind,
        AuthenticationPromptStyle;
export 'src/services/authentication_service.dart'
    show AuthenticationService, NativeAuthenticationService;
export 'src/services/battery_notification_service.dart'
    show
        BatteryNotification,
        BatteryNotificationSink,
        FreedesktopBatteryNotificationSink;
export 'src/services/bluetooth_backend.dart'
    show
        BluetoothBackend,
        BluetoothDeviceInfo,
        BluetoothPairingRequest,
        BluetoothPairingRequestKind,
        BluetoothService,
        BluetoothSnapshot;
export 'src/services/iwd_service.dart' show IwdService;
export 'src/services/logind_backend.dart' show LogindService;
export 'src/services/network_backend.dart'
    show
        NetworkBackend,
        NetworkConnectivityStatus,
        NetworkPermission,
        NetworkSnapshot,
        SavedWifiConnectionInfo,
        WifiNetwork,
        WifiSecurity;
export 'src/services/network_manager_service.dart' show NetworkManagerService;
export 'src/services/network_service_backend.dart' show NetworkService;
export 'src/services/non_blocking_fifo.dart' show NonBlockingFifoWriter;
export 'src/services/upower_backend.dart' show UPowerBackend, UPowerService;
export 'src/state/session_power.dart'
    show NativeSessionRuntimeBackend, SessionRuntimeBackend;
export 'src/state/ui_development.dart'
    show SystemUiWorkspaceSetupService, UiWorkspaceSetupService;
