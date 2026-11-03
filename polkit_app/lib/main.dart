import 'dart:async';
import 'dart:io';

import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_color_scheme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:denial_flutter_sdk/wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'access.dart';
import 'agent.dart';
import 'prompt.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = StartupEnvironment.capture();
  // denial-portal starts the same bundle for its Access requests.
  final access = Platform.environment.containsKey('DENIAL_ACCESS_SOCKET');
  runApp(
    ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(environment),
        denialBridgeProvider.overrideWith((ref) {
          final bridge = DenialBridge(useControlSocket: true);
          ref.onDispose(bridge.dispose);
          return bridge;
        }),
      ],
      child: access ? const AccessApp() : const AuthenticationApp(),
    ),
  );
}

/// The authentication prompt in the user's live Denial appearance.
///
/// Authentication policy and the conversation remain Rust's.
class AuthenticationApp extends StatefulWidget {
  const AuthenticationApp({super.key});

  @override
  State<AuthenticationApp> createState() => _AuthenticationAppState();
}

class _AuthenticationAppState extends State<AuthenticationApp> {
  final session = AgentSession();

  @override
  void initState() {
    super.initState();
    unawaited(session.connect());
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DialogApp(
    title: 'Authentication',
    builder: (appearanceReady, durationScale) => AuthenticationDialog(
      session: session,
      appearanceReady: appearanceReady,
      durationScale: durationScale,
    ),
  );
}

/// An Access request from denial-portal: whether an app may have something.
class AccessApp extends StatefulWidget {
  const AccessApp({super.key});

  @override
  State<AccessApp> createState() => _AccessAppState();
}

class _AccessAppState extends State<AccessApp> {
  final session = AccessSession();

  @override
  void initState() {
    super.initState();
    unawaited(session.connect());
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DialogApp(
    title: 'Permission',
    builder: (appearanceReady, _) =>
        AccessDialog(session: session, appearanceReady: appearanceReady),
  );
}

/// A dialog in the user's live Denial appearance.
///
/// Appearance is presentation only: an unavailable control socket leaves the
/// defaults.
class DialogApp extends ConsumerWidget {
  const DialogApp({required this.title, required this.builder, super.key});

  final String title;

  /// The dialog, told whether its final colors are known and how fast the
  /// user's animations run.
  final Widget Function(bool appearanceReady, double durationScale) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(
      shellSettingsProvider.select((settings) => settings.appearance),
    );
    final durationScale = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.animations.durationScale,
      ),
    );
    final locale = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.localization.localeOverride,
      ),
    );
    final syncing =
        ref.watch(shellSettingsSyncStatusProvider).phase ==
        ShellSettingsSyncPhase.loading;
    final accent = ref.watch(shellAccentProvider);
    // Match the shell's own theme construction, including the opacity
    // threshold that decides where the compositor frosts the card.
    final light = appearance.transparencyMode == ShellTransparencyMode.glass
        ? appearance.glass.appearance == ShellGlassAppearance.light
        : appearance.colorSchemePreference.effectiveBrightness ==
              Brightness.light;
    final theme = ShellThemeData(
      colors: light ? ShellColorScheme.light : ShellColorScheme.dark,
      accent: accent.color,
      fontFamily: appearance.fontFamily,
      cornerRadiusScale: appearance.cornerRadiusScale,
      panelOpacity: appearance.panelOpacity,
      cardOpacity: appearance.cardOpacity,
      transparencyMode: appearance.transparencyMode,
      backdropBlurLevel: appearance.backdropBlurLevel,
      backdropBlurOpacityThreshold: appearance.backdropBlurOpacityThreshold,
      glass: appearance.glass,
    );
    final material = theme.toMaterialTheme();
    return AnimatedShellTheme(
      data: theme,
      duration: Duration(milliseconds: (240 * durationScale).round()),
      child: MaterialApp(
        title: title,
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: material,
        darkTheme: material,
        themeMode: light ? ThemeMode.light : ThemeMode.dark,
        // Only the card is painted. The overlay canvas around it stays fully
        // transparent, so neither glass nor tint appears outside the card.
        builder: (context, child) =>
            ColoredBox(color: Colors.transparent, child: child),
        home: builder(
          // Reveal in the final accent rather than recoloring a visible card.
          !syncing &&
              (appearance.accentSource == ShellAccentSource.custom ||
                  accent.isResolved),
          durationScale,
        ),
      ),
    );
  }
}
