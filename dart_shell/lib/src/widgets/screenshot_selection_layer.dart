import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../localization/denial_localizations.dart';
import '../state/screenshot_selection.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';

class ScreenshotSelectionLayer extends ConsumerWidget {
  const ScreenshotSelectionLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(screenshotSelectionProvider);
    if (session?.phase != ScreenshotSelectionPhase.selecting ||
        session?.textureId == null) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: _ScreenshotSelectionSurface(
        key: ValueKey<int>(session!.requestId),
        session: session,
      ),
    );
  }
}

class _ScreenshotSelectionSurface extends ConsumerStatefulWidget {
  const _ScreenshotSelectionSurface({required this.session, super.key});

  final ScreenshotSelectionSession session;

  @override
  ConsumerState<_ScreenshotSelectionSurface> createState() =>
      _ScreenshotSelectionSurfaceState();
}

class _ScreenshotSelectionSurfaceState
    extends ConsumerState<_ScreenshotSelectionSurface>
    with SingleTickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'screenshot-region-selection',
  );
  late final AnimationController _take;
  int? _pointer;
  Rect? _takenSelection;

  bool get _isTaking => _takenSelection != null;

  @override
  void initState() {
    super.initState();
    _take = AnimationController(vsync: this, duration: Motion.screenshotTake)
      ..addStatusListener(_handleTakeStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _take.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Offset _clamp(Offset point, Size size) {
    return Offset(
      point.dx.clamp(0.0, size.width).toDouble(),
      point.dy.clamp(0.0, size.height).toDouble(),
    );
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    if (_isTaking) {
      return;
    }
    if (event.buttons & kSecondaryMouseButton != 0) {
      _cancel();
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0 || _pointer != null) {
      return;
    }
    _pointer = event.pointer;
    ref
        .read(screenshotSelectionProvider.notifier)
        .start(_clamp(event.localPosition, size));
  }

  void _handlePointerMove(PointerMoveEvent event, Size size) {
    if (_isTaking || _pointer != event.pointer) {
      return;
    }
    ref
        .read(screenshotSelectionProvider.notifier)
        .update(_clamp(event.localPosition, size));
  }

  void _handlePointerUp(PointerUpEvent event, Size size) {
    if (_pointer != event.pointer) {
      return;
    }
    _pointer = null;
    final controller = ref.read(screenshotSelectionProvider.notifier);
    controller.update(_clamp(event.localPosition, size));
    final selection = controller.complete();
    if (selection == null) {
      return;
    }
    setState(() => _takenSelection = selection);
    _focusNode.unfocus();
    _take.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.screenshotTake;
    _take.forward(from: 0);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_isTaking || _pointer != event.pointer) {
      return;
    }
    _pointer = null;
    ref.read(screenshotSelectionProvider.notifier).resetDrag();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (_isTaking) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTakeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) {
      return;
    }
    final selection = _takenSelection;
    if (selection == null) {
      return;
    }
    final requestId = widget.session.requestId;
    final controller = ref.read(screenshotSelectionProvider.notifier);
    controller.finishLocally(requestId);
    if (!ref
        .read(denialBridgeProvider)
        .finishScreenshotRegion(requestId, selection)) {
      ref.read(denialBridgeProvider).cancelScreenshot(requestId);
    }
  }

  void _cancel() {
    _pointer = null;
    final requestId = widget.session.requestId;
    // Mark the texture layer gone before native unregisters it. This queues
    // Flutter's replacement frame first and avoids holding the frozen atlas
    // on screen while the external-texture teardown is dispatched.
    ref.read(screenshotSelectionProvider.notifier).finishLocally(requestId);
    ref.read(denialBridgeProvider).cancelScreenshot(requestId);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.session.selection;
    final hint = context.l10n.screenshotSelectionHint;
    final theme = ShellTheme.of(context);
    return ShellInputRegion(
      debugLabel: 'screenshot region selection',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: Semantics(
          container: true,
          liveRegion: true,
          label: hint,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              if (_takenSelection case final selection?) {
                return _ScreenshotTakeAnimation(
                  animation: _take,
                  selection: selection.intersect(Offset.zero & size),
                  textureId: widget.session.textureId!,
                  accent: theme.accent,
                  canvasSize: size,
                );
              }
              return MouseRegion(
                cursor: SystemMouseCursors.precise,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => _handlePointerDown(event, size),
                  onPointerMove: (event) => _handlePointerMove(event, size),
                  onPointerUp: (event) => _handlePointerUp(event, size),
                  onPointerCancel: _handlePointerCancel,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ExcludeSemantics(
                        child: Texture(
                          textureId: widget.session.textureId!,
                          freeze: true,
                          filterQuality: FilterQuality.none,
                        ),
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: _ScreenshotSelectionPainter(
                            selection: selection,
                            accent: theme.accent,
                            radius: theme.scaledRadius(8),
                          ),
                        ),
                      ),
                      if (selection case final rect?
                          when rect.width >= 72 && rect.height >= 44)
                        Positioned(
                          left: rect.left + 8,
                          top: rect.top + 8,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: context.shellColors.surfaceContainerLow,
                                borderRadius: context.shellTheme.borderRadius(
                                  8,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Text(
                                  '${rect.width.round()} × ${rect.height.round()}',
                                  style: ShellText.base.copyWith(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
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
            },
          ),
        ),
      ),
    );
  }
}

class _ScreenshotTakeAnimation extends StatelessWidget {
  const _ScreenshotTakeAnimation({
    required this.animation,
    required this.selection,
    required this.textureId,
    required this.accent,
    required this.canvasSize,
  });

  final Animation<double> animation;
  final Rect selection;
  final int textureId;
  final Color accent;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) {
    final radius = context.shellTheme.scaledRadius(8);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: animation,
        child: ExcludeSemantics(
          child: Texture(
            textureId: textureId,
            freeze: true,
            filterQuality: FilterQuality.low,
          ),
        ),
        builder: (context, frozenCanvas) {
          final progress = Motion.md3EmphasizedAccelerate.transform(
            animation.value,
          );
          final scale = 1 - progress;
          final collapsed = Rect.fromCenter(
            center: selection.center,
            width: selection.width * scale,
            height: selection.height * scale,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              ClipPath(
                clipper: _ScreenshotTakeClipper(collapsed, radius),
                child: Transform.scale(
                  scale: scale,
                  alignment: _alignmentFor(selection.center, canvasSize),
                  child: frozenCanvas,
                ),
              ),
              CustomPaint(
                painter: _ScreenshotTakeOutlinePainter(
                  selection: collapsed,
                  accent: accent.withValues(alpha: scale),
                  radius: radius,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Alignment _alignmentFor(Offset center, Size size) {
    if (size.isEmpty) {
      return Alignment.center;
    }
    return Alignment(
      center.dx / size.width * 2 - 1,
      center.dy / size.height * 2 - 1,
    );
  }
}

class _ScreenshotTakeClipper extends CustomClipper<Path> {
  const _ScreenshotTakeClipper(this.selection, this.radius);

  final Rect selection;
  final double radius;

  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        selection.intersect(Offset.zero & size),
        Radius.circular(radius),
      ),
    );

  @override
  bool shouldReclip(covariant _ScreenshotTakeClipper oldClipper) =>
      oldClipper.selection != selection || oldClipper.radius != radius;
}

class _ScreenshotTakeOutlinePainter extends CustomPainter {
  const _ScreenshotTakeOutlinePainter({
    required this.selection,
    required this.accent,
    required this.radius,
  });

  final Rect selection;
  final Color accent;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final selected = selection.intersect(Offset.zero & size);
    if (selected.isEmpty) {
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        selected.deflate(1),
        Radius.circular(radius > 1 ? radius - 1 : 0),
      ),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ScreenshotTakeOutlinePainter oldDelegate) =>
      oldDelegate.selection != selection ||
      oldDelegate.accent != accent ||
      oldDelegate.radius != radius;
}

class _ScreenshotSelectionPainter extends CustomPainter {
  const _ScreenshotSelectionPainter({
    required this.selection,
    required this.accent,
    required this.radius,
  });

  final Rect? selection;
  final Color accent;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final canvasRect = Offset.zero & size;
    final selected = selection?.intersect(canvasRect);
    final scrim = Path()..fillType = PathFillType.evenOdd;
    scrim.addRect(canvasRect);
    if (selected != null && !selected.isEmpty) {
      scrim.addRRect(
        RRect.fromRectAndRadius(selected, Radius.circular(radius)),
      );
    }
    canvas.drawPath(
      scrim,
      Paint()..color = ShellMediaColors.darkness.withValues(alpha: 0.60),
    );

    if (selected == null || selected.isEmpty) {
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(selected, Radius.circular(radius)),
      Paint()..color = accent.withValues(alpha: 0.10),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        selected.deflate(1),
        Radius.circular(radius > 1 ? radius - 1 : 0),
      ),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ScreenshotSelectionPainter oldDelegate) {
    return oldDelegate.selection != selection ||
        oldDelegate.accent != accent ||
        oldDelegate.radius != radius;
  }
}
