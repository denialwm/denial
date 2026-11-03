import 'dart:async';

import 'package:flutter/services.dart';

import '../../models/display_layout.dart';
import '../../models/output_configuration.dart';
import '../denial_wire.dart' as wire;
import 'context.dart';

final class BridgeDisplaysClient {
  BridgeDisplaysClient(this._context);

  final BridgeContext _context;
  final Map<int, Completer<DisplayLayout?>> _pendingDisplayRequests = {};
  final StreamController<DisplayLayout> _displayLayouts =
      StreamController<DisplayLayout>.broadcast(sync: true);

  Future<DisplayLayout?> getDisplayLayout() async {
    if (!_context.useControlSocket) {
      return _getDisplayLayoutFromPlatform();
    }
    try {
      final configuration = DenialOutputConfiguration.fromJson(
        await _context.control.request('outputs.get'),
      );
      final enabled = configuration.outputs
          .where(
            (output) =>
                output.enabled &&
                output.logicalWidth > 0 &&
                output.logicalHeight > 0,
          )
          .toList(growable: false);
      if (enabled.isEmpty) {
        return null;
      }

      var originX = enabled.first.x.toDouble();
      var originY = enabled.first.y.toDouble();
      var right = originX + enabled.first.logicalWidth;
      var bottom = originY + enabled.first.logicalHeight;
      var engineScale = enabled.first.scale;
      for (final output in enabled.skip(1)) {
        final x = output.x.toDouble();
        final y = output.y.toDouble();
        if (x < originX) originX = x;
        if (y < originY) originY = y;
        final outputRight = x + output.logicalWidth;
        final outputBottom = y + output.logicalHeight;
        if (outputRight > right) right = outputRight;
        if (outputBottom > bottom) bottom = outputBottom;
        if (output.scale > engineScale) engineScale = output.scale;
      }

      final outputs = enabled
          .map((output) {
            final mode = output.effectiveMode;
            final pixelWidth = output.transform.swapsAxes
                ? mode.height
                : mode.width;
            final pixelHeight = output.transform.swapsAxes
                ? mode.width
                : mode.height;
            return DisplayOutput(
              monitorId: output.monitorId,
              name: output.name,
              logicalRect: Rect.fromLTWH(
                output.x - originX,
                output.y - originY,
                output.logicalWidth.toDouble(),
                output.logicalHeight.toDouble(),
              ),
              pixelSize: Size(pixelWidth.toDouble(), pixelHeight.toDouble()),
              scale: output.scale,
              refreshRate: mode.refreshHz,
            );
          })
          .toList(growable: false);
      final primary = outputs.firstWhere(
        (output) => output.name == configuration.primaryOutput,
        orElse: () => outputs.first,
      );
      final logicalSize = Size(right - originX, bottom - originY);
      final layout = DisplayLayout(
        epoch: configuration.serial,
        globalOrigin: Offset(originX, originY),
        logicalSize: logicalSize,
        pixelSize: logicalSize * engineScale,
        engineScale: engineScale,
        tickerMonitorId: primary.monitorId,
        systemBarMonitorId: primary.monitorId,
        systemBarMonitorIds: <int>[primary.monitorId],
        systemBarSide: SystemBarSide.top,
        systemBarThickness: 32.0,
        maximizePadding: 10.0,
        outputs: outputs,
      );
      if (!_displayLayouts.isClosed) {
        _displayLayouts.add(layout);
      }
      return layout;
    } on Object {
      return null;
    }
  }

  Future<DisplayLayout?> _getDisplayLayoutFromPlatform() {
    final requestId = _context.platform.nextRequestId();
    final completer = Completer<DisplayLayout?>();
    _pendingDisplayRequests[requestId] = completer;
    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.GetDisplayLayout,
        requestId: requestId,
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingDisplayRequests.remove(requestId);
        return null;
      },
    );
  }

  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
    required double systemBarThickness,
    required double maximizePadding,
  }) {
    final requestId = _context.platform.nextRequestId();
    final bytes = _context.codec.encodeSystemBarConfiguration(
      requestId: requestId,
      side: side,
      monitorIds: monitorIds,
      systemBarThickness: systemBarThickness,
      maximizePadding: maximizePadding,
    );
    if (bytes == null) {
      return Future<DisplayLayout?>.value(null);
    }
    final completer = Completer<DisplayLayout?>();
    _pendingDisplayRequests[requestId] = completer;
    _context.sendWire(bytes);
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingDisplayRequests.remove(requestId);
        return null;
      },
    );
  }

  Future<DenialOutputConfiguration> readOutputConfiguration() async {
    final result = await _context.control.request('outputs.get');
    return DenialOutputConfiguration.fromJson(result);
  }

  Future<DenialOutputConfiguration> applyOutputConfiguration({
    required int serial,
    required List<DenialOutput> outputs,
    required bool persistent,
    String? primaryOutput,
    int? confirmationTimeoutMilliseconds,
  }) async {
    final result = await _context.control.request(
      'outputs.apply',
      parameters: <String, Object>{
        'serial': serial,
        'persistent': persistent,
        'primary_output': ?primaryOutput,
        'confirmation_timeout_milliseconds': ?confirmationTimeoutMilliseconds,
        'outputs': <Map<String, Object>>[
          for (final output in outputs) output.toApplyJson(),
        ],
      },
    );
    return DenialOutputConfiguration.fromJson(result);
  }

  Future<void> confirmOutputConfiguration(int token) async {
    await _context.control.request(
      'outputs.confirm',
      parameters: <String, Object>{'token': token},
    );
  }

  Future<void> rollbackOutputConfiguration(int token) async {
    await _context.control.request(
      'outputs.rollback',
      parameters: <String, Object>{'token': token},
    );
  }

  /// The grade of the desktop, or of one app, with its base LUT's title.
  Future<Map<String, Object?>> readColorGrade({String? appId}) =>
      _context.control.request(
        'color.grade.get',
        parameters: <String, Object>{'app_id': ?appId},
      );

  /// Shows [grade] at once; [save] keeps it for the next start.
  Future<Map<String, Object?>> writeColorGrade({
    String? appId,
    required Map<String, Object> grade,
    required bool save,
  }) => _context.control.request(
    'color.grade.set',
    parameters: <String, Object>{
      'app_id': ?appId,
      'grade': grade,
      'save': save,
    },
  );

  /// Puts [path], a `.cube` file, under the grade, or nothing for null.
  Future<void> setColorBase({String? appId, String? path}) async {
    final scope = appId == null ? 'color.lut' : 'color.app.lut';
    await _context.control.request(
      path == null ? '$scope.clear' : '$scope.load',
      parameters: <String, Object>{'app_id': ?appId, 'path': ?path},
    );
  }

  /// False when readying the desktop restarts the shell, which then opens
  /// the editor again by itself.
  Future<bool> prepareColorTuning() async {
    final result = await _context.control.request('color.tune.prepare');
    return result['ready'] == true;
  }

  Stream<DisplayLayout> get displayLayouts => _displayLayouts.stream;

  void completeLayout(int requestId, wire.DisplayLayout payload) {
    final layout = _context.codec.decodeDisplayLayout(payload);
    if (layout == null) {
      return;
    }
    final completer = _pendingDisplayRequests.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(layout);
    } else if (requestId == 0 && !_displayLayouts.isClosed) {
      _displayLayouts.add(layout);
    }
  }

  void reject(int requestId) {
    final pending = _pendingDisplayRequests.remove(requestId);
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  void dispose() {
    for (final pending in _pendingDisplayRequests.values) {
      if (!pending.isCompleted) pending.complete(null);
    }
    _pendingDisplayRequests.clear();
    unawaited(_displayLayouts.close());
  }
}
