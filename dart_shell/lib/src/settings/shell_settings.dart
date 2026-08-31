import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/display_layout.dart';
import '../models/shell_popup_placement.dart';
import '../state/desktop_window_close_effect.dart';
import '../theme/backdrop_blur_level.dart';
import '../theme/cursor_themes.dart';
import '../theme/tokens.dart';

enum ShellAccentSource { wallpaper, custom }

enum DesktopColorSchemePreference {
  preferDark,
  preferLight,
  noPreference;

  Brightness get effectiveBrightness => switch (this) {
    DesktopColorSchemePreference.preferLight => Brightness.light,
    DesktopColorSchemePreference.preferDark => Brightness.dark,
    DesktopColorSchemePreference.noPreference => denialDefaultBrightness,
  };

  int get portalValue => switch (this) {
    DesktopColorSchemePreference.noPreference => 0,
    DesktopColorSchemePreference.preferDark => 1,
    DesktopColorSchemePreference.preferLight => 2,
  };
}

const Brightness denialDefaultBrightness = Brightness.dark;

enum ShellOverlaySurface { launcher, dashboard, notifications, systemHud }

enum ClipboardTrayEdge { left, right, top, bottom }

enum MinimizedWindowPlacement { desktop, offscreen }

/// Compositor geometry policy for ordinary, non-transient desktop windows.
/// Each value maps to a Rust `WindowLayout` implementation.
enum DesktopWindowLayout { stacking, dwindle }

const double clipboardTrayMinimumExtent = 100;
const double clipboardTrayMaximumExtent = 300;
const double clipboardTrayDefaultExtent = 250;
const double launcherOverlayMinimumHeight = 200;

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
    this.colorSchemePreference = DesktopColorSchemePreference.preferDark,
    this.accentSource = ShellAccentSource.wallpaper,
    this.customAccentColor = ShellBrandColors.defaultAccent,
    this.cornerRadiusScale = ShellRoundness.normal,
    this.panelOpacity = ShellOpacity.panel,
    this.cardOpacity = ShellOpacity.card,
    this.backdropBlurEnabled = true,
    this.backdropBlurLevel = ShellBackdropBlurLevel.fast,
    this.backdropBlurOpacityThreshold = 0.2,
    this.focusedWindowBorderEnabled = true,
    this.focusedWindowOpacity = 1,
    this.unfocusedWindowOpacity = 1,
    this.cursorSize = shellCursorDefaultSize,
    this.cursorThemeId = 'bibata_modern_ice',
    this.allowClientCursorSurfaces = true,
  });

  final DesktopColorSchemePreference colorSchemePreference;
  final ShellAccentSource accentSource;
  final Color customAccentColor;
  final double cornerRadiusScale;
  final double panelOpacity;
  final double cardOpacity;
  final bool backdropBlurEnabled;
  final ShellBackdropBlurLevel backdropBlurLevel;
  final double backdropBlurOpacityThreshold;
  final bool focusedWindowBorderEnabled;
  final double focusedWindowOpacity;
  final double unfocusedWindowOpacity;
  final double cursorSize;
  final String cursorThemeId;
  final bool allowClientCursorSurfaces;

  ShellAppearanceSettings copyWith({
    DesktopColorSchemePreference? colorSchemePreference,
    ShellAccentSource? accentSource,
    Color? customAccentColor,
    double? cornerRadiusScale,
    double? panelOpacity,
    double? cardOpacity,
    bool? backdropBlurEnabled,
    ShellBackdropBlurLevel? backdropBlurLevel,
    double? backdropBlurOpacityThreshold,
    bool? focusedWindowBorderEnabled,
    double? focusedWindowOpacity,
    double? unfocusedWindowOpacity,
    double? cursorSize,
    String? cursorThemeId,
    bool? allowClientCursorSurfaces,
  }) {
    return ShellAppearanceSettings(
      colorSchemePreference:
          colorSchemePreference ?? this.colorSchemePreference,
      accentSource: accentSource ?? this.accentSource,
      customAccentColor: customAccentColor ?? this.customAccentColor,
      cornerRadiusScale: cornerRadiusScale ?? this.cornerRadiusScale,
      panelOpacity: panelOpacity ?? this.panelOpacity,
      cardOpacity: cardOpacity ?? this.cardOpacity,
      backdropBlurEnabled: backdropBlurEnabled ?? this.backdropBlurEnabled,
      backdropBlurLevel: backdropBlurLevel ?? this.backdropBlurLevel,
      backdropBlurOpacityThreshold:
          backdropBlurOpacityThreshold ?? this.backdropBlurOpacityThreshold,
      focusedWindowBorderEnabled:
          focusedWindowBorderEnabled ?? this.focusedWindowBorderEnabled,
      focusedWindowOpacity: focusedWindowOpacity ?? this.focusedWindowOpacity,
      unfocusedWindowOpacity:
          unfocusedWindowOpacity ?? this.unfocusedWindowOpacity,
      cursorSize: cursorSize ?? this.cursorSize,
      cursorThemeId: cursorThemeId ?? this.cursorThemeId,
      allowClientCursorSurfaces:
          allowClientCursorSurfaces ?? this.allowClientCursorSurfaces,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellAppearanceSettings &&
        other.colorSchemePreference == colorSchemePreference &&
        other.accentSource == accentSource &&
        other.customAccentColor == customAccentColor &&
        other.cornerRadiusScale == cornerRadiusScale &&
        other.panelOpacity == panelOpacity &&
        other.cardOpacity == cardOpacity &&
        other.backdropBlurEnabled == backdropBlurEnabled &&
        other.backdropBlurLevel == backdropBlurLevel &&
        other.backdropBlurOpacityThreshold == backdropBlurOpacityThreshold &&
        other.focusedWindowBorderEnabled == focusedWindowBorderEnabled &&
        other.focusedWindowOpacity == focusedWindowOpacity &&
        other.unfocusedWindowOpacity == unfocusedWindowOpacity &&
        other.cursorSize == cursorSize &&
        other.cursorThemeId == cursorThemeId &&
        other.allowClientCursorSurfaces == allowClientCursorSurfaces;
  }

  @override
  int get hashCode => Object.hash(
    colorSchemePreference,
    accentSource,
    customAccentColor,
    cornerRadiusScale,
    panelOpacity,
    cardOpacity,
    backdropBlurEnabled,
    backdropBlurLevel,
    backdropBlurOpacityThreshold,
    focusedWindowBorderEnabled,
    focusedWindowOpacity,
    unfocusedWindowOpacity,
    cursorSize,
    cursorThemeId,
    allowClientCursorSurfaces,
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
    this.windowLayout = DesktopWindowLayout.stacking,
    this.systemBarSide,
    this.systemBarOutputNames = const <String>[],
    this.systemBarThickness = 32,
    this.maximizePadding = 10,
    this.minimizedWindowPlacement = MinimizedWindowPlacement.desktop,
    this.clipboardTrayEdge = ClipboardTrayEdge.right,
    this.clipboardTrayExtent = clipboardTrayDefaultExtent,
  });

  final DesktopWindowLayout windowLayout;
  final SystemBarSide? systemBarSide;
  final List<String> systemBarOutputNames;
  final double systemBarThickness;
  final double maximizePadding;
  final MinimizedWindowPlacement minimizedWindowPlacement;
  final ClipboardTrayEdge clipboardTrayEdge;
  final double clipboardTrayExtent;

  ShellLayoutSettings copyWith({
    DesktopWindowLayout? windowLayout,
    SystemBarSide? systemBarSide,
    bool clearSystemBarSide = false,
    List<String>? systemBarOutputNames,
    double? systemBarThickness,
    double? maximizePadding,
    MinimizedWindowPlacement? minimizedWindowPlacement,
    ClipboardTrayEdge? clipboardTrayEdge,
    double? clipboardTrayExtent,
  }) {
    return ShellLayoutSettings(
      windowLayout: windowLayout ?? this.windowLayout,
      systemBarSide: clearSystemBarSide
          ? null
          : systemBarSide ?? this.systemBarSide,
      systemBarOutputNames: List<String>.unmodifiable(
        systemBarOutputNames ?? this.systemBarOutputNames,
      ),
      systemBarThickness: systemBarThickness ?? this.systemBarThickness,
      maximizePadding: maximizePadding ?? this.maximizePadding,
      minimizedWindowPlacement:
          minimizedWindowPlacement ?? this.minimizedWindowPlacement,
      clipboardTrayEdge: clipboardTrayEdge ?? this.clipboardTrayEdge,
      clipboardTrayExtent: clipboardTrayExtent ?? this.clipboardTrayExtent,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellLayoutSettings &&
        other.windowLayout == windowLayout &&
        other.systemBarSide == systemBarSide &&
        listEquals(other.systemBarOutputNames, systemBarOutputNames) &&
        other.systemBarThickness == systemBarThickness &&
        other.maximizePadding == maximizePadding &&
        other.minimizedWindowPlacement == minimizedWindowPlacement &&
        other.clipboardTrayEdge == clipboardTrayEdge &&
        other.clipboardTrayExtent == clipboardTrayExtent;
  }

  @override
  int get hashCode => Object.hash(
    windowLayout,
    systemBarSide,
    Object.hashAll(systemBarOutputNames),
    systemBarThickness,
    maximizePadding,
    minimizedWindowPlacement,
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
    this.idleLockEnabled = true,
    this.idleLockTimeoutMinutes = 5,
    this.idleDpmsEnabled = true,
    this.idleDpmsTimeoutMinutes = 10,
    this.idleSuspendEnabled = false,
    this.idleSuspendTimeoutMinutes = 30,
  });

  static const int minimumIdleTimeoutMinutes = 1;
  static const int maximumIdleTimeoutMinutes = 120;
  static const int minimumIdleDpmsMinutes = minimumIdleTimeoutMinutes;
  static const int maximumIdleDpmsMinutes = maximumIdleTimeoutMinutes;

  final bool idleLockEnabled;
  final int idleLockTimeoutMinutes;
  final bool idleDpmsEnabled;
  final int idleDpmsTimeoutMinutes;
  final bool idleSuspendEnabled;
  final int idleSuspendTimeoutMinutes;

  ShellPowerSettings copyWith({
    bool? idleLockEnabled,
    int? idleLockTimeoutMinutes,
    bool? idleDpmsEnabled,
    int? idleDpmsTimeoutMinutes,
    bool? idleSuspendEnabled,
    int? idleSuspendTimeoutMinutes,
  }) {
    return ShellPowerSettings(
      idleLockEnabled: idleLockEnabled ?? this.idleLockEnabled,
      idleLockTimeoutMinutes:
          idleLockTimeoutMinutes ?? this.idleLockTimeoutMinutes,
      idleDpmsEnabled: idleDpmsEnabled ?? this.idleDpmsEnabled,
      idleDpmsTimeoutMinutes:
          idleDpmsTimeoutMinutes ?? this.idleDpmsTimeoutMinutes,
      idleSuspendEnabled: idleSuspendEnabled ?? this.idleSuspendEnabled,
      idleSuspendTimeoutMinutes:
          idleSuspendTimeoutMinutes ?? this.idleSuspendTimeoutMinutes,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellPowerSettings &&
        other.idleLockEnabled == idleLockEnabled &&
        other.idleLockTimeoutMinutes == idleLockTimeoutMinutes &&
        other.idleDpmsEnabled == idleDpmsEnabled &&
        other.idleDpmsTimeoutMinutes == idleDpmsTimeoutMinutes &&
        other.idleSuspendEnabled == idleSuspendEnabled &&
        other.idleSuspendTimeoutMinutes == idleSuspendTimeoutMinutes;
  }

  @override
  int get hashCode => Object.hash(
    idleLockEnabled,
    idleLockTimeoutMinutes,
    idleDpmsEnabled,
    idleDpmsTimeoutMinutes,
    idleSuspendEnabled,
    idleSuspendTimeoutMinutes,
  );
}

const int applicationEnvironmentMaximumNameBytes = 256;
const int applicationEnvironmentMaximumValueBytes = 16 * 1024;
const int applicationEnvironmentMaximumDesktopFileIdBytes = 4096;

bool isValidApplicationEnvironmentVariableName(String name) {
  if (name.isEmpty ||
      utf8.encode(name).length > applicationEnvironmentMaximumNameBytes) {
    return false;
  }
  final first = name.codeUnitAt(0);
  if (first != 0x5f &&
      !(first >= 0x41 && first <= 0x5a) &&
      !(first >= 0x61 && first <= 0x7a)) {
    return false;
  }
  for (var index = 1; index < name.length; index += 1) {
    final codeUnit = name.codeUnitAt(index);
    if (codeUnit != 0x5f &&
        !(codeUnit >= 0x30 && codeUnit <= 0x39) &&
        !(codeUnit >= 0x41 && codeUnit <= 0x5a) &&
        !(codeUnit >= 0x61 && codeUnit <= 0x7a)) {
      return false;
    }
  }
  return true;
}

bool isValidApplicationEnvironmentDesktopFileId(String desktopFileId) {
  return desktopFileId.isNotEmpty &&
      desktopFileId.endsWith('.desktop') &&
      !desktopFileId.contains('/') &&
      !desktopFileId.contains('\u0000') &&
      utf8.encode(desktopFileId).length <=
          applicationEnvironmentMaximumDesktopFileIdBytes;
}

@immutable
class ShellApplicationEnvironmentSettings {
  const ShellApplicationEnvironmentSettings({
    this.variables = const <String, String?>{},
    this.applications = const <String, Map<String, String?>>{},
  });

  /// Overrides applied to every application launched directly by Denial.
  final Map<String, String?> variables;
  final Map<String, Map<String, String?>> applications;

  Map<String, String?> variablesFor(String? desktopFileId) {
    if (desktopFileId == null) {
      return variables;
    }
    return applications[desktopFileId] ?? const <String, String?>{};
  }

  ShellApplicationEnvironmentSettings withOverride(
    String name,
    String? value, {
    String? desktopFileId,
  }) {
    if (!isValidApplicationEnvironmentVariableName(name)) {
      throw ArgumentError.value(name, 'name', 'invalid environment variable');
    }
    if (value != null &&
        utf8.encode(value).length > applicationEnvironmentMaximumValueBytes) {
      throw ArgumentError.value(
        value,
        'value',
        'environment value is too long',
      );
    }
    if (desktopFileId != null &&
        !isValidApplicationEnvironmentDesktopFileId(desktopFileId)) {
      throw ArgumentError.value(
        desktopFileId,
        'desktopFileId',
        'invalid desktop-file ID',
      );
    }
    if (desktopFileId != null) {
      final scoped = <String, String?>{
        ...variablesFor(desktopFileId),
        name: value,
      };
      return ShellApplicationEnvironmentSettings(
        variables: variables,
        applications: _immutableApplicationEnvironmentMaps(
          <String, Map<String, String?>>{
            ...applications,
            desktopFileId: scoped,
          },
        ),
      );
    }
    return ShellApplicationEnvironmentSettings(
      variables: Map<String, String?>.unmodifiable(<String, String?>{
        ...variables,
        name: value,
      }),
      applications: applications,
    );
  }

  ShellApplicationEnvironmentSettings withoutOverride(
    String name, {
    String? desktopFileId,
  }) {
    final scoped = variablesFor(desktopFileId);
    if (!scoped.containsKey(name)) {
      return this;
    }
    final next = Map<String, String?>.of(scoped)..remove(name);
    if (desktopFileId != null) {
      final applicationMaps = <String, Map<String, String?>>{...applications};
      if (next.isEmpty) {
        applicationMaps.remove(desktopFileId);
      } else {
        applicationMaps[desktopFileId] = next;
      }
      return ShellApplicationEnvironmentSettings(
        variables: variables,
        applications: _immutableApplicationEnvironmentMaps(applicationMaps),
      );
    }
    return ShellApplicationEnvironmentSettings(
      variables: Map<String, String?>.unmodifiable(next),
      applications: applications,
    );
  }

  ShellApplicationEnvironmentSettings withoutApplication(String desktopFileId) {
    if (!applications.containsKey(desktopFileId)) {
      return this;
    }
    return ShellApplicationEnvironmentSettings(
      variables: variables,
      applications: _immutableApplicationEnvironmentMaps(
        <String, Map<String, String?>>{...applications}..remove(desktopFileId),
      ),
    );
  }

  factory ShellApplicationEnvironmentSettings.fromJson(Object? value) {
    final json = _map(value);
    if (json.values.every((value) => value == null || value is String)) {
      return ShellApplicationEnvironmentSettings(
        variables: _parseApplicationEnvironmentVariables(json),
      );
    }
    final variables = _parseApplicationEnvironmentVariables(json['default']);
    final applications = <String, Map<String, String?>>{};
    for (final entry in _map(json['applications']).entries) {
      if (!isValidApplicationEnvironmentDesktopFileId(entry.key)) {
        continue;
      }
      applications[entry.key] = _parseApplicationEnvironmentVariables(
        entry.value,
      );
    }
    return ShellApplicationEnvironmentSettings(
      variables: variables,
      applications: _immutableApplicationEnvironmentMaps(applications),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'default': <String, Object?>{
      for (final entry in variables.entries) entry.key: entry.value,
    },
    'applications': <String, Object?>{
      for (final application in applications.entries)
        application.key: <String, Object?>{
          for (final entry in application.value.entries) entry.key: entry.value,
        },
    },
  };

  @override
  bool operator ==(Object other) {
    return other is ShellApplicationEnvironmentSettings &&
        mapEquals(other.variables, variables) &&
        _applicationEnvironmentMapsEqual(other.applications, applications);
  }

  @override
  int get hashCode {
    final defaultEntries = variables.entries.toList(growable: false)
      ..sort((first, second) => first.key.compareTo(second.key));
    final applicationEntries = applications.entries.toList(growable: false)
      ..sort((first, second) => first.key.compareTo(second.key));
    return Object.hash(
      Object.hashAll(
        defaultEntries.map((entry) => Object.hash(entry.key, entry.value)),
      ),
      Object.hashAll(
        applicationEntries.map((application) {
          final entries = application.value.entries.toList(growable: false)
            ..sort((first, second) => first.key.compareTo(second.key));
          return Object.hash(
            application.key,
            Object.hashAll(
              entries.map((entry) => Object.hash(entry.key, entry.value)),
            ),
          );
        }),
      ),
    );
  }
}

Map<String, String?> _parseApplicationEnvironmentVariables(Object? value) {
  final variables = <String, String?>{};
  for (final entry in _map(value).entries) {
    if (isValidApplicationEnvironmentVariableName(entry.key) &&
        (entry.value == null || entry.value is String)) {
      final stringValue = entry.value as String?;
      if (stringValue == null ||
          utf8.encode(stringValue).length <=
              applicationEnvironmentMaximumValueBytes) {
        variables[entry.key] = stringValue;
      }
    }
  }
  return Map<String, String?>.unmodifiable(variables);
}

Map<String, Map<String, String?>> _immutableApplicationEnvironmentMaps(
  Map<String, Map<String, String?>> applications,
) {
  return Map<String, Map<String, String?>>.unmodifiable(
    <String, Map<String, String?>>{
      for (final entry in applications.entries)
        entry.key: Map<String, String?>.unmodifiable(entry.value),
    },
  );
}

bool _applicationEnvironmentMapsEqual(
  Map<String, Map<String, String?>> first,
  Map<String, Map<String, String?>> second,
) {
  if (first.length != second.length) {
    return false;
  }
  for (final entry in first.entries) {
    if (!mapEquals(entry.value, second[entry.key])) {
      return false;
    }
  }
  return true;
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
    this.applicationEnvironment = const ShellApplicationEnvironmentSettings(),
  });

  // Blur levels are additive in schema 9. Keep emitting the derived legacy
  // sigma so older shells can read settings written by this version.
  static const int schemaVersion = 21;

  final ShellLocalizationSettings localization;
  final ShellAppearanceSettings appearance;
  final ShellLayoutSettings layout;
  final ShellOverlaySettings overlays;
  final ShellAnimationSettings animations;
  final ShellLockScreenSettings lockScreen;
  final ShellPowerSettings power;
  final ShellApplicationEnvironmentSettings applicationEnvironment;

  ShellSettings copyWith({
    ShellLocalizationSettings? localization,
    ShellAppearanceSettings? appearance,
    ShellLayoutSettings? layout,
    ShellOverlaySettings? overlays,
    ShellAnimationSettings? animations,
    ShellLockScreenSettings? lockScreen,
    ShellPowerSettings? power,
    ShellApplicationEnvironmentSettings? applicationEnvironment,
  }) {
    return ShellSettings(
      localization: localization ?? this.localization,
      appearance: appearance ?? this.appearance,
      layout: layout ?? this.layout,
      overlays: overlays ?? this.overlays,
      animations: animations ?? this.animations,
      lockScreen: lockScreen ?? this.lockScreen,
      power: power ?? this.power,
      applicationEnvironment:
          applicationEnvironment ?? this.applicationEnvironment,
    );
  }

  /// Returns only the typed fields changed since [previous].
  ///
  /// The settings controller uses this patch while a debounced native write
  /// is pending, so a concurrent authoritative update can be merged without
  /// serializing and recursively comparing two complete documents per input
  /// event.
  Map<String, Object?> differenceFrom(ShellSettings previous) {
    final patch = <String, Object?>{};

    if (localization != previous.localization) {
      final section = <String, Object?>{};
      if (localization.locale != previous.localization.locale) {
        section['locale'] = localization.locale.name;
      }
      patch['localization'] = section;
    }

    if (appearance != previous.appearance) {
      final before = previous.appearance;
      final section = <String, Object?>{};
      if (appearance.colorSchemePreference != before.colorSchemePreference) {
        section['colorSchemePreference'] =
            appearance.colorSchemePreference.name;
      }
      if (appearance.accentSource != before.accentSource) {
        section['accentSource'] = appearance.accentSource.name;
      }
      if (appearance.customAccentColor != before.customAccentColor) {
        section['customAccentColor'] = appearance.customAccentColor.toARGB32();
      }
      if (appearance.cornerRadiusScale != before.cornerRadiusScale) {
        section['cornerRadiusScale'] = appearance.cornerRadiusScale;
      }
      if (appearance.panelOpacity != before.panelOpacity) {
        section['panelOpacity'] = appearance.panelOpacity;
      }
      if (appearance.cardOpacity != before.cardOpacity) {
        section['cardOpacity'] = appearance.cardOpacity;
      }
      if (appearance.backdropBlurEnabled != before.backdropBlurEnabled) {
        section['backdropBlurEnabled'] = appearance.backdropBlurEnabled;
      }
      if (appearance.backdropBlurLevel != before.backdropBlurLevel) {
        section['backdropBlurLevel'] = appearance.backdropBlurLevel.name;
        section['backdropBlurSigma'] = appearance.backdropBlurLevel.sigma;
      }
      if (appearance.backdropBlurOpacityThreshold !=
          before.backdropBlurOpacityThreshold) {
        section['backdropBlurPixelOpacityThreshold'] =
            appearance.backdropBlurOpacityThreshold;
      }
      if (appearance.focusedWindowBorderEnabled !=
          before.focusedWindowBorderEnabled) {
        section['focusedWindowBorderEnabled'] =
            appearance.focusedWindowBorderEnabled;
      }
      if (appearance.focusedWindowOpacity != before.focusedWindowOpacity) {
        section['focusedWindowOpacity'] = appearance.focusedWindowOpacity;
      }
      if (appearance.unfocusedWindowOpacity != before.unfocusedWindowOpacity) {
        section['unfocusedWindowOpacity'] = appearance.unfocusedWindowOpacity;
      }
      if (appearance.cursorSize != before.cursorSize) {
        section['cursorSize'] = appearance.cursorSize;
      }
      if (appearance.cursorThemeId != before.cursorThemeId) {
        section['cursorThemeId'] = appearance.cursorThemeId;
      }
      if (appearance.allowClientCursorSurfaces !=
          before.allowClientCursorSurfaces) {
        section['allowClientCursorSurfaces'] =
            appearance.allowClientCursorSurfaces;
      }
      patch['appearance'] = section;
    }

    if (layout != previous.layout) {
      final before = previous.layout;
      final section = <String, Object?>{};
      if (layout.windowLayout != before.windowLayout) {
        section['windowLayout'] = layout.windowLayout.name;
      }
      if (layout.systemBarSide != before.systemBarSide) {
        section['systemBarSide'] = layout.systemBarSide?.name;
      }
      if (!listEquals(
        layout.systemBarOutputNames,
        before.systemBarOutputNames,
      )) {
        section['systemBarOutputs'] = layout.systemBarOutputNames;
      }
      if (layout.systemBarThickness != before.systemBarThickness) {
        section['systemBarThickness'] = layout.systemBarThickness;
      }
      if (layout.maximizePadding != before.maximizePadding) {
        section['maximizePadding'] = layout.maximizePadding;
      }
      if (layout.minimizedWindowPlacement != before.minimizedWindowPlacement) {
        section['minimizedWindowPlacement'] =
            layout.minimizedWindowPlacement.name;
      }
      if (layout.clipboardTrayEdge != before.clipboardTrayEdge) {
        section['clipboardTrayEdge'] = layout.clipboardTrayEdge.name;
      }
      if (layout.clipboardTrayExtent != before.clipboardTrayExtent) {
        section['clipboardTrayExtent'] = layout.clipboardTrayExtent;
      }
      patch['layout'] = section;
    }

    if (overlays != previous.overlays) {
      final before = previous.overlays;
      final section = <String, Object?>{};
      if (overlays.launcher != before.launcher) {
        section['launcher'] = _placementToJson(overlays.launcher);
      }
      if (overlays.dashboard != before.dashboard) {
        section['dashboard'] = _placementToJson(overlays.dashboard);
      }
      if (overlays.notifications != before.notifications) {
        section['notifications'] = _placementToJson(overlays.notifications);
      }
      if (overlays.systemHud != before.systemHud) {
        section['systemHud'] = _placementToJson(overlays.systemHud);
      }
      patch['overlays'] = section;
    }

    if (animations != previous.animations) {
      final before = previous.animations;
      final section = <String, Object?>{};
      if (animations.windowCloseEffect != before.windowCloseEffect) {
        section['windowCloseEffect'] = animations.windowCloseEffect.name;
      }
      if (animations.durationScale != before.durationScale) {
        section['durationScale'] = animations.durationScale;
      }
      if (animations.panelTravel != before.panelTravel) {
        section['panelTravel'] = animations.panelTravel;
      }
      if (animations.animateLockScreen != before.animateLockScreen) {
        section['animateLockScreen'] = animations.animateLockScreen;
      }
      patch['animations'] = section;
    }

    if (lockScreen != previous.lockScreen) {
      final before = previous.lockScreen;
      final section = <String, Object?>{};
      if (lockScreen.useSystemWallpaper != before.useSystemWallpaper) {
        section['useSystemWallpaper'] = lockScreen.useSystemWallpaper;
      }
      if (lockScreen.dimAmount != before.dimAmount) {
        section['dimAmount'] = lockScreen.dimAmount;
      }
      if (lockScreen.blurRadius != before.blurRadius) {
        section['blurRadius'] = lockScreen.blurRadius;
      }
      if (lockScreen.clockScale != before.clockScale) {
        section['clockScale'] = lockScreen.clockScale;
      }
      if (lockScreen.showSystemStatus != before.showSystemStatus) {
        section['showSystemStatus'] = lockScreen.showSystemStatus;
      }
      patch['lockScreen'] = section;
    }

    if (power != previous.power) {
      final before = previous.power;
      final section = <String, Object?>{};
      if (power.idleLockEnabled != before.idleLockEnabled) {
        section['idleLockEnabled'] = power.idleLockEnabled;
      }
      if (power.idleLockTimeoutMinutes != before.idleLockTimeoutMinutes) {
        section['idleLockTimeoutMinutes'] = power.idleLockTimeoutMinutes;
      }
      if (power.idleDpmsEnabled != before.idleDpmsEnabled) {
        section['idleDpmsEnabled'] = power.idleDpmsEnabled;
      }
      if (power.idleDpmsTimeoutMinutes != before.idleDpmsTimeoutMinutes) {
        section['idleDpmsTimeoutMinutes'] = power.idleDpmsTimeoutMinutes;
      }
      if (power.idleSuspendEnabled != before.idleSuspendEnabled) {
        section['idleSuspendEnabled'] = power.idleSuspendEnabled;
      }
      if (power.idleSuspendTimeoutMinutes != before.idleSuspendTimeoutMinutes) {
        section['idleSuspendTimeoutMinutes'] = power.idleSuspendTimeoutMinutes;
      }
      patch['power'] = section;
    }

    if (applicationEnvironment != previous.applicationEnvironment) {
      // This section is a complete desired map: absence means delete the
      // override, so it must never be recursively merged with an older map.
      patch['applicationEnvironment'] = applicationEnvironment.toJson();
    }

    return patch;
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'version': schemaVersion,
      'localization': <String, Object>{'locale': localization.locale.name},
      'appearance': <String, Object>{
        'colorSchemePreference': appearance.colorSchemePreference.name,
        'accentSource': appearance.accentSource.name,
        'customAccentColor': appearance.customAccentColor.toARGB32(),
        'cornerRadiusScale': appearance.cornerRadiusScale,
        'panelOpacity': appearance.panelOpacity,
        'cardOpacity': appearance.cardOpacity,
        'backdropBlurEnabled': appearance.backdropBlurEnabled,
        'backdropBlurLevel': appearance.backdropBlurLevel.name,
        'backdropBlurSigma': appearance.backdropBlurLevel.sigma,
        'backdropBlurPixelOpacityThreshold':
            appearance.backdropBlurOpacityThreshold,
        'focusedWindowBorderEnabled': appearance.focusedWindowBorderEnabled,
        'focusedWindowOpacity': appearance.focusedWindowOpacity,
        'unfocusedWindowOpacity': appearance.unfocusedWindowOpacity,
        'cursorSize': appearance.cursorSize,
        'cursorThemeId': appearance.cursorThemeId,
        'allowClientCursorSurfaces': appearance.allowClientCursorSurfaces,
      },
      'layout': <String, Object>{
        'windowLayout': layout.windowLayout.name,
        if (layout.systemBarSide case final side?) 'systemBarSide': side.name,
        'systemBarOutputs': layout.systemBarOutputNames,
        'systemBarThickness': layout.systemBarThickness,
        'maximizePadding': layout.maximizePadding,
        'minimizedWindowPlacement': layout.minimizedWindowPlacement.name,
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
        'idleLockEnabled': power.idleLockEnabled,
        'idleLockTimeoutMinutes': power.idleLockTimeoutMinutes,
        'idleDpmsEnabled': power.idleDpmsEnabled,
        'idleDpmsTimeoutMinutes': power.idleDpmsTimeoutMinutes,
        'idleSuspendEnabled': power.idleSuspendEnabled,
        'idleSuspendTimeoutMinutes': power.idleSuspendTimeoutMinutes,
      },
      'applicationEnvironment': applicationEnvironment.toJson(),
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
    final legacyHoverTriggersEnabled = overlaysJson['hoverTriggersEnabled'];
    final launcherFallback = legacyHoverTriggersEnabled is bool
        ? defaults.overlays.launcher.copyWith(
            hoverTriggerEnabled: legacyHoverTriggersEnabled,
          )
        : defaults.overlays.launcher;
    final dashboardFallback = legacyHoverTriggersEnabled is bool
        ? defaults.overlays.dashboard.copyWith(
            hoverTriggerEnabled: legacyHoverTriggersEnabled,
          )
        : defaults.overlays.dashboard;
    var legacyCornerRadiusScale = defaults.appearance.cornerRadiusScale;
    if (appearanceJson.containsKey('panelRadius')) {
      legacyCornerRadiusScale =
          _number(
            appearanceJson['panelRadius'],
            ShellRadii.panel,
            0,
            ShellRadii.panel * ShellRoundness.maximum,
          ) /
          ShellRadii.panel;
    } else if (appearanceJson.containsKey('windowRadius')) {
      legacyCornerRadiusScale =
          _number(
            appearanceJson['windowRadius'],
            ShellRadii.window,
            0,
            ShellRadii.window * ShellRoundness.maximum,
          ) /
          ShellRadii.window;
    }
    final outputNames = <String>[];
    for (final value in _list(layoutJson['systemBarOutputs'])) {
      if (value is! String) {
        continue;
      }
      final outputName = value.trim();
      if (outputName.isNotEmpty) {
        outputNames.add(outputName);
      }
    }
    final idleDpmsTimeoutMinutes = _integer(
      powerJson['idleDpmsTimeoutMinutes'],
      defaults.power.idleDpmsTimeoutMinutes,
      ShellPowerSettings.minimumIdleTimeoutMinutes,
      ShellPowerSettings.maximumIdleTimeoutMinutes,
    );
    final idleSuspendTimeoutMinutes =
        _integer(
              powerJson['idleSuspendTimeoutMinutes'],
              defaults.power.idleSuspendTimeoutMinutes,
              ShellPowerSettings.minimumIdleTimeoutMinutes,
              ShellPowerSettings.maximumIdleTimeoutMinutes,
            )
            .clamp(
              idleDpmsTimeoutMinutes,
              ShellPowerSettings.maximumIdleTimeoutMinutes,
            )
            .toInt();
    final idleLockTimeoutMinutes =
        _integer(
              powerJson['idleLockTimeoutMinutes'],
              defaults.power.idleLockTimeoutMinutes,
              ShellPowerSettings.minimumIdleTimeoutMinutes,
              ShellPowerSettings.maximumIdleTimeoutMinutes,
            )
            .clamp(
              ShellPowerSettings.minimumIdleTimeoutMinutes,
              idleSuspendTimeoutMinutes,
            )
            .toInt();
    return ShellSettings(
      localization: ShellLocalizationSettings(
        locale: _enumValue(
          ShellLocalePreference.values,
          localizationJson['locale'],
          defaults.localization.locale,
        ),
      ),
      appearance: ShellAppearanceSettings(
        colorSchemePreference: _enumValue(
          DesktopColorSchemePreference.values,
          appearanceJson['colorSchemePreference'],
          defaults.appearance.colorSchemePreference,
        ),
        accentSource: _enumValue(
          ShellAccentSource.values,
          appearanceJson['accentSource'],
          defaults.appearance.accentSource,
        ),
        customAccentColor: _color(
          appearanceJson['customAccentColor'],
          defaults.appearance.customAccentColor,
        ),
        cornerRadiusScale: _number(
          appearanceJson['cornerRadiusScale'],
          legacyCornerRadiusScale,
          ShellRoundness.minimum,
          ShellRoundness.maximum,
        ),
        panelOpacity: _number(
          appearanceJson['panelOpacity'],
          defaults.appearance.panelOpacity,
          ShellOpacity.minimumPanel,
          1,
        ),
        cardOpacity: _number(
          appearanceJson['cardOpacity'],
          defaults.appearance.cardOpacity,
          ShellOpacity.minimumCard,
          1,
        ),
        backdropBlurEnabled: appearanceJson['backdropBlurEnabled'] is bool
            ? appearanceJson['backdropBlurEnabled'] as bool
            : defaults.appearance.backdropBlurEnabled,
        backdropBlurLevel: _enumValue(
          ShellBackdropBlurLevel.values,
          appearanceJson['backdropBlurLevel'],
          defaults.appearance.backdropBlurLevel,
        ),
        backdropBlurOpacityThreshold: _number(
          appearanceJson['backdropBlurPixelOpacityThreshold'],
          defaults.appearance.backdropBlurOpacityThreshold,
          0,
          1,
        ),
        focusedWindowBorderEnabled:
            appearanceJson['focusedWindowBorderEnabled'] is bool
            ? appearanceJson['focusedWindowBorderEnabled'] as bool
            : defaults.appearance.focusedWindowBorderEnabled,
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
        cursorThemeId: _cursorThemeId(
          appearanceJson['cursorThemeId'],
          defaults.appearance.cursorThemeId,
        ),
        allowClientCursorSurfaces:
            appearanceJson['allowClientCursorSurfaces'] is bool
            ? appearanceJson['allowClientCursorSurfaces'] as bool
            : defaults.appearance.allowClientCursorSurfaces,
      ),
      layout: ShellLayoutSettings(
        windowLayout: _enumValue(
          DesktopWindowLayout.values,
          layoutJson['windowLayout'],
          defaults.layout.windowLayout,
        ),
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
        minimizedWindowPlacement: _enumValue(
          MinimizedWindowPlacement.values,
          layoutJson['minimizedWindowPlacement'],
          defaults.layout.minimizedWindowPlacement,
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
          launcherFallback,
          minWidth: 420,
          minHeight: launcherOverlayMinimumHeight,
        ),
        dashboard: _placement(
          overlaysJson['dashboard'],
          dashboardFallback,
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
        idleLockEnabled: powerJson['idleLockEnabled'] is bool
            ? powerJson['idleLockEnabled'] as bool
            : defaults.power.idleLockEnabled,
        idleLockTimeoutMinutes: idleLockTimeoutMinutes,
        idleDpmsEnabled: powerJson['idleDpmsEnabled'] is bool
            ? powerJson['idleDpmsEnabled'] as bool
            : defaults.power.idleDpmsEnabled,
        idleDpmsTimeoutMinutes: idleDpmsTimeoutMinutes,
        idleSuspendEnabled: powerJson['idleSuspendEnabled'] is bool
            ? powerJson['idleSuspendEnabled'] as bool
            : defaults.power.idleSuspendEnabled,
        idleSuspendTimeoutMinutes: idleSuspendTimeoutMinutes,
      ),
      applicationEnvironment: ShellApplicationEnvironmentSettings.fromJson(
        json['applicationEnvironment'],
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
        other.power == power &&
        other.applicationEnvironment == applicationEnvironment;
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
    applicationEnvironment,
  );
}

Map<String, Object> _placementToJson(ShellPopupPlacement placement) {
  return <String, Object>{
    'anchor': placement.anchor.name,
    'width': placement.width,
    'height': placement.height,
    'margin': placement.margin,
    'hoverTriggerEnabled': placement.hoverTriggerEnabled,
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
    hoverTriggerEnabled: json['hoverTriggerEnabled'] is bool
        ? json['hoverTriggerEnabled'] as bool
        : fallback.hoverTriggerEnabled,
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

String _cursorThemeId(Object? value, String fallback) {
  if (value is! String) {
    return fallback;
  }
  final id = value.trim();
  if (id.isEmpty || id.length > 128 || id.contains('\u0000')) {
    return fallback;
  }
  return id;
}
