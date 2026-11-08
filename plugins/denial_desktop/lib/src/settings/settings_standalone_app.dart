import 'dart:async';

import 'package:flutter/material.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/shell_color_scheme.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import 'settings_application.dart';
import 'widgets/settings_navigation.dart';

const _standaloneRootBackground = Color.fromRGBO(0, 0, 0, 0.01);

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
    this.applicationBuilder,
    this.title = 'Denial Settings',
    super.key,
  });

  final SettingsPageId initialPage;
  final StartupEnvironment? startupEnvironment;
  final String? controlSocketPath;
  final WidgetBuilder? applicationBuilder;
  final String title;

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
      child: _DenialSettingsStandaloneContent(
        initialPage: initialPage,
        applicationBuilder: applicationBuilder,
        title: title,
      ),
    );
  }
}

class _DenialSettingsStandaloneContent extends ConsumerStatefulWidget {
  const _DenialSettingsStandaloneContent({
    required this.initialPage,
    required this.applicationBuilder,
    required this.title,
  });

  final SettingsPageId initialPage;
  final WidgetBuilder? applicationBuilder;
  final String title;

  @override
  ConsumerState<_DenialSettingsStandaloneContent> createState() =>
      _DenialSettingsStandaloneContentState();
}

class _DenialSettingsStandaloneContentState
    extends ConsumerState<_DenialSettingsStandaloneContent> {
  static const _activationChannel = MethodChannel(
    'denial/settings_activation',
    JSONMethodCodec(),
  );
  final AssetBundle _packageAssets = _DenialShellPackageAssetBundle();
  Color? _lightMaterialThemeAccent;
  Color? _darkMaterialThemeAccent;
  String? _lightMaterialThemeFontFamily;
  String? _darkMaterialThemeFontFamily;
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
    final light = appearance.transparencyMode == ShellTransparencyMode.glass
        ? appearance.glass.appearance == ShellGlassAppearance.light
        : appearance.colorSchemePreference.effectiveBrightness ==
              Brightness.light;
    final selectedColors = light
        ? ShellColorScheme.light
        : ShellColorScheme.dark;
    final accent = ref.watch(
      shellAccentProvider.select((accent) => accent.color),
    );
    final selectedTheme = ShellThemeData(
      colors: selectedColors,
      accent: accent,
      fontFamily: appearance.fontFamily,
      cornerRadiusScale: appearance.cornerRadiusScale,
      panelOpacity: appearance.panelOpacity,
      cardOpacity: appearance.cardOpacity,
      transparencyMode: appearance.transparencyMode,
      glass: appearance.glass,
      focusedWindowBorderEnabled: appearance.focusedWindowBorderEnabled,
      focusedWindowOpacity: appearance.focusedWindowOpacity,
      unfocusedWindowOpacity: appearance.unfocusedWindowOpacity,
    );
    final materialThemes = _materialThemesFor(
      accent,
      appearance.fontFamily,
      selectedTheme.brightness,
    );
    return DefaultAssetBundle(
      bundle: _packageAssets,
      child: AnimatedShellTheme(
        data: selectedTheme,
        duration: Duration(
          milliseconds: (200 * presentation.animationDurationScale).round(),
        ),
        child: MaterialApp(
          title: widget.title,
          debugShowCheckedModeBanner: false,
          color: _standaloneRootBackground,
          builder: (context, child) {
            // The tablet UI needs a larger Settings surface than a desktop
            // window at the same logical size. Lay the app out at a smaller
            // logical size and scale it back up: controls grow together and
            // glyphs stay vector-crisp.
            final media = MediaQuery.of(context);
            const uiScale = 1.3;
            final scaled = media.size / uiScale;
            return ColoredBox(
              color: _standaloneRootBackground,
              child: MediaQuery(
                data: media.copyWith(size: scaled),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Transform.scale(
                    scale: uiScale,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: scaled.width,
                      height: scaled.height,
                      child: child,
                    ),
                  ),
                ),
              ),
            );
          },
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
                child: widget.applicationBuilder != null
                    ? Builder(builder: widget.applicationBuilder!)
                    : DenialSettingsApplication(
                        initialPage: widget.initialPage,
                        onOpenWallpaperSelector: () => ref
                            .read(denialBridgeProvider)
                            .openWallpaperSelector(),
                        onPickCursorZip: () => _activationChannel
                            .invokeMethod<String>('pickCursorZip'),
                        onPickProfileImage:
                            ({
                              required title,
                              required cancelLabel,
                              required chooseLabel,
                            }) => _activationChannel.invokeMethod<String>(
                              'pickProfileImage',
                              {
                                'title': title,
                                'cancel': cancelLabel,
                                'choose': chooseLabel,
                              },
                            ),
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
    String fontFamily,
    Brightness activeBrightness,
  ) {
    // Keep the inactive theme available for MaterialApp, but do not rebuild it
    // for every color-wheel event. It is refreshed when that mode is selected.
    if (activeBrightness == Brightness.light) {
      _refreshLightMaterialTheme(accent, fontFamily);
      _darkMaterialTheme ??= _buildMaterialTheme(
        ShellColorScheme.dark,
        accent,
        fontFamily,
      );
      _darkMaterialThemeAccent ??= accent;
      _darkMaterialThemeFontFamily ??= fontFamily;
    } else {
      _refreshDarkMaterialTheme(accent, fontFamily);
      _lightMaterialTheme ??= _buildMaterialTheme(
        ShellColorScheme.light,
        accent,
        fontFamily,
      );
      _lightMaterialThemeAccent ??= accent;
      _lightMaterialThemeFontFamily ??= fontFamily;
    }
    return (light: _lightMaterialTheme!, dark: _darkMaterialTheme!);
  }

  void _refreshLightMaterialTheme(Color accent, String fontFamily) {
    if (_lightMaterialThemeAccent == accent &&
        _lightMaterialThemeFontFamily == fontFamily) {
      return;
    }
    _lightMaterialThemeAccent = accent;
    _lightMaterialThemeFontFamily = fontFamily;
    _lightMaterialTheme = _buildMaterialTheme(
      ShellColorScheme.light,
      accent,
      fontFamily,
    );
  }

  void _refreshDarkMaterialTheme(Color accent, String fontFamily) {
    if (_darkMaterialThemeAccent == accent &&
        _darkMaterialThemeFontFamily == fontFamily) {
      return;
    }
    _darkMaterialThemeAccent = accent;
    _darkMaterialThemeFontFamily = fontFamily;
    _darkMaterialTheme = _buildMaterialTheme(
      ShellColorScheme.dark,
      accent,
      fontFamily,
    );
  }

  ThemeData _buildMaterialTheme(
    ShellColorScheme colors,
    Color accent,
    String fontFamily,
  ) {
    return DenialApplicationTheme.fromShell(
      ShellThemeData(colors: colors, accent: accent, fontFamily: fontFamily),
    ).materialTheme;
  }
}

class _SettingsSynchronizationLoading extends StatelessWidget {
  const _SettingsSynchronizationLoading();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.applicationColors.canvas,
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
      color: context.applicationColors.canvas,
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
  static const _packagePrefix = 'packages/denial_flutter_sdk/';

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
