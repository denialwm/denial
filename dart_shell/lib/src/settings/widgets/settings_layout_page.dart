import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../shell_settings.dart';
import 'settings_controls.dart';
import 'system_bar_placement_card.dart';

class SettingsLayoutPage extends StatelessWidget {
  const SettingsLayoutPage({
    required this.settings,
    required this.displayLayout,
    required this.onWindowLayoutChanged,
    required this.onSystemBarChanged,
    required this.onSystemBarThicknessChanged,
    required this.onMaximizePaddingChanged,
    required this.onMinimizedWindowPlacementChanged,
    required this.onClipboardTrayEdgeChanged,
    required this.onClipboardTrayExtentChanged,
    required this.onReset,
    super.key,
  });

  final ShellLayoutSettings settings;
  final DisplayLayout? displayLayout;
  final ValueChanged<DesktopWindowLayout> onWindowLayoutChanged;
  final SystemBarPlacementChanged onSystemBarChanged;
  final ValueChanged<double> onSystemBarThicknessChanged;
  final ValueChanged<double> onMaximizePaddingChanged;
  final ValueChanged<MinimizedWindowPlacement>
  onMinimizedWindowPlacementChanged;
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
            SettingsSection(
              title: l10n.settingsWindowLayoutTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingsSegmentedControl<DesktopWindowLayout>(
                    value: settings.windowLayout,
                    choices: [
                      SettingsChoice(
                        DesktopWindowLayout.stacking,
                        l10n.settingsWindowLayoutStacking,
                      ),
                      SettingsChoice(
                        DesktopWindowLayout.dwindle,
                        l10n.settingsWindowLayoutDwindle,
                      ),
                    ],
                    onChanged: onWindowLayoutChanged,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.settingsWindowLayoutDescription,
                    style: ShellText.base.copyWith(
                      color: ShellTheme.colorsOf(context).textSecondary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
              title: l10n.settingsWindowMinimizationTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingsSegmentedControl<MinimizedWindowPlacement>(
                    value: settings.minimizedWindowPlacement,
                    choices: [
                      SettingsChoice(
                        MinimizedWindowPlacement.desktop,
                        l10n.settingsWindowMinimizationDesktop,
                      ),
                      SettingsChoice(
                        MinimizedWindowPlacement.offscreen,
                        l10n.settingsWindowMinimizationOffscreen,
                      ),
                    ],
                    onChanged: onMinimizedWindowPlacementChanged,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.settingsWindowMinimizationDescription,
                    style: ShellText.base.copyWith(
                      color: ShellTheme.colorsOf(context).textSecondary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
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
