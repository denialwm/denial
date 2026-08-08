import 'package:flutter/foundation.dart';

import 'denial_window.dart';

@immutable
class DenialWindowSnapshot {
  const DenialWindowSnapshot({required this.sequence, required this.windows});

  final int sequence;
  final List<DenialWindow> windows;
}
