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
  String get screenshotSelectionHint =>
      'Drag to select an area · Esc to cancel';

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
  String get clipboardCloseHistory => 'Close clipboard history';

  @override
  String get clipboardClearAll => 'Clear all';

  @override
  String get clipboardDelete => 'Delete';

  @override
  String get clipboardDeleteItem => 'Delete clipboard item';

  @override
  String get clipboardDragToClose =>
      'Drag clipboard tray toward its edge to close';

  @override
  String get clipboardEmptyDescription =>
      'Copy text, an image, or files and they will appear here.';

  @override
  String get clipboardEmptyTitle => 'Nothing captured yet';

  @override
  String get clipboardFileSelection => 'File selection';

  @override
  String get clipboardHistoryLockedDescription =>
      'Clipboard contents stay hidden while the session is locked.';

  @override
  String get clipboardHistoryLockedTitle => 'History is sealed';

  @override
  String get clipboardImageFileThumbnail => 'Image file thumbnail';

  @override
  String get clipboardImagePreview => 'Clipboard image preview';

  @override
  String get clipboardItemHint =>
      'Activate to paste it into the focused app. Drag it to drop it.';

  @override
  String clipboardItemSemantics(String type, String preview) {
    return '$type clipboard item. $preview';
  }

  @override
  String get clipboardPin => 'Pin';

  @override
  String get clipboardPinItem => 'Pin clipboard item';

  @override
  String get clipboardNoSearchResultsDescription =>
      'Try a different word, file type, or application.';

  @override
  String get clipboardNoSearchResultsTitle => 'No echoes found';

  @override
  String get clipboardPreviewUnavailable => 'Preview unavailable';

  @override
  String get clipboardTypeFiles => 'FILES';

  @override
  String get clipboardTypeImage => 'IMAGE';

  @override
  String get clipboardTypeText => 'TEXT';

  @override
  String get clipboardUnpin => 'Unpin';

  @override
  String get clipboardUnpinItem => 'Unpin clipboard item';

  @override
  String get clipboardUnavailableDescription =>
      'The native history service did not answer.';

  @override
  String get clipboardUnavailableTitle => 'Clipboard bridge unavailable';

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
  String get settingsBatteryChargeCycles => 'Charge cycles';

  @override
  String get settingsBatteryChargeEnd => 'Stop';

  @override
  String get settingsBatteryChargeLevel => 'Charge level';

  @override
  String get settingsBatteryChargeLimit => 'Charge limit';

  @override
  String get settingsBatteryChargeLimitDescription =>
      'Limit the full charge level to reduce battery wear.';

  @override
  String settingsBatteryChargeLimitEndDescription(int percent) {
    return 'Stop charging at $percent% to reduce battery wear.';
  }

  @override
  String get settingsBatteryChargeLimitLevelsReadOnly =>
      'Threshold levels are supplied by the system and are read-only in UPower.';

  @override
  String get settingsBatteryChargeLimitOptimizedDescription =>
      'Let the firmware choose a battery-preserving charging pattern.';

  @override
  String settingsBatteryChargeLimitStartEndDescription(int start, int end) {
    return 'Resume charging below $start% and stop at $end% to reduce battery wear.';
  }

  @override
  String get settingsBatteryChargeStart => 'Start';

  @override
  String get settingsBatteryCritical => 'Critical battery';

  @override
  String get settingsBatteryDevice => 'Device';

  @override
  String settingsBatteryDuration(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String get settingsBatteryEmpty => 'Empty';

  @override
  String get settingsBatteryFirmwareOptimized => 'Firmware optimized';

  @override
  String get settingsBatteryFullCapacity => 'Full capacity';

  @override
  String settingsBatteryFullCapacityValue(String full, String design) {
    return '$full / $design Wh';
  }

  @override
  String get settingsBatteryFullyCharged => 'Fully charged';

  @override
  String get settingsBatteryHealth => 'Health';

  @override
  String get settingsBatteryInformationTitle => 'Battery information';

  @override
  String get settingsBatteryLeadAcid => 'Lead acid';

  @override
  String get settingsBatteryLithiumIon => 'Lithium ion';

  @override
  String get settingsBatteryLithiumIronPhosphate => 'Lithium iron phosphate';

  @override
  String get settingsBatteryLithiumPolymer => 'Lithium polymer';

  @override
  String get settingsBatteryLoading => 'Reading battery information…';

  @override
  String get settingsBatteryLow => 'Low battery';

  @override
  String get settingsBatteryNickelCadmium => 'Nickel cadmium';

  @override
  String get settingsBatteryNickelMetalHydride => 'Nickel metal hydride';

  @override
  String get settingsBatteryNoSystemBattery =>
      'No system battery was detected.';

  @override
  String get settingsBatteryOnBatteryPower => 'On battery';

  @override
  String get settingsBatteryPendingCharge => 'Waiting to charge';

  @override
  String get settingsBatteryPendingDischarge => 'Waiting to discharge';

  @override
  String get settingsBatteryPluggedIn => 'Plugged in';

  @override
  String get settingsBatteryPowerRate => 'Power rate';

  @override
  String get settingsBatteryRefreshing => 'Refreshing…';

  @override
  String get settingsBatterySerial => 'Serial';

  @override
  String get settingsBatteryServiceUnavailable =>
      'UPower battery information is unavailable.';

  @override
  String get settingsBatteryStoredEnergy => 'Stored energy';

  @override
  String get settingsBatteryTechnology => 'Technology';

  @override
  String get settingsBatteryTemperature => 'Temperature';

  @override
  String get settingsBatteryTimeRemaining => 'Time remaining';

  @override
  String get settingsBatteryTimeToFull => 'Time to full';

  @override
  String get settingsBatteryUnknownDevice => 'System battery';

  @override
  String get settingsBatteryUpdateFailed =>
      'UPower could not refresh or change the battery settings.';

  @override
  String get settingsBatteryVoltage => 'Voltage';

  @override
  String settingsBatteryWattHours(String value) {
    return '$value Wh';
  }

  @override
  String get settingsBackdropBlur => 'Backdrop blur';

  @override
  String get settingsBackdropBlurDescription =>
      'Soften content behind translucent windows and panels. Higher quality uses more GPU.';

  @override
  String get settingsBackdropBlurEnabled => 'Enable backdrop blur';

  @override
  String get settingsBackdropBlurEnabledDescription =>
      'Blur only where transparent content can reveal the desktop beneath it.';

  @override
  String get settingsBackdropBlurIntensity => 'Blur quality';

  @override
  String get settingsBackdropBlurLevelShitty => 'Shitty';

  @override
  String get settingsBackdropBlurLevelFast => 'Fast';

  @override
  String get settingsBackdropBlurLevelGood => 'Good';

  @override
  String get settingsBackdropBlurLevelBest => 'Best';

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
  String get settingsCursorSize => 'Cursor size';

  @override
  String get settingsCursorTitle => 'Cursor';

  @override
  String get settingsDashboardOverlayDescription =>
      'Position the desktop dashboard.';

  @override
  String get settingsDashboardOverlayTitle => 'Dashboard';

  @override
  String get settingsDisconnect => 'Disconnect';

  @override
  String get settingsApplying => 'Applying…';

  @override
  String get settingsApplyDisplayConfiguration => 'Apply changes';

  @override
  String get settingsDisplayApplyPersistentHint =>
      'Keep changes to update this session and outputs.conf.';

  @override
  String get settingsDisplayApplySessionHint =>
      'Keep changes to use them for this session.';

  @override
  String get settingsDisplayConfirmationTitle => 'Keep these display settings?';

  @override
  String settingsDisplayConfirmationMessage(int seconds) {
    return 'The previous display settings will be restored automatically in $seconds s.';
  }

  @override
  String get settingsDisplayKeepChanges => 'Keep changes';

  @override
  String get settingsDisplayRevertNow => 'Revert now';

  @override
  String get settingsDisplayArrangementSemantics =>
      'Monitor arrangement editor';

  @override
  String get settingsDisplayCanvasPanHint =>
      'Drag empty space to move the canvas. Use the mouse wheel to zoom.';

  @override
  String get settingsDisplayCanvasPanSemantics => 'Pannable monitor canvas';

  @override
  String get settingsDisplayArrangementTitle => 'Monitor configuration';

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
  String settingsDisplayPosition(int x, int y) {
    return 'Position $x, $y';
  }

  @override
  String get settingsDisplayPrimary => 'Primary display';

  @override
  String get settingsDisplayPrimaryAutomatic =>
      'Automatic (highest refresh rate)';

  @override
  String get settingsDisplayPrimaryHint =>
      'Shell surfaces open on the primary display. Automatic uses the connected display with the highest refresh rate.';

  @override
  String get settingsDisplayRefreshRate => 'Refresh rate';

  @override
  String get settingsDisplayResolution => 'Resolution';

  @override
  String get settingsDisplayRotation => 'Rotation';

  @override
  String get settingsDisplayRotationNormal => 'Landscape';

  @override
  String get settingsDisplayRotation90 => '90° clockwise';

  @override
  String get settingsDisplayRotation180 => 'Upside down';

  @override
  String get settingsDisplayRotation270 => '90° counterclockwise';

  @override
  String get settingsDisplayScale => 'Scale';

  @override
  String get settingsDisplayVariableRefreshRate =>
      'Variable refresh rate (VRR)';

  @override
  String get settingsDisplayVariableRefreshRateDescription =>
      'Match the monitor refresh rate to rendered content.';

  @override
  String get settingsDisplayZoomFit => 'Fit all monitors';

  @override
  String get settingsDisplayZoomIn => 'Zoom in';

  @override
  String settingsDisplayZoomLevel(int percent) {
    return 'Canvas zoom $percent%';
  }

  @override
  String get settingsDisplayZoomOut => 'Zoom out';

  @override
  String get settingsLoadingDisplays => 'Loading monitor configuration…';

  @override
  String get settingsMonitorDragHint =>
      'Drag to arrange, or use the arrow keys to move.';

  @override
  String settingsMonitorSemantics(String name) {
    return 'Monitor $name';
  }

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
  String get settingsLanguageDescription =>
      'System default follows your desktop language. Changes apply immediately.';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsLanguageInterfaceTitle => 'Interface language';

  @override
  String get settingsLanguageSection => 'LANGUAGE';

  @override
  String get settingsLanguageSelectorSemantics => 'Denial interface language';

  @override
  String get settingsLanguageSimplifiedChinese => '简体中文';

  @override
  String get settingsLanguageSystemDefault => 'System default';

  @override
  String get settingsLanguageTitle => 'Choose the language Denial uses.';

  @override
  String get settingsKeyboardSection => 'INPUT';

  @override
  String get settingsKeyboardTitle =>
      'Configure the physical keyboard used by Flutter, Wayland, and Xwayland.';

  @override
  String get settingsKeyboardLayoutsTitle => 'Layouts and variants';

  @override
  String get settingsKeyboardLayoutsDescription =>
      'Enter layouts in switching order. Add a variant after a colon, for example us, de:nodeadkeys.';

  @override
  String get settingsKeyboardLayoutsLabel => 'Layouts';

  @override
  String get settingsKeyboardLayoutsHint => 'us, de:nodeadkeys';

  @override
  String get settingsKeyboardOptionsLabel => 'XKB options';

  @override
  String get settingsKeyboardOptionsHint => 'compose:menu, caps:escape';

  @override
  String get settingsKeyboardOptionsDescription =>
      'Comma-separated options enable Compose, alternate group shortcuts, Caps remapping, and other XKB behavior.';

  @override
  String get settingsKeyboardRepeatTitle => 'Key repeat';

  @override
  String get settingsKeyboardRepeatDelay => 'Delay';

  @override
  String get settingsKeyboardRepeatRate => 'Rate';

  @override
  String get settingsKeyboardSwitchingTitle => 'Layout switching';

  @override
  String get settingsKeyboardActiveLayout => 'Active layout';

  @override
  String get settingsKeyboardSwitchingShortcut =>
      'Super+Space selects the next layout. Add Shift to select the previous one.';

  @override
  String get settingsKeyboardApply => 'Apply keyboard settings';

  @override
  String get settingsKeyboardApplying => 'Applying…';

  @override
  String get settingsKeyboardLoading =>
      'Reading the compositor keyboard configuration…';

  @override
  String get settingsKeyboardInvalidLayouts =>
      'Enter at least one valid XKB layout.';

  @override
  String get settingsTouchpadSection => 'INPUT';

  @override
  String get settingsTouchpadTitle => 'Use your touchpad across the desktop.';

  @override
  String get settingsTouchpadTapToClick => 'Tap to click';

  @override
  String get settingsTouchpadTapToClickDescription =>
      'Tap the touchpad to press the primary mouse button.';

  @override
  String get settingsTouchpadNaturalScroll => 'Reverse two-finger scrolling';

  @override
  String get settingsTouchpadNaturalScrollDescription =>
      'Move content in the same direction as your fingers.';

  @override
  String get settingsTouchpadScrollSpeed => 'Finger scroll speed';

  @override
  String get settingsShortcutsSection => 'SHORTCUTS';

  @override
  String get settingsShortcutsTitle =>
      'Choose what Denial does when a shortcut is pressed.';

  @override
  String settingsShortcutsConfigured(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count shortcuts',
      one: '1 shortcut',
      zero: 'No shortcuts',
    );
    return '$_temp0';
  }

  @override
  String get settingsShortcutsAdd => 'Add shortcut';

  @override
  String get settingsShortcutsLoading =>
      'Reading shortcuts from the compositor…';

  @override
  String get settingsShortcutsUnavailable =>
      'The compositor shortcut configuration is unavailable.';

  @override
  String get settingsShortcutsRetry => 'Retry';

  @override
  String get settingsShortcutsEmpty =>
      'No shortcuts are configured. Add one to make an action easier to reach.';

  @override
  String settingsShortcutsRowSemantics(String shortcut, String action) {
    return '$shortcut, $action';
  }

  @override
  String settingsShortcutsDeleteTooltip(String shortcut) {
    return 'Delete $shortcut';
  }

  @override
  String get settingsShortcutEditorAddTitle => 'Add shortcut';

  @override
  String get settingsShortcutEditorEditTitle => 'Edit shortcut';

  @override
  String get settingsShortcutEditorDescription =>
      'Write a shortcut, choose what it runs, and let the compositor check it before saving.';

  @override
  String get settingsShortcutEditorShortcutLabel => 'Shortcut';

  @override
  String get settingsShortcutEditorShortcutHint => 'Super+K';

  @override
  String get settingsShortcutEditorShortcutExample =>
      'Examples: Super+K · Ctrl+Alt+Backspace · ThreeFingerSwipeLeft';

  @override
  String get settingsShortcutEditorSupportedInputs => 'Supported inputs';

  @override
  String get settingsShortcutEditorTargetLabel => 'Runs';

  @override
  String get settingsShortcutEditorTargetAction => 'Denial action';

  @override
  String get settingsShortcutEditorTargetApplication => 'Application';

  @override
  String get settingsShortcutEditorTargetProgram => 'Program';

  @override
  String get settingsShortcutEditorTargetShell => 'Shell command';

  @override
  String get settingsShortcutEditorProgramDescription =>
      'Run a program directly, without a shell. Every argument is passed exactly as written.';

  @override
  String get settingsShortcutEditorProgramLabel => 'Program';

  @override
  String get settingsShortcutEditorProgramHint => 'foot';

  @override
  String get settingsShortcutEditorArgumentsLabel => 'Arguments';

  @override
  String get settingsShortcutEditorAddArgument => 'Add argument';

  @override
  String get settingsShortcutEditorNoArguments => 'No arguments';

  @override
  String settingsShortcutEditorArgumentLabel(int index) {
    return 'Argument $index';
  }

  @override
  String get settingsShortcutEditorArgumentHint => '--option';

  @override
  String settingsShortcutEditorRemoveArgument(int index) {
    return 'Remove argument $index';
  }

  @override
  String get settingsShortcutEditorShellDescription =>
      'Run one command through sh -c. Shell variables, pipelines, redirects, and command chaining are supported.';

  @override
  String get settingsShortcutEditorShellCommandLabel => 'Shell command';

  @override
  String get settingsShortcutEditorShellCommandHint =>
      'grim -g \"\$(slurp)\" ~/Pictures/capture.png';

  @override
  String get settingsShortcutEditorChooseAction => 'Choose an action';

  @override
  String get settingsShortcutEditorChooseApplication => 'Choose an application';

  @override
  String settingsShortcutApplicationTarget(String desktopFileId) {
    return 'Application · $desktopFileId';
  }

  @override
  String get settingsShortcutEditorValidating =>
      'Checking with the compositor…';

  @override
  String settingsShortcutEditorValid(String shortcut) {
    return 'Recognized as $shortcut';
  }

  @override
  String settingsShortcutEditorConflict(String shortcut, String action) {
    return '$shortcut is already assigned to $action.';
  }

  @override
  String get settingsShortcutEditorSearch => 'Search';

  @override
  String get settingsShortcutEditorNoResults => 'No matching entries.';

  @override
  String get settingsShortcutEditorBack => 'Back to shortcut editor';

  @override
  String get settingsShortcutEditorDone => 'Done';

  @override
  String get settingsShortcutEditorCancel => 'Cancel';

  @override
  String get settingsShortcutEditorSave => 'Save';

  @override
  String get settingsShortcutEditorSaving => 'Saving…';

  @override
  String get settingsShortcutEditorDelete => 'Delete';

  @override
  String get settingsShortcutGestureThreeFingerSwipeUp =>
      'Three-finger swipe up';

  @override
  String get settingsShortcutGestureThreeFingerSwipeLeft =>
      'Three-finger swipe left';

  @override
  String get settingsShortcutGestureThreeFingerSwipeRight =>
      'Three-finger swipe right';

  @override
  String get settingsShortcutInputCategoryModifier => 'Modifier';

  @override
  String get settingsShortcutInputCategoryNavigation => 'Navigation';

  @override
  String get settingsShortcutInputCategoryEditing => 'Editing';

  @override
  String get settingsShortcutInputCategoryPunctuation => 'Punctuation';

  @override
  String get settingsShortcutInputCategoryFunction => 'Function';

  @override
  String get settingsShortcutInputCategoryMedia => 'Media';

  @override
  String get settingsShortcutInputCategoryHardware => 'Hardware';

  @override
  String get settingsShortcutInputCategorySpecial => 'Special';

  @override
  String get settingsShortcutInputCategoryGesture => 'Gesture';

  @override
  String get settingsShortcutActionShutdown => 'Shut down';

  @override
  String get settingsShortcutActionOpenApplications => 'Open applications';

  @override
  String get settingsShortcutActionOpenSettings => 'Open Settings';

  @override
  String get settingsShortcutActionOpenOverview => 'Open overview';

  @override
  String get settingsShortcutActionToggleVerticalMaximize =>
      'Maximize vertically';

  @override
  String get settingsShortcutActionWindowSwitcher => 'Switch windows';

  @override
  String get settingsShortcutActionOpenClipboard => 'Open clipboard';

  @override
  String get settingsShortcutActionCaptureRegion => 'Capture region';

  @override
  String get settingsShortcutActionCloseWindow => 'Close window';

  @override
  String get settingsShortcutActionMinimizeWindow => 'Minimize window';

  @override
  String get settingsShortcutActionToggleMaximize => 'Maximize or restore';

  @override
  String get settingsShortcutActionToggleFullscreen =>
      'Enter or leave fullscreen';

  @override
  String get settingsShortcutActionReleasePointer => 'Release pointer';

  @override
  String get settingsShortcutActionLockScreen => 'Lock screen';

  @override
  String get settingsShortcutActionVolumeUp => 'Increase volume';

  @override
  String get settingsShortcutActionVolumeDown => 'Decrease volume';

  @override
  String get settingsShortcutActionVolumeMute => 'Mute or unmute';

  @override
  String get settingsShortcutActionBrightnessUp => 'Increase brightness';

  @override
  String get settingsShortcutActionBrightnessDown => 'Decrease brightness';

  @override
  String get settingsShortcutActionNextKeyboardLayout => 'Next keyboard layout';

  @override
  String get settingsShortcutActionPreviousKeyboardLayout =>
      'Previous keyboard layout';

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
  String get settingsEnvironmentAdd => 'Add';

  @override
  String get settingsEnvironmentAddedStatus => 'Added to launched applications';

  @override
  String get settingsEnvironmentAddModeDescription =>
      'Inject a literal value when Denial executes an application. An empty value is preserved as an empty string.';

  @override
  String get settingsEnvironmentAllApplications => 'All applications';

  @override
  String get settingsEnvironmentAllApplicationsDescription =>
      'Default launch environment';

  @override
  String settingsEnvironmentApplicationInherited(int count) {
    return 'Inherits $count all-app rules';
  }

  @override
  String get settingsEnvironmentApplicationSearchHint =>
      'Search applications or desktop IDs';

  @override
  String get settingsEnvironmentApplicationsTitle => 'Applications';

  @override
  String get settingsEnvironmentApplicationsUnavailable =>
      'Installed applications could not be loaded.';

  @override
  String get settingsEnvironmentBackToApplications => 'Back to applications';

  @override
  String get settingsEnvironmentCancel => 'Cancel';

  @override
  String get settingsEnvironmentClearScope => 'Clear';

  @override
  String settingsEnvironmentDeleteVariable(String variable) {
    return 'Delete $variable';
  }

  @override
  String settingsEnvironmentEditVariable(String variable) {
    return 'Edit $variable';
  }

  @override
  String get settingsEnvironmentEditorDescription =>
      'Set a value, leave it empty to pass an empty string, or choose Remove to keep the variable out of the child process.';

  @override
  String settingsEnvironmentEditorEditTitle(String variable) {
    return 'Edit $variable';
  }

  @override
  String get settingsEnvironmentEditorTitle => 'Add an override';

  @override
  String get settingsEnvironmentEmptyDescription =>
      'Add a variable above to change the environment of subsequently launched applications.';

  @override
  String get settingsEnvironmentEmptyTitle => 'No overrides';

  @override
  String get settingsEnvironmentEmptyValue => 'Empty string';

  @override
  String get settingsEnvironmentHiddenStatus =>
      'Hidden from launched applications';

  @override
  String get settingsEnvironmentHide => 'Hide';

  @override
  String get settingsEnvironmentHideModeDescription =>
      'Strip an inherited variable immediately before exec. The application behaves as if that name was never exported.';

  @override
  String get settingsEnvironmentNameDuplicate =>
      'That variable already has an override.';

  @override
  String get settingsEnvironmentNameHint => 'e.g. MOZ_ENABLE_WAYLAND';

  @override
  String get settingsEnvironmentNameInvalid =>
      'Use letters, numbers, and underscores, beginning with a letter or underscore.';

  @override
  String get settingsEnvironmentNameLabel => 'Variable name';

  @override
  String get settingsEnvironmentNameRequired => 'Enter a variable name.';

  @override
  String get settingsEnvironmentOverridesDefault =>
      'Overrides the all-applications rule';

  @override
  String get settingsEnvironmentModeAdd => 'Add Variable';

  @override
  String get settingsEnvironmentModeHide => 'Hide Variable';

  @override
  String get settingsEnvironmentRemoveDescription =>
      'Denial will remove this inherited variable before starting the application.';

  @override
  String get settingsEnvironmentRemoveLabel =>
      'Remove from launched applications';

  @override
  String get settingsEnvironmentRemovedValue =>
      'Removed from child environment';

  @override
  String get settingsEnvironmentScopeDescription =>
      'These overrides apply only to applications and shortcut commands started by Denial. They affect subsequent launches, not XDG autostart entries, systemd services, D-Bus services, or Denial itself.';

  @override
  String get settingsEnvironmentScopeTitle => 'Launch scope';

  @override
  String get settingsEnvironmentSection => 'APPLICATIONS';

  @override
  String get settingsEnvironmentTitle =>
      'Customize the environment of applications launched by Denial.';

  @override
  String get settingsEnvironmentUpdate => 'Update variable';

  @override
  String get settingsEnvironmentUnavailableApplication =>
      'Unavailable application';

  @override
  String get settingsEnvironmentValueHint => 'e.g. 1';

  @override
  String get settingsEnvironmentValueLabel => 'Value';

  @override
  String get settingsEnvironmentValueNul =>
      'Values cannot contain a NUL character.';

  @override
  String get settingsEnvironmentValueTooLong => 'The value is too long.';

  @override
  String settingsEnvironmentVariablesStatus(int count) {
    return '$count configured';
  }

  @override
  String get settingsEnvironmentVariablesTitle => 'Configured overrides';

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
  String get settingsNavigationEnvironment => 'App environment';

  @override
  String get settingsNavigationDisplays => 'Displays & video';

  @override
  String get settingsNavigationLanguage => 'Language';

  @override
  String get settingsNavigationKeyboard => 'Keyboard';

  @override
  String get settingsNavigationTouchpad => 'Touchpad';

  @override
  String get settingsNavigationShortcuts => 'Shortcuts';

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
  String get settingsColorSchemeTitle => 'Colour scheme';

  @override
  String get settingsColorSchemeDark => 'Dark';

  @override
  String get settingsColorSchemeLight => 'Light';

  @override
  String get settingsColorSchemeNoPreference => 'No preference';

  @override
  String get settingsColorSchemeDescription =>
      'Use the same colour scheme across Denial and supported applications.';

  @override
  String get settingsColorSchemeNoPreferenceDescription =>
      'Denial keeps its default dark appearance while applications choose their own.';

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
  String get settingsWallpaperChoose => 'Choose wallpaper';

  @override
  String get settingsWallpaperDescription =>
      'Choose the image shown behind the shell and on the lock screen.';

  @override
  String get settingsWallpaperPreviewSemantics => 'Current wallpaper preview';

  @override
  String get settingsWallpaperTitle => 'Wallpaper';

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
  String get wallpaperMobileBackToSelection => 'Back to wallpaper selection';

  @override
  String get wallpaperMobileCenterPosition => 'Center';

  @override
  String get wallpaperMobileChoose => 'Choose a wallpaper';

  @override
  String get wallpaperMobileDone => 'Done';

  @override
  String get wallpaperMobileHideControls => 'Hide controls';

  @override
  String get wallpaperMobileHorizontalPosition => 'Horizontal';

  @override
  String get wallpaperMobilePosition => 'Position';

  @override
  String get wallpaperMobilePositionHint =>
      'Drag the wallpaper, then fine-tune its position';

  @override
  String get wallpaperMobileShowControls => 'Show controls';

  @override
  String get wallpaperMobileTitle => 'Wallpaper';

  @override
  String get wallpaperMobileVerticalPosition => 'Vertical';

  @override
  String get wallpaperNoneFound => 'No wallpapers found';

  @override
  String get wallpaperSearchHint => 'Search wallpapers';

  @override
  String get wallpaperSearchSemantics => 'Search wallpapers';

  @override
  String get wallpaperServiceUnavailable => 'Wallpaper service unavailable';

  @override
  String get wallpaperSpanAlignment => 'Image position';

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
  String get wifiServiceUnavailable => 'Network service is unavailable';

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
