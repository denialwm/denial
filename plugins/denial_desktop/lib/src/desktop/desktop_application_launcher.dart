import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/default_shell/panel_composition.dart';
import 'desktop_workspace.dart';

/// Runtime adapter for the statically selected launcher presentation.
class DesktopApplicationLauncher extends ConsumerStatefulWidget {
  const DesktopApplicationLauncher({
    super.key,
    required this.searchFocusNode,
    required this.onEnter,
    required this.onExit,
    required this.onDismiss,
    required this.onLaunch,
    required this.onLaunchLocal,
  });

  final FocusNode searchFocusNode;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onDismiss;
  final ValueChanged<DesktopApp> onLaunch;
  final ValueChanged<LocalFlutterApplication> onLaunchLocal;

  @override
  ConsumerState<DesktopApplicationLauncher> createState() =>
      _DesktopApplicationLauncherHostState();
}

class _DesktopApplicationLauncherHostState
    extends ConsumerState<DesktopApplicationLauncher> {
  List<HomeGridItem?>? _slots;
  LocalFlutterApplicationRegistry? _registry;
  Locale? _locale;
  List<LauncherApplication> _applications = const [];
  Map<String, DesktopApp> _desktopApps = const {};
  Map<String, LocalFlutterApplication> _localApps = const {};

  void _updateCatalog(
    BuildContext context,
    List<HomeGridItem?>? slots,
    LocalFlutterApplicationRegistry registry,
  ) {
    final locale = Localizations.localeOf(context);
    if (identical(_slots, slots) &&
        identical(_registry, registry) &&
        _locale == locale) {
      return;
    }
    _slots = slots;
    _registry = registry;
    _locale = locale;
    final desktopApps = HomeGridLayout.appsIn(slots ?? const <HomeGridItem?>[])
        .map((item) => item.app)
        .whereType<DesktopApp>();
    _desktopApps = {
      for (final app in desktopApps) desktopApplicationRecentId(app.id): app,
    };
    _localApps = {
      for (final app in registry.applications)
        localApplicationRecentId(app.id): app,
    };
    _applications = List.unmodifiable([
      for (final entry in _desktopApps.entries)
        LauncherApplication(
          id: entry.key,
          name: entry.value.name,
          searchableText: entry.value.searchableText,
        ),
      for (final entry in _localApps.entries)
        LauncherApplication(
          id: entry.key,
          name: entry.value.titleFor(context),
          searchableText: [
            entry.value.id,
            entry.value.titleFor(context),
            ...entry.value.categoriesFor(context),
          ].join(' ').toLowerCase(),
        ),
    ]);
  }

  void _launch(String id) {
    if (_desktopApps[id] case final app?) {
      widget.onLaunch(app);
    } else if (_localApps[id] case final app?) {
      widget.onLaunchLocal(app);
    }
  }

  Widget _buildIcon(BuildContext context, String id) {
    if (_localApps[id] case final app?) {
      return ExcludeSemantics(
        child: Icon(
          app.icon,
          size: 46,
          color: context.shellTheme.accentPalette.primary,
        ),
      );
    }
    return DeferredAppIcon(iconPath: _desktopApps[id]?.iconPath);
  }

  @override
  Widget build(BuildContext context) {
    final plugin = ref.watch(desktopLauncherProvider);
    if (plugin == null) return const SizedBox.shrink();
    _updateCatalog(
      context,
      ref.watch(
        homeGridControllerProvider.select((state) => state.asData?.value.slots),
      ),
      ref.watch(localFlutterApplicationRegistryProvider),
    );
    return plugin.build(
      context,
      launcher: LauncherContext(
        applications: _applications,
        recentApplicationIds: ref.watch(applicationRecentsProvider),
        visible: ref.watch(
          desktopWorkspaceProvider.select((state) => state.launcherOpen),
        ),
        searchFocusNode: widget.searchFocusNode,
        onEnter: widget.onEnter,
        onExit: widget.onExit,
        onDismiss: widget.onDismiss,
        onLaunch: _launch,
        buildIcon: _buildIcon,
        strings: _RuntimeLauncherStrings(context.l10n),
        linkCursor: ShellMouseCursors.link,
        textCursor: ShellMouseCursors.text,
      ),
    );
  }
}

class _RuntimeLauncherStrings implements LauncherStrings {
  const _RuntimeLauncherStrings(this.l10n);
  final AppLocalizations l10n;
  @override
  String get suggestionsTitle => l10n.desktopApplicationSuggestionsTitle;
  @override
  String get searchApplications => l10n.desktopSearchApplications;
  @override
  String get clearSearch => l10n.desktopClearApplicationSearch;
  @override
  String get noApplicationsFound => l10n.desktopNoApplicationsFound;
  @override
  String get loadingApplications => l10n.desktopLoadingApplications;
  @override
  String launchApplication(String name) => l10n.desktopLaunchApplication(name);
}
