import 'package:flutter/foundation.dart';

import 'hypr_window.dart';

@immutable
class HyprWindowSnapshot {
  const HyprWindowSnapshot({
    required this.sequence,
    required this.windows,
  });

  final int sequence;
  final List<HyprWindow> windows;
}
