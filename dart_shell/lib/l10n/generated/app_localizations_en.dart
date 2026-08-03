// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionDismiss => 'Dismiss';

  @override
  String get anchorBottomCenter => 'Bottom center';

  @override
  String get anchorBottomLeft => 'Bottom left';

  @override
  String get anchorBottomRight => 'Bottom right';

  @override
  String get anchorCenter => 'Center';

  @override
  String get anchorCenterLeft => 'Center left';

  @override
  String get anchorCenterRight => 'Center right';

  @override
  String get anchorTopCenter => 'Top center';

  @override
  String get anchorTopLeft => 'Top left';

  @override
  String get anchorTopRight => 'Top right';

  @override
  String get batteryCapacityUnavailable => '--';

  @override
  String get batteryCharging => 'Charging';

  @override
  String get batteryDischarging => 'Discharging';

  @override
  String batteryGraphMarker(String label, String value) {
    return '$label $value';
  }

  @override
  String get batteryIdle => 'Idle';

  @override
  String batteryStateAndPercent(String state, int percent) {
    return '$state $percent%';
  }

  @override
  String get batteryTitle => 'Battery';

  @override
  String get bluetoothAllow => 'Allow';

  @override
  String bluetoothAllowPairing(String deviceName) {
    return 'Allow $deviceName to pair?';
  }

  @override
  String get bluetoothAllowService => 'Allow a Bluetooth service?';

  @override
  String bluetoothAvailableSignal(int signal) {
    return 'Available · $signal dBm';
  }

  @override
  String get bluetoothBlocked => 'Blocked';

  @override
  String get bluetoothCloseDetails => 'Close Bluetooth details';

  @override
  String get bluetoothCodeDisplayed => 'Code displayed';

  @override
  String bluetoothConfirmCode(String code) {
    return 'Confirm that both devices display $code.';
  }

  @override
  String bluetoothConfirmDevice(String deviceName) {
    return 'Confirm $deviceName';
  }

  @override
  String bluetoothConnectDeviceStatus(String deviceName, String status) {
    return 'Connect $deviceName, $status';
  }

  @override
  String get bluetoothConnectedConfiguring =>
      'Connected · configuring services';

  @override
  String bluetoothDevicesConnected(int count) {
    return 'Connected devices: $count';
  }

  @override
  String get bluetoothDismissError => 'Dismiss Bluetooth error';

  @override
  String bluetoothEnterPasskey(String deviceName) {
    return 'Enter the passkey for $deviceName';
  }

  @override
  String bluetoothEnterPasskeyOnDevice(String deviceName) {
    return 'Enter this passkey on $deviceName';
  }

  @override
  String bluetoothEnterPin(String deviceName) {
    return 'Enter the PIN for $deviceName';
  }

  @override
  String bluetoothEnterPinOnDevice(String deviceName) {
    return 'Enter this PIN on $deviceName';
  }

  @override
  String get bluetoothLoadingService => 'Loading Bluetooth service…';

  @override
  String get bluetoothNoAdapter => 'No Bluetooth adapter';

  @override
  String get bluetoothNoAdapterDescription =>
      'Denial will enable these controls when an adapter appears.';

  @override
  String get bluetoothNoAdapterShort => 'No adapter';

  @override
  String get bluetoothNoDevices => 'No devices found';

  @override
  String get bluetoothNoDevicesDescription =>
      'Start a scan and make the other device discoverable.';

  @override
  String get bluetoothOff => 'Bluetooth is off';

  @override
  String get bluetoothOffDescription =>
      'Turn it on to see paired and nearby devices.';

  @override
  String get bluetoothOperationFailed =>
      'Bluetooth could not complete the request.';

  @override
  String bluetoothPairDevice(String deviceName) {
    return 'Pair $deviceName';
  }

  @override
  String get bluetoothPairedTrusted => 'Paired · trusted';

  @override
  String get bluetoothPasskey => 'Bluetooth passkey';

  @override
  String get bluetoothPasskeyPrivacy =>
      'The passkey is sent once to BlueZ and is not retained by Denial.';

  @override
  String bluetoothPasskeyProgress(String code, int enteredDigits) {
    return '$code · $enteredDigits of 6 digits entered.';
  }

  @override
  String get bluetoothPasskeyRequirements =>
      'Enter a numeric passkey up to 6 digits.';

  @override
  String get bluetoothPinCode => 'Bluetooth PIN code';

  @override
  String get bluetoothPinPrivacy =>
      'The PIN is sent once to BlueZ and is not retained by Denial.';

  @override
  String get bluetoothPinRequirements =>
      'Enter a PIN containing 1–16 characters.';

  @override
  String get bluetoothRecognizeDevice =>
      'Only continue if you recognize this device.';

  @override
  String get bluetoothReject => 'Reject';

  @override
  String bluetoothRemoveDevice(String deviceName) {
    return 'Remove $deviceName';
  }

  @override
  String get bluetoothSameCode => 'the same code';

  @override
  String get bluetoothScanningDescription =>
      'Nearby devices will appear automatically.';

  @override
  String get bluetoothServiceUnavailable => 'BlueZ is unavailable';

  @override
  String get bluetoothServiceUnavailableDescription =>
      'Bluetooth controls will return when the service starts.';

  @override
  String get bluetoothServiceUnavailableShort => 'Bluetooth unavailable';

  @override
  String get bluetoothStopScanning => 'Stop scanning for Bluetooth devices';

  @override
  String bluetoothStopTrustingDevice(String deviceName) {
    return 'Stop trusting $deviceName';
  }

  @override
  String get bluetoothSubmit => 'Submit';

  @override
  String bluetoothTrustDevice(String deviceName) {
    return 'Trust $deviceName';
  }

  @override
  String bluetoothTrustServiceDevice(String deviceName) {
    return 'Only continue if you trust $deviceName.';
  }

  @override
  String bluetoothWaitingForDevice(String code) {
    return '$code · waiting for the other device.';
  }

  @override
  String get brightnessTitle => 'Brightness';

  @override
  String get celsiusUnit => '°C';

  @override
  String get chargeProtocolFast => 'FAST';

  @override
  String get chargeProtocolPowerDelivery => 'PD';

  @override
  String get chargeProtocolPps => 'PPS';

  @override
  String get chargeProtocolVooc => 'VOOC';

  @override
  String get commonBluetooth => 'Bluetooth';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonChecking => 'Checking…';

  @override
  String get commonConnecting => 'Connecting…';

  @override
  String get commonError => 'Error';

  @override
  String get commonLimited => 'Limited';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonNotConnected => 'Not connected';

  @override
  String get commonOff => 'Off';

  @override
  String get commonOn => 'On';

  @override
  String get commonOnline => 'Online';

  @override
  String get commonOpening => 'Opening…';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonScanning => 'Scanning…';

  @override
  String commonTitleAndBody(String title, String body) {
    return '$title. $body';
  }

  @override
  String commonTitleAndSubtitle(String title, String subtitle) {
    return '$title, $subtitle';
  }

  @override
  String get commonUnavailable => 'Unavailable';

  @override
  String get commonVolume => 'Volume';

  @override
  String get commonWifi => 'Wi-Fi';

  @override
  String currentMilliamps(int value) {
    return '$value mA';
  }

  @override
  String get currentMilliampsUnavailable => '-- mA';

  @override
  String desktopActivateWindow(String windowTitle) {
    return 'Activate $windowTitle';
  }

  @override
  String get desktopApplicationAudioUnavailable =>
      'Application audio is unavailable.';

  @override
  String desktopApplicationSearchResults(int visible, int total) {
    return '$visible of $total applications';
  }

  @override
  String get desktopApplicationVolumeDescription =>
      'Adjust audio for individual applications.';

  @override
  String get desktopApplicationVolumeTitle => 'Application volume';

  @override
  String get desktopApplicationsTitle => 'Applications';

  @override
  String get desktopChooseWallpaper => 'Choose wallpaper';

  @override
  String get desktopClearApplicationSearch => 'Clear application search';

  @override
  String get desktopCloseApplicationAudio => 'Close application volume';

  @override
  String desktopConnectDevice(String deviceName) {
    return 'Connect $deviceName';
  }

  @override
  String get desktopDashboardTitle => 'Dashboard';

  @override
  String desktopDisconnectDevice(String deviceName) {
    return 'Disconnect $deviceName';
  }

  @override
  String get desktopEnableBluetoothForDevices =>
      'Turn on Bluetooth to see devices.';

  @override
  String desktopFeatureAvailability(String feature, String availability) {
    return '$feature: $availability';
  }

  @override
  String get desktopGpuLabel => 'GPU';

  @override
  String get desktopGpuPresetAutomatic => 'Automatic';

  @override
  String get desktopGpuPresetHigh => 'High';

  @override
  String get desktopGpuPresetLow => 'Low';

  @override
  String desktopInstalledApplications(int count) {
    return 'Installed applications: $count';
  }

  @override
  String desktopLaunchApplication(String applicationName) {
    return 'Launch $applicationName';
  }

  @override
  String get desktopLoadingApplications => 'Loading applications…';

  @override
  String get desktopNoApplicationAudio => 'No applications are playing audio.';

  @override
  String get desktopNoApplicationsFound => 'No applications found';

  @override
  String get desktopOpenApplicationAudio => 'Open application volume';

  @override
  String get desktopOpenNotificationCenter => 'Open notification center';

  @override
  String desktopOpenNotificationCenterUnread(int count) {
    return 'Open notification center · $count unread';
  }

  @override
  String get desktopOpenPowerControls => 'Open power controls';

  @override
  String get desktopPboBalanced => 'Balanced';

  @override
  String get desktopPboLabel => 'PBO';

  @override
  String get desktopPboPerformance => 'Performance';

  @override
  String get desktopPboSilent => 'Silent';

  @override
  String get desktopPowerModesTitle => 'Power modes';

  @override
  String get desktopPowerModesUnavailable => 'Power modes are unavailable.';

  @override
  String get desktopRefreshApplicationAudio => 'Refresh application audio';

  @override
  String get desktopRefreshBluetooth => 'Refresh Bluetooth devices';

  @override
  String get desktopRefreshPowerModes => 'Refresh power modes';

  @override
  String desktopRestoreWindow(String windowTitle) {
    return 'Restore $windowTitle';
  }

  @override
  String get desktopScanBluetooth => 'Scan for Bluetooth devices';

  @override
  String get desktopScanningBluetoothDevices =>
      'Scanning for Bluetooth devices…';

  @override
  String get desktopSearchApplications => 'Search applications';

  @override
  String get desktopSystemProfile => 'System profile';

  @override
  String get desktopSystemProfileBalanced => 'Balanced';

  @override
  String get desktopSystemProfilePerformance => 'Performance';

  @override
  String get desktopSystemProfilePowerSaver => 'Power saver';

  @override
  String get desktopTurnBluetoothOff => 'Turn Bluetooth off';

  @override
  String get desktopTurnBluetoothOn => 'Turn Bluetooth on';

  @override
  String desktopVolumeForApplication(String applicationName) {
    return 'Volume for $applicationName';
  }

  @override
  String frameAppRendering(String title) {
    return 'APP · $title · RENDER';
  }

  @override
  String frameAppWaiting(String title) {
    return 'APP · $title · WAIT';
  }

  @override
  String frameImportedStats(
    String average,
    String maximum,
    int overBudget,
    int samples,
  ) {
    return 'AVG $average  MAX $maximum  OVER $overBudget  N $samples';
  }

  @override
  String get frameImportedStatsUnavailable => 'AVG --.-  MAX --.-  OVER -  N -';

  @override
  String frameMilliseconds(String value) {
    return '~$value ms';
  }

  @override
  String get frameMillisecondsUnavailable => '--.- ms';

  @override
  String frameShellPhases(String build, String raster, String gap) {
    return 'UI $build  R $raster  GAP $gap';
  }

  @override
  String frameShellRendering(int refreshRate) {
    return 'SHELL · $refreshRate HZ · RENDER';
  }

  @override
  String frameShellStats(String average, String maximum, int overBudget) {
    return 'AVG $average  MAX $maximum  OVER $overBudget';
  }

  @override
  String get frameShellWaiting => 'SHELL · WAIT';

  @override
  String launchOpeningApplication(String applicationName) {
    return 'Opening $applicationName';
  }

  @override
  String localApplicationNotRegistered(String appId) {
    return 'Local application “$appId” is not registered.';
  }

  @override
  String get lockAuthenticating => 'Authenticating…';

  @override
  String get lockAuthenticationResponse => 'Authentication response';

  @override
  String get lockAuthenticationUnavailable => 'Authentication is unavailable.';

  @override
  String get lockCpuLabel => 'CPU';

  @override
  String get lockDesktopPromptDescription =>
      'Enter your password to unlock this desktop session.';

  @override
  String get lockHideOnScreenKeyboard => 'Hide on-screen keyboard';

  @override
  String get lockKeyboardBackspace => 'Backspace';

  @override
  String get lockKeyboardLetters => 'Letters';

  @override
  String get lockKeyboardShift => 'Shift';

  @override
  String get lockKeyboardSpace => 'Space';

  @override
  String get lockKeyboardSymbols => 'Symbols';

  @override
  String get lockMetricUnavailable => '--';

  @override
  String get lockOnScreenKeyboard => 'On-screen keyboard';

  @override
  String get lockPamVerified => 'Identity verified';

  @override
  String get lockPasswordObscured => 'Password, obscured';

  @override
  String lockPerformanceMetric(String label, String value) {
    return '$label: $value';
  }

  @override
  String get lockPerformanceStatusLabel => 'Desktop performance status';

  @override
  String get lockPleaseWait => 'Please wait…';

  @override
  String get lockPressEnter => 'Press Enter to unlock';

  @override
  String lockRetryInSeconds(int seconds) {
    return 'Try again in $seconds s';
  }

  @override
  String get lockScreenSemanticsLabel => 'Desktop lock screen';

  @override
  String get lockShowOnScreenKeyboard => 'Show on-screen keyboard';

  @override
  String get lockSignInSemantics => 'Sign in to Denial';

  @override
  String lockTemperature(int temperature) {
    return '$temperature°C';
  }

  @override
  String get lockTryAgain => 'Try again';

  @override
  String get lockUnlock => 'Unlock';

  @override
  String get lockUnlockDenial => 'Unlock Denial';

  @override
  String get lockWaitingForAuthentication => 'Waiting for authentication…';

  @override
  String get lockWelcomeBack => 'Welcome back';

  @override
  String longDate(String weekday, int day, String month) {
    return '$weekday $day $month';
  }

  @override
  String get mediaControls => 'Media controls';

  @override
  String get mediaNext => 'Next track';

  @override
  String get mediaNowPlaying => 'Now playing';

  @override
  String get mediaPause => 'Pause';

  @override
  String get mediaPlay => 'Play';

  @override
  String get mediaPrevious => 'Previous track';

  @override
  String get metricAverage => 'AVG';

  @override
  String get metricCpu => 'CPU';

  @override
  String get metricMaximum => 'MAX';

  @override
  String get metricMinimum => 'MIN';

  @override
  String get metricNow => 'NOW';

  @override
  String get monthApril => 'April';

  @override
  String get monthAugust => 'August';

  @override
  String get monthDecember => 'December';

  @override
  String get monthFebruary => 'February';

  @override
  String get monthJanuary => 'January';

  @override
  String get monthJuly => 'July';

  @override
  String get monthJune => 'June';

  @override
  String get monthMarch => 'March';

  @override
  String get monthMay => 'May';

  @override
  String get monthNovember => 'November';

  @override
  String get monthOctober => 'October';

  @override
  String get monthSeptember => 'September';

  @override
  String get notificationDismiss => 'Dismiss notification';

  @override
  String get notificationGeneric => 'Notification';

  @override
  String get notificationNew => 'New notification';

  @override
  String notificationOpen(String summary) {
    return 'Open $summary';
  }

  @override
  String notificationProgress(int percent) {
    return 'Progress: $percent%';
  }

  @override
  String notificationSemantics(String applicationName, String summary) {
    return '$applicationName: $summary';
  }

  @override
  String notificationSemanticsWithBody(
    String applicationName,
    String summary,
    String body,
  ) {
    return '$applicationName: $summary. $body';
  }

  @override
  String get notificationsAllQuiet => 'All quiet';

  @override
  String get notificationsClearAll => 'Clear all notifications';

  @override
  String get notificationsCloseCenter => 'Close notification center';

  @override
  String get notificationsClosed => 'Closed';

  @override
  String get notificationsClosedByApplication => 'Closed by application';

  @override
  String get notificationsDisableDoNotDisturb => 'Disable do not disturb';

  @override
  String get notificationsDismissed => 'Dismissed';

  @override
  String get notificationsDoNotDisturbSemantics =>
      'Do not disturb is on. Ordinary banners are silent. Critical notifications can still appear.';

  @override
  String get notificationsEmptyDescription =>
      'New notifications will appear here.';

  @override
  String get notificationsEnableDoNotDisturb => 'Enable do not disturb';

  @override
  String get notificationsExpired => 'Expired';

  @override
  String get notificationsLoadingPolicy => 'Loading do not disturb policy';

  @override
  String get notificationsLockPrivacy => 'Lock screen notification privacy';

  @override
  String get notificationsNone => 'No notifications';

  @override
  String get notificationsOnLockScreen => 'On lock screen';

  @override
  String get notificationsPreviewApplicationOnly => 'App only';

  @override
  String get notificationsPreviewFull => 'Full';

  @override
  String get notificationsPreviewHidden => 'Hidden';

  @override
  String notificationsPreviewModeSemantics(String mode) {
    return '$mode lock screen previews';
  }

  @override
  String get notificationsQuietMode =>
      'Quiet mode · critical alerts can bypass';

  @override
  String get notificationsTitle => 'Notifications';

  @override
  String notificationsUnread(int count) {
    return 'Unread notifications: $count';
  }

  @override
  String numberValue(int value) {
    return '$value';
  }

  @override
  String get oskArrowDown => 'Down';

  @override
  String get oskArrowUp => 'Up';

  @override
  String get oskBackspace => 'Backspace';

  @override
  String get oskControlKey => 'CTRL';

  @override
  String get oskEnter => 'Enter';

  @override
  String get oskLetters => 'Letters';

  @override
  String get oskLettersKey => 'ABC';

  @override
  String get oskMoreSymbols => 'More symbols';

  @override
  String get oskMoreSymbolsKey => '=<';

  @override
  String get oskNumbersAndSymbols => 'Numbers and symbols';

  @override
  String get oskNumbersAndSymbolsKey => '?123';

  @override
  String get oskShift => 'Shift';

  @override
  String get oskSpace => 'Space';

  @override
  String outputBrightnessSemantics(String outputName) {
    return '$outputName brightness';
  }

  @override
  String get outputVolumeSemantics => 'Output volume';

  @override
  String get overviewNoWindows => 'No windows';

  @override
  String percentCompact(int percent) {
    return '$percent%';
  }

  @override
  String get percentSign => '%';

  @override
  String percentValue(int percent) {
    return '$percent percent';
  }

  @override
  String get powerActionHibernate => 'Hibernate';

  @override
  String get powerActionHibernateDescription => 'Save the session to disk';

  @override
  String get powerActionLock => 'Lock';

  @override
  String get powerActionLockDescription => 'Secure the session immediately';

  @override
  String get powerActionLogOut => 'Log out';

  @override
  String get powerActionLogOutDescription => 'Close the Denial session';

  @override
  String get powerActionPowerOff => 'Power off';

  @override
  String get powerActionPowerOffDescription => 'Shut down the computer';

  @override
  String get powerActionRestart => 'Restart';

  @override
  String get powerActionRestartDescription => 'Restart the computer';

  @override
  String get powerActionSuspend => 'Suspend';

  @override
  String get powerActionSuspendDescription => 'Keep the session in memory';

  @override
  String powerAuthenticationRequired(String description) {
    return 'Authentication required · $description';
  }

  @override
  String powerBlockedBy(String blocker) {
    return 'An application is preventing this action: $blocker';
  }

  @override
  String get powerConfirmLogOutBody =>
      'Your graphical session will end. Save work in open applications before continuing.';

  @override
  String get powerConfirmLogOutTitle => 'Log out of Denial?';

  @override
  String get powerConfirmPowerOffBody =>
      'All applications will be closed and the computer will shut down.';

  @override
  String get powerConfirmPowerOffTitle => 'Power off the computer?';

  @override
  String get powerConfirmRestartBody =>
      'All applications will be closed and the operating system will restart.';

  @override
  String get powerConfirmRestartTitle => 'Restart the computer?';

  @override
  String powerDelayNotice(String details) {
    return 'An application may briefly delay sleep or shutdown: $details';
  }

  @override
  String get powerPermissionDenied => 'Not authorized for this session';

  @override
  String get powerPermissionUnavailable => 'Session service unavailable';

  @override
  String get powerPermissionUnsupported => 'Not supported by this system';

  @override
  String get powerSessionBusy => 'Completing system request…';

  @override
  String get powerSessionClose => 'Close power and session controls';

  @override
  String get powerSessionDescription => 'Choose what Denial does';

  @override
  String get powerSessionLoading =>
      'Reading system capabilities and inhibitors…';

  @override
  String get powerSessionRefresh => 'Refresh power capabilities';

  @override
  String get powerSessionRequestError =>
      'The system could not complete the request.';

  @override
  String get powerSessionSemantics => 'Power and session controls';

  @override
  String get powerSessionTitle => 'Power & session';

  @override
  String get powerSessionUnavailable =>
      'System power controls are unavailable. Lock and log out remain local to Denial.';

  @override
  String powerWatts(int watts) {
    return '$watts W';
  }

  @override
  String powerWattsDecimal(String watts) {
    return '$watts W';
  }

  @override
  String get quickSettingsAutomatic => 'Automatic';

  @override
  String get quickSettingsBalanced => 'Balanced';

  @override
  String get quickSettingsBatterySaver => 'Battery saver';

  @override
  String get quickSettingsClose => 'Close quick settings';

  @override
  String get quickSettingsControls => 'Controls';

  @override
  String quickSettingsDate(String weekday, int day) {
    return '$weekday $day';
  }

  @override
  String get quickSettingsHighPerformance => 'High performance';

  @override
  String get quickSettingsKeyboard => 'Keyboard';

  @override
  String get quickSettingsLocked => 'Locked';

  @override
  String get quickSettingsNormal => 'Normal';

  @override
  String quickSettingsNotificationsCount(int count) {
    return 'Notifications · $count';
  }

  @override
  String get quickSettingsOneAppActive => 'One application active';

  @override
  String quickSettingsOpenDetails(String title) {
    return 'Open $title details';
  }

  @override
  String get quickSettingsOpenOnScreen => 'Open on-screen keyboard';

  @override
  String get quickSettingsPerformance => 'Performance';

  @override
  String get quickSettingsRotation => 'Rotation';

  @override
  String get quickSettingsSettingsUnavailable => 'Settings are unavailable.';

  @override
  String get quickSettingsSilent => 'Silent';

  @override
  String get settingsAboutArchitecture =>
      'Flutter is not an overlay placed on top of another compositor. It is part of the compositor’s foundation.';

  @override
  String get settingsAboutBelief => 'Origin does not have to dictate purpose.';

  @override
  String get settingsAboutCollaboration =>
      'Built in continuous collaboration with OpenAI Codex.';

  @override
  String get settingsAboutCreditLabel => 'CONCEIVED, DIRECTED & TESTED BY';

  @override
  String get settingsAboutCreditName => 'Doctor Logix';

  @override
  String get settingsAboutDescription =>
      'Denial gives Flutter a different life. It owns the desktop scene itself: the shell, its motion, and the composition of Wayland applications.';

  @override
  String get settingsAboutLogoSemanticsLabel => 'Denial wordmark';

  @override
  String get settingsAboutPageSemanticsLabel => 'About Denial';

  @override
  String get settingsAboutTagline => 'A Flutter-native Wayland compositor.';

  @override
  String get settingsAccentPickerRouteLabel => 'Shell accent color picker';

  @override
  String get settingsAccentPickerWheelLabel => 'Shell accent color';

  @override
  String get settingsAnimateLockScreen => 'Animate lock screen';

  @override
  String get settingsAnimateLockScreenDescription =>
      'Use a short desktop entrance animation while security input remains active immediately.';

  @override
  String get settingsAnimationSpeed => 'Animation speed';

  @override
  String settingsAnimationSpeedValue(int percent) {
    return '$percent% speed';
  }

  @override
  String get settingsAnimationsDescription =>
      'Choose close effects and tune how quickly shell surfaces move.';

  @override
  String get settingsAnimationsSection => 'ANIMATIONS';

  @override
  String get settingsAnimationsTitle => 'Motion that matches your desktop.';

  @override
  String get settingsAppearanceDescription =>
      'Changes made here are reflected across the desktop in real time.';

  @override
  String get settingsAppearanceSection => 'APPEARANCE';

  @override
  String get settingsAppearanceTitle => 'Make the desktop feel like yours.';

  @override
  String get settingsApplicationAudioDescription =>
      'Adjust active audio streams independently.';

  @override
  String get settingsApplicationAudioTitle => 'Application audio';

  @override
  String get settingsApplicationCategoryAppearance => 'Appearance';

  @override
  String get settingsApplicationCategoryPreferences => 'Preferences';

  @override
  String get settingsApplicationCategorySystem => 'System';

  @override
  String get settingsApplicationSemanticsLabel => 'Denial Settings';

  @override
  String get settingsApplicationTitle => 'Settings';

  @override
  String get settingsAudioDescription =>
      'Control the master output and individual application streams.';

  @override
  String get settingsAudioSection => 'AUDIO';

  @override
  String get settingsAudioTitle => 'Audio for the whole desktop.';

  @override
  String get settingsAudioUnavailable => 'Application audio is unavailable.';

  @override
  String get settingsAutomaticDisplayPowerDescription =>
      'Turn displays off after a period of inactivity.';

  @override
  String get settingsAutomaticDisplayPowerTitle => 'Automatic display power';

  @override
  String get settingsAutomaticDisplayPowerToggle =>
      'Turn displays off automatically';

  @override
  String get settingsAutomaticDisplayPowerToggleDescription =>
      'The timer resets whenever keyboard or pointer activity is detected.';

  @override
  String get settingsAvailable => 'Available';

  @override
  String get settingsAvailableNetworksDescription =>
      'Nearby and saved Wi-Fi networks.';

  @override
  String get settingsAvailableNetworksTitle => 'Available networks';

  @override
  String get settingsBackdropBlur => 'Backdrop blur';

  @override
  String get settingsBackdropBlurDescription =>
      'Soften content behind translucent windows and panels. Higher intensity uses more GPU.';

  @override
  String get settingsBackdropBlurEnabled => 'Enable backdrop blur';

  @override
  String get settingsBackdropBlurEnabledDescription =>
      'Blur only where transparent content can reveal the desktop beneath it.';

  @override
  String get settingsBackdropBlurIntensity => 'Blur intensity';

  @override
  String get settingsBackdropBlurOpacityThreshold =>
      'Minimum window opacity for blur';

  @override
  String get settingsBackdropDimming => 'Backdrop dimming';

  @override
  String get settingsBarGeometryDescription =>
      'Adjust the space reserved for the desktop system bar.';

  @override
  String get settingsBarGeometryTitle => 'System bar geometry';

  @override
  String get settingsBarThickness => 'Bar thickness';

  @override
  String get settingsBluetoothAdapterDescription => 'Current adapter';

  @override
  String get settingsBluetoothDescription =>
      'Manage the radio and connect paired or nearby devices.';

  @override
  String get settingsBluetoothDevicesDescription =>
      'Paired and nearby Bluetooth devices.';

  @override
  String get settingsBluetoothDevicesTitle => 'Devices';

  @override
  String get settingsBluetoothEnabled => 'Bluetooth enabled';

  @override
  String get settingsBluetoothEnabledDescription =>
      'Allow Denial to discover and connect Bluetooth devices.';

  @override
  String get settingsBluetoothRadioTitle => 'Bluetooth radio';

  @override
  String get settingsBluetoothSection => 'BLUETOOTH';

  @override
  String get settingsBluetoothTitle => 'Bluetooth devices.';

  @override
  String get settingsBluetoothUnavailable =>
      'Bluetooth controls are unavailable.';

  @override
  String get settingsBrightness => 'Brightness';

  @override
  String get settingsClockScale => 'Clock scale';

  @override
  String get settingsCloseEffectExplosion => 'Explosion';

  @override
  String get settingsCloseEffectFade => 'Fade';

  @override
  String get settingsCloseEffectImplode => 'Implode';

  @override
  String get settingsCloseEffectNone => 'None';

  @override
  String get settingsColorPickerCloseSemanticsLabel => 'Close color picker';

  @override
  String get settingsColorPickerDone => 'Done';

  @override
  String get settingsColorPickerInstructions =>
      'Drag to choose a color. Use the arrow keys for fine adjustments.';

  @override
  String get settingsColorPickerReset => 'Reset';

  @override
  String get settingsColorPickerRouteLabel => 'Shell accent color picker';

  @override
  String get settingsColorPickerTitle => 'Accent color';

  @override
  String get settingsColorWheelNextHue => 'Next hue';

  @override
  String get settingsColorWheelPreviousHue => 'Previous hue';

  @override
  String get settingsColorWheelSemanticsLabel => 'Shell accent color';

  @override
  String get settingsConnect => 'Connect';

  @override
  String get settingsConnected => 'Connected';

  @override
  String get settingsConnectedDisplaysDescription =>
      'Resolution, refresh rate, and scale for every output.';

  @override
  String get settingsConnectedDisplaysTitle => 'Connected displays';

  @override
  String get settingsDashboardOverlayDescription =>
      'Position the desktop dashboard.';

  @override
  String get settingsDashboardOverlayTitle => 'Dashboard';

  @override
  String get settingsDisconnect => 'Disconnect';

  @override
  String get settingsDisplayBrightnessDescription =>
      'Adjust the main display brightness.';

  @override
  String get settingsDisplayBrightnessTitle => 'Brightness';

  @override
  String settingsDisplayDetails(
    int width,
    int height,
    String refreshRate,
    String scale,
  ) {
    return '$width × $height · $refreshRate Hz · $scale×';
  }

  @override
  String get settingsDisplayInformationUnavailable =>
      'Display information is unavailable.';

  @override
  String get settingsDisplaysDescription =>
      'Review connected outputs and control screen brightness.';

  @override
  String get settingsDisplaysSection => 'DISPLAYS & VIDEO';

  @override
  String get settingsDisplaysTitle => 'Displays and video.';

  @override
  String get settingsEdgeDistance => 'Edge distance';

  @override
  String get settingsFocusedWindows => 'Focused windows';

  @override
  String get settingsHeaderContext => 'DENIAL / SYSTEM';

  @override
  String get settingsHeaderLogoSemanticsLabel => 'Denial';

  @override
  String get settingsHeight => 'Height';

  @override
  String get settingsHudOverlayDescription =>
      'Position volume and brightness feedback.';

  @override
  String get settingsHudOverlayTitle => 'System level display';

  @override
  String get settingsIdleInhibitDescription =>
      'Honor application requests that temporarily prevent display power-off.';

  @override
  String get settingsIdleInhibitSemantics =>
      'Applications may keep displays awake';

  @override
  String get settingsInactivityTimeout => 'Inactivity timeout';

  @override
  String get settingsLauncherOverlayDescription =>
      'Position the application launcher.';

  @override
  String get settingsLauncherOverlayTitle => 'Applications';

  @override
  String get settingsLayoutDescription =>
      'Control the spacing reserved around ordinary and maximized windows.';

  @override
  String get settingsLayoutSection => 'DESKTOP LAYOUT';

  @override
  String get settingsLayoutTitle => 'Give every window room to breathe.';

  @override
  String get settingsLiveBadge => 'LIVE';

  @override
  String get settingsLiveChangesSemanticsLabel =>
      'Changes are applied in real time';

  @override
  String get settingsLoadingAudio => 'Loading application audio…';

  @override
  String get settingsLockBackdropDescription =>
      'Control wallpaper darkness and blur while locked.';

  @override
  String get settingsLockBackdropTitle => 'Backdrop';

  @override
  String get settingsLockInformationDescription =>
      'Choose which useful details remain visible before sign-in.';

  @override
  String get settingsLockInformationTitle => 'Desktop status';

  @override
  String get settingsLockMotionDescription =>
      'Animate the desktop lock screen when it appears.';

  @override
  String get settingsLockMotionTitle => 'Lock screen motion';

  @override
  String get settingsLockPreviewDate => 'Thursday 23 July';

  @override
  String get settingsLockPreviewSemantics => 'Lock screen preview';

  @override
  String get settingsLockPreviewStatus => 'CPU 18% · GPU 12% · 52°C';

  @override
  String get settingsLockPreviewTime => '22:41';

  @override
  String get settingsLockScreenDescription =>
      'The main display presents an intentional sign-in stage while secondary displays remain calm and informative.';

  @override
  String get settingsLockScreenSection => 'LOCK SCREEN';

  @override
  String get settingsLockScreenTitle =>
      'A desktop lock screen, not a stretched phone.';

  @override
  String get settingsMasterOutputDescription =>
      'Set the current desktop output volume.';

  @override
  String get settingsMasterOutputTitle => 'Master output';

  @override
  String get settingsMaximizedSpacingDescription =>
      'Keep a small margin around maximized windows.';

  @override
  String get settingsMaximizedSpacingTitle => 'Maximized spacing';

  @override
  String get settingsDeveloperAutoReloadDescription =>
      'Let Denial watch the workspace and reload successful source changes. Available when the native tooling bridge is installed.';

  @override
  String get settingsDeveloperAutoReloadTitle => 'Reload when files change';

  @override
  String get settingsDeveloperBuildOptimized => 'Build & activate optimized';

  @override
  String get settingsDeveloperBuildRecoveryDescription =>
      'Promote the current workspace to an optimized shell, or return to a known working UI without restarting the Wayland session.';

  @override
  String get settingsDeveloperBuildRecoveryTitle => 'Build & recovery';

  @override
  String get settingsDeveloperDescription =>
      'Edit the complete Flutter desktop, reload it live, then promote it to an optimized build.';

  @override
  String get settingsDeveloperDiagnosticsTitle => 'Connection & diagnostics';

  @override
  String get settingsDeveloperEditorAttachDescription =>
      'Open the Flutter shell workspace in VSCodium, choose “Attach to Denial live UI” in Run and Debug, then save changed Dart files to reload the desktop. Native compositor changes require a normal rebuild.';

  @override
  String get settingsDeveloperEnableDescription =>
      'Run the selected workspace with the Dart VM service available for VSCodium and Flutter tooling.';

  @override
  String get settingsDeveloperEnableTitle => 'Enable live UI development';

  @override
  String get settingsDeveloperGeneration => 'Generation';

  @override
  String get settingsDeveloperHotReload => 'Hot reload';

  @override
  String get settingsDeveloperHotRestart => 'Hot restart';

  @override
  String get settingsDeveloperLiveControlsTitle => 'Live session';

  @override
  String get settingsDeveloperModeCustom => 'Custom optimized';

  @override
  String get settingsDeveloperModeLive => 'Live development';

  @override
  String get settingsDeveloperModeOfficial => 'Official optimized';

  @override
  String get settingsDeveloperModeUnavailable => 'Connecting';

  @override
  String get settingsDeveloperNoDiagnostics => 'No diagnostics reported.';

  @override
  String get settingsDeveloperPerformanceWarning =>
      'Live development uses a JIT Flutter engine and debug checks. Frame pacing and game performance will be lower until you return to an optimized build.';

  @override
  String get settingsDeveloperRefreshStatus => 'Refresh status';

  @override
  String get settingsDeveloperRestoreOfficial => 'Restore official UI';

  @override
  String get settingsDeveloperRevertLastWorking => 'Revert last working';

  @override
  String get settingsDeveloperRuntimeTitle => 'Flutter shell runtime';

  @override
  String get settingsDeveloperSection => 'DEVELOPER';

  @override
  String get settingsDeveloperSetupAction => 'Create and start editable UI';

  @override
  String get settingsDeveloperSetupDescription =>
      'Clone the version-matched Denial source from GitHub into ~/DenialUI, prepare it with the pinned toolchain, and enter live development.';

  @override
  String get settingsDeveloperSetupRunning =>
      'Preparing the editable UI. The shell will switch automatically when it is ready…';

  @override
  String get settingsDeveloperSetupUnavailable =>
      'Install denial-ui-development to enable automatic setup.';

  @override
  String get settingsDeveloperUseWorkspace => 'Use this workspace';

  @override
  String get settingsDeveloperVmServiceTitle => 'Dart VM service';

  @override
  String get settingsDeveloperWaitingForStatus =>
      'Waiting for native runtime status…';

  @override
  String get settingsDeveloperWorkspaceDescription =>
      'Select a Flutter project containing pubspec.yaml and lib/main.dart. Source changes can replace any shell UI that does not require a new native protocol.';

  @override
  String get settingsDeveloperWorkspaceFieldLabel => 'Flutter source workspace';

  @override
  String get settingsDeveloperWorkspaceHint => '/home/you/DenialUI/dart_shell';

  @override
  String get settingsDeveloperWorkspaceNotReady => 'Needs setup';

  @override
  String get settingsDeveloperWorkspaceReady => 'Ready';

  @override
  String get settingsDeveloperWorkspaceTitle => 'Source workspace';

  @override
  String settingsMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get settingsNavigationAbout => 'About';

  @override
  String get settingsNavigationAnimations => 'Animations';

  @override
  String get settingsNavigationAppearance => 'Appearance';

  @override
  String get settingsNavigationAudio => 'Audio';

  @override
  String get settingsNavigationBluetooth => 'Bluetooth';

  @override
  String get settingsNavigationDesktopLayout => 'Desktop layout';

  @override
  String get settingsNavigationDeveloper => 'Developer';

  @override
  String get settingsNavigationDisplays => 'Displays & video';

  @override
  String get settingsNavigationLockScreen => 'Lock screen';

  @override
  String get settingsNavigationNetwork => 'Network';

  @override
  String get settingsNavigationOverlays => 'Overlays';

  @override
  String get settingsNavigationPower => 'Power';

  @override
  String get settingsNavigationSection => 'SETTINGS';

  @override
  String get settingsNetworkDescription =>
      'Manage Wi-Fi and connect to nearby networks.';

  @override
  String get settingsNetworkSection => 'NETWORK';

  @override
  String get settingsNetworkStatusCaptivePortal => 'Sign-in required';

  @override
  String get settingsNetworkStatusConnecting => 'Connecting…';

  @override
  String get settingsNetworkStatusDisabled => 'Wi-Fi is off';

  @override
  String get settingsNetworkStatusDisconnected => 'Disconnected';

  @override
  String get settingsNetworkStatusLimited => 'Limited connection';

  @override
  String get settingsNetworkStatusLocal => 'Local network only';

  @override
  String get settingsNetworkStatusOnline => 'Online';

  @override
  String get settingsNetworkStatusUnavailable => 'Network unavailable';

  @override
  String get settingsNetworkTitle => 'Network connections.';

  @override
  String get settingsNetworkUnavailable => 'Network controls are unavailable.';

  @override
  String get settingsNoApplicationAudio => 'No applications are playing audio.';

  @override
  String get settingsNoBluetoothDevices => 'No Bluetooth devices found.';

  @override
  String get settingsNoNetworks => 'No networks found.';

  @override
  String get settingsNotificationOverlayDescription =>
      'Position notification banners.';

  @override
  String get settingsNotificationOverlayTitle => 'Notifications';

  @override
  String get settingsOneHour => '1 hour';

  @override
  String get settingsOuterPadding => 'Outer padding';

  @override
  String get settingsOutputVolume => 'Output volume';

  @override
  String get settingsOverlaysDescription =>
      'Choose the position and size of launchers, notifications, and system feedback.';

  @override
  String get settingsOverlaysSection => 'OVERLAYS';

  @override
  String get settingsOverlaysTitle => 'Put shell controls where they belong.';

  @override
  String get settingsPaired => 'Paired';

  @override
  String get settingsPanelMotionDescription =>
      'Tune the speed and travel of launcher and dashboard transitions.';

  @override
  String get settingsPanelMotionTitle => 'Panel motion';

  @override
  String get settingsPanelOpacity => 'Panel opacity';

  @override
  String get settingsPanelRadius => 'Panel radius';

  @override
  String get settingsPanelTravel => 'Panel travel';

  @override
  String get settingsPasswordRequired => 'Password required';

  @override
  String settingsPercent(int percent) {
    return '$percent%';
  }

  @override
  String settingsPixels(int pixels) {
    return '$pixels px';
  }

  @override
  String get settingsPowerDescription =>
      'Control display timeout behavior and idle inhibition.';

  @override
  String get settingsPowerSection => 'POWER';

  @override
  String get settingsPowerTitle => 'Power that respects your workflow.';

  @override
  String get settingsRefresh => 'Refresh';

  @override
  String get settingsResetPage => 'Reset page';

  @override
  String get settingsScan => 'Scan';

  @override
  String get settingsScanning => 'Scanning…';

  @override
  String get settingsScreenAnchor => 'Screen anchor';

  @override
  String get settingsShapeDescription => 'Tune window and panel corner radii.';

  @override
  String get settingsShapeTitle => 'Shape';

  @override
  String get settingsShellAccentChoose => 'Choose accent color';

  @override
  String get settingsShellAccentCustom => 'Custom color';

  @override
  String get settingsShellAccentDescription =>
      'The accent colors focused windows, controls, and active shell surfaces.';

  @override
  String get settingsShellAccentTitle => 'Shell accent';

  @override
  String get settingsShellAccentWallpaper => 'From wallpaper';

  @override
  String get settingsShowSystemStatus => 'Show performance and power status';

  @override
  String get settingsShowSystemStatusDescription =>
      'Show CPU, GPU, battery, and temperature information on the desktop lock screen.';

  @override
  String settingsSignalStrength(int strength) {
    return 'Signal: $strength%';
  }

  @override
  String get settingsStorageLocation =>
      'Settings are stored in\n~/.config/denial/settings.json';

  @override
  String get settingsSystemBarCloneHint =>
      'Each selected display gets its own bar. The bar never spans displays.';

  @override
  String get settingsSystemBarDescription =>
      'Place the bar on any edge and show an independent copy on every selected display.';

  @override
  String settingsSystemBarDisplayDetails(int width, int height, String scale) {
    return '$width × $height · $scale×';
  }

  @override
  String settingsSystemBarDisplayNotSelectedSemantics(String displayName) {
    return 'System bar not shown on $displayName';
  }

  @override
  String settingsSystemBarDisplaySelectedSemantics(String displayName) {
    return 'System bar shown on $displayName';
  }

  @override
  String get settingsSystemBarDisplaysLabel => 'DISPLAYS';

  @override
  String settingsSystemBarDisplaysSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count displays selected',
      one: '1 display selected',
    );
    return '$_temp0';
  }

  @override
  String get settingsSystemBarEdgeBottom => 'Bottom';

  @override
  String get settingsSystemBarEdgeLabel => 'EDGE';

  @override
  String get settingsSystemBarEdgeLeft => 'Left';

  @override
  String get settingsSystemBarEdgeRight => 'Right';

  @override
  String get settingsSystemBarEdgeTop => 'Top';

  @override
  String get settingsSystemBarLastDisplayHint =>
      'Select another display before removing this one.';

  @override
  String get settingsSystemBarMainDisplay => 'MAIN';

  @override
  String get settingsSystemBarTitle => 'Desktop system bar';

  @override
  String get settingsSystemBarUnavailable =>
      'Display information is not available yet.';

  @override
  String get settingsTwoHours => '2 hours';

  @override
  String get settingsUnfocusedWindows => 'Unfocused windows';

  @override
  String get settingsUseSystemWallpaper => 'Use system wallpaper';

  @override
  String get settingsUseSystemWallpaperDescription =>
      'The lock screen follows wallpaper changes and per-output assignments.';

  @override
  String get settingsWidth => 'Width';

  @override
  String get settingsWifiEnabled => 'Wi-Fi enabled';

  @override
  String get settingsWifiEnabledDescription =>
      'Allow Denial to scan for and connect to wireless networks.';

  @override
  String get settingsWifiTitle => 'Wi-Fi';

  @override
  String get settingsWindowCloseEffectDescription =>
      'Choose the animation used when a desktop window closes.';

  @override
  String get settingsWindowCloseEffectTitle => 'Window closing effect';

  @override
  String get settingsWindowOpacityDescription =>
      'Control the opacity of focused and unfocused windows.';

  @override
  String get settingsWindowOpacityTitle => 'Window opacity';

  @override
  String get settingsWindowRadius => 'Window radius';

  @override
  String shortDate(String weekday, int day, String month) {
    return '$weekday $day $month';
  }

  @override
  String statusBarLiveTime(String time) {
    return '$time · LIVE';
  }

  @override
  String get statusUnknown => 'Unknown';

  @override
  String get statusWaiting => 'Waiting';

  @override
  String temperatureCelsius(int temperature) {
    return '$temperature°C';
  }

  @override
  String get thermalSensorCpu => 'CPU';

  @override
  String get thermalSensorExp2 => 'EXP2';

  @override
  String get thermalSensorPmic => 'PMIC';

  @override
  String get thermalSensorSvooc => 'SVOOC';

  @override
  String timeHoursMinutes(String hour, String minute) {
    return '$hour:$minute';
  }

  @override
  String get valueUnavailable => '--.-';

  @override
  String voltageVolts(String voltage) {
    return '$voltage V';
  }

  @override
  String get volumeTitle => 'Volume';

  @override
  String get wallpaperAlignBottom => 'Bottom';

  @override
  String get wallpaperAlignHorizontalCenter => 'Horizontal center';

  @override
  String get wallpaperAlignLeft => 'Left';

  @override
  String get wallpaperAlignRight => 'Right';

  @override
  String get wallpaperAlignTop => 'Top';

  @override
  String get wallpaperAlignVerticalCenter => 'Vertical center';

  @override
  String get wallpaperAllDisplays => 'All displays';

  @override
  String get wallpaperApplyAllDisplays => 'Apply to all displays';

  @override
  String wallpaperApplyCandidate(String wallpaperName) {
    return 'Apply $wallpaperName';
  }

  @override
  String wallpaperApplyDisplay(String displayName) {
    return 'Apply to $displayName';
  }

  @override
  String get wallpaperCloseSelector => 'Close wallpaper selector';

  @override
  String get wallpaperDarkness => 'Wallpaper darkness';

  @override
  String get wallpaperDarknessShort => 'Darkness';

  @override
  String get wallpaperDecodeError => 'This wallpaper could not be decoded.';

  @override
  String get wallpaperDefault => 'Default';

  @override
  String wallpaperDimensions(int width, int height) {
    return '$width × $height';
  }

  @override
  String get wallpaperFinding => 'Finding wallpapers…';

  @override
  String get wallpaperNoneFound => 'No wallpapers found';

  @override
  String get wallpaperSearchHint => 'Search wallpapers';

  @override
  String get wallpaperSearchSemantics => 'Search wallpapers';

  @override
  String get wallpaperServiceUnavailable => 'Wallpaper service unavailable';

  @override
  String get wallpaperSpanAlignment => 'Span alignment';

  @override
  String get wallpaperTarget => 'Target';

  @override
  String get weekdayFriday => 'Friday';

  @override
  String get weekdayMonday => 'Monday';

  @override
  String get weekdaySaturday => 'Saturday';

  @override
  String get weekdaySunday => 'Sunday';

  @override
  String get weekdayThursday => 'Thursday';

  @override
  String get weekdayTuesday => 'Tuesday';

  @override
  String get weekdayWednesday => 'Wednesday';

  @override
  String get wifiAuthorizationMayBeRequired => 'Authorization may be required.';

  @override
  String get wifiCloseDetails => 'Close Wi-Fi details';

  @override
  String wifiConnectNetwork(String networkName, String status, int strength) {
    return 'Connect to $networkName, $status, signal $strength%';
  }

  @override
  String wifiDisconnectNetwork(String networkName) {
    return 'Disconnect from $networkName';
  }

  @override
  String get wifiDismissError => 'Dismiss Wi-Fi error';

  @override
  String wifiForgetNetwork(String networkName) {
    return 'Forget $networkName';
  }

  @override
  String get wifiHardwareBlocked => 'Wi-Fi is hardware blocked';

  @override
  String get wifiHardwareBlockedDescription =>
      'Enable the wireless hardware switch to continue.';

  @override
  String get wifiHardwareDisabled => 'Wi-Fi hardware disabled';

  @override
  String get wifiLimitedConnection => 'Limited connection';

  @override
  String get wifiLoadingService => 'Loading network service…';

  @override
  String get wifiLocalConnection => 'Local network';

  @override
  String get wifiLocalOnly => 'Local only';

  @override
  String wifiNamedStatus(String networkName, String status) {
    return '$networkName · $status';
  }

  @override
  String get wifiNoAdapter => 'No Wi-Fi adapter';

  @override
  String get wifiNoAdapterDescription =>
      'Wi-Fi controls will appear when an adapter is available.';

  @override
  String get wifiNoNetworks => 'No networks found';

  @override
  String get wifiNoNetworksDescription =>
      'Start a scan to find nearby networks.';

  @override
  String get wifiOff => 'Wi-Fi is off';

  @override
  String get wifiOffDescription => 'Turn it on to see nearby networks.';

  @override
  String get wifiOperationFailed => 'Wi-Fi could not complete the request.';

  @override
  String wifiPasswordField(String networkName) {
    return 'Password for $networkName';
  }

  @override
  String wifiPasswordFor(String networkName) {
    return 'Enter the password for $networkName';
  }

  @override
  String get wifiPasswordRequirements =>
      'Enter a password containing at least 8 characters.';

  @override
  String get wifiPermissionLimited => 'Network permissions are limited.';

  @override
  String get wifiSavedOutOfRange => 'Saved · out of range';

  @override
  String wifiSavedWithSecurity(String security) {
    return 'Saved · $security';
  }

  @override
  String get wifiScanNetworks => 'Scan for Wi-Fi networks';

  @override
  String get wifiScanningDescription =>
      'Nearby networks will appear automatically.';

  @override
  String get wifiScanningNetworks => 'Scanning for Wi-Fi networks…';

  @override
  String get wifiSecurityEnhancedOpen => 'Enhanced Open';

  @override
  String get wifiSecurityEnterprise => 'Enterprise';

  @override
  String get wifiSecurityOpen => 'Open';

  @override
  String get wifiSecurityUnsupported => 'Unsupported security';

  @override
  String get wifiSecurityWep => 'WEP';

  @override
  String get wifiSecurityWpa3Personal => 'WPA3 Personal';

  @override
  String get wifiSecurityWpaPersonal => 'WPA/WPA2 Personal';

  @override
  String get wifiServiceUnavailable => 'NetworkManager is unavailable';

  @override
  String get wifiServiceUnavailableDescription =>
      'Wi-Fi controls will return when the network service starts.';

  @override
  String get wifiServiceUnavailableShort => 'Network unavailable';

  @override
  String get wifiSignInRequired => 'Sign-in required';

  @override
  String get wifiTurnOff => 'Turn Wi-Fi off';

  @override
  String get wifiTurnOn => 'Turn Wi-Fi on';

  @override
  String get wifiWepRequirements =>
      'WEP keys must contain between 5 and 64 characters.';

  @override
  String windowSwitcherPosition(int position, int total) {
    return '$position / $total';
  }

  @override
  String windowSwitcherSelected(String windowTitle) {
    return 'Selected $windowTitle';
  }

  @override
  String windowUntitled(int windowId) {
    return 'Window $windowId';
  }
}
