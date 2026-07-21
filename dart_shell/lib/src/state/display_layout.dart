import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';

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
  int _configurationSerial = 0;

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
    unawaited(
      request.whenComplete(() {
        if (identical(_requestInFlight, request)) {
          _requestInFlight = null;
        }
      }),
    );
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

  Future<bool> configureSystemBar({
    required SystemBarSide side,
    required Iterable<int> monitorIds,
  }) async {
    final previous = state;
    if (previous == null || side == SystemBarSide.hidden) {
      return false;
    }
    final requested = monitorIds.toSet();
    if (requested.isEmpty ||
        requested.any(
          (monitorId) =>
              !previous.outputs.any((output) => output.monitorId == monitorId),
        )) {
      return false;
    }
    final ordered = previous.outputs
        .where((output) => requested.contains(output.monitorId))
        .map((output) => output.monitorId)
        .toList(growable: false);
    final currentIds = previous.effectiveSystemBarMonitorIds.toSet();
    if (side == previous.systemBarSide &&
        currentIds.length == requested.length &&
        currentIds.containsAll(requested)) {
      return true;
    }

    final serial = ++_configurationSerial;
    state = previous.copyWithSystemBar(side: side, monitorIds: ordered);
    DisplayLayout? resolved;
    try {
      resolved = await _bridge.configureSystemBar(
        side: side,
        monitorIds: ordered,
      );
    } on Object {
      resolved = null;
    }
    if (_disposed || serial != _configurationSerial) {
      return resolved != null;
    }
    state = resolved ?? previous;
    return resolved != null;
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    super.dispose();
  }
}
