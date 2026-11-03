import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../home_grid_geometry.dart';
import '../home_interactions.dart';
import 'home_app_tile.dart';
import 'home_grid_page.dart';

/// The open folder: a glass panel that grows out of the folder's icon over
/// the frosted home, with the folder's name above it.
///
/// Its apps launch and lift like home's. An app dragged off the panel
/// closes it and continues onto the grid.
class HomeFolderPanel extends ConsumerStatefulWidget {
  const HomeFolderPanel({super.key});

  @override
  ConsumerState<HomeFolderPanel> createState() => _HomeFolderPanelState();
}

class _HomeFolderPanelState extends ConsumerState<HomeFolderPanel>
    with SingleTickerProviderStateMixin
    implements HomeFolderLayout {
  static const double _margin = 24;
  static const double _padding = 22;
  static const double _gap = 14;
  static const double _maxTileWidth = 118;
  static const double _tileHeight = 134;
  static const double _titleHeight = 72;
  static const double _radius = 34;

  /// Dims home beneath the frost; the panel itself is lighter.
  static const Color _scrim = Color(0x47000000);
  static const Color _tint = Color(0x24ffffff);

  late final _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 300),
  );

  /// The contents appear once the panel has mostly grown, and leave before
  /// it shrinks back.
  late final _content = _open.drive(
    CurveTween(curve: const Interval(0.45, 1, curve: Curves.easeOut)),
  );
  late HomeFolderController _folders;
  bool _attached = false;
  HomeOpenFolder? _shown;

  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  bool _editing = false;

  // The current layout, in this panel's coordinates.
  Rect _card = Rect.zero;
  int _columns = 4;
  Size _tile = const Size(_maxTileWidth, _tileHeight);

  @override
  void initState() {
    super.initState();
    _open.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _folders.open.value == null) {
        setState(() => _shown = null);
      }
    });
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _commitName();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final folders = HomeInteractionScope.of(context).folders;
    if (_attached && identical(folders, _folders)) return;
    if (_attached) _folders.open.removeListener(_openChanged);
    _folders = folders;
    _attached = true;
    _folders.open.addListener(_openChanged);
    _openChanged();
  }

  @override
  void dispose() {
    _folders.open.removeListener(_openChanged);
    if (identical(_folders.layout, this)) _folders.layout = null;
    _open.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _openChanged() {
    final open = _folders.open.value;
    if (open != null) {
      _folders.layout = this;
      _editing = false;
      setState(() => _shown = open);
      springTo(
        _open,
        1,
        spring: Motion.gentle,
        telemetryLabel: 'home_folder_open',
      );
    } else if (_shown != null) {
      _commitName();
      if (identical(_folders.layout, this)) _folders.layout = null;
      setState(() => _editing = false);
      _open.reverse();
    }
  }

  ({int index, HomeGridItem folder})? _folderIn(List<HomeGridItem?>? slots) {
    final id = _shown?.id;
    if (id == null || slots == null) return null;
    final index = slots.indexWhere((item) => item?.id == id);
    return index < 0 ? null : (index: index, folder: slots[index]!);
  }

  void _commitName() {
    if (!_editing) return;
    _editing = false;
    final slots = ref.read(homeGridControllerProvider).asData?.value.slots;
    final found = _folderIn(slots);
    final name = _name.text.trim();
    if (found != null && name.isNotEmpty) {
      ref
          .read(homeGridControllerProvider.notifier)
          .renameFolder(found.index, name);
    }
    if (mounted) setState(() {});
  }

  void _startEditing(String name) {
    _name
      ..text = name
      ..selection = TextSelection(baseOffset: 0, extentOffset: name.length);
    setState(() => _editing = true);
    _nameFocus.requestFocus();
  }

  // HomeFolderLayout --------------------------------------------------------

  RenderBox? get _box {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  Rect _toGlobal(Rect rect) {
    final box = _box;
    return box == null ? rect : rect.shift(box.localToGlobal(Offset.zero));
  }

  Rect _localTile(int position) => Rect.fromLTWH(
    _padding + (position % _columns) * (_tile.width + _gap),
    _padding + (position ~/ _columns) * (_tile.height + _gap),
    _tile.width,
    _tile.height,
  );

  @override
  Rect get bounds => _toGlobal(_card);

  @override
  int positionAt(Offset global) {
    final box = _box;
    final count =
        _folderIn(ref.read(homeGridControllerProvider).asData?.value.slots)
            ?.folder
            .folderApps
            .length ??
        1;
    final local =
        (box?.globalToLocal(global) ?? global) -
        _card.topLeft -
        const Offset(_padding, _padding);
    final rows = (count / _columns).ceil();
    final column = ((local.dx + _gap / 2) / (_tile.width + _gap)).floor().clamp(
      0,
      _columns - 1,
    );
    final row = ((local.dy + _gap / 2) / (_tile.height + _gap)).floor().clamp(
      0,
      math.max(0, rows - 1),
    );
    return (row * _columns + column).clamp(0, count - 1).toInt();
  }

  @override
  Rect tileRect(int position) =>
      _toGlobal(_localTile(position).shift(_card.topLeft));

  // Building -----------------------------------------------------------------

  void _layOut(Size size, int count) {
    final available = size.width - _margin * 2 - _padding * 2;
    _columns = available >= 4 * 96 + 3 * _gap ? 4 : 3;
    final tileWidth = math.min(
      _maxTileWidth,
      (available - (_columns - 1) * _gap) / _columns,
    );
    _tile = Size(tileWidth, _tileHeight);
    final rows = math.max(1, (count / _columns).ceil());
    final width = _padding * 2 + _columns * tileWidth + (_columns - 1) * _gap;
    final height = _padding * 2 + rows * _tileHeight + (rows - 1) * _gap;
    // Slightly above center, leaving room for the name.
    final top = math.max(
      _titleHeight + MediaQuery.paddingOf(context).top,
      size.height * 0.46 - height / 2,
    );
    _card = Rect.fromLTWH((size.width - width) / 2, top, width, height);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final slots = ref.watch(
      homeGridControllerProvider.select((value) => value.asData?.value.slots),
    );
    final found = _folderIn(slots);
    if (shown == null || found == null) {
      if (shown != null && _folders.open.value?.id == shown.id) {
        // The folder dissolved under the panel.
        WidgetsBinding.instance.addPostFrameCallback((_) => _folders.close());
      }
      return const SizedBox.shrink();
    }
    final folder = found.folder;
    final apps = folder.folderApps;
    // Closing, the panel lets home take touches at once.
    return IgnorePointer(
      ignoring: _folders.open.value == null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _layOut(constraints.biggest, apps.length);
          final name = folder.folderName ?? '';
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _folders.close,
                child: _Frost(overlay: _scrim, opacity: _open),
              ),
              RetainedWindowMotion(
                progress: _open,
                begin: shown.origin,
                beginIsGlobal: true,
                end: _card,
                beginRadius:
                    shown.origin.width * HomeTileMetrics.iconRadiusFraction,
                endRadius: context.shellTheme.scaledRadius(_radius),
                transformChild: false,
                child: const _Frost(overlay: _tint),
              ),
              // A tap between the apps stays on the panel, not the scrim.
              if (_folders.open.value != null)
                Positioned.fromRect(rect: _card, child: const AbsorbPointer()),
              Positioned(
                left: _margin,
                right: _margin,
                top: _card.top - _titleHeight,
                height: _titleHeight,
                child: FadeSnapshot(
                  opacity: _content,
                  child: Center(
                    child: _editing
                        ? _NameField(controller: _name, focusNode: _nameFocus)
                        : GestureDetector(
                            onTap: () => _startEditing(name),
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _NameField.style,
                            ),
                          ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: _card,
                child: FadeSnapshot(
                  opacity: _content,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var position = 0; position < apps.length; position++)
                        HomeSlidingTile(
                          key: ValueKey(apps[position].id),
                          rect: _localTile(position),
                          item: apps[position],
                          index: found.index,
                          inFolder: true,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The frosted wallpaper over [overlay], fading in with [opacity]. Without
/// a captured frost, the overlay alone darkens or lightens what is beneath.
class _Frost extends StatelessWidget {
  const _Frost({required this.overlay, this.opacity});

  final Color overlay;
  final Animation<double>? opacity;

  @override
  Widget build(BuildContext context) {
    final cache = WindowBackdropCache.maybeOf(context);
    if (cache == null) {
      final fallback = ColoredBox(
        color: overlay.withValues(alpha: math.min(1, overlay.a * 2.4)),
      );
      final fade = opacity;
      return fade == null
          ? fallback
          : FadeTransition(opacity: fade, child: fallback);
    }
    return WindowBackdropCache(
      backdrop: cache.backdrop,
      motion: cache.motion,
      overlayColor: overlay,
      child: Builder(
        builder: (context) => WindowBackdropSlice(
          cache: WindowBackdropCache.maybeOf(context)!,
          opacity: opacity,
          fadeOverlay: true,
        ),
      ),
    );
  }
}

class _NameField extends StatelessWidget {
  const _NameField({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  static const TextStyle style = TextStyle(
    color: ShellMediaColors.lightForeground,
    fontSize: 28,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    shadows: HomeAppTile.labelShadows,
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        hint: context.l10n.homeFolderRename,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          textAlign: TextAlign.center,
          maxLength: 40,
          maxLines: 1,
          style: style,
          cursorColor: ShellMediaColors.lightForeground,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration.collapsed(hintText: null)
              .copyWith(counterText: ''),
          onSubmitted: (_) => focusNode.unfocus(),
        ),
      ),
    );
  }
}
