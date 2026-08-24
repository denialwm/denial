import 'package:flutter/foundation.dart';

@immutable
class DenialKeyboardLayout {
  const DenialKeyboardLayout({
    required this.layout,
    this.variant = '',
    this.displayName = '',
  });

  final String layout;
  final String variant;
  final String displayName;

  factory DenialKeyboardLayout.fromJson(Map<String, Object?> json) {
    return DenialKeyboardLayout(
      layout: json['layout'] as String? ?? '',
      variant: json['variant'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
    );
  }

  Map<String, Object> toApplyJson() => <String, Object>{
    'layout': layout,
    'variant': variant,
  };

  String get label => displayName.isNotEmpty
      ? displayName
      : variant.isEmpty
      ? layout
      : '$layout ($variant)';

  DenialKeyboardLayout copyWith({
    String? layout,
    String? variant,
    String? displayName,
  }) {
    return DenialKeyboardLayout(
      layout: layout ?? this.layout,
      variant: variant ?? this.variant,
      displayName: displayName ?? this.displayName,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DenialKeyboardLayout &&
        other.layout == layout &&
        other.variant == variant &&
        other.displayName == displayName;
  }

  @override
  int get hashCode => Object.hash(layout, variant, displayName);
}

@immutable
class DenialKeyboardConfiguration {
  const DenialKeyboardConfiguration({
    required this.revision,
    required this.layouts,
    required this.options,
    required this.repeatDelayMs,
    required this.repeatRateHz,
    required this.activeLayout,
  });

  const DenialKeyboardConfiguration.defaults()
    : revision = 0,
      layouts = const <DenialKeyboardLayout>[
        DenialKeyboardLayout(layout: 'us', displayName: 'English (US)'),
      ],
      options = const <String>[],
      repeatDelayMs = 600,
      repeatRateHz = 25,
      activeLayout = 0;

  final int revision;
  final List<DenialKeyboardLayout> layouts;
  final List<String> options;
  final int repeatDelayMs;
  final int repeatRateHz;
  final int activeLayout;

  factory DenialKeyboardConfiguration.fromJson(Map<String, Object?> json) {
    final layouts = (json['layouts'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<String, Object?>>()
        .map(DenialKeyboardLayout.fromJson)
        .toList(growable: false);
    final activeLayout = json['active_layout'] as int? ?? 0;
    if (layouts.isEmpty || activeLayout < 0 || activeLayout >= layouts.length) {
      throw const FormatException('invalid keyboard layout configuration');
    }
    return DenialKeyboardConfiguration(
      revision: json['revision'] as int? ?? 0,
      layouts: List<DenialKeyboardLayout>.unmodifiable(layouts),
      options: List<String>.unmodifiable(
        (json['options'] as List<Object?>? ?? const <Object?>[])
            .whereType<String>(),
      ),
      repeatDelayMs: json['repeat_delay_ms'] as int? ?? 600,
      repeatRateHz: json['repeat_rate_hz'] as int? ?? 25,
      activeLayout: activeLayout,
    );
  }

  Map<String, Object> toApplyJson() => <String, Object>{
    'layouts': <Map<String, Object>>[
      for (final layout in layouts) layout.toApplyJson(),
    ],
    'options': options,
    'repeatDelayMs': repeatDelayMs,
    'repeatRateHz': repeatRateHz,
  };

  DenialKeyboardLayout get active => layouts[activeLayout];

  DenialKeyboardConfiguration copyWith({
    int? revision,
    List<DenialKeyboardLayout>? layouts,
    List<String>? options,
    int? repeatDelayMs,
    int? repeatRateHz,
    int? activeLayout,
  }) {
    return DenialKeyboardConfiguration(
      revision: revision ?? this.revision,
      layouts: List<DenialKeyboardLayout>.unmodifiable(layouts ?? this.layouts),
      options: List<String>.unmodifiable(options ?? this.options),
      repeatDelayMs: repeatDelayMs ?? this.repeatDelayMs,
      repeatRateHz: repeatRateHz ?? this.repeatRateHz,
      activeLayout: activeLayout ?? this.activeLayout,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DenialKeyboardConfiguration &&
        other.revision == revision &&
        listEquals(other.layouts, layouts) &&
        listEquals(other.options, options) &&
        other.repeatDelayMs == repeatDelayMs &&
        other.repeatRateHz == repeatRateHz &&
        other.activeLayout == activeLayout;
  }

  @override
  int get hashCode => Object.hash(
    revision,
    Object.hashAll(layouts),
    Object.hashAll(options),
    repeatDelayMs,
    repeatRateHz,
    activeLayout,
  );
}
