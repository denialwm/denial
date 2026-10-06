import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/input_layout.dart';
import '../input/shell_interaction_registry.dart';
import '../models/display_layout.dart';
import '../models/denial_window.dart';
import '../state/desktop_window_switcher.dart';
import '../state/shell_controller.dart';
import '../state/display_layout.dart';
import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import 'desktop_workspace.dart';

class DesktopInputLayoutPublisher extends ConsumerStatefulWidget {
  const DesktopInputLayoutPublisher({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DesktopInputLayoutPublisher> createState() =>
      _DesktopInputLayoutPublisherState();
}

class _DesktopInputLayoutPublisherState
    extends ConsumerState<DesktopInputLayoutPublisher> {
  final DesktopWindowConfigureTracker _configureTracker =
      DesktopWindowConfigureTracker();
  bool _scheduled = false;
  int _epoch = 0;
  InputLayoutSnapshot? _lastSnapshot;
  _DesktopInputLayoutSource? _lastSource;

  @override
  Widget build(BuildContext context) {
    ref.watch(
      shellControllerProvider.select(
        (state) =>
            (state.windows, state.layerSurfaces, state.windowSnapshotSequence),
      ),
    );
    ref.watch(
      desktopWorkspaceProvider.select((state) => state.inputLayoutRevision),
    );
    ref.watch(desktopWindowSwitcherProvider);
    ref.watch(
      shellSettingsProvider.select(
        (settings) => (
          settings.layout.workspacesEnabled,
          settings.layout.workspaceCount,
          settings.layout.windowLayout,
        ),
      ),
    );
    ref.watch(displayLayoutProvider);
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
      final settings = ref.read(shellSettingsProvider).layout;
      final displayLayout = ref.read(displayLayoutProvider);
      ref
          .read(desktopWorkspaceProvider.notifier)
          .syncWorkspaceConfiguration(
            enabled: settings.workspacesEnabled,
            count: settings.workspaceCount,
            authoritativeActiveWorkspaces: <int, int>{
              for (final output
                  in displayLayout?.outputs ?? const <DisplayOutput>[])
                output.monitorId: output.activeWorkspace,
            },
            monitorIds:
                displayLayout?.outputs.map((output) => output.monitorId) ??
                windows
                    .where((window) => window.monitorId >= 0)
                    .map((window) => window.monitorId),
          );
      ref
          .read(desktopWorkspaceProvider.notifier)
          .syncWindows(
            windows,
            viewSize,
            devicePixelRatio,
            snapshotSequence: shell.windowSnapshotSequence,
            windowLayout: settings.windowLayout,
          );
      final source = _DesktopInputLayoutSource(
        viewSize: viewSize,
        devicePixelRatio: devicePixelRatio,
        windows: shell.windows,
        layerSurfaces: shell.layerSurfaces,
        windowSnapshotSequence: shell.windowSnapshotSequence,
        desktop: ref.read(desktopWorkspaceProvider),
        switcher: ref.read(desktopWindowSwitcherProvider),
        interactions: ref.read(shellInteractionRegistryProvider),
        displayLayout: displayLayout,
        windowLayout: settings.windowLayout,
      );
      if (_lastSource?.hasSameInputsAs(source) ?? false) {
        return;
      }
      if (_publish(source)) {
        _lastSource = source;
      }
    });
  }

  bool _publish(_DesktopInputLayoutSource source) {
    final viewSize = source.viewSize;
    if (viewSize.width <= 0.0 || viewSize.height <= 0.0) {
      return false;
    }
    final windows = source.windows;
    final layerSurfaces = source.layerSurfaces
        .where((surface) => surface.geometry != null)
        .toList(growable: false);
    final backgroundLayerSurfaces = layerSurfaces
        .where(
          (surface) =>
              surface.contentKind ==
                  DenialWindowContentKind.layerShellBackground ||
              surface.contentKind == DenialWindowContentKind.layerShellBottom,
        )
        .toList(growable: false);
    final foregroundLayerSurfaces = layerSurfaces
        .where(
          (surface) =>
              surface.contentKind == DenialWindowContentKind.layerShellTop ||
              surface.contentKind == DenialWindowContentKind.layerShellOverlay,
        )
        .toList(growable: false);
    final desktop = source.desktop;
    final interactions = source.interactions;

    final windowsById = <int, DenialWindow>{
      for (final window in windows)
        if (window.isUserApp) window.objectId: window,
    };
    final popupSurfaces = windows
        .where((window) => window.isPopupSurface && window.geometry != null)
        .toList(growable: false);
    final switcher = source.switcher;
    final sampledSwitcherIds =
        interactions.capturesFullScene && (switcher?.isSelecting ?? false)
        ? switcher!.objectIds.toSet()
        : const <int>{};
    final placements =
        desktop.placements.values
            .where(
              (placement) =>
                  (!placement.minimized ||
                      desktop.isInOverview(placement.objectId) ||
                      sampledSwitcherIds.contains(placement.objectId)) &&
                  (desktop.isPlacementOnActiveWorkspace(placement) ||
                      desktop.isInOverview(placement.objectId)) &&
                  windowsById.containsKey(placement.objectId),
            )
            .toList(growable: false)
          ..sort((a, b) => compareDesktopWindowStack(a, b, windowsById));

    final canvas = Offset.zero & viewSize;
    final outputRects = <int, Rect>{
      for (final output
          in source.displayLayout?.outputs ?? const <DisplayOutput>[])
        output.monitorId: output.logicalRect,
    };
    Rect? outputClipFor(DesktopWindowPlacement placement) {
      return desktopOutputClip(
        activelyDragging: placement.dragging,
        outputRect: outputRects[placement.monitorId],
      );
    }

    var shellRegions = <Rect>[canvas];
    void subtractSurfaceTree(DenialWindow surface) {
      final geometry = surface.geometry!;
      shellRegions = _subtractFromAll(shellRegions, geometry);
      for (final popup in surface.popupRoots) {
        final popupRect = surface.mapSurfaceRect(popup, geometry);
        if (!popupRect.isEmpty) {
          shellRegions = _subtractFromAll(shellRegions, popupRect);
        }
      }
    }

    // Hover panels must not take pointer ownership of the whole scene. Changing
    // ownership while leaving a hot edge can synthesize another edge enter and
    // make the launcher repeatedly open and close over client windows.
    if (!interactions.capturesFullScene) {
      for (final popup in popupSurfaces) {
        shellRegions = _subtractFromAll(shellRegions, popup.geometry!);
      }
      for (final surface in backgroundLayerSurfaces) {
        subtractSurfaceTree(surface);
      }
      for (final placement in placements) {
        final visualContentRect = placement.contentRect;
        final outputClip = outputClipFor(placement);
        final visibleContentRect = outputClip == null
            ? visualContentRect
            : visualContentRect.intersect(outputClip);
        if (!visibleContentRect.isEmpty) {
          shellRegions = _subtractFromAll(shellRegions, visibleContentRect);
        }
        final window = windowsById[placement.objectId]!;
        for (final popup in window.popupRoots) {
          final popupRect = window.mapSurfaceRect(popup, visualContentRect);
          final visiblePopupRect = outputClip == null
              ? popupRect
              : popupRect.intersect(outputClip);
          if (!visiblePopupRect.isEmpty) {
            shellRegions = _subtractFromAll(shellRegions, visiblePopupRect);
          }
        }
      }
    }
    for (final region in interactions.childRegions) {
      final clipped = region.intersect(canvas);
      if (!clipped.isEmpty) {
        shellRegions.add(clipped);
      }
    }
    if (!interactions.capturesFullScene) {
      // Top and overlay layer surfaces are painted above Flutter's normal
      // desktop controls, so they also outrank child shell hit regions.
      for (final surface in foregroundLayerSurfaces) {
        subtractSurfaceTree(surface);
      }
    }

    final inputWindows = <InputWindowRegion>[];
    final visibleSurfaceIds = <int>{};
    for (final surface in layerSurfaces) {
      visibleSurfaceIds.addAll(surface.visibleSurfaceIds);
    }

    inputWindows.addAll(
      desktopLayerInputRegions(
        foregroundLayerSurfaces,
        zBand: 2000000000,
        enabled: !interactions.capturesFullScene,
      ),
    );
    for (final popup in popupSurfaces) {
      visibleSurfaceIds.addAll(popup.visibleSurfaceIds);
      if (!interactions.capturesFullScene) {
        inputWindows.add(
          InputWindowRegion(
            window: popup,
            surfaceId: popup.objectId,
            rect: popup.geometry!,
            sourceRect: popup.contentCoordinateRect,
            z: 1000000000,
            geometryLocked: true,
          ),
        );
      }
    }
    // Desktop widgets still sample their live main-surface textures. Keep
    // those surfaces presentation-visible without adding a client input
    // region or configuring the native window to the widget rectangle.
    for (final placement in desktop.placements.values) {
      if (!placement.minimized) {
        continue;
      }
      final window = windowsById[placement.objectId];
      if (window == null) {
        continue;
      }
      visibleSurfaceIds.addAll(window.mainVisibleSurfaceIds);
    }
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
        _configureWindowGeometry(
          window,
          placement.contentRect,
          nativeDragActive: placement.dragging,
        );
        continue;
      }
      final window = windowsById[placement.objectId]!;
      visibleSurfaceIds.addAll(window.visibleSurfaceIds);
      final visualContentRect = placement.contentRect;
      final sourceRect = window.contentCoordinateRect;
      final outputClip = outputClipFor(placement);
      final baseZ = placementOrder[placement.objectId]! * zStride;
      final popupRoots = window.popupRoots.toList(growable: false).reversed;
      for (final popup in popupRoots) {
        final popupRect = window.mapSurfaceRect(popup, visualContentRect);
        final popupGeometry = outputClip == null
            ? (
                rect: popupRect,
                sourceRect: Rect.fromLTWH(
                  0.0,
                  0.0,
                  popup.surfaceWidth,
                  popup.surfaceHeight,
                ),
              )
            : desktopClipInputGeometryToRect(
                rect: popupRect,
                sourceRect: Rect.fromLTWH(
                  0.0,
                  0.0,
                  popup.surfaceWidth,
                  popup.surfaceHeight,
                ),
                clipRect: outputClip,
              );
        if (popupGeometry == null) {
          continue;
        }
        inputWindows.add(
          InputWindowRegion(
            window: window,
            surfaceId: popup.surfaceId,
            rect: popupGeometry.rect,
            sourceRect: popupGeometry.sourceRect,
            z: baseZ + popup.compositionOrder + 1,
            geometryLocked: placement.fullscreen,
          ),
        );
      }
      final contentGeometry = outputClip == null
          ? (rect: visualContentRect, sourceRect: sourceRect)
          : desktopClipInputGeometryToRect(
              rect: visualContentRect,
              sourceRect: sourceRect,
              clipRect: outputClip,
            );
      if (contentGeometry != null) {
        inputWindows.add(
          InputWindowRegion(
            window: window,
            // A logical window region routes through the complete toplevel
            // surface tree. The primary texture may be a full-window child and
            // is a rendering choice, not an input target.
            surfaceId: window.objectId,
            rect: contentGeometry.rect,
            sourceRect: contentGeometry.sourceRect,
            z: baseZ,
            geometryLocked: placement.fullscreen,
          ),
        );
      }
      _configureWindowGeometry(
        window,
        placement.contentRect,
        nativeDragActive: placement.dragging,
      );
    }
    inputWindows.addAll(
      desktopLayerInputRegions(
        backgroundLayerSurfaces,
        zBand: -1000000000,
        enabled: !interactions.capturesFullScene,
      ),
    );

    _configureTracker.retainWindowIds(windowsById.keys.toSet());
    final snapshot = InputLayoutSnapshot(
      epoch: _epoch + 1,
      shellRegions: shellRegions,
      windows: inputWindows,
      visibleSurfaceIds: visibleSurfaceIds.toList(growable: false),
      keyboardCapture: interactions.capturesKeyboard,
      exclusiveShellMode: interactions.compositorExclusive,
      observeClientPointerPresses: interactions.observesClientPointerPresses,
    );
    if (_lastSnapshot?.hasSameRoutingAs(snapshot) ?? false) {
      return true;
    }

    if (!ref.read(denialBridgeProvider).publishInputLayout(snapshot)) {
      return false;
    }
    _epoch = snapshot.epoch;
    _lastSnapshot = snapshot;
    return true;
  }

  void _configureWindowGeometry(
    DenialWindow window,
    Rect contentRect, {
    required bool nativeDragActive,
  }) {
    final configuredGeometry = _configureTracker.update(
      window.objectId,
      contentRect,
      nativeDragActive: nativeDragActive,
    );
    if (configuredGeometry == null) {
      return;
    }
    ref.read(denialBridgeProvider).configureWindow(window, configuredGeometry);
  }
}

List<InputWindowRegion> desktopLayerInputRegions(
  List<DenialWindow> surfaces, {
  required int zBand,
  bool enabled = true,
}) {
  if (!enabled) {
    return const <InputWindowRegion>[];
  }
  final regions = <InputWindowRegion>[];
  var nextZ =
      zBand +
      surfaces.fold<int>(0, (count, surface) {
        return count + surface.popupRoots.length + 1;
      });
  for (var index = surfaces.length - 1; index >= 0; index -= 1) {
    final surface = surfaces[index];
    final geometry = surface.geometry;
    if (geometry == null) {
      continue;
    }
    for (final popup in surface.popupRoots.toList().reversed) {
      final popupRect = surface.mapSurfaceRect(popup, geometry);
      if (popupRect.isEmpty) {
        continue;
      }
      regions.add(
        InputWindowRegion(
          window: surface,
          surfaceId: popup.surfaceId,
          rect: popupRect,
          sourceRect: Rect.fromLTWH(
            0.0,
            0.0,
            popup.surfaceWidth,
            popup.surfaceHeight,
          ),
          z: nextZ--,
          geometryLocked: true,
        ),
      );
    }
    regions.add(
      InputWindowRegion(
        window: surface,
        surfaceId: surface.objectId,
        rect: geometry,
        sourceRect: surface.contentCoordinateRect,
        z: nextZ--,
        geometryLocked: true,
      ),
    );
  }
  return regions;
}

class _DesktopInputLayoutSource {
  const _DesktopInputLayoutSource({
    required this.viewSize,
    required this.devicePixelRatio,
    required this.windows,
    required this.layerSurfaces,
    required this.windowSnapshotSequence,
    required this.desktop,
    required this.switcher,
    required this.interactions,
    required this.displayLayout,
    required this.windowLayout,
  });

  final Size viewSize;
  final double devicePixelRatio;
  final List<DenialWindow> windows;
  final List<DenialWindow> layerSurfaces;
  final int windowSnapshotSequence;
  final DesktopWorkspaceState desktop;
  final DesktopWindowSwitcherState? switcher;
  final ShellInteractionSnapshot interactions;
  final DisplayLayout? displayLayout;
  final DesktopWindowLayout windowLayout;

  bool hasSameInputsAs(_DesktopInputLayoutSource other) {
    return viewSize == other.viewSize &&
        devicePixelRatio == other.devicePixelRatio &&
        identical(windows, other.windows) &&
        identical(layerSurfaces, other.layerSurfaces) &&
        windowSnapshotSequence == other.windowSnapshotSequence &&
        desktop.inputLayoutRevision == other.desktop.inputLayoutRevision &&
        identical(switcher, other.switcher) &&
        identical(interactions, other.interactions) &&
        identical(displayLayout, other.displayLayout) &&
        windowLayout == other.windowLayout;
  }
}

({Rect rect, Rect sourceRect})? desktopClipInputGeometryToRect({
  required Rect rect,
  required Rect sourceRect,
  required Rect clipRect,
}) {
  final clipped = rect.intersect(clipRect);
  if (clipped.isEmpty || rect.isEmpty || sourceRect.isEmpty) {
    return null;
  }
  final scaleX = sourceRect.width / rect.width;
  final scaleY = sourceRect.height / rect.height;
  return (
    rect: clipped,
    sourceRect: Rect.fromLTRB(
      sourceRect.left + (clipped.left - rect.left) * scaleX,
      sourceRect.top + (clipped.top - rect.top) * scaleY,
      sourceRect.right - (rect.right - clipped.right) * scaleX,
      sourceRect.bottom - (rect.bottom - clipped.bottom) * scaleY,
    ),
  );
}

/// Tracks complete shell-authored window rectangles crossing the native
/// bridge. Location is part of the identity: dropping a position-only update
/// leaves Rust hit testing and Flutter composition on different coordinates.
class DesktopWindowConfigureTracker {
  final Map<int, ({int left, int top, int width, int height})> _configured =
      <int, ({int left, int top, int width, int height})>{};

  Rect? update(
    int objectId,
    Rect contentRect, {
    required bool nativeDragActive,
  }) {
    final geometry = (
      left: contentRect.left.round().clamp(0, 16384),
      top: contentRect.top.round().clamp(0, 16384),
      width: contentRect.width.round().clamp(64, 16384),
      height: contentRect.height.round().clamp(64, 16384),
    );
    final previous = _configured[objectId];
    _configured[objectId] = geometry;
    if (previous == null) {
      // The native compositor owns initial placement and sizing. Seed from
      // the received geometry instead of echoing a newly discovered window.
      return null;
    }
    if (nativeDragActive) {
      // Rust is the sole writer during a native move/resize grab.
      return null;
    }
    if (previous == geometry) {
      return null;
    }
    return Rect.fromLTWH(
      geometry.left.toDouble(),
      geometry.top.toDouble(),
      geometry.width.toDouble(),
      geometry.height.toDouble(),
    );
  }

  void retainWindowIds(Set<int> activeObjectIds) {
    _configured.removeWhere(
      (objectId, _) => !activeObjectIds.contains(objectId),
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
