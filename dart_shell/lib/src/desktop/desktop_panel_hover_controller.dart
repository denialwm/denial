import 'dart:async';

/// Coordinates hover-driven panel dismissal with the panel's entrance motion.
///
/// Leaving an edge trigger while the panel is still entering records a pending
/// close instead of starting the ordinary hover timer. The timer begins only
/// once the transition reports completion, giving the pointer the full
/// [closeDelay] to enter the settled panel. Later exits use the same delay.
class DesktopPanelHoverController {
  DesktopPanelHoverController({
    required this.onClose,
    this.closeDelay = const Duration(milliseconds: 220),
  });

  final void Function() onClose;
  final Duration closeDelay;

  Timer? _closeTimer;
  bool _opening = false;
  bool _closePending = false;
  bool _disposed = false;

  void beginOpening() {
    if (_disposed) {
      return;
    }
    _opening = true;
    cancelClose();
  }

  void openingCompleted() {
    if (_disposed || !_opening) {
      return;
    }
    _opening = false;
    if (!_closePending) {
      return;
    }
    _closePending = false;
    _startCloseTimer(closeDelay);
  }

  void cancelClose() {
    if (_disposed) {
      return;
    }
    _closePending = false;
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void scheduleClose() {
    if (_disposed) {
      return;
    }
    _closeTimer?.cancel();
    _closeTimer = null;
    if (_opening) {
      _closePending = true;
      return;
    }
    _closePending = false;
    _startCloseTimer(closeDelay);
  }

  void reset() {
    if (_disposed) {
      return;
    }
    _opening = false;
    cancelClose();
  }

  void _startCloseTimer(Duration delay) {
    _closeTimer = Timer(delay, () {
      _closeTimer = null;
      if (!_disposed) {
        onClose();
      }
    });
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _closePending = false;
    _closeTimer?.cancel();
    _closeTimer = null;
  }
}
