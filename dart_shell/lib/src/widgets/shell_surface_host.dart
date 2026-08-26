import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';

enum ShellDismissPolicy { none, outsideTap, outsideTapAndEscape }

typedef ShellSurfaceBuilder =
    Widget Function(BuildContext context, ShellSurfaceHandle handle);

@immutable
class ManagedShellSurface {
  const ManagedShellSurface({
    required this.id,
    required this.keyName,
    required this.debugLabel,
    required this.builder,
    required this.pointerPolicy,
    required this.keyboardPolicy,
    required this.compositorPolicy,
    required this.dismissPolicy,
    required this.transitionDuration,
    required this.barrierColor,
    required this.closing,
    required this.restoreFocus,
  });

  final int id;
  final String? keyName;
  final String debugLabel;
  final ShellSurfaceBuilder builder;
  final ShellPointerPolicy pointerPolicy;
  final ShellKeyboardPolicy keyboardPolicy;
  final ShellCompositorPolicy compositorPolicy;
  final ShellDismissPolicy dismissPolicy;
  final Duration transitionDuration;
  final Color? barrierColor;
  final bool closing;
  final FocusNode? restoreFocus;

  ManagedShellSurface copyWith({bool? closing}) {
    return ManagedShellSurface(
      id: id,
      keyName: keyName,
      debugLabel: debugLabel,
      builder: builder,
      pointerPolicy: pointerPolicy,
      keyboardPolicy: keyboardPolicy,
      compositorPolicy: compositorPolicy,
      dismissPolicy: dismissPolicy,
      transitionDuration: transitionDuration,
      barrierColor: barrierColor,
      closing: closing ?? this.closing,
      restoreFocus: restoreFocus,
    );
  }
}

final shellSurfaceControllerProvider =
    NotifierProvider<ShellSurfaceController, List<ManagedShellSurface>>(
      ShellSurfaceController.new,
    );

class ShellSurfaceController extends Notifier<List<ManagedShellSurface>> {
  late ShellInteractionRegistry _interactions;

  @override
  List<ManagedShellSurface> build() {
    _interactions = ref.watch(shellInteractionRegistryProvider.notifier);
    return const <ManagedShellSurface>[];
  }

  ShellSurfaceHandle show({
    required String debugLabel,
    required ShellSurfaceBuilder builder,
    String? keyName,
    ShellPointerPolicy pointerPolicy = ShellPointerPolicy.fullScene,
    ShellKeyboardPolicy keyboardPolicy = ShellKeyboardPolicy.capture,
    ShellCompositorPolicy compositorPolicy = ShellCompositorPolicy.normal,
    ShellDismissPolicy dismissPolicy = ShellDismissPolicy.outsideTapAndEscape,
    Duration transitionDuration = Motion.cardSettle,
    Color? barrierColor,
  }) {
    if (keyName != null) {
      for (final surface in state.reversed) {
        if (surface.keyName == keyName && !surface.closing) {
          return ShellSurfaceHandle._(this, surface.id);
        }
      }
    }

    final id = _interactions.reserveSurfaceId();
    final surface = ManagedShellSurface(
      id: id,
      keyName: keyName,
      debugLabel: debugLabel,
      builder: builder,
      pointerPolicy: pointerPolicy,
      keyboardPolicy: keyboardPolicy,
      compositorPolicy: compositorPolicy,
      dismissPolicy: dismissPolicy,
      transitionDuration: transitionDuration,
      barrierColor: barrierColor,
      closing: false,
      restoreFocus: FocusManager.instance.primaryFocus,
    );
    state = List<ManagedShellSurface>.unmodifiable(<ManagedShellSurface>[
      ...state,
      surface,
    ]);
    _interactions.upsert(
      ShellInteractionSurface(
        id: id,
        debugLabel: debugLabel,
        pointerPolicy: pointerPolicy,
        keyboardPolicy: keyboardPolicy,
        compositorPolicy: compositorPolicy,
      ),
    );
    return ShellSurfaceHandle._(this, id);
  }

  void close(int id) {
    var changed = false;
    final next = <ManagedShellSurface>[];
    for (final surface in state) {
      if (surface.id == id && !surface.closing) {
        changed = true;
        next.add(surface.copyWith(closing: true));
      } else {
        next.add(surface);
      }
    }
    if (changed) {
      state = List<ManagedShellSurface>.unmodifiable(next);
    }
  }

  void completeClose(int id) {
    ManagedShellSurface? removed;
    final next = <ManagedShellSurface>[];
    for (final surface in state) {
      if (surface.id == id) {
        removed = surface;
      } else {
        next.add(surface);
      }
    }
    if (removed == null) {
      return;
    }
    state = List<ManagedShellSurface>.unmodifiable(next);
    _interactions.remove(id);
    final restoreFocus = removed.restoreFocus;
    if (restoreFocus != null && restoreFocus.canRequestFocus) {
      restoreFocus.requestFocus();
    }
  }

  /// Removes every transient surface synchronously.
  ///
  /// Locking uses this path so credential fields are disposed before the lock
  /// layer becomes interactive. Focus is deliberately not restored into the
  /// now-secured scene.
  void dismissAllImmediately() {
    if (state.isEmpty) {
      return;
    }
    for (final surface in state) {
      _interactions.remove(surface.id);
    }
    state = const <ManagedShellSurface>[];
  }
}

class ShellSurfaceHandle {
  const ShellSurfaceHandle._(this._controller, this.id);

  final ShellSurfaceController _controller;
  final int id;

  void close() => _controller.close(id);
}

/// The only host for transient shell surfaces. Entries remain registered with
/// native input routing until their closing transition has fully completed.
class ShellSurfaceHost extends ConsumerWidget {
  const ShellSurfaceHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = ref.watch(shellSurfaceControllerProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        for (final surface in surfaces)
          _ManagedShellSurfaceLayer(
            key: ValueKey<int>(surface.id),
            surface: surface,
          ),
      ],
    );
  }
}

class _ManagedShellSurfaceLayer extends ConsumerStatefulWidget {
  const _ManagedShellSurfaceLayer({required this.surface, super.key});

  final ManagedShellSurface surface;

  @override
  ConsumerState<_ManagedShellSurfaceLayer> createState() =>
      _ManagedShellSurfaceLayerState();
}

class _ManagedShellSurfaceLayerState
    extends ConsumerState<_ManagedShellSurfaceLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  final FocusScopeNode _focusScopeNode = FocusScopeNode(
    debugLabel: 'managed-shell-surface',
  );
  bool _completingClose = false;

  @override
  void initState() {
    super.initState();
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    _controller = AnimationController(
      vsync: this,
      duration: reduceMotion
          ? Duration.zero
          : widget.surface.transitionDuration,
      reverseDuration: reduceMotion
          ? Duration.zero
          : widget.surface.transitionDuration,
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Motion.md3EmphasizedDecelerate,
      reverseCurve: Motion.md3EmphasizedAccelerate,
    );
    _opacity = curved;
    _scale = Tween<double>(begin: 0.96, end: 1.0).animate(curved);
    unawaited(_controller.forward());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.surface.closing) {
        _focusScopeNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ManagedShellSurfaceLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.surface.closing && !oldWidget.surface.closing) {
      _beginClose();
    }
  }

  void _beginClose() {
    if (_completingClose) {
      return;
    }
    _completingClose = true;
    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted) {
        return;
      }
      ref
          .read(shellSurfaceControllerProvider.notifier)
          .completeClose(widget.surface.id);
    });
  }

  @override
  void dispose() {
    _focusScopeNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    final handle = ShellSurfaceHandle._(
      ref.read(shellSurfaceControllerProvider.notifier),
      surface.id,
    );
    final dismissOnOutside =
        surface.dismissPolicy == ShellDismissPolicy.outsideTap ||
        surface.dismissPolicy == ShellDismissPolicy.outsideTapAndEscape;
    final dismissOnEscape =
        surface.dismissPolicy == ShellDismissPolicy.outsideTapAndEscape;

    return IgnorePointer(
      ignoring: surface.closing,
      child: FadeTransition(
        opacity: _opacity,
        child: FocusScope(
          node: _focusScopeNode,
          onKeyEvent: (_, event) {
            if (dismissOnEscape &&
                event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              handle.close();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: dismissOnOutside ? handle.close : null,
                  child: ColoredBox(
                    color:
                        surface.barrierColor ??
                        context.shellColors.overviewScrim,
                  ),
                ),
                ScaleTransition(
                  scale: _scale,
                  child: surface.builder(context, handle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
