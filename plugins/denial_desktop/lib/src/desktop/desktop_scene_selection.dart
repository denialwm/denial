import 'package:denial_flutter_sdk/models.dart';
import 'package:flutter/foundation.dart';

import 'desktop_workspace.dart';

class DesktopSceneWindows {
  // Structural scene invalidation deliberately excludes window titles. During
  // a native grab it also excludes live buffer geometry for the grabbed
  // windows. Each keyed frame and popup layer selects its own current window.
  DesktopSceneWindows(
    List<DenialWindow> windows,
    Set<int> livePlacementObjectIds,
  ) : windows = List<DenialWindow>.unmodifiable(
        windows.where((window) => window.isUserApp || window.isPopupSurface),
      ),
      livePlacementObjectIds = Set.unmodifiable(livePlacementObjectIds);

  final List<DenialWindow> windows;
  final Set<int> livePlacementObjectIds;

  @override
  bool operator ==(Object other) {
    if (other is! DesktopSceneWindows ||
        !setEquals(other.livePlacementObjectIds, livePlacementObjectIds) ||
        other.windows.length != windows.length) {
      return false;
    }
    for (var index = 0; index < windows.length; index += 1) {
      final window = windows[index];
      final otherWindow = other.windows[index];
      final livePlacement =
          livePlacementObjectIds.contains(window.objectId) &&
          other.livePlacementObjectIds.contains(otherWindow.objectId);
      if (livePlacement
          ? !window.hasSameStaticSceneRoleAs(otherWindow)
          : !window.hasSameSceneDescriptionAs(otherWindow)) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => runtimeType.hashCode;
}

class DesktopSceneLayerSurfaces {
  // A layer held by a window (denial-pet-v1) is drawn by that window's keyed
  // held-layer slot, which selects the layer's current geometry and textures
  // itself. Only which window holds it, and on which side, changes the scene
  // structure, so moving a window with a held layer stays a keyed update.
  const DesktopSceneLayerSurfaces(this.layerSurfaces);

  final List<DenialWindow> layerSurfaces;

  @override
  bool operator ==(Object other) {
    if (other is! DesktopSceneLayerSurfaces) return false;
    if (identical(other.layerSurfaces, layerSurfaces)) return true;
    if (other.layerSurfaces.length != layerSurfaces.length) return false;
    for (var index = 0; index < layerSurfaces.length; index += 1) {
      final surface = layerSurfaces[index];
      final otherSurface = other.layerSurfaces[index];
      if (surface.isHeld && otherSurface.isHeld
          ? !surface.hasSameStaticSceneRoleAs(otherSurface)
          : surface != otherSurface) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => runtimeType.hashCode;
}

class DesktopSceneWorkspace {
  const DesktopSceneWorkspace(this.state);

  final DesktopWorkspaceState state;

  @override
  bool operator ==(Object other) {
    return other is DesktopSceneWorkspace &&
        desktopWorkspaceHasSameSceneStructure(state, other.state);
  }

  @override
  int get hashCode => Object.hash(
    state.nextZ,
    state.viewSize,
    identityHashCode(state.overview),
    state.placements.length,
  );
}
