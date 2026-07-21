import 'package:flutter/widgets.dart';

import '../models/display_layout.dart';
import '../models/denial_window.dart';
import 'desktop_overview_layout.dart';
import 'desktop_workspace.dart';

class DesktopOverviewTarget {
  const DesktopOverviewTarget({
    required this.monitorId,
    required this.bounds,
    required this.backgroundBounds,
    required this.objectIds,
  });

  final int monitorId;
  final Rect bounds;
  final Rect backgroundBounds;
  final Set<int> objectIds;

  static DesktopOverviewTarget? resolve({
    required Size viewSize,
    required DisplayLayout? displayLayout,
    required List<DenialWindow> windows,
    required DesktopWorkspaceState workspace,
    required int? foregroundObjectId,
    required int? preferredMonitorId,
  }) {
    final canvas = Offset.zero & viewSize;
    if (canvas.isEmpty || workspace.placements.isEmpty) {
      return null;
    }

    final windowsById = <int, DenialWindow>{
      for (final window in windows) window.objectId: window,
    };
    final foreground = windowsById[foregroundObjectId];
    final topmost = workspace.placements.values.fold<DesktopWindowPlacement?>(
      null,
      (current, placement) =>
          current == null || placement.z > current.z ? placement : current,
    );
    final anchor =
        foreground ?? (topmost == null ? null : windowsById[topmost.objectId]);
    final anchorPlacement =
        anchor == null ? null : workspace.placements[anchor.objectId];
    final outputs = displayLayout?.outputs
            .where((output) => !output.logicalRect.intersect(canvas).isEmpty)
            .toList(growable: false) ??
        const <DisplayOutput>[];

    DisplayOutput? output = preferredMonitorId == null
        ? null
        : _outputById(outputs, preferredMonitorId);
    if (output == null && anchorPlacement != null) {
      output = _outputById(outputs, anchorPlacement.monitorId);
      output ??= _outputContaining(outputs, anchorPlacement.frame.center);
    }
    output ??= displayLayout?.systemBarOutput;

    final fallbackMonitorId = preferredMonitorId ?? anchorPlacement?.monitorId;
    final monitorId = output?.monitorId ?? fallbackMonitorId ?? 0;
    final monitorBounds = (output?.logicalRect ?? canvas).intersect(canvas);
    if (monitorBounds.isEmpty) {
      return null;
    }

    final objectIds = <int>{};
    for (final placement in workspace.placements.values) {
      final window = windowsById[placement.objectId];
      if (window == null) {
        continue;
      }
      if (!DesktopOverviewLayout.isUsefulPreview(placement.frame)) {
        continue;
      }
      final belongsToOutput = switch ((output, fallbackMonitorId)) {
        (final DisplayOutput targetOutput, _) when placement.monitorId >= 0 =>
          placement.monitorId == targetOutput.monitorId,
        (null, final int anchorMonitorId)
            when anchorMonitorId >= 0 && placement.monitorId >= 0 =>
          placement.monitorId == anchorMonitorId,
        _ => monitorBounds.contains(placement.frame.center),
      };
      if (belongsToOutput) {
        objectIds.add(placement.objectId);
      }
    }
    if (objectIds.isEmpty) {
      return null;
    }

    var overviewBounds = monitorBounds;
    final systemBarRect = output == null
        ? Rect.zero
        : displayLayout?.systemBarRectFor(output).intersect(canvas) ??
            Rect.zero;
    final systemBarSide = displayLayout?.systemBarSide ?? SystemBarSide.hidden;
    if (!systemBarRect.isEmpty && systemBarRect.overlaps(monitorBounds)) {
      overviewBounds = switch (systemBarSide) {
        SystemBarSide.left => Rect.fromLTRB(
            systemBarRect.right + DesktopMetrics.panelGap,
            monitorBounds.top,
            monitorBounds.right,
            monitorBounds.bottom,
          ),
        SystemBarSide.right => Rect.fromLTRB(
            monitorBounds.left,
            monitorBounds.top,
            systemBarRect.left - DesktopMetrics.panelGap,
            monitorBounds.bottom,
          ),
        SystemBarSide.top => Rect.fromLTRB(
            monitorBounds.left,
            systemBarRect.bottom + DesktopMetrics.panelGap,
            monitorBounds.right,
            monitorBounds.bottom,
          ),
        SystemBarSide.bottom => Rect.fromLTRB(
            monitorBounds.left,
            monitorBounds.top,
            monitorBounds.right,
            systemBarRect.top - DesktopMetrics.panelGap,
          ),
        SystemBarSide.hidden => monitorBounds,
      };
    }
    if (overviewBounds.isEmpty) {
      overviewBounds = monitorBounds;
    }

    return DesktopOverviewTarget(
      monitorId: monitorId,
      bounds: overviewBounds,
      backgroundBounds: monitorBounds,
      objectIds: objectIds,
    );
  }

  static DisplayOutput? _outputById(
    List<DisplayOutput> outputs,
    int monitorId,
  ) {
    for (final output in outputs) {
      if (output.monitorId == monitorId) {
        return output;
      }
    }
    return null;
  }

  static DisplayOutput? _outputContaining(
    List<DisplayOutput> outputs,
    Offset point,
  ) {
    for (final output in outputs) {
      if (output.logicalRect.contains(point)) {
        return output;
      }
    }
    return null;
  }
}
