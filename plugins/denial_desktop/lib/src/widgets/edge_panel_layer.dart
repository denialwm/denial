import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';

import 'package:flutter/gestures.dart' show DeviceGestureSettings;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import 'osk/shell_osk_panel.dart';
import '../state/input_deck.dart';

import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/effects.dart';

/// Keeps the software keyboard above applications and shell surfaces,
/// including the compositor-owned lock screen.
class SystemKeyboardLayer extends ConsumerWidget {
  const SystemKeyboardLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      referenceShellProvider.select((state) => !state.launchTransitionActive),
    );
    final deckActive = ref.watch(
      inputDeckProvider.select((deck) => deck.activeOutput != null),
    );
    final showKeyboard =
        enabled &&
        (!deckActive ||
            ref.watch(referenceShellProvider.select((state) => state.locked)));
    return Offstage(
      offstage: !showKeyboard,
      child: TickerMode(
        enabled: showKeyboard,
        child: IgnorePointer(
          ignoring: !showKeyboard,
          child: const EdgePanelLayer(),
        ),
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
  const MobileKeyboardViewport({
    required this.child,
    this.appScene = false,
    super.key,
  });

  final Widget child;

  /// The application scene stays in place while its primary window lays
  /// itself out around the keyboard (denial-insets-v1 keyboard inset).
  final bool appScene;

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

  ({double progress, double scroll}) _position(ReferenceShellState state) => (
    progress: widget.appScene && state.primaryWindowHandlesKeyboard
        ? 0.0
        : state.edgePanelDragProgress,
    scroll: state.edgePanelViewportScroll,
  );

  @override
  void dispose() {
    _translation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      referenceShellProvider.select(_position),
      (_, next) => _updateTranslation(next),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        _panelHeight = ReferenceShellMetrics.edgePanelHeight(
          constraints.biggest,
        );
        _updateTranslation(_position(ref.read(referenceShellProvider)));
        return CompositedTranslation(
          translation: _translation,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          child: widget.child,
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

  /// The keyboard height last reported to applications laid out around it.
  int? _reportedHeight;

  @override
  void initState() {
    super.initState();
    final state = ref.read(referenceShellProvider);
    _controller = AnimationController.unbounded(
      vsync: this,
      value: state.edgePanelVisible ? 1.0 : state.edgePanelDragProgress,
    )..addListener(_updatePresentation);
    _shown = unit(_controller.value) > 0.001;
    _scrollReady = unit(_controller.value) >= 0.98;
    ref.read(hapticsServiceProvider).prewarm();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _panelHeight = ReferenceShellMetrics.edgePanelHeight(
      MediaQuery.sizeOf(context),
    );
    _updateTranslation();
    _reportMotion(ref.read(referenceShellProvider).edgePanelVisible);
  }

  @override
  void dispose() {
    _controller.dispose();
    _translation.dispose();
    super.dispose();
  }

  /// Tells applications laid out around the keyboard where it settles and
  /// how long the spring there takes, once per motion. A drag is reported
  /// when it is released.
  void _reportMotion(bool visible) {
    final height = visible ? _panelHeight.round() : 0;
    if (height == _reportedHeight) return;
    _reportedHeight = height;
    ref
        .read(denialBridgeProvider)
        .reportKeyboardPanelMotion(
          height,
          springSettleDuration(
            _controller.value,
            visible ? 1.0 : 0.0,
            extent: _panelHeight,
          ),
        );
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
      _reportMotion(visible);
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
      referenceShellProvider.select(
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
      referenceShellProvider.select((state) => state.edgePanelVisible),
    );
    final controller = ref.read(referenceShellProvider.notifier);
    return Positioned(
      right: 0,
      bottom: ReferenceShellMetrics.gestureBottomInset,
      width: ReferenceShellMetrics.edgePanelGestureWidth,
      height: ReferenceShellMetrics.edgePanelGestureHeight,
      child: TextFieldTapRegion(
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
      referenceShellProvider.select((state) => state.edgePanelVisible),
    );
    if (!edgePanelVisible || !enabled) {
      return const SizedBox.expand();
    }

    final controller = ref.read(referenceShellProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final panelHeight = ReferenceShellMetrics.edgePanelHeight(size);

    return Positioned(
      top: 0,
      right: 0,
      bottom: panelHeight,
      width: ReferenceShellMetrics.edgePanelScrollStripWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          controller.updateEdgePanelViewportScroll(
            details.delta.dy * ReferenceShellMetrics.edgePanelScrollMultiplier,
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

  /// How far a finger travels before it drags the sheet instead of typing:
  /// about half a key, twice the default slop, so a key touch that wanders
  /// still types.
  static const _dragSlop = 36.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(referenceShellProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final panelHeight = ReferenceShellMetrics.edgePanelHeight(size);
    final media = MediaQuery.of(context);

    return Align(
      alignment: Alignment.bottomCenter,
      child: MediaQuery(
        data: media.copyWith(
          gestureSettings: const DeviceGestureSettings(touchSlop: _dragSlop),
        ),
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
    final vibrate = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.sound.keyboardVibration,
      ),
    );
    final theme = ShellTheme.of(context);
    // The keys sit beside the clipped glass, not in it: key popups rise
    // above the panel's top edge.
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        ShellBackdropBlur(
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
          ),
        ),
        RepaintBoundary(
          // Keep OSK presses inside the focused EditableText tap group. A
          // keyboard key must not look like an outside tap and retire the
          // editor before its command is delivered.
          child: TextFieldTapRegion(
            child: ShellOskPanel(
              onKeyDown: vibrate ? haptics.pulse : null,
              onKey: (intent) => _sendOskIntent(bridge, intent),
              textInputStates: bridge.textInputStates,
              predictions: bridge.textPredictions,
              onPredict: (word) => bridge.requestTextPrediction(
                serial: word.serial,
                word: word.word,
                touchX: word.touchX,
                touchY: word.touchY,
                manualCapital: word.manualCapital,
              ),
            ),
          ),
        ),
      ],
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
      case ShellOskKeyAction.replace:
        bridge.sendKeyboardReplace(intent.replaced ?? '', intent.text ?? '');
    }
  }
}
