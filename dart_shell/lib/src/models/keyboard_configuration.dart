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
