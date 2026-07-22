import 'package:flutter/material.dart';

import '../../models/display_layout.dart';
import '../shell_settings.dart';
import 'settings_controls.dart';
import 'system_bar_placement_card.dart';

class SettingsLayoutPage extends StatelessWidget {
  const SettingsLayoutPage({
    required this.settings,
    required this.displayLayout,
    required this.onSystemBarChanged,
    required this.onSystemBarThicknessChanged,
    required this.onMaximizePaddingChanged,
    required this.onReset,
    super.key,
  });

  final ShellLayoutSettings settings;
  final DisplayLayout? displayLayout;
  final SystemBarPlacementChanged onSystemBarChanged;
  final ValueChanged<double> onSystemBarThicknessChanged;
  final ValueChanged<double> onMaximizePaddingChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return SettingsPageLayout(
      icon: Icons.space_dashboard_outlined,
      eyebrow: 'Desktop layout',
      title: 'Make every pixel intentional.',
      description:
          'Configure the reserved shell area and the breathing room around maximized windows.',
      onReset: onReset,
      children: [
        SystemBarPlacementCard(
          layout: displayLayout,
          onChanged: onSystemBarChanged,
        ),
        SettingsCard(
          title: 'System bar geometry',
          description:
              'The reserved strip and its cards resize together on every selected display.',
          child: SettingsSlider(
            label: 'Bar thickness',
            value: settings.systemBarThickness,
            minimum: 24,
            maximum: 112,
            divisions: 88,
            valueLabel: '${settings.systemBarThickness.round()} px',
            onChanged: onSystemBarThicknessChanged,
          ),
        ),
        SettingsCard(
          title: 'Maximized window spacing',
          description:
              'Add a gap along output edges that are not occupied by the system bar. Fullscreen remains edge-to-edge.',
          child: SettingsSlider(
            label: 'Outer padding',
            value: settings.maximizePadding,
            minimum: 0,
            maximum: 64,
            divisions: 64,
            valueLabel: '${settings.maximizePadding.round()} px',
            onChanged: onMaximizePaddingChanged,
          ),
        ),
      ],
    );
  }
}
