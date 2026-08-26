import 'dart:math' as math;

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
    this.systemBarMonitorIds = const <int>[],
    required this.systemBarSide,
    required this.outputs,
    this.systemBarThickness = 0.0,
    this.maximizePadding = 0.0,
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
      systemBarMonitorIds: const <int>[0],
      systemBarSide: SystemBarSide.top,
      systemBarThickness: 32.0,
      maximizePadding: 10.0,
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

  /// All outputs which host independent copies of the system bar. Empty is
  /// the legacy wire representation and falls back to [systemBarMonitorId].
  final List<int> systemBarMonitorIds;
  final int systemBarMonitorId;
  final SystemBarSide systemBarSide;
  final double systemBarThickness;

  /// Logical pixels of breathing room between a maximized window and every
  /// output edge the system bar does not occupy. Zero keeps maximized
  /// windows flush with the output edges.
  final double maximizePadding;
  final List<DisplayOutput> outputs;

  /// Whether the rectangular Flutter atlas contains space that belongs to no
  /// physical output. This occurs in mixed-orientation and offset layouts.
  /// Output topology rejects overlaps, so summing clipped output areas is the
  /// exact covered area of the atlas.
  bool get hasAtlasGaps {
    if (outputs.isEmpty || logicalSize.isEmpty) {
      return false;
    }
    final canvas = Offset.zero & logicalSize;
    var coveredArea = 0.0;
    for (final output in outputs) {
      final visible = output.logicalRect.intersect(canvas);
      if (!visible.isEmpty) {
        coveredArea += visible.width * visible.height;
      }
    }
    final canvasArea = canvas.width * canvas.height;
    return coveredArea < canvasArea - 0.01;
  }

  List<int> get effectiveSystemBarMonitorIds {
    if (systemBarMonitorIds.isNotEmpty) {
      return systemBarMonitorIds;
    }
    return systemBarMonitorId < 0 ? const <int>[] : <int>[systemBarMonitorId];
  }

  bool hostsSystemBar(DisplayOutput output) =>
      effectiveSystemBarMonitorIds.contains(output.monitorId);

  List<DisplayOutput> get systemBarOutputs =>
      List<DisplayOutput>.unmodifiable(outputs.where(hostsSystemBar));

  DisplayOutput? get systemBarOutput {
    for (final output in outputs) {
      if (output.monitorId == systemBarMonitorId) {
        return output;
      }
    }
    final selected = systemBarOutputs;
    return selected.isEmpty ? null : selected.first;
  }

  /// Whether a system bar strip is configured and can land on an output.
  bool get systemBarActive =>
      systemBarSide != SystemBarSide.hidden &&
      systemBarThickness > 0.0 &&
      systemBarOutputs.isNotEmpty;

  /// The flush strip the system bar occupies inside [outputRect], or
  /// [Rect.zero] when the bar is hidden. The strip is clamped so a
  /// misconfigured thickness can never swallow the whole output.
  Rect systemBarRectWithin(Rect outputRect) {
    if (systemBarSide == SystemBarSide.hidden ||
        systemBarThickness <= 0.0 ||
        outputRect.isEmpty) {
      return Rect.zero;
    }
    if (systemBarSide.isHorizontal) {
      final thickness = math.min(systemBarThickness, outputRect.height / 2.0);
      return systemBarSide == SystemBarSide.top
          ? Rect.fromLTWH(
              outputRect.left,
              outputRect.top,
              outputRect.width,
              thickness,
            )
          : Rect.fromLTWH(
              outputRect.left,
              outputRect.bottom - thickness,
              outputRect.width,
              thickness,
            );
    }
    final thickness = math.min(systemBarThickness, outputRect.width / 2.0);
    return systemBarSide == SystemBarSide.left
        ? Rect.fromLTWH(
            outputRect.left,
            outputRect.top,
            thickness,
            outputRect.height,
          )
        : Rect.fromLTWH(
            outputRect.right - thickness,
            outputRect.top,
            thickness,
            outputRect.height,
          );
  }

  /// The system bar strip in desktop scene coordinates, or [Rect.zero] when
  /// the bar is hidden.
  Rect get systemBarRect {
    final output = systemBarOutput;
    if (!systemBarActive || output == null) {
      return Rect.zero;
    }
    return systemBarRectWithin(output.logicalRect);
  }

  /// The bar strip for one selected output, or [Rect.zero] when that output
  /// does not host a clone.
  Rect systemBarRectFor(DisplayOutput output) {
    if (!systemBarActive || !hostsSystemBar(output)) {
      return Rect.zero;
    }
    return systemBarRectWithin(output.logicalRect);
  }

  /// [outputRect] minus the system bar strip [bar] on [barSide], and minus
  /// [maximizePadding] on every bar-free edge. The padding is clamped so a
  /// misconfigured value can never swallow the output.
  Rect _workAreaInset(Rect outputRect, Rect bar, SystemBarSide barSide) {
    final padding = maximizePadding.isFinite && maximizePadding > 0.0
        ? math.min(
            maximizePadding,
            math.min(outputRect.width, outputRect.height) / 4.0,
          )
        : 0.0;
    return Rect.fromLTRB(
      barSide == SystemBarSide.left ? bar.right : outputRect.left + padding,
      barSide == SystemBarSide.top ? bar.bottom : outputRect.top + padding,
      barSide == SystemBarSide.right ? bar.left : outputRect.right - padding,
      barSide == SystemBarSide.bottom ? bar.top : outputRect.bottom - padding,
    );
  }

  /// [outputRect] minus the system bar strip when the bar lives on that
  /// output, and minus [maximizePadding] on every bar-free edge; windows
  /// maximize into this area while true fullscreen keeps the complete output
  /// rect.
  Rect workAreaWithin(Rect outputRect) {
    final bar = systemBarRectWithin(outputRect);
    final barSide = bar.isEmpty ? SystemBarSide.hidden : systemBarSide;
    return _workAreaInset(outputRect, bar, barSide);
  }

  Rect workAreaOf(DisplayOutput output) {
    if (!systemBarActive || !hostsSystemBar(output)) {
      return _workAreaInset(
        output.logicalRect,
        Rect.zero,
        SystemBarSide.hidden,
      );
    }
    return workAreaWithin(output.logicalRect);
  }

  DisplayLayout copyWithSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
    double? thickness,
    double? windowPadding,
  }) {
    final selected = List<int>.unmodifiable(monitorIds);
    final primary = selected.contains(tickerMonitorId)
        ? tickerMonitorId
        : selected.isEmpty
        ? -1
        : selected.first;
    return DisplayLayout(
      epoch: epoch,
      globalOrigin: globalOrigin,
      logicalSize: logicalSize,
      pixelSize: pixelSize,
      engineScale: engineScale,
      tickerMonitorId: tickerMonitorId,
      systemBarMonitorId: primary,
      systemBarMonitorIds: selected,
      systemBarSide: side,
      systemBarThickness: thickness ?? systemBarThickness,
      maximizePadding: windowPadding ?? maximizePadding,
      outputs: outputs,
    );
  }

  DisplayLayout copyWithShellMetrics({
    required double systemBarThickness,
    required double maximizePadding,
  }) {
    return copyWithSystemBar(
      side: systemBarSide,
      monitorIds: effectiveSystemBarMonitorIds,
      thickness: systemBarThickness,
      windowPadding: maximizePadding,
    );
  }

  Map<int, Rect> workAreasByMonitor() {
    return <int, Rect>{
      for (final output in outputs) output.monitorId: workAreaOf(output),
    };
  }

  /// The output that owns shell experiences intended for the user's primary
  /// display. The compositor's render ticker carries either the configured
  /// primary output or its highest-refresh default. A stable top-left fallback
  /// keeps malformed or older layouts deterministic without coupling primary
  /// display selection to the system-bar host.
  DisplayOutput? get mainOutput {
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
      final isFurtherUp =
          output.logicalRect.left == result.logicalRect.left &&
          output.logicalRect.top < result.logicalRect.top;
      if (isFurtherLeft || isFurtherUp) {
        result = output;
      }
    }
    return result;
  }
}
