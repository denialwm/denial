// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsApplicationTitle => 'Settings';

  @override
  String get settingsApplicationCategorySystem => 'System';

  @override
  String get settingsApplicationCategoryAppearance => 'Appearance';

  @override
  String get settingsApplicationCategoryPreferences => 'Preferences';

  @override
  String get settingsApplicationSemanticsLabel => 'Denial Settings';

  @override
  String get settingsHeaderContext => 'DENIAL / SYSTEM';

  @override
  String get settingsAppearanceSection => 'APPEARANCE';

  @override
  String get settingsAppearanceTitle => 'Make the desktop feel like yours.';

  @override
  String get settingsAppearanceDescription =>
      'Changes made here are reflected across the desktop in real time.';

  @override
  String get settingsLiveChangesSemanticsLabel =>
      'Changes are applied in real time';

  @override
  String get settingsLiveBadge => 'LIVE';

  @override
  String get settingsFocusedBorderTitle => 'Focused window border';

  @override
  String get settingsFocusedBorderDescription =>
      'Choose the accent that identifies the window currently receiving your input.';

  @override
  String get settingsFocusedBorderPreviewSemanticsLabel =>
      'Preview of the focused window border';

  @override
  String get settingsFocusedBorderChangeSemanticsLabel =>
      'Change the focused window border color';

  @override
  String get settingsSystemBarTitle => 'Desktop system bar';

  @override
  String get settingsSystemBarDescription =>
      'Place the bar on any edge and show an independent copy on every selected display.';

  @override
  String get settingsSystemBarEdgeLabel => 'EDGE';

  @override
  String get settingsSystemBarEdgeTop => 'Top';

  @override
  String get settingsSystemBarEdgeBottom => 'Bottom';

  @override
  String get settingsSystemBarEdgeLeft => 'Left';

  @override
  String get settingsSystemBarEdgeRight => 'Right';

  @override
  String get settingsSystemBarDisplaysLabel => 'DISPLAYS';

  @override
  String get settingsSystemBarCloneHint =>
      'Each selected display gets its own bar. The bar never spans displays.';

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
  String get settingsSystemBarMainDisplay => 'MAIN';

  @override
  String settingsSystemBarDisplayDetails(int width, int height, String scale) {
    return '$width × $height · $scale×';
  }

  @override
  String settingsSystemBarDisplaySelectedSemantics(String displayName) {
    return 'System bar shown on $displayName';
  }

  @override
  String settingsSystemBarDisplayNotSelectedSemantics(String displayName) {
    return 'System bar not shown on $displayName';
  }

  @override
  String get settingsSystemBarLastDisplayHint =>
      'Select another display before removing this one.';

  @override
  String get settingsSystemBarUnavailable =>
      'Display information is not available yet.';

  @override
  String get settingsColorPickerRouteLabel =>
      'Focused window border color picker';

  @override
  String get settingsColorPickerTitle => 'Border color';

  @override
  String get settingsColorPickerInstructions =>
      'Drag to choose a color. Use the arrow keys for fine adjustments.';

  @override
  String get settingsColorPickerReset => 'Reset';

  @override
  String get settingsColorPickerDone => 'Done';

  @override
  String get settingsColorPickerCloseSemanticsLabel => 'Close color picker';

  @override
  String get settingsColorWheelSemanticsLabel => 'Focused window border color';

  @override
  String get settingsColorWheelNextHue => 'Next hue';

  @override
  String get settingsColorWheelPreviousHue => 'Previous hue';
}
