import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// Application appearance synchronization setting.
  ///
  /// In en, this message translates to:
  /// **'Theme supported application using Denial styling'**
  String get settingsApplicationThemingEnabled;

  /// Application appearance synchronization setting.
  ///
  /// In en, this message translates to:
  /// **'Apply Denial styling to supported application. Currently supported applications: Kitty.'**
  String get settingsApplicationThemingDescription;

  /// Application appearance synchronization setting.
  ///
  /// In en, this message translates to:
  /// **'Re-apply'**
  String get settingsApplicationThemingReapply;

  /// Scrolling layout swap setting.
  ///
  /// In en, this message translates to:
  /// **'Scrolling swaps'**
  String get settingsScrollingLayoutSwapTitle;

  /// Scrolling layout swap setting.
  ///
  /// In en, this message translates to:
  /// **'Keep window sizes when swapping'**
  String get settingsScrollingLayoutPreserveSwapSizes;

  /// Scrolling layout swap setting.
  ///
  /// In en, this message translates to:
  /// **'Keep each window’s width when swapping single-window columns on the same workspace and display. On vertical strips, keep height instead. Split columns keep their existing sizes.'**
  String get settingsScrollingLayoutPreserveSwapSizesDescription;

  /// Accessible label for a home widget resize handle.
  ///
  /// In en, this message translates to:
  /// **'Resize widget'**
  String get homeResizeWidget;

  /// English UI text for actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// English UI text for actionDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get actionDismiss;

  /// Instruction shown while selecting a desktop screenshot region.
  ///
  /// In en, this message translates to:
  /// **'Drag to select an area · Esc to cancel'**
  String get screenshotSelectionHint;

  /// English UI text for anchorBottomCenter.
  ///
  /// In en, this message translates to:
  /// **'Bottom center'**
  String get anchorBottomCenter;

  /// English UI text for anchorBottomLeft.
  ///
  /// In en, this message translates to:
  /// **'Bottom left'**
  String get anchorBottomLeft;

  /// English UI text for anchorBottomRight.
  ///
  /// In en, this message translates to:
  /// **'Bottom right'**
  String get anchorBottomRight;

  /// English UI text for anchorCenter.
  ///
  /// In en, this message translates to:
  /// **'Center'**
  String get anchorCenter;

  /// English UI text for anchorCenterLeft.
  ///
  /// In en, this message translates to:
  /// **'Center left'**
  String get anchorCenterLeft;

  /// English UI text for anchorCenterRight.
  ///
  /// In en, this message translates to:
  /// **'Center right'**
  String get anchorCenterRight;

  /// English UI text for anchorTopCenter.
  ///
  /// In en, this message translates to:
  /// **'Top center'**
  String get anchorTopCenter;

  /// English UI text for anchorTopLeft.
  ///
  /// In en, this message translates to:
  /// **'Top left'**
  String get anchorTopLeft;

  /// English UI text for anchorTopRight.
  ///
  /// In en, this message translates to:
  /// **'Top right'**
  String get anchorTopRight;

  /// English UI text for batteryCapacityUnavailable.
  ///
  /// In en, this message translates to:
  /// **'--'**
  String get batteryCapacityUnavailable;

  /// English UI text for batteryCharging.
  ///
  /// In en, this message translates to:
  /// **'Charging'**
  String get batteryCharging;

  /// English UI text for batteryDischarging.
  ///
  /// In en, this message translates to:
  /// **'Discharging'**
  String get batteryDischarging;

  /// English UI text for batteryGraphMarker.
  ///
  /// In en, this message translates to:
  /// **'{label} {value}'**
  String batteryGraphMarker(String label, String value);

  /// English UI text for batteryIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get batteryIdle;

  /// Message shown when the battery crosses a low-charge warning threshold.
  ///
  /// In en, this message translates to:
  /// **'Battery is at {percent}%. Connect a charger.'**
  String batteryLowNotificationBody(int percent);

  /// Title for the 20% and 15% battery notifications.
  ///
  /// In en, this message translates to:
  /// **'Low battery'**
  String get batteryLowNotificationTitle;

  /// Title for the 10%, 5%, and 1% battery notifications.
  ///
  /// In en, this message translates to:
  /// **'Critical battery'**
  String get batteryCriticalNotificationTitle;

  /// English UI text for batteryStateAndPercent.
  ///
  /// In en, this message translates to:
  /// **'{state} {percent}%'**
  String batteryStateAndPercent(String state, int percent);

  /// English UI text for batteryTitle.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get batteryTitle;

  /// English UI text for bluetoothAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get bluetoothAllow;

  /// English UI text for bluetoothAllowPairing.
  ///
  /// In en, this message translates to:
  /// **'Allow {deviceName} to pair?'**
  String bluetoothAllowPairing(String deviceName);

  /// English UI text for bluetoothAllowService.
  ///
  /// In en, this message translates to:
  /// **'Allow a Bluetooth service?'**
  String get bluetoothAllowService;

  /// English UI text for bluetoothAvailableSignal.
  ///
  /// In en, this message translates to:
  /// **'Available · {signal} dBm'**
  String bluetoothAvailableSignal(int signal);

  /// English UI text for bluetoothBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get bluetoothBlocked;

  /// English UI text for bluetoothCloseDetails.
  ///
  /// In en, this message translates to:
  /// **'Close Bluetooth details'**
  String get bluetoothCloseDetails;

  /// English UI text for bluetoothCodeDisplayed.
  ///
  /// In en, this message translates to:
  /// **'Code displayed'**
  String get bluetoothCodeDisplayed;

  /// English UI text for bluetoothConfirmCode.
  ///
  /// In en, this message translates to:
  /// **'Confirm that both devices display {code}.'**
  String bluetoothConfirmCode(String code);

  /// English UI text for bluetoothConfirmDevice.
  ///
  /// In en, this message translates to:
  /// **'Confirm {deviceName}'**
  String bluetoothConfirmDevice(String deviceName);

  /// English UI text for bluetoothConnectDeviceStatus.
  ///
  /// In en, this message translates to:
  /// **'Connect {deviceName}, {status}'**
  String bluetoothConnectDeviceStatus(String deviceName, String status);

  /// English UI text for bluetoothConnectedConfiguring.
  ///
  /// In en, this message translates to:
  /// **'Connected · configuring services'**
  String get bluetoothConnectedConfiguring;

  /// English UI text for bluetoothDevicesConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected devices: {count}'**
  String bluetoothDevicesConnected(int count);

  /// English UI text for bluetoothDismissError.
  ///
  /// In en, this message translates to:
  /// **'Dismiss Bluetooth error'**
  String get bluetoothDismissError;

  /// English UI text for bluetoothEnterPasskey.
  ///
  /// In en, this message translates to:
  /// **'Enter the passkey for {deviceName}'**
  String bluetoothEnterPasskey(String deviceName);

  /// English UI text for bluetoothEnterPasskeyOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Enter this passkey on {deviceName}'**
  String bluetoothEnterPasskeyOnDevice(String deviceName);

  /// English UI text for bluetoothEnterPin.
  ///
  /// In en, this message translates to:
  /// **'Enter the PIN for {deviceName}'**
  String bluetoothEnterPin(String deviceName);

  /// English UI text for bluetoothEnterPinOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Enter this PIN on {deviceName}'**
  String bluetoothEnterPinOnDevice(String deviceName);

  /// English UI text for bluetoothLoadingService.
  ///
  /// In en, this message translates to:
  /// **'Loading Bluetooth service…'**
  String get bluetoothLoadingService;

  /// English UI text for bluetoothNoAdapter.
  ///
  /// In en, this message translates to:
  /// **'No Bluetooth adapter'**
  String get bluetoothNoAdapter;

  /// English UI text for bluetoothNoAdapterDescription.
  ///
  /// In en, this message translates to:
  /// **'Denial will enable these controls when an adapter appears.'**
  String get bluetoothNoAdapterDescription;

  /// English UI text for bluetoothNoAdapterShort.
  ///
  /// In en, this message translates to:
  /// **'No adapter'**
  String get bluetoothNoAdapterShort;

  /// English UI text for bluetoothNoDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices found'**
  String get bluetoothNoDevices;

  /// English UI text for bluetoothNoDevicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Start a scan and make the other device discoverable.'**
  String get bluetoothNoDevicesDescription;

  /// English UI text for bluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off'**
  String get bluetoothOff;

  /// English UI text for bluetoothOffDescription.
  ///
  /// In en, this message translates to:
  /// **'Turn it on to see paired and nearby devices.'**
  String get bluetoothOffDescription;

  /// English UI text for bluetoothOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth could not complete the request.'**
  String get bluetoothOperationFailed;

  /// English UI text for bluetoothPairDevice.
  ///
  /// In en, this message translates to:
  /// **'Pair {deviceName}'**
  String bluetoothPairDevice(String deviceName);

  /// English UI text for bluetoothPairedTrusted.
  ///
  /// In en, this message translates to:
  /// **'Paired · trusted'**
  String get bluetoothPairedTrusted;

  /// English UI text for bluetoothPasskey.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth passkey'**
  String get bluetoothPasskey;

  /// English UI text for bluetoothPasskeyPrivacy.
  ///
  /// In en, this message translates to:
  /// **'The passkey is sent once to BlueZ and is not retained by Denial.'**
  String get bluetoothPasskeyPrivacy;

  /// English UI text for bluetoothPasskeyProgress.
  ///
  /// In en, this message translates to:
  /// **'{code} · {enteredDigits} of 6 digits entered.'**
  String bluetoothPasskeyProgress(String code, int enteredDigits);

  /// English UI text for bluetoothPasskeyRequirements.
  ///
  /// In en, this message translates to:
  /// **'Enter a numeric passkey up to 6 digits.'**
  String get bluetoothPasskeyRequirements;

  /// English UI text for bluetoothPinCode.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth PIN code'**
  String get bluetoothPinCode;

  /// English UI text for bluetoothPinPrivacy.
  ///
  /// In en, this message translates to:
  /// **'The PIN is sent once to BlueZ and is not retained by Denial.'**
  String get bluetoothPinPrivacy;

  /// English UI text for bluetoothPinRequirements.
  ///
  /// In en, this message translates to:
  /// **'Enter a PIN containing 1–16 characters.'**
  String get bluetoothPinRequirements;

  /// English UI text for bluetoothRecognizeDevice.
  ///
  /// In en, this message translates to:
  /// **'Only continue if you recognize this device.'**
  String get bluetoothRecognizeDevice;

  /// English UI text for bluetoothReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get bluetoothReject;

  /// English UI text for bluetoothRemoveDevice.
  ///
  /// In en, this message translates to:
  /// **'Remove {deviceName}'**
  String bluetoothRemoveDevice(String deviceName);

  /// English UI text for bluetoothSameCode.
  ///
  /// In en, this message translates to:
  /// **'the same code'**
  String get bluetoothSameCode;

  /// English UI text for bluetoothScanningDescription.
  ///
  /// In en, this message translates to:
  /// **'Nearby devices will appear automatically.'**
  String get bluetoothScanningDescription;

  /// English UI text for bluetoothServiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'BlueZ is unavailable'**
  String get bluetoothServiceUnavailable;

  /// English UI text for bluetoothServiceUnavailableDescription.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth controls will return when the service starts.'**
  String get bluetoothServiceUnavailableDescription;

  /// English UI text for bluetoothServiceUnavailableShort.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth unavailable'**
  String get bluetoothServiceUnavailableShort;

  /// English UI text for bluetoothStopScanning.
  ///
  /// In en, this message translates to:
  /// **'Stop scanning for Bluetooth devices'**
  String get bluetoothStopScanning;

  /// English UI text for bluetoothStopTrustingDevice.
  ///
  /// In en, this message translates to:
  /// **'Stop trusting {deviceName}'**
  String bluetoothStopTrustingDevice(String deviceName);

  /// English UI text for bluetoothSubmit.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get bluetoothSubmit;

  /// English UI text for bluetoothTrustDevice.
  ///
  /// In en, this message translates to:
  /// **'Trust {deviceName}'**
  String bluetoothTrustDevice(String deviceName);

  /// English UI text for bluetoothTrustServiceDevice.
  ///
  /// In en, this message translates to:
  /// **'Only continue if you trust {deviceName}.'**
  String bluetoothTrustServiceDevice(String deviceName);

  /// English UI text for bluetoothWaitingForDevice.
  ///
  /// In en, this message translates to:
  /// **'{code} · waiting for the other device.'**
  String bluetoothWaitingForDevice(String code);

  /// English UI text for brightnessTitle.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get brightnessTitle;

  /// English UI text for celsiusUnit.
  ///
  /// In en, this message translates to:
  /// **'°C'**
  String get celsiusUnit;

  /// English UI text for chargeProtocolFast.
  ///
  /// In en, this message translates to:
  /// **'FAST'**
  String get chargeProtocolFast;

  /// English UI text for chargeProtocolPowerDelivery.
  ///
  /// In en, this message translates to:
  /// **'PD'**
  String get chargeProtocolPowerDelivery;

  /// English UI text for chargeProtocolPps.
  ///
  /// In en, this message translates to:
  /// **'PPS'**
  String get chargeProtocolPps;

  /// English UI text for chargeProtocolVooc.
  ///
  /// In en, this message translates to:
  /// **'VOOC'**
  String get chargeProtocolVooc;

  /// Accessible label for the barrier that closes clipboard history.
  ///
  /// In en, this message translates to:
  /// **'Close clipboard history'**
  String get clipboardCloseHistory;

  /// Label for clearing all unpinned clipboard-history entries.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get clipboardClearAll;

  /// Tooltip for deleting a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get clipboardDelete;

  /// Accessible label for deleting a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Delete clipboard item'**
  String get clipboardDeleteItem;

  /// Accessible instruction for the clipboard tray drag handle.
  ///
  /// In en, this message translates to:
  /// **'Drag clipboard tray toward its edge to close'**
  String get clipboardDragToClose;

  /// Clipboard-history empty-state guidance.
  ///
  /// In en, this message translates to:
  /// **'Copy text, an image, or files and they will appear here.'**
  String get clipboardEmptyDescription;

  /// Title shown when clipboard history has no entries.
  ///
  /// In en, this message translates to:
  /// **'Nothing captured yet'**
  String get clipboardEmptyTitle;

  /// Fallback label for a clipboard entry containing selected files.
  ///
  /// In en, this message translates to:
  /// **'File selection'**
  String get clipboardFileSelection;

  /// Explanation shown when clipboard history is hidden on the lock screen.
  ///
  /// In en, this message translates to:
  /// **'Clipboard contents stay hidden while the session is locked.'**
  String get clipboardHistoryLockedDescription;

  /// Title shown when clipboard history is hidden on the lock screen.
  ///
  /// In en, this message translates to:
  /// **'History is sealed'**
  String get clipboardHistoryLockedTitle;

  /// Accessible label for an image-file thumbnail in clipboard history.
  ///
  /// In en, this message translates to:
  /// **'Image file thumbnail'**
  String get clipboardImageFileThumbnail;

  /// Accessible label for an image preview in clipboard history.
  ///
  /// In en, this message translates to:
  /// **'Clipboard image preview'**
  String get clipboardImagePreview;

  /// Accessible interaction hint for a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Activate to paste it into the focused app. Drag it to drop it.'**
  String get clipboardItemHint;

  /// Accessible summary of a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'{type} clipboard item. {preview}'**
  String clipboardItemSemantics(String type, String preview);

  /// Tooltip for pinning a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get clipboardPin;

  /// Accessible label for pinning a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Pin clipboard item'**
  String get clipboardPinItem;

  /// Guidance shown when clipboard search has no results.
  ///
  /// In en, this message translates to:
  /// **'Try a different word, file type, or application.'**
  String get clipboardNoSearchResultsDescription;

  /// Title shown when clipboard search has no results.
  ///
  /// In en, this message translates to:
  /// **'No echoes found'**
  String get clipboardNoSearchResultsTitle;

  /// Fallback label when a clipboard image preview cannot be rendered.
  ///
  /// In en, this message translates to:
  /// **'Preview unavailable'**
  String get clipboardPreviewUnavailable;

  /// Accessible clipboard-entry type label for files.
  ///
  /// In en, this message translates to:
  /// **'FILES'**
  String get clipboardTypeFiles;

  /// Accessible clipboard-entry type label for an image.
  ///
  /// In en, this message translates to:
  /// **'IMAGE'**
  String get clipboardTypeImage;

  /// Accessible clipboard-entry type label for text.
  ///
  /// In en, this message translates to:
  /// **'TEXT'**
  String get clipboardTypeText;

  /// Tooltip for unpinning a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get clipboardUnpin;

  /// Accessible label for unpinning a clipboard-history entry.
  ///
  /// In en, this message translates to:
  /// **'Unpin clipboard item'**
  String get clipboardUnpinItem;

  /// Explanation shown when the native clipboard-history service is unavailable.
  ///
  /// In en, this message translates to:
  /// **'The native history service did not answer.'**
  String get clipboardUnavailableDescription;

  /// Title shown when the native clipboard-history service is unavailable.
  ///
  /// In en, this message translates to:
  /// **'Clipboard bridge unavailable'**
  String get clipboardUnavailableTitle;

  /// English UI text for commonBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get commonBluetooth;

  /// English UI text for commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// English UI text for commonChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get commonChecking;

  /// English UI text for commonConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get commonConnecting;

  /// English UI text for commonError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get commonError;

  /// English UI text for commonLimited.
  ///
  /// In en, this message translates to:
  /// **'Limited'**
  String get commonLimited;

  /// English UI text for commonLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get commonLoading;

  /// English UI text for commonNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get commonNotConnected;

  /// English UI text for commonOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get commonOff;

  /// English UI text for commonOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get commonOn;

  /// English UI text for commonOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get commonOnline;

  /// English UI text for commonOpening.
  ///
  /// In en, this message translates to:
  /// **'Opening…'**
  String get commonOpening;

  /// English UI text for commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// English UI text for commonScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get commonScanning;

  /// English UI text for commonTitleAndBody.
  ///
  /// In en, this message translates to:
  /// **'{title}. {body}'**
  String commonTitleAndBody(String title, String body);

  /// English UI text for commonTitleAndSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{title}, {subtitle}'**
  String commonTitleAndSubtitle(String title, String subtitle);

  /// English UI text for commonUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get commonUnavailable;

  /// English UI text for commonVolume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get commonVolume;

  /// English UI text for commonWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get commonWifi;

  /// English UI text for currentMilliamps.
  ///
  /// In en, this message translates to:
  /// **'{value} mA'**
  String currentMilliamps(int value);

  /// English UI text for currentMilliampsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'-- mA'**
  String get currentMilliampsUnavailable;

  /// English UI text for desktopActivateWindow.
  ///
  /// In en, this message translates to:
  /// **'Activate {windowTitle}'**
  String desktopActivateWindow(String windowTitle);

  /// English UI text for desktopAudioOutputDevicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose where desktop audio plays.'**
  String get desktopAudioOutputDevicesDescription;

  /// English UI text for desktopAudioOutputDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Output devices'**
  String get desktopAudioOutputDevicesTitle;

  /// English UI text for desktopAudioOutputDevicesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Audio output devices are unavailable.'**
  String get desktopAudioOutputDevicesUnavailable;

  /// Status shown for an audio output whose jack or route is explicitly unavailable.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get desktopAudioOutputDeviceNotConnected;

  /// English UI text for desktopApplicationAudioUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Application audio is unavailable.'**
  String get desktopApplicationAudioUnavailable;

  /// English UI text for desktopApplicationSearchResults.
  ///
  /// In en, this message translates to:
  /// **'{visible} of {total} applications'**
  String desktopApplicationSearchResults(int visible, int total);

  /// Heading for the dedicated row of recently opened launcher applications.
  ///
  /// In en, this message translates to:
  /// **'Suggested'**
  String get desktopApplicationSuggestionsTitle;

  /// English UI text for desktopApplicationVolumeDescription.
  ///
  /// In en, this message translates to:
  /// **'Adjust audio for individual applications.'**
  String get desktopApplicationVolumeDescription;

  /// You profile settings: settingsNavigationYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get settingsNavigationYou;

  /// You profile settings: settingsYouDescription.
  ///
  /// In en, this message translates to:
  /// **'Make this space yours.'**
  String get settingsYouDescription;

  /// You profile settings: settingsYouPreview.
  ///
  /// In en, this message translates to:
  /// **'Your profile on the dashboard'**
  String get settingsYouPreview;

  /// You profile settings: settingsYouChoosePhoto.
  ///
  /// In en, this message translates to:
  /// **'Choose photo'**
  String get settingsYouChoosePhoto;

  /// You profile settings: settingsYouDefaultPhoto.
  ///
  /// In en, this message translates to:
  /// **'Use default avatar'**
  String get settingsYouDefaultPhoto;

  /// You profile settings: settingsYouDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get settingsYouDisplayName;

  /// You profile settings: settingsYouNameHint.
  ///
  /// In en, this message translates to:
  /// **'Leave this empty to use your account name.'**
  String get settingsYouNameHint;

  /// You profile settings: settingsYouAccountName.
  ///
  /// In en, this message translates to:
  /// **'Use account name'**
  String get settingsYouAccountName;

  /// You profile settings: settingsYouSave.
  ///
  /// In en, this message translates to:
  /// **'Save name'**
  String get settingsYouSave;

  /// You profile settings: settingsYouSaved.
  ///
  /// In en, this message translates to:
  /// **'Name saved.'**
  String get settingsYouSaved;

  /// You profile settings: settingsYouImageError.
  ///
  /// In en, this message translates to:
  /// **'Could not use that photo. Choose a PNG, JPEG, WebP, GIF or BMP image under 16 MB.'**
  String get settingsYouImageError;

  /// You profile settings: settingsYouSaveError.
  ///
  /// In en, this message translates to:
  /// **'Could not save your profile. Please try again.'**
  String get settingsYouSaveError;

  /// You profile settings: settingsYouLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load your profile.'**
  String get settingsYouLoadError;

  /// Fallback user name in the dashboard when the session has no account name.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get desktopCurrentUser;

  /// Expandable application audio mixer row in the desktop dashboard.
  ///
  /// In en, this message translates to:
  /// **'Mixer'**
  String get desktopMixerTitle;

  /// English UI text for desktopApplicationVolumeTitle.
  ///
  /// In en, this message translates to:
  /// **'Application volume'**
  String get desktopApplicationVolumeTitle;

  /// English UI text for desktopApplicationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Applications'**
  String get desktopApplicationsTitle;

  /// English UI text for desktopChooseWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Choose wallpaper'**
  String get desktopChooseWallpaper;

  /// English UI text for desktopClearApplicationSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear application search'**
  String get desktopClearApplicationSearch;

  /// English UI text for desktopCloseApplicationAudio.
  ///
  /// In en, this message translates to:
  /// **'Close application volume'**
  String get desktopCloseApplicationAudio;

  /// English UI text for desktopCloseAudioOutputDevices.
  ///
  /// In en, this message translates to:
  /// **'Close output devices'**
  String get desktopCloseAudioOutputDevices;

  /// English UI text for desktopConnectDevice.
  ///
  /// In en, this message translates to:
  /// **'Connect {deviceName}'**
  String desktopConnectDevice(String deviceName);

  /// English UI text for desktopDashboardTitle.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get desktopDashboardTitle;

  /// English UI text for desktopDisconnectDevice.
  ///
  /// In en, this message translates to:
  /// **'Disconnect {deviceName}'**
  String desktopDisconnectDevice(String deviceName);

  /// English UI text for desktopLoadingAudioOutputDevices.
  ///
  /// In en, this message translates to:
  /// **'Loading output devices…'**
  String get desktopLoadingAudioOutputDevices;

  /// English UI text for desktopEnableBluetoothForDevices.
  ///
  /// In en, this message translates to:
  /// **'Turn on Bluetooth to see devices.'**
  String get desktopEnableBluetoothForDevices;

  /// English UI text for desktopFeatureAvailability.
  ///
  /// In en, this message translates to:
  /// **'{feature}: {availability}'**
  String desktopFeatureAvailability(String feature, String availability);

  /// English UI text for desktopGpuLabel.
  ///
  /// In en, this message translates to:
  /// **'GPU'**
  String get desktopGpuLabel;

  /// English UI text for desktopGpuPresetAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get desktopGpuPresetAutomatic;

  /// English UI text for desktopGpuPresetHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get desktopGpuPresetHigh;

  /// English UI text for desktopGpuPresetLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get desktopGpuPresetLow;

  /// English UI text for desktopInstalledApplications.
  ///
  /// In en, this message translates to:
  /// **'Installed applications: {count}'**
  String desktopInstalledApplications(int count);

  /// English UI text for desktopLaunchApplication.
  ///
  /// In en, this message translates to:
  /// **'Launch {applicationName}'**
  String desktopLaunchApplication(String applicationName);

  /// English UI text for desktopLoadingApplications.
  ///
  /// In en, this message translates to:
  /// **'Loading applications…'**
  String get desktopLoadingApplications;

  /// English UI text for desktopNoApplicationAudio.
  ///
  /// In en, this message translates to:
  /// **'No applications are playing audio.'**
  String get desktopNoApplicationAudio;

  /// English UI text for desktopNoAudioOutputDevices.
  ///
  /// In en, this message translates to:
  /// **'No audio output devices found.'**
  String get desktopNoAudioOutputDevices;

  /// English UI text for desktopNoApplicationsFound.
  ///
  /// In en, this message translates to:
  /// **'No applications found'**
  String get desktopNoApplicationsFound;

  /// English UI text for desktopOpenApplicationAudio.
  ///
  /// In en, this message translates to:
  /// **'Open application volume'**
  String get desktopOpenApplicationAudio;

  /// English UI text for desktopOpenNotificationCenter.
  ///
  /// In en, this message translates to:
  /// **'Open notification center'**
  String get desktopOpenNotificationCenter;

  /// English UI text for desktopOpenNotificationCenterUnread.
  ///
  /// In en, this message translates to:
  /// **'Open notification center · {count} unread'**
  String desktopOpenNotificationCenterUnread(int count);

  /// English UI text for desktopOpenPowerControls.
  ///
  /// In en, this message translates to:
  /// **'Open power controls'**
  String get desktopOpenPowerControls;

  /// English UI text for desktopPboBalanced.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get desktopPboBalanced;

  /// English UI text for desktopPboLabel.
  ///
  /// In en, this message translates to:
  /// **'PBO'**
  String get desktopPboLabel;

  /// English UI text for desktopPboPerformance.
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get desktopPboPerformance;

  /// English UI text for desktopPboSilent.
  ///
  /// In en, this message translates to:
  /// **'Silent'**
  String get desktopPboSilent;

  /// English UI text for desktopPowerModesTitle.
  ///
  /// In en, this message translates to:
  /// **'Power modes'**
  String get desktopPowerModesTitle;

  /// English UI text for desktopPowerModesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Power modes are unavailable.'**
  String get desktopPowerModesUnavailable;

  /// English UI text for desktopRefreshApplicationAudio.
  ///
  /// In en, this message translates to:
  /// **'Refresh application audio'**
  String get desktopRefreshApplicationAudio;

  /// English UI text for desktopRefreshAudioOutputDevices.
  ///
  /// In en, this message translates to:
  /// **'Refresh output devices'**
  String get desktopRefreshAudioOutputDevices;

  /// English UI text for desktopRefreshBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Refresh Bluetooth devices'**
  String get desktopRefreshBluetooth;

  /// English UI text for desktopRefreshPowerModes.
  ///
  /// In en, this message translates to:
  /// **'Refresh power modes'**
  String get desktopRefreshPowerModes;

  /// English UI text for desktopRestoreWindow.
  ///
  /// In en, this message translates to:
  /// **'Restore {windowTitle}'**
  String desktopRestoreWindow(String windowTitle);

  /// English UI text for desktopScanBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Scan for Bluetooth devices'**
  String get desktopScanBluetooth;

  /// English UI text for desktopSelectAudioOutputDevice.
  ///
  /// In en, this message translates to:
  /// **'Select audio output device'**
  String get desktopSelectAudioOutputDevice;

  /// English UI text for desktopScanningBluetoothDevices.
  ///
  /// In en, this message translates to:
  /// **'Scanning for Bluetooth devices…'**
  String get desktopScanningBluetoothDevices;

  /// English UI text for desktopSearchApplications.
  ///
  /// In en, this message translates to:
  /// **'Search applications'**
  String get desktopSearchApplications;

  /// English UI text for desktopSystemProfile.
  ///
  /// In en, this message translates to:
  /// **'System profile'**
  String get desktopSystemProfile;

  /// English UI text for desktopSystemProfileBalanced.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get desktopSystemProfileBalanced;

  /// English UI text for desktopSystemProfilePerformance.
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get desktopSystemProfilePerformance;

  /// English UI text for desktopSystemProfilePowerSaver.
  ///
  /// In en, this message translates to:
  /// **'Power saver'**
  String get desktopSystemProfilePowerSaver;

  /// English UI text for desktopTurnBluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Turn Bluetooth off'**
  String get desktopTurnBluetoothOff;

  /// English UI text for desktopTurnBluetoothOn.
  ///
  /// In en, this message translates to:
  /// **'Turn Bluetooth on'**
  String get desktopTurnBluetoothOn;

  /// English UI text for desktopVolumeForApplication.
  ///
  /// In en, this message translates to:
  /// **'Volume for {applicationName}'**
  String desktopVolumeForApplication(String applicationName);

  /// English UI text for frameMilliseconds.
  ///
  /// In en, this message translates to:
  /// **'~{value} ms'**
  String frameMilliseconds(String value);

  /// English UI text for frameMillisecondsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'--.- ms'**
  String get frameMillisecondsUnavailable;

  /// English UI text for frameShellPhases.
  ///
  /// In en, this message translates to:
  /// **'UI {build}  R {raster}  GAP {gap}'**
  String frameShellPhases(String build, String raster, String gap);

  /// English UI text for frameShellRendering.
  ///
  /// In en, this message translates to:
  /// **'SHELL · {refreshRate} HZ · RENDER'**
  String frameShellRendering(int refreshRate);

  /// English UI text for frameShellStats.
  ///
  /// In en, this message translates to:
  /// **'AVG {average}  MAX {maximum}  OVER {overBudget}'**
  String frameShellStats(String average, String maximum, int overBudget);

  /// English UI text for frameShellWaiting.
  ///
  /// In en, this message translates to:
  /// **'SHELL · WAIT'**
  String get frameShellWaiting;

  /// English UI text for launchOpeningApplication.
  ///
  /// In en, this message translates to:
  /// **'Opening {applicationName}'**
  String launchOpeningApplication(String applicationName);

  /// English UI text for localApplicationNotRegistered.
  ///
  /// In en, this message translates to:
  /// **'Local application “{appId}” is not registered.'**
  String localApplicationNotRegistered(String appId);

  /// English UI text for lockAuthenticating.
  ///
  /// In en, this message translates to:
  /// **'Authenticating…'**
  String get lockAuthenticating;

  /// English UI text for lockAuthenticationResponse.
  ///
  /// In en, this message translates to:
  /// **'Authentication response'**
  String get lockAuthenticationResponse;

  /// English UI text for lockAuthenticationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Authentication is unavailable.'**
  String get lockAuthenticationUnavailable;

  /// English UI text for lockCpuLabel.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get lockCpuLabel;

  /// English UI text for lockDesktopPromptDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter your password to unlock this desktop session.'**
  String get lockDesktopPromptDescription;

  /// English UI text for lockHideOnScreenKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Hide on-screen keyboard'**
  String get lockHideOnScreenKeyboard;

  /// English UI text for lockKeyboardBackspace.
  ///
  /// In en, this message translates to:
  /// **'Backspace'**
  String get lockKeyboardBackspace;

  /// English UI text for lockKeyboardLetters.
  ///
  /// In en, this message translates to:
  /// **'Letters'**
  String get lockKeyboardLetters;

  /// English UI text for lockKeyboardShift.
  ///
  /// In en, this message translates to:
  /// **'Shift'**
  String get lockKeyboardShift;

  /// English UI text for lockKeyboardSpace.
  ///
  /// In en, this message translates to:
  /// **'Space'**
  String get lockKeyboardSpace;

  /// English UI text for lockKeyboardSymbols.
  ///
  /// In en, this message translates to:
  /// **'Symbols'**
  String get lockKeyboardSymbols;

  /// English UI text for lockMetricUnavailable.
  ///
  /// In en, this message translates to:
  /// **'--'**
  String get lockMetricUnavailable;

  /// English UI text for lockOnScreenKeyboard.
  ///
  /// In en, this message translates to:
  /// **'On-screen keyboard'**
  String get lockOnScreenKeyboard;

  /// English UI text for lockPamVerified.
  ///
  /// In en, this message translates to:
  /// **'Identity verified'**
  String get lockPamVerified;

  /// English UI text for lockPasswordObscured.
  ///
  /// In en, this message translates to:
  /// **'Password, obscured'**
  String get lockPasswordObscured;

  /// English UI text for lockPerformanceMetric.
  ///
  /// In en, this message translates to:
  /// **'{label}: {value}'**
  String lockPerformanceMetric(String label, String value);

  /// English UI text for lockPerformanceStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Desktop performance status'**
  String get lockPerformanceStatusLabel;

  /// English UI text for lockPleaseWait.
  ///
  /// In en, this message translates to:
  /// **'Please wait…'**
  String get lockPleaseWait;

  /// English UI text for lockPressEnter.
  ///
  /// In en, this message translates to:
  /// **'Press Enter to unlock'**
  String get lockPressEnter;

  /// English UI text for lockRetryInSeconds.
  ///
  /// In en, this message translates to:
  /// **'Try again in {seconds} s'**
  String lockRetryInSeconds(int seconds);

  /// English UI text for lockScreenSemanticsLabel.
  ///
  /// In en, this message translates to:
  /// **'Desktop lock screen'**
  String get lockScreenSemanticsLabel;

  /// English UI text for lockShowOnScreenKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Show on-screen keyboard'**
  String get lockShowOnScreenKeyboard;

  /// English UI text for lockSignInSemantics.
  ///
  /// In en, this message translates to:
  /// **'Sign in to Denial'**
  String get lockSignInSemantics;

  /// English UI text for lockTemperature.
  ///
  /// In en, this message translates to:
  /// **'{temperature}°C'**
  String lockTemperature(int temperature);

  /// English UI text for lockTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get lockTryAgain;

  /// English UI text for lockUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockUnlock;

  /// English UI text for lockUnlockDenial.
  ///
  /// In en, this message translates to:
  /// **'Unlock Denial'**
  String get lockUnlockDenial;

  /// English UI text for lockWaitingForAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Waiting for authentication…'**
  String get lockWaitingForAuthentication;

  /// English UI text for lockWelcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get lockWelcomeBack;

  /// English UI text for longDate.
  ///
  /// In en, this message translates to:
  /// **'{weekday} {day} {month}'**
  String longDate(String weekday, int day, String month);

  /// Accessible label for the system bar media controls.
  ///
  /// In en, this message translates to:
  /// **'Media controls'**
  String get mediaControls;

  /// Accessible label for the next-track action.
  ///
  /// In en, this message translates to:
  /// **'Next track'**
  String get mediaNext;

  /// Heading for the active media popup.
  ///
  /// In en, this message translates to:
  /// **'Now playing'**
  String get mediaNowPlaying;

  /// Accessible label for pausing media.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get mediaPause;

  /// Accessible label for playing media.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get mediaPlay;

  /// Accessible label for the previous-track action.
  ///
  /// In en, this message translates to:
  /// **'Previous track'**
  String get mediaPrevious;

  /// English UI text for metricAverage.
  ///
  /// In en, this message translates to:
  /// **'AVG'**
  String get metricAverage;

  /// English UI text for metricCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get metricCpu;

  /// English UI text for metricMaximum.
  ///
  /// In en, this message translates to:
  /// **'MAX'**
  String get metricMaximum;

  /// English UI text for metricMinimum.
  ///
  /// In en, this message translates to:
  /// **'MIN'**
  String get metricMinimum;

  /// English UI text for metricNow.
  ///
  /// In en, this message translates to:
  /// **'NOW'**
  String get metricNow;

  /// English UI text for monthApril.
  ///
  /// In en, this message translates to:
  /// **'April'**
  String get monthApril;

  /// English UI text for monthAugust.
  ///
  /// In en, this message translates to:
  /// **'August'**
  String get monthAugust;

  /// English UI text for monthDecember.
  ///
  /// In en, this message translates to:
  /// **'December'**
  String get monthDecember;

  /// English UI text for monthFebruary.
  ///
  /// In en, this message translates to:
  /// **'February'**
  String get monthFebruary;

  /// English UI text for monthJanuary.
  ///
  /// In en, this message translates to:
  /// **'January'**
  String get monthJanuary;

  /// English UI text for monthJuly.
  ///
  /// In en, this message translates to:
  /// **'July'**
  String get monthJuly;

  /// English UI text for monthJune.
  ///
  /// In en, this message translates to:
  /// **'June'**
  String get monthJune;

  /// English UI text for monthMarch.
  ///
  /// In en, this message translates to:
  /// **'March'**
  String get monthMarch;

  /// English UI text for monthMay.
  ///
  /// In en, this message translates to:
  /// **'May'**
  String get monthMay;

  /// English UI text for monthNovember.
  ///
  /// In en, this message translates to:
  /// **'November'**
  String get monthNovember;

  /// English UI text for monthOctober.
  ///
  /// In en, this message translates to:
  /// **'October'**
  String get monthOctober;

  /// English UI text for monthSeptember.
  ///
  /// In en, this message translates to:
  /// **'September'**
  String get monthSeptember;

  /// English UI text for notificationDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss notification'**
  String get notificationDismiss;

  /// English UI text for notificationGeneric.
  ///
  /// In en, this message translates to:
  /// **'Notification'**
  String get notificationGeneric;

  /// English UI text for notificationNew.
  ///
  /// In en, this message translates to:
  /// **'New notification'**
  String get notificationNew;

  /// English UI text for notificationOpen.
  ///
  /// In en, this message translates to:
  /// **'Open {summary}'**
  String notificationOpen(String summary);

  /// English UI text for notificationProgress.
  ///
  /// In en, this message translates to:
  /// **'Progress: {percent}%'**
  String notificationProgress(int percent);

  /// English UI text for notificationSemantics.
  ///
  /// In en, this message translates to:
  /// **'{applicationName}: {summary}'**
  String notificationSemantics(String applicationName, String summary);

  /// English UI text for notificationSemanticsWithBody.
  ///
  /// In en, this message translates to:
  /// **'{applicationName}: {summary}. {body}'**
  String notificationSemanticsWithBody(
    String applicationName,
    String summary,
    String body,
  );

  /// English UI text for notificationsAllQuiet.
  ///
  /// In en, this message translates to:
  /// **'All quiet'**
  String get notificationsAllQuiet;

  /// English UI text for notificationsClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all notifications'**
  String get notificationsClearAll;

  /// English UI text for notificationsCloseCenter.
  ///
  /// In en, this message translates to:
  /// **'Close notification center'**
  String get notificationsCloseCenter;

  /// English UI text for notificationsClosed.
  ///
  /// In en, this message translates to:
  /// **'Closed'**
  String get notificationsClosed;

  /// English UI text for notificationsClosedByApplication.
  ///
  /// In en, this message translates to:
  /// **'Closed by application'**
  String get notificationsClosedByApplication;

  /// English UI text for notificationsDisableDoNotDisturb.
  ///
  /// In en, this message translates to:
  /// **'Disable do not disturb'**
  String get notificationsDisableDoNotDisturb;

  /// English UI text for notificationsDismissed.
  ///
  /// In en, this message translates to:
  /// **'Dismissed'**
  String get notificationsDismissed;

  /// English UI text for notificationsDoNotDisturbSemantics.
  ///
  /// In en, this message translates to:
  /// **'Do not disturb is on. Ordinary banners are silent. Critical notifications can still appear.'**
  String get notificationsDoNotDisturbSemantics;

  /// English UI text for notificationsEmptyDescription.
  ///
  /// In en, this message translates to:
  /// **'New notifications will appear here.'**
  String get notificationsEmptyDescription;

  /// English UI text for notificationsEnableDoNotDisturb.
  ///
  /// In en, this message translates to:
  /// **'Enable do not disturb'**
  String get notificationsEnableDoNotDisturb;

  /// English UI text for notificationsExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get notificationsExpired;

  /// English UI text for notificationsLoadingPolicy.
  ///
  /// In en, this message translates to:
  /// **'Loading do not disturb policy'**
  String get notificationsLoadingPolicy;

  /// English UI text for notificationsLockPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Lock screen notification privacy'**
  String get notificationsLockPrivacy;

  /// English UI text for notificationsNone.
  ///
  /// In en, this message translates to:
  /// **'No notifications'**
  String get notificationsNone;

  /// English UI text for notificationsOnLockScreen.
  ///
  /// In en, this message translates to:
  /// **'On lock screen'**
  String get notificationsOnLockScreen;

  /// English UI text for notificationsPreviewApplicationOnly.
  ///
  /// In en, this message translates to:
  /// **'App only'**
  String get notificationsPreviewApplicationOnly;

  /// English UI text for notificationsPreviewFull.
  ///
  /// In en, this message translates to:
  /// **'Full'**
  String get notificationsPreviewFull;

  /// English UI text for notificationsPreviewHidden.
  ///
  /// In en, this message translates to:
  /// **'Hidden'**
  String get notificationsPreviewHidden;

  /// English UI text for notificationsPreviewModeSemantics.
  ///
  /// In en, this message translates to:
  /// **'{mode} lock screen previews'**
  String notificationsPreviewModeSemantics(String mode);

  /// English UI text for notificationsQuietMode.
  ///
  /// In en, this message translates to:
  /// **'Quiet mode · critical alerts can bypass'**
  String get notificationsQuietMode;

  /// English UI text for notificationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsTitle;

  /// English UI text for notificationsUnread.
  ///
  /// In en, this message translates to:
  /// **'Unread notifications: {count}'**
  String notificationsUnread(int count);

  /// English UI text for numberValue.
  ///
  /// In en, this message translates to:
  /// **'{value}'**
  String numberValue(int value);

  /// English UI text for oskArrowDown.
  ///
  /// In en, this message translates to:
  /// **'Down'**
  String get oskArrowDown;

  /// English UI text for oskArrowUp.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get oskArrowUp;

  /// English UI text for oskBackspace.
  ///
  /// In en, this message translates to:
  /// **'Backspace'**
  String get oskBackspace;

  /// English UI text for oskControlKey.
  ///
  /// In en, this message translates to:
  /// **'CTRL'**
  String get oskControlKey;

  /// English UI text for oskEnter.
  ///
  /// In en, this message translates to:
  /// **'Enter'**
  String get oskEnter;

  /// English UI text for oskLetters.
  ///
  /// In en, this message translates to:
  /// **'Letters'**
  String get oskLetters;

  /// English UI text for oskLettersKey.
  ///
  /// In en, this message translates to:
  /// **'ABC'**
  String get oskLettersKey;

  /// English UI text for oskMoreSymbols.
  ///
  /// In en, this message translates to:
  /// **'More symbols'**
  String get oskMoreSymbols;

  /// English UI text for oskMoreSymbolsKey.
  ///
  /// In en, this message translates to:
  /// **'=<'**
  String get oskMoreSymbolsKey;

  /// English UI text for oskNumbersAndSymbols.
  ///
  /// In en, this message translates to:
  /// **'Numbers and symbols'**
  String get oskNumbersAndSymbols;

  /// English UI text for oskNumbersAndSymbolsKey.
  ///
  /// In en, this message translates to:
  /// **'?123'**
  String get oskNumbersAndSymbolsKey;

  /// English UI text for oskShift.
  ///
  /// In en, this message translates to:
  /// **'Shift'**
  String get oskShift;

  /// English UI text for oskSpace.
  ///
  /// In en, this message translates to:
  /// **'Space'**
  String get oskSpace;

  /// English UI text for outputBrightnessSemantics.
  ///
  /// In en, this message translates to:
  /// **'{outputName} brightness'**
  String outputBrightnessSemantics(String outputName);

  /// Accessible label for an output gamma-LUT dimming slider.
  ///
  /// In en, this message translates to:
  /// **'{outputName} software dimming'**
  String outputSoftwareDimmingSemantics(String outputName);

  /// Label for an output that has no usable DRM gamma LUT.
  ///
  /// In en, this message translates to:
  /// **'{outputName} software dimming (unavailable)'**
  String outputSoftwareDimmingUnavailable(String outputName);

  /// English UI text for outputVolumeSemantics.
  ///
  /// In en, this message translates to:
  /// **'Output volume'**
  String get outputVolumeSemantics;

  /// English UI text for overviewNoWindows.
  ///
  /// In en, this message translates to:
  /// **'No windows'**
  String get overviewNoWindows;

  /// English UI text for percentCompact.
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String percentCompact(int percent);

  /// English UI text for percentSign.
  ///
  /// In en, this message translates to:
  /// **'%'**
  String get percentSign;

  /// English UI text for percentValue.
  ///
  /// In en, this message translates to:
  /// **'{percent} percent'**
  String percentValue(int percent);

  /// English UI text for powerActionHibernate.
  ///
  /// In en, this message translates to:
  /// **'Hibernate'**
  String get powerActionHibernate;

  /// English UI text for powerActionHibernateDescription.
  ///
  /// In en, this message translates to:
  /// **'Save the session to disk'**
  String get powerActionHibernateDescription;

  /// English UI text for powerActionLock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get powerActionLock;

  /// English UI text for powerActionLockDescription.
  ///
  /// In en, this message translates to:
  /// **'Secure the session immediately'**
  String get powerActionLockDescription;

  /// English UI text for powerActionLogOut.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get powerActionLogOut;

  /// English UI text for powerActionLogOutDescription.
  ///
  /// In en, this message translates to:
  /// **'Close the Denial session'**
  String get powerActionLogOutDescription;

  /// English UI text for powerActionPowerOff.
  ///
  /// In en, this message translates to:
  /// **'Power off'**
  String get powerActionPowerOff;

  /// English UI text for powerActionPowerOffDescription.
  ///
  /// In en, this message translates to:
  /// **'Shut down the computer'**
  String get powerActionPowerOffDescription;

  /// English UI text for powerActionRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get powerActionRestart;

  /// English UI text for powerActionRestartDescription.
  ///
  /// In en, this message translates to:
  /// **'Restart the computer'**
  String get powerActionRestartDescription;

  /// English UI text for powerActionSuspend.
  ///
  /// In en, this message translates to:
  /// **'Suspend'**
  String get powerActionSuspend;

  /// English UI text for powerActionSuspendDescription.
  ///
  /// In en, this message translates to:
  /// **'Keep the session in memory'**
  String get powerActionSuspendDescription;

  /// English UI text for powerAuthenticationRequired.
  ///
  /// In en, this message translates to:
  /// **'Authentication required · {description}'**
  String powerAuthenticationRequired(String description);

  /// English UI text for powerBlockedBy.
  ///
  /// In en, this message translates to:
  /// **'An application is preventing this action: {blocker}'**
  String powerBlockedBy(String blocker);

  /// English UI text for powerConfirmLogOutBody.
  ///
  /// In en, this message translates to:
  /// **'Your graphical session will end. Save work in open applications before continuing.'**
  String get powerConfirmLogOutBody;

  /// English UI text for powerConfirmLogOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Log out of Denial?'**
  String get powerConfirmLogOutTitle;

  /// English UI text for powerConfirmPowerOffBody.
  ///
  /// In en, this message translates to:
  /// **'All applications will be closed and the computer will shut down.'**
  String get powerConfirmPowerOffBody;

  /// English UI text for powerConfirmPowerOffTitle.
  ///
  /// In en, this message translates to:
  /// **'Power off the computer?'**
  String get powerConfirmPowerOffTitle;

  /// English UI text for powerConfirmRestartBody.
  ///
  /// In en, this message translates to:
  /// **'All applications will be closed and the operating system will restart.'**
  String get powerConfirmRestartBody;

  /// English UI text for powerConfirmRestartTitle.
  ///
  /// In en, this message translates to:
  /// **'Restart the computer?'**
  String get powerConfirmRestartTitle;

  /// English UI text for powerDelayNotice.
  ///
  /// In en, this message translates to:
  /// **'An application may briefly delay sleep or shutdown: {details}'**
  String powerDelayNotice(String details);

  /// English UI text for powerPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Not authorized for this session'**
  String get powerPermissionDenied;

  /// English UI text for powerPermissionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Session service unavailable'**
  String get powerPermissionUnavailable;

  /// English UI text for powerPermissionUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Not supported by this system'**
  String get powerPermissionUnsupported;

  /// English UI text for powerSessionBusy.
  ///
  /// In en, this message translates to:
  /// **'Completing system request…'**
  String get powerSessionBusy;

  /// English UI text for powerSessionClose.
  ///
  /// In en, this message translates to:
  /// **'Close power and session controls'**
  String get powerSessionClose;

  /// English UI text for powerSessionDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose what Denial does'**
  String get powerSessionDescription;

  /// English UI text for powerSessionLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading system capabilities and inhibitors…'**
  String get powerSessionLoading;

  /// English UI text for powerSessionRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh power capabilities'**
  String get powerSessionRefresh;

  /// English UI text for powerSessionRequestError.
  ///
  /// In en, this message translates to:
  /// **'The system could not complete the request.'**
  String get powerSessionRequestError;

  /// English UI text for powerSessionSemantics.
  ///
  /// In en, this message translates to:
  /// **'Power and session controls'**
  String get powerSessionSemantics;

  /// English UI text for powerSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Power & session'**
  String get powerSessionTitle;

  /// English UI text for powerSessionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'System power controls are unavailable. Lock and log out remain local to Denial.'**
  String get powerSessionUnavailable;

  /// English UI text for powerWatts.
  ///
  /// In en, this message translates to:
  /// **'{watts} W'**
  String powerWatts(int watts);

  /// English UI text for powerWattsDecimal.
  ///
  /// In en, this message translates to:
  /// **'{watts} W'**
  String powerWattsDecimal(String watts);

  /// English UI text for quickSettingsAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get quickSettingsAutomatic;

  /// English UI text for quickSettingsBalanced.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get quickSettingsBalanced;

  /// English UI text for quickSettingsBatterySaver.
  ///
  /// In en, this message translates to:
  /// **'Battery saver'**
  String get quickSettingsBatterySaver;

  /// English UI text for quickSettingsClose.
  ///
  /// In en, this message translates to:
  /// **'Close quick settings'**
  String get quickSettingsClose;

  /// English UI text for quickSettingsControls.
  ///
  /// In en, this message translates to:
  /// **'Controls'**
  String get quickSettingsControls;

  /// English UI text for quickSettingsDate.
  ///
  /// In en, this message translates to:
  /// **'{weekday} {day}'**
  String quickSettingsDate(String weekday, int day);

  /// English UI text for quickSettingsHighPerformance.
  ///
  /// In en, this message translates to:
  /// **'High performance'**
  String get quickSettingsHighPerformance;

  /// English UI text for quickSettingsKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get quickSettingsKeyboard;

  /// English UI text for quickSettingsLocked.
  ///
  /// In en, this message translates to:
  /// **'Locked'**
  String get quickSettingsLocked;

  /// English UI text for quickSettingsNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get quickSettingsNormal;

  /// English UI text for quickSettingsNotificationsCount.
  ///
  /// In en, this message translates to:
  /// **'Notifications · {count}'**
  String quickSettingsNotificationsCount(int count);

  /// English UI text for quickSettingsOneAppActive.
  ///
  /// In en, this message translates to:
  /// **'One application active'**
  String get quickSettingsOneAppActive;

  /// English UI text for quickSettingsOpenDetails.
  ///
  /// In en, this message translates to:
  /// **'Open {title} details'**
  String quickSettingsOpenDetails(String title);

  /// English UI text for quickSettingsOpenOnScreen.
  ///
  /// In en, this message translates to:
  /// **'Open on-screen keyboard'**
  String get quickSettingsOpenOnScreen;

  /// English UI text for quickSettingsPerformance.
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get quickSettingsPerformance;

  /// English UI text for quickSettingsRotation.
  ///
  /// In en, this message translates to:
  /// **'Rotation'**
  String get quickSettingsRotation;

  /// English UI text for quickSettingsSettingsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Settings are unavailable.'**
  String get quickSettingsSettingsUnavailable;

  /// English UI text for quickSettingsSilent.
  ///
  /// In en, this message translates to:
  /// **'Silent'**
  String get quickSettingsSilent;

  /// Second explanatory paragraph on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'Flutter is not an overlay placed on top of another compositor. It is part of the compositor’s foundation.'**
  String get settingsAboutArchitecture;

  /// Denial's founding belief, shown prominently on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'Origin does not have to dictate purpose.'**
  String get settingsAboutBelief;

  /// Collaboration credit on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'Built in continuous collaboration with OpenAI Codex.'**
  String get settingsAboutCollaboration;

  /// Uppercase label above the creator's name on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'CONCEIVED, DIRECTED & TESTED BY'**
  String get settingsAboutCreditLabel;

  /// The credited creator of Denial.
  ///
  /// In en, this message translates to:
  /// **'Doctor Logix'**
  String get settingsAboutCreditName;

  /// Primary explanation of Denial on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'Denial gives Flutter a different life. It owns the desktop scene itself: the shell, its motion, and the composition of Wayland applications.'**
  String get settingsAboutDescription;

  /// Accessibility label for the large Denial wordmark on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'Denial wordmark'**
  String get settingsAboutLogoSemanticsLabel;

  /// Accessibility label for the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'About Denial'**
  String get settingsAboutPageSemanticsLabel;

  /// Denial's product tagline on the Settings About page.
  ///
  /// In en, this message translates to:
  /// **'A Flutter-native Wayland compositor.'**
  String get settingsAboutTagline;

  /// English UI text for settingsAccentPickerRouteLabel.
  ///
  /// In en, this message translates to:
  /// **'Shell accent color picker'**
  String get settingsAccentPickerRouteLabel;

  /// English UI text for settingsAccentPickerWheelLabel.
  ///
  /// In en, this message translates to:
  /// **'Shell accent color'**
  String get settingsAccentPickerWheelLabel;

  /// English UI text for settingsAnimateLockScreen.
  ///
  /// In en, this message translates to:
  /// **'Animate lock screen'**
  String get settingsAnimateLockScreen;

  /// English UI text for settingsAnimateLockScreenDescription.
  ///
  /// In en, this message translates to:
  /// **'Use a short desktop entrance animation while security input remains active immediately.'**
  String get settingsAnimateLockScreenDescription;

  /// English UI text for settingsAnimationSpeed.
  ///
  /// In en, this message translates to:
  /// **'Animation speed'**
  String get settingsAnimationSpeed;

  /// English UI text for settingsAnimationSpeedValue.
  ///
  /// In en, this message translates to:
  /// **'{percent}% speed'**
  String settingsAnimationSpeedValue(int percent);

  /// English UI text for settingsAnimationsDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose close effects and tune how quickly shell surfaces move.'**
  String get settingsAnimationsDescription;

  /// English UI text for settingsAnimationsSection.
  ///
  /// In en, this message translates to:
  /// **'Animations'**
  String get settingsAnimationsSection;

  /// English UI text for settingsAnimationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Motion that matches your desktop.'**
  String get settingsAnimationsTitle;

  /// Explanation that shell appearance changes are applied immediately.
  ///
  /// In en, this message translates to:
  /// **'Changes made here are reflected across the desktop in real time.'**
  String get settingsAppearanceDescription;

  /// Uppercase label for the appearance settings section.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearanceSection;

  /// Heading introducing personalization controls.
  ///
  /// In en, this message translates to:
  /// **'Make the desktop feel like yours.'**
  String get settingsAppearanceTitle;

  /// English UI text for settingsApplicationAudioDescription.
  ///
  /// In en, this message translates to:
  /// **'Adjust active audio streams independently.'**
  String get settingsApplicationAudioDescription;

  /// English UI text for settingsApplicationAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Application audio'**
  String get settingsApplicationAudioTitle;

  /// Search category for appearance settings.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsApplicationCategoryAppearance;

  /// Search category used to find the Settings application.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get settingsApplicationCategoryPreferences;

  /// Search category for system-level settings.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsApplicationCategorySystem;

  /// Accessibility label for the complete Settings application.
  ///
  /// In en, this message translates to:
  /// **'Denial Settings'**
  String get settingsApplicationSemanticsLabel;

  /// Display name of the built-in Denial Settings application.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsApplicationTitle;

  /// English UI text for settingsAudioDescription.
  ///
  /// In en, this message translates to:
  /// **'Control the master output and individual application streams.'**
  String get settingsAudioDescription;

  /// English UI text for settingsAudioSection.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get settingsAudioSection;

  /// English UI text for settingsAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Audio for the whole desktop.'**
  String get settingsAudioTitle;

  /// English UI text for settingsAudioUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Application audio is unavailable.'**
  String get settingsAudioUnavailable;

  /// English UI text for settingsAutomaticDisplayPowerDescription.
  ///
  /// In en, this message translates to:
  /// **'Turn displays off after a period of inactivity.'**
  String get settingsAutomaticDisplayPowerDescription;

  /// English UI text for settingsAutomaticDisplayPowerTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatic display power'**
  String get settingsAutomaticDisplayPowerTitle;

  /// English UI text for settingsAutomaticDisplayPowerToggle.
  ///
  /// In en, this message translates to:
  /// **'Turn displays off automatically'**
  String get settingsAutomaticDisplayPowerToggle;

  /// English UI text for settingsAutomaticDisplayPowerToggleDescription.
  ///
  /// In en, this message translates to:
  /// **'Power down connected displays after inactivity.'**
  String get settingsAutomaticDisplayPowerToggleDescription;

  /// Title for the coordinated idle lock, display power, and suspend settings.
  ///
  /// In en, this message translates to:
  /// **'Automatic idle actions'**
  String get settingsAutomaticIdleTitle;

  /// Title for physical power button behavior settings.
  ///
  /// In en, this message translates to:
  /// **'Power button'**
  String get settingsPowerButtonTitle;

  /// Label for the physical power button action selector.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get settingsPowerButtonAction;

  /// Explanation for the physical power button action selector.
  ///
  /// In en, this message translates to:
  /// **'Choose what happens when you press the physical power button.'**
  String get settingsPowerButtonDescription;

  /// Power button action that suspends the system.
  ///
  /// In en, this message translates to:
  /// **'Suspend'**
  String get settingsPowerButtonSuspend;

  /// Power button action that hibernates the system.
  ///
  /// In en, this message translates to:
  /// **'Hibernate'**
  String get settingsPowerButtonHibernate;

  /// Disabled persisted hibernate action when hibernation is unavailable.
  ///
  /// In en, this message translates to:
  /// **'Hibernate (unavailable)'**
  String get settingsPowerButtonHibernateUnavailable;

  /// Power button action that toggles compositor-owned display power.
  ///
  /// In en, this message translates to:
  /// **'Turn off displays (DPMS)'**
  String get settingsPowerButtonDpms;

  /// Power button action that powers off the system.
  ///
  /// In en, this message translates to:
  /// **'Power off'**
  String get settingsPowerButtonPowerOff;

  /// Toggle for automatically locking the session after inactivity.
  ///
  /// In en, this message translates to:
  /// **'Lock automatically'**
  String get settingsAutomaticLockToggle;

  /// Description for automatic session locking.
  ///
  /// In en, this message translates to:
  /// **'Show the lock screen and require authentication after inactivity.'**
  String get settingsAutomaticLockToggleDescription;

  /// Toggle for automatically suspending the system after inactivity.
  ///
  /// In en, this message translates to:
  /// **'Suspend automatically'**
  String get settingsAutomaticSuspendToggle;

  /// Description for automatic system suspend.
  ///
  /// In en, this message translates to:
  /// **'Keep the session in memory and enter low power after extended inactivity.'**
  String get settingsAutomaticSuspendToggleDescription;

  /// Label for choosing the kernel memory sleep mode.
  ///
  /// In en, this message translates to:
  /// **'Suspend mode'**
  String get settingsSuspendMode;

  /// Explanation for the kernel memory sleep mode selector.
  ///
  /// In en, this message translates to:
  /// **'Choose how Linux keeps memory powered. This applies to every suspend while Denial is active.'**
  String get settingsSuspendModeDescription;

  /// Friendly label for the Linux s2idle memory sleep mode.
  ///
  /// In en, this message translates to:
  /// **'Suspend to idle (s2idle)'**
  String get settingsSuspendModeS2idle;

  /// Friendly label for the Linux shallow memory sleep mode.
  ///
  /// In en, this message translates to:
  /// **'Standby (shallow)'**
  String get settingsSuspendModeShallow;

  /// Friendly label for the Linux deep memory sleep mode.
  ///
  /// In en, this message translates to:
  /// **'Suspend to RAM (deep)'**
  String get settingsSuspendModeDeep;

  /// Disabled suspend mode selector value when Linux exposes no memory sleep mode.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get settingsSuspendModeUnavailable;

  /// English UI text for settingsAvailable.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get settingsAvailable;

  /// English UI text for settingsAvailableNetworksDescription.
  ///
  /// In en, this message translates to:
  /// **'Nearby and saved Wi-Fi networks.'**
  String get settingsAvailableNetworksDescription;

  /// English UI text for settingsAvailableNetworksTitle.
  ///
  /// In en, this message translates to:
  /// **'Available networks'**
  String get settingsAvailableNetworksTitle;

  /// Label for a battery's completed charge-cycle count.
  ///
  /// In en, this message translates to:
  /// **'Charge cycles'**
  String get settingsBatteryChargeCycles;

  /// Label for the battery charge end-threshold value.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get settingsBatteryChargeEnd;

  /// Accessibility label for the battery percentage indicator.
  ///
  /// In en, this message translates to:
  /// **'Charge level'**
  String get settingsBatteryChargeLevel;

  /// Toggle label for UPower battery charge-threshold support.
  ///
  /// In en, this message translates to:
  /// **'Charge limit'**
  String get settingsBatteryChargeLimit;

  /// Fallback description for the battery charge-limit toggle.
  ///
  /// In en, this message translates to:
  /// **'Limit the full charge level to reduce battery wear.'**
  String get settingsBatteryChargeLimitDescription;

  /// Charge-limit description when the system exposes only an end threshold.
  ///
  /// In en, this message translates to:
  /// **'Stop charging at {percent}% to reduce battery wear.'**
  String settingsBatteryChargeLimitEndDescription(int percent);

  /// Explanation that UPower exposes threshold levels without setters.
  ///
  /// In en, this message translates to:
  /// **'Threshold levels are supplied by the system and are read-only in UPower.'**
  String get settingsBatteryChargeLimitLevelsReadOnly;

  /// Charge-limit description for firmware-optimized charging.
  ///
  /// In en, this message translates to:
  /// **'Let the firmware choose a battery-preserving charging pattern.'**
  String get settingsBatteryChargeLimitOptimizedDescription;

  /// Charge-limit description when start and end thresholds are available.
  ///
  /// In en, this message translates to:
  /// **'Resume charging below {start}% and stop at {end}% to reduce battery wear.'**
  String settingsBatteryChargeLimitStartEndDescription(int start, int end);

  /// Label for the battery charge start-threshold value.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get settingsBatteryChargeStart;

  /// Battery status shown for critical and action warning levels.
  ///
  /// In en, this message translates to:
  /// **'Critical battery'**
  String get settingsBatteryCritical;

  /// Label for the native UPower battery device path.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get settingsBatteryDevice;

  /// Compact battery time estimate with hours and minutes.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String settingsBatteryDuration(int hours, int minutes);

  /// UPower empty-battery state.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get settingsBatteryEmpty;

  /// Battery capability label for firmware-managed optimized charging.
  ///
  /// In en, this message translates to:
  /// **'Firmware optimized'**
  String get settingsBatteryFirmwareOptimized;

  /// Label for current full battery energy compared with design energy.
  ///
  /// In en, this message translates to:
  /// **'Full capacity'**
  String get settingsBatteryFullCapacity;

  /// Current full battery energy followed by design energy.
  ///
  /// In en, this message translates to:
  /// **'{full} / {design} Wh'**
  String settingsBatteryFullCapacityValue(String full, String design);

  /// UPower fully charged battery state.
  ///
  /// In en, this message translates to:
  /// **'Fully charged'**
  String get settingsBatteryFullyCharged;

  /// Label for battery full capacity as a percentage of design capacity.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get settingsBatteryHealth;

  /// Title for the UPower battery information and controls section.
  ///
  /// In en, this message translates to:
  /// **'Battery information'**
  String get settingsBatteryInformationTitle;

  /// Battery chemistry label.
  ///
  /// In en, this message translates to:
  /// **'Lead acid'**
  String get settingsBatteryLeadAcid;

  /// Battery chemistry label.
  ///
  /// In en, this message translates to:
  /// **'Lithium ion'**
  String get settingsBatteryLithiumIon;

  /// Battery chemistry label.
  ///
  /// In en, this message translates to:
  /// **'Lithium iron phosphate'**
  String get settingsBatteryLithiumIronPhosphate;

  /// Battery chemistry label.
  ///
  /// In en, this message translates to:
  /// **'Lithium polymer'**
  String get settingsBatteryLithiumPolymer;

  /// Loading message shown while querying UPower.
  ///
  /// In en, this message translates to:
  /// **'Reading battery information…'**
  String get settingsBatteryLoading;

  /// Battery status shown for UPower's low warning level.
  ///
  /// In en, this message translates to:
  /// **'Low battery'**
  String get settingsBatteryLow;

  /// Battery chemistry label.
  ///
  /// In en, this message translates to:
  /// **'Nickel cadmium'**
  String get settingsBatteryNickelCadmium;

  /// Battery chemistry label.
  ///
  /// In en, this message translates to:
  /// **'Nickel metal hydride'**
  String get settingsBatteryNickelMetalHydride;

  /// Empty state shown when UPower reports no system battery.
  ///
  /// In en, this message translates to:
  /// **'No system battery was detected.'**
  String get settingsBatteryNoSystemBattery;

  /// UPower source status when external power is disconnected.
  ///
  /// In en, this message translates to:
  /// **'On battery'**
  String get settingsBatteryOnBatteryPower;

  /// UPower pending-charge battery state.
  ///
  /// In en, this message translates to:
  /// **'Waiting to charge'**
  String get settingsBatteryPendingCharge;

  /// UPower pending-discharge battery state.
  ///
  /// In en, this message translates to:
  /// **'Waiting to discharge'**
  String get settingsBatteryPendingDischarge;

  /// UPower source status when external power is connected.
  ///
  /// In en, this message translates to:
  /// **'Plugged in'**
  String get settingsBatteryPluggedIn;

  /// Label for the current UPower battery energy rate in watts.
  ///
  /// In en, this message translates to:
  /// **'Power rate'**
  String get settingsBatteryPowerRate;

  /// Status shown while refreshing UPower battery information.
  ///
  /// In en, this message translates to:
  /// **'Refreshing…'**
  String get settingsBatteryRefreshing;

  /// Label for a battery serial number.
  ///
  /// In en, this message translates to:
  /// **'Serial'**
  String get settingsBatterySerial;

  /// Error shown when the UPower system D-Bus service cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'UPower battery information is unavailable.'**
  String get settingsBatteryServiceUnavailable;

  /// Label for currently stored battery energy.
  ///
  /// In en, this message translates to:
  /// **'Stored energy'**
  String get settingsBatteryStoredEnergy;

  /// Label for battery chemistry.
  ///
  /// In en, this message translates to:
  /// **'Technology'**
  String get settingsBatteryTechnology;

  /// Label for battery temperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get settingsBatteryTemperature;

  /// Label for UPower's estimated time until the battery is empty.
  ///
  /// In en, this message translates to:
  /// **'Time remaining'**
  String get settingsBatteryTimeRemaining;

  /// Label for UPower's estimated time until the battery is full.
  ///
  /// In en, this message translates to:
  /// **'Time to full'**
  String get settingsBatteryTimeToFull;

  /// Fallback name for a battery without vendor, model, or native path.
  ///
  /// In en, this message translates to:
  /// **'System battery'**
  String get settingsBatteryUnknownDevice;

  /// Error shown after a UPower refresh or charge-limit operation fails.
  ///
  /// In en, this message translates to:
  /// **'UPower could not refresh or change the battery settings.'**
  String get settingsBatteryUpdateFailed;

  /// Label for current battery voltage.
  ///
  /// In en, this message translates to:
  /// **'Voltage'**
  String get settingsBatteryVoltage;

  /// Battery energy value in watt-hours.
  ///
  /// In en, this message translates to:
  /// **'{value} Wh'**
  String settingsBatteryWattHours(String value);

  /// English UI text for settingsBackdropBlur.
  ///
  /// In en, this message translates to:
  /// **'Backdrop blur'**
  String get settingsBackdropBlur;

  /// Explanation and performance guidance for compositor backdrop blur.
  ///
  /// In en, this message translates to:
  /// **'Soften content behind translucent windows and panels. Higher quality uses more GPU.'**
  String get settingsBackdropBlurDescription;

  /// Toggle label for compositor backdrop blur.
  ///
  /// In en, this message translates to:
  /// **'Enable backdrop blur'**
  String get settingsBackdropBlurEnabled;

  /// Description of the compositor backdrop blur toggle.
  ///
  /// In en, this message translates to:
  /// **'Blur only where transparent content can reveal the desktop beneath it.'**
  String get settingsBackdropBlurEnabledDescription;

  /// Slider label for the compositor backdrop blur quality level.
  ///
  /// In en, this message translates to:
  /// **'Blur quality'**
  String get settingsBackdropBlurIntensity;

  /// Lowest-quality, fastest compositor backdrop blur level.
  ///
  /// In en, this message translates to:
  /// **'Shitty'**
  String get settingsBackdropBlurLevelShitty;

  /// Fast compositor backdrop blur level.
  ///
  /// In en, this message translates to:
  /// **'Fast'**
  String get settingsBackdropBlurLevelFast;

  /// Good-quality compositor backdrop blur level.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get settingsBackdropBlurLevelGood;

  /// Highest-quality compositor backdrop blur level.
  ///
  /// In en, this message translates to:
  /// **'Best'**
  String get settingsBackdropBlurLevelBest;

  /// Slider label for the strict final-composition pixel alpha threshold above which backdrop blur is rendered.
  ///
  /// In en, this message translates to:
  /// **'Minimum pixel opacity for blur'**
  String get settingsBackdropBlurOpacityThreshold;

  /// Dark or light appearance for glass surfaces.
  ///
  /// In en, this message translates to:
  /// **'Glass appearance'**
  String get settingsGlassAppearance;

  /// Opacity of Denial shell surfaces: launcher, Dashboard, taskbar and top cards.
  ///
  /// In en, this message translates to:
  /// **'Shell glass opacity'**
  String get settingsGlassShellOpacity;

  /// Opacity of compatible application window backgrounds; other applications and foreground controls are unaffected.
  ///
  /// In en, this message translates to:
  /// **'Window glass opacity'**
  String get settingsGlassWindowOpacity;

  /// Opacity of glass sidebars and toolbars within compatible applications, independent of shell and window background opacity.
  ///
  /// In en, this message translates to:
  /// **'App panels opacity'**
  String get settingsGlassAppPanelOpacity;

  /// Title for choosing the visual material behind translucent shell surfaces.
  ///
  /// In en, this message translates to:
  /// **'Transparency material'**
  String get settingsTransparencyTitle;

  /// Title for shell typography appearance settings.
  ///
  /// In en, this message translates to:
  /// **'Typography'**
  String get settingsTypographyTitle;

  /// Transparency material choice that disables backdrop processing.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get settingsTransparencyOff;

  /// Transparency material choice for the existing backdrop blur.
  ///
  /// In en, this message translates to:
  /// **'Blur'**
  String get settingsTransparencyBlur;

  /// Transparency material choice for Denial's native glass effect.
  ///
  /// In en, this message translates to:
  /// **'Glass'**
  String get settingsTransparencyGlass;

  /// Description of the disabled transparency material.
  ///
  /// In en, this message translates to:
  /// **'Leave translucent surfaces clear without processing the desktop behind them.'**
  String get settingsTransparencyOffDescription;

  /// Description of the existing blur material.
  ///
  /// In en, this message translates to:
  /// **'Use Denial’s current fast Gaussian backdrop blur.'**
  String get settingsTransparencyBlurDescription;

  /// Description of the native glass material.
  ///
  /// In en, this message translates to:
  /// **'Refract the sharp desktop through a frosted, accent-tinted lens with directional edge lighting.'**
  String get settingsTransparencyGlassDescription;

  /// Glass setting controlling the backdrop blur radius.
  ///
  /// In en, this message translates to:
  /// **'Frost'**
  String get settingsGlassFrost;

  /// Glass setting controlling intermediate texture resolution.
  ///
  /// In en, this message translates to:
  /// **'Render quality'**
  String get settingsGlassQuality;

  /// Glass setting controlling the width of the refractive edge.
  ///
  /// In en, this message translates to:
  /// **'Optical thickness'**
  String get settingsGlassThickness;

  /// Glass setting controlling background displacement.
  ///
  /// In en, this message translates to:
  /// **'Refraction'**
  String get settingsGlassRefraction;

  /// Glass setting controlling chromatic separation.
  ///
  /// In en, this message translates to:
  /// **'Color dispersion'**
  String get settingsGlassDispersion;

  /// Glass setting controlling backdrop color saturation.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get settingsGlassSaturation;

  /// Glass setting controlling how much of the shell accent is mixed into the material.
  ///
  /// In en, this message translates to:
  /// **'Accent tint'**
  String get settingsGlassAccentTint;

  /// Glass setting controlling adaptive brightening or darkening.
  ///
  /// In en, this message translates to:
  /// **'Luminosity'**
  String get settingsGlassBrightness;

  /// Glass setting controlling the angle of the simulated key light.
  ///
  /// In en, this message translates to:
  /// **'Light direction'**
  String get settingsGlassLightAngle;

  /// Glass setting controlling directional lighting strength.
  ///
  /// In en, this message translates to:
  /// **'Light intensity'**
  String get settingsGlassLightIntensity;

  /// Glass setting controlling rim and caustic highlights.
  ///
  /// In en, this message translates to:
  /// **'Edge shine'**
  String get settingsGlassEdgeStrength;

  /// English UI text for settingsBackdropDimming.
  ///
  /// In en, this message translates to:
  /// **'Backdrop dimming'**
  String get settingsBackdropDimming;

  /// English UI text for settingsBarGeometryDescription.
  ///
  /// In en, this message translates to:
  /// **'Adjust the space reserved for the desktop system bar.'**
  String get settingsBarGeometryDescription;

  /// English UI text for settingsBarGeometryTitle.
  ///
  /// In en, this message translates to:
  /// **'System bar geometry'**
  String get settingsBarGeometryTitle;

  /// English UI text for settingsBarThickness.
  ///
  /// In en, this message translates to:
  /// **'Bar thickness'**
  String get settingsBarThickness;

  /// English UI text for settingsBluetoothAdapterDescription.
  ///
  /// In en, this message translates to:
  /// **'Current adapter'**
  String get settingsBluetoothAdapterDescription;

  /// English UI text for settingsBluetoothDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage the radio and connect paired or nearby devices.'**
  String get settingsBluetoothDescription;

  /// English UI text for settingsBluetoothDevicesDescription.
  ///
  /// In en, this message translates to:
  /// **'Paired and nearby Bluetooth devices.'**
  String get settingsBluetoothDevicesDescription;

  /// English UI text for settingsBluetoothDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get settingsBluetoothDevicesTitle;

  /// English UI text for settingsBluetoothEnabled.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth enabled'**
  String get settingsBluetoothEnabled;

  /// English UI text for settingsBluetoothEnabledDescription.
  ///
  /// In en, this message translates to:
  /// **'Allow Denial to discover and connect Bluetooth devices.'**
  String get settingsBluetoothEnabledDescription;

  /// English UI text for settingsBluetoothRadioTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth radio'**
  String get settingsBluetoothRadioTitle;

  /// English UI text for settingsBluetoothSection.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get settingsBluetoothSection;

  /// English UI text for settingsBluetoothTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth devices.'**
  String get settingsBluetoothTitle;

  /// English UI text for settingsBluetoothUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth controls are unavailable.'**
  String get settingsBluetoothUnavailable;

  /// English UI text for settingsBrightness.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get settingsBrightness;

  /// Opacity of card backgrounds inside shell panels and Settings.
  ///
  /// In en, this message translates to:
  /// **'Card opacity'**
  String get settingsCardOpacity;

  /// English UI text for settingsClockScale.
  ///
  /// In en, this message translates to:
  /// **'Clock scale'**
  String get settingsClockScale;

  /// English UI text for settingsCloseEffectExplosion.
  ///
  /// In en, this message translates to:
  /// **'Explosion'**
  String get settingsCloseEffectExplosion;

  /// English UI text for settingsCloseEffectFade.
  ///
  /// In en, this message translates to:
  /// **'Fade'**
  String get settingsCloseEffectFade;

  /// English UI text for settingsCloseEffectImplode.
  ///
  /// In en, this message translates to:
  /// **'Implode'**
  String get settingsCloseEffectImplode;

  /// English UI text for settingsCloseEffectNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get settingsCloseEffectNone;

  /// Accessibility label for the icon button that closes the color picker.
  ///
  /// In en, this message translates to:
  /// **'Close color picker'**
  String get settingsColorPickerCloseSemanticsLabel;

  /// Button label that closes the color picker.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get settingsColorPickerDone;

  /// Instructions displayed between the color wheel and exact color-value editor.
  ///
  /// In en, this message translates to:
  /// **'Choose visually or enter exact color values.'**
  String get settingsColorPickerInstructions;

  /// Heading for exact color-value input controls.
  ///
  /// In en, this message translates to:
  /// **'Color values'**
  String get settingsColorInputTitle;

  /// Label for RGB color-value input mode.
  ///
  /// In en, this message translates to:
  /// **'RGB'**
  String get settingsColorInputRgb;

  /// Label for HSL color-value input mode.
  ///
  /// In en, this message translates to:
  /// **'HSL'**
  String get settingsColorInputHsl;

  /// Label for hexadecimal color-value input mode.
  ///
  /// In en, this message translates to:
  /// **'HEX'**
  String get settingsColorInputHex;

  /// Label for the red RGB channel input.
  ///
  /// In en, this message translates to:
  /// **'Red'**
  String get settingsColorInputRed;

  /// Label for the green RGB channel input.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get settingsColorInputGreen;

  /// Label for the blue RGB channel input.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get settingsColorInputBlue;

  /// Label for the HSL hue input.
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get settingsColorInputHue;

  /// Label for the HSL saturation input.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get settingsColorInputSaturation;

  /// Label for the HSL lightness input.
  ///
  /// In en, this message translates to:
  /// **'Lightness'**
  String get settingsColorInputLightness;

  /// Label for the exact hexadecimal color input.
  ///
  /// In en, this message translates to:
  /// **'Hex color'**
  String get settingsColorInputHexValue;

  /// Keyboard hint below exact color channel inputs.
  ///
  /// In en, this message translates to:
  /// **'Use ↑↓ to nudge · Hold Shift for 10'**
  String get settingsColorInputNudgeHint;

  /// Validation error for out-of-range RGB color values.
  ///
  /// In en, this message translates to:
  /// **'Use RGB values from 0 to 255.'**
  String get settingsColorInputRgbError;

  /// Validation error for out-of-range HSL color values.
  ///
  /// In en, this message translates to:
  /// **'Use H 0–360 and S/L 0–100.'**
  String get settingsColorInputHslError;

  /// Validation error for an invalid hexadecimal color value.
  ///
  /// In en, this message translates to:
  /// **'Use 3 or 6 hex digits.'**
  String get settingsColorInputHexError;

  /// Button label that restores the default border color.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get settingsColorPickerReset;

  /// Accessibility route name for the focused-window border color picker.
  ///
  /// In en, this message translates to:
  /// **'Shell accent color picker'**
  String get settingsColorPickerRouteLabel;

  /// Title displayed in the border color picker.
  ///
  /// In en, this message translates to:
  /// **'Accent color'**
  String get settingsColorPickerTitle;

  /// Accessibility value announced when increasing the color wheel.
  ///
  /// In en, this message translates to:
  /// **'Next hue'**
  String get settingsColorWheelNextHue;

  /// Accessibility value announced when decreasing the color wheel.
  ///
  /// In en, this message translates to:
  /// **'Previous hue'**
  String get settingsColorWheelPreviousHue;

  /// Accessibility label for the HSV border color wheel.
  ///
  /// In en, this message translates to:
  /// **'Shell accent color'**
  String get settingsColorWheelSemanticsLabel;

  /// English UI text for settingsConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get settingsConnect;

  /// English UI text for settingsConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get settingsConnected;

  /// English UI text for settingsConnectedDisplaysDescription.
  ///
  /// In en, this message translates to:
  /// **'Resolution, refresh rate, and scale for every output.'**
  String get settingsConnectedDisplaysDescription;

  /// English UI text for settingsConnectedDisplaysTitle.
  ///
  /// In en, this message translates to:
  /// **'Connected displays'**
  String get settingsConnectedDisplaysTitle;

  /// Label for the physical cursor-size slider.
  ///
  /// In en, this message translates to:
  /// **'Cursor size'**
  String get settingsCursorSize;

  /// Heading for cursor appearance settings.
  ///
  /// In en, this message translates to:
  /// **'Cursor'**
  String get settingsCursorTitle;

  /// Heading above the cursor theme selector.
  ///
  /// In en, this message translates to:
  /// **'Cursor theme'**
  String get settingsCursorTheme;

  /// Button for importing an animated Windows cursor archive.
  ///
  /// In en, this message translates to:
  /// **'Import cursor ZIP'**
  String get settingsCursorImport;

  /// Busy label while a cursor archive is being imported.
  ///
  /// In en, this message translates to:
  /// **'Importing…'**
  String get settingsCursorImporting;

  /// Generic cursor import failure message.
  ///
  /// In en, this message translates to:
  /// **'The cursor theme could not be imported.'**
  String get settingsCursorImportFailed;

  /// Tooltip for removing an imported cursor theme.
  ///
  /// In en, this message translates to:
  /// **'Remove imported cursor theme'**
  String get settingsCursorRemove;

  /// Generic cursor removal failure message.
  ///
  /// In en, this message translates to:
  /// **'The imported cursor theme could not be removed.'**
  String get settingsCursorRemoveFailed;

  /// Toggle label for client-defined cursor surfaces.
  ///
  /// In en, this message translates to:
  /// **'Allow applications to show their own cursor'**
  String get settingsCursorAllowApplications;

  /// Explanation of the client-defined cursor surface toggle.
  ///
  /// In en, this message translates to:
  /// **'Wayland and X11 applications can provide cursor artwork. Turn this off to always use the selected Denial theme.'**
  String get settingsCursorAllowApplicationsDescription;

  /// English UI text for settingsDashboardOverlayDescription.
  ///
  /// In en, this message translates to:
  /// **'Position the desktop dashboard.'**
  String get settingsDashboardOverlayDescription;

  /// English UI text for settingsDashboardOverlayTitle.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get settingsDashboardOverlayTitle;

  /// English UI text for settingsDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get settingsDisconnect;

  /// Busy label shown while a display configuration is being applied.
  ///
  /// In en, this message translates to:
  /// **'Applying…'**
  String get settingsApplying;

  /// Button label that applies the edited monitor configuration.
  ///
  /// In en, this message translates to:
  /// **'Apply changes'**
  String get settingsApplyDisplayConfiguration;

  /// Explains that display changes will be persisted.
  ///
  /// In en, this message translates to:
  /// **'Keep changes to update this session and outputs.conf.'**
  String get settingsDisplayApplyPersistentHint;

  /// Explains that display changes cannot be persisted.
  ///
  /// In en, this message translates to:
  /// **'Keep changes to use them for this session.'**
  String get settingsDisplayApplySessionHint;

  /// Title of the timed display configuration confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Keep these display settings?'**
  String get settingsDisplayConfirmationTitle;

  /// Countdown shown before an unconfirmed display configuration is rolled back.
  ///
  /// In en, this message translates to:
  /// **'The previous display settings will be restored automatically in {seconds} s.'**
  String settingsDisplayConfirmationMessage(int seconds);

  /// Button that confirms a newly applied display configuration.
  ///
  /// In en, this message translates to:
  /// **'Keep changes'**
  String get settingsDisplayKeepChanges;

  /// Button that immediately restores the previous display configuration.
  ///
  /// In en, this message translates to:
  /// **'Revert now'**
  String get settingsDisplayRevertNow;

  /// Accessibility label for the draggable monitor arrangement.
  ///
  /// In en, this message translates to:
  /// **'Monitor arrangement editor'**
  String get settingsDisplayArrangementSemantics;

  /// Instruction shown above the pannable monitor arrangement canvas.
  ///
  /// In en, this message translates to:
  /// **'Drag empty space to move the canvas. Use the mouse wheel to zoom.'**
  String get settingsDisplayCanvasPanHint;

  /// Accessibility label for the draggable background of the monitor arrangement.
  ///
  /// In en, this message translates to:
  /// **'Pannable monitor canvas'**
  String get settingsDisplayCanvasPanSemantics;

  /// Heading for output modes, scale, rotation, and arrangement.
  ///
  /// In en, this message translates to:
  /// **'Monitor configuration'**
  String get settingsDisplayArrangementTitle;

  /// Label for including a connected monitor in the desktop.
  ///
  /// In en, this message translates to:
  /// **'Use this display'**
  String get settingsDisplayEnabled;

  /// Explanation shown below the monitor enable toggle.
  ///
  /// In en, this message translates to:
  /// **'Include this monitor in the desktop. At least one display must remain enabled.'**
  String get settingsDisplayEnabledDescription;

  /// English UI text for settingsDisplayBrightnessDescription.
  ///
  /// In en, this message translates to:
  /// **'Adjust the main display brightness.'**
  String get settingsDisplayBrightnessDescription;

  /// English UI text for settingsDisplayBrightnessTitle.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get settingsDisplayBrightnessTitle;

  /// English UI text for settingsDisplayDetails.
  ///
  /// In en, this message translates to:
  /// **'{width} × {height} · {refreshRate} Hz · {scale}×'**
  String settingsDisplayDetails(
    int width,
    int height,
    String refreshRate,
    String scale,
  );

  /// English UI text for settingsDisplayInformationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Display information is unavailable.'**
  String get settingsDisplayInformationUnavailable;

  /// English UI text for settingsDisplaysDescription.
  ///
  /// In en, this message translates to:
  /// **'Review connected outputs and control screen brightness.'**
  String get settingsDisplaysDescription;

  /// English UI text for settingsDisplaysSection.
  ///
  /// In en, this message translates to:
  /// **'Displays & video'**
  String get settingsDisplaysSection;

  /// English UI text for settingsDisplaysTitle.
  ///
  /// In en, this message translates to:
  /// **'Displays and video.'**
  String get settingsDisplaysTitle;

  /// Logical position of one monitor in the desktop layout.
  ///
  /// In en, this message translates to:
  /// **'Position {x}, {y}'**
  String settingsDisplayPosition(int x, int y);

  /// Label for choosing the output that owns primary shell experiences.
  ///
  /// In en, this message translates to:
  /// **'Primary display'**
  String get settingsDisplayPrimary;

  /// Choice that lets the compositor select the primary display by refresh rate.
  ///
  /// In en, this message translates to:
  /// **'Automatic (highest refresh rate)'**
  String get settingsDisplayPrimaryAutomatic;

  /// Explains the primary display selector and its automatic fallback.
  ///
  /// In en, this message translates to:
  /// **'Shell surfaces open on the primary display. Automatic uses the enabled display with the highest refresh rate.'**
  String get settingsDisplayPrimaryHint;

  /// Label for the monitor refresh-rate selector.
  ///
  /// In en, this message translates to:
  /// **'Refresh rate'**
  String get settingsDisplayRefreshRate;

  /// Label for the monitor resolution selector.
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get settingsDisplayResolution;

  /// Label for the monitor rotation selector.
  ///
  /// In en, this message translates to:
  /// **'Rotation'**
  String get settingsDisplayRotation;

  /// Label for an unrotated monitor.
  ///
  /// In en, this message translates to:
  /// **'Landscape'**
  String get settingsDisplayRotationNormal;

  /// Label for a monitor rotated by 90 degrees.
  ///
  /// In en, this message translates to:
  /// **'90° counterclockwise'**
  String get settingsDisplayRotation90;

  /// Label for a monitor rotated by 180 degrees.
  ///
  /// In en, this message translates to:
  /// **'Upside down'**
  String get settingsDisplayRotation180;

  /// Label for a monitor rotated by 270 degrees.
  ///
  /// In en, this message translates to:
  /// **'90° clockwise'**
  String get settingsDisplayRotation270;

  /// Label for choosing the scrolling window layout axis on one monitor.
  ///
  /// In en, this message translates to:
  /// **'Scrolling layout axis'**
  String get settingsDisplayScrollingLayoutAxis;

  /// Explanation shown beside the per-monitor scrolling layout axis selector.
  ///
  /// In en, this message translates to:
  /// **'Choose how scrolling windows are arranged on this display.'**
  String get settingsDisplayScrollingLayoutAxisDescription;

  /// Choice that derives the scrolling layout axis from the monitor rotation.
  ///
  /// In en, this message translates to:
  /// **'Automatic (follows rotation)'**
  String get settingsDisplayScrollingLayoutAxisAuto;

  /// Choice that forces a horizontal scrolling window strip.
  ///
  /// In en, this message translates to:
  /// **'Horizontal'**
  String get settingsDisplayScrollingLayoutAxisHorizontal;

  /// Choice that forces a vertical scrolling window strip.
  ///
  /// In en, this message translates to:
  /// **'Vertical'**
  String get settingsDisplayScrollingLayoutAxisVertical;

  /// Label for the monitor scale selector.
  ///
  /// In en, this message translates to:
  /// **'Scale'**
  String get settingsDisplayScale;

  /// Validation error for a monitor scale outside the editable percentage range.
  ///
  /// In en, this message translates to:
  /// **'Enter a value from 50 to 600.'**
  String get settingsDisplayScaleInvalid;

  /// Label for the common monitor scale preset selector.
  ///
  /// In en, this message translates to:
  /// **'Presets'**
  String get settingsDisplayScalePreset;

  /// Guidance shown below the editable monitor scale percentage.
  ///
  /// In en, this message translates to:
  /// **'Enter 50–600%. Values are rounded to the nearest supported scale. Below 100% may look softer.'**
  String get settingsDisplayScaleRange;

  /// Label for enabling variable refresh rate on a supported monitor.
  ///
  /// In en, this message translates to:
  /// **'Variable refresh rate (VRR)'**
  String get settingsDisplayVariableRefreshRate;

  /// Explanation shown below the variable refresh rate toggle.
  ///
  /// In en, this message translates to:
  /// **'Match the monitor refresh rate to rendered content.'**
  String get settingsDisplayVariableRefreshRateDescription;

  /// Tooltip for fitting the complete monitor layout in the canvas.
  ///
  /// In en, this message translates to:
  /// **'Fit all monitors'**
  String get settingsDisplayZoomFit;

  /// Tooltip for increasing monitor canvas zoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get settingsDisplayZoomIn;

  /// Accessibility label for the current monitor canvas zoom.
  ///
  /// In en, this message translates to:
  /// **'Canvas zoom {percent}%'**
  String settingsDisplayZoomLevel(int percent);

  /// Tooltip for decreasing monitor canvas zoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get settingsDisplayZoomOut;

  /// Loading notice on the monitor settings page.
  ///
  /// In en, this message translates to:
  /// **'Loading monitor configuration…'**
  String get settingsLoadingDisplays;

  /// Accessibility hint for a draggable monitor tile.
  ///
  /// In en, this message translates to:
  /// **'Drag to arrange, or use the arrow keys to move.'**
  String get settingsMonitorDragHint;

  /// Accessibility label for one monitor tile.
  ///
  /// In en, this message translates to:
  /// **'Monitor {name}'**
  String settingsMonitorSemantics(String name);

  /// English UI text for settingsEdgeDistance.
  ///
  /// In en, this message translates to:
  /// **'Edge distance'**
  String get settingsEdgeDistance;

  /// English UI text for settingsFocusedWindows.
  ///
  /// In en, this message translates to:
  /// **'Focused windows'**
  String get settingsFocusedWindows;

  /// Description shown while the shell font catalog is loading.
  ///
  /// In en, this message translates to:
  /// **'Finding installed fonts…'**
  String get settingsFontCatalogLoading;

  /// Explanation for the shell font family selector.
  ///
  /// In en, this message translates to:
  /// **'Use the system default or an installed font across the Denial shell.'**
  String get settingsFontDescription;

  /// Label for the shell font family selector.
  ///
  /// In en, this message translates to:
  /// **'Font family'**
  String get settingsFontFamily;

  /// Option that restores the platform's default font family.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get settingsFontSystemDefault;

  /// Toggle label for changing the focused window border to the accent colour.
  ///
  /// In en, this message translates to:
  /// **'Highlight the focused window border'**
  String get settingsFocusedWindowBorder;

  /// Explanation of the focused-window border highlight toggle.
  ///
  /// In en, this message translates to:
  /// **'Turn this off to keep focused and unfocused window borders the same colour.'**
  String get settingsFocusedWindowBorderDescription;

  /// Compact product and section context shown in the Settings header.
  ///
  /// In en, this message translates to:
  /// **'DENIAL / SYSTEM'**
  String get settingsHeaderContext;

  /// Accessibility label for the Denial wordmark in the Settings header.
  ///
  /// In en, this message translates to:
  /// **'Denial'**
  String get settingsHeaderLogoSemanticsLabel;

  /// English UI text for settingsHeight.
  ///
  /// In en, this message translates to:
  /// **'Height'**
  String get settingsHeight;

  /// Per-panel toggle label for a pointer hover trigger at the output edge.
  ///
  /// In en, this message translates to:
  /// **'Open on edge hover'**
  String get settingsHoverTrigger;

  /// Explanation for a panel's hover-trigger preference.
  ///
  /// In en, this message translates to:
  /// **'Reveal this panel when the pointer reaches its screen edge.'**
  String get settingsHoverTriggerDescription;

  /// English UI text for settingsHudOverlayDescription.
  ///
  /// In en, this message translates to:
  /// **'Position volume and brightness feedback.'**
  String get settingsHudOverlayDescription;

  /// English UI text for settingsHudOverlayTitle.
  ///
  /// In en, this message translates to:
  /// **'System level display'**
  String get settingsHudOverlayTitle;

  /// Label for the automatic display power-off timeout.
  ///
  /// In en, this message translates to:
  /// **'Turn displays off after'**
  String get settingsDisplayOffTimeout;

  /// English UI text for settingsIdleInhibitDescription.
  ///
  /// In en, this message translates to:
  /// **'Application activity such as video playback can temporarily pause these timers.'**
  String get settingsIdleInhibitDescription;

  /// English UI text for settingsIdleInhibitSemantics.
  ///
  /// In en, this message translates to:
  /// **'Applications may pause automatic idle actions'**
  String get settingsIdleInhibitSemantics;

  /// English UI text for settingsInactivityTimeout.
  ///
  /// In en, this message translates to:
  /// **'Inactivity timeout'**
  String get settingsInactivityTimeout;

  /// Label for the automatic lock timeout.
  ///
  /// In en, this message translates to:
  /// **'Lock after'**
  String get settingsLockTimeout;

  /// English UI text for settingsLauncherOverlayDescription.
  ///
  /// In en, this message translates to:
  /// **'Position the application launcher.'**
  String get settingsLauncherOverlayDescription;

  /// English UI text for settingsLauncherOverlayTitle.
  ///
  /// In en, this message translates to:
  /// **'Applications'**
  String get settingsLauncherOverlayTitle;

  /// Explanation shown beside the Settings language selector.
  ///
  /// In en, this message translates to:
  /// **'System default follows your desktop language. Changes apply immediately.'**
  String get settingsLanguageDescription;

  /// Self-name for the English language option.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settingsLanguageEnglish;

  /// Heading for the interface language setting.
  ///
  /// In en, this message translates to:
  /// **'Interface language'**
  String get settingsLanguageInterfaceTitle;

  /// Eyebrow label for the Settings language page.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageSection;

  /// Accessibility label for the interface language choices.
  ///
  /// In en, this message translates to:
  /// **'Denial interface language'**
  String get settingsLanguageSelectorSemantics;

  /// Self-name for the Simplified Chinese language option.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get settingsLanguageSimplifiedChinese;

  /// Language option that follows the operating system locale.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get settingsLanguageSystemDefault;

  /// Title text for the Settings language page.
  ///
  /// In en, this message translates to:
  /// **'Choose the language Denial uses.'**
  String get settingsLanguageTitle;

  /// Section eyebrow for physical keyboard settings.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get settingsKeyboardSection;

  /// Physical keyboard settings page description.
  ///
  /// In en, this message translates to:
  /// **'Configure the physical keyboard used by Flutter, Wayland, and Xwayland.'**
  String get settingsKeyboardTitle;

  /// Title for configured XKB layouts.
  ///
  /// In en, this message translates to:
  /// **'Layouts and variants'**
  String get settingsKeyboardLayoutsTitle;

  /// Help for XKB layout and variant syntax.
  ///
  /// In en, this message translates to:
  /// **'Enter layouts in switching order. Add a variant after a colon, for example us, de:nodeadkeys.'**
  String get settingsKeyboardLayoutsDescription;

  /// Label for the XKB layouts field.
  ///
  /// In en, this message translates to:
  /// **'Layouts'**
  String get settingsKeyboardLayoutsLabel;

  /// Example XKB layouts.
  ///
  /// In en, this message translates to:
  /// **'us, de:nodeadkeys'**
  String get settingsKeyboardLayoutsHint;

  /// Label for XKB options.
  ///
  /// In en, this message translates to:
  /// **'XKB options'**
  String get settingsKeyboardOptionsLabel;

  /// Example XKB options.
  ///
  /// In en, this message translates to:
  /// **'compose:menu, caps:escape'**
  String get settingsKeyboardOptionsHint;

  /// Help for the XKB options field.
  ///
  /// In en, this message translates to:
  /// **'Comma-separated options enable Compose, alternate group shortcuts, Caps remapping, and other XKB behavior.'**
  String get settingsKeyboardOptionsDescription;

  /// Title for keyboard repeat settings.
  ///
  /// In en, this message translates to:
  /// **'Key repeat'**
  String get settingsKeyboardRepeatTitle;

  /// Keyboard repeat delay label.
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get settingsKeyboardRepeatDelay;

  /// Keyboard repeat rate label.
  ///
  /// In en, this message translates to:
  /// **'Rate'**
  String get settingsKeyboardRepeatRate;

  /// Title for keyboard layout switching status.
  ///
  /// In en, this message translates to:
  /// **'Layout switching'**
  String get settingsKeyboardSwitchingTitle;

  /// Label for the active keyboard layout.
  ///
  /// In en, this message translates to:
  /// **'Active layout'**
  String get settingsKeyboardActiveLayout;

  /// Description of Denial's physical layout switching shortcut.
  ///
  /// In en, this message translates to:
  /// **'Super+Space selects the next layout. Add Shift to select the previous one.'**
  String get settingsKeyboardSwitchingShortcut;

  /// Button label for applying keyboard settings.
  ///
  /// In en, this message translates to:
  /// **'Apply keyboard settings'**
  String get settingsKeyboardApply;

  /// Busy label while keyboard settings are applied.
  ///
  /// In en, this message translates to:
  /// **'Applying…'**
  String get settingsKeyboardApplying;

  /// Loading label for keyboard settings.
  ///
  /// In en, this message translates to:
  /// **'Reading the compositor keyboard configuration…'**
  String get settingsKeyboardLoading;

  /// Validation error for the keyboard layouts field.
  ///
  /// In en, this message translates to:
  /// **'Enter at least one valid XKB layout.'**
  String get settingsKeyboardInvalidLayouts;

  /// Eyebrow label for mouse and touchpad settings.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get settingsTouchpadSection;

  /// Description of the mouse and touchpad settings page.
  ///
  /// In en, this message translates to:
  /// **'Tune mouse and touchpad behavior.'**
  String get settingsTouchpadTitle;

  /// Label for the touchpad tap-to-click toggle.
  ///
  /// In en, this message translates to:
  /// **'Tap to click'**
  String get settingsTouchpadTapToClick;

  /// Description of the touchpad tap-to-click toggle.
  ///
  /// In en, this message translates to:
  /// **'Tap the touchpad to press the primary mouse button.'**
  String get settingsTouchpadTapToClickDescription;

  /// Label for the touchpad natural scrolling toggle.
  ///
  /// In en, this message translates to:
  /// **'Reverse two-finger scrolling'**
  String get settingsTouchpadNaturalScroll;

  /// Description of the touchpad natural scrolling toggle.
  ///
  /// In en, this message translates to:
  /// **'Move content in the same direction as your fingers.'**
  String get settingsTouchpadNaturalScrollDescription;

  /// Label for the continuous touchpad scroll speed slider.
  ///
  /// In en, this message translates to:
  /// **'Finger scroll speed'**
  String get settingsTouchpadScrollSpeed;

  /// Label for the continuous three-finger scrolling-layout swipe speed slider.
  ///
  /// In en, this message translates to:
  /// **'Scrolling layout swipe speed'**
  String get settingsTouchpadScrollingLayoutSwipeSpeed;

  /// Label for the mouse pointer speed slider.
  ///
  /// In en, this message translates to:
  /// **'Mouse pointer speed'**
  String get settingsMousePointerSpeed;

  /// Eyebrow label for the configured shortcuts page.
  ///
  /// In en, this message translates to:
  /// **'Shortcuts'**
  String get settingsShortcutsSection;

  /// Description of the configured shortcuts page.
  ///
  /// In en, this message translates to:
  /// **'Choose what Denial does when a shortcut is pressed.'**
  String get settingsShortcutsTitle;

  /// Number of shortcuts currently configured.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0 {No shortcuts} =1 {1 shortcut} other {{count} shortcuts}}'**
  String settingsShortcutsConfigured(int count);

  /// Button label for adding a shortcut.
  ///
  /// In en, this message translates to:
  /// **'Add shortcut'**
  String get settingsShortcutsAdd;

  /// Loading message for the configured shortcut list.
  ///
  /// In en, this message translates to:
  /// **'Reading shortcuts from the compositor…'**
  String get settingsShortcutsLoading;

  /// Message shown when configured shortcuts cannot be loaded.
  ///
  /// In en, this message translates to:
  /// **'The compositor shortcut configuration is unavailable.'**
  String get settingsShortcutsUnavailable;

  /// Button label for retrying a shortcut configuration read.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get settingsShortcutsRetry;

  /// Empty state message for the configured shortcut list.
  ///
  /// In en, this message translates to:
  /// **'No shortcuts are configured. Add one to make an action easier to reach.'**
  String get settingsShortcutsEmpty;

  /// Accessibility summary for a configured shortcut row.
  ///
  /// In en, this message translates to:
  /// **'{shortcut}, {action}'**
  String settingsShortcutsRowSemantics(String shortcut, String action);

  /// Tooltip for deleting a configured shortcut.
  ///
  /// In en, this message translates to:
  /// **'Delete {shortcut}'**
  String settingsShortcutsDeleteTooltip(String shortcut);

  /// Title of the shortcut editor when adding a binding.
  ///
  /// In en, this message translates to:
  /// **'Add shortcut'**
  String get settingsShortcutEditorAddTitle;

  /// Title of the shortcut editor when editing a binding.
  ///
  /// In en, this message translates to:
  /// **'Edit shortcut'**
  String get settingsShortcutEditorEditTitle;

  /// Introductory text in the shortcut editor.
  ///
  /// In en, this message translates to:
  /// **'Write a shortcut, choose what it runs, and let the compositor check it before saving.'**
  String get settingsShortcutEditorDescription;

  /// Label for the shortcut expression field.
  ///
  /// In en, this message translates to:
  /// **'Shortcut'**
  String get settingsShortcutEditorShortcutLabel;

  /// Example shown in an empty shortcut expression field.
  ///
  /// In en, this message translates to:
  /// **'Super+K'**
  String get settingsShortcutEditorShortcutHint;

  /// Persistent examples of accepted shortcut expression formats.
  ///
  /// In en, this message translates to:
  /// **'Examples: Super+K · Ctrl+Alt+Backspace · ThreeFingerSwipeLeft'**
  String get settingsShortcutEditorShortcutExample;

  /// Button and catalog title for supported shortcut inputs.
  ///
  /// In en, this message translates to:
  /// **'Supported inputs'**
  String get settingsShortcutEditorSupportedInputs;

  /// Label for choosing what a shortcut runs.
  ///
  /// In en, this message translates to:
  /// **'Runs'**
  String get settingsShortcutEditorTargetLabel;

  /// Shortcut target option for a built-in Denial action.
  ///
  /// In en, this message translates to:
  /// **'Denial action'**
  String get settingsShortcutEditorTargetAction;

  /// Shortcut target option for a desktop application with a stable desktop-file identity.
  ///
  /// In en, this message translates to:
  /// **'Application'**
  String get settingsShortcutEditorTargetApplication;

  /// Shortcut target option for directly spawning a program.
  ///
  /// In en, this message translates to:
  /// **'Program'**
  String get settingsShortcutEditorTargetProgram;

  /// Shortcut target option for a command run through sh.
  ///
  /// In en, this message translates to:
  /// **'Shell command'**
  String get settingsShortcutEditorTargetShell;

  /// Explanation of direct Niri-style program execution.
  ///
  /// In en, this message translates to:
  /// **'Run a program directly, without a shell. Every argument is passed exactly as written.'**
  String get settingsShortcutEditorProgramDescription;

  /// Label for the directly executed program.
  ///
  /// In en, this message translates to:
  /// **'Program'**
  String get settingsShortcutEditorProgramLabel;

  /// Example executable in the direct program field.
  ///
  /// In en, this message translates to:
  /// **'foot'**
  String get settingsShortcutEditorProgramHint;

  /// Label above a direct program's argument list.
  ///
  /// In en, this message translates to:
  /// **'Arguments'**
  String get settingsShortcutEditorArgumentsLabel;

  /// Button for appending one direct program argument.
  ///
  /// In en, this message translates to:
  /// **'Add argument'**
  String get settingsShortcutEditorAddArgument;

  /// Empty state for a direct program's argument list.
  ///
  /// In en, this message translates to:
  /// **'No arguments'**
  String get settingsShortcutEditorNoArguments;

  /// Label for one direct program argument.
  ///
  /// In en, this message translates to:
  /// **'Argument {index}'**
  String settingsShortcutEditorArgumentLabel(int index);

  /// Example direct program argument.
  ///
  /// In en, this message translates to:
  /// **'--option'**
  String get settingsShortcutEditorArgumentHint;

  /// Tooltip for removing one direct program argument.
  ///
  /// In en, this message translates to:
  /// **'Remove argument {index}'**
  String settingsShortcutEditorRemoveArgument(int index);

  /// Explanation of Niri-style shell command execution.
  ///
  /// In en, this message translates to:
  /// **'Run one command through sh -c. Shell variables, pipelines, redirects, and command chaining are supported.'**
  String get settingsShortcutEditorShellDescription;

  /// Label for the shell command field.
  ///
  /// In en, this message translates to:
  /// **'Shell command'**
  String get settingsShortcutEditorShellCommandLabel;

  /// Example shell command.
  ///
  /// In en, this message translates to:
  /// **'grim -g \"\$(slurp)\" ~/Pictures/capture.png'**
  String get settingsShortcutEditorShellCommandHint;

  /// Title of the shortcut action catalog.
  ///
  /// In en, this message translates to:
  /// **'Choose an action'**
  String get settingsShortcutEditorChooseAction;

  /// Title and empty selection label for the shortcut application catalog.
  ///
  /// In en, this message translates to:
  /// **'Choose an application'**
  String get settingsShortcutEditorChooseApplication;

  /// Configured shortcut target carrying a standard desktop-file identity.
  ///
  /// In en, this message translates to:
  /// **'Application · {desktopFileId}'**
  String settingsShortcutApplicationTarget(String desktopFileId);

  /// Status shown while Rust validates a shortcut draft.
  ///
  /// In en, this message translates to:
  /// **'Checking with the compositor…'**
  String get settingsShortcutEditorValidating;

  /// Status shown for a valid canonical shortcut.
  ///
  /// In en, this message translates to:
  /// **'Recognized as {shortcut}'**
  String settingsShortcutEditorValid(String shortcut);

  /// Conflict reported by the native shortcut validator.
  ///
  /// In en, this message translates to:
  /// **'{shortcut} is already assigned to {action}.'**
  String settingsShortcutEditorConflict(String shortcut, String action);

  /// Hint for shortcut editor catalog searches.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get settingsShortcutEditorSearch;

  /// Empty result message for shortcut editor catalogs.
  ///
  /// In en, this message translates to:
  /// **'No matching entries.'**
  String get settingsShortcutEditorNoResults;

  /// Tooltip for returning from a shortcut catalog.
  ///
  /// In en, this message translates to:
  /// **'Back to shortcut editor'**
  String get settingsShortcutEditorBack;

  /// Button label for closing the supported input catalog.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get settingsShortcutEditorDone;

  /// Button label for closing the shortcut editor.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsShortcutEditorCancel;

  /// Button label for saving a shortcut.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get settingsShortcutEditorSave;

  /// Button label while a shortcut mutation is running.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get settingsShortcutEditorSaving;

  /// Button label for deleting the shortcut being edited.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get settingsShortcutEditorDelete;

  /// Friendly display name for the three-finger swipe-up gesture.
  ///
  /// In en, this message translates to:
  /// **'Three-finger swipe up'**
  String get settingsShortcutGestureThreeFingerSwipeUp;

  /// Friendly display name for the three-finger swipe-left gesture.
  ///
  /// In en, this message translates to:
  /// **'Three-finger swipe left'**
  String get settingsShortcutGestureThreeFingerSwipeLeft;

  /// Friendly display name for the three-finger swipe-right gesture.
  ///
  /// In en, this message translates to:
  /// **'Three-finger swipe right'**
  String get settingsShortcutGestureThreeFingerSwipeRight;

  /// Friendly display name for the four-finger swipe-left gesture.
  ///
  /// In en, this message translates to:
  /// **'Four-finger swipe left'**
  String get settingsShortcutGestureFourFingerSwipeLeft;

  /// Friendly display name for the four-finger swipe-right gesture.
  ///
  /// In en, this message translates to:
  /// **'Four-finger swipe right'**
  String get settingsShortcutGestureFourFingerSwipeRight;

  /// Friendly display name for the four-finger swipe-up gesture.
  ///
  /// In en, this message translates to:
  /// **'Four-finger swipe up'**
  String get settingsShortcutGestureFourFingerSwipeUp;

  /// Friendly display name for the four-finger swipe-down gesture.
  ///
  /// In en, this message translates to:
  /// **'Four-finger swipe down'**
  String get settingsShortcutGestureFourFingerSwipeDown;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Modifier'**
  String get settingsShortcutInputCategoryModifier;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Navigation'**
  String get settingsShortcutInputCategoryNavigation;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Editing'**
  String get settingsShortcutInputCategoryEditing;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Punctuation'**
  String get settingsShortcutInputCategoryPunctuation;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Function'**
  String get settingsShortcutInputCategoryFunction;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Media'**
  String get settingsShortcutInputCategoryMedia;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Hardware'**
  String get settingsShortcutInputCategoryHardware;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Special'**
  String get settingsShortcutInputCategorySpecial;

  /// Supported shortcut input category.
  ///
  /// In en, this message translates to:
  /// **'Gesture'**
  String get settingsShortcutInputCategoryGesture;

  /// Display name for the shutdown shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Shut down'**
  String get settingsShortcutActionShutdown;

  /// Display name for the open applications shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Open applications'**
  String get settingsShortcutActionOpenApplications;

  /// Display name for the open dashboard shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Open dashboard'**
  String get settingsShortcutActionOpenDashboard;

  /// Display name for the open Settings shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get settingsShortcutActionOpenSettings;

  /// Display name for the open overview shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Open overview'**
  String get settingsShortcutActionOpenOverview;

  /// Display name for the vertical maximize shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Maximize vertically'**
  String get settingsShortcutActionToggleVerticalMaximize;

  /// Display name for the window switcher shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Switch windows'**
  String get settingsShortcutActionWindowSwitcher;

  /// Display name for the clipboard shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Open clipboard'**
  String get settingsShortcutActionOpenClipboard;

  /// Display name for the region capture shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Capture region'**
  String get settingsShortcutActionCaptureRegion;

  /// Display name for the close window shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Close window'**
  String get settingsShortcutActionCloseWindow;

  /// Display name for the minimize window shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Minimize window'**
  String get settingsShortcutActionMinimizeWindow;

  /// Display name for the minimize all windows shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Minimize all windows'**
  String get settingsShortcutActionMinimizeAllWindows;

  /// Display name for the toggle maximize shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Maximize or restore'**
  String get settingsShortcutActionToggleMaximize;

  /// Display name for the toggle fullscreen shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Enter or leave fullscreen'**
  String get settingsShortcutActionToggleFullscreen;

  /// Display name for the shortcut action that pins or unpins the focused window above other windows.
  ///
  /// In en, this message translates to:
  /// **'Toggle always on top'**
  String get settingsShortcutActionToggleWindowAlwaysOnTop;

  /// Display name for the release pointer shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Release pointer'**
  String get settingsShortcutActionReleasePointer;

  /// Display name for the lock screen shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Lock screen'**
  String get settingsShortcutActionLockScreen;

  /// Display name for the volume up shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Increase volume'**
  String get settingsShortcutActionVolumeUp;

  /// Display name for the volume down shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Decrease volume'**
  String get settingsShortcutActionVolumeDown;

  /// Display name for the volume mute shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Mute or unmute'**
  String get settingsShortcutActionVolumeMute;

  /// Display name for the brightness up shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Increase brightness'**
  String get settingsShortcutActionBrightnessUp;

  /// Display name for the brightness down shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Decrease brightness'**
  String get settingsShortcutActionBrightnessDown;

  /// Display name for the next keyboard layout shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Next keyboard layout'**
  String get settingsShortcutActionNextKeyboardLayout;

  /// Display name for the previous keyboard layout shortcut action.
  ///
  /// In en, this message translates to:
  /// **'Previous keyboard layout'**
  String get settingsShortcutActionPreviousKeyboardLayout;

  /// Display name for focusing the tiled window to the left.
  ///
  /// In en, this message translates to:
  /// **'Focus window left'**
  String get settingsShortcutActionFocusLeft;

  /// Display name for focusing the tiled window to the right.
  ///
  /// In en, this message translates to:
  /// **'Focus window right'**
  String get settingsShortcutActionFocusRight;

  /// Display name for focusing the tiled window above.
  ///
  /// In en, this message translates to:
  /// **'Focus window above'**
  String get settingsShortcutActionFocusUp;

  /// Display name for focusing the tiled window below.
  ///
  /// In en, this message translates to:
  /// **'Focus window below'**
  String get settingsShortcutActionFocusDown;

  /// Display name for swapping a tiled window to the left.
  ///
  /// In en, this message translates to:
  /// **'Swap window left'**
  String get settingsShortcutActionSwapLeft;

  /// Display name for swapping a tiled window to the right.
  ///
  /// In en, this message translates to:
  /// **'Swap window right'**
  String get settingsShortcutActionSwapRight;

  /// Display name for swapping a tiled window upward.
  ///
  /// In en, this message translates to:
  /// **'Swap window upward'**
  String get settingsShortcutActionSwapUp;

  /// Display name for swapping a tiled window downward.
  ///
  /// In en, this message translates to:
  /// **'Swap window downward'**
  String get settingsShortcutActionSwapDown;

  /// Display name for switching to the previous monitor-local workspace.
  ///
  /// In en, this message translates to:
  /// **'Previous workspace'**
  String get settingsShortcutActionPreviousWorkspace;

  /// Display name for switching to the next monitor-local workspace.
  ///
  /// In en, this message translates to:
  /// **'Next workspace'**
  String get settingsShortcutActionNextWorkspace;

  /// Display name for moving the focused window to the previous workspace.
  ///
  /// In en, this message translates to:
  /// **'Move window to previous workspace'**
  String get settingsShortcutActionMoveToPreviousWorkspace;

  /// Display name for moving the focused window to the next workspace.
  ///
  /// In en, this message translates to:
  /// **'Move window to next workspace'**
  String get settingsShortcutActionMoveToNextWorkspace;

  /// Display name for switching directly to a numbered workspace.
  ///
  /// In en, this message translates to:
  /// **'Switch to workspace {workspace}'**
  String settingsShortcutActionSwitchWorkspace(int workspace);

  /// Display name for moving the focused window to a numbered workspace.
  ///
  /// In en, this message translates to:
  /// **'Move window to workspace {workspace}'**
  String settingsShortcutActionMoveToWorkspace(int workspace);

  /// English UI text for settingsLayoutDescription.
  ///
  /// In en, this message translates to:
  /// **'Control the spacing reserved around ordinary and maximized windows.'**
  String get settingsLayoutDescription;

  /// English UI text for settingsLayoutSection.
  ///
  /// In en, this message translates to:
  /// **'Desktop layout'**
  String get settingsLayoutSection;

  /// English UI text for settingsLayoutTitle.
  ///
  /// In en, this message translates to:
  /// **'Give every window room to breathe.'**
  String get settingsLayoutTitle;

  /// Explains the available desktop window layouts.
  ///
  /// In en, this message translates to:
  /// **'Stacking lets windows overlap. Tiling divides the desktop dynamically. Scrolling follows focus along a strip; its axis is configured per display and follows rotation by default.'**
  String get settingsWindowLayoutDescription;

  /// Label for the Dwindle tiling window layout.
  ///
  /// In en, this message translates to:
  /// **'Tiling'**
  String get settingsWindowLayoutDwindle;

  /// Label for the freely overlapping window layout.
  ///
  /// In en, this message translates to:
  /// **'Stacking'**
  String get settingsWindowLayoutStacking;

  /// Label for the focus-following adaptive-axis scrolling layout.
  ///
  /// In en, this message translates to:
  /// **'Scrolling'**
  String get settingsWindowLayoutScrolling;

  /// Title for choosing how desktop windows are arranged.
  ///
  /// In en, this message translates to:
  /// **'Window layout'**
  String get settingsWindowLayoutTitle;

  /// Heading for mouse-wheel navigation in the scrolling window layout.
  ///
  /// In en, this message translates to:
  /// **'Super + mouse wheel'**
  String get settingsScrollingLayoutWheelTitle;

  /// Explains the scrolling-layout mouse-wheel shortcut.
  ///
  /// In en, this message translates to:
  /// **'Hold Super and turn the mouse wheel to scroll the window strip.'**
  String get settingsScrollingLayoutWheelDescription;

  /// Label for the scrolling-layout mouse-wheel speed slider.
  ///
  /// In en, this message translates to:
  /// **'Wheel speed'**
  String get settingsScrollingLayoutWheelSpeed;

  /// Label for choosing the scrolling-layout direction of a wheel-up gesture.
  ///
  /// In en, this message translates to:
  /// **'Wheel up moves'**
  String get settingsScrollingLayoutWheelUpDirection;

  /// Choice that maps mouse-wheel up to leftward scrolling-layout travel.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get settingsScrollingLayoutWheelUpLeft;

  /// Choice that maps mouse-wheel up to rightward scrolling-layout travel.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get settingsScrollingLayoutWheelUpRight;

  /// Heading for monitor-local workspace settings.
  ///
  /// In en, this message translates to:
  /// **'Workspaces'**
  String get settingsWorkspacesTitle;

  /// Toggle which enables monitor-local workspaces.
  ///
  /// In en, this message translates to:
  /// **'Enable workspaces'**
  String get settingsWorkspacesEnable;

  /// Explanation of Denial's monitor-local workspace model.
  ///
  /// In en, this message translates to:
  /// **'Each monitor switches workspaces independently. Minimized windows remain available across every workspace on their monitor.'**
  String get settingsWorkspacesDescription;

  /// Label for the number of workspaces per monitor.
  ///
  /// In en, this message translates to:
  /// **'Workspace count'**
  String get settingsWorkspaceCount;

  /// Label for choosing the direction of workspace transition motion.
  ///
  /// In en, this message translates to:
  /// **'Switching direction'**
  String get settingsWorkspaceSwitchingOrientation;

  /// Label for horizontal workspace transition motion.
  ///
  /// In en, this message translates to:
  /// **'Horizontal'**
  String get settingsWorkspaceSwitchingHorizontal;

  /// Label for vertical workspace transition motion.
  ///
  /// In en, this message translates to:
  /// **'Vertical'**
  String get settingsWorkspaceSwitchingVertical;

  /// Accessible and visible label for a numbered workspace.
  ///
  /// In en, this message translates to:
  /// **'Workspace {workspace}'**
  String workspaceLabel(int workspace);

  /// Accessible workspace state for the currently active workspace.
  ///
  /// In en, this message translates to:
  /// **'active'**
  String get workspaceActive;

  /// Accessible workspace state when ordinary windows are present.
  ///
  /// In en, this message translates to:
  /// **'occupied'**
  String get workspaceOccupied;

  /// Accessible workspace state when no ordinary windows are present.
  ///
  /// In en, this message translates to:
  /// **'empty'**
  String get workspaceEmpty;

  /// Short uppercase status label indicating immediate application.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get settingsLiveBadge;

  /// Accessibility label for the live-change status badge.
  ///
  /// In en, this message translates to:
  /// **'Changes are applied in real time'**
  String get settingsLiveChangesSemanticsLabel;

  /// English UI text for settingsLoadingAudio.
  ///
  /// In en, this message translates to:
  /// **'Loading application audio…'**
  String get settingsLoadingAudio;

  /// English UI text for settingsLockBackdropDescription.
  ///
  /// In en, this message translates to:
  /// **'Control wallpaper darkness and blur while locked.'**
  String get settingsLockBackdropDescription;

  /// English UI text for settingsLockBackdropTitle.
  ///
  /// In en, this message translates to:
  /// **'Backdrop'**
  String get settingsLockBackdropTitle;

  /// English UI text for settingsLockInformationDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose which useful details remain visible before sign-in.'**
  String get settingsLockInformationDescription;

  /// English UI text for settingsLockInformationTitle.
  ///
  /// In en, this message translates to:
  /// **'Desktop status'**
  String get settingsLockInformationTitle;

  /// English UI text for settingsLockMotionDescription.
  ///
  /// In en, this message translates to:
  /// **'Animate the desktop lock screen when it appears.'**
  String get settingsLockMotionDescription;

  /// English UI text for settingsLockMotionTitle.
  ///
  /// In en, this message translates to:
  /// **'Lock screen motion'**
  String get settingsLockMotionTitle;

  /// English UI text for settingsLockPreviewDate.
  ///
  /// In en, this message translates to:
  /// **'Thursday 23 July'**
  String get settingsLockPreviewDate;

  /// English UI text for settingsLockPreviewSemantics.
  ///
  /// In en, this message translates to:
  /// **'Lock screen preview'**
  String get settingsLockPreviewSemantics;

  /// English UI text for settingsLockPreviewStatus.
  ///
  /// In en, this message translates to:
  /// **'CPU 18% · GPU 12% · 52°C'**
  String get settingsLockPreviewStatus;

  /// English UI text for settingsLockPreviewTime.
  ///
  /// In en, this message translates to:
  /// **'22:41'**
  String get settingsLockPreviewTime;

  /// English UI text for settingsLockScreenDescription.
  ///
  /// In en, this message translates to:
  /// **'The main display presents an intentional sign-in stage while secondary displays remain calm and informative.'**
  String get settingsLockScreenDescription;

  /// English UI text for settingsLockScreenSection.
  ///
  /// In en, this message translates to:
  /// **'Lock screen'**
  String get settingsLockScreenSection;

  /// English UI text for settingsLockScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'A desktop lock screen, not a stretched phone.'**
  String get settingsLockScreenTitle;

  /// English UI text for settingsMasterOutputDescription.
  ///
  /// In en, this message translates to:
  /// **'Set the current desktop output volume.'**
  String get settingsMasterOutputDescription;

  /// English UI text for settingsMasterOutputTitle.
  ///
  /// In en, this message translates to:
  /// **'Master output'**
  String get settingsMasterOutputTitle;

  /// English UI text for settingsMaximizedSpacingDescription.
  ///
  /// In en, this message translates to:
  /// **'Keep a small margin around maximized windows.'**
  String get settingsMaximizedSpacingDescription;

  /// English UI text for settingsMaximizedSpacingTitle.
  ///
  /// In en, this message translates to:
  /// **'Maximized spacing'**
  String get settingsMaximizedSpacingTitle;

  /// Description for automatic live UI reload.
  ///
  /// In en, this message translates to:
  /// **'Let Denial watch the workspace and reload successful source changes. Available when the native tooling bridge is installed.'**
  String get settingsDeveloperAutoReloadDescription;

  /// Title for automatic live UI reload.
  ///
  /// In en, this message translates to:
  /// **'Reload when files change'**
  String get settingsDeveloperAutoReloadTitle;

  /// Action which builds the workspace in release mode and activates it.
  ///
  /// In en, this message translates to:
  /// **'Build & activate optimized'**
  String get settingsDeveloperBuildOptimized;

  /// Description for UI build and recovery controls.
  ///
  /// In en, this message translates to:
  /// **'Promote the current workspace to an optimized shell, or return to a known working UI without restarting the Wayland session.'**
  String get settingsDeveloperBuildRecoveryDescription;

  /// Heading for UI build and recovery controls.
  ///
  /// In en, this message translates to:
  /// **'Build & recovery'**
  String get settingsDeveloperBuildRecoveryTitle;

  /// Developer settings page description.
  ///
  /// In en, this message translates to:
  /// **'Edit the complete Flutter desktop, reload it live, then promote it to an optimized build.'**
  String get settingsDeveloperDescription;

  /// Heading for live development diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Connection & diagnostics'**
  String get settingsDeveloperDiagnosticsTitle;

  /// Instructions for attaching VSCodium to the live Flutter shell.
  ///
  /// In en, this message translates to:
  /// **'Open the Flutter shell workspace in VSCodium, choose “Attach to Denial live UI” in Run and Debug, then save changed Dart files to reload the desktop. Native compositor changes require a normal rebuild.'**
  String get settingsDeveloperEditorAttachDescription;

  /// Description for enabling live UI development.
  ///
  /// In en, this message translates to:
  /// **'Run the selected workspace with the Dart VM service available for VSCodium and Flutter tooling.'**
  String get settingsDeveloperEnableDescription;

  /// Title for enabling live UI development.
  ///
  /// In en, this message translates to:
  /// **'Enable live UI development'**
  String get settingsDeveloperEnableTitle;

  /// Label preceding the Flutter runtime generation number.
  ///
  /// In en, this message translates to:
  /// **'Generation'**
  String get settingsDeveloperGeneration;

  /// Action which hot reloads Dart source changes.
  ///
  /// In en, this message translates to:
  /// **'Hot reload'**
  String get settingsDeveloperHotReload;

  /// Action which hot restarts the Dart isolate.
  ///
  /// In en, this message translates to:
  /// **'Hot restart'**
  String get settingsDeveloperHotRestart;

  /// Heading for live UI development controls.
  ///
  /// In en, this message translates to:
  /// **'Live session'**
  String get settingsDeveloperLiveControlsTitle;

  /// Label for a user-built optimized Flutter shell.
  ///
  /// In en, this message translates to:
  /// **'Custom optimized'**
  String get settingsDeveloperModeCustom;

  /// Label for the JIT Flutter shell development mode.
  ///
  /// In en, this message translates to:
  /// **'Live development'**
  String get settingsDeveloperModeLive;

  /// Label for the packaged Denial Flutter shell.
  ///
  /// In en, this message translates to:
  /// **'Official optimized'**
  String get settingsDeveloperModeOfficial;

  /// Label shown before native UI development state is known.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get settingsDeveloperModeUnavailable;

  /// Empty state for live UI diagnostics.
  ///
  /// In en, this message translates to:
  /// **'No diagnostics reported.'**
  String get settingsDeveloperNoDiagnostics;

  /// Performance warning shown for live UI development.
  ///
  /// In en, this message translates to:
  /// **'Live development uses a JIT Flutter engine and debug checks. Frame pacing and game performance will be lower until you return to an optimized build.'**
  String get settingsDeveloperPerformanceWarning;

  /// Action which requests fresh live development state.
  ///
  /// In en, this message translates to:
  /// **'Refresh status'**
  String get settingsDeveloperRefreshStatus;

  /// Recovery action which activates the packaged shell.
  ///
  /// In en, this message translates to:
  /// **'Restore official UI'**
  String get settingsDeveloperRestoreOfficial;

  /// Recovery action which activates the previous working shell.
  ///
  /// In en, this message translates to:
  /// **'Revert last working'**
  String get settingsDeveloperRevertLastWorking;

  /// Heading for the active Flutter shell runtime.
  ///
  /// In en, this message translates to:
  /// **'Flutter shell runtime'**
  String get settingsDeveloperRuntimeTitle;

  /// Eyebrow for the Developer settings page.
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get settingsDeveloperSection;

  /// Action which creates, prepares, selects, and starts the version-matched Denial UI source.
  ///
  /// In en, this message translates to:
  /// **'Create and start editable UI'**
  String get settingsDeveloperSetupAction;

  /// Description of automatic Denial UI development setup.
  ///
  /// In en, this message translates to:
  /// **'Clone the version-matched Denial source from GitHub into ~/DenialUI, prepare it with the pinned toolchain, and enter live development.'**
  String get settingsDeveloperSetupDescription;

  /// Progress message while automatic UI development setup is running.
  ///
  /// In en, this message translates to:
  /// **'Preparing the editable UI. The shell will switch automatically when it is ready…'**
  String get settingsDeveloperSetupRunning;

  /// Message shown when the optional UI development package is absent.
  ///
  /// In en, this message translates to:
  /// **'Install denial-ui-development to enable automatic setup.'**
  String get settingsDeveloperSetupUnavailable;

  /// Action which validates and selects a Flutter source workspace.
  ///
  /// In en, this message translates to:
  /// **'Use this workspace'**
  String get settingsDeveloperUseWorkspace;

  /// Label for the local Dart VM service URI.
  ///
  /// In en, this message translates to:
  /// **'Dart VM service'**
  String get settingsDeveloperVmServiceTitle;

  /// Fallback while UI development state is loading.
  ///
  /// In en, this message translates to:
  /// **'Waiting for native runtime status…'**
  String get settingsDeveloperWaitingForStatus;

  /// Description for the live UI source workspace.
  ///
  /// In en, this message translates to:
  /// **'Select a Flutter project containing pubspec.yaml and lib/main.dart. Source changes can replace any shell UI that does not require a new native protocol.'**
  String get settingsDeveloperWorkspaceDescription;

  /// Accessible label for the Flutter workspace path field.
  ///
  /// In en, this message translates to:
  /// **'Flutter source workspace'**
  String get settingsDeveloperWorkspaceFieldLabel;

  /// Example path shown in the Flutter workspace field.
  ///
  /// In en, this message translates to:
  /// **'/home/you/DenialUI/dart_shell'**
  String get settingsDeveloperWorkspaceHint;

  /// Status for an absent or invalid Flutter workspace.
  ///
  /// In en, this message translates to:
  /// **'Needs setup'**
  String get settingsDeveloperWorkspaceNotReady;

  /// Status for a valid Flutter workspace.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get settingsDeveloperWorkspaceReady;

  /// Heading for Flutter source workspace selection.
  ///
  /// In en, this message translates to:
  /// **'Source workspace'**
  String get settingsDeveloperWorkspaceTitle;

  /// Button label for adding an application environment override.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get settingsEnvironmentAdd;

  /// Accessibility label for the green plus on a set environment override.
  ///
  /// In en, this message translates to:
  /// **'Added to launched applications'**
  String get settingsEnvironmentAddedStatus;

  /// Technical explanation shown in Add Variable mode.
  ///
  /// In en, this message translates to:
  /// **'Inject a literal value when Denial executes an application. An empty value is preserved as an empty string.'**
  String get settingsEnvironmentAddModeDescription;

  /// Name of the default environment scope applied to every direct Denial application launch.
  ///
  /// In en, this message translates to:
  /// **'All applications'**
  String get settingsEnvironmentAllApplications;

  /// Technical subtitle for the all-applications environment scope.
  ///
  /// In en, this message translates to:
  /// **'Default launch environment'**
  String get settingsEnvironmentAllApplicationsDescription;

  /// Count of default environment rules inherited by a selected application.
  ///
  /// In en, this message translates to:
  /// **'Inherits {count} all-app rules'**
  String settingsEnvironmentApplicationInherited(int count);

  /// Placeholder for filtering the application environment scope list.
  ///
  /// In en, this message translates to:
  /// **'Search applications or desktop IDs'**
  String get settingsEnvironmentApplicationSearchHint;

  /// Title for the application environment scope list.
  ///
  /// In en, this message translates to:
  /// **'Applications'**
  String get settingsEnvironmentApplicationsTitle;

  /// Error shown when desktop entries cannot be loaded for per-application environment settings.
  ///
  /// In en, this message translates to:
  /// **'Installed applications could not be loaded.'**
  String get settingsEnvironmentApplicationsUnavailable;

  /// Tooltip for returning from a narrow application environment editor to the application list.
  ///
  /// In en, this message translates to:
  /// **'Back to applications'**
  String get settingsEnvironmentBackToApplications;

  /// Button label for cancelling application environment editing.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsEnvironmentCancel;

  /// Button label for clearing every environment override in the selected scope.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get settingsEnvironmentClearScope;

  /// Tooltip for deleting an application environment override.
  ///
  /// In en, this message translates to:
  /// **'Delete {variable}'**
  String settingsEnvironmentDeleteVariable(String variable);

  /// Tooltip for editing an application environment override.
  ///
  /// In en, this message translates to:
  /// **'Edit {variable}'**
  String settingsEnvironmentEditVariable(String variable);

  /// Instructions for the application environment editor.
  ///
  /// In en, this message translates to:
  /// **'Set a value, leave it empty to pass an empty string, or choose Remove to keep the variable out of the child process.'**
  String get settingsEnvironmentEditorDescription;

  /// Title shown while editing an existing environment override.
  ///
  /// In en, this message translates to:
  /// **'Edit {variable}'**
  String settingsEnvironmentEditorEditTitle(String variable);

  /// Title for the application environment editor.
  ///
  /// In en, this message translates to:
  /// **'Add an override'**
  String get settingsEnvironmentEditorTitle;

  /// Description shown when there are no application environment overrides.
  ///
  /// In en, this message translates to:
  /// **'Add a variable above to change the environment of subsequently launched applications.'**
  String get settingsEnvironmentEmptyDescription;

  /// Title shown when there are no application environment overrides.
  ///
  /// In en, this message translates to:
  /// **'No overrides'**
  String get settingsEnvironmentEmptyTitle;

  /// Value label for an environment variable set to an empty string.
  ///
  /// In en, this message translates to:
  /// **'Empty string'**
  String get settingsEnvironmentEmptyValue;

  /// Accessibility label for the red minus on a hidden environment override.
  ///
  /// In en, this message translates to:
  /// **'Hidden from launched applications'**
  String get settingsEnvironmentHiddenStatus;

  /// Button label for hiding an inherited application environment variable.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get settingsEnvironmentHide;

  /// Technical explanation shown in Hide Variable mode.
  ///
  /// In en, this message translates to:
  /// **'Strip an inherited variable immediately before exec. The application behaves as if that name was never exported.'**
  String get settingsEnvironmentHideModeDescription;

  /// Validation error for a duplicate application environment variable.
  ///
  /// In en, this message translates to:
  /// **'That variable already has an override.'**
  String get settingsEnvironmentNameDuplicate;

  /// Example environment variable name.
  ///
  /// In en, this message translates to:
  /// **'e.g. MOZ_ENABLE_WAYLAND'**
  String get settingsEnvironmentNameHint;

  /// Validation error for an invalid environment variable name.
  ///
  /// In en, this message translates to:
  /// **'Use letters, numbers, and underscores, beginning with a letter or underscore.'**
  String get settingsEnvironmentNameInvalid;

  /// Field label for an application environment variable name.
  ///
  /// In en, this message translates to:
  /// **'Variable name'**
  String get settingsEnvironmentNameLabel;

  /// Validation error for an empty environment variable name.
  ///
  /// In en, this message translates to:
  /// **'Enter a variable name.'**
  String get settingsEnvironmentNameRequired;

  /// Tooltip for an application rule that replaces an all-applications rule with the same variable name.
  ///
  /// In en, this message translates to:
  /// **'Overrides the all-applications rule'**
  String get settingsEnvironmentOverridesDefault;

  /// Tab label for setting an application environment variable.
  ///
  /// In en, this message translates to:
  /// **'Add Variable'**
  String get settingsEnvironmentModeAdd;

  /// Tab label for removing an inherited application environment variable.
  ///
  /// In en, this message translates to:
  /// **'Hide Variable'**
  String get settingsEnvironmentModeHide;

  /// Description of the remove-from-child environment option.
  ///
  /// In en, this message translates to:
  /// **'Denial will remove this inherited variable before starting the application.'**
  String get settingsEnvironmentRemoveDescription;

  /// Label for an environment override whose value is null.
  ///
  /// In en, this message translates to:
  /// **'Remove from launched applications'**
  String get settingsEnvironmentRemoveLabel;

  /// Value label for an environment variable removed before launch.
  ///
  /// In en, this message translates to:
  /// **'Removed from child environment'**
  String get settingsEnvironmentRemovedValue;

  /// Explains the scope and timing of application environment overrides.
  ///
  /// In en, this message translates to:
  /// **'These overrides apply only to applications and shortcut commands started by Denial. They affect subsequent launches, not XDG autostart entries, systemd services, D-Bus services, or Denial itself.'**
  String get settingsEnvironmentScopeDescription;

  /// Title for the application environment scope explanation.
  ///
  /// In en, this message translates to:
  /// **'Launch scope'**
  String get settingsEnvironmentScopeTitle;

  /// Eyebrow label for the application environment page.
  ///
  /// In en, this message translates to:
  /// **'Applications'**
  String get settingsEnvironmentSection;

  /// Title text for the application environment page.
  ///
  /// In en, this message translates to:
  /// **'Customize the environment of applications launched by Denial.'**
  String get settingsEnvironmentTitle;

  /// Button label for updating an application environment override.
  ///
  /// In en, this message translates to:
  /// **'Update variable'**
  String get settingsEnvironmentUpdate;

  /// Fallback name for a configured desktop-file ID that is no longer installed.
  ///
  /// In en, this message translates to:
  /// **'Unavailable application'**
  String get settingsEnvironmentUnavailableApplication;

  /// Example application environment variable value.
  ///
  /// In en, this message translates to:
  /// **'e.g. 1'**
  String get settingsEnvironmentValueHint;

  /// Field label for an application environment variable value.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get settingsEnvironmentValueLabel;

  /// Validation error for an environment value containing NUL.
  ///
  /// In en, this message translates to:
  /// **'Values cannot contain a NUL character.'**
  String get settingsEnvironmentValueNul;

  /// Validation error for an oversized environment value.
  ///
  /// In en, this message translates to:
  /// **'The value is too long.'**
  String get settingsEnvironmentValueTooLong;

  /// Count of configured application environment overrides.
  ///
  /// In en, this message translates to:
  /// **'{count} configured'**
  String settingsEnvironmentVariablesStatus(int count);

  /// Title for the list of configured application environment overrides.
  ///
  /// In en, this message translates to:
  /// **'Configured overrides'**
  String get settingsEnvironmentVariablesTitle;

  /// English UI text for settingsMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String settingsMinutes(int minutes);

  /// Label for the About destination in Settings navigation.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsNavigationAbout;

  /// English UI text for settingsNavigationAnimations.
  ///
  /// In en, this message translates to:
  /// **'Animations'**
  String get settingsNavigationAnimations;

  /// English UI text for settingsNavigationAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsNavigationAppearance;

  /// English UI text for settingsNavigationAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get settingsNavigationAudio;

  /// English UI text for settingsNavigationBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get settingsNavigationBluetooth;

  /// English UI text for settingsNavigationDesktopLayout.
  ///
  /// In en, this message translates to:
  /// **'Desktop layout'**
  String get settingsNavigationDesktopLayout;

  /// Label for the Developer destination in Settings navigation.
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get settingsNavigationDeveloper;

  /// Settings navigation label for application environment overrides.
  ///
  /// In en, this message translates to:
  /// **'App environment'**
  String get settingsNavigationEnvironment;

  /// English UI text for settingsNavigationDisplays.
  ///
  /// In en, this message translates to:
  /// **'Displays & video'**
  String get settingsNavigationDisplays;

  /// Label for the Language destination in Settings navigation.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsNavigationLanguage;

  /// Settings navigation label for physical keyboard configuration.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get settingsNavigationKeyboard;

  /// Settings navigation label for mouse and touchpad configuration.
  ///
  /// In en, this message translates to:
  /// **'Mouse & touchpad'**
  String get settingsNavigationTouchpad;

  /// Settings navigation label for configured shortcuts.
  ///
  /// In en, this message translates to:
  /// **'Shortcuts'**
  String get settingsNavigationShortcuts;

  /// English UI text for settingsNavigationLockScreen.
  ///
  /// In en, this message translates to:
  /// **'Lock screen'**
  String get settingsNavigationLockScreen;

  /// English UI text for settingsNavigationNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get settingsNavigationNetwork;

  /// English UI text for settingsNavigationOverlays.
  ///
  /// In en, this message translates to:
  /// **'Overlays'**
  String get settingsNavigationOverlays;

  /// English UI text for settingsNavigationPower.
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get settingsNavigationPower;

  /// English UI text for settingsNavigationSection.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsNavigationSection;

  /// English UI text for settingsNetworkDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage Wi-Fi and connect to nearby networks.'**
  String get settingsNetworkDescription;

  /// English UI text for settingsNetworkSection.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get settingsNetworkSection;

  /// English UI text for settingsNetworkStatusCaptivePortal.
  ///
  /// In en, this message translates to:
  /// **'Sign-in required'**
  String get settingsNetworkStatusCaptivePortal;

  /// English UI text for settingsNetworkStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get settingsNetworkStatusConnecting;

  /// English UI text for settingsNetworkStatusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi is off'**
  String get settingsNetworkStatusDisabled;

  /// English UI text for settingsNetworkStatusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get settingsNetworkStatusDisconnected;

  /// English UI text for settingsNetworkStatusLimited.
  ///
  /// In en, this message translates to:
  /// **'Limited connection'**
  String get settingsNetworkStatusLimited;

  /// English UI text for settingsNetworkStatusLocal.
  ///
  /// In en, this message translates to:
  /// **'Local network only'**
  String get settingsNetworkStatusLocal;

  /// English UI text for settingsNetworkStatusOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get settingsNetworkStatusOnline;

  /// English UI text for settingsNetworkStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Network unavailable'**
  String get settingsNetworkStatusUnavailable;

  /// English UI text for settingsNetworkTitle.
  ///
  /// In en, this message translates to:
  /// **'Network connections.'**
  String get settingsNetworkTitle;

  /// English UI text for settingsNetworkUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Network controls are unavailable.'**
  String get settingsNetworkUnavailable;

  /// English UI text for settingsNoApplicationAudio.
  ///
  /// In en, this message translates to:
  /// **'No applications are playing audio.'**
  String get settingsNoApplicationAudio;

  /// English UI text for settingsNoBluetoothDevices.
  ///
  /// In en, this message translates to:
  /// **'No Bluetooth devices found.'**
  String get settingsNoBluetoothDevices;

  /// English UI text for settingsNoNetworks.
  ///
  /// In en, this message translates to:
  /// **'No networks found.'**
  String get settingsNoNetworks;

  /// English UI text for settingsNotificationOverlayDescription.
  ///
  /// In en, this message translates to:
  /// **'Position notification banners.'**
  String get settingsNotificationOverlayDescription;

  /// English UI text for settingsNotificationOverlayTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotificationOverlayTitle;

  /// English UI text for settingsOneHour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get settingsOneHour;

  /// English UI text for settingsOuterPadding.
  ///
  /// In en, this message translates to:
  /// **'Outer padding'**
  String get settingsOuterPadding;

  /// English UI text for settingsOutputVolume.
  ///
  /// In en, this message translates to:
  /// **'Output volume'**
  String get settingsOutputVolume;

  /// English UI text for settingsOverlaysDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose the position and size of launchers, notifications, and system feedback.'**
  String get settingsOverlaysDescription;

  /// English UI text for settingsOverlaysSection.
  ///
  /// In en, this message translates to:
  /// **'Overlays'**
  String get settingsOverlaysSection;

  /// English UI text for settingsOverlaysTitle.
  ///
  /// In en, this message translates to:
  /// **'Put shell controls where they belong.'**
  String get settingsOverlaysTitle;

  /// English UI text for settingsPaired.
  ///
  /// In en, this message translates to:
  /// **'Paired'**
  String get settingsPaired;

  /// English UI text for settingsPanelMotionDescription.
  ///
  /// In en, this message translates to:
  /// **'Tune the speed and travel of launcher and dashboard transitions.'**
  String get settingsPanelMotionDescription;

  /// English UI text for settingsPanelMotionTitle.
  ///
  /// In en, this message translates to:
  /// **'Panel motion'**
  String get settingsPanelMotionTitle;

  /// English UI text for settingsPanelOpacity.
  ///
  /// In en, this message translates to:
  /// **'Panel opacity'**
  String get settingsPanelOpacity;

  /// English UI text for settingsPanelTravel.
  ///
  /// In en, this message translates to:
  /// **'Panel travel'**
  String get settingsPanelTravel;

  /// English UI text for settingsPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Password required'**
  String get settingsPasswordRequired;

  /// English UI text for settingsPercent.
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String settingsPercent(int percent);

  /// English UI text for settingsPixels.
  ///
  /// In en, this message translates to:
  /// **'{pixels} px'**
  String settingsPixels(int pixels);

  /// English UI text for settingsPowerDescription.
  ///
  /// In en, this message translates to:
  /// **'Control display timeout behavior and idle inhibition.'**
  String get settingsPowerDescription;

  /// English UI text for settingsPowerSection.
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get settingsPowerSection;

  /// English UI text for settingsPowerTitle.
  ///
  /// In en, this message translates to:
  /// **'Power that respects your workflow.'**
  String get settingsPowerTitle;

  /// English UI text for settingsRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get settingsRefresh;

  /// English UI text for settingsResetPage.
  ///
  /// In en, this message translates to:
  /// **'Reset page'**
  String get settingsResetPage;

  /// English UI text for settingsScan.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get settingsScan;

  /// English UI text for settingsScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get settingsScanning;

  /// English UI text for settingsScreenAnchor.
  ///
  /// In en, this message translates to:
  /// **'Screen anchor'**
  String get settingsScreenAnchor;

  /// English UI text for settingsShapeDescription.
  ///
  /// In en, this message translates to:
  /// **'Scale every shell corner while preserving the hierarchy between windows, panels, cards, and controls.'**
  String get settingsShapeDescription;

  /// English UI text for settingsShapeTitle.
  ///
  /// In en, this message translates to:
  /// **'Shape'**
  String get settingsShapeTitle;

  /// Slider label for the global shell corner-radius scale.
  ///
  /// In en, this message translates to:
  /// **'Corner roundness'**
  String get settingsCornerRoundness;

  /// Title for the desktop-wide colour-scheme preference.
  ///
  /// In en, this message translates to:
  /// **'Colour scheme'**
  String get settingsColorSchemeTitle;

  /// Dark colour-scheme choice.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsColorSchemeDark;

  /// Light colour-scheme choice.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsColorSchemeLight;

  /// Choice that lets applications select their own colour scheme.
  ///
  /// In en, this message translates to:
  /// **'No preference'**
  String get settingsColorSchemeNoPreference;

  /// Explanation for an explicit dark or light desktop preference.
  ///
  /// In en, this message translates to:
  /// **'Use the same colour scheme across Denial and supported applications.'**
  String get settingsColorSchemeDescription;

  /// Explanation of the no-preference state and Denial's concrete fallback.
  ///
  /// In en, this message translates to:
  /// **'Denial keeps its default dark appearance while applications choose their own.'**
  String get settingsColorSchemeNoPreferenceDescription;

  /// English UI text for settingsShellAccentChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose accent color'**
  String get settingsShellAccentChoose;

  /// English UI text for settingsShellAccentCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get settingsShellAccentCustom;

  /// English UI text for settingsShellAccentDescription.
  ///
  /// In en, this message translates to:
  /// **'The accent colors focused windows, controls, and active shell surfaces.'**
  String get settingsShellAccentDescription;

  /// English UI text for settingsShellAccentTitle.
  ///
  /// In en, this message translates to:
  /// **'Shell accent'**
  String get settingsShellAccentTitle;

  /// English UI text for settingsShellAccentWallpaper.
  ///
  /// In en, this message translates to:
  /// **'From wallpaper'**
  String get settingsShellAccentWallpaper;

  /// English UI text for settingsShowSystemStatus.
  ///
  /// In en, this message translates to:
  /// **'Show performance and power status'**
  String get settingsShowSystemStatus;

  /// English UI text for settingsShowSystemStatusDescription.
  ///
  /// In en, this message translates to:
  /// **'Show CPU, GPU, battery, and temperature information on the desktop lock screen.'**
  String get settingsShowSystemStatusDescription;

  /// English UI text for settingsSignalStrength.
  ///
  /// In en, this message translates to:
  /// **'Signal: {strength}%'**
  String settingsSignalStrength(int strength);

  /// English UI text for settingsStorageLocation.
  ///
  /// In en, this message translates to:
  /// **'Settings are stored in\n~/.config/denial/settings.json'**
  String get settingsStorageLocation;

  /// Clarifies that multiple bars are cloned rather than stretched.
  ///
  /// In en, this message translates to:
  /// **'Each selected display gets its own bar. The bar never spans displays.'**
  String get settingsSystemBarCloneHint;

  /// Explanation of system bar edge and multi-display behavior.
  ///
  /// In en, this message translates to:
  /// **'Place the bar on any edge and show an independent copy on every selected display.'**
  String get settingsSystemBarDescription;

  /// Resolution and scale shown for one display.
  ///
  /// In en, this message translates to:
  /// **'{width} × {height} · {scale}×'**
  String settingsSystemBarDisplayDetails(int width, int height, String scale);

  /// Accessibility value for an unselected system bar display.
  ///
  /// In en, this message translates to:
  /// **'System bar not shown on {displayName}'**
  String settingsSystemBarDisplayNotSelectedSemantics(String displayName);

  /// Accessibility value for a selected system bar display.
  ///
  /// In en, this message translates to:
  /// **'System bar shown on {displayName}'**
  String settingsSystemBarDisplaySelectedSemantics(String displayName);

  /// Uppercase label above the system bar display choices.
  ///
  /// In en, this message translates to:
  /// **'DISPLAYS'**
  String get settingsSystemBarDisplaysLabel;

  /// Count of displays selected to show a system bar.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 display selected} other{{count} displays selected}}'**
  String settingsSystemBarDisplaysSelected(int count);

  /// Label for placing the system bar at the bottom edge.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get settingsSystemBarEdgeBottom;

  /// Uppercase label above the system bar edge choices.
  ///
  /// In en, this message translates to:
  /// **'EDGE'**
  String get settingsSystemBarEdgeLabel;

  /// Label for placing the system bar at the left edge.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get settingsSystemBarEdgeLeft;

  /// Label for placing the system bar at the right edge.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get settingsSystemBarEdgeRight;

  /// Label for placing the system bar at the top edge.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get settingsSystemBarEdgeTop;

  /// Accessibility hint explaining why the last selected display cannot be removed.
  ///
  /// In en, this message translates to:
  /// **'Select another display before removing this one.'**
  String get settingsSystemBarLastDisplayHint;

  /// Badge identifying the compositor's main display.
  ///
  /// In en, this message translates to:
  /// **'MAIN'**
  String get settingsSystemBarMainDisplay;

  /// Title of the system bar placement setting.
  ///
  /// In en, this message translates to:
  /// **'Desktop system bar'**
  String get settingsSystemBarTitle;

  /// Message shown while display topology is unavailable.
  ///
  /// In en, this message translates to:
  /// **'Display information is not available yet.'**
  String get settingsSystemBarUnavailable;

  /// English UI text for settingsTwoHours.
  ///
  /// In en, this message translates to:
  /// **'2 hours'**
  String get settingsTwoHours;

  /// Label for the automatic suspend timeout.
  ///
  /// In en, this message translates to:
  /// **'Suspend after'**
  String get settingsSuspendTimeout;

  /// English UI text for settingsUnfocusedWindows.
  ///
  /// In en, this message translates to:
  /// **'Unfocused windows'**
  String get settingsUnfocusedWindows;

  /// English UI text for settingsUseSystemWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Use system wallpaper'**
  String get settingsUseSystemWallpaper;

  /// English UI text for settingsUseSystemWallpaperDescription.
  ///
  /// In en, this message translates to:
  /// **'The lock screen follows wallpaper changes and per-output assignments.'**
  String get settingsUseSystemWallpaperDescription;

  /// Action that opens the shell wallpaper selector.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get settingsWallpaperChoose;

  /// Explanation of the wallpaper appearance setting.
  ///
  /// In en, this message translates to:
  /// **'Choose the image shown behind the shell and on the lock screen.'**
  String get settingsWallpaperDescription;

  /// Accessibility label for the current wallpaper thumbnail.
  ///
  /// In en, this message translates to:
  /// **'Current wallpaper preview'**
  String get settingsWallpaperPreviewSemantics;

  /// Title of the wallpaper appearance setting.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get settingsWallpaperTitle;

  /// English UI text for settingsWidth.
  ///
  /// In en, this message translates to:
  /// **'Width'**
  String get settingsWidth;

  /// English UI text for settingsWifiEnabled.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi enabled'**
  String get settingsWifiEnabled;

  /// English UI text for settingsWifiEnabledDescription.
  ///
  /// In en, this message translates to:
  /// **'Allow Denial to scan for and connect to wireless networks.'**
  String get settingsWifiEnabledDescription;

  /// English UI text for settingsWifiTitle.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get settingsWifiTitle;

  /// English UI text for settingsWindowCloseEffectDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose the animation used when a desktop window closes.'**
  String get settingsWindowCloseEffectDescription;

  /// English UI text for settingsWindowCloseEffectTitle.
  ///
  /// In en, this message translates to:
  /// **'Window closing effect'**
  String get settingsWindowCloseEffectTitle;

  /// Explanation of the minimized-window placement setting.
  ///
  /// In en, this message translates to:
  /// **'Keep minimized windows as live previews on the desktop, or glide them beyond the screen edge until restored.'**
  String get settingsWindowMinimizationDescription;

  /// Choice that places minimized windows on the desktop.
  ///
  /// In en, this message translates to:
  /// **'On desktop'**
  String get settingsWindowMinimizationDesktop;

  /// Choice that places minimized windows beyond the screen edge.
  ///
  /// In en, this message translates to:
  /// **'Off-screen'**
  String get settingsWindowMinimizationOffscreen;

  /// Title for the minimized-window placement setting.
  ///
  /// In en, this message translates to:
  /// **'Window minimization'**
  String get settingsWindowMinimizationTitle;

  /// English UI text for settingsWindowOpacityDescription.
  ///
  /// In en, this message translates to:
  /// **'Control the opacity of focused and unfocused windows.'**
  String get settingsWindowOpacityDescription;

  /// English UI text for settingsWindowOpacityTitle.
  ///
  /// In en, this message translates to:
  /// **'Window opacity'**
  String get settingsWindowOpacityTitle;

  /// English UI text for shortDate.
  ///
  /// In en, this message translates to:
  /// **'{weekday} {day} {month}'**
  String shortDate(String weekday, int day, String month);

  /// English UI text for statusBarLiveTime.
  ///
  /// In en, this message translates to:
  /// **'{time} · LIVE'**
  String statusBarLiveTime(String time);

  /// English UI text for statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get statusUnknown;

  /// English UI text for statusWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get statusWaiting;

  /// English UI text for temperatureCelsius.
  ///
  /// In en, this message translates to:
  /// **'{temperature}°C'**
  String temperatureCelsius(int temperature);

  /// English UI text for thermalSensorCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get thermalSensorCpu;

  /// English UI text for thermalSensorExp2.
  ///
  /// In en, this message translates to:
  /// **'EXP2'**
  String get thermalSensorExp2;

  /// English UI text for thermalSensorPmic.
  ///
  /// In en, this message translates to:
  /// **'PMIC'**
  String get thermalSensorPmic;

  /// English UI text for thermalSensorSvooc.
  ///
  /// In en, this message translates to:
  /// **'SVOOC'**
  String get thermalSensorSvooc;

  /// English UI text for timeHoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hour}:{minute}'**
  String timeHoursMinutes(String hour, String minute);

  /// English UI text for valueUnavailable.
  ///
  /// In en, this message translates to:
  /// **'--.-'**
  String get valueUnavailable;

  /// English UI text for voltageVolts.
  ///
  /// In en, this message translates to:
  /// **'{voltage} V'**
  String voltageVolts(String voltage);

  /// English UI text for volumeTitle.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get volumeTitle;

  /// English UI text for wallpaperAlignBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get wallpaperAlignBottom;

  /// English UI text for wallpaperAlignHorizontalCenter.
  ///
  /// In en, this message translates to:
  /// **'Horizontal center'**
  String get wallpaperAlignHorizontalCenter;

  /// English UI text for wallpaperAlignLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get wallpaperAlignLeft;

  /// English UI text for wallpaperAlignRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get wallpaperAlignRight;

  /// English UI text for wallpaperAlignTop.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get wallpaperAlignTop;

  /// English UI text for wallpaperAlignVerticalCenter.
  ///
  /// In en, this message translates to:
  /// **'Vertical center'**
  String get wallpaperAlignVerticalCenter;

  /// English UI text for wallpaperAllDisplays.
  ///
  /// In en, this message translates to:
  /// **'All displays'**
  String get wallpaperAllDisplays;

  /// English UI text for wallpaperApplyAllDisplays.
  ///
  /// In en, this message translates to:
  /// **'Apply to all displays'**
  String get wallpaperApplyAllDisplays;

  /// English UI text for wallpaperApplyCandidate.
  ///
  /// In en, this message translates to:
  /// **'Apply {wallpaperName}'**
  String wallpaperApplyCandidate(String wallpaperName);

  /// English UI text for wallpaperApplyDisplay.
  ///
  /// In en, this message translates to:
  /// **'Apply to {displayName}'**
  String wallpaperApplyDisplay(String displayName);

  /// English UI text for wallpaperCloseSelector.
  ///
  /// In en, this message translates to:
  /// **'Close wallpaper selector'**
  String get wallpaperCloseSelector;

  /// English UI text for wallpaperDarkness.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper darkness'**
  String get wallpaperDarkness;

  /// English UI text for wallpaperDarknessShort.
  ///
  /// In en, this message translates to:
  /// **'Darkness'**
  String get wallpaperDarknessShort;

  /// English UI text for wallpaperDecodeError.
  ///
  /// In en, this message translates to:
  /// **'This wallpaper could not be decoded.'**
  String get wallpaperDecodeError;

  /// English UI text for wallpaperDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get wallpaperDefault;

  /// English UI text for wallpaperDimensions.
  ///
  /// In en, this message translates to:
  /// **'{width} × {height}'**
  String wallpaperDimensions(int width, int height);

  /// English UI text for wallpaperFinding.
  ///
  /// In en, this message translates to:
  /// **'Finding wallpapers…'**
  String get wallpaperFinding;

  /// Hint identifying the folder scanned for manually added wallpapers.
  ///
  /// In en, this message translates to:
  /// **'Add your own wallpapers to {directory}.'**
  String wallpaperFolderHint(String directory);

  /// Warning shown when the remote wallpaper image server cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'Online wallpapers are unavailable. Local wallpapers still work.'**
  String get wallpaperImageServerUnavailable;

  /// Wallpaper catalog pagination control.
  ///
  /// In en, this message translates to:
  /// **'Previous wallpaper page'**
  String get wallpaperPreviousPage;

  /// Wallpaper catalog pagination control.
  ///
  /// In en, this message translates to:
  /// **'Next wallpaper page'**
  String get wallpaperNextPage;

  /// Wallpaper catalog pagination control.
  ///
  /// In en, this message translates to:
  /// **'Page {page}'**
  String wallpaperPageNumber(int page);

  /// Wallpaper catalog pagination control.
  ///
  /// In en, this message translates to:
  /// **'Page {page} of {total}'**
  String wallpaperPageOfTotal(int page, int total);

  /// Accessibility label for the wallpaper selector's strip/gallery layout switch.
  ///
  /// In en, this message translates to:
  /// **'Preview layout'**
  String get wallpaperLayout;

  /// Wallpaper selector layout option that shows each wallpaper uncropped in a grid.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get wallpaperLayoutGallery;

  /// Accessibility label for switching the wallpaper selector to its uncropped gallery.
  ///
  /// In en, this message translates to:
  /// **'Show full wallpaper previews'**
  String get wallpaperLayoutGalleryDescription;

  /// Wallpaper selector layout option that shows narrow cropped strips.
  ///
  /// In en, this message translates to:
  /// **'Strips'**
  String get wallpaperLayoutStrips;

  /// Accessibility label for switching the wallpaper selector to its default narrow strips.
  ///
  /// In en, this message translates to:
  /// **'Show cropped wallpaper strips'**
  String get wallpaperLayoutStripsDescription;

  /// Accessibility label for leaving mobile wallpaper positioning.
  ///
  /// In en, this message translates to:
  /// **'Back to wallpaper selection'**
  String get wallpaperMobileBackToSelection;

  /// Button that centers the mobile wallpaper position.
  ///
  /// In en, this message translates to:
  /// **'Center'**
  String get wallpaperMobileCenterPosition;

  /// Heading above mobile wallpaper choices.
  ///
  /// In en, this message translates to:
  /// **'Choose a wallpaper'**
  String get wallpaperMobileChoose;

  /// Button that finishes precise mobile wallpaper positioning.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get wallpaperMobileDone;

  /// Accessibility label for hiding the mobile wallpaper selector UI.
  ///
  /// In en, this message translates to:
  /// **'Hide controls'**
  String get wallpaperMobileHideControls;

  /// Label for precise horizontal wallpaper positioning.
  ///
  /// In en, this message translates to:
  /// **'Horizontal'**
  String get wallpaperMobileHorizontalPosition;

  /// Action and title for precise mobile wallpaper positioning.
  ///
  /// In en, this message translates to:
  /// **'Position'**
  String get wallpaperMobilePosition;

  /// Instruction shown while positioning a mobile wallpaper.
  ///
  /// In en, this message translates to:
  /// **'Drag the wallpaper, then fine-tune its position'**
  String get wallpaperMobilePositionHint;

  /// Accessibility label for restoring the hidden mobile wallpaper selector UI.
  ///
  /// In en, this message translates to:
  /// **'Show controls'**
  String get wallpaperMobileShowControls;

  /// Title of the dedicated mobile wallpaper selector.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get wallpaperMobileTitle;

  /// Label for precise vertical wallpaper positioning.
  ///
  /// In en, this message translates to:
  /// **'Vertical'**
  String get wallpaperMobileVerticalPosition;

  /// English UI text for wallpaperNoneFound.
  ///
  /// In en, this message translates to:
  /// **'No wallpapers found'**
  String get wallpaperNoneFound;

  /// English UI text for wallpaperSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search wallpapers'**
  String get wallpaperSearchHint;

  /// English UI text for wallpaperSearchSemantics.
  ///
  /// In en, this message translates to:
  /// **'Search wallpapers'**
  String get wallpaperSearchSemantics;

  /// English UI text for wallpaperServiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper service unavailable'**
  String get wallpaperServiceUnavailable;

  /// Accessibility label for positioning the wallpaper within its selected display target.
  ///
  /// In en, this message translates to:
  /// **'Image position'**
  String get wallpaperSpanAlignment;

  /// English UI text for wallpaperTarget.
  ///
  /// In en, this message translates to:
  /// **'Target'**
  String get wallpaperTarget;

  /// English UI text for weekdayFriday.
  ///
  /// In en, this message translates to:
  /// **'Friday'**
  String get weekdayFriday;

  /// English UI text for weekdayMonday.
  ///
  /// In en, this message translates to:
  /// **'Monday'**
  String get weekdayMonday;

  /// English UI text for weekdaySaturday.
  ///
  /// In en, this message translates to:
  /// **'Saturday'**
  String get weekdaySaturday;

  /// English UI text for weekdaySunday.
  ///
  /// In en, this message translates to:
  /// **'Sunday'**
  String get weekdaySunday;

  /// English UI text for weekdayThursday.
  ///
  /// In en, this message translates to:
  /// **'Thursday'**
  String get weekdayThursday;

  /// English UI text for weekdayTuesday.
  ///
  /// In en, this message translates to:
  /// **'Tuesday'**
  String get weekdayTuesday;

  /// English UI text for weekdayWednesday.
  ///
  /// In en, this message translates to:
  /// **'Wednesday'**
  String get weekdayWednesday;

  /// English UI text for wifiAuthorizationMayBeRequired.
  ///
  /// In en, this message translates to:
  /// **'Authorization may be required.'**
  String get wifiAuthorizationMayBeRequired;

  /// English UI text for wifiCloseDetails.
  ///
  /// In en, this message translates to:
  /// **'Close Wi-Fi details'**
  String get wifiCloseDetails;

  /// English UI text for wifiConnectNetwork.
  ///
  /// In en, this message translates to:
  /// **'Connect to {networkName}, {status}, signal {strength}%'**
  String wifiConnectNetwork(String networkName, String status, int strength);

  /// English UI text for wifiDisconnectNetwork.
  ///
  /// In en, this message translates to:
  /// **'Disconnect from {networkName}'**
  String wifiDisconnectNetwork(String networkName);

  /// English UI text for wifiDismissError.
  ///
  /// In en, this message translates to:
  /// **'Dismiss Wi-Fi error'**
  String get wifiDismissError;

  /// English UI text for wifiForgetNetwork.
  ///
  /// In en, this message translates to:
  /// **'Forget {networkName}'**
  String wifiForgetNetwork(String networkName);

  /// English UI text for wifiHardwareBlocked.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi is hardware blocked'**
  String get wifiHardwareBlocked;

  /// English UI text for wifiHardwareBlockedDescription.
  ///
  /// In en, this message translates to:
  /// **'Enable the wireless hardware switch to continue.'**
  String get wifiHardwareBlockedDescription;

  /// English UI text for wifiHardwareDisabled.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi hardware disabled'**
  String get wifiHardwareDisabled;

  /// English UI text for wifiLimitedConnection.
  ///
  /// In en, this message translates to:
  /// **'Limited connection'**
  String get wifiLimitedConnection;

  /// English UI text for wifiLoadingService.
  ///
  /// In en, this message translates to:
  /// **'Loading network service…'**
  String get wifiLoadingService;

  /// English UI text for wifiLocalConnection.
  ///
  /// In en, this message translates to:
  /// **'Local network'**
  String get wifiLocalConnection;

  /// English UI text for wifiLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'Local only'**
  String get wifiLocalOnly;

  /// English UI text for wifiNamedStatus.
  ///
  /// In en, this message translates to:
  /// **'{networkName} · {status}'**
  String wifiNamedStatus(String networkName, String status);

  /// English UI text for wifiNoAdapter.
  ///
  /// In en, this message translates to:
  /// **'No Wi-Fi adapter'**
  String get wifiNoAdapter;

  /// English UI text for wifiNoAdapterDescription.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi controls will appear when an adapter is available.'**
  String get wifiNoAdapterDescription;

  /// English UI text for wifiNoNetworks.
  ///
  /// In en, this message translates to:
  /// **'No networks found'**
  String get wifiNoNetworks;

  /// English UI text for wifiNoNetworksDescription.
  ///
  /// In en, this message translates to:
  /// **'Start a scan to find nearby networks.'**
  String get wifiNoNetworksDescription;

  /// English UI text for wifiOff.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi is off'**
  String get wifiOff;

  /// English UI text for wifiOffDescription.
  ///
  /// In en, this message translates to:
  /// **'Turn it on to see nearby networks.'**
  String get wifiOffDescription;

  /// English UI text for wifiOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi could not complete the request.'**
  String get wifiOperationFailed;

  /// English UI text for wifiPasswordField.
  ///
  /// In en, this message translates to:
  /// **'Password for {networkName}'**
  String wifiPasswordField(String networkName);

  /// English UI text for wifiPasswordFor.
  ///
  /// In en, this message translates to:
  /// **'Enter the password for {networkName}'**
  String wifiPasswordFor(String networkName);

  /// English UI text for wifiPasswordRequirements.
  ///
  /// In en, this message translates to:
  /// **'Enter a password containing at least 8 characters.'**
  String get wifiPasswordRequirements;

  /// English UI text for wifiPermissionLimited.
  ///
  /// In en, this message translates to:
  /// **'Network permissions are limited.'**
  String get wifiPermissionLimited;

  /// English UI text for wifiSavedOutOfRange.
  ///
  /// In en, this message translates to:
  /// **'Saved · out of range'**
  String get wifiSavedOutOfRange;

  /// English UI text for wifiSavedWithSecurity.
  ///
  /// In en, this message translates to:
  /// **'Saved · {security}'**
  String wifiSavedWithSecurity(String security);

  /// English UI text for wifiScanNetworks.
  ///
  /// In en, this message translates to:
  /// **'Scan for Wi-Fi networks'**
  String get wifiScanNetworks;

  /// English UI text for wifiScanningDescription.
  ///
  /// In en, this message translates to:
  /// **'Nearby networks will appear automatically.'**
  String get wifiScanningDescription;

  /// English UI text for wifiScanningNetworks.
  ///
  /// In en, this message translates to:
  /// **'Scanning for Wi-Fi networks…'**
  String get wifiScanningNetworks;

  /// English UI text for wifiSecurityEnhancedOpen.
  ///
  /// In en, this message translates to:
  /// **'Enhanced Open'**
  String get wifiSecurityEnhancedOpen;

  /// English UI text for wifiSecurityEnterprise.
  ///
  /// In en, this message translates to:
  /// **'Enterprise'**
  String get wifiSecurityEnterprise;

  /// English UI text for wifiSecurityOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get wifiSecurityOpen;

  /// English UI text for wifiSecurityUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Unsupported security'**
  String get wifiSecurityUnsupported;

  /// English UI text for wifiSecurityWep.
  ///
  /// In en, this message translates to:
  /// **'WEP'**
  String get wifiSecurityWep;

  /// English UI text for wifiSecurityWpa3Personal.
  ///
  /// In en, this message translates to:
  /// **'WPA3 Personal'**
  String get wifiSecurityWpa3Personal;

  /// English UI text for wifiSecurityWpaPersonal.
  ///
  /// In en, this message translates to:
  /// **'WPA/WPA2 Personal'**
  String get wifiSecurityWpaPersonal;

  /// English UI text for wifiServiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Network service is unavailable'**
  String get wifiServiceUnavailable;

  /// English UI text for wifiServiceUnavailableDescription.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi controls will return when the network service starts.'**
  String get wifiServiceUnavailableDescription;

  /// English UI text for wifiServiceUnavailableShort.
  ///
  /// In en, this message translates to:
  /// **'Network unavailable'**
  String get wifiServiceUnavailableShort;

  /// English UI text for wifiSignInRequired.
  ///
  /// In en, this message translates to:
  /// **'Sign-in required'**
  String get wifiSignInRequired;

  /// English UI text for wifiTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn Wi-Fi off'**
  String get wifiTurnOff;

  /// English UI text for wifiTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn Wi-Fi on'**
  String get wifiTurnOn;

  /// English UI text for wifiWepRequirements.
  ///
  /// In en, this message translates to:
  /// **'WEP keys must contain between 5 and 64 characters.'**
  String get wifiWepRequirements;

  /// English UI text for windowSwitcherPosition.
  ///
  /// In en, this message translates to:
  /// **'{position} / {total}'**
  String windowSwitcherPosition(int position, int total);

  /// English UI text for windowSwitcherSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected {windowTitle}'**
  String windowSwitcherSelected(String windowTitle);

  /// English UI text for windowUntitled.
  ///
  /// In en, this message translates to:
  /// **'Window {windowId}'**
  String windowUntitled(int windowId);

  /// Glass appearance tuning: Advanced.
  ///
  /// In en, this message translates to:
  /// **'Glass tuning'**
  String get settingsGlassAdvanced;

  /// Glass appearance tuning: Reset.
  ///
  /// In en, this message translates to:
  /// **'Reset glass'**
  String get settingsGlassReset;

  /// Glass appearance tuning: TuningDescription.
  ///
  /// In en, this message translates to:
  /// **'Changes apply immediately. The defaults preserve the original glass effect.'**
  String get settingsGlassTuningDescription;

  /// Glass appearance tuning: BevelWidth.
  ///
  /// In en, this message translates to:
  /// **'Bevel width'**
  String get settingsGlassBevelWidth;

  /// Glass appearance tuning: RefractionDepth.
  ///
  /// In en, this message translates to:
  /// **'Refraction depth'**
  String get settingsGlassRefractionDepth;

  /// Glass appearance tuning: RimWidth.
  ///
  /// In en, this message translates to:
  /// **'Highlight width'**
  String get settingsGlassRimWidth;

  /// Glass appearance tuning: RimFalloff.
  ///
  /// In en, this message translates to:
  /// **'Highlight falloff'**
  String get settingsGlassRimFalloff;

  /// Glass appearance tuning: OppositeLight.
  ///
  /// In en, this message translates to:
  /// **'Opposite-edge light'**
  String get settingsGlassOppositeLight;

  /// Width of the glass highlight in pixels, including fractional values.
  ///
  /// In en, this message translates to:
  /// **'{width} px'**
  String settingsGlassRimPixels(String width);

  /// Brief lock screen feedback when a fingerprint does not match.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint not recognized'**
  String get lockFingerprintNotRecognized;

  /// Fingerprint settings: fingerprintSection
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get fingerprintSection;

  /// Fingerprint settings: fingerprintPasswordPrompt
  ///
  /// In en, this message translates to:
  /// **'Enter your sudo password to manage fingerprints.'**
  String get fingerprintPasswordPrompt;

  /// Fingerprint settings: fingerprintSudoPassword
  ///
  /// In en, this message translates to:
  /// **'Sudo password'**
  String get fingerprintSudoPassword;

  /// Fingerprint settings: fingerprintContinue
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get fingerprintContinue;

  /// Fingerprint settings: fingerprintDescription
  ///
  /// In en, this message translates to:
  /// **'Use your enrolled fingers to unlock Denial.'**
  String get fingerprintDescription;

  /// Fingerprint settings: fingerprintEmptyTitle
  ///
  /// In en, this message translates to:
  /// **'No fingerprints enrolled'**
  String get fingerprintEmptyTitle;

  /// Fingerprint settings: fingerprintEmptyDescription
  ///
  /// In en, this message translates to:
  /// **'Choose a finger below to enroll your first fingerprint.'**
  String get fingerprintEmptyDescription;

  /// Fingerprint settings: fingerprintChooseFinger
  ///
  /// In en, this message translates to:
  /// **'Finger to enroll'**
  String get fingerprintChooseFinger;

  /// Fingerprint settings: fingerprintEnroll
  ///
  /// In en, this message translates to:
  /// **'Enroll fingerprint'**
  String get fingerprintEnroll;

  /// Fingerprint settings: fingerprintAdd
  ///
  /// In en, this message translates to:
  /// **'Add fingerprint'**
  String get fingerprintAdd;

  /// Fingerprint settings: fingerprintAuthenticationFailed
  ///
  /// In en, this message translates to:
  /// **'Password verification failed. Try again.'**
  String get fingerprintAuthenticationFailed;

  /// Fingerprint settings: fingerprintExpired
  ///
  /// In en, this message translates to:
  /// **'Enter your password again to continue.'**
  String get fingerprintExpired;

  /// Fingerprint settings: fingerprintPreparing
  ///
  /// In en, this message translates to:
  /// **'Preparing the fingerprint reader…'**
  String get fingerprintPreparing;

  /// Fingerprint settings: fingerprintTouchSensor
  ///
  /// In en, this message translates to:
  /// **'Touch and lift your selected finger on the sensor.'**
  String get fingerprintTouchSensor;

  /// Fingerprint settings: fingerprintEnrolled
  ///
  /// In en, this message translates to:
  /// **'Fingerprint enrolled. You can now use it to unlock Denial.'**
  String get fingerprintEnrolled;

  /// Fingerprint settings: fingerprintCancelled
  ///
  /// In en, this message translates to:
  /// **'Enrollment cancelled.'**
  String get fingerprintCancelled;

  /// Fingerprint settings: fingerprintDuplicate
  ///
  /// In en, this message translates to:
  /// **'This fingerprint is already enrolled. Choose another finger.'**
  String get fingerprintDuplicate;

  /// Fingerprint settings: fingerprintRetry
  ///
  /// In en, this message translates to:
  /// **'Lift your finger and touch the sensor again, adjusting its position.'**
  String get fingerprintRetry;

  /// Fingerprint settings: fingerprintUnavailable
  ///
  /// In en, this message translates to:
  /// **'Fingerprint management could not complete. Check the reader and try again.'**
  String get fingerprintUnavailable;

  /// Fingerprint settings: fingerprintProgress
  ///
  /// In en, this message translates to:
  /// **'{completed} of {total} scans'**
  String fingerprintProgress(int completed, int total);

  /// Fingerprint settings: fingerprintLeftThumb
  ///
  /// In en, this message translates to:
  /// **'Left thumb'**
  String get fingerprintLeftThumb;

  /// Fingerprint settings: fingerprintLeftIndex
  ///
  /// In en, this message translates to:
  /// **'Left index finger'**
  String get fingerprintLeftIndex;

  /// Fingerprint settings: fingerprintLeftMiddle
  ///
  /// In en, this message translates to:
  /// **'Left middle finger'**
  String get fingerprintLeftMiddle;

  /// Fingerprint settings: fingerprintLeftRing
  ///
  /// In en, this message translates to:
  /// **'Left ring finger'**
  String get fingerprintLeftRing;

  /// Fingerprint settings: fingerprintLeftLittle
  ///
  /// In en, this message translates to:
  /// **'Left little finger'**
  String get fingerprintLeftLittle;

  /// Fingerprint settings: fingerprintRightThumb
  ///
  /// In en, this message translates to:
  /// **'Right thumb'**
  String get fingerprintRightThumb;

  /// Fingerprint settings: fingerprintRightIndex
  ///
  /// In en, this message translates to:
  /// **'Right index finger'**
  String get fingerprintRightIndex;

  /// Fingerprint settings: fingerprintRightMiddle
  ///
  /// In en, this message translates to:
  /// **'Right middle finger'**
  String get fingerprintRightMiddle;

  /// Fingerprint settings: fingerprintRightRing
  ///
  /// In en, this message translates to:
  /// **'Right ring finger'**
  String get fingerprintRightRing;

  /// Fingerprint settings: fingerprintRightLittle
  ///
  /// In en, this message translates to:
  /// **'Right little finger'**
  String get fingerprintRightLittle;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Mobile data'**
  String get mobileData;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get mobileConnected;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get mobileDisconnected;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Mobile network unavailable'**
  String get mobileUnavailable;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Unable to change mobile data'**
  String get mobileChangeFailed;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Unlock SIM'**
  String get simPinTitle;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'SIM PIN'**
  String get simPinLabel;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Unlock SIM'**
  String get simPinUnlock;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get simPinLater;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'SIM could not be unlocked. Check your PIN and remaining attempts.'**
  String get simPinFailed;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'SIM requires a PUK. Contact your carrier.'**
  String get simPukRequired;

  /// Mobile connectivity and SIM authentication UI.
  ///
  /// In en, this message translates to:
  /// **'SIM locked'**
  String get simLocked;

  /// No description provided for @simPinRetries.
  ///
  /// In en, this message translates to:
  /// **'{count} attempts remaining'**
  String simPinRetries(int count);

  /// Shortcut action label: grow window width.
  ///
  /// In en, this message translates to:
  /// **'Grow window width'**
  String get settingsShortcutActionResizeGrowWidth;

  /// Shortcut action label: shrink window width.
  ///
  /// In en, this message translates to:
  /// **'Shrink window width'**
  String get settingsShortcutActionResizeShrinkWidth;

  /// Shortcut action label: grow window height.
  ///
  /// In en, this message translates to:
  /// **'Grow window height'**
  String get settingsShortcutActionResizeGrowHeight;

  /// Shortcut action label: shrink window height.
  ///
  /// In en, this message translates to:
  /// **'Shrink window height'**
  String get settingsShortcutActionResizeShrinkHeight;

  /// Shortcut action label: reset window height.
  ///
  /// In en, this message translates to:
  /// **'Reset window height'**
  String get settingsShortcutActionResetWindowHeight;

  /// Shortcut action label: reset window width.
  ///
  /// In en, this message translates to:
  /// **'Reset window width'**
  String get settingsShortcutActionResetWindowWidth;

  /// Appearance card heading for color scheme and accent.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsAppearanceTheme;

  /// Appearance card heading for window shape and focus.
  ///
  /// In en, this message translates to:
  /// **'Windows'**
  String get settingsAppearanceWindows;

  /// Appearance card heading for transparency and its effects.
  ///
  /// In en, this message translates to:
  /// **'Transparency'**
  String get settingsAppearanceTransparency;

  /// Disclosure for detailed transparency controls.
  ///
  /// In en, this message translates to:
  /// **'Advanced effects'**
  String get settingsAppearanceAdvancedEffects;

  /// Summary of advanced glass controls.
  ///
  /// In en, this message translates to:
  /// **'Color, optics, lighting and rendering.'**
  String get settingsAppearanceAdvancedEffectsDescription;

  /// Summary of advanced blur controls.
  ///
  /// In en, this message translates to:
  /// **'Fine-tune where the effect is applied.'**
  String get settingsAppearanceCompositingDescription;

  /// Advanced glass color controls heading.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get settingsAppearanceColorEffects;

  /// Advanced glass optical controls heading.
  ///
  /// In en, this message translates to:
  /// **'Optics'**
  String get settingsAppearanceOptics;

  /// Advanced glass lighting controls heading.
  ///
  /// In en, this message translates to:
  /// **'Lighting'**
  String get settingsAppearanceLighting;

  /// Advanced glass rendering controls heading.
  ///
  /// In en, this message translates to:
  /// **'Rendering'**
  String get settingsAppearanceRendering;

  /// Disclosure for application-provided cursors.
  ///
  /// In en, this message translates to:
  /// **'Application cursors'**
  String get settingsAppearanceCursorAdvanced;

  /// Tooltip for Appearance actions menu.
  ///
  /// In en, this message translates to:
  /// **'Appearance actions'**
  String get settingsAppearanceActions;

  /// Action to reset Appearance settings.
  ///
  /// In en, this message translates to:
  /// **'Reset appearance'**
  String get settingsResetAppearance;

  /// Action to reset glass effects while preserving appearance and all three opacity settings.
  ///
  /// In en, this message translates to:
  /// **'Reset glass effects'**
  String get settingsResetGlassEffects;

  /// Wallpaper card: Default
  ///
  /// In en, this message translates to:
  /// **'Denial default'**
  String get settingsWallpaperDefault;

  /// Wallpaper card: Live
  ///
  /// In en, this message translates to:
  /// **'Live / app-managed wallpaper'**
  String get settingsWallpaperLive;

  /// Wallpaper card: Static
  ///
  /// In en, this message translates to:
  /// **'Static wallpaper'**
  String get settingsWallpaperStatic;

  /// Wallpaper card: LiveDescription
  ///
  /// In en, this message translates to:
  /// **'A wallpaper app is drawing this desktop. Choosing a fallback image will not stop it.'**
  String get settingsWallpaperLiveDescription;

  /// Wallpaper card: ChooseFallback
  ///
  /// In en, this message translates to:
  /// **'Choose fallback image'**
  String get settingsWallpaperChooseFallback;

  /// Wallpaper card: PreviewUnavailable
  ///
  /// In en, this message translates to:
  /// **'Preview unavailable'**
  String get settingsWallpaperPreviewUnavailable;

  /// Caption for the saved fallback image without a filename.
  ///
  /// In en, this message translates to:
  /// **'Fallback image'**
  String get settingsWallpaperFallback;

  /// Wallpaper card: Display
  ///
  /// In en, this message translates to:
  /// **'Display · {name}'**
  String settingsWallpaperDisplay(String name);

  /// Label for the wallpaper applied in appearance settings.
  ///
  /// In en, this message translates to:
  /// **'Applied wallpaper'**
  String get settingsWallpaperApplied;

  /// Shown for a shortcut whose plugin action is currently unavailable.
  ///
  /// In en, this message translates to:
  /// **'Provider unavailable'**
  String get settingsShortcutProviderUnavailable;

  /// Progress label for the first welcome wizard step.
  ///
  /// In en, this message translates to:
  /// **'Welcome'**
  String get welcomeStart;

  /// Button to begin setup from the welcome screen.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get welcomeGetStarted;

  /// Introduction to the welcome wizard and its setup steps.
  ///
  /// In en, this message translates to:
  /// **'Make yourself at home. We will walk through the essential shortcuts, help you choose a window layout, and make the desktop feel like yours. You can change these preferences later in Settings.'**
  String get welcomeStartDescription;

  /// Welcome wizard: Title.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Denial'**
  String get welcomeTitle;

  /// Welcome wizard: Shortcuts.
  ///
  /// In en, this message translates to:
  /// **'Shortcuts'**
  String get welcomeShortcuts;

  /// Welcome wizard: Layout.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get welcomeLayout;

  /// Welcome wizard: Appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get welcomeAppearance;

  /// Welcome wizard: Support.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get welcomeSupport;

  /// Welcome wizard: Next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get welcomeNext;

  /// Welcome wizard: Previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get welcomePrevious;

  /// Welcome wizard: Finish.
  ///
  /// In en, this message translates to:
  /// **'Start using Denial'**
  String get welcomeFinish;

  /// Welcome wizard: ExitSetup.
  ///
  /// In en, this message translates to:
  /// **'Exit setup'**
  String get welcomeExitSetup;

  /// Welcome wizard: Exit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get welcomeExit;

  /// Welcome wizard: Cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get welcomeCancel;

  /// Welcome wizard: ExitMessage.
  ///
  /// In en, this message translates to:
  /// **'The setup won\'\'t appear again, you can open it from your launcher.'**
  String get welcomeExitMessage;

  /// Welcome wizard: Intro.
  ///
  /// In en, this message translates to:
  /// **'A different desktop. A few keys to make it yours.'**
  String get welcomeIntro;

  /// Welcome wizard: ShortcutsDescription.
  ///
  /// In en, this message translates to:
  /// **'These are your current bindings. You can change them later in Settings → Shortcuts.'**
  String get welcomeShortcutsDescription;

  /// Welcome wizard: Kill.
  ///
  /// In en, this message translates to:
  /// **'Kill / close the focused window'**
  String get welcomeKill;

  /// Welcome wizard: Move.
  ///
  /// In en, this message translates to:
  /// **'Move a window'**
  String get welcomeMove;

  /// Welcome wizard: Resize.
  ///
  /// In en, this message translates to:
  /// **'Resize a window'**
  String get welcomeResize;

  /// Welcome wizard: MoveGesture.
  ///
  /// In en, this message translates to:
  /// **'Super + left-button drag'**
  String get welcomeMoveGesture;

  /// Welcome wizard: ResizeGesture.
  ///
  /// In en, this message translates to:
  /// **'Super + right-button drag'**
  String get welcomeResizeGesture;

  /// Welcome wizard: PointerHint.
  ///
  /// In en, this message translates to:
  /// **'Hold Super (the Windows key) and drag anywhere on a window. These pointer gestures are built in.'**
  String get welcomePointerHint;

  /// Welcome wizard: Unbound.
  ///
  /// In en, this message translates to:
  /// **'Not assigned'**
  String get welcomeUnbound;

  /// Welcome wizard: Retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get welcomeRetry;

  /// Welcome wizard: ShortcutsError.
  ///
  /// In en, this message translates to:
  /// **'Your shortcuts could not be loaded.'**
  String get welcomeShortcutsError;

  /// Welcome wizard: LayoutTitle.
  ///
  /// In en, this message translates to:
  /// **'Make room for the way you work.'**
  String get welcomeLayoutTitle;

  /// Welcome wizard: Instant.
  ///
  /// In en, this message translates to:
  /// **'Try a choice. Your desktop changes immediately.'**
  String get welcomeInstant;

  /// Welcome wizard: StackingDescription.
  ///
  /// In en, this message translates to:
  /// **'Place and overlap windows freely.'**
  String get welcomeStackingDescription;

  /// Welcome wizard: DwindleDescription.
  ///
  /// In en, this message translates to:
  /// **'Windows tile into a balanced, branching layout.'**
  String get welcomeDwindleDescription;

  /// Welcome wizard: ScrollingDescription.
  ///
  /// In en, this message translates to:
  /// **'A flowing strip of windows with room to keep going.'**
  String get welcomeScrollingDescription;

  /// Welcome wizard: AppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'A desktop that feels like you.'**
  String get welcomeAppearanceTitle;

  /// Welcome wizard: Material.
  ///
  /// In en, this message translates to:
  /// **'Window material'**
  String get welcomeMaterial;

  /// Welcome wizard: Glass.
  ///
  /// In en, this message translates to:
  /// **'Glass'**
  String get welcomeGlass;

  /// Welcome wizard: Blur.
  ///
  /// In en, this message translates to:
  /// **'Blur'**
  String get welcomeBlur;

  /// Welcome wizard: Nothing.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get welcomeNothing;

  /// Welcome wizard: Theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get welcomeTheme;

  /// Welcome wizard: Light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get welcomeLight;

  /// Welcome wizard: Dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get welcomeDark;

  /// Welcome wizard: SupportTitle.
  ///
  /// In en, this message translates to:
  /// **'Help Denial become what comes next.'**
  String get welcomeSupportTitle;

  /// Welcome wizard: SupportDescription.
  ///
  /// In en, this message translates to:
  /// **'Denial is built with care, curiosity, and the belief that a desktop can be different. If it feels like home, your support helps keep it growing.'**
  String get welcomeSupportDescription;

  /// Welcome wizard: SupportOptional.
  ///
  /// In en, this message translates to:
  /// **'Always optional. Thank you for giving Denial a place on your desktop.'**
  String get welcomeSupportOptional;

  /// Donation button; the destination follows the active language.
  ///
  /// In en, this message translates to:
  /// **'Donate'**
  String get welcomeDonate;

  /// Welcome wizard: Sponsors.
  ///
  /// In en, this message translates to:
  /// **'GitHub Sponsors'**
  String get welcomeSponsors;

  /// Welcome wizard: Repository.
  ///
  /// In en, this message translates to:
  /// **'Explore Denial on GitHub'**
  String get welcomeRepository;

  /// Welcome wizard: LinksPending.
  ///
  /// In en, this message translates to:
  /// **'Donation links will be available soon.'**
  String get welcomeLinksPending;

  /// Welcome wizard: LinkError.
  ///
  /// In en, this message translates to:
  /// **'Could not open your browser. Please try again.'**
  String get welcomeLinkError;

  /// Welcome wizard: SaveError.
  ///
  /// In en, this message translates to:
  /// **'Could not save setup completion. Please try again.'**
  String get welcomeSaveError;

  /// Welcome wizard: WorkspaceDisabled.
  ///
  /// In en, this message translates to:
  /// **'Workspaces are currently disabled. Enable them in Settings → Layout to use these bindings.'**
  String get welcomeWorkspaceDisabled;

  /// Welcome shortcut concept group heading.
  ///
  /// In en, this message translates to:
  /// **'Desktop essentials'**
  String get welcomeDesktopUsage;

  /// Welcome shortcut concept group heading.
  ///
  /// In en, this message translates to:
  /// **'Workspaces'**
  String get welcomeWorkspaces;

  /// Welcome shortcut concept group heading.
  ///
  /// In en, this message translates to:
  /// **'Tiling and keyboard control'**
  String get welcomeTiling;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Administrator authentication required.'**
  String get polkitRunCommandAsAdministrator;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Authentication is required to run this command as {user}.'**
  String polkitRunCommandAsUser(String user);

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Authentication is required.'**
  String get polkitAuthenticationRequired;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Authentication is unavailable.'**
  String get polkitAuthenticationUnavailable;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get polkitPassword;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Verifying…'**
  String get polkitVerifying;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get polkitPreparing;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Caps Lock'**
  String get polkitCapsLock;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get polkitConfirm;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get polkitContinue;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get polkitClose;

  /// Authentication prompt text.
  ///
  /// In en, this message translates to:
  /// **'Temporarily locked'**
  String get polkitLocked;

  /// Plugin Manager: AppTitle.
  ///
  /// In en, this message translates to:
  /// **'Denial Plugins'**
  String get pluginsAppTitle;

  /// Plugin Manager: Title.
  ///
  /// In en, this message translates to:
  /// **'Plugins'**
  String get pluginsTitle;

  /// Plugin Manager: Installed.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get pluginsInstalled;

  /// Plugin Manager: Discover.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get pluginsDiscover;

  /// Plugin Manager: Activity.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get pluginsActivity;

  /// Plugin Manager: Library.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get pluginsLibrary;

  /// Plugin Manager: Preferences.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get pluginsPreferences;

  /// Plugin Manager: SearchInstalled.
  ///
  /// In en, this message translates to:
  /// **'Search installed'**
  String get pluginsSearchInstalled;

  /// Plugin Manager: Search.
  ///
  /// In en, this message translates to:
  /// **'Search plugins'**
  String get pluginsSearch;

  /// Plugin Manager: ClearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get pluginsClearSearch;

  /// Plugin Manager: AddTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add a plugin from a repository link'**
  String get pluginsAddTooltip;

  /// Plugin Manager: AddToolbar.
  ///
  /// In en, this message translates to:
  /// **'Add Plugin'**
  String get pluginsAddToolbar;

  /// Plugin Manager: MoreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get pluginsMoreActions;

  /// Plugin Manager: Refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get pluginsRefresh;

  /// Plugin Manager: InstalledTitle.
  ///
  /// In en, this message translates to:
  /// **'Installed plugins'**
  String get pluginsInstalledTitle;

  /// Plugin Manager: InstalledDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose the plugins that make up your desktop.'**
  String get pluginsInstalledDescription;

  /// Plugin Manager: NoneInstalled.
  ///
  /// In en, this message translates to:
  /// **'No plugins installed'**
  String get pluginsNoneInstalled;

  /// Plugin Manager: NoneInstalledDescription.
  ///
  /// In en, this message translates to:
  /// **'Discover plugins for your desktop, or add one using a repository link.'**
  String get pluginsNoneInstalledDescription;

  /// Plugin Manager: DiscoverAction.
  ///
  /// In en, this message translates to:
  /// **'Discover Plugins'**
  String get pluginsDiscoverAction;

  /// Plugin Manager: UseDefaults.
  ///
  /// In en, this message translates to:
  /// **'Use Denial defaults'**
  String get pluginsUseDefaults;

  /// Plugin Manager: NoMatches.
  ///
  /// In en, this message translates to:
  /// **'No matching plugins'**
  String get pluginsNoMatches;

  /// Plugin Manager: NoMatchesDescription.
  ///
  /// In en, this message translates to:
  /// **'Try another name or clear your search.'**
  String get pluginsNoMatchesDescription;

  /// Plugin Manager: AutomaticTitle.
  ///
  /// In en, this message translates to:
  /// **'Included automatically'**
  String get pluginsAutomaticTitle;

  /// Plugin Manager: AutomaticDescription.
  ///
  /// In en, this message translates to:
  /// **'These keep your selected plugins working.'**
  String get pluginsAutomaticDescription;

  /// Plugin Manager: DiscoverMore.
  ///
  /// In en, this message translates to:
  /// **'Discover more plugins'**
  String get pluginsDiscoverMore;

  /// Plugin Manager: PreparingDesktop.
  ///
  /// In en, this message translates to:
  /// **'Preparing your desktop'**
  String get pluginsPreparingDesktop;

  /// Plugin Manager: PreparingDescription.
  ///
  /// In en, this message translates to:
  /// **'Denial is getting everything ready. You can leave this window open or come back later.'**
  String get pluginsPreparingDescription;

  /// Plugin Manager: TryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get pluginsTryAgain;

  /// Plugin Manager: FallbackDescription.
  ///
  /// In en, this message translates to:
  /// **'Customize your desktop with this plugin.'**
  String get pluginsFallbackDescription;

  /// Plugin Manager: Selected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get pluginsSelected;

  /// Plugin Manager: NotSelected.
  ///
  /// In en, this message translates to:
  /// **'Not selected'**
  String get pluginsNotSelected;

  /// Plugin Manager: DesktopOptions.
  ///
  /// In en, this message translates to:
  /// **'Desktop options'**
  String get pluginsDesktopOptions;

  /// Plugin Manager: DesktopOptionsDescription.
  ///
  /// In en, this message translates to:
  /// **'Updates, compatibility and recovery'**
  String get pluginsDesktopOptionsDescription;

  /// Plugin Manager: CheckUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for plugin updates'**
  String get pluginsCheckUpdates;

  /// Plugin Manager: CheckCompatibility.
  ///
  /// In en, this message translates to:
  /// **'Check compatibility'**
  String get pluginsCheckCompatibility;

  /// Plugin Manager: Undo.
  ///
  /// In en, this message translates to:
  /// **'Undo last change'**
  String get pluginsUndo;

  /// Plugin Manager: Restore.
  ///
  /// In en, this message translates to:
  /// **'Restore default desktop'**
  String get pluginsRestore;

  /// Plugin Manager: CheckSelection.
  ///
  /// In en, this message translates to:
  /// **'Check your selection'**
  String get pluginsCheckSelection;

  /// Plugin Manager: StartupFailed.
  ///
  /// In en, this message translates to:
  /// **'Saved plugins could not start'**
  String get pluginsStartupFailed;

  /// Plugin Manager: ChangeFailed.
  ///
  /// In en, this message translates to:
  /// **'Change couldn’t be completed'**
  String get pluginsChangeFailed;

  /// Plugin Manager: SelectionChanged.
  ///
  /// In en, this message translates to:
  /// **'Your selection has changed'**
  String get pluginsSelectionChanged;

  /// Plugin Manager: Paused.
  ///
  /// In en, this message translates to:
  /// **'Your plugins are paused'**
  String get pluginsPaused;

  /// Plugin Manager: PendingReady.
  ///
  /// In en, this message translates to:
  /// **'Pending actions are ready'**
  String get pluginsPendingReady;

  /// Plugin Manager: PreparingSupport.
  ///
  /// In en, this message translates to:
  /// **'Preparing plugin support'**
  String get pluginsPreparingSupport;

  /// Plugin Manager: ViewDetails.
  ///
  /// In en, this message translates to:
  /// **'View details'**
  String get pluginsViewDetails;

  /// Plugin Manager: Discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get pluginsDiscard;

  /// Plugin Manager: SwitchNow.
  ///
  /// In en, this message translates to:
  /// **'Switch now'**
  String get pluginsSwitchNow;

  /// Plugin Manager: DismissError.
  ///
  /// In en, this message translates to:
  /// **'Dismiss error'**
  String get pluginsDismissError;

  /// Plugin Manager: InProgress.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get pluginsInProgress;

  /// Plugin Manager: DiscoverTitle.
  ///
  /// In en, this message translates to:
  /// **'Discover plugins'**
  String get pluginsDiscoverTitle;

  /// Plugin Manager: DiscoverDescription.
  ///
  /// In en, this message translates to:
  /// **'Add new features and make your desktop your own.'**
  String get pluginsDiscoverDescription;

  /// Plugin Manager: NothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found yet'**
  String get pluginsNothingFound;

  /// Plugin Manager: NothingFoundDescription.
  ///
  /// In en, this message translates to:
  /// **'Try another search, or add a plugin using its repository link.'**
  String get pluginsNothingFoundDescription;

  /// Plugin Manager: Official.
  ///
  /// In en, this message translates to:
  /// **'Made for Denial'**
  String get pluginsOfficial;

  /// Plugin Manager: Community.
  ///
  /// In en, this message translates to:
  /// **'From the community'**
  String get pluginsCommunity;

  /// Plugin Manager: RefreshDiscoveries.
  ///
  /// In en, this message translates to:
  /// **'Refresh discoveries'**
  String get pluginsRefreshDiscoveries;

  /// Plugin Manager: NoCommunity.
  ///
  /// In en, this message translates to:
  /// **'No community plugins are listed yet. Add a plugin using its repository link.'**
  String get pluginsNoCommunity;

  /// Plugin Manager: AddRepository.
  ///
  /// In en, this message translates to:
  /// **'Add from a repository'**
  String get pluginsAddRepository;

  /// Plugin Manager: AddRepositoryDescription.
  ///
  /// In en, this message translates to:
  /// **'Use a Git link to install a plugin from its developer.'**
  String get pluginsAddRepositoryDescription;

  /// Plugin Manager: AddLink.
  ///
  /// In en, this message translates to:
  /// **'Add from a link'**
  String get pluginsAddLink;

  /// Plugin Manager: DiscoveryFailed.
  ///
  /// In en, this message translates to:
  /// **'Some discoveries couldn’t be loaded. Try refreshing again.'**
  String get pluginsDiscoveryFailed;

  /// Plugin Manager: ByDenial.
  ///
  /// In en, this message translates to:
  /// **'By Denial'**
  String get pluginsByDenial;

  /// Plugin Manager: CommunityPlugin.
  ///
  /// In en, this message translates to:
  /// **'Community plugin'**
  String get pluginsCommunityPlugin;

  /// Plugin Manager: SelectedDesktop.
  ///
  /// In en, this message translates to:
  /// **'Selected for your desktop'**
  String get pluginsSelectedDesktop;

  /// Plugin Manager: Select.
  ///
  /// In en, this message translates to:
  /// **'Select plugin'**
  String get pluginsSelect;

  /// Plugin Manager: RecentActivity.
  ///
  /// In en, this message translates to:
  /// **'Recent activity'**
  String get pluginsRecentActivity;

  /// Plugin Manager: ActivityDescription.
  ///
  /// In en, this message translates to:
  /// **'Installation progress and changes to your desktop.'**
  String get pluginsActivityDescription;

  /// Plugin Manager: NoActivity.
  ///
  /// In en, this message translates to:
  /// **'No activity yet'**
  String get pluginsNoActivity;

  /// Plugin Manager: NoActivityDescription.
  ///
  /// In en, this message translates to:
  /// **'Plugin installations and desktop changes will appear here.'**
  String get pluginsNoActivityDescription;

  /// Plugin Manager: Completed.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get pluginsCompleted;

  /// Plugin Manager: NeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get pluginsNeedsAttention;

  /// Plugin Manager: NoCandidates.
  ///
  /// In en, this message translates to:
  /// **'No plugin package candidates were found in this repository.'**
  String get pluginsNoCandidates;

  /// Plugin Manager: BringNew.
  ///
  /// In en, this message translates to:
  /// **'Bring something new.'**
  String get pluginsBringNew;

  /// Plugin Manager: TrustDescription.
  ///
  /// In en, this message translates to:
  /// **'Paste a repository link to find its plugins. Plugins become part of your desktop, so choose code you trust.'**
  String get pluginsTrustDescription;

  /// Plugin Manager: LocalDirectory.
  ///
  /// In en, this message translates to:
  /// **'Local package or repository directory'**
  String get pluginsLocalDirectory;

  /// Plugin Manager: RepositoryLink.
  ///
  /// In en, this message translates to:
  /// **'Repository link'**
  String get pluginsRepositoryLink;

  /// Plugin Manager: AdvancedOptions.
  ///
  /// In en, this message translates to:
  /// **'Advanced options'**
  String get pluginsAdvancedOptions;

  /// Plugin Manager: GitRef.
  ///
  /// In en, this message translates to:
  /// **'Branch, tag, or commit (optional)'**
  String get pluginsGitRef;

  /// Plugin Manager: LocalDevelopment.
  ///
  /// In en, this message translates to:
  /// **'Local development'**
  String get pluginsLocalDevelopment;

  /// Plugin Manager: UseLocal.
  ///
  /// In en, this message translates to:
  /// **'Use a local development checkout'**
  String get pluginsUseLocal;

  /// Plugin Manager: Choose.
  ///
  /// In en, this message translates to:
  /// **'Choose a plugin'**
  String get pluginsChoose;

  /// Plugin Manager: IncludeDependencies.
  ///
  /// In en, this message translates to:
  /// **'We’ll include anything this plugin needs automatically.'**
  String get pluginsIncludeDependencies;

  /// Plugin Manager: Finding.
  ///
  /// In en, this message translates to:
  /// **'Finding plugins…'**
  String get pluginsFinding;

  /// Plugin Manager: Find.
  ///
  /// In en, this message translates to:
  /// **'Find plugins'**
  String get pluginsFind;

  /// Plugin Manager: Add.
  ///
  /// In en, this message translates to:
  /// **'Add plugin'**
  String get pluginsAdd;

  /// Plugin Manager: YourPlugins.
  ///
  /// In en, this message translates to:
  /// **'Your plugins'**
  String get pluginsYourPlugins;

  /// Plugin Manager: LogLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The build log could not be loaded.'**
  String get pluginsLogLoadFailed;

  /// Plugin Manager: TechnicalDetails.
  ///
  /// In en, this message translates to:
  /// **'Technical details'**
  String get pluginsTechnicalDetails;

  /// Plugin Manager: BuildLog.
  ///
  /// In en, this message translates to:
  /// **'Build log'**
  String get pluginsBuildLog;

  /// Plugin Manager: NoBuildOutput.
  ///
  /// In en, this message translates to:
  /// **'No build output was recorded.'**
  String get pluginsNoBuildOutput;

  /// Plugin Manager: Close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get pluginsClose;

  /// Plugin Manager: Done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get pluginsDone;

  /// Plugin Manager: Apply.
  ///
  /// In en, this message translates to:
  /// **'Apply plugins'**
  String get pluginsApply;

  /// Plugin Manager: Build.
  ///
  /// In en, this message translates to:
  /// **'Build plugins'**
  String get pluginsBuild;

  /// Plugin Manager: CheckChanges.
  ///
  /// In en, this message translates to:
  /// **'Check your changes'**
  String get pluginsCheckChanges;

  /// Plugin Manager: Enable.
  ///
  /// In en, this message translates to:
  /// **'Enable plugin'**
  String get pluginsEnable;

  /// Plugin Manager: Disable.
  ///
  /// In en, this message translates to:
  /// **'Disable plugin'**
  String get pluginsDisable;

  /// Plugin Manager: Update.
  ///
  /// In en, this message translates to:
  /// **'Update plugins'**
  String get pluginsUpdate;

  /// Plugin Manager: Rebuild.
  ///
  /// In en, this message translates to:
  /// **'Rebuild plugins'**
  String get pluginsRebuild;

  /// Plugin Manager: Setup.
  ///
  /// In en, this message translates to:
  /// **'Set up plugins'**
  String get pluginsSetup;

  /// Plugin Manager: ChooseDefaults.
  ///
  /// In en, this message translates to:
  /// **'Choose default plugins'**
  String get pluginsChooseDefaults;

  /// Plugin Manager: ActivityFallback.
  ///
  /// In en, this message translates to:
  /// **'Plugin activity'**
  String get pluginsActivityFallback;

  /// Plugin Manager: Working.
  ///
  /// In en, this message translates to:
  /// **'Working on your changes'**
  String get pluginsWorking;

  /// Plugin Manager: ApplyChanges.
  ///
  /// In en, this message translates to:
  /// **'Apply changes'**
  String get pluginsApplyChanges;

  /// Plugin Manager: ApplyPending.
  ///
  /// In en, this message translates to:
  /// **'Apply pending actions'**
  String get pluginsApplyPending;

  /// Plugin Manager: ApplySelectionUpdates.
  ///
  /// In en, this message translates to:
  /// **'Apply your selection changes and pending updates to your desktop.'**
  String get pluginsApplySelectionUpdates;

  /// Plugin Manager: ApplySelection.
  ///
  /// In en, this message translates to:
  /// **'Apply your plugin selection changes to your desktop.'**
  String get pluginsApplySelection;

  /// Plugin Manager: ApplyUnchanged.
  ///
  /// In en, this message translates to:
  /// **'Your switches are unchanged. Pending plugin updates need to be applied to your desktop.'**
  String get pluginsApplyUnchanged;

  /// Plugin Manager: StaleSelection.
  ///
  /// In en, this message translates to:
  /// **'The selection changed elsewhere. Discard your draft to load the latest selection.'**
  String get pluginsStaleSelection;

  /// Plugin Manager: Updated.
  ///
  /// In en, this message translates to:
  /// **'Denial was updated.'**
  String get pluginsUpdated;

  /// Plugin Manager: FailureEngine.
  ///
  /// In en, this message translates to:
  /// **'Your applied plugins are saved, but this session uses a different Flutter engine. Use a Denial session with the matching engine to load them again.'**
  String get pluginsFailureEngine;

  /// Plugin Manager: FailureVersion.
  ///
  /// In en, this message translates to:
  /// **'Your saved plugins were built for another Denial version. Rebuild them with the matching installed build tools.'**
  String get pluginsFailureVersion;

  /// Plugin Manager: FailurePanel.
  ///
  /// In en, this message translates to:
  /// **'More than one desktop panel is selected. Keep one enabled, then apply again.'**
  String get pluginsFailurePanel;

  /// Plugin Manager: FailureConflict.
  ///
  /// In en, this message translates to:
  /// **'Multiple plugins provide the same feature. Choose one, then apply again. Details identify the conflicting plugins.'**
  String get pluginsFailureConflict;

  /// Plugin Manager: FailureMissing.
  ///
  /// In en, this message translates to:
  /// **'A required desktop feature is missing. Enable a plugin that provides it, then apply again.'**
  String get pluginsFailureMissing;

  /// Plugin Manager: FailureLogin.
  ///
  /// In en, this message translates to:
  /// **'Log out and back into Denial once to finish the update. Your choices are saved.'**
  String get pluginsFailureLogin;

  /// Plugin Manager: FailureWorker.
  ///
  /// In en, this message translates to:
  /// **'The background operation stopped unexpectedly. Check Activity before trying again.'**
  String get pluginsFailureWorker;

  /// Plugin Manager: FailureDownload.
  ///
  /// In en, this message translates to:
  /// **'A download failed. Check your connection and try again.'**
  String get pluginsFailureDownload;

  /// Plugin Manager: FailureGeneric.
  ///
  /// In en, this message translates to:
  /// **'This change could not be completed. Open details to see the cause.'**
  String get pluginsFailureGeneric;

  /// Plugin Manager: ToolsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Plugin tools are temporarily unavailable. Retrying automatically.'**
  String get pluginsToolsUnavailable;

  /// Plugin Manager: DartCompatible.
  ///
  /// In en, this message translates to:
  /// **'Compatible Dart is required'**
  String get pluginsDartCompatible;

  /// Plugin Manager: DartRequired.
  ///
  /// In en, this message translates to:
  /// **'Dart is required'**
  String get pluginsDartRequired;

  /// Plugin Manager: ToolsAttention.
  ///
  /// In en, this message translates to:
  /// **'Plugin tools need attention'**
  String get pluginsToolsAttention;

  /// Plugin Manager: SetupFailed.
  ///
  /// In en, this message translates to:
  /// **'Preparation could not finish. See Activity for details, then try again.'**
  String get pluginsSetupFailed;

  /// Plugin Manager: WaitingStart.
  ///
  /// In en, this message translates to:
  /// **'Waiting to start'**
  String get pluginsWaitingStart;

  /// Plugin Manager: CloseWhileWorking.
  ///
  /// In en, this message translates to:
  /// **'You can close this window. We’ll keep going.'**
  String get pluginsCloseWhileWorking;

  /// Plugin Manager: PreparingPlugins.
  ///
  /// In en, this message translates to:
  /// **'Preparing your plugins'**
  String get pluginsPreparingPlugins;

  /// Plugin Manager: CheckingCompatibility.
  ///
  /// In en, this message translates to:
  /// **'Checking plugin compatibility'**
  String get pluginsCheckingCompatibility;

  /// Plugin Manager: PreparingBuild.
  ///
  /// In en, this message translates to:
  /// **'Preparing your desktop build'**
  String get pluginsPreparingBuild;

  /// Plugin Manager: CompilingSources.
  ///
  /// In en, this message translates to:
  /// **'Compiling Dart sources'**
  String get pluginsCompilingSources;

  /// Plugin Manager: Optimizing.
  ///
  /// In en, this message translates to:
  /// **'Optimizing and generating native code'**
  String get pluginsOptimizing;

  /// Plugin Manager: PreparingAssets.
  ///
  /// In en, this message translates to:
  /// **'Preparing assets'**
  String get pluginsPreparingAssets;

  /// Plugin Manager: LoadingDesktop.
  ///
  /// In en, this message translates to:
  /// **'Loading your saved desktop'**
  String get pluginsLoadingDesktop;

  /// Plugin Manager: CompilingDesktop.
  ///
  /// In en, this message translates to:
  /// **'Compiling your desktop'**
  String get pluginsCompilingDesktop;

  /// Plugin Manager: VerifyingDesktop.
  ///
  /// In en, this message translates to:
  /// **'Verifying your desktop'**
  String get pluginsVerifyingDesktop;

  /// Plugin Manager: SwitchingPause.
  ///
  /// In en, this message translates to:
  /// **'Switching when you pause'**
  String get pluginsSwitchingPause;

  /// Plugin Manager: ApplyingDesktop.
  ///
  /// In en, this message translates to:
  /// **'Applying and checking your desktop'**
  String get pluginsApplyingDesktop;

  /// Plugin Manager: VerifyingTools.
  ///
  /// In en, this message translates to:
  /// **'Verifying plugin tools'**
  String get pluginsVerifyingTools;

  /// Plugin Manager: PreparingTools.
  ///
  /// In en, this message translates to:
  /// **'Preparing plugin tools'**
  String get pluginsPreparingTools;

  /// Plugin Manager: ConfigurationDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose plugins from your library, then apply your changes together. Denial takes care of preparing everything your desktop needs.\n\nYou can also add plugins using a repository link. Previous working desktops remain available in the desktop menu.'**
  String get pluginsConfigurationDescription;

  /// Plugin Manager: SelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{0 selected} =1{1 selected} other{{count} selected}}'**
  String pluginsSelectedCount(int count);

  /// Plugin Manager: SwitchSemantics.
  ///
  /// In en, this message translates to:
  /// **'{name} plugin'**
  String pluginsSwitchSemantics(String name);

  /// Plugin Manager: CandidateLabel.
  ///
  /// In en, this message translates to:
  /// **'{name} · {path}'**
  String pluginsCandidateLabel(String name, String path);

  /// Plugin Manager: StepsComplete.
  ///
  /// In en, this message translates to:
  /// **'{completed} of {total} steps complete'**
  String pluginsStepsComplete(int completed, int total);

  /// Plugin Manager: Step.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of {total} · {label}'**
  String pluginsStep(int step, int total, String label);

  /// Plugin Manager: Elapsed.
  ///
  /// In en, this message translates to:
  /// **'{stage} · {clock} elapsed'**
  String pluginsElapsed(String stage, String clock);

  /// Plugin Manager: InstalledVersion.
  ///
  /// In en, this message translates to:
  /// **'Denial {version} is installed.'**
  String pluginsInstalledVersion(String version);

  /// Plugin Manager: RebuildDescription.
  ///
  /// In en, this message translates to:
  /// **'{introduction} Rebuild your plugins to bring them back, with all their settings. No need to log out.'**
  String pluginsRebuildDescription(String introduction);

  /// Plugin Manager: DartIncompatible.
  ///
  /// In en, this message translates to:
  /// **'Dart {installed} is installed, but Denial requires {constraint}. Install a compatible Dart package and make sure dart is available in PATH, then try again.'**
  String pluginsDartIncompatible(String installed, String constraint);

  /// Plugin Manager: DartInstall.
  ///
  /// In en, this message translates to:
  /// **'Install Dart with your system package manager. Denial recommends Dart {expected}. Make sure dart is available in PATH, then try again.'**
  String pluginsDartInstall(String expected);

  /// Plugin Manager: ProviderConflict.
  ///
  /// In en, this message translates to:
  /// **'{feature} is provided by {plugins}. {owner} accepts at most {maximum} providers. Disable extra plugins before applying.'**
  String pluginsProviderConflict(
    String feature,
    String plugins,
    String owner,
    int maximum,
  );

  /// Plugin Manager: ProviderMissing.
  ///
  /// In en, this message translates to:
  /// **'{owner} needs at least {minimum} providers for {feature}. Enable a compatible plugin before applying.'**
  String pluginsProviderMissing(String owner, int minimum, String feature);

  /// Plugin Manager: InvalidDeclaration.
  ///
  /// In en, this message translates to:
  /// **'{plugins} has invalid compatibility declarations. Open details to see the cause.'**
  String pluginsInvalidDeclaration(String plugins);

  /// Plugin Manager compatibility declaration or preflight failure summary.
  ///
  /// In en, this message translates to:
  /// **'Plugin compatibility information needs attention. Check your selection and open details before applying again.'**
  String get pluginsFailureDeclaration;

  /// Plugin Manager: DesktopFeature.
  ///
  /// In en, this message translates to:
  /// **'Desktop'**
  String get pluginsDesktopFeature;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
