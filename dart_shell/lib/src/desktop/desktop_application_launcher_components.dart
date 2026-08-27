part of 'desktop_shell.dart';

class _DesktopApplicationSuggestionsRow extends StatelessWidget {
  const _DesktopApplicationSuggestionsRow({
    required this.apps,
    required this.selectedTargetId,
    required this.tileKeyFor,
    required this.onLaunch,
  });

  final List<_DesktopLauncherEntry> apps;
  final String? selectedTargetId;
  final GlobalKey<_DesktopAppTileState> Function(String targetId) tileKeyFor;
  final ValueChanged<_DesktopLauncherEntry> onLaunch;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.desktopApplicationSuggestionsTitle,
      child: SizedBox(
        height: _DesktopApplicationLauncherState._suggestedTileExtent,
        child: GridView.builder(
          key: desktopApplicationSuggestionsRowKey,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _DesktopApplicationLauncherState._tileExtent,
            mainAxisExtent:
                _DesktopApplicationLauncherState._suggestedTileExtent,
            crossAxisSpacing: _DesktopApplicationLauncherState._tileSpacing,
          ),
          itemCount: apps.length,
          itemBuilder: (context, index) {
            final app = apps[index];
            final targetId = _suggestedLauncherTargetId(app.navigationId);
            return KeyedSubtree(
              key: ValueKey<String>(
                'desktop-suggested-app-${app.navigationId}',
              ),
              child: _DesktopAppTile(
                key: tileKeyFor(targetId),
                app: app,
                selected: selectedTargetId == null
                    ? index == 0
                    : targetId == selectedTargetId,
                singleLineName: true,
                onTap: () => onLaunch(app),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DesktopAppSearchField extends StatelessWidget {
  const _DesktopAppSearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

  static final List<TextInputFormatter> _inputFormatters =
      List<TextInputFormatter>.unmodifiable(<TextInputFormatter>[
        FilteringTextInputFormatter.deny(RegExp(r'[\u0000-\u001F\u007F]')),
      ]);

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.text.isNotEmpty;
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    return Semantics(
      textField: true,
      label: l10n.desktopSearchApplications,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.chip),
        ),
        child: Stack(
          children: <Widget>[
            SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: context.shellColors.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          if (!hasQuery)
                            IgnorePointer(
                              child: Text(
                                l10n.desktopSearchApplications,
                                style: TextStyle(
                                  color: context.shellColors.textTertiary,
                                  fontSize: 14,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          EditableText(
                            controller: controller,
                            focusNode: focusNode,
                            mouseCursor: ShellMouseCursors.text,
                            autofocus: true,
                            maxLines: 1,
                            keyboardType: TextInputType.text,
                            textInputAction: TextInputAction.search,
                            onEditingComplete: () {},
                            onSubmitted: (_) => onSubmit(),
                            style: context.shellTheme.text.base,
                            cursorColor: accent.primary,
                            backgroundCursorColor:
                                context.shellColors.textSecondary,
                            selectionColor: accent.selection,
                            // Raw shortcuts and text input are separate
                            // channels. Deny control characters in case an IME
                            // commits one.
                            inputFormatters: _inputFormatters,
                          ),
                        ],
                      ),
                    ),
                    if (hasQuery) ...[
                      const SizedBox(width: 8),
                      Semantics(
                        button: true,
                        label: l10n.desktopClearApplicationSearch,
                        child: MouseRegion(
                          cursor: ShellMouseCursors.link,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onClear,
                            child: SizedBox.square(
                              dimension: 28,
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: context.shellColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ListenableBuilder(
                  listenable: focusNode,
                  builder: (context, child) => DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(ShellRadii.chip),
                      border: Border.all(
                        color: focusNode.hasFocus
                            ? accent.primary
                            : context.shellColors.hairline,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopAppSearchEmptyState extends StatelessWidget {
  const _DesktopAppSearchEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 34,
            color: context.shellColors.textTertiary,
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.desktopNoApplicationsFound,
            style: context.shellTheme.text.cardTitle.copyWith(
              color: context.shellColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopAppTile extends StatefulWidget {
  const _DesktopAppTile({
    super.key,
    required this.app,
    required this.selected,
    this.singleLineName = false,
    required this.onTap,
  });

  final _DesktopLauncherEntry app;
  final bool selected;
  final bool singleLineName;
  final VoidCallback onTap;

  @override
  State<_DesktopAppTile> createState() => _DesktopAppTileState();
}

class _DesktopAppTileState extends State<_DesktopAppTile> {
  bool _hovered = false;
  late bool _selected = widget.selected;

  @override
  void didUpdateWidget(covariant _DesktopAppTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selected = widget.selected;
  }

  void setSelected(bool selected) {
    if (_selected == selected) {
      return;
    }
    setState(() => _selected = selected);
  }

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    final highlighted = _selected || _hovered;
    final name = Text(
      widget.app.name,
      maxLines: widget.singleLineName ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: context.shellTheme.text.cardTitle.copyWith(
        color: highlighted
            ? accent.onContainer
            : context.shellColors.textPrimary,
        fontSize: 11,
      ),
    );
    return Semantics(
      button: true,
      selected: _selected,
      label: l10n.desktopLaunchApplication(widget.app.name),
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              // Keep the idle endpoint in the accent hue so the implicit
              // alpha transition never flashes through neutral grey before
              // reaching the highlighted state.
              color: highlighted
                  ? accent.container
                  : accent.container.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(18),
              border: _selected ? Border.all(color: accent.primary) : null,
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 54,
                  height: 54,
                  child: widget.app.icon != null
                      ? ExcludeSemantics(
                          child: Icon(
                            widget.app.icon!,
                            size: 46,
                            color: accent.primary,
                          ),
                        )
                      : DeferredAppIcon(iconPath: widget.app.iconPath),
                ),
                const SizedBox(height: 8),
                if (widget.singleLineName) name else Expanded(child: name),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _bluetoothIcon(String icon) {
  final normalized = icon.toLowerCase();
  if (normalized.contains('head') || normalized.contains('audio')) {
    return Icons.headphones_rounded;
  }
  if (normalized.contains('gaming')) {
    return Icons.sports_esports_rounded;
  }
  if (normalized.contains('keyboard')) {
    return Icons.keyboard_rounded;
  }
  if (normalized.contains('mouse')) {
    return Icons.mouse_rounded;
  }
  if (normalized.contains('phone')) {
    return Icons.smartphone_rounded;
  }
  if (normalized.contains('computer')) {
    return Icons.computer_rounded;
  }
  return Icons.bluetooth_rounded;
}

List<_DesktopLauncherEntry> _installedDesktopApps(List<HomeGridItem?>? slots) {
  final apps = <_DesktopLauncherEntry>[];
  for (final item
      in slots?.whereType<HomeGridItem>() ?? const <HomeGridItem>[]) {
    if (item.app case final app?) {
      apps.add(_DesktopLauncherEntry.desktop(app));
    }
  }
  return apps;
}

List<_DesktopLauncherEntry> _installedLocalApps(
  BuildContext context,
  Iterable<LocalFlutterApplication> localApps,
) {
  return <_DesktopLauncherEntry>[
    for (final app in localApps) _DesktopLauncherEntry.local(app, context),
  ];
}

List<_DesktopLauncherEntry> _mergeInstalledApps(
  List<_DesktopLauncherEntry> desktopApps,
  List<_DesktopLauncherEntry> localApps,
) {
  final byId = <String, _DesktopLauncherEntry>{};
  for (final app in desktopApps) {
    byId[app.navigationId] = app;
  }
  for (final app in localApps) {
    byId[app.navigationId] = app;
  }
  final apps = byId.values.toList(growable: false)
    ..sort((a, b) => a.sortName.compareTo(b.sortName));
  return apps;
}

List<_DesktopLauncherEntry> _filterInstalledApps(
  List<_DesktopLauncherEntry> apps,
  String query,
) {
  if (query.isEmpty) {
    return apps;
  }

  return apps
      .where((app) => app.searchableText.contains(query))
      .toList(growable: false);
}
