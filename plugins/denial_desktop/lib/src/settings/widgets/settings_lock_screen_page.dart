import 'package:denial_flutter_sdk/materials.dart';

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';
import 'package:denial_flutter_sdk/settings.dart';

import 'settings_controls.dart';
import 'settings_lock_pin_section.dart';

class SettingsLockScreenPage extends StatelessWidget {
  const SettingsLockScreenPage({
    required this.settings,
    required this.wallpaper,
    required this.onUseWallpaperChanged,
    required this.onDimChanged,
    required this.onBlurChanged,
    required this.onClockScaleChanged,
    required this.onShowStatusChanged,
    required this.onReset,
    super.key,
  });

  final ShellLockScreenSettings settings;
  final WallpaperResource wallpaper;
  final ValueChanged<bool> onUseWallpaperChanged;
  final ValueChanged<double> onDimChanged;
  final ValueChanged<double> onBlurChanged;
  final ValueChanged<double> onClockScaleChanged;
  final ValueChanged<bool> onShowStatusChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPageLayout(
      icon: Icons.lock_outline_rounded,
      eyebrow: l10n.settingsLockScreenSection,
      title: l10n.settingsLockScreenTitle,
      onReset: onReset,
      children: [
        _LockPreview(settings: settings, wallpaper: wallpaper),
        const SettingsCardGroup(children: [SettingsLockPinSection()]),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsLockBackdropTitle,
              child: Column(
                children: [
                  SettingsToggle(
                    label: l10n.settingsUseSystemWallpaper,
                    description: l10n.settingsUseSystemWallpaperDescription,
                    value: settings.useSystemWallpaper,
                    onChanged: onUseWallpaperChanged,
                  ),
                  const SizedBox(height: 18),
                  SettingsSlider(
                    label: l10n.settingsBackdropDimming,
                    value: settings.dimAmount,
                    minimum: 0,
                    maximum: 0.85,
                    divisions: 85,
                    valueLabel: l10n.settingsPercent(
                      (settings.dimAmount * 100).round(),
                    ),
                    onChanged: onDimChanged,
                  ),
                  const SizedBox(height: 6),
                  SettingsSlider(
                    label: l10n.settingsBackdropBlur,
                    value: settings.blurRadius,
                    minimum: 0,
                    maximum: 32,
                    divisions: 32,
                    valueLabel: l10n.settingsPixels(
                      settings.blurRadius.round(),
                    ),
                    onChanged: onBlurChanged,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsLockInformationTitle,
              child: Column(
                children: [
                  SettingsSlider(
                    label: l10n.settingsClockScale,
                    value: settings.clockScale,
                    minimum: 0.65,
                    maximum: 1.4,
                    divisions: 75,
                    valueLabel: l10n.settingsPercent(
                      (settings.clockScale * 100).round(),
                    ),
                    onChanged: onClockScaleChanged,
                  ),
                  const SizedBox(height: 18),
                  SettingsToggle(
                    label: l10n.settingsShowSystemStatus,
                    description: l10n.settingsShowSystemStatusDescription,
                    value: settings.showSystemStatus,
                    onChanged: onShowStatusChanged,
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

class _LockPreview extends StatelessWidget {
  const _LockPreview({required this.settings, required this.wallpaper});

  final ShellLockScreenSettings settings;
  final WallpaperResource wallpaper;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;
    return Semantics(
      image: true,
      label: l10n.settingsLockPreviewSemantics,
      child: AspectRatio(
        aspectRatio: 16 / 7,
        child: ClipRRect(
          borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      context.shellColors.surfaceContainerHigh,
                      context.shellColors.background,
                    ],
                  ),
                ),
              ),
              if (settings.useSystemWallpaper)
                ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: settings.blurRadius / 2,
                    sigmaY: settings.blurRadius / 2,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Image(
                      image: wallpaperImageProvider(
                        wallpaper,
                        targetPixelSize:
                            constraints.biggest *
                            MediaQuery.devicePixelRatioOf(context),
                      ),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ColoredBox(
                color: ShellMediaColors.darkness.withValues(
                  alpha: settings.dimAmount,
                ),
              ),
              Positioned(
                left: 26,
                top: 20,
                child: Transform.scale(
                  alignment: Alignment.topLeft,
                  scale: settings.clockScale.clamp(0.65, 1.4).toDouble(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.settingsLockPreviewTime,
                        style: ShellText.lockClock.copyWith(fontSize: 54),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        l10n.settingsLockPreviewDate,
                        style: ShellText.lockDate.copyWith(fontSize: 13),
                      ),
                      if (settings.showSystemStatus) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.settingsLockPreviewStatus,
                          style: ShellText.lockStatus.copyWith(fontSize: 10),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 24,
                top: 22,
                bottom: 22,
                width: 168,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.shellColors.panelBackgroundBottom,
                    borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
                    border: Border.all(color: accent.withAlpha(96)),
                    boxShadow: [
                      BoxShadow(
                        color: context.shellColors.shadow,
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 18,
                          color: accent,
                        ),
                        const Spacer(),
                        Text(
                          l10n.lockWelcomeBack,
                          style: ShellText.cardTitle.copyWith(fontSize: 14),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          l10n.lockPressEnter,
                          style: ShellText.base.copyWith(
                            color: context.applicationColors.secondary,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
