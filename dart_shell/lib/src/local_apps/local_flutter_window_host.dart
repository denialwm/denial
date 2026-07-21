import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../models/denial_window.dart';
import '../state/shell_controller.dart';
import '../theme/tokens.dart';
import 'local_flutter_application.dart';

/// Resolves and mounts the in-bundle widget tree for a native local window.
/// The host remains keyed by native window identity through move, resize,
/// minimize, overview, and switching transitions, preserving application
/// element state just like an ordinary desktop window preserves its client.
class LocalFlutterWindowHost extends ConsumerStatefulWidget {
  const LocalFlutterWindowHost({
    required this.window,
    required this.active,
    super.key,
  });

  final DenialWindow window;
  final bool active;

  @override
  ConsumerState<LocalFlutterWindowHost> createState() =>
      _LocalFlutterWindowHostState();
}

class _LocalFlutterWindowHostState
    extends ConsumerState<LocalFlutterWindowHost> {
  late final FocusScopeNode _focusScope = FocusScopeNode(
    debugLabel: 'local-app-${widget.window.appId}-${widget.window.objectId}',
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _requestFocusAfterFrame();
    }
  }

  @override
  void didUpdateWidget(covariant LocalFlutterWindowHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _requestFocusAfterFrame();
    } else if (!widget.active && oldWidget.active) {
      _focusScope.unfocus();
    }
  }

  void _requestFocusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) {
        _focusScope.requestFocus();
      }
    });
  }

  void _focusWindow() {
    _focusScope.requestFocus();
    ref.read(shellControllerProvider.notifier).focusWindow(widget.window);
  }

  void _closeWindow() {
    ref.read(shellControllerProvider.notifier).closeWindow(widget.window);
  }

  @override
  void dispose() {
    _focusScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final application =
        ref.watch(localFlutterApplicationRegistryProvider)[widget.window.appId];
    final handle = LocalFlutterWindowHandle(
      window: widget.window,
      focus: _focusWindow,
      close: _closeWindow,
    );
    final content = application?.builder(context, handle) ??
        _MissingLocalFlutterApplication(window: widget.window);

    return ShellInputRegion(
      debugLabel: 'Local app ${widget.window.appId}',
      active: widget.active,
      pointerPolicy: ShellPointerPolicy.none,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      child: FocusScope(
        node: _focusScope,
        child: FocusTraversalGroup(
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: widget.window.displayTitle,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _focusWindow(),
              child: KeyedSubtree(
                key: ValueKey<String>(widget.window.appId),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MissingLocalFlutterApplication extends StatelessWidget {
  const _MissingLocalFlutterApplication({required this.window});

  final DenialWindow window;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ShellColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Local application “${window.appId}” is not registered.',
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(color: ShellColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
