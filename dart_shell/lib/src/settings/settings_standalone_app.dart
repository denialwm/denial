import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../config/startup_environment.dart';
import '../platform/denial_bridge.dart';
import '../settings/settings_controller.dart';
import '../state/shell_controller.dart';
import '../theme/shell_color_scheme.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import 'settings_application.dart';
import 'widgets/settings_navigation.dart';

/// The process root for the standalone Wayland Settings client.
///
/// It intentionally initializes no shell scene, window registry, cursor
/// renderer, or compositor texture pipeline. Page-specific providers remain
/// lazy below [DenialSettingsApplication].
class DenialSettingsStandaloneApp extends StatelessWidget {
  const DenialSettingsStandaloneApp({
    this.initialPage = SettingsPageId.appearance,
    this.startupEnvironment,
    this.controlSocketPath,
    super.key,
  });

  final SettingsPageId initialPage;
  final StartupEnvironment? startupEnvironment;
  final String? controlSocketPath;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(
          startupEnvironment ?? StartupEnvironment.capture(),
        ),
        denialBridgeProvider.overrideWith((ref) {
          final bridge = DenialBridge(
            useControlSocket: true,
            controlSocketPath: controlSocketPath,
          );
          ref.onDispose(bridge.dispose);
          return bridge;
        }),
      ],
      child: _DenialSettingsStandaloneContent(initialPage: initialPage),
    );
  }
}

class _DenialSettingsStandaloneContent extends ConsumerStatefulWidget {
  const _DenialSettingsStandaloneContent({required this.initialPage});

  final SettingsPageId initialPage;

  @override
  ConsumerState<_DenialSettingsStandaloneContent> createState() =>
      _DenialSettingsStandaloneContentState();
}

class _DenialSettingsStandaloneContentState
    extends ConsumerState<_DenialSettingsStandaloneContent> {
  static const _activationChannel = MethodChannel('denial/settings_activation');
  final AssetBundle _packageAssets = _DenialShellPackageAssetBundle();
  Color? _lightMaterialThemeAccent;
  Color? _darkMaterialThemeAccent;
  ThemeData? _lightMaterialTheme;
  ThemeData? _darkMaterialTheme;

  @override
  void initState() {
    super.initState();
    _activationChannel.setMethodCallHandler((call) async {
      if (call.method != 'openPage' || call.arguments is! String) return;
      final requested = call.arguments as String;
      for (final page in SettingsPageId.values) {
        if (page.name == requested) {
          ref.read(settingsPageOpenRequestProvider.notifier).request(page);
          return;
        }
      }
    });
  }

  @override
  void dispose() {
    _activationChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final syncStatus = ref.watch(shellSettingsSyncStatusProvider);
    final presentation = ref.watch(
      shellSettingsProvider.select(
        (settings) => (
          locale: settings.localization.localeOverride,
          appearance: settings.appearance,
          animationDurationScale: settings.animations.durationScale,
        ),
      ),
    );
    final appearance = presentation.appearance;
    final selectedColors =
        appearance.colorSchemePreference.effectiveBrightness == Brightness.light
        ? ShellColorScheme.light
        : ShellColorScheme.dark;
    final accent = ref.watch(
      shellAccentProvider.select((accent) => accent.color),
    );
    final selectedTheme = ShellThemeData(
      colors: selectedColors,
      accent: accent,
      cornerRadiusScale: appearance.cornerRadiusScale,
      panelOpacity: appearance.panelOpacity,
      cardOpacity: appearance.cardOpacity,
      backdropBlurEnabled: false,
      focusedWindowBorderEnabled: appearance.focusedWindowBorderEnabled,
      focusedWindowOpacity: appearance.focusedWindowOpacity,
      unfocusedWindowOpacity: appearance.unfocusedWindowOpacity,
    );
    final materialThemes = _materialThemesFor(accent, selectedTheme.brightness);
    return DefaultAssetBundle(
      bundle: _packageAssets,
      child: AnimatedShellTheme(
        data: selectedTheme,
        duration: Duration(
          milliseconds: (200 * presentation.animationDurationScale).round(),
        ),
        child: MaterialApp(
          title: 'Denial Settings',
          debugShowCheckedModeBanner: false,
          color: ShellMediaColors.transparentDark,
          locale: presentation.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: materialThemes.light,
          darkTheme: materialThemes.dark,
          themeMode: selectedTheme.brightness == Brightness.light
              ? ThemeMode.light
              : ThemeMode.dark,
          home: Stack(
            fit: StackFit.expand,
            children: [
              AbsorbPointer(
                absorbing: syncStatus.phase != ShellSettingsSyncPhase.ready,
                child: DenialSettingsApplication(
                  initialPage: widget.initialPage,
                  onOpenWallpaperSelector: () =>
                      ref.read(denialBridgeProvider).openWallpaperSelector(),
                  onPickCursorZip: () =>
                      _activationChannel.invokeMethod<String>('pickCursorZip'),
                ),
              ),
              if (syncStatus.phase == ShellSettingsSyncPhase.loading)
                const _SettingsSynchronizationLoading(),
              if (syncStatus.phase == ShellSettingsSyncPhase.failed)
                _SettingsSynchronizationFailure(
                  onRetry: () {
                    unawaited(
                      ref
                          .read(shellSettingsProvider.notifier)
                          .retrySynchronization(),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  ({ThemeData light, ThemeData dark}) _materialThemesFor(
    Color accent,
    Brightness activeBrightness,
  ) {
    // Keep the inactive theme available for MaterialApp, but do not rebuild it
    // for every color-wheel event. It is refreshed when that mode is selected.
    if (activeBrightness == Brightness.light) {
      _refreshLightMaterialTheme(accent);
      _darkMaterialTheme ??= _buildMaterialTheme(ShellColorScheme.dark, accent);
      _darkMaterialThemeAccent ??= accent;
    } else {
      _refreshDarkMaterialTheme(accent);
      _lightMaterialTheme ??= _buildMaterialTheme(
        ShellColorScheme.light,
        accent,
      );
      _lightMaterialThemeAccent ??= accent;
    }
    return (light: _lightMaterialTheme!, dark: _darkMaterialTheme!);
  }

  void _refreshLightMaterialTheme(Color accent) {
    if (_lightMaterialThemeAccent == accent) return;
    _lightMaterialThemeAccent = accent;
    _lightMaterialTheme = _buildMaterialTheme(ShellColorScheme.light, accent);
  }

  void _refreshDarkMaterialTheme(Color accent) {
    if (_darkMaterialThemeAccent == accent) return;
    _darkMaterialThemeAccent = accent;
    _darkMaterialTheme = _buildMaterialTheme(ShellColorScheme.dark, accent);
  }

  ThemeData _buildMaterialTheme(ShellColorScheme colors, Color accent) {
    return ShellThemeData(colors: colors, accent: accent).toMaterialTheme();
  }
}

class _SettingsSynchronizationLoading extends StatelessWidget {
  const _SettingsSynchronizationLoading();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.shellColors.background.withValues(alpha: 0.74),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _SettingsSynchronizationFailure extends StatelessWidget {
  const _SettingsSynchronizationFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: context.shellColors.background.withValues(alpha: 0.88),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sync_problem_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.quickSettingsSettingsUnavailable,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh_rounded),
              label: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

/// Assets belong to the reusable shell package when this code is hosted by
/// the standalone application. Existing widgets keep their root-package keys;
/// this bundle retries those keys through Flutter's dependency namespace.
class _DenialShellPackageAssetBundle extends CachingAssetBundle {
  static const _packagePrefix = 'packages/denial_dart_shell/';

  @override
  Future<ByteData> load(String key) async {
    try {
      return await rootBundle.load(key);
    } on FlutterError {
      return rootBundle.load('$_packagePrefix$key');
    }
  }

  @override
  Future<ImmutableBuffer> loadBuffer(String key) async {
    try {
      return await rootBundle.loadBuffer(key);
    } on FlutterError {
      return rootBundle.loadBuffer('$_packagePrefix$key');
    }
  }
}
