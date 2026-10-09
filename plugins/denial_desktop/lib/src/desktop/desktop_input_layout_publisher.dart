import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/models.dart';

import '../state/desktop_window_switcher.dart';
import '../state/desktop_visibility.dart';

import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/settings.dart';

import 'desktop_workspace.dart';
import 'desktop_held_layers.dart';
import 'desktop_input_surface_index.dart';

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
  DesktopInputSurfaceIndex? _surfaceIndex;
  Map<int, DenialWindow>? _configuredAppWindows;

  @override
  Widget build(BuildContext context) {
    ref.watch(
      referenceShellProvider.select(
        (state) =>
            (state.windows, state.layerSurfaces, state.windowSnapshotSequence),
      ),
    );
    ref.watch(
      desktopWorkspaceProvider.select((state) => state.inputLayoutRevision),
    );
    ref.watch(desktopWindowSwitcherProvider);
    ref.watch(desktopVisibleProvider);
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

      final shell = ref.read(referenceShellProvider);
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
        desktopVisible: ref.read(desktopVisibleProvider),
        viewSize: viewSize,
        devicePixelRatio: devicePixelRatio,
        windows: shell.windows,
        windowsById: shell.openAppWindowsByObjectId,
        popupSurfaces: shell.positionedPopupSurfaces,
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
    if (!identical(_surfaceIndex?.source, source.layerSurfaces)) {
      _surfaceIndex = DesktopInputSurfaceIndex(source.layerSurfaces);
    }
    final layerSurfaces = _surfaceIndex!.positioned;
    final backgroundLayerSurfaces = _surfaceIndex!.background;
    final foregroundLayerSurfaces = _surfaceIndex!.foreground;
    final heldLayerSurfaces = _surfaceIndex!.held;
    final desktop = source.desktop;
    final interactions = source.interactions;

    final windowsById = source.windowsById;
    final popupSurfaces = source.desktopVisible
        ? const <DenialWindow>[]
        : source.popupSurfaces;
    final switcher = source.switcher;
    final samplesSwitcher =
        interactions.capturesFullScene && (switcher?.isSelecting ?? false);
    final placements =
        desktop.placements.values
            .where(
              (placement) =>
                  !source.desktopVisible &&
                  (!placement.minimized ||
                      desktop.isInOverview(placement.objectId) ||
                      (samplesSwitcher &&
                          switcher!.contains(placement.objectId))) &&
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
        for (final layer
            in heldLayerSurfaces[placement.objectId] ??
                const <DenialWindow>[]) {
          final heldRect = desktopHeldLayerRect(
            layer: layer,
            window: window,
            contentRect: visualContentRect,
            frameBorder: placement.frameBorder,
          );
          if (heldRect == null) {
            continue;
          }
          for (final rect in <Rect>[
            heldRect,
            for (final popup in layer.popupRoots)
              layer.mapSurfaceRect(popup, heldRect),
          ]) {
            final visibleRect = outputClip == null
                ? rect
                : rect.intersect(outputClip);
            if (!visibleRect.isEmpty) {
              shellRegions = _subtractFromAll(shellRegions, visibleRect);
            }
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
    if (source.desktopVisible) {
      // Taskbar previews can still sample these live textures. No client input
      // regions or geometry changes are published for the hidden windows.
      for (final window in windowsById.values) {
        visibleSurfaceIds.addAll(window.mainVisibleSurfaceIds);
      }
    }
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
    // Each window owns one z block of zStride values. From the bottom up it
    // holds the regions of the pets it holds below itself (one per popup and
    // one per root), its main region, the regions of the pets it holds above
    // itself, and a value per surface layer for its popups: the order its
    // frame draws them in.
    final zStride = placements.fold<int>(2, (stride, placement) {
      final held =
          heldLayerSurfaces[placement.objectId] ?? const <DenialWindow>[];
      final block =
          _heldLayerRegionCount(held, below: true) +
          windowsById[placement.objectId]!.surfaceLayers.length +
          2 +
          _heldLayerRegionCount(held, below: false);
      return math.max(stride, block);
    });
    // The wire hit tester consumes the first matching window. Build this list
    // in its final topmost-first order so the codec normally needs neither a
    // defensive copy nor another sort.
    for (var index = placements.length - 1; index >= 0; index--) {
      final placement = placements[index];
      final held =
          heldLayerSurfaces[placement.objectId] ?? const <DenialWindow>[];
      if (interactions.capturesFullScene) {
        final window = windowsById[placement.objectId]!;
        visibleSurfaceIds.addAll(window.visibleSurfaceIds);
        for (final layer in held) {
          visibleSurfaceIds.addAll(layer.visibleSurfaceIds);
        }
        _configureWindowGeometry(
          window,
          placement.contentRect,
          nativeDragActive: placement.dragging,
        );
        continue;
      }
      final window = windowsById[placement.objectId]!;
      visibleSurfaceIds.addAll(window.visibleSurfaceIds);
      for (final layer in held) {
        visibleSurfaceIds.addAll(layer.visibleSurfaceIds);
      }
      final visualContentRect = placement.contentRect;
      final sourceRect = window.contentCoordinateRect;
      final outputClip = outputClipFor(placement);
      final baseZ = index * zStride;
      final mainZ = baseZ + _heldLayerRegionCount(held, below: true);
      final popupZ = mainZ + _heldLayerRegionCount(held, below: false);
      Rect? heldLayerRect(DenialWindow layer) => desktopHeldLayerRect(
        layer: layer,
        window: window,
        contentRect: visualContentRect,
        frameBorder: placement.frameBorder,
      );
      // Held pets are hit like layer surfaces, but at their window's place
      // and clipped like its regions.
      inputWindows.addAll(
        desktopLayerInputRegions(
          [
            for (final layer in held)
              if (!(layer.pet?.below ?? false)) layer,
          ],
          zBand: mainZ,
          rectOf: heldLayerRect,
          clipRect: outputClip,
        ),
      );
      final popupRoots = window.popupRootsFrontToBack;
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
            z: popupZ + popup.compositionOrder + 1,
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
            z: mainZ,
            geometryLocked: placement.fullscreen,
          ),
        );
      }
      inputWindows.addAll(
        desktopLayerInputRegions(
          [
            for (final layer in held)
              if (layer.pet?.below ?? false) layer,
          ],
          zBand: baseZ - 1,
          rectOf: heldLayerRect,
          clipRect: outputClip,
        ),
      );
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

    if (!identical(windowsById, _configuredAppWindows)) {
      _configureTracker.retainWindowIds(windowsById.keys.toSet());
      _configuredAppWindows = windowsById;
    }
    final snapshot = InputLayoutSnapshot(
      epoch: _epoch + 1,
      shellRegions: shellRegions,
      windows: inputWindows,
      visibleSurfaceIds: visibleSurfaceIds.toList(growable: false),
      keyboardCapture: source.desktopVisible || interactions.capturesKeyboard,
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

/// Topmost-first input regions of layer surfaces and their popups, with
/// unique z values just above [zBand]: one per popup and one per root.
///
/// A layer is placed at its own geometry unless [rectOf] gives its rectangle,
/// as for a layer held by a window; a null rectangle leaves the layer out.
/// [clipRect] clips every region, mapping its source rectangle to match.
List<InputWindowRegion> desktopLayerInputRegions(
  List<DenialWindow> surfaces, {
  required int zBand,
  bool enabled = true,
  Rect? Function(DenialWindow surface)? rectOf,
  Rect? clipRect,
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
  ({Rect rect, Rect sourceRect})? clipped(Rect rect, Rect sourceRect) =>
      clipRect == null
      ? (rect: rect, sourceRect: sourceRect)
      : desktopClipInputGeometryToRect(
          rect: rect,
          sourceRect: sourceRect,
          clipRect: clipRect,
        );
  for (var index = surfaces.length - 1; index >= 0; index -= 1) {
    final surface = surfaces[index];
    final geometry = rectOf == null ? surface.geometry : rectOf(surface);
    if (geometry == null) {
      continue;
    }
    for (final popup in surface.popupRootsFrontToBack) {
      final popupRect = surface.mapSurfaceRect(popup, geometry);
      if (popupRect.isEmpty) {
        continue;
      }
      final popupGeometry = clipped(
        popupRect,
        Rect.fromLTWH(0.0, 0.0, popup.surfaceWidth, popup.surfaceHeight),
      );
      if (popupGeometry == null) {
        continue;
      }
      regions.add(
        InputWindowRegion(
          window: surface,
          surfaceId: popup.surfaceId,
          rect: popupGeometry.rect,
          sourceRect: popupGeometry.sourceRect,
          z: nextZ--,
          geometryLocked: true,
        ),
      );
    }
    final rootGeometry = clipped(geometry, surface.contentCoordinateRect);
    if (rootGeometry == null) {
      continue;
    }
    regions.add(
      InputWindowRegion(
        window: surface,
        surfaceId: surface.objectId,
        rect: rootGeometry.rect,
        sourceRect: rootGeometry.sourceRect,
        z: nextZ--,
        geometryLocked: true,
      ),
    );
  }
  return regions;
}

/// The z values [desktopLayerInputRegions] takes for the layers of [held]
/// that a window holds on the side [below].
int _heldLayerRegionCount(List<DenialWindow> held, {required bool below}) =>
    held.fold<int>(
      0,
      (count, layer) => (layer.pet?.below ?? false) == below
          ? count + layer.popupRoots.length + 1
          : count,
    );

class _DesktopInputLayoutSource {
  const _DesktopInputLayoutSource({
    required this.desktopVisible,
    required this.viewSize,
    required this.devicePixelRatio,
    required this.windows,
    required this.windowsById,
    required this.popupSurfaces,
    required this.layerSurfaces,
    required this.windowSnapshotSequence,
    required this.desktop,
    required this.switcher,
    required this.interactions,
    required this.displayLayout,
    required this.windowLayout,
  });

  final Size viewSize;
  final bool desktopVisible;
  final double devicePixelRatio;
  final List<DenialWindow> windows;
  final Map<int, DenialWindow> windowsById;
  final List<DenialWindow> popupSurfaces;
  final List<DenialWindow> layerSurfaces;
  final int windowSnapshotSequence;
  final DesktopWorkspaceState desktop;
  final DesktopWindowSwitcherState? switcher;
  final ShellInteractionSnapshot interactions;
  final DisplayLayout? displayLayout;
  final DesktopWindowLayout windowLayout;

  bool hasSameInputsAs(_DesktopInputLayoutSource other) {
    return desktopVisible == other.desktopVisible &&
        viewSize == other.viewSize &&
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
  void add(Rect rect) {
    if (rect.width > 0.0 && rect.height > 0.0) {
      result.add(rect);
    }
  }

  // Append fragments directly instead of allocating a list for every source
  // rectangle, most of which often do not intersect this window at all.
  for (final source in regions) {
    final overlap = source.intersect(cut);
    if (overlap.isEmpty) {
      result.add(source);
      continue;
    }
    add(Rect.fromLTRB(source.left, source.top, source.right, overlap.top));
    add(
      Rect.fromLTRB(source.left, overlap.bottom, source.right, source.bottom),
    );
    add(Rect.fromLTRB(source.left, overlap.top, overlap.left, overlap.bottom));
    add(
      Rect.fromLTRB(overlap.right, overlap.top, source.right, overlap.bottom),
    );
  }
  return result;
}
