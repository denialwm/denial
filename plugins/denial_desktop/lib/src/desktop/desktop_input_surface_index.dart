import 'dart:collection';

import 'package:denial_flutter_sdk/models.dart';

import 'desktop_held_layers.dart';

/// Input-routing partitions of one immutable layer-surface snapshot.
/// Each partition retains the original order, which determines stacking.
///
/// A layer held by a window (denial-pet-v1) belongs to no layer partition:
/// it is hit with its window, at its window's z, from [held].
final class DesktopInputSurfaceIndex {
  factory DesktopInputSurfaceIndex(List<DenialWindow> source) {
    final positioned = <DenialWindow>[];
    final background = <DenialWindow>[];
    final foreground = <DenialWindow>[];
    final held = <DenialWindow>[];
    for (final surface in source) {
      if (surface.geometry == null) continue;
      if (surface.isHeld) {
        held.add(surface);
        continue;
      }
      positioned.add(surface);
      switch (surface.contentKind) {
        case DenialWindowContentKind.layerShellBackground ||
            DenialWindowContentKind.layerShellBottom:
          background.add(surface);
        case DenialWindowContentKind.layerShellTop ||
            DenialWindowContentKind.layerShellOverlay:
          foreground.add(surface);
        default:
          break;
      }
    }
    return DesktopInputSurfaceIndex._(
      source,
      UnmodifiableListView(positioned),
      UnmodifiableListView(background),
      UnmodifiableListView(foreground),
      desktopHeldLayersByWindow(held),
    );
  }

  const DesktopInputSurfaceIndex._(
    this.source,
    this.positioned,
    this.background,
    this.foreground,
    this.held,
  );

  final List<DenialWindow> source;

  /// Layers placed at their own geometry, in their layer planes.
  final List<DenialWindow> positioned;
  final List<DenialWindow> background;
  final List<DenialWindow> foreground;

  /// Held layers keyed by the object id of the window that holds them.
  final Map<int, List<DenialWindow>> held;
}
