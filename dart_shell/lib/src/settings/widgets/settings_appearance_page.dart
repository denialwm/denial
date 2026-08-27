import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../settings/shell_settings.dart';
import '../../theme/backdrop_blur_level.dart';
import '../../theme/cursor_theme_repository.dart';
import '../../theme/cursor_themes.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../wallpaper/wallpaper.dart';
import '../../wallpaper/widgets/wallpaper_image.dart';
import '../../widgets/shell_cursor.dart';
import 'settings_controls.dart';

const settingsWallpaperTriggerKey = ValueKey<String>(
  'settings-wallpaper-trigger',
);
const settingsAccentColorTriggerKey = ValueKey<String>(
  'settings-accent-color-trigger',
);
const settingsColorSchemeControlKey = ValueKey<String>(
  'settings-color-scheme-control',
);
const settingsBackdropBlurToggleKey = ValueKey<String>(
  'settings-backdrop-blur-toggle',
);
const settingsBackdropBlurSliderKey = ValueKey<String>(
  'settings-backdrop-blur-slider',
);
const settingsBackdropBlurOpacityThresholdKey = ValueKey<String>(
  'settings-backdrop-blur-opacity-threshold',
);
const settingsCursorSizeSliderKey = ValueKey<String>(
  'settings-cursor-size-slider',
);
const settingsCornerRoundnessSliderKey = ValueKey<String>(
  'settings-corner-roundness-slider',
);
const settingsCardOpacitySliderKey = ValueKey<String>(
  'settings-card-opacity-slider',
);

class SettingsAppearancePage extends StatelessWidget {
  const SettingsAppearancePage({
    required this.settings,
    required this.extractedAccent,
    required this.wallpaper,
    required this.onOpenWallpaperSelector,
    required this.onColorSchemePreferenceChanged,
    required this.onAccentSourceChanged,
    required this.onOpenAccentPicker,
    required this.onCornerRadiusScaleChanged,
    required this.onPanelOpacityChanged,
    required this.onCardOpacityChanged,
    required this.onBackdropBlurEnabledChanged,
    required this.onBackdropBlurLevelChanged,
    required this.onBackdropBlurOpacityThresholdChanged,
    required this.onFocusedWindowBorderEnabledChanged,
    required this.onFocusedOpacityChanged,
    required this.onUnfocusedOpacityChanged,
    required this.onCursorSizeChanged,
    required this.cursorThemes,
    required this.cursorCatalogLoading,
    required this.onCursorThemeChanged,
    required this.onAllowClientCursorSurfacesChanged,
    required this.onImportCursorZip,
    required this.onRemoveCursorTheme,
    required this.onReset,
    super.key,
  });

  final ShellAppearanceSettings settings;
  final Color extractedAccent;
  final WallpaperResource wallpaper;
  final VoidCallback onOpenWallpaperSelector;
  final ValueChanged<DesktopColorSchemePreference>
  onColorSchemePreferenceChanged;
  final ValueChanged<ShellAccentSource> onAccentSourceChanged;
  final VoidCallback onOpenAccentPicker;
  final ValueChanged<double> onCornerRadiusScaleChanged;
  final ValueChanged<double> onPanelOpacityChanged;
  final ValueChanged<double> onCardOpacityChanged;
  final ValueChanged<bool> onBackdropBlurEnabledChanged;
  final ValueChanged<ShellBackdropBlurLevel> onBackdropBlurLevelChanged;
  final ValueChanged<double> onBackdropBlurOpacityThresholdChanged;
  final ValueChanged<bool> onFocusedWindowBorderEnabledChanged;
  final ValueChanged<double> onFocusedOpacityChanged;
  final ValueChanged<double> onUnfocusedOpacityChanged;
  final ValueChanged<double> onCursorSizeChanged;
  final List<ShellCursorThemeData> cursorThemes;
  final bool cursorCatalogLoading;
  final ValueChanged<String> onCursorThemeChanged;
  final ValueChanged<bool> onAllowClientCursorSurfacesChanged;
  final Future<ShellCursorThemeData?> Function()? onImportCursorZip;
  final Future<void> Function(ShellCursorThemeData) onRemoveCursorTheme;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final effectiveAccent = settings.accentSource == ShellAccentSource.wallpaper
        ? extractedAccent
        : settings.customAccentColor;
    return SettingsPageLayout(
      icon: Icons.palette_outlined,
      eyebrow: l10n.settingsAppearanceSection,
      title: l10n.settingsAppearanceTitle,
      onReset: onReset,
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsColorSchemeTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingsSegmentedControl<DesktopColorSchemePreference>(
                    key: settingsColorSchemeControlKey,
                    value: settings.colorSchemePreference,
                    choices: [
                      SettingsChoice(
                        DesktopColorSchemePreference.preferDark,
                        l10n.settingsColorSchemeDark,
                      ),
                      SettingsChoice(
                        DesktopColorSchemePreference.preferLight,
                        l10n.settingsColorSchemeLight,
                      ),
                      SettingsChoice(
                        DesktopColorSchemePreference.noPreference,
                        l10n.settingsColorSchemeNoPreference,
                      ),
                    ],
                    onChanged: onColorSchemePreferenceChanged,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    settings.colorSchemePreference ==
                            DesktopColorSchemePreference.noPreference
                        ? l10n.settingsColorSchemeNoPreferenceDescription
                        : l10n.settingsColorSchemeDescription,
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
              title: l10n.settingsWallpaperTitle,
              leading: _WallpaperThumbnail(
                wallpaper: wallpaper,
                semanticsLabel: l10n.settingsWallpaperPreviewSemantics,
              ),
              trailing: SettingsTextButton(
                key: settingsWallpaperTriggerKey,
                label: l10n.settingsWallpaperChoose,
                onPressed: onOpenWallpaperSelector,
              ),
              child: Text(
                l10n.settingsWallpaperDescription,
                style: ShellText.base.copyWith(
                  color: ShellTheme.colorsOf(context).textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
            SettingsSection(
              title: l10n.settingsShellAccentTitle,
              leading: _ColorOrb(color: effectiveAccent),
              trailing: settings.accentSource == ShellAccentSource.custom
                  ? SettingsColorButton(
                      key: settingsAccentColorTriggerKey,
                      color: settings.customAccentColor,
                      label: l10n.settingsShellAccentChoose,
                      onPressed: onOpenAccentPicker,
                    )
                  : null,
              child: SettingsSegmentedControl<ShellAccentSource>(
                value: settings.accentSource,
                choices: [
                  SettingsChoice(
                    ShellAccentSource.wallpaper,
                    l10n.settingsShellAccentWallpaper,
                  ),
                  SettingsChoice(
                    ShellAccentSource.custom,
                    l10n.settingsShellAccentCustom,
                  ),
                ],
                onChanged: onAccentSourceChanged,
              ),
            ),
            SettingsSection(
              title: l10n.settingsBackdropBlur,
              child: Column(
                children: [
                  SettingsToggle(
                    key: settingsBackdropBlurToggleKey,
                    label: l10n.settingsBackdropBlurEnabled,
                    description: l10n.settingsBackdropBlurEnabledDescription,
                    value: settings.backdropBlurEnabled,
                    onChanged: onBackdropBlurEnabledChanged,
                  ),
                  const SizedBox(height: 12),
                  SettingsSlider(
                    key: settingsBackdropBlurSliderKey,
                    label: l10n.settingsBackdropBlurIntensity,
                    value: settings.backdropBlurLevel.index.toDouble(),
                    minimum: 0,
                    maximum: ShellBackdropBlurLevel.values.length - 1,
                    divisions: ShellBackdropBlurLevel.values.length - 1,
                    enabled: settings.backdropBlurEnabled,
                    valueLabel: _backdropBlurLevelLabel(
                      l10n,
                      settings.backdropBlurLevel,
                    ),
                    onChanged: (value) => onBackdropBlurLevelChanged(
                      ShellBackdropBlurLevel.values[value.round()],
                    ),
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    key: settingsBackdropBlurOpacityThresholdKey,
                    label: l10n.settingsBackdropBlurOpacityThreshold,
                    value: settings.backdropBlurOpacityThreshold,
                    minimum: 0,
                    maximum: 1,
                    divisions: 100,
                    enabled: settings.backdropBlurEnabled,
                    valueLabel: l10n.settingsPercent(
                      (settings.backdropBlurOpacityThreshold * 100).round(),
                    ),
                    onChanged: onBackdropBlurOpacityThresholdChanged,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsShapeTitle,
              child: Column(
                children: [
                  SettingsSlider(
                    key: settingsCornerRoundnessSliderKey,
                    label: l10n.settingsCornerRoundness,
                    value: settings.cornerRadiusScale,
                    minimum: ShellRoundness.minimum,
                    maximum: ShellRoundness.maximum,
                    divisions: 40,
                    valueLabel: l10n.settingsPercent(
                      (settings.cornerRadiusScale * 100).round(),
                    ),
                    onChanged: onCornerRadiusScaleChanged,
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsPanelOpacity,
                    value: settings.panelOpacity,
                    minimum: ShellOpacity.minimumPanel,
                    maximum: 1,
                    divisions: 95,
                    valueLabel: l10n.settingsPercent(
                      (settings.panelOpacity * 100).round(),
                    ),
                    onChanged: onPanelOpacityChanged,
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    key: settingsCardOpacitySliderKey,
                    label: l10n.settingsCardOpacity,
                    value: settings.cardOpacity,
                    minimum: ShellOpacity.minimumCard,
                    maximum: 1,
                    divisions: 95,
                    valueLabel: l10n.settingsPercent(
                      (settings.cardOpacity * 100).round(),
                    ),
                    onChanged: onCardOpacityChanged,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsCursorTitle,
              child: _CursorSettings(
                settings: settings,
                themes: cursorThemes,
                catalogLoading: cursorCatalogLoading,
                onThemeChanged: onCursorThemeChanged,
                onSizeChanged: onCursorSizeChanged,
                onAllowClientCursorSurfacesChanged:
                    onAllowClientCursorSurfacesChanged,
                onImport: onImportCursorZip,
                onRemove: onRemoveCursorTheme,
              ),
            ),
            SettingsSection(
              title: l10n.settingsWindowOpacityTitle,
              child: Column(
                children: [
                  SettingsToggle(
                    label: l10n.settingsFocusedWindowBorder,
                    description: l10n.settingsFocusedWindowBorderDescription,
                    value: settings.focusedWindowBorderEnabled,
                    onChanged: onFocusedWindowBorderEnabledChanged,
                  ),
                  const SizedBox(height: 12),
                  SettingsSlider(
                    label: l10n.settingsFocusedWindows,
                    value: settings.focusedWindowOpacity,
                    minimum: 0.35,
                    maximum: 1,
                    divisions: 65,
                    valueLabel: l10n.settingsPercent(
                      (settings.focusedWindowOpacity * 100).round(),
                    ),
                    onChanged: onFocusedOpacityChanged,
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsUnfocusedWindows,
                    value: settings.unfocusedWindowOpacity,
                    minimum: 0.2,
                    maximum: 1,
                    divisions: 80,
                    valueLabel: l10n.settingsPercent(
                      (settings.unfocusedWindowOpacity * 100).round(),
                    ),
                    onChanged: onUnfocusedOpacityChanged,
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

class _CursorSettings extends StatefulWidget {
  const _CursorSettings({
    required this.settings,
    required this.themes,
    required this.catalogLoading,
    required this.onThemeChanged,
    required this.onSizeChanged,
    required this.onAllowClientCursorSurfacesChanged,
    required this.onImport,
    required this.onRemove,
  });

  final ShellAppearanceSettings settings;
  final List<ShellCursorThemeData> themes;
  final bool catalogLoading;
  final ValueChanged<String> onThemeChanged;
  final ValueChanged<double> onSizeChanged;
  final ValueChanged<bool> onAllowClientCursorSurfacesChanged;
  final Future<ShellCursorThemeData?> Function()? onImport;
  final Future<void> Function(ShellCursorThemeData) onRemove;

  @override
  State<_CursorSettings> createState() => _CursorSettingsState();
}

class _CursorSettingsState extends State<_CursorSettings> {
  bool _busy = false;
  String? _error;

  Future<void> _import() async {
    final importer = widget.onImport;
    if (importer == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await importer();
    } on CursorThemeException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = context.l10n.settingsCursorImportFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _remove(ShellCursorThemeData theme) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRemove(theme);
    } on CursorThemeException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = context.l10n.settingsCursorRemoveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settingsCursorTheme,
            style: ShellText.cardTitle.copyWith(
              color: context.shellColors.textSecondary,
            ),
          ),
          const SizedBox(height: 9),
          if (widget.catalogLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final theme in widget.themes)
                  _CursorThemeCard(
                    theme: theme,
                    selected: theme.id == widget.settings.cursorThemeId,
                    enabled: !_busy,
                    onSelected: () => widget.onThemeChanged(theme.id),
                    onRemove: theme.isImported ? () => _remove(theme) : null,
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SettingsTextButton(
              label: _busy
                  ? l10n.settingsCursorImporting
                  : l10n.settingsCursorImport,
              onPressed: widget.onImport == null || _busy ? null : _import,
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: ShellText.base.copyWith(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 11,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SettingsSlider(
            key: settingsCursorSizeSliderKey,
            label: l10n.settingsCursorSize,
            value: widget.settings.cursorSize,
            minimum: shellCursorMinimumSize,
            maximum: shellCursorMaximumSize,
            divisions: ((shellCursorMaximumSize - shellCursorMinimumSize) / 4)
                .round(),
            valueLabel: l10n.settingsPixels(widget.settings.cursorSize.round()),
            onChanged: widget.onSizeChanged,
          ),
          const SizedBox(height: 12),
          SettingsToggle(
            label: l10n.settingsCursorAllowApplications,
            description: l10n.settingsCursorAllowApplicationsDescription,
            value: widget.settings.allowClientCursorSurfaces,
            onChanged: widget.onAllowClientCursorSurfacesChanged,
          ),
        ],
      ),
    );
  }
}

class _CursorThemeCard extends StatefulWidget {
  const _CursorThemeCard({
    required this.theme,
    required this.selected,
    required this.enabled,
    required this.onSelected,
    required this.onRemove,
  });

  final ShellCursorThemeData theme;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;
  final VoidCallback? onRemove;

  @override
  State<_CursorThemeCard> createState() => _CursorThemeCardState();
}

class _CursorThemeCardState extends State<_CursorThemeCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accent;
    final colors = context.shellColors;
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: enabled,
      label: widget.theme.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? ShellMouseCursors.link
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (enabled) {
                widget.onSelected();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onSelected : null,
          child: AnimatedOpacity(
            duration: Motion.tile,
            opacity: enabled ? 1 : 0.52,
            child: AnimatedContainer(
              duration: Motion.tile,
              width: 250,
              constraints: const BoxConstraints(minHeight: 124),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: widget.selected
                    ? theme.cardColor(
                        Color.alphaBlend(
                          accent.withAlpha(34),
                          colors.surfaceContainerHigh.withValues(alpha: 1),
                        ),
                      )
                    : theme.cardColor(colors.surfaceContainerHigh),
                borderRadius: context.shellTheme.borderRadius(12),
                border: Border.all(
                  color: widget.selected
                      ? accent
                      : _hovered || _focused
                      ? colors.panelHighlight
                      : colors.hairline,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.theme.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ShellText.cardTitle,
                            ),
                            if (!widget.theme.isImported &&
                                widget.theme.author.trim().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.theme.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ShellText.base.copyWith(
                                  color: colors.textTertiary,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (widget.onRemove case final remove?)
                        Tooltip(
                          message: context.l10n.settingsCursorRemove,
                          child: IconButton(
                            onPressed: enabled ? remove : null,
                            icon: const Icon(Icons.delete_outline_rounded),
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                          ),
                        )
                      else if (widget.selected)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: accent,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  RepaintBoundary(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final kind in const <ShellCursorKind>[
                          ShellCursorKind.normal,
                          ShellCursorKind.link,
                          ShellCursorKind.text,
                          ShellCursorKind.working,
                          ShellCursorKind.busy,
                        ])
                          SizedBox.square(
                            dimension: 34,
                            child: Center(
                              child: ShellCursorArtwork(
                                theme: widget.theme,
                                kind: kind,
                                longestEdge: 28,
                                running: enabled,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _backdropBlurLevelLabel(
  AppLocalizations l10n,
  ShellBackdropBlurLevel level,
) {
  return switch (level) {
    ShellBackdropBlurLevel.shitty => l10n.settingsBackdropBlurLevelShitty,
    ShellBackdropBlurLevel.fast => l10n.settingsBackdropBlurLevelFast,
    ShellBackdropBlurLevel.good => l10n.settingsBackdropBlurLevelGood,
    ShellBackdropBlurLevel.best => l10n.settingsBackdropBlurLevelBest,
  };
}

class _WallpaperThumbnail extends StatelessWidget {
  const _WallpaperThumbnail({
    required this.wallpaper,
    required this.semanticsLabel,
  });

  final WallpaperResource wallpaper;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final radius = context.shellTheme.borderRadius(10);
    return Semantics(
      image: true,
      label: semanticsLabel,
      child: Container(
        width: 54,
        height: 40,
        foregroundDecoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: context.shellColors.hairline),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Image(
            image: wallpaperImageProvider(
              wallpaper,
              targetPixelSize:
                  const Size(54, 40) * MediaQuery.devicePixelRatioOf(context),
            ),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => ColoredBox(
              color: context.shellColors.surfaceContainerHighest,
              child: Icon(
                Icons.wallpaper_rounded,
                size: 20,
                color: ShellTheme.of(context).accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorOrb extends StatelessWidget {
  const _ColorOrb({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: context.shellColors.panelHighlight),
        boxShadow: [BoxShadow(color: color.withAlpha(48), blurRadius: 18)],
      ),
    );
  }
}
