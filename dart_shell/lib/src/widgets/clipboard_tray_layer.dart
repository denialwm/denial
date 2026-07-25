import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../models/clipboard_history.dart';
import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import '../state/clipboard_tray.dart';
import '../state/display_layout.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'shell_backdrop_blur.dart';

typedef _ClipboardEntryDragStart =
    void Function(
      ClipboardHistoryEntry entry,
      DragStartDetails details,
      Rect sourceRect,
    );
typedef _ClipboardEntryDragUpdate = void Function(DragUpdateDetails details);
typedef _ClipboardEntryDragEnd = void Function(DragEndDetails details);

class ClipboardTrayLayer extends ConsumerStatefulWidget {
  const ClipboardTrayLayer({super.key});

  @override
  ConsumerState<ClipboardTrayLayer> createState() => _ClipboardTrayLayerState();
}

class _ClipboardTrayLayerState extends ConsumerState<ClipboardTrayLayer>
    with TickerProviderStateMixin {
  late final AnimationController _motion;
  late final AnimationController _dragSettle;
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  _ClipboardDragPreviewState? _dragPreview;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this)
      ..addListener(_publishMotion)
      ..addStatusListener(_handleMotionStatus);
    _dragSettle = AnimationController(vsync: this, duration: Motion.cardSettle);
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode(debugLabel: 'clipboard-history-search')
      ..addListener(_handleSearchFocusChanged);
  }

  @override
  void dispose() {
    _motion
      ..removeListener(_publishMotion)
      ..removeStatusListener(_handleMotionStatus)
      ..dispose();
    _dragSettle.dispose();
    _searchController.dispose();
    _searchFocusNode
      ..removeListener(_handleSearchFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _handleSearchFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _publishMotion() {
    ref.read(clipboardTrayProvider.notifier).setMotionProgress(_motion.value);
  }

  void _handleMotionStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      _searchFocusNode.unfocus();
    }
  }

  void _animateTo(bool open) {
    final target = open ? 1.0 : 0.0;
    if (!open) {
      _searchFocusNode.unfocus();
    }
    if ((_motion.value - target).abs() < 0.001) {
      _motion.value = target;
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.value = target;
    } else {
      springTo(
        _motion,
        target,
        spring: Motion.gentle,
        telemetryLabel: 'clipboard_tray',
      );
    }
  }

  void _beginTrayDrag(DragStartDetails details) {
    _motion.stop();
    ref
        .read(clipboardTrayProvider.notifier)
        .setMotionProgress(_motion.value, gestureActive: true);
  }

  void _updateTrayDrag(
    DragUpdateDetails details,
    ClipboardTrayEdge edge,
    double extent,
  ) {
    final delta = switch (edge) {
      ClipboardTrayEdge.left => details.delta.dx,
      ClipboardTrayEdge.right => -details.delta.dx,
      ClipboardTrayEdge.top => details.delta.dy,
      ClipboardTrayEdge.bottom => -details.delta.dy,
    };
    _motion.value = unit(_motion.value + delta / extent);
  }

  void _endTrayDrag(
    DragEndDetails details,
    ClipboardTrayEdge edge,
    double extent,
  ) {
    final pixelsPerSecond = switch (edge) {
      ClipboardTrayEdge.left => details.velocity.pixelsPerSecond.dx,
      ClipboardTrayEdge.right => -details.velocity.pixelsPerSecond.dx,
      ClipboardTrayEdge.top => details.velocity.pixelsPerSecond.dy,
      ClipboardTrayEdge.bottom => -details.velocity.pixelsPerSecond.dy,
    };
    final velocity = pixelsPerSecond / extent;
    final open = velocity.abs() > 0.45 ? velocity > 0 : _motion.value >= 0.5;
    ref.read(clipboardTrayProvider.notifier).settle(open: open);
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.value = open ? 1 : 0;
    } else {
      springTo(
        _motion,
        open ? 1 : 0,
        velocity: velocity,
        spring: Motion.gentle,
        telemetryLabel: 'clipboard_tray_gesture',
      );
    }
  }

  void _closeTray() {
    _searchFocusNode.unfocus();
    ref.read(clipboardTrayProvider.notifier).close();
  }

  void _beginEntryDrag(
    ClipboardHistoryEntry entry,
    DragStartDetails details,
    Rect sourceRect,
  ) {
    final width = math.min(sourceRect.width, 320.0);
    final height = math.min(sourceRect.height, 190.0);
    final anchor = Offset(
      sourceRect.width <= 0
          ? 0.5
          : ((details.globalPosition.dx - sourceRect.left) / sourceRect.width)
                .clamp(0.08, 0.92)
                .toDouble(),
      sourceRect.height <= 0
          ? 0.2
          : ((details.globalPosition.dy - sourceRect.top) / sourceRect.height)
                .clamp(0.08, 0.92)
                .toDouble(),
    );
    _dragSettle
      ..stop()
      ..value = 0;
    setState(() {
      _dragPreview = _ClipboardDragPreviewState(
        entry: entry,
        position: details.globalPosition,
        sourceRect: sourceRect,
        size: Size(width, height),
        anchor: anchor,
      );
    });
    unawaited(_startNativeEntryDrag(entry.id));
  }

  Future<void> _startNativeEntryDrag(int itemId) async {
    final started = await ref
        .read(clipboardHistoryProvider.notifier)
        .startDrag(itemId);
    if (!started && mounted && _dragPreview?.entry.id == itemId) {
      _settleEntryDrag(Offset.zero, cancelled: true);
    }
  }

  void _updateEntryDrag(DragUpdateDetails details) {
    final preview = _dragPreview;
    if (preview == null || preview.settling) {
      return;
    }
    setState(() {
      _dragPreview = preview.copyWith(position: details.globalPosition);
    });
  }

  void _endEntryDrag(DragEndDetails details) {
    _settleEntryDrag(details.velocity.pixelsPerSecond);
  }

  void _cancelEntryDrag() {
    _settleEntryDrag(Offset.zero, cancelled: true);
  }

  void _settleEntryDrag(Offset velocity, {bool cancelled = false}) {
    final preview = _dragPreview;
    if (preview == null || preview.settling) {
      return;
    }
    setState(() {
      _dragPreview = preview.copyWith(
        settling: true,
        cancelled: cancelled,
        releaseVelocity: velocity,
      );
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _dragPreview = null);
      return;
    }
    unawaited(
      _dragSettle.forward(from: 0).whenComplete(() {
        if (mounted && _dragPreview?.entry.id == preview.entry.id) {
          setState(() => _dragPreview = null);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(
      shellSettingsProvider.select((settings) => settings.layout),
    );
    final displayLayout = ref.watch(displayLayoutProvider);
    final tray = ref.watch(clipboardTrayProvider);
    ref.listen<bool>(
      clipboardTrayProvider.select((state) => state.open),
      (_, open) => _animateTo(open),
    );

    final edge = layout.clipboardTrayEdge;
    final viewSize = MediaQuery.sizeOf(context);
    final canvas = Offset.zero & viewSize;
    final requestedOutput = clipboardTrayTargetOutput(tray, displayLayout);
    final requestedOutputRect = requestedOutput?.logicalRect.intersect(canvas);
    final outputRect =
        requestedOutputRect == null || requestedOutputRect.isEmpty
        ? canvas
        : requestedOutputRect;
    final extent = clipboardTrayExtentForSize(layout, outputRect.size);
    final trayRect = _trayRect(outputRect, edge, extent);
    final dragPreview = _dragPreview;
    final dismissActive = tray.open && dragPreview == null;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _closeTray,
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !dismissActive,
              child: ShellInputRegion(
                debugLabel: 'Clipboard outside-dismiss barrier',
                active: dismissActive,
                pointerPolicy: ShellPointerPolicy.fullScene,
                child: Semantics(
                  button: true,
                  label: 'Close clipboard history',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeTray,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: trayRect,
            child: AnimatedBuilder(
              animation: _motion,
              builder: (context, child) {
                final hiddenOffset = _hiddenOffset(edge, extent);
                return Transform.translate(
                  offset: hiddenOffset * (1 - _motion.value),
                  child: child,
                );
              },
              child: ShellInputRegion(
                debugLabel: 'Clipboard history tray',
                active: tray.painted,
                keyboardPolicy: tray.open && _searchFocusNode.hasFocus
                    ? ShellKeyboardPolicy.capture
                    : ShellKeyboardPolicy.none,
                child: _ClipboardTraySurface(
                  edge: edge,
                  extent: extent,
                  searchController: _searchController,
                  searchFocusNode: _searchFocusNode,
                  onSearchChanged: ref
                      .read(clipboardHistoryProvider.notifier)
                      .setQuery,
                  onClose: _closeTray,
                  onDragStart: _beginTrayDrag,
                  onDragUpdate: (details) =>
                      _updateTrayDrag(details, edge, extent),
                  onDragEnd: (details) => _endTrayDrag(details, edge, extent),
                  onEntryDragStart: _beginEntryDrag,
                  onEntryDragUpdate: _updateEntryDrag,
                  onEntryDragEnd: _endEntryDrag,
                  onEntryDragCancel: _cancelEntryDrag,
                ),
              ),
            ),
          ),
          if (dragPreview != null)
            _ClipboardDragPreview(state: dragPreview, settle: _dragSettle),
        ],
      ),
    );
  }
}

class _ClipboardTraySurface extends ConsumerWidget {
  const _ClipboardTraySurface({
    required this.edge,
    required this.extent,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearchChanged,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
    required this.onEntryDragCancel,
  });

  final ClipboardTrayEdge edge;
  final double extent;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClose;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;
  final VoidCallback onEntryDragCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shellTheme = ShellTheme.of(context);
    final accent = shellTheme.accentPalette;
    final radius = _panelRadius(edge, shellTheme.panelRadius);
    final history = ref.watch(clipboardHistoryProvider);
    final controller = ref.read(clipboardHistoryProvider.notifier);
    final horizontal = !_isVerticalEdge(edge);

    return RepaintBoundary(
      child: ShellBackdropBlur(
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border(
                left: edge == ClipboardTrayEdge.right
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
                right: edge == ClipboardTrayEdge.left
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
                top: edge == ClipboardTrayEdge.bottom
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
                bottom: edge == ClipboardTrayEdge.top
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
              ),
              gradient: LinearGradient(
                begin: _gradientBegin(edge),
                end: _gradientEnd(edge),
                colors: [
                  shellTheme.panelColor(
                    Color.alphaBlend(
                      accent.primary.withValues(alpha: 0.14),
                      ShellColors.surfaceContainerLow,
                    ),
                  ),
                  shellTheme.panelColor(ShellColors.panelBackgroundBottom),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.primary.withValues(alpha: 0.14),
                  blurRadius: 32,
                  spreadRadius: -8,
                ),
                const BoxShadow(
                  color: ShellColors.shadow,
                  blurRadius: 36,
                  spreadRadius: -12,
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                edge == ClipboardTrayEdge.left ? 18 : 16,
                edge == ClipboardTrayEdge.top ? 18 : 16,
                edge == ClipboardTrayEdge.right ? 18 : 16,
                edge == ClipboardTrayEdge.bottom ? 18 : 16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ClipboardTrayHeader(
                    horizontal: horizontal,
                    snapshot: history.snapshot,
                    searchController: searchController,
                    searchFocusNode: searchFocusNode,
                    onSearchChanged: onSearchChanged,
                    onClear: controller.clear,
                    onDragStart: onDragStart,
                    onDragUpdate: onDragUpdate,
                    onDragEnd: onDragEnd,
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: _ClipboardHistoryBody(
                      horizontal: horizontal,
                      state: history,
                      onActivate: (entry) async {
                        if (await controller.activate(entry.id)) {
                          onClose();
                        }
                      },
                      onPinnedChanged: (entry) =>
                          controller.setPinned(entry.id, pinned: !entry.pinned),
                      onDelete: (entry) => controller.delete(entry.id),
                      onEntryDragStart: onEntryDragStart,
                      onEntryDragUpdate: onEntryDragUpdate,
                      onEntryDragEnd: onEntryDragEnd,
                      onEntryDragCancel: onEntryDragCancel,
                      onRetry: controller.refresh,
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

class _ClipboardTrayHeader extends StatelessWidget {
  const _ClipboardTrayHeader({
    required this.horizontal,
    required this.snapshot,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearchChanged,
    required this.onClear,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool horizontal;
  final ClipboardHistorySnapshot? snapshot;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClear;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final count = snapshot?.entries.length ?? 0;
    final search = TextField(
      controller: searchController,
      focusNode: searchFocusNode,
      onChanged: onSearchChanged,
      textInputAction: TextInputAction.search,
      style: ShellText.base,
      cursorColor: accent.primary,
      decoration: InputDecoration(
        hintText: 'Search text, files, apps…',
        hintStyle: ShellText.base.copyWith(color: ShellColors.textTertiary),
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: ShellColors.textTertiary,
        ),
        suffixIcon: searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: () {
                  searchController.clear();
                  onSearchChanged('');
                },
                icon: const Icon(Icons.close_rounded),
              ),
        filled: true,
        fillColor: ShellColors.surfaceContainerHigh.withValues(alpha: 0.74),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: ShellColors.hairlineSoft),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: accent.primary, width: 1.4),
        ),
      ),
    );
    return Semantics(
      label: 'Drag clipboard tray toward its edge to close',
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: horizontal ? null : onDragStart,
        onHorizontalDragUpdate: horizontal ? null : onDragUpdate,
        onHorizontalDragEnd: horizontal ? null : onDragEnd,
        onVerticalDragStart: horizontal ? onDragStart : null,
        onVerticalDragUpdate: horizontal ? onDragUpdate : null,
        onVerticalDragEnd: horizontal ? onDragEnd : null,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: horizontal ? 560 : double.infinity,
                  ),
                  child: search,
                ),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: accent.subtle,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: accent.outline),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Text(
                    '$count',
                    semanticsLabel: count == 1
                        ? '1 clipboard item'
                        : '$count clipboard items',
                    style: ShellText.cardTitle.copyWith(
                      color: accent.primary,
                      fontFamily: ShellText.systemBarFontFamily,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            _TrayIconButton(
              icon: Icons.delete_sweep_outlined,
              label: 'Clear clipboard history',
              onPressed: count == 0 ? null : onClear,
            ),
          ],
        ),
      ),
    );
  }
}

class _ClipboardHistoryBody extends StatelessWidget {
  const _ClipboardHistoryBody({
    required this.horizontal,
    required this.state,
    required this.onActivate,
    required this.onPinnedChanged,
    required this.onDelete,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
    required this.onEntryDragCancel,
    required this.onRetry,
  });

  final bool horizontal;
  final ClipboardHistoryViewState state;
  final ValueChanged<ClipboardHistoryEntry> onActivate;
  final ValueChanged<ClipboardHistoryEntry> onPinnedChanged;
  final ValueChanged<ClipboardHistoryEntry> onDelete;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;
  final VoidCallback onEntryDragCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.snapshot?.locked ?? false) {
      return const _ClipboardMessage(
        icon: Icons.lock_outline_rounded,
        title: 'History is sealed',
        message: 'Clipboard contents stay hidden while the session is locked.',
      );
    }
    if (state.entries.isEmpty && state.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.entries.isEmpty && state.error != null) {
      return _ClipboardMessage(
        icon: Icons.sync_problem_rounded,
        title: 'Clipboard bridge unavailable',
        message: 'The native history service did not answer.',
        actionLabel: 'Try again',
        onAction: onRetry,
      );
    }
    if (state.entries.isEmpty) {
      return _ClipboardMessage(
        icon: state.query.isEmpty
            ? Icons.content_paste_off_rounded
            : Icons.search_off_rounded,
        title: state.query.isEmpty ? 'Nothing captured yet' : 'No echoes found',
        message: state.query.isEmpty
            ? 'Copy text, an image, or files and they will appear here.'
            : 'Try a different word, file type, or application.',
      );
    }

    final entries = <ClipboardHistoryEntry>[
      ...state.entries.where((entry) => entry.pinned),
      ...state.entries.where((entry) => !entry.pinned),
    ];
    return Stack(
      children: [
        ListView.separated(
          scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
          padding: const EdgeInsets.only(bottom: 6),
          itemCount: entries.length,
          separatorBuilder: (_, _) =>
              SizedBox(width: horizontal ? 12 : 0, height: horizontal ? 0 : 12),
          itemBuilder: (context, index) {
            final entry = entries[index];
            return SizedBox(
              width: horizontal
                  ? clipboardImageMimeType(entry) != null
                        ? 340
                        : clipboardFileMimeType(entry) != null
                        ? 320
                        : 292
                  : double.infinity,
              height: horizontal
                  ? null
                  : clipboardImageMimeType(entry) != null
                  ? 196
                  : clipboardFileMimeType(entry) != null
                  ? 154
                  : 142,
              child: _ClipboardHistoryCard(
                entry: entry,
                horizontalTray: horizontal,
                busy: state.busyItemIds.contains(entry.id),
                onActivate: () => onActivate(entry),
                onPinnedChanged: () => onPinnedChanged(entry),
                onDelete: () => onDelete(entry),
                onEntryDragStart: onEntryDragStart,
                onEntryDragUpdate: onEntryDragUpdate,
                onEntryDragEnd: onEntryDragEnd,
                onEntryDragCancel: onEntryDragCancel,
              ),
            );
          },
        ),
        if (state.loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _ClipboardHistoryCard extends ConsumerStatefulWidget {
  const _ClipboardHistoryCard({
    required this.entry,
    required this.horizontalTray,
    required this.busy,
    required this.onActivate,
    required this.onPinnedChanged,
    required this.onDelete,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
    required this.onEntryDragCancel,
  });

  final ClipboardHistoryEntry entry;
  final bool horizontalTray;
  final bool busy;
  final VoidCallback onActivate;
  final VoidCallback onPinnedChanged;
  final VoidCallback onDelete;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;
  final VoidCallback onEntryDragCancel;

  @override
  ConsumerState<_ClipboardHistoryCard> createState() =>
      _ClipboardHistoryCardState();
}

class _ClipboardHistoryCardState extends ConsumerState<_ClipboardHistoryCard> {
  bool _hovered = false;
  bool _dragging = false;

  void _handleDragStart(DragStartDetails details) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) {
      return;
    }
    final sourceRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    setState(() => _dragging = true);
    widget.onEntryDragStart(widget.entry, details, sourceRect);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    widget.onEntryDragUpdate(details);
  }

  void _handleDragEnd(DragEndDetails details) {
    setState(() => _dragging = false);
    widget.onEntryDragEnd(details);
  }

  void _handleDragCancel() {
    setState(() => _dragging = false);
    widget.onEntryDragCancel();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final accent = ShellTheme.of(context).accentPalette;
    final fileMime = clipboardFileMimeType(entry);
    final imageMime = clipboardImageMimeType(entry);
    final typeLabel = fileMime != null
        ? 'FILES'
        : imageMime != null
        ? 'IMAGE'
        : 'TEXT';

    return Semantics(
      key: ValueKey<String>('clipboard-history-card-${entry.id}'),
      button: true,
      label: '$typeLabel clipboard item. ${entry.preview}',
      hint: 'Activate to paste it into the focused app. Drag it to drop it.',
      child: MouseRegion(
        cursor: widget.busy
            ? SystemMouseCursors.forbidden
            : SystemMouseCursors.grab,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: widget.busy ? null : _handleDragStart,
          onPanUpdate: widget.busy ? null : _handleDragUpdate,
          onPanEnd: widget.busy ? null : _handleDragEnd,
          onPanCancel: widget.busy ? null : _handleDragCancel,
          child: AnimatedOpacity(
            duration: Motion.cardSettle,
            opacity: _dragging ? 0.28 : 1,
            child: AnimatedScale(
              duration: Motion.cardSettle,
              curve: Motion.standard,
              scale: _dragging
                  ? 0.975
                  : _hovered
                  ? 1.006
                  : 1,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(19),
                  onTap: widget.busy ? null : widget.onActivate,
                  child: AnimatedContainer(
                    duration: Motion.cardSettle,
                    curve: Motion.standard,
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        accent.primary.withValues(
                          alpha: entry.active
                              ? 0.1
                              : _hovered
                              ? 0.055
                              : 0.018,
                        ),
                        ShellColors.surfaceContainerHigh.withValues(
                          alpha: 0.82,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(19),
                      border: Border.all(
                        color: entry.active || _hovered
                            ? accent.outline
                            : ShellColors.hairlineSoft,
                      ),
                      boxShadow: _hovered
                          ? const [
                              BoxShadow(
                                color: ShellColors.shadowSoft,
                                blurRadius: 16,
                                offset: Offset(0, 7),
                              ),
                            ]
                          : const [],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            child: AnimatedContainer(
                              duration: Motion.tile,
                              width: entry.active ? 4 : 2,
                              color: entry.active
                                  ? accent.primary
                                  : accent.primary.withValues(alpha: 0.28),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: fileMime != null
                                      ? _ClipboardFilePreview(
                                          entry: entry,
                                          mimeType: fileMime,
                                        )
                                      : imageMime != null
                                      ? _ClipboardImagePreview(
                                          entry: entry,
                                          mimeType: imageMime,
                                        )
                                      : _ClipboardTextPreview(
                                          text: entry.preview,
                                          maxLines: widget.horizontalTray
                                              ? 10
                                              : 4,
                                        ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _ClipboardCardMetadata(
                                        entry: entry,
                                        typeLabel: typeLabel,
                                      ),
                                    ),
                                    _CardAction(
                                      icon: entry.pinned
                                          ? Icons.push_pin_rounded
                                          : Icons.push_pin_outlined,
                                      label: entry.pinned
                                          ? 'Unpin clipboard item'
                                          : 'Pin clipboard item',
                                      selected: entry.pinned,
                                      onPressed: widget.busy
                                          ? null
                                          : widget.onPinnedChanged,
                                    ),
                                    _CardAction(
                                      icon: Icons.delete_outline_rounded,
                                      label: 'Delete clipboard item',
                                      onPressed: widget.busy
                                          ? null
                                          : widget.onDelete,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (widget.busy)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Color(0x22000000),
                                child: Center(
                                  child: SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
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
        ),
      ),
    );
  }
}

class _ClipboardImagePreview extends ConsumerWidget {
  const _ClipboardImagePreview({required this.entry, required this.mimeType});

  final ClipboardHistoryEntry entry;
  final String mimeType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(
      clipboardEntryDataProvider(ClipboardDataKey(entry.id, mimeType)),
    );
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: ShellColors.surfaceContainerLow,
          child: Stack(
            fit: StackFit.expand,
            children: [
              data.when(
                data: (payload) => Image.memory(
                  payload.bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  semanticLabel: 'Clipboard image preview',
                  errorBuilder: (_, _, _) => const _PreviewFallback(
                    icon: Icons.broken_image_outlined,
                    label: 'Preview unavailable',
                  ),
                ),
                loading: () => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (_, _) => const _PreviewFallback(
                  icon: Icons.broken_image_outlined,
                  label: 'Preview unavailable',
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xbb101318),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      '${entry.width} × ${entry.height}',
                      style: ShellText.base.copyWith(
                        fontFamily: ShellText.systemBarFontFamily,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClipboardFilePreview extends ConsumerWidget {
  const _ClipboardFilePreview({required this.entry, required this.mimeType});

  final ClipboardHistoryEntry entry;
  final String mimeType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ShellTheme.of(context).accentPalette;
    final data = ref.watch(
      clipboardEntryDataProvider(ClipboardDataKey(entry.id, mimeType)),
    );
    final files = data.maybeWhen(
      data: (payload) =>
          clipboardFileUris(utf8.decode(payload.bytes, allowMalformed: true)),
      orElse: () => clipboardFileUris(entry.preview),
    );
    final first = files.isEmpty ? null : files.first;
    final thumbnail = first != null && clipboardUriCanRenderAsImage(first)
        ? ref.watch(clipboardLocalFilePreviewProvider(first))
        : null;
    final isFolder = first?.path.endsWith('/') ?? false;
    final name = first == null
        ? 'File selection'
        : first.pathSegments
                  .where((segment) => segment.isNotEmpty)
                  .lastOrNull ??
              first.path;
    final location = first?.toFilePath(windows: false) ?? entry.preview;

    return LayoutBuilder(
      builder: (context, constraints) {
        final previewExtent = constraints.maxHeight.clamp(48.0, 104.0);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.surfaceContainerLow.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: ShellColors.hairlineSoft),
          ),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: previewExtent,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent.subtle,
                        border: Border.all(color: accent.outline),
                      ),
                      child: thumbnail == null
                          ? Icon(
                              isFolder
                                  ? Icons.folder_rounded
                                  : Icons.insert_drive_file_rounded,
                              size: 28,
                              color: accent.primary,
                            )
                          : thumbnail.when(
                              data: (bytes) => bytes == null
                                  ? Icon(
                                      Icons.image_outlined,
                                      size: 28,
                                      color: accent.primary,
                                    )
                                  : Image.memory(
                                      bytes,
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      filterQuality: FilterQuality.medium,
                                      semanticLabel: 'Image file thumbnail',
                                      errorBuilder: (_, _, _) => Icon(
                                        Icons.broken_image_outlined,
                                        size: 27,
                                        color: accent.primary,
                                      ),
                                    ),
                              loading: () => const Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                              error: (_, _) => Icon(
                                Icons.broken_image_outlined,
                                size: 27,
                                color: accent.primary,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.cardTitle.copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.base.copyWith(
                          color: ShellColors.textTertiary,
                          fontFamily: ShellText.systemBarFontFamily,
                          fontSize: 10,
                          height: 1.3,
                        ),
                      ),
                      if (files.length > 1) ...[
                        const SizedBox(height: 5),
                        Text(
                          '+ ${files.length - 1} more',
                          style: ShellText.cardTitle.copyWith(
                            color: accent.primary,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ClipboardTextPreview extends StatelessWidget {
  const _ClipboardTextPreview({required this.text, this.maxLines = 7});

  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final normalized = text.replaceAll(RegExp(r'\s+$'), '');
    final bounded = normalized.length > 360
        ? '${normalized.substring(0, 360)}…'
        : normalized;
    return Align(
      alignment: Alignment.topLeft,
      child: Text(
        bounded,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: ShellText.base.copyWith(
          color: ShellColors.textPrimary,
          fontSize: 13,
          height: 1.42,
        ),
      ),
    );
  }
}

class _ClipboardCardMetadata extends StatelessWidget {
  const _ClipboardCardMetadata({required this.entry, required this.typeLabel});

  final ClipboardHistoryEntry entry;
  final String typeLabel;

  @override
  Widget build(BuildContext context) {
    final source = entry.sourceTitle.trim().isNotEmpty
        ? entry.sourceTitle.trim()
        : entry.sourceAppId.trim().isNotEmpty
        ? entry.sourceAppId.trim()
        : switch (entry.origin) {
            ClipboardHistoryOrigin.wayland => 'Wayland',
            ClipboardHistoryOrigin.x11 => 'X11',
            ClipboardHistoryOrigin.flutter => 'Denial',
          };
    return Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: entry.active
                ? ShellTheme.of(context).accentPalette.subtle
                : ShellColors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(99),
          ),
          child: SizedBox.square(
            dimension: 22,
            child: Icon(
              switch (typeLabel) {
                'FILES' => Icons.folder_copy_outlined,
                'IMAGE' => Icons.image_outlined,
                _ => Icons.notes_rounded,
              },
              size: 12,
              color: entry.active
                  ? ShellTheme.of(context).accent
                  : ShellColors.textTertiary,
            ),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  color: ShellColors.textSecondary,
                  fontSize: 10,
                ),
              ),
              Text(
                '${_relativeTime(entry.capturedAt)} · ${_formatBytes(entry.byteLength)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.base.copyWith(
                  color: ShellColors.textTertiary,
                  fontFamily: ShellText.systemBarFontFamily,
                  fontSize: 8.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

@immutable
class _ClipboardDragPreviewState {
  const _ClipboardDragPreviewState({
    required this.entry,
    required this.position,
    required this.sourceRect,
    required this.size,
    required this.anchor,
    this.settling = false,
    this.cancelled = false,
    this.releaseVelocity = Offset.zero,
  });

  final ClipboardHistoryEntry entry;
  final Offset position;
  final Rect sourceRect;
  final Size size;
  final Offset anchor;
  final bool settling;
  final bool cancelled;
  final Offset releaseVelocity;

  _ClipboardDragPreviewState copyWith({
    Offset? position,
    bool? settling,
    bool? cancelled,
    Offset? releaseVelocity,
  }) {
    return _ClipboardDragPreviewState(
      entry: entry,
      position: position ?? this.position,
      sourceRect: sourceRect,
      size: size,
      anchor: anchor,
      settling: settling ?? this.settling,
      cancelled: cancelled ?? this.cancelled,
      releaseVelocity: releaseVelocity ?? this.releaseVelocity,
    );
  }
}

class _ClipboardDragPreview extends StatelessWidget {
  const _ClipboardDragPreview({required this.state, required this.settle});

  final _ClipboardDragPreviewState state;
  final Animation<double> settle;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settle,
      builder: (context, child) {
        final raw = state.settling ? settle.value : 0.0;
        final progress = Curves.easeOutCubic.transform(raw);
        final origin =
            state.position -
            Offset(
              state.size.width * state.anchor.dx,
              state.size.height * state.anchor.dy,
            );
        final target = state.cancelled
            ? state.sourceRect.center -
                  Offset(state.size.width / 2, state.size.height / 2)
            : origin +
                  Offset(
                    state.releaseVelocity.dx.clamp(-2400.0, 2400.0) * 0.035,
                    state.releaseVelocity.dy.clamp(-2400.0, 2400.0) * 0.035,
                  );
        final position = Offset.lerp(origin, target, progress)!;
        final scale = state.settling
            ? 1.035 - (state.cancelled ? 0.14 : 0.19) * progress
            : 1.035;
        final turn = state.settling && !state.cancelled
            ? (state.releaseVelocity.dx / 80000).clamp(-0.035, 0.035) * progress
            : 0.0;
        return Positioned(
          key: const ValueKey<String>('clipboard-drag-preview'),
          left: position.dx,
          top: position.dy,
          width: state.size.width,
          height: state.size.height,
          child: IgnorePointer(
            child: Opacity(
              opacity: state.settling ? 1 - progress : 1,
              child: Transform.rotate(
                angle: turn,
                child: Transform.scale(scale: scale, child: child),
              ),
            ),
          ),
        );
      },
      child: RepaintBoundary(child: _ClipboardDragGhost(entry: state.entry)),
    );
  }
}

class _ClipboardDragGhost extends StatelessWidget {
  const _ClipboardDragGhost({required this.entry});

  final ClipboardHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final fileMime = clipboardFileMimeType(entry);
    final imageMime = clipboardImageMimeType(entry);
    final typeLabel = fileMime != null
        ? 'FILES'
        : imageMime != null
        ? 'IMAGE'
        : 'TEXT';
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            accent.primary.withValues(alpha: 0.13),
            ShellColors.surfaceContainerHighest,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.primary.withValues(alpha: 0.82)),
          boxShadow: [
            BoxShadow(
              color: accent.primary.withValues(alpha: 0.26),
              blurRadius: 28,
              spreadRadius: -5,
            ),
            const BoxShadow(
              color: ShellColors.shadow,
              blurRadius: 30,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 10, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: fileMime != null
                      ? _ClipboardFilePreview(entry: entry, mimeType: fileMime)
                      : imageMime != null
                      ? _ClipboardImagePreview(
                          entry: entry,
                          mimeType: imageMime,
                        )
                      : _ClipboardTextPreview(text: entry.preview, maxLines: 4),
                ),
                const SizedBox(height: 7),
                _ClipboardCardMetadata(entry: entry, typeLabel: typeLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrayIconButton extends StatelessWidget {
  const _TrayIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: ShellColors.textSecondary,
        backgroundColor: Colors.transparent,
        disabledForegroundColor: ShellColors.glyphInactive,
      ),
      icon: Icon(icon, size: 19),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return IconButton(
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      tooltip: label,
      onPressed: onPressed,
      color: selected ? accent.primary : ShellColors.textTertiary,
      disabledColor: ShellColors.glyphInactive,
      icon: Icon(icon, size: 16),
    );
  }
}

class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: ShellColors.textTertiary),
          const SizedBox(height: 6),
          Text(
            label,
            style: ShellText.base.copyWith(
              color: ShellColors.textTertiary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipboardMessage extends StatelessWidget {
  const _ClipboardMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: accent.subtle,
                shape: BoxShape.circle,
                border: Border.all(color: accent.outline),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Icon(icon, size: 28, color: accent.primary),
              ),
            ),
            const SizedBox(height: 15),
            Text(
              title,
              textAlign: TextAlign.center,
              style: ShellText.statusClock,
            ),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: ShellColors.textTertiary,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

bool _isVerticalEdge(ClipboardTrayEdge edge) =>
    edge == ClipboardTrayEdge.left || edge == ClipboardTrayEdge.right;

Offset _hiddenOffset(ClipboardTrayEdge edge, double extent) => switch (edge) {
  ClipboardTrayEdge.left => Offset(-extent, 0),
  ClipboardTrayEdge.right => Offset(extent, 0),
  ClipboardTrayEdge.top => Offset(0, -extent),
  ClipboardTrayEdge.bottom => Offset(0, extent),
};

Rect _trayRect(Rect output, ClipboardTrayEdge edge, double extent) =>
    switch (edge) {
      ClipboardTrayEdge.left => Rect.fromLTWH(
        output.left,
        output.top,
        extent,
        output.height,
      ),
      ClipboardTrayEdge.right => Rect.fromLTWH(
        output.right - extent,
        output.top,
        extent,
        output.height,
      ),
      ClipboardTrayEdge.top => Rect.fromLTWH(
        output.left,
        output.top,
        output.width,
        extent,
      ),
      ClipboardTrayEdge.bottom => Rect.fromLTWH(
        output.left,
        output.bottom - extent,
        output.width,
        extent,
      ),
    };

BorderRadius _panelRadius(ClipboardTrayEdge edge, double radius) =>
    switch (edge) {
      ClipboardTrayEdge.left => BorderRadius.only(
        topRight: Radius.circular(radius),
        bottomRight: Radius.circular(radius),
      ),
      ClipboardTrayEdge.right => BorderRadius.only(
        topLeft: Radius.circular(radius),
        bottomLeft: Radius.circular(radius),
      ),
      ClipboardTrayEdge.top => BorderRadius.only(
        bottomLeft: Radius.circular(radius),
        bottomRight: Radius.circular(radius),
      ),
      ClipboardTrayEdge.bottom => BorderRadius.only(
        topLeft: Radius.circular(radius),
        topRight: Radius.circular(radius),
      ),
    };

Alignment _gradientBegin(ClipboardTrayEdge edge) => switch (edge) {
  ClipboardTrayEdge.left => Alignment.centerRight,
  ClipboardTrayEdge.right => Alignment.centerLeft,
  ClipboardTrayEdge.top => Alignment.bottomCenter,
  ClipboardTrayEdge.bottom => Alignment.topCenter,
};

Alignment _gradientEnd(ClipboardTrayEdge edge) => switch (edge) {
  ClipboardTrayEdge.left => Alignment.centerLeft,
  ClipboardTrayEdge.right => Alignment.centerRight,
  ClipboardTrayEdge.top => Alignment.topCenter,
  ClipboardTrayEdge.bottom => Alignment.bottomCenter,
};

String _relativeTime(DateTime capturedAt) {
  final elapsed = DateTime.now().difference(capturedAt);
  if (elapsed.isNegative || elapsed.inSeconds < 5) {
    return 'now';
  }
  if (elapsed.inMinutes < 1) {
    return '${elapsed.inSeconds}s';
  }
  if (elapsed.inHours < 1) {
    return '${elapsed.inMinutes}m';
  }
  if (elapsed.inDays < 1) {
    return '${elapsed.inHours}h';
  }
  return '${elapsed.inDays}d';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
