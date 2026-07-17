import 'package:flutter/widgets.dart';

enum SystemBarSide {
  left,
  right,
  top,
  bottom,
  hidden;

  bool get isHorizontal => this == top || this == bottom;
}

@immutable
class DisplayOutput {
  const DisplayOutput({
    required this.monitorId,
    required this.name,
    required this.logicalRect,
    required this.pixelSize,
    required this.scale,
    required this.refreshRate,
  });

  final int monitorId;
  final String name;
  final Rect logicalRect;
  final Size pixelSize;
  final double scale;
  final double refreshRate;
}

@immutable
class DisplayLayout {
  const DisplayLayout({
    required this.epoch,
    required this.globalOrigin,
    required this.logicalSize,
    required this.pixelSize,
    required this.engineScale,
    required this.tickerMonitorId,
    required this.systemBarMonitorId,
    required this.systemBarSide,
    required this.outputs,
  });

  factory DisplayLayout.fallback(Size logicalSize, double scale) {
    final safeScale = scale.isFinite && scale > 0.0 ? scale : 1.0;
    return DisplayLayout(
      epoch: 0,
      globalOrigin: Offset.zero,
      logicalSize: logicalSize,
      pixelSize: logicalSize * safeScale,
      engineScale: safeScale,
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      systemBarSide: SystemBarSide.left,
      outputs: <DisplayOutput>[
        DisplayOutput(
          monitorId: 0,
          name: 'default',
          logicalRect: Offset.zero & logicalSize,
          pixelSize: logicalSize * safeScale,
          scale: safeScale,
          refreshRate: 60.0,
        ),
      ],
    );
  }

  final int epoch;
  final Offset globalOrigin;
  final Size logicalSize;
  final Size pixelSize;
  final double engineScale;
  final int tickerMonitorId;
  final int systemBarMonitorId;
  final SystemBarSide systemBarSide;
  final List<DisplayOutput> outputs;

  DisplayOutput? get systemBarOutput {
    for (final output in outputs) {
      if (output.monitorId == systemBarMonitorId) {
        return output;
      }
    }
    return outputs.isEmpty ? null : outputs.first;
  }

  /// The output that owns shell experiences intended for the user's main
  /// display. The explicitly configured system-bar output is the strongest
  /// signal, followed by the compositor's render-ticker output. A stable
  /// top-left fallback keeps malformed or older layouts deterministic.
  DisplayOutput? get mainOutput {
    for (final output in outputs) {
      if (output.monitorId == systemBarMonitorId) {
        return output;
      }
    }
    for (final output in outputs) {
      if (output.monitorId == tickerMonitorId) {
        return output;
      }
    }
    if (outputs.isEmpty) {
      return null;
    }
    var result = outputs.first;
    for (final output in outputs.skip(1)) {
      final isFurtherLeft = output.logicalRect.left < result.logicalRect.left;
      final isFurtherUp = output.logicalRect.left == result.logicalRect.left &&
          output.logicalRect.top < result.logicalRect.top;
      if (isFurtherLeft || isFurtherUp) {
        result = output;
      }
    }
    return result;
  }
}
