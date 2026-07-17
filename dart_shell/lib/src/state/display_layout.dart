import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../platform/denial_bridge.dart';
import 'shell_controller.dart';

final displayLayoutProvider =
    StateNotifierProvider<DisplayLayoutController, DisplayLayout?>((ref) {
  // The shell controller installs the shared native message handler before the
  // display-layout request is sent.
  ref.read(shellControllerProvider);
  return DisplayLayoutController(ref.read(denialBridgeProvider));
});

class DisplayLayoutController extends StateNotifier<DisplayLayout?> {
  DisplayLayoutController(this._bridge) : super(null) {
    unawaited(ensureLoaded());
  }

  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  final DenialBridge _bridge;
  bool _disposed = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  Future<DisplayLayout?>? _requestInFlight;

  Future<DisplayLayout?> ensureLoaded() {
    final current = state;
    if (current != null) {
      return Future<DisplayLayout?>.value(current);
    }
    final inFlight = _requestInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    final request = _load();
    _requestInFlight = request;
    unawaited(request.whenComplete(() {
      if (identical(_requestInFlight, request)) {
        _requestInFlight = null;
      }
    }));
    return request;
  }

  Future<DisplayLayout?> _load() async {
    DisplayLayout? layout;
    try {
      layout = await _bridge.getDisplayLayout();
    } on Object {
      layout = null;
    }
    if (_disposed) {
      return null;
    }
    if (layout != null && layout.outputs.isNotEmpty) {
      _retryAttempt = 0;
      state = layout;
      return layout;
    }
    _scheduleRetry();
    return null;
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer != null) {
      return;
    }
    final delayIndex = _retryAttempt.clamp(0, _retryDelays.length - 1).toInt();
    final delay = _retryDelays[delayIndex];
    _retryAttempt += 1;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!_disposed) {
        unawaited(ensureLoaded());
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    super.dispose();
  }
}
