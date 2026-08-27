import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature, FramePhase, FrameTiming, TimingsCallback;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../config/startup_environment.dart';
import '../localization/denial_localizations.dart';
import '../models/denial_window.dart';
import '../theme/shell_color_scheme.dart';
import '../theme/shell_theme.dart';

part 'frame_timing_imported_chart.dart';
part 'frame_timing_shell_chart.dart';
part 'frame_timing_shell_overlay.dart';

/// Diagnostics are opt-in: even a rate-limited frame overlay participates in
/// frame scheduling and must not tax the production shell it is measuring.
class ShellFrameTimingOptions {
  const ShellFrameTimingOptions({
    required this.showOverlay,
    required this.showImportedTextureCharts,
  });

  final bool showOverlay;
  final bool showImportedTextureCharts;
}

final shellFrameTimingOptionsProvider = Provider<ShellFrameTimingOptions>((
  ref,
) {
  final environment = ref.watch(startupEnvironmentProvider);
  final showOverlay = environment.flag('DENIA_FRAME_TIMING_OVERLAY');
  return ShellFrameTimingOptions(
    showOverlay: showOverlay,
    showImportedTextureCharts:
        showOverlay &&
        environment.flag(
          'DENIA_IMPORTED_FRAME_TIMING_OVERLAY',
          defaultValue: true,
        ),
  );
});

/// Owns the shell chart and one independent chart for every imported texture.
///
/// Imported callback-to-commit timings arrive already bucketed by the
/// compositor, so diagnostics cross the platform channel only five times per
/// second per active surface.
class ShellFrameTimingOverlayStack extends StatefulWidget {
  const ShellFrameTimingOverlayStack({
    required this.windows,
    required this.showImportedTextureCharts,
    super.key,
  });

  final List<DenialWindow> windows;
  final bool showImportedTextureCharts;

  @override
  State<ShellFrameTimingOverlayStack> createState() =>
      _ShellFrameTimingOverlayStackState();
}

class _ShellFrameTimingOverlayStackState
    extends State<ShellFrameTimingOverlayStack> {
  static const String _timingChannel = 'denial/imported_frame_timing';
  static const String _controlChannel = 'denial/imported_frame_timing_control';
  static const int _messageBytes = 7 * 8;
  static final Future<ByteData?> _emptyResponse = SynchronousFuture<ByteData?>(
    null,
  );

  final Map<int, _ImportedFrameTimingSampler> _samplers = {};
  bool _channelStarted = false;
  int _budgetUs = (1000000 / 60).round();

  @override
  void initState() {
    super.initState();
    _syncSamplers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.showImportedTextureCharts) {
      return;
    }

    final reportedRate = View.of(context).display.refreshRate;
    final refreshRate = reportedRate.isFinite && reportedRate > 0
        ? reportedRate
        : 60.0;
    final nextBudgetUs = (1000000 / refreshRate).round();
    final budgetChanged = nextBudgetUs != _budgetUs;
    _budgetUs = nextBudgetUs;
    for (final sampler in _samplers.values) {
      sampler.updateBudget(_budgetUs / 1000);
    }

    if (!_channelStarted) {
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _timingChannel,
        _handleTimingMessage,
      );
      _channelStarted = true;
      _sendTimingControl(enabled: true);
    } else if (budgetChanged) {
      _sendTimingControl(enabled: true);
    }
  }

  @override
  void didUpdateWidget(covariant ShellFrameTimingOverlayStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.windows != widget.windows) {
      _syncSamplers();
    }
  }

  @override
  void dispose() {
    if (_channelStarted) {
      _sendTimingControl(enabled: false);
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _timingChannel,
        null,
      );
    }
    for (final sampler in _samplers.values) {
      sampler.dispose();
    }
    _samplers.clear();
    super.dispose();
  }

  void _syncSamplers() {
    if (!widget.showImportedTextureCharts) {
      return;
    }

    final activeSurfaceIds = widget.windows
        .map((window) => window.surfaceId)
        .toSet();
    final removedSurfaceIds = _samplers.keys
        .where((surfaceId) => !activeSurfaceIds.contains(surfaceId))
        .toList(growable: false);
    for (final surfaceId in removedSurfaceIds) {
      _samplers.remove(surfaceId)?.dispose();
    }
    for (final surfaceId in activeSurfaceIds) {
      _samplers.putIfAbsent(
        surfaceId,
        () => _ImportedFrameTimingSampler(_budgetUs / 1000),
      );
    }
  }

  void _sendTimingControl({required bool enabled}) {
    final data = ByteData(1 + 8)
      ..setUint8(0, enabled ? 1 : 0)
      ..setUint64(1, _budgetUs, Endian.little);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_controlChannel, data)
        ?.catchError((Object _) => null);
  }

  Future<ByteData?> _handleTimingMessage(ByteData? data) {
    if (data == null || data.lengthInBytes < _messageBytes) {
      return _emptyResponse;
    }

    final surfaceId = data.getUint64(0, Endian.little);
    final sampler = _samplers[surfaceId];
    if (sampler == null) {
      return _emptyResponse;
    }

    sampler.addBucket(
      _ImportedFrameTimeBucket(
        averageMs: data.getUint64(24, Endian.little) / 1000,
        peakMs: data.getUint64(32, Endian.little) / 1000,
        frameCount: data.getUint64(40, Endian.little),
        overBudgetFrames: data.getUint64(48, Endian.little),
      ),
    );
    return _emptyResponse;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ShellFrameTimeOverlay(),
            if (widget.showImportedTextureCharts)
              for (final window in widget.windows)
                if (_samplers[window.surfaceId] case final sampler?) ...[
                  const SizedBox(height: 6),
                  _ImportedTextureFrameTimeOverlay(
                    key: ValueKey(window.surfaceId),
                    title: localizedWindowTitle(context, window),
                    sampler: sampler,
                  ),
                ],
          ],
        ),
      ),
    );
  }
}

/// A low-overhead view of the embedded shell engine's real frame timings.
///
/// Unlike a [Ticker]-based meter, this widget does not manufacture a frame on
/// every vsync. It observes completed engine frames and refreshes its own small
/// repaint boundary at most five times per second while other work is active.
