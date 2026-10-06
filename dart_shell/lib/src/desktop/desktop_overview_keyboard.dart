import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_workspace.dart';

/// Owns keyboard focus while the desktop overview is open.
class DesktopOverviewKeyboard extends StatefulWidget {
  const DesktopOverviewKeyboard({
    super.key,
    required this.active,
    required this.onNavigate,
    required this.onActivate,
    required this.onDismiss,
    required this.child,
  });

  final bool active;
  final ValueChanged<DesktopOverviewDirection> onNavigate;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<DesktopOverviewKeyboard> createState() =>
      _DesktopOverviewKeyboardState();
}

class _DesktopOverviewKeyboardState extends State<DesktopOverviewKeyboard> {
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'desktop-overview-keyboard',
    skipTraversal: true,
  );
  bool _focusRequestScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _requestFocusAfterFrame();
    }
  }

  @override
  void didUpdateWidget(covariant DesktopOverviewKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _requestFocusAfterFrame();
    } else if (!widget.active && oldWidget.active && _focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _requestFocusAfterFrame() {
    if (_focusRequestScheduled) {
      return;
    }
    _focusRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusRequestScheduled = false;
      if (mounted && widget.active) {
        _focusNode.requestFocus();
      }
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (!widget.active || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => DesktopOverviewDirection.left,
      LogicalKeyboardKey.arrowRight => DesktopOverviewDirection.right,
      LogicalKeyboardKey.arrowUp => DesktopOverviewDirection.up,
      LogicalKeyboardKey.arrowDown => DesktopOverviewDirection.down,
      _ => null,
    };
    if (direction != null) {
      widget.onNavigate(direction);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        widget.onActivate();
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.active,
      onKeyEvent: _handleKeyEvent,
      child: widget.child,
    );
  }
}
