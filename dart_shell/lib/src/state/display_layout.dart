import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../platform/denial_bridge.dart';
import 'notifier_lifecycle.dart';
import 'shell_controller.dart';

final displayLayoutProvider =
    NotifierProvider<DisplayLayoutController, DisplayLayout?>(
      DisplayLayoutController.new,
    );

class DisplayLayoutController extends Notifier<DisplayLayout?>
    with NotifierLifecycle<DisplayLayout?> {
  @override
  DisplayLayout? build() {
    _bridge = ref.watch(denialBridgeProvider);
    _retryAttempt = 0;
    _retryTimer = null;
    _requestInFlight = null;
    _configurationSerial = 0;
    _configuredSide = null;
    _configuredOutputNames = const <String>[];
    _configuredThickness = null;
    _configuredMaximizePadding = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    cancelOnDispose(
      _bridge.displayLayouts.listen((layout) {
        if (!isBuildGenerationActive(generation) || layout.outputs.isEmpty) {
          return;
        }
        _retryAttempt = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
        final configured = _applyConfiguredValues(layout);
        state = configured;
        _publishConfiguredSystemBar(layout, configured);
      }),
    );
    ref.onDispose(() {
      _retryTimer?.cancel();
      _retryTimer = null;
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        unawaited(ensureLoaded());
      }
    });
    return null;
  }

  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  late DenialBridge _bridge;
  late int _buildGeneration;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  Future<DisplayLayout?>? _requestInFlight;
  int _configurationSerial = 0;
  SystemBarSide? _configuredSide;
  List<String> _configuredOutputNames = const <String>[];
  double? _configuredThickness;
  double? _configuredMaximizePadding;

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
    final generation = _buildGeneration;
    final request = _load(generation);
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

  Future<DisplayLayout?> _load(int generation) async {
    DisplayLayout? layout;
    try {
      layout = await _bridge.getDisplayLayout();
    } on Object {
      layout = null;
    }
    if (!isBuildGenerationActive(generation)) {
      return null;
    }
    if (layout != null && layout.outputs.isNotEmpty) {
      _retryAttempt = 0;
      final configured = _applyConfiguredValues(layout);
      state = configured;
      _publishConfiguredSystemBar(layout, configured);
      return configured;
    }
    _scheduleRetry(generation);
    return null;
  }

  void _scheduleRetry(int generation) {
    if (!isBuildGenerationActive(generation) || _retryTimer != null) {
      return;
    }
    final delayIndex = _retryAttempt.clamp(0, _retryDelays.length - 1).toInt();
    final delay = _retryDelays[delayIndex];
    _retryAttempt += 1;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (isBuildGenerationActive(generation)) {
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
    final generation = _buildGeneration;
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
    if (!isBuildGenerationActive(generation) ||
        serial != _configurationSerial) {
      return resolved != null;
    }
    state = _applyConfiguredValues(resolved ?? previous);
    return resolved != null;
  }

  /// Updates Settings' local topology preview without sending an embedder
  /// command. The committed settings document is what instructs the embedded
  /// shell to publish the real compositor work area.
  void previewSystemBar({
    required SystemBarSide side,
    required Iterable<int> monitorIds,
  }) {
    final current = state;
    if (current == null) return;
    final requested = monitorIds.toSet();
    final ordered = current.outputs
        .where((output) => requested.contains(output.monitorId))
        .map((output) => output.monitorId)
        .toList(growable: false);
    if (ordered.isEmpty && side != SystemBarSide.hidden) return;
    state = current.copyWithSystemBar(side: side, monitorIds: ordered);
  }

  /// Applies persisted shell policy without coupling this runtime controller
  /// to the Settings UI or its serialization model.
  void applyShellConfiguration({
    required SystemBarSide? side,
    required Iterable<String> outputNames,
    required double systemBarThickness,
    required double maximizePadding,
  }) {
    _configuredSide = side;
    _configuredOutputNames = List<String>.unmodifiable(outputNames);
    _configuredThickness = systemBarThickness;
    _configuredMaximizePadding = maximizePadding;
    final current = state;
    if (current == null) {
      return;
    }
    final configured = _applyConfiguredValues(current);
    if (!_sameShellConfiguration(current, configured)) {
      state = configured;
    }
    _publishConfiguredSystemBar(current, configured);
  }

  DisplayLayout _applyConfiguredValues(DisplayLayout layout) {
    final selectedNames = _configuredOutputNames.toSet();
    final selectedIds = selectedNames.isEmpty
        ? layout.effectiveSystemBarMonitorIds
        : layout.outputs
              .where((output) => selectedNames.contains(output.name))
              .map((output) => output.monitorId)
              .toList(growable: false);
    final side = _configuredSide ?? layout.systemBarSide;
    final monitorIds = selectedIds.isEmpty
        ? layout.effectiveSystemBarMonitorIds
        : selectedIds;
    return layout.copyWithSystemBar(
      side: side,
      monitorIds: monitorIds,
      thickness: _configuredThickness ?? layout.systemBarThickness,
      windowPadding: _configuredMaximizePadding ?? layout.maximizePadding,
    );
  }

  bool _sameShellConfiguration(DisplayLayout left, DisplayLayout right) {
    return left.systemBarSide == right.systemBarSide &&
        left.systemBarThickness == right.systemBarThickness &&
        left.maximizePadding == right.maximizePadding &&
        listEquals(
          left.effectiveSystemBarMonitorIds,
          right.effectiveSystemBarMonitorIds,
        );
  }

  void _publishConfiguredSystemBar(
    DisplayLayout native,
    DisplayLayout configured,
  ) {
    if (_configuredSide == null ||
        _configuredOutputNames.isEmpty ||
        (native.systemBarSide == configured.systemBarSide &&
            native.effectiveSystemBarMonitorIds.toSet().containsAll(
              configured.effectiveSystemBarMonitorIds,
            ) &&
            native.effectiveSystemBarMonitorIds.length ==
                configured.effectiveSystemBarMonitorIds.length)) {
      return;
    }
    unawaited(_sendConfiguredSystemBar(configured));
  }

  Future<void> _sendConfiguredSystemBar(DisplayLayout configured) async {
    try {
      await _bridge.configureSystemBar(
        side: configured.systemBarSide,
        monitorIds: configured.effectiveSystemBarMonitorIds,
      );
    } on Object {
      // Persisted policy is applied locally even when the native bridge is
      // temporarily unavailable; bridge failure must not take down the shell.
    }
  }
}
