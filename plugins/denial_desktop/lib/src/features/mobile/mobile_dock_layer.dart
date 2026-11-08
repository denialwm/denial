import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../../launcher/home_drag_controller.dart';
import '../../launcher/home_interactions.dart';
import '../../launcher/home_launch.dart';
import '../../launcher/widgets/launcher_icon.dart';
import '../../state/reference_shell_controller.dart';

/// The home dock's pinned applications. An empty or missing file falls back
/// to the defaults; a saved empty list means the user removed everything.
final dockPinnedProvider =
    AsyncNotifierProvider<DockPinnedController, List<String>>(
      DockPinnedController.new,
    );

class DockPinnedController extends AsyncNotifier<List<String>> {
  static const defaults = <String>[
    'app:firefox.desktop',
    'app:org.gnome.Nautilus.desktop',
    'app:qq.desktop',
    'app:droidloom-650f2ba5242c203a3a7c706d46c4602f.desktop',
    'app:dev.denial.Settings.desktop',
  ];

  File get _file {
    final paths = ref.read(runtimePathsProvider);
    return File('${paths.configHome}/denia-home/dock.json');
  }

  @override
  Future<List<String>> build() async {
    final file = _file;
    try {
      if (!await file.exists()) return defaults;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        return [
          for (final id in decoded)
            if (id is String && id.isNotEmpty) id,
        ];
      }
    } on Object {
      // A damaged file falls back to the defaults; the next save repairs it.
    }
    return defaults;
  }

  Future<void> add(String id) async {
    final current = state.value ?? defaults;
    if (current.contains(id)) return;
    final next = [...current, id];
    state = AsyncData(next);
    await _save(next);
  }

  Future<void> remove(String id) async {
    final current = state.value ?? defaults;
    if (!current.contains(id)) return;
    final next = [...current]..remove(id);
    state = AsyncData(next);
    await _save(next);
  }

  Future<void> _save(List<String> ids) async {
    try {
      final file = _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(ids));
    } on Object {
      // Persistence is best effort; the live list remains applied.
    }
  }
}

/// The home screen's bottom dock: pinned apps, running apps, and an all-apps
/// drawer. It lives inside the launcher so app windows cover it and dragging
/// a home icon onto it pins that app.
class MobileDockLayer extends ConsumerStatefulWidget {
  const MobileDockLayer({super.key});

  @override
  ConsumerState<MobileDockLayer> createState() => _MobileDockLayerState();
}

class _MobileDockLayerState extends ConsumerState<MobileDockLayer> {
  final _dockKey = GlobalKey();
  HomeDragController? _drag;
  HomeDrag? _lastDrag;
  bool _drawerOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drag = HomeInteractionScope.of(context).drag;
    if (identical(drag, _drag)) return;
    _detachDrag();
    _drag = drag;
    _drag!.drag.addListener(_dragChanged);
    _drag!.pointer.addListener(_pointerChanged);
  }

  @override
  void dispose() {
    _detachDrag();
    super.dispose();
  }

  void _detachDrag() {
    _drag?.drag.removeListener(_dragChanged);
    _drag?.pointer.removeListener(_pointerChanged);
    _drag = null;
  }

  void _pointerChanged() {
    if (mounted) setState(() {});
  }

  void _dragChanged() {
    final current = _drag?.drag.value;
    final wasLanding = _lastDrag?.landing != null;
    if (current != null &&
        current.landing != null &&
        !wasLanding &&
        current.item.isApp &&
        _overDock(_drag!.pointer.value)) {
      unawaited(ref.read(dockPinnedProvider.notifier).add(current.item.id));
      ref.read(hapticsServiceProvider).pulse();
    }
    _lastDrag = current;
    if (mounted) setState(() {});
  }

  bool _overDock(Offset pointer) {
    final box = _dockKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size)
        .inflate(18)
        .contains(pointer);
  }

  void _showDockMenu(HomeGridItem item) {
    ref
        .read(shellPopupControllerProvider.notifier)
        .show(
          keyName: 'dock-item-${item.id}',
          debugLabel: 'Dock item',
          pointerPolicy: ShellPointerPolicy.fullScene,
          keyboardPolicy: ShellKeyboardPolicy.capture,
          dismissPolicy: ShellDismissPolicy.outsideTapAndEscape,
          builder: (context, handle) => _DockItemMenu(
            title: _nameOf(context, item),
            onRemove: () {
              handle.close();
              unawaited(
                ref.read(dockPinnedProvider.notifier).remove(item.id),
              );
            },
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(referenceShellProvider);
    final visible =
        state.primaryWindow == null &&
        !state.launchTransitionActive &&
        !state.overviewVisible &&
        !state.quickSettingsEngaged &&
        !state.lockLayerVisible &&
        !state.locked;
    if (!visible && _drawerOpen) {
      // Mutating during build is not allowed; defer the close.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _drawerOpen) setState(() => _drawerOpen = false);
      });
    }

    final catalog =
        ref
            .watch(homeGridControllerProvider)
            .asData
            ?.value
            .apps
            .where((item) => item.isApp)
            .toList(growable: false) ??
        const <HomeGridItem>[];
    final pinnedIds =
        ref.watch(dockPinnedProvider).value ?? DockPinnedController.defaults;
    final launcher = ref.read(appLauncherProvider);
    final byId = {for (final item in catalog) item.id: item};
    final windows = state.openAppWindows;
    final foreground = state.foregroundWindow?.objectId;

    final pinned = <HomeGridItem>[
      for (final id in pinnedIds)
        if (byId[id] != null) byId[id]!,
    ];

    // Map window identities back to launcher items so an app opened from a
    // shell command still gets its dock icon.
    final windowIndex = <String, HomeGridItem>{};
    for (final item in catalog) {
      final app = item.app;
      if (app == null) continue;
      for (final id in launcher.expectedWindowAppIds(app)) {
        windowIndex[id.toLowerCase()] = item;
      }
    }

    final runningExtras = <HomeGridItem>[];
    final seen = <String>{for (final item in pinned) item.id};
    for (final window in windows) {
      if (!window.isUserApp) continue;
      HomeGridItem? item = windowIndex[window.appId.toLowerCase()];
      if (item == null && window.isLocalFlutter) {
        for (final candidate in catalog) {
          if (candidate.localApp?.id == window.appId) {
            item = candidate;
            break;
          }
        }
      }
      if (item != null && seen.add(item.id)) runningExtras.add(item);
    }

    final theme = ShellTheme.of(context);
    final radius = theme.scaledRadius(24);
    final accent = theme.accentPalette.primary;
    final draggingOver =
        _drag?.drag.value != null &&
        _drag!.drag.value!.landing == null &&
        _drag!.drag.value!.item.isApp &&
        _overDock(_drag!.pointer.value);

    Widget entry(HomeGridItem item, {required bool pinned}) {
      final running = _windowFor(item, windows, launcher);
      return _DockButton(
        item: item,
        running: running != null,
        active: running != null && running.objectId == foreground,
        pinned: pinned,
        onLongPress: pinned ? () => _showDockMenu(item) : null,
        onTap: (rect) => launchHomeApp(context, ref, item, rect),
      );
    }

    final dock = ShellBackdropBlur(
      key: _dockKey,
      blur: theme.effectivePanelOpacity < 1,
      grouped: true,
      strength: 1,
      separateChild: true,
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.cardColor(context.shellColors.panelBackground),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: draggingOver
                ? accent
                : context.shellColors.hairlineSoft,
            width: draggingOver ? 2 : 1,
          ),
          boxShadow: [
            const BoxShadow(
              color: Color(0x66000000),
              blurRadius: 34,
              offset: Offset(0, 14),
            ),
            if (draggingOver)
              BoxShadow(
                color: accent.withValues(alpha: 0.30),
                blurRadius: 26,
                spreadRadius: 2,
              ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AllAppsButton(
                onPressed: () => setState(() => _drawerOpen = true),
              ),
              const _DockDivider(),
              for (final item in pinned)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: entry(item, pinned: true),
                ),
              if (runningExtras.isNotEmpty) ...[
                const _DockDivider(),
                for (final item in runningExtras)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: entry(item, pinned: false),
                  ),
              ],
            ],
          ),
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: AnimatedSlide(
              offset: visible ? Offset.zero : const Offset(0, 1.3),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(ignoring: !visible, child: dock),
              ),
            ),
          ),
        ),
        if (_drawerOpen && visible)
          Positioned.fill(
            child: _AllAppsDrawer(
              apps: catalog,
              onClose: () => setState(() => _drawerOpen = false),
              onLaunch: (item, rect) {
                setState(() => _drawerOpen = false);
                launchHomeApp(context, ref, item, rect);
              },
            ),
          ),
      ],
    );
  }
}

String _nameOf(BuildContext context, HomeGridItem item) =>
    item.localApp?.titleFor(context) ?? item.app?.name ?? '';

DenialWindow? _windowFor(
  HomeGridItem item,
  List<DenialWindow> windows,
  AppLauncher launcher,
) {
  final app = item.app;
  if (app != null) return launcher.findOpenWindow(app, windows);
  final local = item.localApp;
  if (local != null) {
    for (final window in windows) {
      if (window.isLocalFlutter && window.appId == local.id) {
        return window;
      }
    }
  }
  return null;
}

class _DockDivider extends StatelessWidget {
  const _DockDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: context.shellColors.hairlineSoft,
    );
  }
}

class _AllAppsButton extends StatefulWidget {
  const _AllAppsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_AllAppsButton> createState() => _AllAppsButtonState();
}

class _AllAppsButtonState extends State<_AllAppsButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l10n.dockAllApps,
      child: Semantics(
        button: true,
        label: context.l10n.dockAllApps,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: SizedBox(
              width: 62,
              height: 62,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: _hover
                        ? context.shellColors.hairlineSoft
                        : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.grid_view_rounded,
                    size: 28,
                    color: context.shellColors.panelText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockButton extends StatefulWidget {
  const _DockButton({
    required this.item,
    required this.running,
    required this.active,
    required this.pinned,
    required this.onTap,
    this.onLongPress,
  });

  final HomeGridItem item;
  final bool running;
  final bool active;
  final bool pinned;
  final void Function(Rect iconRect) onTap;
  final VoidCallback? onLongPress;

  @override
  State<_DockButton> createState() => _DockButtonState();
}

class _DockButtonState extends State<_DockButton> {
  bool _hover = false;
  bool _pressed = false;

  String get _name => _nameOf(context, widget.item);

  Rect? _iconRect() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette.primary;
    final scale = _pressed ? 0.93 : (_hover ? 1.05 : 1.0);
    return Tooltip(
      message: _name,
      child: Semantics(
        button: true,
        label: _name,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onLongPress: widget.onLongPress,
            onTap: () {
              final rect = _iconRect();
              if (rect != null) widget.onTap(rect);
            },
            child: SizedBox(
              width: 62,
              height: 74,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedScale(
                    scale: scale,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    child: AnimatedSlide(
                      offset: _hover ? const Offset(0, -0.06) : Offset.zero,
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: widget.active
                              ? [
                                  BoxShadow(
                                    color: accent.withValues(alpha: 0.30),
                                    blurRadius: 18,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: SizedBox.square(
                          dimension: 54,
                          child: LauncherIcon.of(widget.item),
                        ),
                      ),
                    ),
                  ),
                  if (widget.active)
                    Positioned(
                      bottom: 1,
                      child: Container(
                        width: 18,
                        height: 4,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    )
                  else if (widget.running)
                    Positioned(
                      bottom: 1,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                        ),
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

class _DockItemMenu extends StatelessWidget {
  const _DockItemMenu({required this.title, required this.onRemove});

  final String title;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    return Center(
      child: SizedBox(
        width: 320,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.panelColor(context.shellColors.panelBackground),
            borderRadius: BorderRadius.circular(theme.scaledRadius(18)),
            border: Border.all(color: context.shellColors.hairlineSoft),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 36,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.shellColors.panelText,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.shellColors.tileOff,
                      borderRadius: BorderRadius.circular(
                        theme.scaledRadius(12),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline_rounded,
                            size: 20,
                            color: context.shellColors.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            l10n.dockRemove,
                            style: TextStyle(
                              color: context.shellColors.panelText,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
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
      ),
    );
  }
}

class _AllAppsDrawer extends StatelessWidget {
  const _AllAppsDrawer({
    required this.apps,
    required this.onClose,
    required this.onLaunch,
  });

  final List<HomeGridItem> apps;
  final VoidCallback onClose;
  final void Function(HomeGridItem item, Rect rect) onLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final unique = <String, HomeGridItem>{
      for (final item in apps) item.id: item,
    }.values.toList(growable: false)
      ..sort(
        (a, b) => _nameOf(context, a).toLowerCase().compareTo(
          _nameOf(context, b).toLowerCase(),
        ),
      );
    return ColoredBox(
      color: const Color(0x73000000),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: FractionallySizedBox(
              widthFactor: 0.84,
              heightFactor: 0.76,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.cardColor(context.shellColors.panelBackground),
                  borderRadius: BorderRadius.circular(theme.scaledRadius(18)),
                  border: Border.all(color: context.shellColors.hairlineSoft),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 40,
                      offset: Offset(0, 18),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            context.l10n.dockAllApps,
                            style: TextStyle(
                              color: context.shellColors.panelText,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onClose,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(
                                Icons.close_rounded,
                                size: 22,
                                color: context.shellColors.textTertiary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: GridView.builder(
                          padding: EdgeInsets.zero,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 8,
                                mainAxisSpacing: 6,
                                crossAxisSpacing: 6,
                                mainAxisExtent: 92,
                              ),
                          itemCount: unique.length,
                          itemBuilder: (context, index) {
                            final item = unique[index];
                            return Builder(
                              builder: (tileContext) => GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  final box =
                                      tileContext.findRenderObject();
                                  final rect = box is RenderBox && box.hasSize
                                      ? box.localToGlobal(Offset.zero) &
                                            box.size
                                      : Rect.zero;
                                  onLaunch(item, rect);
                                },
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox.square(
                                      dimension: 46,
                                      child: LauncherIcon.of(item),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      _nameOf(context, item),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: context.shellColors.panelText,
                                        fontSize: 11.5,
                                        height: 1.1,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
