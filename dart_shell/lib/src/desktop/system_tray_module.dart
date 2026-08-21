import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../launcher/launcher_providers.dart';
import '../launcher/repositories/desktop_apps_repository.dart';
import '../launcher/runtime_paths.dart';
import '../models/system_tray_item.dart';
import '../services/background_worker.dart';
import '../state/system_tray.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/shell_cursor.dart';

@immutable
class SystemTrayIconRequest {
  const SystemTrayIconRequest({
    required this.iconName,
    required this.iconThemePath,
  });

  final String iconName;
  final String iconThemePath;

  @override
  bool operator ==(Object other) {
    return other is SystemTrayIconRequest &&
        other.iconName == iconName &&
        other.iconThemePath == iconThemePath;
  }

  @override
  int get hashCode => Object.hash(iconName, iconThemePath);
}

const int _maxResolvedTrayIconPaths = 256;
const int _resolveTrayIconOperation = 1;

final _systemTrayIconResolverProvider = Provider<_SystemTrayIconResolver>((
  ref,
) {
  final resolver = _SystemTrayIconResolver(
    environment: ref.watch(runtimePathsProvider).environment,
  );
  ref.onDispose(resolver.dispose);
  return resolver;
});

final systemTrayIconPathProvider =
    FutureProvider.family<String?, SystemTrayIconRequest>(
      (ref, request) =>
          ref.watch(_systemTrayIconResolverProvider).resolve(request),
      isAutoDispose: true,
    );

class _SystemTrayIconResolver {
  _SystemTrayIconResolver({required Map<String, String> environment})
    : _environment = Map<String, String>.of(environment),
      _worker = BackgroundWorker(
        entrypoint: _runSystemTrayIconResolver,
        debugName: 'denial-system-tray-icon-resolver',
      );

  final Map<String, String> _environment;
  final BackgroundWorker _worker;

  Future<String?> resolve(SystemTrayIconRequest request) async {
    try {
      return await _worker.invoke<String?>(
        operation: _resolveTrayIconOperation,
        payload: <Object?>[
          _environment,
          request.iconName,
          request.iconThemePath,
        ],
        decode: (response) => response as String?,
      );
    } on Object {
      return null;
    }
  }

  void dispose() {
    unawaited(_worker.close());
  }
}

@pragma('vm:entry-point')
void _runSystemTrayIconResolver(List<SendPort> bootstrap) {
  DesktopAppsRepository? repository;
  final resolved = <(String, String), String?>{};
  serveBackgroundWorker(bootstrap, (operation, payload) {
    if (operation != _resolveTrayIconOperation ||
        payload is! List<Object?> ||
        payload.length != 3 ||
        payload[0] is! Map ||
        payload[1] is! String ||
        payload[2] is! String) {
      throw ArgumentError.value(payload, 'payload');
    }
    repository ??= DesktopAppsRepository(
      paths: RuntimePaths(
        environment: Map<String, String>.from(payload[0]! as Map),
      ),
    );
    final iconName = payload[1]! as String;
    final iconThemePath = payload[2]! as String;
    final key = (iconName, iconThemePath);
    String? path;
    if (resolved.containsKey(key)) {
      path = resolved.remove(key);
    } else {
      path = repository!.resolveTrayIcon(
        iconName: iconName,
        iconThemePath: iconThemePath,
      );
    }
    resolved[key] = path;
    if (resolved.length > _maxResolvedTrayIconPaths) {
      resolved.remove(resolved.keys.first);
    }
    return path;
  });
}

typedef SystemTrayInvoke =
    FutureOr<bool> Function(
      SystemTrayItem item,
      SystemTrayAction action,
      Offset position,
    );
typedef SystemTrayMenuLoader =
    Future<List<SystemTrayMenuEntry>?> Function(SystemTrayItem item);
typedef SystemTrayMenuInvoke =
    FutureOr<bool> Function(SystemTrayItem item, int entryId);

ValueKey<String> systemTrayItemButtonKey(String id) =>
    ValueKey<String>('system-tray-item:$id');
ValueKey<String> systemTrayItemIconKey(String id) =>
    ValueKey<String>('system-tray-item-icon:$id');
ValueKey<int> systemTrayMenuEntryButtonKey(int id) => ValueKey<int>(id);
ValueKey<String> systemTrayMenuEntryLabelKey(int id) =>
    ValueKey<String>('system-tray-menu-entry-label:$id');
const systemTrayMenuDismissLayerKey = ValueKey<String>(
  'system-tray-menu-dismiss-layer',
);

void dismissOpenSystemTrayMenu(WidgetRef ref) {
  ref.read(_systemTrayMenuSessionProvider.notifier).dismiss();
}

class _SystemTrayMenuSession {
  const _SystemTrayMenuSession({required this.owner, required this.dismiss});

  final Object owner;
  final VoidCallback dismiss;
}

final _systemTrayMenuSessionProvider =
    NotifierProvider<_SystemTrayMenuSessionController, _SystemTrayMenuSession?>(
      _SystemTrayMenuSessionController.new,
    );

class _SystemTrayMenuSessionController
    extends Notifier<_SystemTrayMenuSession?> {
  final Set<int> _menuPointerDowns = <int>{};

  @override
  _SystemTrayMenuSession? build() => null;

  void show(Object owner, VoidCallback dismiss) {
    final previous = state;
    if (previous != null && !identical(previous.owner, owner)) {
      previous.dismiss();
    }
    state = _SystemTrayMenuSession(owner: owner, dismiss: dismiss);
  }

  void clear(Object owner) {
    if (identical(state?.owner, owner)) {
      state = null;
    }
  }

  void dismiss() {
    final current = state;
    if (current == null) {
      return;
    }
    state = null;
    current.dismiss();
  }

  void noteMenuPointerDown(int pointer) {
    _menuPointerDowns.add(pointer);
  }

  bool takeMenuPointerDown(int pointer) {
    return _menuPointerDowns.remove(pointer);
  }
}

/// Passively observes client and Flutter clicks while an application menu is
/// open.
///
/// This surface owns no pointer area. Native input mirrors client clicks, while
/// Flutter's global pointer route observes shell clicks after hit testing. The
/// original target receives either event without requiring a second click.
class SystemTrayMenuDismissLayer extends ConsumerStatefulWidget {
  const SystemTrayMenuDismissLayer({super.key});

  @override
  ConsumerState<SystemTrayMenuDismissLayer> createState() =>
      _SystemTrayMenuDismissLayerState();
}

class _SystemTrayMenuDismissLayerState
    extends ConsumerState<SystemTrayMenuDismissLayer> {
  late final _SystemTrayMenuSessionController _menuSessions;

  @override
  void initState() {
    super.initState();
    _menuSessions = ref.read(_systemTrayMenuSessionProvider.notifier);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
  }

  void _handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent ||
        ref.read(_systemTrayMenuSessionProvider) == null) {
      return;
    }
    scheduleMicrotask(() {
      if (!mounted || _menuSessions.takeMenuPointerDown(event.pointer)) {
        return;
      }
      _menuSessions.dismiss();
    });
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handlePointerEvent,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(_systemTrayMenuSessionProvider) != null;
    return ShellInputRegion(
      debugLabel: 'System tray menu dismissal',
      active: active,
      pointerPolicy: ShellPointerPolicy.none,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      observeClientPointerPresses: true,
      child: const SizedBox.shrink(key: systemTrayMenuDismissLayerKey),
    );
  }
}

class SystemTrayModule extends ConsumerWidget {
  const SystemTrayModule({
    required this.horizontal,
    required this.accent,
    required this.items,
    this.onInvoke,
    this.onLoadMenu,
    this.onInvokeMenu,
    super.key,
  });

  final bool horizontal;
  final Color accent;
  final List<SystemTrayItem> items;
  final SystemTrayInvoke? onInvoke;
  final SystemTrayMenuLoader? onLoadMenu;
  final SystemTrayMenuInvoke? onInvokeMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoke =
        onInvoke ??
        (item, action, position) => ref
            .read(systemTrayProvider.notifier)
            .invoke(item, action, position);
    final loadMenu =
        onLoadMenu ??
        (item) => ref.read(systemTrayProvider.notifier).loadMenu(item);
    final invokeMenu =
        onInvokeMenu ??
        (item, entryId) => ref
            .read(systemTrayProvider.notifier)
            .activateMenuEntry(item, entryId);
    return ShellInputRegion(
      debugLabel: 'System tray',
      child: Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var index = 0; index < items.length; index += 1) ...[
            if (index > 0)
              SizedBox(width: horizontal ? 4 : 0, height: horizontal ? 0 : 4),
            _SystemTrayButton(
              key: systemTrayItemButtonKey(items[index].id),
              item: items[index],
              accent: accent,
              onInvoke: invoke,
              onLoadMenu: loadMenu,
              onInvokeMenu: invokeMenu,
            ),
          ],
        ],
      ),
    );
  }
}

class _SystemTrayButton extends ConsumerStatefulWidget {
  const _SystemTrayButton({
    required this.item,
    required this.accent,
    required this.onInvoke,
    required this.onLoadMenu,
    required this.onInvokeMenu,
    super.key,
  });

  final SystemTrayItem item;
  final Color accent;
  final SystemTrayInvoke onInvoke;
  final SystemTrayMenuLoader onLoadMenu;
  final SystemTrayMenuInvoke onInvokeMenu;

  @override
  ConsumerState<_SystemTrayButton> createState() => _SystemTrayButtonState();
}

class _SystemTrayButtonState extends ConsumerState<_SystemTrayButton> {
  final MenuController _menuController = MenuController();
  final Object _menuOwner = Object();
  late final _SystemTrayMenuSessionController _menuSessions;
  Offset? _primaryPosition;
  List<SystemTrayMenuEntry> _menuEntries = const <SystemTrayMenuEntry>[];
  int _menuGeneration = 0;

  @override
  void initState() {
    super.initState();
    _menuSessions = ref.read(_systemTrayMenuSessionProvider.notifier);
  }

  Future<bool> _invoke(SystemTrayAction action, Offset position) async {
    return await widget.onInvoke(widget.item, action, position);
  }

  Offset _centerPosition() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return Offset.zero;
  }

  Offset _localPosition(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.globalToLocal(globalPosition);
    }
    return Offset.zero;
  }

  Future<bool> _openFlutterMenu(Offset position) async {
    if (!widget.item.menuAvailable) {
      return false;
    }
    if (_menuController.isOpen) {
      _menuController.close();
      return true;
    }
    final generation = ++_menuGeneration;
    final entries = await widget.onLoadMenu(widget.item);
    if (!mounted || generation != _menuGeneration || entries == null) {
      return false;
    }
    final visibleEntries = entries
        .where((entry) => entry.visible)
        .toList(growable: false);
    if (visibleEntries.isEmpty) {
      return false;
    }
    setState(() => _menuEntries = visibleEntries);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _menuGeneration) {
      return false;
    }
    _menuController.open(position: _localPosition(position));
    return true;
  }

  Future<void> _activatePrimary(Offset position) async {
    if (widget.item.primaryOpensMenu) {
      if (!await _openFlutterMenu(position)) {
        await _invoke(SystemTrayAction.contextMenu, position);
      }
      return;
    }
    if (await _invoke(SystemTrayAction.activate, position)) {
      return;
    }
    if (!await _openFlutterMenu(position) && widget.item.menuAvailable) {
      await _invoke(SystemTrayAction.contextMenu, position);
    }
  }

  Future<void> _openContextMenu(Offset position) async {
    if (!await _openFlutterMenu(position)) {
      await _invoke(SystemTrayAction.contextMenu, position);
    }
  }

  Widget _menuInputRegion({required String debugLabel, required Widget child}) {
    return ShellInputRegion(
      debugLabel: debugLabel,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) =>
            _menuSessions.noteMenuPointerDown(event.pointer),
        child: child,
      ),
    );
  }

  List<Widget> _buildMenuChildren(
    BuildContext context,
    List<SystemTrayMenuEntry> entries,
  ) {
    final output = <Widget>[];
    final menuStyle = _menuStyle(context);
    final reservesToggleColumn = entries.any(
      (entry) =>
          entry.visible && entry.toggleType != SystemTrayMenuToggleType.none,
    );
    for (final entry in entries.where((entry) => entry.visible)) {
      if (entry.separator) {
        output.add(
          _menuInputRegion(
            debugLabel: 'System tray menu separator',
            child: const Divider(
              height: 1,
              thickness: 1,
              indent: 6,
              endIndent: 6,
              color: ShellColors.hairlineSoft,
            ),
          ),
        );
        continue;
      }
      final children = _buildMenuChildren(context, entry.children);
      final label = entry.label.isEmpty ? 'Untitled item' : entry.label;
      final leadingIcon = _menuLeadingIcon(
        entry,
        reserveSpace: reservesToggleColumn,
      );
      final style = _menuButtonStyle(context, destructive: entry.destructive);
      final child = Padding(
        key: systemTrayMenuEntryLabelKey(entry.id),
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: true,
            applyHeightToLastDescent: true,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      );
      if (children.isNotEmpty && entry.enabled) {
        output.add(
          _menuInputRegion(
            debugLabel: 'System tray submenu entry',
            child: SubmenuButton(
              key: systemTrayMenuEntryButtonKey(entry.id),
              leadingIcon: leadingIcon,
              style: style,
              menuStyle: menuStyle,
              useRootOverlay: false,
              hoverOpenDelay: const Duration(milliseconds: 140),
              menuChildren: children,
              child: child,
            ),
          ),
        );
        continue;
      }
      output.add(
        _menuInputRegion(
          debugLabel: 'System tray menu entry',
          child: MenuItemButton(
            key: systemTrayMenuEntryButtonKey(entry.id),
            leadingIcon: leadingIcon,
            style: style,
            onPressed: entry.enabled && entry.id > 0
                ? () => unawaited(
                    Future<bool>.value(
                      widget.onInvokeMenu(widget.item, entry.id),
                    ),
                  )
                : null,
            child: child,
          ),
        ),
      );
    }
    return output;
  }

  MenuStyle _menuStyle(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final viewHeight = MediaQuery.sizeOf(context).height;
    return MenuStyle(
      backgroundColor: const WidgetStatePropertyAll<Color>(
        ShellColors.panelBackgroundBottom,
      ),
      shadowColor: const WidgetStatePropertyAll<Color>(ShellColors.shadow),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      elevation: const WidgetStatePropertyAll<double>(14),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(vertical: 4),
      ),
      minimumSize: const WidgetStatePropertyAll<Size>(Size(164, 0)),
      maximumSize: WidgetStatePropertyAll<Size>(
        Size(320, (viewHeight - 16).clamp(120, 560).toDouble()),
      ),
      side: WidgetStatePropertyAll<BorderSide>(
        BorderSide(color: accent.outline, width: 1),
      ),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  ButtonStyle _menuButtonStyle(
    BuildContext context, {
    required bool destructive,
  }) {
    final accent = ShellTheme.of(context).accentPalette;
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.disabled)) {
          return ShellColors.textTertiary;
        }
        return destructive
            ? ShellColors.performanceBad
            : ShellColors.textPrimary;
      }),
      iconColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.disabled)) {
          return ShellColors.textTertiary;
        }
        return destructive
            ? ShellColors.performanceBad
            : ShellColors.textSecondary;
      }),
      backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return accent.subtle;
        }
        return Colors.transparent;
      }),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      textStyle: const WidgetStatePropertyAll<TextStyle>(
        TextStyle(
          fontFamilyFallback: ShellText.fallbackFontFamilies,
          fontSize: 12,
          height: 1.25,
          leadingDistribution: TextLeadingDistribution.even,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.none,
        ),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 10),
      ),
      minimumSize: const WidgetStatePropertyAll<Size>(Size(164, 28)),
      maximumSize: const WidgetStatePropertyAll<Size>(Size(320, 28)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
      ),
      alignment: AlignmentDirectional.centerStart,
    );
  }

  Widget? _menuLeadingIcon(
    SystemTrayMenuEntry entry, {
    required bool reserveSpace,
  }) {
    if (entry.toggleType == SystemTrayMenuToggleType.none) {
      return reserveSpace ? const SizedBox(width: 16, height: 16) : null;
    }
    if (entry.toggleState < 0) {
      return const Icon(Icons.remove, size: 16);
    }
    if (entry.toggleState == 0) {
      return const SizedBox(width: 16, height: 16);
    }
    return Icon(
      entry.toggleType == SystemTrayMenuToggleType.radio
          ? Icons.radio_button_checked
          : Icons.check,
      size: 16,
    );
  }

  @override
  void didUpdateWidget(covariant _SystemTrayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.menuPath != widget.item.menuPath) {
      _menuGeneration += 1;
      _menuEntries = const <SystemTrayMenuEntry>[];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _menuController.close();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final attention = item.status == SystemTrayStatus.needsAttention;
    final passive = item.status == SystemTrayStatus.passive;
    final label = item.title.isNotEmpty
        ? item.title
        : item.iconName.isNotEmpty
        ? item.iconName
        : 'System tray';
    void activate() => unawaited(_activatePrimary(_centerPosition()));
    return MenuAnchor(
      controller: _menuController,
      consumeOutsideTap: false,
      useRootOverlay: false,
      clipBehavior: Clip.antiAlias,
      style: _menuStyle(context),
      onOpen: () => _menuSessions.show(_menuOwner, _menuController.close),
      onClose: () => _menuSessions.clear(_menuOwner),
      menuChildren: _buildMenuChildren(context, _menuEntries),
      child: Semantics(
        button: true,
        label: label,
        value: _statusSemantics(item.status),
        onTap: activate,
        child: ExcludeSemantics(
          child: MouseRegion(
            cursor: ShellMouseCursors.link,
            child: Listener(
              onPointerDown: (event) {
                if (event.buttons == kMiddleMouseButton) {
                  unawaited(
                    _invoke(SystemTrayAction.secondaryActivate, event.position),
                  );
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _primaryPosition = details.globalPosition,
                onTap: () => unawaited(
                  _activatePrimary(_primaryPosition ?? _centerPosition()),
                ),
                onSecondaryTapDown: (details) =>
                    unawaited(_openContextMenu(details.globalPosition)),
                child: SizedBox.square(
                  dimension: 22,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      Center(
                        child: SizedBox.square(
                          key: systemTrayItemIconKey(item.id),
                          dimension: 18,
                          child: Opacity(
                            opacity: passive ? 0.52 : 1,
                            child: RepaintBoundary(
                              child: _SystemTrayIcon(item: item),
                            ),
                          ),
                        ),
                      ),
                      if (attention)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: widget.accent,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox.square(dimension: 4),
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

  @override
  void dispose() {
    _menuSessions.clear(_menuOwner);
    super.dispose();
  }
}

class _SystemTrayIcon extends ConsumerWidget {
  const _SystemTrayIcon({required this.item});

  final SystemTrayItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? path;
    if (item.iconName.isNotEmpty) {
      path = ref
          .watch(
            systemTrayIconPathProvider(
              SystemTrayIconRequest(
                iconName: item.iconName,
                iconThemePath: item.iconThemePath,
              ),
            ),
          )
          .value;
    }
    if (path != null) {
      return AppIconImage(iconPath: path);
    }
    final pixmap = item.iconPixmap;
    return pixmap == null
        ? const AppIconImage(iconPath: null)
        : _RawTrayIcon(pixmap: pixmap);
  }
}

class _RawTrayIcon extends StatefulWidget {
  const _RawTrayIcon({required this.pixmap});

  final SystemTrayIconPixmap pixmap;

  @override
  State<_RawTrayIcon> createState() => _RawTrayIconState();
}

class _RawTrayIconState extends State<_RawTrayIcon> {
  ui.Image? _decoded;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void didUpdateWidget(covariant _RawTrayIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pixmap.width != widget.pixmap.width ||
        oldWidget.pixmap.height != widget.pixmap.height ||
        !listEquals(oldWidget.pixmap.rgba, widget.pixmap.rgba)) {
      unawaited(_decode());
    }
  }

  Future<void> _decode() async {
    final generation = ++_generation;
    final pixmap = widget.pixmap;
    if (pixmap.width <= 0 ||
        pixmap.height <= 0 ||
        pixmap.width > 512 ||
        pixmap.height > 512 ||
        pixmap.rgba.length != pixmap.width * pixmap.height * 4 ||
        pixmap.rgba.length > 512 * 1024) {
      _replace(null, generation);
      return;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(pixmap.rgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: pixmap.width,
        height: pixmap.height,
        rowBytes: pixmap.width * 4,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      decoded = (await codec.getNextFrame()).image;
    } on Object {
      decoded?.dispose();
      decoded = null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
    _replace(decoded, generation);
  }

  void _replace(ui.Image? image, int generation) {
    if (!mounted || generation != _generation) {
      image?.dispose();
      return;
    }
    final previous = _decoded;
    setState(() => _decoded = image);
    previous?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;
    return decoded == null
        ? const AppIconImage(iconPath: null)
        : RawImage(
            image: decoded,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          );
  }

  @override
  void dispose() {
    _generation += 1;
    _decoded?.dispose();
    super.dispose();
  }
}

String _statusSemantics(SystemTrayStatus status) => switch (status) {
  SystemTrayStatus.passive => 'Passive',
  SystemTrayStatus.active => 'Active',
  SystemTrayStatus.needsAttention => 'Needs attention',
};
