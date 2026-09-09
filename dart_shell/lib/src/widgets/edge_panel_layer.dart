import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/input_layout.dart';
import '../platform/denial_bridge.dart';
import '../services/haptics_service.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import 'osk/shell_osk_panel.dart';
import 'retained_translation.dart';
import 'shell_backdrop_blur.dart';

/// Keeps the mobile software keyboard above applications and shell surfaces,
/// including the compositor-owned lock screen.
class MobileSystemKeyboardLayer extends ConsumerWidget {
  const MobileSystemKeyboardLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      shellControllerProvider.select((state) => !state.launchTransitionActive),
    );
    return Offstage(
      offstage: !enabled,
      child: TickerMode(
        enabled: enabled,
        child: IgnorePointer(ignoring: !enabled, child: const EdgePanelLayer()),
      ),
    );
  }
}

/// Moves mobile content within the space left by the software keyboard.
///
/// The keyboard and its right-edge scroll strip must remain stationary, so
/// every full-screen surface that should follow the user's viewport pan wraps
/// itself in this boundary instead of duplicating the translation.
class MobileKeyboardViewport extends ConsumerStatefulWidget {
  const MobileKeyboardViewport({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<MobileKeyboardViewport> createState() =>
      _MobileKeyboardViewportState();
}

class _MobileKeyboardViewportState
    extends ConsumerState<MobileKeyboardViewport> {
  final _translation = ValueNotifier(Offset.zero);
  double _panelHeight = 0;

  void _updateTranslation(({double progress, double scroll}) position) {
    final keyboardOffset = _panelHeight * position.progress;
    final scroll = position.scroll.clamp(0.0, keyboardOffset);
    _translation.value = Offset(0, -(keyboardOffset - scroll));
  }

  @override
  void dispose() {
    _translation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      shellControllerProvider.select(
        (state) => (
          progress: state.edgePanelDragProgress,
          scroll: state.edgePanelViewportScroll,
        ),
      ),
      (_, next) => _updateTranslation(next),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        _panelHeight = ShellMetrics.edgePanelHeight(constraints.biggest);
        final state = ref.read(shellControllerProvider);
        _updateTranslation((
          progress: state.edgePanelDragProgress,
          scroll: state.edgePanelViewportScroll,
        ));
        return RetainedTranslation(
          translation: _translation,
          child: RepaintBoundary(child: widget.child),
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
  final _translation = ValueNotifier(Offset.zero);
  double _panelHeight = 0;
  bool _shown = false;
  bool _scrollReady = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(shellControllerProvider);
    _controller = AnimationController.unbounded(
      vsync: this,
      value: state.edgePanelVisible ? 1.0 : state.edgePanelDragProgress,
    )..addListener(_updatePresentation);
    _shown = unit(_controller.value) > 0.001;
    _scrollReady = unit(_controller.value) >= 0.98;
    ref.read(hapticsServiceProvider).prewarm();
  }

  @override
  void dispose() {
    _controller.dispose();
    _translation.dispose();
    super.dispose();
  }

  void _updateTranslation() {
    _translation.value = Offset(
      0,
      _panelHeight * (1 - unit(_controller.value)),
    );
  }

  void _updatePresentation() {
    _updateTranslation();
    final progress = unit(_controller.value);
    final shown = progress > 0.001;
    final scrollReady = progress >= 0.98;
    if (_shown == shown && _scrollReady == scrollReady) return;
    setState(() {
      _shown = shown;
      _scrollReady = scrollReady;
    });
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
    _panelHeight = ShellMetrics.edgePanelHeight(MediaQuery.sizeOf(context));
    _updateTranslation();
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
          Offstage(
            offstage: !_shown,
            child: TickerMode(
              enabled: _shown,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _EdgePanelScrollStrip(enabled: _scrollReady),
                  RetainedTranslation(
                    translation: _translation,
                    child: const _EdgePanelSheet(),
                  ),
                ],
              ),
            ),
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
  const _EdgePanelScrollStrip({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edgePanelVisible = ref.watch(
      shellControllerProvider.select((state) => state.edgePanelVisible),
    );
    if (!edgePanelVisible || !enabled) {
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
  const _EdgePanelSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final panelHeight = ShellMetrics.edgePanelHeight(size);

    return Align(
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
      separateChild: true,
      blur: theme.effectivePanelOpacity < 1.0,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(theme.panelRadius),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.panelColor(context.shellColors.panelBackground),
          border: Border(
            top: BorderSide(color: context.shellColors.hairline, width: 1),
          ),
        ),
        child: RepaintBoundary(
          // Keep OSK presses inside the focused EditableText tap group. A
          // keyboard key must not look like an outside tap and retire the
          // editor before its command is delivered.
          child: TextFieldTapRegion(
            child: ShellOskPanel(
              onKeyTap: haptics.pulse,
              onKey: (intent) => _sendOskIntent(bridge, intent),
            ),
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
        final key = intent.key ?? 'BackSpace';
        switch (intent.phase) {
          case ShellOskKeyPhase.tap:
            bridge.sendKeyboardKey(key, ctrl: intent.ctrl);
          case ShellOskKeyPhase.pressed:
            bridge.pressKeyboardKey(key);
          case ShellOskKeyPhase.released:
            bridge.releaseKeyboardKey(key);
        }
      case ShellOskKeyAction.enter:
        bridge.sendKeyboardKey(intent.key ?? 'Return', ctrl: intent.ctrl);
    }
  }
}
