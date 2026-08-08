import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
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
    required this.onClipboardTrayEdgeChanged,
    required this.onClipboardTrayExtentChanged,
    required this.onReset,
    super.key,
  });

  final ShellLayoutSettings settings;
  final DisplayLayout? displayLayout;
  final SystemBarPlacementChanged onSystemBarChanged;
  final ValueChanged<double> onSystemBarThicknessChanged;
  final ValueChanged<double> onMaximizePaddingChanged;
  final ValueChanged<ClipboardTrayEdge> onClipboardTrayEdgeChanged;
  final ValueChanged<double> onClipboardTrayExtentChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPageLayout(
      icon: Icons.space_dashboard_outlined,
      eyebrow: l10n.settingsLayoutSection,
      title: l10n.settingsLayoutTitle,
      onReset: onReset,
      children: [
        SettingsCardGroup(
          children: [
            SystemBarPlacementCard(
              layout: displayLayout,
              onChanged: onSystemBarChanged,
            ),
            SettingsSection(
              title: l10n.settingsBarGeometryTitle,
              child: SettingsSlider(
                label: l10n.settingsBarThickness,
                value: settings.systemBarThickness,
                minimum: 24,
                maximum: 112,
                divisions: 88,
                valueLabel: l10n.settingsPixels(
                  settings.systemBarThickness.round(),
                ),
                onChanged: onSystemBarThicknessChanged,
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsMaximizedSpacingTitle,
              child: SettingsSlider(
                label: l10n.settingsOuterPadding,
                value: settings.maximizePadding,
                minimum: 0,
                maximum: 64,
                divisions: 64,
                valueLabel: l10n.settingsPixels(
                  settings.maximizePadding.round(),
                ),
                onChanged: onMaximizePaddingChanged,
              ),
            ),
            SettingsSection(
              title: 'Clipboard tray',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsSegmentedControl<ClipboardTrayEdge>(
                    value: settings.clipboardTrayEdge,
                    choices: const [
                      SettingsChoice(ClipboardTrayEdge.left, 'Left edge'),
                      SettingsChoice(ClipboardTrayEdge.right, 'Right edge'),
                      SettingsChoice(ClipboardTrayEdge.top, 'Top edge'),
                      SettingsChoice(ClipboardTrayEdge.bottom, 'Bottom edge'),
                    ],
                    onChanged: onClipboardTrayEdgeChanged,
                  ),
                  const SizedBox(height: 18),
                  SettingsSlider(
                    label: 'Tray size',
                    value: settings.clipboardTrayExtent,
                    minimum: clipboardTrayMinimumExtent,
                    maximum: clipboardTrayMaximumExtent,
                    divisions: 20,
                    valueLabel: l10n.settingsPixels(
                      settings.clipboardTrayExtent.round(),
                    ),
                    onChanged: onClipboardTrayExtentChanged,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
