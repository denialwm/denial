import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/input_layout.dart';
import '../platform/denial_bridge.dart';
import '../services/haptics_service.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'osk/shell_osk_panel.dart';
import 'shell_backdrop_blur.dart';

/// Keeps the mobile software keyboard above applications and transient shell
/// surfaces while preserving the lock screen as the highest security layer.
class MobileSystemKeyboardLayer extends ConsumerWidget {
  const MobileSystemKeyboardLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      shellControllerProvider.select(
        (state) => !state.lockLayerVisible && !state.launchTransitionActive,
      ),
    );
    return Offstage(
      offstage: !enabled,
      child: IgnorePointer(ignoring: !enabled, child: const EdgePanelLayer()),
    );
  }
}

/// Moves mobile content within the space left by the software keyboard.
///
/// The keyboard and its right-edge scroll strip must remain stationary, so
/// every full-screen surface that should follow the user's viewport pan wraps
/// itself in this boundary instead of duplicating the translation.
class MobileKeyboardViewport extends ConsumerWidget {
  const MobileKeyboardViewport({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      shellControllerProvider.select(
        (state) => (
          progress: state.edgePanelDragProgress,
          scroll: state.edgePanelViewportScroll,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final keyboardOffset =
            ShellMetrics.edgePanelHeight(constraints.biggest) *
            position.progress;
        final viewportScroll = position.scroll
            .clamp(0.0, keyboardOffset)
            .toDouble();
        return Transform.translate(
          offset: Offset(0.0, -(keyboardOffset - viewportScroll)),
          child: child,
        );
      },
    );
  }
}

class EdgePanelLayer extends ConsumerStatefulWidget {
  const EdgePanelLayer({super.key});

  @override
  ConsumerState<EdgePanelLayer> createState() => _EdgePanelLayerState();
}

class _EdgePanelLayerState extends ConsumerState<EdgePanelLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final state = ref.read(shellControllerProvider);
    _controller = AnimationController.unbounded(
      vsync: this,
      value: state.edgePanelVisible ? 1.0 : state.edgePanelDragProgress,
    );
    ref.read(hapticsServiceProvider).prewarm();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPanelChanged((bool, double, bool) signal) {
    final (visible, drag, dragActive) = signal;
    if (dragActive) {
      _controller.stop();
      _controller.value = drag;
    } else {
      springTo(
        _controller,
        visible ? 1.0 : 0.0,
        spring: Motion.gentle,
        telemetryLabel: 'edge_panel_settle',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<(bool, double, bool)>(
      shellControllerProvider.select(
        (state) => (
          state.edgePanelVisible,
          state.edgePanelDragProgress,
          state.edgePanelDragActive,
        ),
      ),
      (_, next) => _onPanelChanged(next),
    );

    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final progress = unit(_controller.value);
              if (progress <= 0.001) {
                return const SizedBox.expand();
              }
              return Stack(
                fit: StackFit.expand,
                children: [
                  _EdgePanelScrollStrip(progress: progress),
                  _EdgePanelSheet(progress: progress),
                ],
              );
            },
          ),
          const _EdgePanelGestureTarget(),
        ],
      ),
    );
  }
}

class _EdgePanelGestureTarget extends ConsumerWidget {
  const _EdgePanelGestureTarget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edgePanelVisible = ref.watch(
      shellControllerProvider.select((state) => state.edgePanelVisible),
    );
    final controller = ref.read(shellControllerProvider.notifier);
    return Positioned(
      right: 0,
      bottom: ShellMetrics.gestureBottomInset,
      width: ShellMetrics.edgePanelGestureWidth,
      height: ShellMetrics.edgePanelGestureHeight,
      child: IgnorePointer(
        ignoring: edgePanelVisible,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => controller.startEdgePanelDrag(),
          onVerticalDragUpdate: (details) {
            controller.updateEdgePanelDrag(Offset(0.0, details.delta.dy));
          },
          onVerticalDragEnd: (details) {
            controller.endEdgePanelDrag(details.primaryVelocity ?? 0.0);
          },
          onVerticalDragCancel: () => controller.endEdgePanelDrag(0.0),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _EdgePanelScrollStrip extends ConsumerWidget {
  const _EdgePanelScrollStrip({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edgePanelVisible = ref.watch(
      shellControllerProvider.select((state) => state.edgePanelVisible),
    );
    if (!edgePanelVisible || progress < 0.98) {
      return const SizedBox.expand();
    }

    final controller = ref.read(shellControllerProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final panelHeight = ShellMetrics.edgePanelHeight(size);

    return Positioned(
      top: 0,
      right: 0,
      bottom: panelHeight,
      width: ShellMetrics.edgePanelScrollStripWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          controller.updateEdgePanelViewportScroll(
            details.delta.dy * ShellMetrics.edgePanelScrollMultiplier,
            panelHeight,
          );
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _EdgePanelSheet extends ConsumerWidget {
  const _EdgePanelSheet({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final panelHeight = ShellMetrics.edgePanelHeight(size);

    return Transform.translate(
      offset: Offset(0.0, panelHeight * (1.0 - progress)),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => controller.startEdgePanelDrag(),
          onVerticalDragUpdate: (details) {
            controller.updateEdgePanelDrag(Offset(0.0, details.delta.dy));
          },
          onVerticalDragEnd: (details) {
            controller.endEdgePanelDrag(details.primaryVelocity ?? 0.0);
          },
          onVerticalDragCancel: () => controller.endEdgePanelDrag(0.0),
          child: SizedBox(
            width: double.infinity,
            height: panelHeight,
            child: const _EdgePanelContent(),
          ),
        ),
      ),
    );
  }
}

class _EdgePanelContent extends ConsumerWidget {
  const _EdgePanelContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.read(denialBridgeProvider);
    final haptics = ref.read(hapticsServiceProvider);
    final theme = ShellTheme.of(context);
    return ShellBackdropBlur(
      blur: theme.panelOpacity < 1.0,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(theme.panelRadius),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.panelColor(ShellColors.panelBackground),
          border: const Border(
            top: BorderSide(color: ShellColors.hairline, width: 1),
          ),
        ),
        child: RepaintBoundary(
          child: ShellOskPanel(
            onKeyTap: haptics.pulse,
            onKey: (intent) => _sendOskIntent(bridge, intent),
          ),
        ),
      ),
    );
  }

  void _sendOskIntent(DenialBridge bridge, ShellOskKeyIntent intent) {
    switch (intent.action) {
      case ShellOskKeyAction.text:
        bridge.sendKeyboardText(intent.text ?? '');
      case ShellOskKeyAction.key:
        bridge.sendKeyboardKey(intent.key ?? '', ctrl: intent.ctrl);
      case ShellOskKeyAction.space:
        if (intent.ctrl) {
          bridge.sendKeyboardKey(intent.key ?? 'space', ctrl: true);
        } else {
          bridge.sendKeyboardText(' ');
        }
      case ShellOskKeyAction.backspace:
        bridge.sendKeyboardKey(intent.key ?? 'BackSpace', ctrl: intent.ctrl);
      case ShellOskKeyAction.enter:
        bridge.sendKeyboardKey(intent.key ?? 'Return', ctrl: intent.ctrl);
    }
  }
}
