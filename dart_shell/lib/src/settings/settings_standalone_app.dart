import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../config/startup_environment.dart';
import '../platform/denial_bridge.dart';
import '../settings/settings_controller.dart';
import '../state/shell_controller.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'settings_application.dart';
import 'shell_settings.dart';
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
        ),
      ),
    );
    final appearance = presentation.appearance;
    final accent = appearance.accentSource == ShellAccentSource.custom
        ? appearance.customAccentColor
        : ShellColors.accent;
    return DefaultAssetBundle(
      bundle: _packageAssets,
      child: ShellTheme(
        data: ShellThemeData(
          accent: accent,
          windowRadius: appearance.windowRadius,
          panelRadius: appearance.panelRadius,
          panelOpacity: appearance.panelOpacity,
          backdropBlurEnabled: false,
          focusedWindowOpacity: appearance.focusedWindowOpacity,
          unfocusedWindowOpacity: appearance.unfocusedWindowOpacity,
        ),
        child: MaterialApp(
          title: 'Denial Settings',
          debugShowCheckedModeBanner: false,
          color: Colors.transparent,
          locale: presentation.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            scaffoldBackgroundColor: Colors.transparent,
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent,
              brightness: Brightness.dark,
              surface: ShellColors.background,
            ),
          ),
          home: Stack(
            fit: StackFit.expand,
            children: [
              AbsorbPointer(
                absorbing: syncStatus.phase != ShellSettingsSyncPhase.ready,
                child: DenialSettingsApplication(
                  initialPage: widget.initialPage,
                  onOpenWallpaperSelector: () =>
                      ref.read(denialBridgeProvider).openWallpaperSelector(),
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
}

class _SettingsSynchronizationLoading extends StatelessWidget {
  const _SettingsSynchronizationLoading();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ShellColors.background.withValues(alpha: 0.74),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _SettingsSynchronizationFailure extends StatelessWidget {
  const _SettingsSynchronizationFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ColoredBox(
      color: ShellColors.background.withValues(alpha: 0.88),
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
              icon: const Icon(Icons.refresh_rounded),
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
