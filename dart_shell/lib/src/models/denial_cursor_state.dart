import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'denial_window.dart';

enum DenialCursorStateKind { hidden, named, surface }

@immutable
class DenialCursorState {
  const DenialCursorState({
    required this.epoch,
    required this.kind,
    this.shape = '',
    this.hotspot = Offset.zero,
    this.surfaceLayers = const <DenialSurfaceLayer>[],
  });

  final int epoch;
  final DenialCursorStateKind kind;
  final String shape;
  final Offset hotspot;
  final List<DenialSurfaceLayer> surfaceLayers;

  bool get hasSurfaceArtwork =>
      kind == DenialCursorStateKind.surface &&
      surfaceLayers.any((layer) => layer.textureId > 0);

  @override
  bool operator ==(Object other) {
    return other is DenialCursorState &&
        other.epoch == epoch &&
        other.kind == kind &&
        other.shape == shape &&
        other.hotspot == hotspot &&
        listEquals(other.surfaceLayers, surfaceLayers);
  }

  @override
  int get hashCode =>
      Object.hash(epoch, kind, shape, hotspot, Object.hashAll(surfaceLayers));
}
