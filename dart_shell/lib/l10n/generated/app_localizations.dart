import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

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
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Display name of the built-in Denial Settings application.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsApplicationTitle;

  /// Search category for system-level settings.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsApplicationCategorySystem;

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

  /// Accessibility label for the complete Settings application.
  ///
  /// In en, this message translates to:
  /// **'Denial Settings'**
  String get settingsApplicationSemanticsLabel;

  /// Compact product and section context shown in the Settings header.
  ///
  /// In en, this message translates to:
  /// **'DENIAL / SYSTEM'**
  String get settingsHeaderContext;

  /// Uppercase label for the appearance settings section.
  ///
  /// In en, this message translates to:
  /// **'APPEARANCE'**
  String get settingsAppearanceSection;

  /// Heading introducing personalization controls.
  ///
  /// In en, this message translates to:
  /// **'Make the desktop feel like yours.'**
  String get settingsAppearanceTitle;

  /// Explanation that shell appearance changes are applied immediately.
  ///
  /// In en, this message translates to:
  /// **'Changes made here are reflected across the desktop in real time.'**
  String get settingsAppearanceDescription;

  /// Accessibility label for the live-change status badge.
  ///
  /// In en, this message translates to:
  /// **'Changes are applied in real time'**
  String get settingsLiveChangesSemanticsLabel;

  /// Short uppercase status label indicating immediate application.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get settingsLiveBadge;

  /// Title of the focused-window border color setting.
  ///
  /// In en, this message translates to:
  /// **'Focused window border'**
  String get settingsFocusedBorderTitle;

  /// Explanation of the focused-window border color.
  ///
  /// In en, this message translates to:
  /// **'Choose the accent that identifies the window currently receiving your input.'**
  String get settingsFocusedBorderDescription;

  /// Accessibility label for the focused-window border preview.
  ///
  /// In en, this message translates to:
  /// **'Preview of the focused window border'**
  String get settingsFocusedBorderPreviewSemanticsLabel;

  /// Accessibility label for the button that opens the border color picker.
  ///
  /// In en, this message translates to:
  /// **'Change the focused window border color'**
  String get settingsFocusedBorderChangeSemanticsLabel;

  /// Title of the system bar placement setting.
  ///
  /// In en, this message translates to:
  /// **'Desktop system bar'**
  String get settingsSystemBarTitle;

  /// Explanation of system bar edge and multi-display behavior.
  ///
  /// In en, this message translates to:
  /// **'Place the bar on any edge and show an independent copy on every selected display.'**
  String get settingsSystemBarDescription;

  /// Uppercase label above the system bar edge choices.
  ///
  /// In en, this message translates to:
  /// **'EDGE'**
  String get settingsSystemBarEdgeLabel;

  /// Label for placing the system bar at the top edge.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get settingsSystemBarEdgeTop;

  /// Label for placing the system bar at the bottom edge.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get settingsSystemBarEdgeBottom;

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

  /// Uppercase label above the system bar display choices.
  ///
  /// In en, this message translates to:
  /// **'DISPLAYS'**
  String get settingsSystemBarDisplaysLabel;

  /// Clarifies that multiple bars are cloned rather than stretched.
  ///
  /// In en, this message translates to:
  /// **'Each selected display gets its own bar. The bar never spans displays.'**
  String get settingsSystemBarCloneHint;

  /// Count of displays selected to show a system bar.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 display selected} other{{count} displays selected}}'**
  String settingsSystemBarDisplaysSelected(int count);

  /// Badge identifying the compositor's main display.
  ///
  /// In en, this message translates to:
  /// **'MAIN'**
  String get settingsSystemBarMainDisplay;

  /// Resolution and scale shown for one display.
  ///
  /// In en, this message translates to:
  /// **'{width} × {height} · {scale}×'**
  String settingsSystemBarDisplayDetails(int width, int height, String scale);

  /// Accessibility value for a selected system bar display.
  ///
  /// In en, this message translates to:
  /// **'System bar shown on {displayName}'**
  String settingsSystemBarDisplaySelectedSemantics(String displayName);

  /// Accessibility value for an unselected system bar display.
  ///
  /// In en, this message translates to:
  /// **'System bar not shown on {displayName}'**
  String settingsSystemBarDisplayNotSelectedSemantics(String displayName);

  /// Accessibility hint explaining why the last selected display cannot be removed.
  ///
  /// In en, this message translates to:
  /// **'Select another display before removing this one.'**
  String get settingsSystemBarLastDisplayHint;

  /// Message shown while display topology is unavailable.
  ///
  /// In en, this message translates to:
  /// **'Display information is not available yet.'**
  String get settingsSystemBarUnavailable;

  /// Accessibility route name for the focused-window border color picker.
  ///
  /// In en, this message translates to:
  /// **'Focused window border color picker'**
  String get settingsColorPickerRouteLabel;

  /// Title displayed in the border color picker.
  ///
  /// In en, this message translates to:
  /// **'Border color'**
  String get settingsColorPickerTitle;

  /// Pointer and keyboard instructions displayed below the color wheel.
  ///
  /// In en, this message translates to:
  /// **'Drag to choose a color. Use the arrow keys for fine adjustments.'**
  String get settingsColorPickerInstructions;

  /// Button label that restores the default border color.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get settingsColorPickerReset;

  /// Button label that closes the color picker.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get settingsColorPickerDone;

  /// Accessibility label for the icon button that closes the color picker.
  ///
  /// In en, this message translates to:
  /// **'Close color picker'**
  String get settingsColorPickerCloseSemanticsLabel;

  /// Accessibility label for the HSV border color wheel.
  ///
  /// In en, this message translates to:
  /// **'Focused window border color'**
  String get settingsColorWheelSemanticsLabel;

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
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
