import 'dart:collection';
import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;

import 'package:denial_flutter_sdk/models.dart';

/// The layer surfaces each window holds (denial-pet-v1), keyed by the holding
/// window's object id. Each list keeps the order of [layerSurfaces], which is
/// the layers' stacking order, back to front.
Map<int, List<DenialWindow>> desktopHeldLayersByWindow(
  Iterable<DenialWindow> layerSurfaces,
) {
  final held = <int, List<DenialWindow>>{};
  for (final surface in layerSurfaces) {
    if (surface.heldBy case final heldBy?) {
      (held[heldBy.windowId] ??= <DenialWindow>[]).add(surface);
    }
  }
  return UnmodifiableMapView<int, List<DenialWindow>>({
    for (final entry in held.entries)
      entry.key: List<DenialWindow>.unmodifiable(entry.value),
  });
}

/// Where [layer], a pet held by [window], is drawn and hit.
///
/// The hold point lies on the window's visible frame: its presentation
/// rectangle inflated by [frameMargins], in the window's unscaled coordinates
/// relative to that rectangle. An edge hold puts the point at the hold's share
/// of the edge from its left or top end; a corner hold at that corner. The
/// layer keeps its own geometry size and puts its [DenialPet.anchor] on the
/// hold point. The result is mapped onto [contentRect], where the window's
/// presentation rectangle is drawn, like [DenialWindow.mapSurfaceRect] maps
/// the window's popups, so it follows the window through drags, overview and
/// switcher scaling.
///
/// The compositor places the layer by the same rule. Returns null when
/// [layer] is not held, has no geometry, or either rectangle is empty.
Rect? desktopHeldLayerRect({
  required DenialWindow layer,
  required DenialWindow window,
  required Rect contentRect,
  required EdgeInsets frameMargins,
}) {
  final held = layer.heldBy;
  final pet = layer.pet;
  final geometry = layer.geometry;
  final source = window.presentationCoordinateRect;
  if (held == null ||
      pet == null ||
      geometry == null ||
      source.width <= 0.0 ||
      source.height <= 0.0 ||
      contentRect.width <= 0.0 ||
      contentRect.height <= 0.0) {
    return null;
  }
  final frame = Rect.fromLTRB(
    -frameMargins.left,
    -frameMargins.top,
    source.width + frameMargins.right,
    source.height + frameMargins.bottom,
  );
  final point = held.hold.pointOn(frame, held.share);
  final rect = Rect.fromLTWH(
    point.dx - pet.anchor.dx,
    point.dy - pet.anchor.dy,
    geometry.width,
    geometry.height,
  );
  final scaleX = contentRect.width / source.width;
  final scaleY = contentRect.height / source.height;
  return Rect.fromLTWH(
    contentRect.left + rect.left * scaleX,
    contentRect.top + rect.top * scaleY,
    rect.width * scaleX,
    rect.height * scaleY,
  );
}

/// [window]'s visible frame, which its held pets' hold points lie on: its
/// presentation rectangle inflated by [frameMargins], mapped onto
/// [contentRect] as [desktopHeldLayerRect] maps the pets. Returns null when
/// either rectangle is empty.
Rect? desktopHeldFrameRect({
  required DenialWindow window,
  required Rect contentRect,
  required EdgeInsets frameMargins,
}) {
  final source = window.presentationCoordinateRect;
  if (source.width <= 0.0 ||
      source.height <= 0.0 ||
      contentRect.width <= 0.0 ||
      contentRect.height <= 0.0) {
    return null;
  }
  final scaleX = contentRect.width / source.width;
  final scaleY = contentRect.height / source.height;
  return Rect.fromLTRB(
    contentRect.left - frameMargins.left * scaleX,
    contentRect.top - frameMargins.top * scaleY,
    contentRect.right + frameMargins.right * scaleX,
    contentRect.bottom + frameMargins.bottom * scaleY,
  );
}
