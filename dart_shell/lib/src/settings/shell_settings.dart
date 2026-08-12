import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/display_layout.dart';
import '../models/shell_popup_placement.dart';
import '../state/desktop_window_close_effect.dart';
import '../theme/cursor_themes.dart';
import '../theme/tokens.dart';

enum ShellAccentSource { wallpaper, custom }

enum ShellOverlaySurface { launcher, dashboard, notifications, systemHud }

enum ClipboardTrayEdge { left, right, top, bottom }

const double clipboardTrayMinimumExtent = 100;
const double clipboardTrayMaximumExtent = 300;
const double clipboardTrayDefaultExtent = 250;

enum ShellLocalePreference { system, english, simplifiedChinese }

@immutable
class ShellLocalizationSettings {
  const ShellLocalizationSettings({this.locale = ShellLocalePreference.system});

  final ShellLocalePreference locale;

  Locale? get localeOverride => switch (locale) {
    ShellLocalePreference.system => null,
    ShellLocalePreference.english => const Locale('en'),
    ShellLocalePreference.simplifiedChinese => const Locale('zh'),
  };

  ShellLocalizationSettings copyWith({ShellLocalePreference? locale}) {
    return ShellLocalizationSettings(locale: locale ?? this.locale);
  }

  @override
  bool operator ==(Object other) {
    return other is ShellLocalizationSettings && other.locale == locale;
  }

  @override
  int get hashCode => locale.hashCode;
}

@immutable
class ShellAppearanceSettings {
  const ShellAppearanceSettings({
    this.accentSource = ShellAccentSource.wallpaper,
    this.customAccentColor = ShellColors.accent,
    this.windowRadius = ShellRadii.window,
    this.panelRadius = ShellRadii.panel,
    this.panelOpacity = ShellOpacity.panel,
    this.backdropBlurEnabled = true,
    this.backdropBlurSigma = 18,
    this.backdropBlurOpacityThreshold = 0.05,
    this.focusedWindowOpacity = 1,
    this.unfocusedWindowOpacity = 1,
    this.cursorSize = shellCursorDefaultSize,
  });

  final ShellAccentSource accentSource;
  final Color customAccentColor;
  final double windowRadius;
  final double panelRadius;
  final double panelOpacity;
  final bool backdropBlurEnabled;
  final double backdropBlurSigma;
  final double backdropBlurOpacityThreshold;
  final double focusedWindowOpacity;
  final double unfocusedWindowOpacity;
  final double cursorSize;

  ShellAppearanceSettings copyWith({
    ShellAccentSource? accentSource,
    Color? customAccentColor,
    double? windowRadius,
    double? panelRadius,
    double? panelOpacity,
    bool? backdropBlurEnabled,
    double? backdropBlurSigma,
    double? backdropBlurOpacityThreshold,
    double? focusedWindowOpacity,
    double? unfocusedWindowOpacity,
    double? cursorSize,
  }) {
    return ShellAppearanceSettings(
      accentSource: accentSource ?? this.accentSource,
      customAccentColor: customAccentColor ?? this.customAccentColor,
      windowRadius: windowRadius ?? this.windowRadius,
      panelRadius: panelRadius ?? this.panelRadius,
      panelOpacity: panelOpacity ?? this.panelOpacity,
      backdropBlurEnabled: backdropBlurEnabled ?? this.backdropBlurEnabled,
      backdropBlurSigma: backdropBlurSigma ?? this.backdropBlurSigma,
      backdropBlurOpacityThreshold:
          backdropBlurOpacityThreshold ?? this.backdropBlurOpacityThreshold,
      focusedWindowOpacity: focusedWindowOpacity ?? this.focusedWindowOpacity,
      unfocusedWindowOpacity:
          unfocusedWindowOpacity ?? this.unfocusedWindowOpacity,
      cursorSize: cursorSize ?? this.cursorSize,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellAppearanceSettings &&
        other.accentSource == accentSource &&
        other.customAccentColor == customAccentColor &&
        other.windowRadius == windowRadius &&
        other.panelRadius == panelRadius &&
        other.panelOpacity == panelOpacity &&
        other.backdropBlurEnabled == backdropBlurEnabled &&
        other.backdropBlurSigma == backdropBlurSigma &&
        other.backdropBlurOpacityThreshold == backdropBlurOpacityThreshold &&
        other.focusedWindowOpacity == focusedWindowOpacity &&
        other.unfocusedWindowOpacity == unfocusedWindowOpacity &&
        other.cursorSize == cursorSize;
  }

  @override
  int get hashCode => Object.hash(
    accentSource,
    customAccentColor,
    windowRadius,
    panelRadius,
    panelOpacity,
    backdropBlurEnabled,
    backdropBlurSigma,
    backdropBlurOpacityThreshold,
    focusedWindowOpacity,
    unfocusedWindowOpacity,
    cursorSize,
  );
}

@immutable
class ShellAnimationSettings {
  const ShellAnimationSettings({
    this.windowCloseEffect = DesktopWindowCloseEffect.explosion,
    this.durationScale = 1,
    this.panelTravel = 32,
    this.animateLockScreen = true,
  });

  final DesktopWindowCloseEffect windowCloseEffect;
  final double durationScale;
  final double panelTravel;
  final bool animateLockScreen;

  ShellAnimationSettings copyWith({
    DesktopWindowCloseEffect? windowCloseEffect,
    double? durationScale,
    double? panelTravel,
    bool? animateLockScreen,
  }) {
    return ShellAnimationSettings(
      windowCloseEffect: windowCloseEffect ?? this.windowCloseEffect,
      durationScale: durationScale ?? this.durationScale,
      panelTravel: panelTravel ?? this.panelTravel,
      animateLockScreen: animateLockScreen ?? this.animateLockScreen,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellAnimationSettings &&
        other.windowCloseEffect == windowCloseEffect &&
        other.durationScale == durationScale &&
        other.panelTravel == panelTravel &&
        other.animateLockScreen == animateLockScreen;
  }

  @override
  int get hashCode => Object.hash(
    windowCloseEffect,
    durationScale,
    panelTravel,
    animateLockScreen,
  );
}

@immutable
class ShellLayoutSettings {
  const ShellLayoutSettings({
    this.systemBarSide,
    this.systemBarOutputNames = const <String>[],
    this.systemBarThickness = 32,
    this.maximizePadding = 10,
    this.clipboardTrayEdge = ClipboardTrayEdge.right,
    this.clipboardTrayExtent = clipboardTrayDefaultExtent,
  });

  final SystemBarSide? systemBarSide;
  final List<String> systemBarOutputNames;
  final double systemBarThickness;
  final double maximizePadding;
  final ClipboardTrayEdge clipboardTrayEdge;
  final double clipboardTrayExtent;

  ShellLayoutSettings copyWith({
    SystemBarSide? systemBarSide,
    bool clearSystemBarSide = false,
    List<String>? systemBarOutputNames,
    double? systemBarThickness,
    double? maximizePadding,
    ClipboardTrayEdge? clipboardTrayEdge,
    double? clipboardTrayExtent,
  }) {
    return ShellLayoutSettings(
      systemBarSide: clearSystemBarSide
          ? null
          : systemBarSide ?? this.systemBarSide,
      systemBarOutputNames: List<String>.unmodifiable(
        systemBarOutputNames ?? this.systemBarOutputNames,
      ),
      systemBarThickness: systemBarThickness ?? this.systemBarThickness,
      maximizePadding: maximizePadding ?? this.maximizePadding,
      clipboardTrayEdge: clipboardTrayEdge ?? this.clipboardTrayEdge,
      clipboardTrayExtent: clipboardTrayExtent ?? this.clipboardTrayExtent,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellLayoutSettings &&
        other.systemBarSide == systemBarSide &&
        listEquals(other.systemBarOutputNames, systemBarOutputNames) &&
        other.systemBarThickness == systemBarThickness &&
        other.maximizePadding == maximizePadding &&
        other.clipboardTrayEdge == clipboardTrayEdge &&
        other.clipboardTrayExtent == clipboardTrayExtent;
  }

  @override
  int get hashCode => Object.hash(
    systemBarSide,
    Object.hashAll(systemBarOutputNames),
    systemBarThickness,
    maximizePadding,
    clipboardTrayEdge,
    clipboardTrayExtent,
  );
}

@immutable
class ShellOverlaySettings {
  const ShellOverlaySettings({
    this.launcher = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.topLeft,
      width: 680,
      height: 620,
      margin: 14,
    ),
    this.dashboard = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomLeft,
      width: 470,
      height: 620,
      margin: 14,
    ),
    this.notifications = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.topLeft,
      width: 410,
      height: 640,
      margin: 16,
    ),
    this.systemHud = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomCenter,
      width: 380,
      height: 74,
      margin: 28,
    ),
  });

  final ShellPopupPlacement launcher;
  final ShellPopupPlacement dashboard;
  final ShellPopupPlacement notifications;
  final ShellPopupPlacement systemHud;

  ShellPopupPlacement placementFor(ShellOverlaySurface surface) {
    return switch (surface) {
      ShellOverlaySurface.launcher => launcher,
      ShellOverlaySurface.dashboard => dashboard,
      ShellOverlaySurface.notifications => notifications,
      ShellOverlaySurface.systemHud => systemHud,
    };
  }

  ShellOverlaySettings withPlacement(
    ShellOverlaySurface surface,
    ShellPopupPlacement placement,
  ) {
    return ShellOverlaySettings(
      launcher: surface == ShellOverlaySurface.launcher ? placement : launcher,
      dashboard: surface == ShellOverlaySurface.dashboard
          ? placement
          : dashboard,
      notifications: surface == ShellOverlaySurface.notifications
          ? placement
          : notifications,
      systemHud: surface == ShellOverlaySurface.systemHud
          ? placement
          : systemHud,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellOverlaySettings &&
        other.launcher == launcher &&
        other.dashboard == dashboard &&
        other.notifications == notifications &&
        other.systemHud == systemHud;
  }

  @override
  int get hashCode =>
      Object.hash(launcher, dashboard, notifications, systemHud);
}

@immutable
class ShellLockScreenSettings {
  const ShellLockScreenSettings({
    this.useSystemWallpaper = true,
    this.dimAmount = 0.24,
    this.blurRadius = 8,
    this.clockScale = 1,
    this.showSystemStatus = true,
  });

  final bool useSystemWallpaper;
  final double dimAmount;
  final double blurRadius;
  final double clockScale;
  final bool showSystemStatus;

  ShellLockScreenSettings copyWith({
    bool? useSystemWallpaper,
    double? dimAmount,
    double? blurRadius,
    double? clockScale,
    bool? showSystemStatus,
  }) {
    return ShellLockScreenSettings(
      useSystemWallpaper: useSystemWallpaper ?? this.useSystemWallpaper,
      dimAmount: dimAmount ?? this.dimAmount,
      blurRadius: blurRadius ?? this.blurRadius,
      clockScale: clockScale ?? this.clockScale,
      showSystemStatus: showSystemStatus ?? this.showSystemStatus,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellLockScreenSettings &&
        other.useSystemWallpaper == useSystemWallpaper &&
        other.dimAmount == dimAmount &&
        other.blurRadius == blurRadius &&
        other.clockScale == clockScale &&
        other.showSystemStatus == showSystemStatus;
  }

  @override
  int get hashCode => Object.hash(
    useSystemWallpaper,
    dimAmount,
    blurRadius,
    clockScale,
    showSystemStatus,
  );
}

@immutable
class ShellPowerSettings {
  const ShellPowerSettings({
    this.idleDpmsEnabled = true,
    this.idleDpmsTimeoutMinutes = 10,
  });

  static const int minimumIdleDpmsMinutes = 1;
  static const int maximumIdleDpmsMinutes = 120;

  final bool idleDpmsEnabled;
  final int idleDpmsTimeoutMinutes;

  ShellPowerSettings copyWith({
    bool? idleDpmsEnabled,
    int? idleDpmsTimeoutMinutes,
  }) {
    return ShellPowerSettings(
      idleDpmsEnabled: idleDpmsEnabled ?? this.idleDpmsEnabled,
      idleDpmsTimeoutMinutes:
          idleDpmsTimeoutMinutes ?? this.idleDpmsTimeoutMinutes,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellPowerSettings &&
        other.idleDpmsEnabled == idleDpmsEnabled &&
        other.idleDpmsTimeoutMinutes == idleDpmsTimeoutMinutes;
  }

  @override
  int get hashCode => Object.hash(idleDpmsEnabled, idleDpmsTimeoutMinutes);
}

@immutable
class ShellSettings {
  const ShellSettings({
    this.localization = const ShellLocalizationSettings(),
    this.appearance = const ShellAppearanceSettings(),
    this.layout = const ShellLayoutSettings(),
    this.overlays = const ShellOverlaySettings(),
    this.animations = const ShellAnimationSettings(),
    this.lockScreen = const ShellLockScreenSettings(),
    this.power = const ShellPowerSettings(),
  });

  static const int schemaVersion = 8;

  final ShellLocalizationSettings localization;
  final ShellAppearanceSettings appearance;
  final ShellLayoutSettings layout;
  final ShellOverlaySettings overlays;
  final ShellAnimationSettings animations;
  final ShellLockScreenSettings lockScreen;
  final ShellPowerSettings power;

  ShellSettings copyWith({
    ShellLocalizationSettings? localization,
    ShellAppearanceSettings? appearance,
    ShellLayoutSettings? layout,
    ShellOverlaySettings? overlays,
    ShellAnimationSettings? animations,
    ShellLockScreenSettings? lockScreen,
    ShellPowerSettings? power,
  }) {
    return ShellSettings(
      localization: localization ?? this.localization,
      appearance: appearance ?? this.appearance,
      layout: layout ?? this.layout,
      overlays: overlays ?? this.overlays,
      animations: animations ?? this.animations,
      lockScreen: lockScreen ?? this.lockScreen,
      power: power ?? this.power,
    );
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'version': schemaVersion,
      'localization': <String, Object>{'locale': localization.locale.name},
      'appearance': <String, Object>{
        'accentSource': appearance.accentSource.name,
        'customAccentColor': appearance.customAccentColor.toARGB32(),
        'windowRadius': appearance.windowRadius,
        'panelRadius': appearance.panelRadius,
        'panelOpacity': appearance.panelOpacity,
        'backdropBlurEnabled': appearance.backdropBlurEnabled,
        'backdropBlurSigma': appearance.backdropBlurSigma,
        'backdropBlurOpacityThreshold': appearance.backdropBlurOpacityThreshold,
        'focusedWindowOpacity': appearance.focusedWindowOpacity,
        'unfocusedWindowOpacity': appearance.unfocusedWindowOpacity,
        'cursorSize': appearance.cursorSize,
      },
      'layout': <String, Object>{
        if (layout.systemBarSide case final side?) 'systemBarSide': side.name,
        'systemBarOutputs': layout.systemBarOutputNames,
        'systemBarThickness': layout.systemBarThickness,
        'maximizePadding': layout.maximizePadding,
        'clipboardTrayEdge': layout.clipboardTrayEdge.name,
        'clipboardTrayExtent': layout.clipboardTrayExtent,
      },
      'overlays': <String, Object>{
        'launcher': _placementToJson(overlays.launcher),
        'dashboard': _placementToJson(overlays.dashboard),
        'notifications': _placementToJson(overlays.notifications),
        'systemHud': _placementToJson(overlays.systemHud),
      },
      'animations': <String, Object>{
        'windowCloseEffect': animations.windowCloseEffect.name,
        'durationScale': animations.durationScale,
        'panelTravel': animations.panelTravel,
        'animateLockScreen': animations.animateLockScreen,
      },
      'lockScreen': <String, Object>{
        'useSystemWallpaper': lockScreen.useSystemWallpaper,
        'dimAmount': lockScreen.dimAmount,
        'blurRadius': lockScreen.blurRadius,
        'clockScale': lockScreen.clockScale,
        'showSystemStatus': lockScreen.showSystemStatus,
      },
      'power': <String, Object>{
        'idleDpmsEnabled': power.idleDpmsEnabled,
        'idleDpmsTimeoutMinutes': power.idleDpmsTimeoutMinutes,
      },
    };
  }

  factory ShellSettings.fromJson(Map<String, dynamic> json) {
    final defaults = const ShellSettings();
    final localizationJson = _map(json['localization']);
    final appearanceJson = _map(json['appearance']);
    final layoutJson = _map(json['layout']);
    final overlaysJson = _map(json['overlays']);
    final animationsJson = _map(json['animations']);
    final lockJson = _map(json['lockScreen']);
    final powerJson = _map(json['power']);
    final outputNames = <String>[
      for (final value in _list(layoutJson['systemBarOutputs']))
        if (value is String && value.trim().isNotEmpty) value.trim(),
    ];
    return ShellSettings(
      localization: ShellLocalizationSettings(
        locale: _enumValue(
          ShellLocalePreference.values,
          localizationJson['locale'],
          defaults.localization.locale,
        ),
      ),
      appearance: ShellAppearanceSettings(
        accentSource: _enumValue(
          ShellAccentSource.values,
          appearanceJson['accentSource'],
          defaults.appearance.accentSource,
        ),
        customAccentColor: _color(
          appearanceJson['customAccentColor'],
          defaults.appearance.customAccentColor,
        ),
        windowRadius: _number(
          appearanceJson['windowRadius'],
          defaults.appearance.windowRadius,
          0,
          48,
        ),
        panelRadius: _number(
          appearanceJson['panelRadius'],
          defaults.appearance.panelRadius,
          8,
          56,
        ),
        panelOpacity: _number(
          appearanceJson['panelOpacity'],
          defaults.appearance.panelOpacity,
          0.35,
          1,
        ),
        backdropBlurEnabled: appearanceJson['backdropBlurEnabled'] is bool
            ? appearanceJson['backdropBlurEnabled'] as bool
            : defaults.appearance.backdropBlurEnabled,
        backdropBlurSigma: _number(
          appearanceJson['backdropBlurSigma'],
          defaults.appearance.backdropBlurSigma,
          4,
          32,
        ),
        backdropBlurOpacityThreshold: _number(
          appearanceJson['backdropBlurOpacityThreshold'],
          defaults.appearance.backdropBlurOpacityThreshold,
          0,
          1,
        ),
        focusedWindowOpacity: _number(
          appearanceJson['focusedWindowOpacity'],
          defaults.appearance.focusedWindowOpacity,
          0.35,
          1,
        ),
        unfocusedWindowOpacity: _number(
          appearanceJson['unfocusedWindowOpacity'],
          defaults.appearance.unfocusedWindowOpacity,
          0.2,
          1,
        ),
        cursorSize: _number(
          appearanceJson['cursorSize'],
          defaults.appearance.cursorSize,
          shellCursorMinimumSize,
          shellCursorMaximumSize,
        ),
      ),
      layout: ShellLayoutSettings(
        systemBarSide: _nullableEnumValue(
          SystemBarSide.values,
          layoutJson['systemBarSide'],
        ),
        systemBarOutputNames: List<String>.unmodifiable(outputNames),
        systemBarThickness: _number(
          layoutJson['systemBarThickness'],
          defaults.layout.systemBarThickness,
          24,
          112,
        ),
        maximizePadding: _number(
          layoutJson['maximizePadding'],
          defaults.layout.maximizePadding,
          0,
          64,
        ),
        clipboardTrayEdge: _enumValue(
          ClipboardTrayEdge.values,
          layoutJson['clipboardTrayEdge'],
          defaults.layout.clipboardTrayEdge,
        ),
        clipboardTrayExtent: _number(
          layoutJson['clipboardTrayExtent'],
          defaults.layout.clipboardTrayExtent,
          clipboardTrayMinimumExtent,
          clipboardTrayMaximumExtent,
        ),
      ),
      overlays: ShellOverlaySettings(
        launcher: _placement(
          overlaysJson['launcher'],
          defaults.overlays.launcher,
          minWidth: 420,
          minHeight: 360,
        ),
        dashboard: _placement(
          overlaysJson['dashboard'],
          defaults.overlays.dashboard,
          minWidth: 320,
          minHeight: 360,
        ),
        notifications: _placement(
          overlaysJson['notifications'],
          defaults.overlays.notifications,
          minWidth: 280,
          minHeight: 200,
        ),
        systemHud: _placement(
          overlaysJson['systemHud'],
          defaults.overlays.systemHud,
          minWidth: 220,
          minHeight: 64,
        ),
      ),
      animations: ShellAnimationSettings(
        windowCloseEffect: _enumValue(
          DesktopWindowCloseEffect.values,
          animationsJson['windowCloseEffect'],
          defaults.animations.windowCloseEffect,
        ),
        durationScale: _number(
          animationsJson['durationScale'],
          defaults.animations.durationScale,
          0.5,
          2,
        ),
        panelTravel: _number(
          animationsJson['panelTravel'],
          defaults.animations.panelTravel,
          0,
          96,
        ),
        animateLockScreen: animationsJson['animateLockScreen'] is bool
            ? animationsJson['animateLockScreen'] as bool
            : defaults.animations.animateLockScreen,
      ),
      lockScreen: ShellLockScreenSettings(
        useSystemWallpaper: lockJson['useSystemWallpaper'] is bool
            ? lockJson['useSystemWallpaper'] as bool
            : defaults.lockScreen.useSystemWallpaper,
        dimAmount: _number(
          lockJson['dimAmount'],
          defaults.lockScreen.dimAmount,
          0,
          0.85,
        ),
        blurRadius: _number(
          lockJson['blurRadius'],
          defaults.lockScreen.blurRadius,
          0,
          32,
        ),
        clockScale: _number(
          lockJson['clockScale'],
          defaults.lockScreen.clockScale,
          0.65,
          1.4,
        ),
        showSystemStatus: lockJson['showSystemStatus'] is bool
            ? lockJson['showSystemStatus'] as bool
            : defaults.lockScreen.showSystemStatus,
      ),
      power: ShellPowerSettings(
        idleDpmsEnabled: powerJson['idleDpmsEnabled'] is bool
            ? powerJson['idleDpmsEnabled'] as bool
            : defaults.power.idleDpmsEnabled,
        idleDpmsTimeoutMinutes: _integer(
          powerJson['idleDpmsTimeoutMinutes'],
          defaults.power.idleDpmsTimeoutMinutes,
          ShellPowerSettings.minimumIdleDpmsMinutes,
          ShellPowerSettings.maximumIdleDpmsMinutes,
        ),
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellSettings &&
        other.localization == localization &&
        other.appearance == appearance &&
        other.layout == layout &&
        other.overlays == overlays &&
        other.animations == animations &&
        other.lockScreen == lockScreen &&
        other.power == power;
  }

  @override
  int get hashCode => Object.hash(
    localization,
    appearance,
    layout,
    overlays,
    animations,
    lockScreen,
    power,
  );
}

Map<String, Object> _placementToJson(ShellPopupPlacement placement) {
  return <String, Object>{
    'anchor': placement.anchor.name,
    'width': placement.width,
    'height': placement.height,
    'margin': placement.margin,
  };
}

ShellPopupPlacement _placement(
  Object? value,
  ShellPopupPlacement fallback, {
  required double minWidth,
  required double minHeight,
}) {
  final json = _map(value);
  return ShellPopupPlacement(
    anchor: _enumValue(
      ShellPopupAnchor.values,
      json['anchor'],
      fallback.anchor,
    ),
    width: _number(json['width'], fallback.width, minWidth, 1400),
    height: _number(json['height'], fallback.height, minHeight, 1200),
    margin: _number(json['margin'], fallback.margin, 0, 96),
  );
}

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic> ? value : const <String, dynamic>{};
}

List<Object?> _list(Object? value) {
  return value is List ? value.cast<Object?>() : const <Object?>[];
}

T _enumValue<T extends Enum>(List<T> values, Object? value, T fallback) {
  return _nullableEnumValue(values, value) ?? fallback;
}

T? _nullableEnumValue<T extends Enum>(List<T> values, Object? value) {
  if (value is! String) {
    return null;
  }
  for (final candidate in values) {
    if (candidate.name == value) {
      return candidate;
    }
  }
  return null;
}

Color _color(Object? value, Color fallback) {
  if (value is! num) {
    return fallback;
  }
  final argb = value.toInt();
  if (argb < 0 || argb > 0xffffffff) {
    return fallback;
  }
  return Color(argb).withAlpha(0xff);
}

double _number(Object? value, double fallback, double minimum, double maximum) {
  if (value is! num) {
    return fallback;
  }
  final result = value.toDouble();
  if (!result.isFinite) {
    return fallback;
  }
  return result.clamp(minimum, maximum).toDouble();
}

int _integer(Object? value, int fallback, int minimum, int maximum) {
  if (value is! num || !value.isFinite) {
    return fallback;
  }
  return value.round().clamp(minimum, maximum).toInt();
}
