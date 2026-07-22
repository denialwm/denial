import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/display_layout.dart';
import '../models/shell_popup_placement.dart';
import '../theme/tokens.dart';

enum ShellAccentSource { wallpaper, custom }

enum ShellOverlaySurface { launcher, dashboard, notifications, systemHud }

@immutable
class ShellAppearanceSettings {
  const ShellAppearanceSettings({
    this.accentSource = ShellAccentSource.wallpaper,
    this.customAccentColor = ShellColors.accent,
    this.focusedWindowBorderColor = ShellColors.focusedWindowBorder,
    this.windowRadius = ShellRadii.window,
    this.panelRadius = ShellRadii.panel,
    this.panelOpacity = 0.93,
    this.focusedWindowOpacity = 1,
    this.unfocusedWindowOpacity = 1,
  });

  final ShellAccentSource accentSource;
  final Color customAccentColor;
  final Color focusedWindowBorderColor;
  final double windowRadius;
  final double panelRadius;
  final double panelOpacity;
  final double focusedWindowOpacity;
  final double unfocusedWindowOpacity;

  ShellAppearanceSettings copyWith({
    ShellAccentSource? accentSource,
    Color? customAccentColor,
    Color? focusedWindowBorderColor,
    double? windowRadius,
    double? panelRadius,
    double? panelOpacity,
    double? focusedWindowOpacity,
    double? unfocusedWindowOpacity,
  }) {
    return ShellAppearanceSettings(
      accentSource: accentSource ?? this.accentSource,
      customAccentColor: customAccentColor ?? this.customAccentColor,
      focusedWindowBorderColor:
          focusedWindowBorderColor ?? this.focusedWindowBorderColor,
      windowRadius: windowRadius ?? this.windowRadius,
      panelRadius: panelRadius ?? this.panelRadius,
      panelOpacity: panelOpacity ?? this.panelOpacity,
      focusedWindowOpacity: focusedWindowOpacity ?? this.focusedWindowOpacity,
      unfocusedWindowOpacity:
          unfocusedWindowOpacity ?? this.unfocusedWindowOpacity,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellAppearanceSettings &&
        other.accentSource == accentSource &&
        other.customAccentColor == customAccentColor &&
        other.focusedWindowBorderColor == focusedWindowBorderColor &&
        other.windowRadius == windowRadius &&
        other.panelRadius == panelRadius &&
        other.panelOpacity == panelOpacity &&
        other.focusedWindowOpacity == focusedWindowOpacity &&
        other.unfocusedWindowOpacity == unfocusedWindowOpacity;
  }

  @override
  int get hashCode => Object.hash(
    accentSource,
    customAccentColor,
    focusedWindowBorderColor,
    windowRadius,
    panelRadius,
    panelOpacity,
    focusedWindowOpacity,
    unfocusedWindowOpacity,
  );
}

@immutable
class ShellLayoutSettings {
  const ShellLayoutSettings({
    this.systemBarSide,
    this.systemBarOutputNames = const <String>[],
    this.systemBarThickness = 32,
    this.maximizePadding = 10,
  });

  final SystemBarSide? systemBarSide;
  final List<String> systemBarOutputNames;
  final double systemBarThickness;
  final double maximizePadding;

  ShellLayoutSettings copyWith({
    SystemBarSide? systemBarSide,
    bool clearSystemBarSide = false,
    List<String>? systemBarOutputNames,
    double? systemBarThickness,
    double? maximizePadding,
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
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellLayoutSettings &&
        other.systemBarSide == systemBarSide &&
        listEquals(other.systemBarOutputNames, systemBarOutputNames) &&
        other.systemBarThickness == systemBarThickness &&
        other.maximizePadding == maximizePadding;
  }

  @override
  int get hashCode => Object.hash(
    systemBarSide,
    Object.hashAll(systemBarOutputNames),
    systemBarThickness,
    maximizePadding,
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
class ShellSettings {
  const ShellSettings({
    this.appearance = const ShellAppearanceSettings(),
    this.layout = const ShellLayoutSettings(),
    this.overlays = const ShellOverlaySettings(),
    this.lockScreen = const ShellLockScreenSettings(),
  });

  static const int schemaVersion = 1;

  final ShellAppearanceSettings appearance;
  final ShellLayoutSettings layout;
  final ShellOverlaySettings overlays;
  final ShellLockScreenSettings lockScreen;

  ShellSettings copyWith({
    ShellAppearanceSettings? appearance,
    ShellLayoutSettings? layout,
    ShellOverlaySettings? overlays,
    ShellLockScreenSettings? lockScreen,
  }) {
    return ShellSettings(
      appearance: appearance ?? this.appearance,
      layout: layout ?? this.layout,
      overlays: overlays ?? this.overlays,
      lockScreen: lockScreen ?? this.lockScreen,
    );
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'version': schemaVersion,
      'appearance': <String, Object>{
        'accentSource': appearance.accentSource.name,
        'customAccentColor': appearance.customAccentColor.toARGB32(),
        'focusedWindowBorderColor': appearance.focusedWindowBorderColor
            .toARGB32(),
        'windowRadius': appearance.windowRadius,
        'panelRadius': appearance.panelRadius,
        'panelOpacity': appearance.panelOpacity,
        'focusedWindowOpacity': appearance.focusedWindowOpacity,
        'unfocusedWindowOpacity': appearance.unfocusedWindowOpacity,
      },
      'layout': <String, Object>{
        if (layout.systemBarSide case final side?) 'systemBarSide': side.name,
        'systemBarOutputs': layout.systemBarOutputNames,
        'systemBarThickness': layout.systemBarThickness,
        'maximizePadding': layout.maximizePadding,
      },
      'overlays': <String, Object>{
        'launcher': _placementToJson(overlays.launcher),
        'dashboard': _placementToJson(overlays.dashboard),
        'notifications': _placementToJson(overlays.notifications),
        'systemHud': _placementToJson(overlays.systemHud),
      },
      'lockScreen': <String, Object>{
        'useSystemWallpaper': lockScreen.useSystemWallpaper,
        'dimAmount': lockScreen.dimAmount,
        'blurRadius': lockScreen.blurRadius,
        'clockScale': lockScreen.clockScale,
        'showSystemStatus': lockScreen.showSystemStatus,
      },
    };
  }

  factory ShellSettings.fromJson(Map<String, dynamic> json) {
    final defaults = const ShellSettings();
    final appearanceJson = _map(json['appearance']);
    final layoutJson = _map(json['layout']);
    final overlaysJson = _map(json['overlays']);
    final lockJson = _map(json['lockScreen']);
    final outputNames = <String>[
      for (final value in _list(layoutJson['systemBarOutputs']))
        if (value is String && value.trim().isNotEmpty) value.trim(),
    ];
    return ShellSettings(
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
        focusedWindowBorderColor: _color(
          appearanceJson['focusedWindowBorderColor'],
          defaults.appearance.focusedWindowBorderColor,
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
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellSettings &&
        other.appearance == appearance &&
        other.layout == layout &&
        other.overlays == overlays &&
        other.lockScreen == lockScreen;
  }

  @override
  int get hashCode => Object.hash(appearance, layout, overlays, lockScreen);
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
