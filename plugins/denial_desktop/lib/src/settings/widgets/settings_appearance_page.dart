import 'dart:math' as math;

import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import 'settings_controls.dart';
import 'settings_glass_tuning_controls.dart';
import 'settings_wallpaper_card.dart';

const settingsWallpaperTriggerKey = ValueKey<String>(
  'settings-wallpaper-trigger',
);
const settingsAccentColorTriggerKey = ValueKey<String>(
  'settings-accent-color-trigger',
);
const settingsColorSchemeControlKey = ValueKey<String>(
  'settings-color-scheme-control',
);
const settingsFontFamilyControlKey = ValueKey<String>(
  'settings-font-family-control',
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

class SettingsAppearancePage extends StatefulWidget {
  const SettingsAppearancePage({
    required this.settings,
    required this.extractedAccent,
    required this.wallpaper,
    this.wallpaperApps,
    this.wallpaperOutputName,
    required this.onOpenWallpaperSelector,
    required this.onColorSchemePreferenceChanged,
    required this.onAccentSourceChanged,
    required this.onOpenAccentPicker,
    required this.fontFamilies,
    required this.fontCatalogLoading,
    required this.onFontFamilyChanged,
    required this.onCornerRadiusScaleChanged,
    required this.onPanelOpacityChanged,
    required this.onCardOpacityChanged,
    required this.onTransparencyModeChanged,
    required this.onBackdropBlurLevelChanged,
    required this.onBackdropBlurOpacityThresholdChanged,
    required this.onGlassChanged,
    required this.onApplicationThemingEnabledChanged,
    required this.onReapplyApplicationTheming,
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
    this.mobile = false,
    super.key,
  });

  final ShellAppearanceSettings settings;
  final Color extractedAccent;
  final WallpaperResource wallpaper;
  final List<String>? wallpaperApps;
  final String? wallpaperOutputName;
  final VoidCallback onOpenWallpaperSelector;
  final ValueChanged<DesktopColorSchemePreference>
  onColorSchemePreferenceChanged;
  final ValueChanged<ShellAccentSource> onAccentSourceChanged;
  final VoidCallback onOpenAccentPicker;
  final List<String> fontFamilies;
  final bool fontCatalogLoading;
  final ValueChanged<String> onFontFamilyChanged;
  final ValueChanged<double> onCornerRadiusScaleChanged;
  final ValueChanged<double> onPanelOpacityChanged;
  final ValueChanged<double> onCardOpacityChanged;
  final ValueChanged<ShellTransparencyMode> onTransparencyModeChanged;
  final ValueChanged<ShellBackdropBlurLevel> onBackdropBlurLevelChanged;
  final ValueChanged<double> onBackdropBlurOpacityThresholdChanged;
  final ValueChanged<ShellGlassConfiguration> onGlassChanged;
  final ValueChanged<bool> onApplicationThemingEnabledChanged;
  final VoidCallback onReapplyApplicationTheming;
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

  /// Settings runs on a phone, under the mobile shell.
  final bool mobile;

  @override
  State<SettingsAppearancePage> createState() => _SettingsAppearancePageState();
}

class _SettingsAppearancePageState extends State<SettingsAppearancePage> {
  String? _cursorError;

  Widget _applicationThemingControls(BuildContext context) {
    final l10n = context.l10n;
    return SettingsCardPadding(
      child: SettingsControlRow(
        label: l10n.settingsApplicationThemingEnabled,
        description: l10n.settingsApplicationThemingDescription,
        control: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('settings-application-theming-reapply'),
              onPressed: widget.settings.applicationThemingEnabled
                  ? widget.onReapplyApplicationTheming
                  : null,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.settingsApplicationThemingReapply),
            ),
            const SizedBox(height: 10),
            SettingsToggle(
              key: const ValueKey('settings-application-theming'),
              label: l10n.settingsApplicationThemingEnabled,
              description: l10n.settingsApplicationThemingDescription,
              showLabel: false,
              value: widget.settings.applicationThemingEnabled,
              onChanged: widget.onApplicationThemingEnabledChanged,
            ),
          ],
        ),
      ),
    );
  }

  void _resetGlassEffects() {
    final glass = widget.settings.glass;
    widget.onGlassChanged(
      const ShellGlassConfiguration().copyWith(
        appearance: glass.appearance,
        opacity: glass.opacity,
        windowOpacity: glass.windowOpacity,
        appPanelOpacity: glass.appPanelOpacity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPageLayout(
      icon: Icons.palette_outlined,
      eyebrow: l10n.settingsAppearanceSection,
      title: l10n.settingsAppearanceTitle,
      cardSpacing: 20,
      commands: [
        PopupMenuButton<String>(
          tooltip: l10n.settingsAppearanceActions,
          icon: const Icon(Icons.more_horiz_rounded),
          onSelected: (action) {
            switch (action) {
              case 'appearance':
                widget.onReset();
              case 'glass':
                _resetGlassEffects();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'appearance',
              child: Text(l10n.settingsResetAppearance),
            ),
            if (widget.settings.transparencyMode == ShellTransparencyMode.glass)
              PopupMenuItem(
                key: const ValueKey('settings-glass-reset'),
                value: 'glass',
                child: Text(l10n.settingsResetGlassEffects),
              ),
          ],
        ),
      ],
      footer: SettingsErrorNotice(message: _cursorError),
      children: [
        SettingsWallpaperCard(
          chooseKey: settingsWallpaperTriggerKey,
          wallpaper: widget.wallpaper,
          wallpaperApps: widget.wallpaperApps,
          outputName: widget.wallpaperOutputName,
          onChoose: widget.onOpenWallpaperSelector,
        ),
        SettingsCardGroup(
          key: const ValueKey('appearance-theme-card'),
          title: l10n.settingsAppearanceTheme,
          children: [
            SettingsCardPadding(
              child: SettingsControlRow(
                label: l10n.settingsColorSchemeTitle,
                description:
                    widget.settings.colorSchemePreference ==
                        DesktopColorSchemePreference.noPreference
                    ? l10n.settingsColorSchemeNoPreferenceDescription
                    : l10n.settingsColorSchemeDescription,
                control: SettingsSegmentedControl<DesktopColorSchemePreference>(
                  key: settingsColorSchemeControlKey,
                  value: widget.settings.colorSchemePreference,
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
                  onChanged: widget.onColorSchemePreferenceChanged,
                ),
              ),
            ),
            SettingsCardPadding(
              child: SettingsControlRow(
                label: l10n.settingsShellAccentTitle,
                description: l10n.settingsShellAccentDescription,
                control: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SettingsSegmentedControl<ShellAccentSource>(
                      value: widget.settings.accentSource,
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
                      onChanged: widget.onAccentSourceChanged,
                    ),
                    if (widget.settings.accentSource ==
                        ShellAccentSource.custom) ...[
                      const SizedBox(height: 10),
                      SettingsColorButton(
                        key: settingsAccentColorTriggerKey,
                        color: widget.settings.customAccentColor,
                        label: l10n.settingsShellAccentChoose,
                        onPressed: widget.onOpenAccentPicker,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _applicationThemingControls(context),
          ],
        ),
        SettingsCardGroup(
          key: const ValueKey('appearance-typography-card'),
          title: l10n.settingsTypographyTitle,
          children: [
            SettingsCardPadding(
              child: SettingsSelect<String>(
                key: settingsFontFamilyControlKey,
                label: l10n.settingsFontFamily,
                description: widget.fontCatalogLoading
                    ? l10n.settingsFontCatalogLoading
                    : l10n.settingsFontDescription,
                value: widget.settings.fontFamily,
                choices: <SettingsChoice<String>>[
                  SettingsChoice('', l10n.settingsFontSystemDefault),
                  for (final family in _fontFamilyChoices(
                    widget.fontFamilies,
                    widget.settings.fontFamily,
                  ))
                    SettingsChoice(family, _fontFamilyLabel(family)),
                ],
                onChanged: widget.onFontFamilyChanged,
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          key: const ValueKey('appearance-windows-card'),
          title: l10n.settingsAppearanceWindows,
          children: [
            SettingsCardPadding(
              child: SettingsSlider(
                key: settingsCornerRoundnessSliderKey,
                label: l10n.settingsCornerRoundness,
                value: widget.settings.cornerRadiusScale,
                minimum: ShellRoundness.minimum,
                maximum: ShellRoundness.maximum,
                divisions: 40,
                valueLabel: l10n.settingsPercent(
                  (widget.settings.cornerRadiusScale * 100).round(),
                ),
                onChanged: widget.onCornerRadiusScaleChanged,
              ),
            ),
            SettingsCardPadding(
              child: SettingsToggle(
                label: l10n.settingsFocusedWindowBorder,
                description: l10n.settingsFocusedWindowBorderDescription,
                value: widget.settings.focusedWindowBorderEnabled,
                onChanged: widget.onFocusedWindowBorderEnabledChanged,
              ),
            ),
            SettingsDisclosure(
              key: const PageStorageKey('appearance-window-opacity'),
              title: l10n.settingsWindowOpacityTitle,
              description: l10n.settingsWindowOpacityDescription,
              children: [
                SettingsSlider(
                  label: l10n.settingsFocusedWindows,
                  value: widget.settings.focusedWindowOpacity,
                  minimum: 0.35,
                  maximum: 1,
                  divisions: 65,
                  valueLabel: l10n.settingsPercent(
                    (widget.settings.focusedWindowOpacity * 100).round(),
                  ),
                  onChanged: widget.onFocusedOpacityChanged,
                ),
                const SizedBox(height: 12),
                SettingsSlider(
                  label: l10n.settingsUnfocusedWindows,
                  value: widget.settings.unfocusedWindowOpacity,
                  minimum: 0.2,
                  maximum: 1,
                  divisions: 80,
                  valueLabel: l10n.settingsPercent(
                    (widget.settings.unfocusedWindowOpacity * 100).round(),
                  ),
                  onChanged: widget.onUnfocusedOpacityChanged,
                ),
              ],
            ),
          ],
        ),
        _transparencyCard(context),
        SettingsCardGroup(
          key: const ValueKey('appearance-cursor-card'),
          title: l10n.settingsCursorTitle,
          children: [
            _CursorSettings(
              settings: widget.settings,
              themes: widget.cursorThemes,
              catalogLoading: widget.cursorCatalogLoading,
              onThemeChanged: widget.onCursorThemeChanged,
              onSizeChanged: widget.onCursorSizeChanged,
              onAllowClientCursorSurfacesChanged:
                  widget.onAllowClientCursorSurfacesChanged,
              onImport: widget.onImportCursorZip,
              onRemove: widget.onRemoveCursorTheme,
              onError: (error) => setState(() => _cursorError = error),
            ),
          ],
        ),
      ],
    );
  }

  Widget _transparencyCard(BuildContext context) {
    final l10n = context.l10n;
    final mode = widget.settings.transparencyMode;
    return SettingsCardGroup(
      key: const ValueKey('appearance-transparency-card'),
      title: l10n.settingsAppearanceTransparency,
      children: [
        SettingsCardPadding(
          child: SettingsControlRow(
            label: l10n.settingsTransparencyTitle,
            description: _transparencyDescription(l10n, mode),
            control: SettingsSegmentedControl<ShellTransparencyMode>(
              key: settingsBackdropBlurToggleKey,
              value: widget.settings.transparencyMode,
              choices: <SettingsChoice<ShellTransparencyMode>>[
                SettingsChoice(
                  ShellTransparencyMode.off,
                  l10n.settingsTransparencyOff,
                ),
                SettingsChoice(
                  ShellTransparencyMode.blur,
                  l10n.settingsTransparencyBlur,
                ),
                SettingsChoice(
                  ShellTransparencyMode.glass,
                  l10n.settingsTransparencyGlass,
                ),
              ],
              onChanged: widget.onTransparencyModeChanged,
            ),
          ),
        ),
        if (mode == ShellTransparencyMode.glass)
          SettingsCardPadding(
            child: _GlassControls(
              configuration: widget.settings.glass,
              mobile: widget.mobile,
              onChanged: widget.onGlassChanged,
            ),
          )
        else ...[
          if (mode == ShellTransparencyMode.blur)
            SettingsCardPadding(
              child: SettingsSlider(
                key: settingsBackdropBlurSliderKey,
                label: l10n.settingsBackdropBlurIntensity,
                value: widget.settings.backdropBlurLevel.index.toDouble(),
                minimum: 0,
                maximum: ShellBackdropBlurLevel.values.length - 1,
                divisions: ShellBackdropBlurLevel.values.length - 1,
                valueLabel: _backdropBlurLevelLabel(
                  l10n,
                  widget.settings.backdropBlurLevel,
                ),
                onChanged: (value) => widget.onBackdropBlurLevelChanged(
                  ShellBackdropBlurLevel.values[value.round()],
                ),
              ),
            ),
          SettingsCardPadding(
            child: Column(
              children: [
                SettingsSlider(
                  label: l10n.settingsPanelOpacity,
                  value: widget.settings.panelOpacity,
                  minimum: ShellOpacity.minimumPanel,
                  maximum: 1,
                  divisions: 95,
                  valueLabel: l10n.settingsPercent(
                    (widget.settings.panelOpacity * 100).round(),
                  ),
                  onChanged: widget.onPanelOpacityChanged,
                ),
                const SizedBox(height: 12),
                SettingsSlider(
                  key: settingsCardOpacitySliderKey,
                  label: l10n.settingsCardOpacity,
                  value: widget.settings.cardOpacity,
                  minimum: ShellOpacity.minimumCard,
                  maximum: 1,
                  divisions: 95,
                  valueLabel: l10n.settingsPercent(
                    (widget.settings.cardOpacity * 100).round(),
                  ),
                  onChanged: widget.onCardOpacityChanged,
                ),
              ],
            ),
          ),
        ],
        if (mode != ShellTransparencyMode.off)
          SettingsDisclosure(
            key: PageStorageKey('appearance-effects-${mode.name}'),
            title: l10n.settingsAppearanceAdvancedEffects,
            description: mode == ShellTransparencyMode.glass
                ? l10n.settingsAppearanceAdvancedEffectsDescription
                : l10n.settingsAppearanceCompositingDescription,
            children: [
              if (mode == ShellTransparencyMode.glass)
                SettingsGlassTuningControls(
                  configuration: widget.settings.glass,
                  onChanged: widget.onGlassChanged,
                  opacityThreshold:
                      widget.settings.backdropBlurOpacityThreshold,
                  onOpacityThresholdChanged:
                      widget.onBackdropBlurOpacityThresholdChanged,
                )
              else
                SettingsSlider(
                  key: settingsBackdropBlurOpacityThresholdKey,
                  label: l10n.settingsBackdropBlurOpacityThreshold,
                  value: widget.settings.backdropBlurOpacityThreshold,
                  minimum: 0,
                  maximum: 1,
                  divisions: 100,
                  valueLabel: l10n.settingsPercent(
                    (widget.settings.backdropBlurOpacityThreshold * 100)
                        .round(),
                  ),
                  onChanged: widget.onBackdropBlurOpacityThresholdChanged,
                ),
            ],
          ),
      ],
    );
  }
}

List<String> _fontFamilyChoices(
  List<String> availableFamilies,
  String selectedFamily,
) {
  if (selectedFamily.isEmpty || availableFamilies.contains(selectedFamily)) {
    return availableFamilies;
  }
  final choices = <String>[...availableFamilies, selectedFamily];
  choices.sort((first, second) {
    final folded = first.toLowerCase().compareTo(second.toLowerCase());
    return folded != 0 ? folded : first.compareTo(second);
  });
  return choices;
}

String _fontFamilyLabel(String family) {
  return family == ShellText.systemBarFontFamily ? 'JetBrains Mono' : family;
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
    required this.onError,
  });

  final ShellAppearanceSettings settings;
  final List<ShellCursorThemeData> themes;
  final bool catalogLoading;
  final ValueChanged<String> onThemeChanged;
  final ValueChanged<double> onSizeChanged;
  final ValueChanged<bool> onAllowClientCursorSurfacesChanged;
  final Future<ShellCursorThemeData?> Function()? onImport;
  final Future<void> Function(ShellCursorThemeData) onRemove;
  final ValueChanged<String?> onError;

  @override
  State<_CursorSettings> createState() => _CursorSettingsState();
}

class _CursorSettingsState extends State<_CursorSettings> {
  bool _busy = false;

  Future<void> _import() async {
    final importer = widget.onImport;
    if (importer == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      widget.onError(null);
    });
    try {
      await importer();
    } on CursorThemeException catch (error) {
      if (mounted) {
        widget.onError(error.message);
      }
    } on Object {
      if (mounted) {
        widget.onError(context.l10n.settingsCursorImportFailed);
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
      widget.onError(null);
    });
    try {
      await widget.onRemove(theme);
    } on CursorThemeException catch (error) {
      if (mounted) {
        widget.onError(error.message);
      }
    } on Object {
      if (mounted) {
        widget.onError(context.l10n.settingsCursorRemoveFailed);
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
          SettingsCardPadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSlider(
                  key: settingsCursorSizeSliderKey,
                  label: l10n.settingsCursorSize,
                  value: widget.settings.cursorSize,
                  minimum: shellCursorMinimumSize,
                  maximum: shellCursorMaximumSize,
                  divisions:
                      ((shellCursorMaximumSize - shellCursorMinimumSize) / 4)
                          .round(),
                  valueLabel: l10n.settingsPixels(
                    widget.settings.cursorSize.round(),
                  ),
                  onChanged: widget.onSizeChanged,
                ),
                const SizedBox(height: 20),
                SettingsControlRow(
                  label: l10n.settingsCursorTheme,
                  description: '',
                  control: SettingsTextButton(
                    label: _busy
                        ? l10n.settingsCursorImporting
                        : l10n.settingsCursorImport,
                    onPressed: widget.onImport == null || _busy
                        ? null
                        : _import,
                  ),
                ),
                const SizedBox(height: 12),
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
                          onRemove: theme.isImported
                              ? () => _remove(theme)
                              : null,
                        ),
                    ],
                  ),
              ],
            ),
          ),
          Divider(
            height: 1,
            indent: 20,
            endIndent: 20,
            color: context.applicationColors.separator,
          ),
          SettingsDisclosure(
            key: const PageStorageKey('appearance-cursor-advanced'),
            title: l10n.settingsAppearanceCursorAdvanced,
            children: [
              SettingsToggle(
                label: l10n.settingsCursorAllowApplications,
                description: l10n.settingsCursorAllowApplicationsDescription,
                value: widget.settings.allowClientCursorSurfaces,
                onChanged: widget.onAllowClientCursorSurfacesChanged,
              ),
            ],
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
    final colors = context.applicationColors;
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
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.tile,
            opacity: enabled ? 1 : 0.52,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : Motion.tile,
              width: 250,
              constraints: const BoxConstraints(minHeight: 124),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: widget.selected
                    ? Color.alphaBlend(accent.withAlpha(34), colors.control)
                    : colors.control,
                borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
                border: Border.all(
                  color: widget.selected
                      ? accent
                      : _hovered || _focused
                      ? colors.foreground
                      : colors.separator,
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
                                  color: colors.secondary,
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

String _transparencyDescription(
  AppLocalizations l10n,
  ShellTransparencyMode mode,
) {
  return switch (mode) {
    ShellTransparencyMode.off => l10n.settingsTransparencyOffDescription,
    ShellTransparencyMode.blur => l10n.settingsTransparencyBlurDescription,
    ShellTransparencyMode.glass => l10n.settingsTransparencyGlassDescription,
  };
}

class _GlassControls extends StatelessWidget {
  const _GlassControls({
    required this.configuration,
    required this.mobile,
    required this.onChanged,
  });

  final ShellGlassConfiguration configuration;

  /// Phone apps never draw glass groups below the appearance's floor, so the
  /// App panels slider starts there instead of showing values that do
  /// nothing. A saved value below it is shown, not rewritten, as the floor.
  final bool mobile;
  final ValueChanged<ShellGlassConfiguration> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String percent(double value) => l10n.settingsPercent((value * 100).round());
    final appPanelMinimum = mobile ? configuration.mobileAppPanelFloor : 0.0;
    final appPanelOpacity = math.max(
      configuration.appPanelOpacity,
      appPanelMinimum,
    );

    return Column(
      children: [
        SettingsControlRow(
          label: l10n.settingsGlassAppearance,
          description: '',
          control: SettingsSegmentedControl<ShellGlassAppearance>(
            key: const ValueKey('settings-glass-appearance'),
            value: configuration.appearance,
            choices: [
              SettingsChoice(
                ShellGlassAppearance.dark,
                l10n.settingsColorSchemeDark,
              ),
              SettingsChoice(
                ShellGlassAppearance.light,
                l10n.settingsColorSchemeLight,
              ),
            ],
            onChanged: (value) =>
                onChanged(configuration.copyWith(appearance: value)),
          ),
        ),
        const SizedBox(height: 12),
        SettingsSlider(
          key: const ValueKey('settings-glass-shell-opacity'),
          label: l10n.settingsGlassShellOpacity,
          value: configuration.opacity,
          minimum: 0,
          maximum: 1,
          divisions: 100,
          valueLabel: percent(configuration.opacity),
          onChanged: (value) =>
              onChanged(configuration.copyWith(opacity: value)),
        ),
        const SizedBox(height: 8),
        SettingsSlider(
          key: const ValueKey('settings-glass-window-opacity'),
          label: l10n.settingsGlassWindowOpacity,
          value: configuration.windowOpacity,
          minimum: 0,
          maximum: 1,
          divisions: 100,
          valueLabel: percent(configuration.windowOpacity),
          onChanged: (value) =>
              onChanged(configuration.copyWith(windowOpacity: value)),
        ),
        const SizedBox(height: 8),
        SettingsSlider(
          key: const ValueKey('settings-glass-app-panel-opacity'),
          label: l10n.settingsGlassAppPanelOpacity,
          value: appPanelOpacity,
          minimum: appPanelMinimum,
          maximum: 1,
          divisions: ((1 - appPanelMinimum) * 100).round(),
          valueLabel: percent(appPanelOpacity),
          onChanged: (value) =>
              onChanged(configuration.copyWith(appPanelOpacity: value)),
        ),
        const SizedBox(height: 8),
        SettingsSlider(
          label: l10n.settingsGlassFrost,
          value: configuration.blurSigma,
          minimum: ShellGlassConfiguration.minimumBlurSigma,
          maximum: ShellGlassConfiguration.maximumBlurSigma,
          divisions: 30,
          valueLabel: l10n.settingsPixels(configuration.blurSigma.round()),
          onChanged: (value) =>
              onChanged(configuration.copyWith(blurSigma: value)),
        ),
      ],
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
