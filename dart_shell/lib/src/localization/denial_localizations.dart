import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/denial_window.dart';
import '../models/shell_power_status.dart';

/// Installs Denial's generated localizations without introducing a
/// [WidgetsApp] or [MaterialApp] above the compositor scene.
///
/// The platform locale is resolved against the generated locale catalog and
/// observed for changes. Unsupported locales fall back through Flutter's
/// standard locale resolution, which currently selects English.
class DenialLocalizationScope extends StatefulWidget {
  const DenialLocalizationScope({required this.child, this.locale, super.key});

  final Widget child;

  /// An explicit locale for tests or a persisted user preference. When
  /// omitted, the scope follows the platform's ordered locale list.
  final Locale? locale;

  @override
  State<DenialLocalizationScope> createState() =>
      _DenialLocalizationScopeState();
}

class _DenialLocalizationScopeState extends State<DenialLocalizationScope>
    with WidgetsBindingObserver {
  late Locale _effectiveLocale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _effectiveLocale = _resolveLocale();
  }

  @override
  void didUpdateWidget(covariant DenialLocalizationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locale != widget.locale) {
      _updateLocale();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (widget.locale == null) {
      _updateLocale(locales);
    }
  }

  Locale _resolveLocale([List<Locale>? platformLocales]) {
    final explicitLocale = widget.locale;
    if (explicitLocale != null) {
      return basicLocaleListResolution(<Locale>[
        explicitLocale,
      ], AppLocalizations.supportedLocales);
    }
    return basicLocaleListResolution(
      platformLocales ?? WidgetsBinding.instance.platformDispatcher.locales,
      AppLocalizations.supportedLocales,
    );
  }

  void _updateLocale([List<Locale>? platformLocales]) {
    final nextLocale = _resolveLocale(platformLocales);
    if (nextLocale != _effectiveLocale) {
      setState(() => _effectiveLocale = nextLocale);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Localizations(
      locale: _effectiveLocale,
      delegates: AppLocalizations.localizationsDelegates,
      child: Builder(
        builder: (context) => Directionality(
          textDirection: WidgetsLocalizations.of(context).textDirection,
          child: widget.child,
        ),
      ),
    );
  }
}

extension DenialLocalizationsBuildContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

String localizedWindowTitle(BuildContext context, DenialWindow window) {
  final title = window.title.trim();
  if (title.isNotEmpty) {
    return title;
  }
  final appId = window.appId.trim();
  return appId.isNotEmpty
      ? appId
      : context.l10n.windowUntitled(window.windowId);
}

String localizedLongDate(BuildContext context, DateTime value) {
  final l10n = context.l10n;
  return l10n.longDate(
    localizedWeekday(l10n, value.weekday),
    value.day,
    localizedMonth(l10n, value.month),
  );
}

String localizedTime(BuildContext context, DateTime value) {
  return context.l10n.timeHoursMinutes(
    value.hour.toString().padLeft(2, '0'),
    value.minute.toString().padLeft(2, '0'),
  );
}

String localizedShortDate(BuildContext context, DateTime value) {
  final l10n = context.l10n;
  final weekday = localizedWeekday(l10n, value.weekday);
  final month = localizedMonth(l10n, value.month);
  return l10n.shortDate(
    _abbreviateDateName(weekday),
    value.day,
    _abbreviateDateName(month),
  );
}

String _abbreviateDateName(String value) =>
    value.length <= 3 ? value : value.substring(0, 3);

String localizedWeekday(AppLocalizations l10n, int weekday) =>
    switch (weekday) {
      DateTime.monday => l10n.weekdayMonday,
      DateTime.tuesday => l10n.weekdayTuesday,
      DateTime.wednesday => l10n.weekdayWednesday,
      DateTime.thursday => l10n.weekdayThursday,
      DateTime.friday => l10n.weekdayFriday,
      DateTime.saturday => l10n.weekdaySaturday,
      DateTime.sunday => l10n.weekdaySunday,
      _ => l10n.weekdayMonday,
    };

String localizedMonth(AppLocalizations l10n, int month) => switch (month) {
  DateTime.january => l10n.monthJanuary,
  DateTime.february => l10n.monthFebruary,
  DateTime.march => l10n.monthMarch,
  DateTime.april => l10n.monthApril,
  DateTime.may => l10n.monthMay,
  DateTime.june => l10n.monthJune,
  DateTime.july => l10n.monthJuly,
  DateTime.august => l10n.monthAugust,
  DateTime.september => l10n.monthSeptember,
  DateTime.october => l10n.monthOctober,
  DateTime.november => l10n.monthNovember,
  DateTime.december => l10n.monthDecember,
  _ => l10n.monthJanuary,
};

String localizedBatteryState(
  AppLocalizations l10n,
  String state, {
  bool showUnknown = false,
}) => switch (state) {
  'charging' => l10n.batteryCharging,
  'discharging' => l10n.batteryDischarging,
  'idle' => l10n.batteryIdle,
  _ => showUnknown ? l10n.statusUnknown : '',
};

String localizedBatteryLine(
  AppLocalizations l10n,
  String state,
  int? capacity,
) {
  if (capacity == null) {
    return '';
  }
  final stateLabel = localizedBatteryState(l10n, state);
  return stateLabel.isEmpty
      ? l10n.percentCompact(capacity)
      : l10n.batteryStateAndPercent(stateLabel, capacity);
}

String localizedChargeProtocol(
  AppLocalizations l10n,
  ShellChargeProtocol protocol,
) => switch (protocol) {
  ShellChargeProtocol.vooc => l10n.chargeProtocolVooc,
  ShellChargeProtocol.pps => l10n.chargeProtocolPps,
  ShellChargeProtocol.powerDelivery => l10n.chargeProtocolPowerDelivery,
  ShellChargeProtocol.fast => l10n.chargeProtocolFast,
};

String localizedThermalSensor(
  AppLocalizations l10n,
  ShellThermalSensor sensor,
) => switch (sensor) {
  ShellThermalSensor.cpu => l10n.thermalSensorCpu,
  ShellThermalSensor.svooc => l10n.thermalSensorSvooc,
  ShellThermalSensor.pmic => l10n.thermalSensorPmic,
  ShellThermalSensor.exp2 => l10n.thermalSensorExp2,
};
