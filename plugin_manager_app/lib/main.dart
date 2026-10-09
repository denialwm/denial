import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/materials.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';

import 'manager.dart';

const _rootBackground = Color.fromRGBO(0, 0, 0, 0.01);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PluginManagerApp());
}

class PluginManagerApp extends StatefulWidget {
  const PluginManagerApp({super.key});
  @override
  State<PluginManagerApp> createState() => _PluginManagerAppState();
}

class _PluginManagerAppState extends State<PluginManagerApp> {
  ShellThemeData theme = const ShellThemeData(
    transparencyMode: ShellTransparencyMode.glass,
  );
  ShellLocalizationSettings localization = const ShellLocalizationSettings();
  StreamSubscription<FileSystemEvent>? watcher;
  Timer? debounce;
  late final File preferences;

  @override
  void initState() {
    super.initState();
    final config =
        Platform.environment['XDG_CONFIG_HOME'] ??
        '${Platform.environment['HOME']}/.config';
    preferences = File('$config/denial/settings.json');
    unawaited(readAppearance());
    // Watch the directory: Settings publishes updates by replacing the file.
    if (preferences.parent.existsSync()) {
      watcher = preferences.parent.watch().listen((event) {
        // Atomic saves arrive as a move from a temporary file to settings.json.
        // The destination, rather than event.path, identifies that update.
        final replacesPreferences =
            event is FileSystemMoveEvent &&
            event.destination == preferences.path;
        if (event.path != preferences.path && !replacesPreferences) return;
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 150), readAppearance);
      }, onError: (Object _) {});
    }
  }

  Future<void> readAppearance() async {
    try {
      final data =
          jsonDecode(await preferences.readAsString()) as Map<String, dynamic>;
      final appearance = data['appearance'] as Map<String, dynamic>? ?? {};
      final glass = ShellGlassConfiguration.fromJson(appearance['glass']);
      final transparencyMode = ShellTransparencyMode.values.firstWhere(
        (mode) => mode.name == appearance['transparencyMode'],
        orElse: () => ShellTransparencyMode.glass,
      );
      // Application materials resolve content and sidebar appearances according
      // to the background they sample, using Denial's shared SDK policy.
      final light = appearance['colorSchemePreference'] == 'preferLight';
      final colors = light ? ShellColorScheme.light : ShellColorScheme.dark;
      final custom = appearance['customAccentColor'];
      final resolved = ShellThemeData(
        colors: colors,
        accent: appearance['accentSource'] == 'custom' && custom is int
            ? Color(custom)
            : ShellBrandColors.defaultAccent,
        fontFamily: appearance['fontFamily'] as String? ?? '',
        cornerRadiusScale:
            (appearance['cornerRadiusScale'] as num?)?.toDouble() ?? 1,
        panelOpacity:
            (appearance['panelOpacity'] as num?)?.toDouble() ??
            ShellOpacity.panel,
        cardOpacity:
            (appearance['cardOpacity'] as num?)?.toDouble() ??
            ShellOpacity.card,
        transparencyMode: transparencyMode,
        glass: glass,
      );
      // Use the same persisted locale preference and generated delegates as
      // Welcome/Settings. A null override lets MaterialApp follow the system.
      final resolvedLocalization = ShellSettings.fromJson(data).localization;
      if (mounted) {
        setState(() {
          theme = resolved;
          localization = resolvedLocalization;
        });
      }
    } on FileSystemException {
      // The app also works before the user has saved any preferences.
    } on FormatException {
      // Keep the last valid appearance while settings are being replaced.
    } on TypeError {
      // Unrecognized future settings retain the SDK's defaults.
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    watcher?.cancel();
    super.dispose();
  }

  ThemeData get materialTheme =>
      DenialApplicationTheme.fromShell(theme).materialTheme;

  @override
  Widget build(BuildContext context) => ShellTheme(
    data: theme,
    child: MaterialApp(
      onGenerateTitle: (context) => context.l10n.pluginsAppTitle,
      locale: localization.localeOverride,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      color: _rootBackground,
      builder: (context, child) =>
          ColoredBox(color: _rootBackground, child: child),
      debugShowCheckedModeBanner: false,
      theme: materialTheme,
      darkTheme: materialTheme,
      themeMode: theme.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: const ManagerPage(),
    ),
  );
}
