import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/input_layout.dart';
import '../input/shell_interaction_registry.dart';
import '../models/hypr_window.dart';
import '../state/desktop_window_switcher.dart';
import '../state/shell_controller.dart';
import 'desktop_workspace.dart';

class DesktopInputLayoutPublisher extends ConsumerStatefulWidget {
  const DesktopInputLayoutPublisher({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  ConsumerState<DesktopInputLayoutPublisher> createState() =>
      _DesktopInputLayoutPublisherState();
}

class _DesktopInputLayoutPublisherState
    extends ConsumerState<DesktopInputLayoutPublisher> {
  final Map<int, ({int width, int height})> _configuredSizes =
      <int, ({int width, int height})>{};
  bool _scheduled = false;
  int _epoch = 0;
  InputLayoutSnapshot? _lastSnapshot;

  @override
  Widget build(BuildContext context) {
    ref.watch(
      shellControllerProvider.select(
        (state) => (state.windows, state.windowSnapshotSequence),
      ),
    );
    ref.watch(desktopWorkspaceProvider);
    ref.watch(desktopWindowSwitcherProvider);
    ref.watch(shellInteractionRegistryProvider);
    _schedulePublish(
      MediaQuery.sizeOf(context),
      MediaQuery.devicePixelRatioOf(context),
    );
    return widget.child;
  }

  void _schedulePublish(Size viewSize, double devicePixelRatio) {
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) {
        return;
      }

      final shell = ref.read(shellControllerProvider);
      final windows = shell.windows;
      ref.read(desktopWorkspaceProvider.notifier).syncWindows(
            windows,
            viewSize,
            devicePixelRatio,
            snapshotSequence: shell.windowSnapshotSequence,
          );
      _publish(
        viewSize,
        ref.read(shellControllerProvider).windows,
        ref.read(desktopWorkspaceProvider),
        ref.read(shellInteractionRegistryProvider),
      );
    });
  }

  void _publish(
    Size viewSize,
    List<HyprWindow> windows,
    DesktopWorkspaceState desktop,
    ShellInteractionSnapshot interactions,
  ) {
    if (viewSize.width <= 0.0 || viewSize.height <= 0.0) {
      return;
    }

    final windowsById = <int, HyprWindow>{
      for (final window in windows)
        if (window.isUserApp) window.objectId: window,
    };
    final switcher = ref.read(desktopWindowSwitcherProvider);
    final sampledSwitcherIds =
        interactions.capturesFullScene && (switcher?.isSelecting ?? false)
            ? switcher!.objectIds.toSet()
            : const <int>{};
    final placements = desktop.placements.values
        .where(
          (placement) =>
              (!placement.minimized ||
                  desktop.isInOverview(placement.objectId) ||
                  sampledSwitcherIds.contains(placement.objectId)) &&
              windowsById.containsKey(placement.objectId),
        )
        .toList(growable: false)
      ..sort((a, b) => compareDesktopWindowStack(a, b, windowsById));

    final canvas = Offset.zero & viewSize;
    var shellRegions = <Rect>[canvas];
    // Hover panels must not take pointer ownership of the whole scene. Changing
    // ownership while leaving a hot edge can synthesize another edge enter and
    // make the launcher repeatedly open and close over client windows.
    if (!interactions.capturesFullScene) {
      for (final placement in placements) {
        shellRegions = _subtractFromAll(shellRegions, placement.contentRect);
        final window = windowsById[placement.objectId]!;
        for (final popup in window.popupRoots) {
          shellRegions = _subtractFromAll(
            shellRegions,
            window.mapSurfaceRect(popup, placement.contentRect),
          );
        }
      }
    }
    for (final region in interactions.childRegions) {
      final clipped = region.intersect(canvas);
      if (!clipped.isEmpty) {
        shellRegions.add(clipped);
      }
    }

    final inputWindows = <InputWindowRegion>[];
    final visibleSurfaceIds = <int>{};
    final zStride = placements.fold<int>(2, (stride, placement) {
      final layers = windowsById[placement.objectId]!.surfaceLayers.length + 2;
      return math.max(stride, layers);
    });
    final placementOrder = <int, int>{
      for (var index = 0; index < placements.length; index += 1)
        placements[index].objectId: index,
    };
    // The wire hit tester consumes the first matching window. Build this list
    // in its final topmost-first order so the codec normally needs neither a
    // defensive copy nor another sort.
    for (final placement in placements.reversed) {
      if (interactions.capturesFullScene) {
        final window = windowsById[placement.objectId]!;
        visibleSurfaceIds.addAll(window.visibleSurfaceIds);
        _configureWindowSize(
          window,
          placement.contentRect,
          nativeDragActive: placement.dragging,
        );
        continue;
      }
      final window = windowsById[placement.objectId]!;
      visibleSurfaceIds.addAll(window.visibleSurfaceIds);
      final sourceRect = window.contentCoordinateRect;
      final baseZ = placementOrder[placement.objectId]! * zStride;
      final popupRoots = window.popupRoots.toList(growable: false).reversed;
      for (final popup in popupRoots) {
        inputWindows.add(
          InputWindowRegion(
            window: window,
            surfaceId: popup.surfaceId,
            rect: window.mapSurfaceRect(popup, placement.contentRect),
            sourceRect: Rect.fromLTWH(
              0.0,
              0.0,
              popup.surfaceWidth,
              popup.surfaceHeight,
            ),
            z: baseZ + popup.compositionOrder + 1,
            geometryLocked: placement.fullscreen,
          ),
        );
      }
      inputWindows.add(
        InputWindowRegion(
          window: window,
          // A logical window region routes through the complete toplevel
          // surface tree. The primary texture may be a full-window child and
          // is a rendering choice, not an input target.
          surfaceId: window.objectId,
          rect: placement.contentRect,
          sourceRect: sourceRect,
          z: baseZ,
          geometryLocked: placement.fullscreen,
        ),
      );
      _configureWindowSize(
        window,
        placement.contentRect,
        nativeDragActive: placement.dragging,
      );
    }

    _configuredSizes.removeWhere(
      (objectId, _) => !windowsById.containsKey(objectId),
    );
    final snapshot = InputLayoutSnapshot(
      epoch: _epoch + 1,
      shellRegions: shellRegions,
      windows: inputWindows,
      visibleSurfaceIds: visibleSurfaceIds.toList(growable: false),
      keyboardCapture: interactions.capturesKeyboard,
      exclusiveShellMode: interactions.compositorExclusive,
    );
    if (_lastSnapshot?.hasSameRoutingAs(snapshot) ?? false) {
      return;
    }

    if (!ref.read(denialBridgeProvider).publishInputLayout(snapshot)) {
      return;
    }
    _epoch = snapshot.epoch;
    _lastSnapshot = snapshot;
  }

  void _configureWindowSize(
    HyprWindow window,
    Rect contentRect, {
    required bool nativeDragActive,
  }) {
    final width = contentRect.width.round().clamp(64, 16384);
    final height = contentRect.height.round().clamp(64, 16384);
    final configuredSize = (width: width, height: height);
    if (!_configuredSizes.containsKey(window.objectId)) {
      // The native compositor owns initial placement and sizing. Seed the
      // cache from the geometry Flutter received instead of configuring a
      // newly discovered window back to the shell's copy of that geometry.
      _configuredSizes[window.objectId] = configuredSize;
      return;
    }
    if (nativeDragActive) {
      // Hypr is the sole geometry writer during a native move/resize grab.
      // Remember its latest size without echoing the same configure back.
      _configuredSizes[window.objectId] = configuredSize;
      return;
    }
    if (_configuredSizes[window.objectId] == configuredSize) {
      return;
    }
    _configuredSizes[window.objectId] = configuredSize;
    ref.read(denialBridgeProvider).configureWindow(
          window,
          Rect.fromLTWH(
            contentRect.left,
            contentRect.top,
            width.toDouble(),
            height.toDouble(),
          ),
        );
  }
}

List<Rect> _subtractFromAll(List<Rect> regions, Rect cut) {
  final result = <Rect>[];
  for (final region in regions) {
    result.addAll(_subtractRect(region, cut));
  }
  return result;
}

List<Rect> _subtractRect(Rect source, Rect cut) {
  final overlap = source.intersect(cut);
  if (overlap.isEmpty) {
    return <Rect>[source];
  }

  final result = <Rect>[];
  void add(Rect rect) {
    if (rect.width > 0.0 && rect.height > 0.0) {
      result.add(rect);
    }
  }

  add(Rect.fromLTRB(source.left, source.top, source.right, overlap.top));
  add(Rect.fromLTRB(source.left, overlap.bottom, source.right, source.bottom));
  add(Rect.fromLTRB(source.left, overlap.top, overlap.left, overlap.bottom));
  add(Rect.fromLTRB(overlap.right, overlap.top, source.right, overlap.bottom));
  return result;
}
