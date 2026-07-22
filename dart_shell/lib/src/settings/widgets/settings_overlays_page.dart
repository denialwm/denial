import 'package:flutter/material.dart';

import '../../models/shell_popup_placement.dart';
import '../shell_settings.dart';
import 'settings_controls.dart';

class SettingsOverlaysPage extends StatelessWidget {
  const SettingsOverlaysPage({
    required this.settings,
    required this.onChanged,
    required this.onReset,
    super.key,
  });

  final ShellOverlaySettings settings;
  final void Function(
    ShellOverlaySurface surface,
    ShellPopupPlacement placement,
  )
  onChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return SettingsPageLayout(
      icon: Icons.picture_in_picture_alt_outlined,
      eyebrow: 'Popups & overlays',
      title: 'Put transient UI where you expect it.',
      description:
          'Choose the screen anchor, dimensions, and edge distance for each desktop surface.',
      onReset: onReset,
      children: [
        _PlacementEditor(
          title: 'Application launcher',
          description:
              'The SUPER popup and its matching pressure-edge hover target.',
          surface: ShellOverlaySurface.launcher,
          placement: settings.launcher,
          onChanged: onChanged,
          minimumWidth: 420,
          minimumHeight: 360,
        ),
        _PlacementEditor(
          title: 'Desktop dashboard',
          description:
              'Quick settings, wallpaper controls, power modes, and notifications.',
          surface: ShellOverlaySurface.dashboard,
          placement: settings.dashboard,
          onChanged: onChanged,
          minimumWidth: 320,
          minimumHeight: 360,
        ),
        _PlacementEditor(
          title: 'Notification banners',
          description:
              'Incoming notification cards. Height adapts to visible content.',
          surface: ShellOverlaySurface.notifications,
          placement: settings.notifications,
          onChanged: onChanged,
          minimumWidth: 280,
          minimumHeight: 200,
          showHeight: false,
        ),
        _PlacementEditor(
          title: 'Volume & brightness HUD',
          description:
              'The compact hardware-key feedback surface on the active output.',
          surface: ShellOverlaySurface.systemHud,
          placement: settings.systemHud,
          onChanged: onChanged,
          minimumWidth: 220,
          minimumHeight: 64,
          showHeight: false,
        ),
      ],
    );
  }
}

class _PlacementEditor extends StatelessWidget {
  const _PlacementEditor({
    required this.title,
    required this.description,
    required this.surface,
    required this.placement,
    required this.onChanged,
    required this.minimumWidth,
    required this.minimumHeight,
    this.showHeight = true,
  });

  final String title;
  final String description;
  final ShellOverlaySurface surface;
  final ShellPopupPlacement placement;
  final void Function(
    ShellOverlaySurface surface,
    ShellPopupPlacement placement,
  )
  onChanged;
  final double minimumWidth;
  final double minimumHeight;
  final bool showHeight;

  @override
  Widget build(BuildContext context) {
    void update(ShellPopupPlacement value) => onChanged(surface, value);
    return SettingsCard(
      title: title,
      description: description,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final controls = Expanded(
            child: Column(
              children: [
                SettingsSlider(
                  label: 'Width',
                  value: placement.width,
                  minimum: minimumWidth,
                  maximum: 1400,
                  divisions: ((1400 - minimumWidth) / 10).round(),
                  valueLabel: '${placement.width.round()} px',
                  onChanged: (value) =>
                      update(placement.copyWith(width: value)),
                ),
                if (showHeight) ...[
                  const SizedBox(height: 6),
                  SettingsSlider(
                    label: 'Height',
                    value: placement.height,
                    minimum: minimumHeight,
                    maximum: 1200,
                    divisions: ((1200 - minimumHeight) / 10).round(),
                    valueLabel: '${placement.height.round()} px',
                    onChanged: (value) =>
                        update(placement.copyWith(height: value)),
                  ),
                ],
                const SizedBox(height: 6),
                SettingsSlider(
                  label: 'Edge distance',
                  value: placement.margin,
                  minimum: 0,
                  maximum: 96,
                  divisions: 48,
                  valueLabel: '${placement.margin.round()} px',
                  onChanged: (value) =>
                      update(placement.copyWith(margin: value)),
                ),
              ],
            ),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsAnchorPicker(
                  value: placement.anchor,
                  onChanged: (anchor) =>
                      update(placement.copyWith(anchor: anchor)),
                ),
                const SizedBox(height: 16),
                Row(children: [controls]),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SettingsAnchorPicker(
                value: placement.anchor,
                onChanged: (anchor) =>
                    update(placement.copyWith(anchor: anchor)),
              ),
              const SizedBox(width: 22),
              controls,
            ],
          );
        },
      ),
    );
  }
}
