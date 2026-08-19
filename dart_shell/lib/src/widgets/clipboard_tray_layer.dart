import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../localization/denial_localizations.dart';
import '../models/clipboard_history.dart';
import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import '../state/clipboard_tray.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'shell_backdrop_blur.dart';

typedef _ClipboardEntryDragStart =
    void Function(
      ClipboardHistoryEntry entry,
      Offset position,
      Rect sourceRect,
    );
typedef _ClipboardEntryDragUpdate = ValueChanged<Offset>;
typedef _ClipboardEntryDragEnd = VoidCallback;

class ClipboardTrayLayer extends ConsumerStatefulWidget {
  const ClipboardTrayLayer({super.key});

  @override
  ConsumerState<ClipboardTrayLayer> createState() => _ClipboardTrayLayerState();
}

class _ClipboardTrayLayerState extends ConsumerState<ClipboardTrayLayer>
    with TickerProviderStateMixin {
  late final AnimationController _motion;
  late final StreamSubscription<Offset> _cursorPositionSubscription;
  _ClipboardEntryDragState? _entryDrag;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this)..addListener(_publishMotion);
    _cursorPositionSubscription = ref
        .read(denialBridgeProvider)
        .cursorPositions
        .listen(_updateEntryDragPosition);
  }

  @override
  void dispose() {
    _motion
      ..removeListener(_publishMotion)
      ..dispose();
    unawaited(_cursorPositionSubscription.cancel());
    super.dispose();
  }

  void _publishMotion() {
    ref.read(clipboardTrayProvider.notifier).setMotionProgress(_motion.value);
  }

  void _animateTo(bool open) {
    final target = open ? 1.0 : 0.0;
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
    ref.read(clipboardTrayProvider.notifier).close();
  }

  void _beginEntryDrag(
    ClipboardHistoryEntry entry,
    Offset position,
    Rect sourceRect,
  ) {
    final anchor = Offset(
      sourceRect.width <= 0
          ? 0.5
          : ((position.dx - sourceRect.left) / sourceRect.width)
                .clamp(0.0, 1.0)
                .toDouble(),
      sourceRect.height <= 0
          ? 0.5
          : ((position.dy - sourceRect.top) / sourceRect.height)
                .clamp(0.0, 1.0)
                .toDouble(),
    );
    setState(() {
      _entryDrag = _ClipboardEntryDragState(
        entry: entry,
        position: position,
        size: sourceRect.size,
        anchor: anchor,
      );
    });
    unawaited(_startNativeEntryDrag(entry.id));
  }

  Future<void> _startNativeEntryDrag(int itemId) async {
    final started = await ref
        .read(clipboardHistoryProvider.notifier)
        .startDrag(itemId);
    if (!started && mounted && _entryDrag?.entry.id == itemId) {
      _finishEntryDrag();
    }
  }

  void _updateEntryDragPosition(Offset position) {
    final drag = _entryDrag;
    if (drag == null ||
        !position.dx.isFinite ||
        !position.dy.isFinite ||
        position == drag.position) {
      return;
    }
    setState(() {
      _entryDrag = drag.copyWith(position: position);
    });
  }

  void _finishEntryDrag() {
    if (_entryDrag != null) {
      setState(() => _entryDrag = null);
    }
  }

  void _endEntryDrag() {
    _finishEntryDrag();
    _closeTray();
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
    final entryDrag = _entryDrag;
    final trayVisible = tray.open || tray.painted;
    final dismissActive = tray.open && entryDrag == null;

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
                  label: context.l10n.clipboardCloseHistory,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeTray,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: outputRect,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fromRect(
                    rect: trayRect.shift(-outputRect.topLeft),
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
                        child: trayVisible
                            ? _ClipboardTraySurface(
                                edge: edge,
                                onClose: _closeTray,
                                onDragStart: _beginTrayDrag,
                                onDragUpdate: (details) =>
                                    _updateTrayDrag(details, edge, extent),
                                onDragEnd: (details) =>
                                    _endTrayDrag(details, edge, extent),
                                draggedEntryId: entryDrag?.entry.id,
                                onEntryDragStart: _beginEntryDrag,
                                onEntryDragUpdate: _updateEntryDragPosition,
                                onEntryDragEnd: _endEntryDrag,
                              )
                            : const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (entryDrag != null) _DraggedClipboardEntry(state: entryDrag),
        ],
      ),
    );
  }
}

class _ClipboardTraySurface extends ConsumerWidget {
  const _ClipboardTraySurface({
    required this.edge,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.draggedEntryId,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
  });

  final ClipboardTrayEdge edge;
  final VoidCallback onClose;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final int? draggedEntryId;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;

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
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: _clipboardTrayContentPadding(edge),
                    child: _ClipboardHistoryBody(
                      horizontal: horizontal,
                      state: history,
                      draggedEntryId: draggedEntryId,
                      onActivate: (entry) async {
                        if (await controller.activate(entry.id)) {
                          onClose();
                        }
                      },
                      onDelete: (entry) => controller.delete(entry.id),
                      onSetPinned: (entry, pinned) =>
                          controller.setPinned(entry.id, pinned: pinned),
                      onClearAll: controller.clear,
                      onEntryDragStart: onEntryDragStart,
                      onEntryDragUpdate: onEntryDragUpdate,
                      onEntryDragEnd: onEntryDragEnd,
                      onRetry: controller.refresh,
                    ),
                  ),
                ),
                _ClipboardTrayDragRegion(
                  edge: edge,
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardTrayDragRegion extends StatelessWidget {
  const _ClipboardTrayDragRegion({
    required this.edge,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ClipboardTrayEdge edge;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final verticalTray = _isVerticalEdge(edge);
    final region = Semantics(
      label: context.l10n.clipboardDragToClose,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: verticalTray ? onDragStart : null,
        onHorizontalDragUpdate: verticalTray ? onDragUpdate : null,
        onHorizontalDragEnd: verticalTray ? onDragEnd : null,
        onVerticalDragStart: verticalTray ? null : onDragStart,
        onVerticalDragUpdate: verticalTray ? null : onDragUpdate,
        onVerticalDragEnd: verticalTray ? null : onDragEnd,
        child: const SizedBox.expand(),
      ),
    );
    return switch (edge) {
      ClipboardTrayEdge.left => Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 8,
        child: region,
      ),
      ClipboardTrayEdge.right => Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: 8,
        child: region,
      ),
      ClipboardTrayEdge.top => Positioned(
        left: 0,
        top: 0,
        right: 0,
        height: 18,
        child: region,
      ),
      ClipboardTrayEdge.bottom => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 18,
        child: region,
      ),
    };
  }
}

class _ClipboardHistoryBody extends StatelessWidget {
  const _ClipboardHistoryBody({
    required this.horizontal,
    required this.state,
    required this.draggedEntryId,
    required this.onActivate,
    required this.onDelete,
    required this.onSetPinned,
    required this.onClearAll,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
    required this.onRetry,
  });

  final bool horizontal;
  final ClipboardHistoryViewState state;
  final int? draggedEntryId;
  final ValueChanged<ClipboardHistoryEntry> onActivate;
  final ValueChanged<ClipboardHistoryEntry> onDelete;
  final void Function(ClipboardHistoryEntry entry, bool pinned) onSetPinned;
  final VoidCallback onClearAll;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.snapshot?.locked ?? false) {
      return _ClipboardMessage(
        icon: Icons.lock_outline_rounded,
        title: l10n.clipboardHistoryLockedTitle,
        message: l10n.clipboardHistoryLockedDescription,
      );
    }
    if (state.entries.isEmpty && state.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.entries.isEmpty && state.error != null) {
      return _ClipboardMessage(
        icon: Icons.sync_problem_rounded,
        title: l10n.clipboardUnavailableTitle,
        message: l10n.clipboardUnavailableDescription,
        actionLabel: l10n.commonRetry,
        onAction: onRetry,
      );
    }
    if (state.entries.isEmpty) {
      return _ClipboardMessage(
        icon: state.query.isEmpty
            ? Icons.content_paste_off_rounded
            : Icons.search_off_rounded,
        title: state.query.isEmpty
            ? l10n.clipboardEmptyTitle
            : l10n.clipboardNoSearchResultsTitle,
        message: state.query.isEmpty
            ? l10n.clipboardEmptyDescription
            : l10n.clipboardNoSearchResultsDescription,
      );
    }

    final entries = <ClipboardHistoryEntry>[
      ...state.entries.where((entry) => entry.pinned),
      ...state.entries.where((entry) => !entry.pinned),
    ];
    final clearable = entries.any((entry) => !entry.pinned);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _ClipboardClearAllButton(
            enabled: clearable && !state.clearing,
            clearing: state.clearing,
            onPressed: onClearAll,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Stack(
            children: [
              ListView.separated(
                scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
                physics: draggedEntryId == null
                    ? null
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 6),
                itemCount: entries.length,
                separatorBuilder: (_, _) => SizedBox(
                  width: horizontal ? 12 : 0,
                  height: horizontal ? 0 : 12,
                ),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return Align(
                    alignment: horizontal
                        ? Alignment.centerLeft
                        : Alignment.topCenter,
                    child: _ClipboardHistoryCard(
                      entry: entry,
                      busy: state.busyItemIds.contains(entry.id),
                      dragging: draggedEntryId == entry.id,
                      onActivate: () => onActivate(entry),
                      onDelete: () => onDelete(entry),
                      onTogglePinned: () => onSetPinned(entry, !entry.pinned),
                      onEntryDragStart: onEntryDragStart,
                      onEntryDragUpdate: onEntryDragUpdate,
                      onEntryDragEnd: onEntryDragEnd,
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
          ),
        ),
      ],
    );
  }
}

class _ClipboardClearAllButton extends StatelessWidget {
  const _ClipboardClearAllButton({
    required this.enabled,
    required this.clearing,
    required this.onPressed,
  });

  final bool enabled;
  final bool clearing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.clipboardClearAll;
    return Tooltip(
      message: label,
      child: TextButton.icon(
        key: const ValueKey<String>('clipboard-clear-all'),
        onPressed: enabled ? onPressed : null,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          foregroundColor: ShellColors.textSecondary,
          disabledForegroundColor: ShellColors.glyphInactive,
          backgroundColor: ShellColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: ShellColors.hairlineSoft),
          ),
        ),
        icon: clearing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.clear_all_rounded, size: 18),
        label: Text(label),
      ),
    );
  }
}

class _ClipboardHistoryCard extends StatefulWidget {
  const _ClipboardHistoryCard({
    required this.entry,
    required this.busy,
    required this.dragging,
    required this.onActivate,
    required this.onDelete,
    required this.onTogglePinned,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
  });

  final ClipboardHistoryEntry entry;
  final bool busy;
  final bool dragging;
  final VoidCallback onActivate;
  final VoidCallback onDelete;
  final VoidCallback onTogglePinned;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;

  @override
  State<_ClipboardHistoryCard> createState() => _ClipboardHistoryCardState();
}

class _ClipboardHistoryCardState extends State<_ClipboardHistoryCard> {
  static const _dragThreshold = 5.0;

  final GlobalKey _itemKey = GlobalKey();
  bool _hovered = false;
  bool _focused = false;
  int? _trackedPointer;
  Offset? _pointerDownPosition;
  Rect? _sourceRect;
  bool _dragStarted = false;

  void _setHovered(bool hovered) {
    if (_hovered != hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _setFocused(bool focused) {
    if (_focused != focused) {
      setState(() => _focused = focused);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.busy ||
        widget.dragging ||
        _trackedPointer != null ||
        event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    final renderBox = _itemKey.currentContext?.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) {
      return;
    }
    _trackedPointer = event.pointer;
    _pointerDownPosition = event.position;
    _sourceRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _trackedPointer) {
      return;
    }
    if (!_dragStarted) {
      final down = _pointerDownPosition;
      final sourceRect = _sourceRect;
      if (down == null ||
          sourceRect == null ||
          (event.position - down).distance < _dragThreshold) {
        return;
      }
      _dragStarted = true;
      widget.onEntryDragStart(widget.entry, event.position, sourceRect);
      return;
    }
    widget.onEntryDragUpdate(event.position);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _trackedPointer) {
      return;
    }
    final dragStarted = _dragStarted;
    final activate =
        !dragStarted && (_sourceRect?.contains(event.position) ?? false);
    _resetPointerTracking();
    if (dragStarted) {
      widget.onEntryDragEnd();
    } else if (activate) {
      widget.onActivate();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _trackedPointer || _dragStarted) {
      return;
    }
    _resetPointerTracking();
  }

  void _resetPointerTracking() {
    _trackedPointer = null;
    _pointerDownPosition = null;
    _sourceRect = null;
    _dragStarted = false;
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final fileMime = clipboardFileMimeType(entry);
    final imageMime = clipboardImageMimeType(entry);
    final typeLabel = fileMime != null
        ? context.l10n.clipboardTypeFiles
        : imageMime != null
        ? context.l10n.clipboardTypeImage
        : context.l10n.clipboardTypeText;
    final highlighted = _hovered || _focused;

    return SizedBox(
      key: _itemKey,
      child: _ClipboardEntryItem(
        visible: !widget.dragging,
        onDelete: widget.busy ? null : widget.onDelete,
        pinned: entry.pinned,
        onTogglePinned: widget.busy ? null : widget.onTogglePinned,
        child: Semantics(
          key: ValueKey<String>('clipboard-history-card-${entry.id}'),
          button: true,
          label: context.l10n.clipboardItemSemantics(typeLabel, entry.preview),
          hint: context.l10n.clipboardItemHint,
          child: FocusableActionDetector(
            enabled: !widget.busy,
            mouseCursor: widget.dragging
                ? SystemMouseCursors.basic
                : widget.busy
                ? SystemMouseCursors.forbidden
                : SystemMouseCursors.grab,
            onShowHoverHighlight: _setHovered,
            onShowFocusHighlight: _setFocused,
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onActivate();
                  return null;
                },
              ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: _ClipboardEntryVisual(
                entry: entry,
                highlighted: highlighted && !widget.dragging,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardEntryItem extends StatelessWidget {
  const _ClipboardEntryItem({
    required this.child,
    required this.onDelete,
    required this.pinned,
    required this.onTogglePinned,
    this.visible = true,
    this.showDelete = true,
    this.showPin = true,
  });

  final Widget child;
  final VoidCallback? onDelete;
  final bool pinned;
  final VoidCallback? onTogglePinned;
  final bool visible;
  final bool showDelete;
  final bool showPin;

  @override
  Widget build(BuildContext context) {
    Widget maintainLayout(Widget child) => Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      child: child,
    );

    return Stack(
      children: [
        Padding(padding: const EdgeInsets.all(8), child: maintainLayout(child)),
        if (showDelete)
          Positioned(
            left: 0,
            top: 0,
            child: maintainLayout(_ClipboardDeleteButton(onPressed: onDelete)),
          ),
        if (showPin)
          Positioned(
            right: 0,
            top: 0,
            child: maintainLayout(
              _ClipboardPinButton(pinned: pinned, onPressed: onTogglePinned),
            ),
          ),
      ],
    );
  }
}

class _ClipboardPinButton extends StatelessWidget {
  const _ClipboardPinButton({required this.pinned, required this.onPressed});

  final bool pinned;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final tooltip = pinned
        ? context.l10n.clipboardUnpin
        : context.l10n.clipboardPin;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: pinned,
        label: pinned
            ? context.l10n.clipboardUnpinItem
            : context.l10n.clipboardPinItem,
        child: SizedBox.square(
          key: ValueKey<String>('clipboard-pin-${pinned ? 'on' : 'off'}'),
          dimension: 20,
          child: Material(
            color: Color.alphaBlend(
              accent.primary.withValues(alpha: pinned ? 0.34 : 0.18),
              ShellColors.surfaceContainerHigh,
            ).withValues(alpha: 0.94),
            shape: CircleBorder(
              side: BorderSide(
                color: accent.primary.withValues(alpha: pinned ? 0.7 : 0.38),
              ),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 13,
                color: onPressed == null
                    ? ShellColors.textTertiary
                    : pinned
                    ? accent.primary
                    : ShellColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardDeleteButton extends StatelessWidget {
  const _ClipboardDeleteButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Tooltip(
      message: context.l10n.clipboardDelete,
      child: Semantics(
        button: true,
        label: context.l10n.clipboardDeleteItem,
        child: SizedBox.square(
          dimension: 16,
          child: Material(
            color: Color.alphaBlend(
              accent.primary.withValues(alpha: 0.18),
              ShellColors.surfaceContainerHigh,
            ).withValues(alpha: 0.9),
            shape: CircleBorder(
              side: BorderSide(color: accent.primary.withValues(alpha: 0.38)),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(
                Icons.close_rounded,
                size: 12,
                color: onPressed == null
                    ? ShellColors.textTertiary
                    : ShellColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardEntryVisual extends StatelessWidget {
  const _ClipboardEntryVisual({
    required this.entry,
    this.highlighted = false,
    this.lifted = false,
  });

  final ClipboardHistoryEntry entry;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final imageMime = clipboardImageMimeType(entry);
    if (imageMime != null) {
      return _ClipboardImageTile(entry: entry, mimeType: imageMime);
    }
    final fileMime = clipboardFileMimeType(entry);
    if (fileMime != null) {
      return _ClipboardFileTile(
        entry: entry,
        mimeType: fileMime,
        highlighted: highlighted,
        lifted: lifted,
      );
    }
    return _ClipboardTextTile(
      entry: entry,
      highlighted: highlighted,
      lifted: lifted,
    );
  }
}

class _ClipboardImageTile extends StatelessWidget {
  const _ClipboardImageTile({required this.entry, required this.mimeType});

  final ClipboardHistoryEntry entry;
  final String mimeType;

  @override
  Widget build(BuildContext context) {
    final requestedSize = _clipboardImageDisplaySize(entry);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _fitClipboardImageSize(requestedSize, constraints);
        return SizedBox(
          width: size.width,
          height: size.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _ClipboardImagePreview(
              entry: entry,
              mimeType: mimeType,
              displaySize: size,
            ),
          ),
        );
      },
    );
  }
}

class _ClipboardImagePreview extends ConsumerWidget {
  const _ClipboardImagePreview({
    required this.entry,
    required this.mimeType,
    required this.displaySize,
  });

  final ClipboardHistoryEntry entry;
  final String mimeType;
  final Size displaySize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = math.max(1, (displaySize.width * pixelRatio).ceil());
    final cacheHeight = math.max(1, (displaySize.height * pixelRatio).ceil());
    final data = ref.watch(
      clipboardEntryDataProvider(ClipboardDataKey(entry.id, mimeType)),
    );
    return RepaintBoundary(
      child: ColoredBox(
        color: ShellColors.surfaceContainerLow,
        child: data.when(
          data: (payload) => Image.memory(
            payload.bytes,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            semanticLabel: context.l10n.clipboardImagePreview,
            errorBuilder: (_, _, _) => _PreviewFallback(
              icon: Icons.broken_image_outlined,
              label: context.l10n.clipboardPreviewUnavailable,
            ),
          ),
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (_, _) => _PreviewFallback(
            icon: Icons.broken_image_outlined,
            label: context.l10n.clipboardPreviewUnavailable,
          ),
        ),
      ),
    );
  }
}

class _ClipboardFileTile extends ConsumerWidget {
  const _ClipboardFileTile({
    required this.entry,
    required this.mimeType,
    required this.highlighted,
    required this.lifted,
  });

  final ClipboardHistoryEntry entry;
  final String mimeType;
  final bool highlighted;
  final bool lifted;

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
        ? context.l10n.clipboardFileSelection
        : first.pathSegments
                  .where((segment) => segment.isNotEmpty)
                  .lastOrNull ??
              first.path;

    return AnimatedContainer(
      duration: Motion.cardSettle,
      curve: Motion.standard,
      width: 280,
      height: 64,
      padding: const EdgeInsets.all(9),
      decoration: _clipboardNoteDecoration(
        context,
        entry: entry,
        highlighted: highlighted,
        lifted: lifted,
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 46,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: ColoredBox(
                color: accent.subtle,
                child: thumbnail == null
                    ? Icon(
                        isFolder
                            ? Icons.folder_rounded
                            : Icons.insert_drive_file_rounded,
                        size: 24,
                        color: accent.primary,
                      )
                    : thumbnail.when(
                        data: (bytes) => bytes == null
                            ? Icon(
                                Icons.image_outlined,
                                size: 24,
                                color: accent.primary,
                              )
                            : Image.memory(
                                bytes,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                semanticLabel:
                                    context.l10n.clipboardImageFileThumbnail,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.broken_image_outlined,
                                  size: 23,
                                  color: accent.primary,
                                ),
                              ),
                        loading: () => const Center(
                          child: SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        error: (_, _) => Icon(
                          Icons.broken_image_outlined,
                          size: 23,
                          color: accent.primary,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              files.length > 1 ? '$name  +${files.length - 1}' : name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(fontSize: 12.5, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipboardTextTile extends StatelessWidget {
  const _ClipboardTextTile({
    required this.entry,
    required this.highlighted,
    required this.lifted,
  });

  final ClipboardHistoryEntry entry;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    const maxLines = 8;
    const horizontalPadding = 14.0;
    const verticalPadding = 12.0;
    const maxTileWidth = 280.0;
    final normalized = entry.preview.replaceAll(RegExp(r'\s+$'), '');
    final text = normalized.isEmpty ? ' ' : normalized;
    final style = ShellText.base.copyWith(
      color: ShellColors.textPrimary,
      fontSize: 13,
      height: 1.38,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.hasBoundedWidth
            ? math.min(maxTileWidth, constraints.maxWidth)
            : maxTileWidth;
        final contentWidth = math.max(1.0, tileWidth - horizontalPadding * 2);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          ellipsis: '…',
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          textWidthBasis: TextWidthBasis.longestLine,
        )..layout(maxWidth: contentWidth);
        final measuredSize = painter.size;
        painter.dispose();
        final minimumWidth = math.min(72.0, tileWidth);
        final width = (measuredSize.width + horizontalPadding * 2)
            .clamp(minimumWidth, tileWidth)
            .toDouble();
        final height = measuredSize.height + verticalPadding * 2;

        return AnimatedContainer(
          duration: Motion.cardSettle,
          curve: Motion.standard,
          width: width,
          height: height,
          padding: const EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: _clipboardNoteDecoration(
            context,
            entry: entry,
            highlighted: highlighted,
            lifted: lifted,
          ),
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        );
      },
    );
  }
}

BoxDecoration _clipboardNoteDecoration(
  BuildContext context, {
  required ClipboardHistoryEntry entry,
  required bool highlighted,
  required bool lifted,
}) {
  final accent = ShellTheme.of(context).accentPalette;
  final raised = highlighted || lifted;
  final tint = entry.active
      ? 0.16
      : raised
      ? 0.11
      : 0.055;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          accent.primary.withValues(alpha: tint),
          ShellColors.surfaceContainerLow,
        ).withValues(
          alpha: entry.active
              ? 0.62
              : raised
              ? 0.54
              : 0.44,
        ),
        Color.alphaBlend(
          accent.primary.withValues(alpha: tint * 0.3),
          ShellColors.panelBackgroundBottom,
        ).withValues(
          alpha: entry.active
              ? 0.46
              : raised
              ? 0.38
              : 0.3,
        ),
      ],
    ),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(
      color: accent.primary.withValues(
        alpha: entry.active
            ? 0.48
            : raised
            ? 0.3
            : 0.12,
      ),
    ),
  );
}

Size _clipboardImageDisplaySize(ClipboardHistoryEntry entry) {
  const maxWidth = 320.0;
  const maxHeight = 220.0;
  const minLongestSide = 72.0;
  if (entry.width <= 0 || entry.height <= 0) {
    return const Size(280, 175);
  }
  final width = entry.width.toDouble();
  final height = entry.height.toDouble();
  final fitScale = math.min(maxWidth / width, maxHeight / height);
  final minimumScale = minLongestSide / math.max(width, height);
  final scale = math.min(fitScale, math.max(1.0, minimumScale));
  return Size(width * scale, height * scale);
}

Size _fitClipboardImageSize(Size requested, BoxConstraints constraints) {
  final widthScale = constraints.hasBoundedWidth
      ? constraints.maxWidth / requested.width
      : 1.0;
  final heightScale = constraints.hasBoundedHeight
      ? constraints.maxHeight / requested.height
      : 1.0;
  final scale = math.min(1.0, math.min(widthScale, heightScale));
  return Size(requested.width * scale, requested.height * scale);
}

@immutable
class _ClipboardEntryDragState {
  const _ClipboardEntryDragState({
    required this.entry,
    required this.position,
    required this.size,
    required this.anchor,
  });

  final ClipboardHistoryEntry entry;
  final Offset position;
  final Size size;
  final Offset anchor;

  _ClipboardEntryDragState copyWith({Offset? position}) {
    return _ClipboardEntryDragState(
      entry: entry,
      position: position ?? this.position,
      size: size,
      anchor: anchor,
    );
  }
}

class _DraggedClipboardEntry extends StatelessWidget {
  const _DraggedClipboardEntry({required this.state});

  final _ClipboardEntryDragState state;

  @override
  Widget build(BuildContext context) {
    final origin =
        state.position -
        Offset(
          state.size.width * state.anchor.dx,
          state.size.height * state.anchor.dy,
        );
    return Positioned(
      key: const ValueKey<String>('clipboard-drag-preview'),
      left: origin.dx,
      top: origin.dy,
      width: state.size.width,
      height: state.size.height,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: _ClipboardEntryItem(
              onDelete: () {},
              pinned: state.entry.pinned,
              onTogglePinned: () {},
              showDelete: false,
              showPin: false,
              child: _ClipboardEntryVisual(entry: state.entry, lifted: true),
            ),
          ),
        ),
      ),
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

EdgeInsets _clipboardTrayContentPadding(ClipboardTrayEdge edge) {
  if (_isVerticalEdge(edge)) {
    return const EdgeInsets.symmetric(horizontal: 8, vertical: 16);
  }
  return EdgeInsets.fromLTRB(
    16,
    edge == ClipboardTrayEdge.top ? 18 : 16,
    16,
    edge == ClipboardTrayEdge.bottom ? 18 : 16,
  );
}

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
