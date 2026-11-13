import '../models/denial_window.dart';

/// The window in front once the one in front, [closed], is gone from
/// [windows]: as when a dialog closes on Android, the open window it opened
/// over, or that window's own parent. Null when none is left.
DenialWindow? frontAfterClose(
  DenialWindow? closed,
  List<DenialWindow> windows,
) {
  final byObjectId = {for (final window in windows) window.objectId: window};
  var parent = closed?.transientParentObjectId;
  // Parents form a tree; the bound only guards a broken one.
  for (var depth = 0; parent != null && depth < 16; depth++) {
    final window = byObjectId[parent];
    if (window == null) return null;
    if (window.isUserApp && !window.minimized) return window;
    parent = window.transientParentObjectId;
  }
  return null;
}
