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

part 'clipboard_drag_preview.dart';
part 'clipboard_entry_visual.dart';
part 'clipboard_history_card.dart';
part 'clipboard_tray_surface.dart';

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
