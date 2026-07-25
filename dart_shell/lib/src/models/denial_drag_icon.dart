import 'package:flutter/widgets.dart';

import 'denial_window.dart';

@immutable
class DenialDragIcon {
  const DenialDragIcon({
    required this.sequence,
    required this.surfaceId,
    required this.offset,
    required this.size,
    required this.layer,
  });

  final int sequence;
  final int surfaceId;
  final Offset offset;
  final Size size;
  final DenialSurfaceLayer layer;
}

@immutable
class DenialDragIconUpdate {
  const DenialDragIconUpdate({
    required this.sequence,
    required this.icon,
  });

  final int sequence;
  final DenialDragIcon? icon;
}
