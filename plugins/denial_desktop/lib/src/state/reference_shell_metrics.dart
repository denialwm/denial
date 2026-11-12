import 'package:flutter/widgets.dart';

class ReferenceShellMetrics {
  const ReferenceShellMetrics._();

  static const double gestureHitWidth = 176.0;
  static const double gestureHitHeight = 60.0;
  static const double gestureBottomInset = -8.0;

  /// Upward drag over which the home pill rises to its full lift.
  static const double gesturePillLiftTravel = 280.0;
  static const double edgePanelGestureWidth = 220.0;
  static const double edgePanelGestureHeight = 28.0;

  /// From the view's bottom edge to the middle of the home pill, whose line
  /// the keyboard's pill shares.
  static const double gesturePillCentre = 12.0;

  /// The keyboard's suggestion strip, on top of the keys.
  static const double oskSuggestionStripHeight = 64.0;
  static const double edgePanelKeysMaxHeight = 338.0;

  /// The row of shortcut keys a portrait keyboard can show above its keys,
  /// with the gap under it.
  static const double oskShortcutRowExtent = 52.0;
  static const double edgePanelMaxHeight =
      edgePanelKeysMaxHeight + oskSuggestionStripHeight;
  static const double edgePanelOpenDistance = 86.0;
  static const double edgePanelDragDistance = edgePanelMaxHeight;
  static const double edgePanelScrollStripWidth = 18.0;
  static const double edgePanelScrollMultiplier = 1.15;

  /// Visual gutter between the outgoing and incoming windows during a
  /// horizontal app switch. The switch animation must travel `width + this`
  /// so the incoming window lands exactly centred.
  static const double appSwitchGap = 18.0;
  static const double statusBarHeight = 48.0;

  static const double statusDragHeight = statusBarHeight;
  static const double quickSettingsPanelHeight = 488.0;
  static const double quickSettingsDragDistance = quickSettingsPanelHeight;

  /// ColorOS-style split shades occupy the complete output while their
  /// internal controls and notification list keep their own safe-area insets.
  static double quickSettingsPanelExtent(Size viewSize) =>
      viewSize.height.clamp(1.0, double.infinity).toDouble();

  static double quickSettingsDragScale(Size viewSize) =>
      quickSettingsDragDistance / quickSettingsPanelExtent(viewSize);

  static Rect gestureRect(Size viewSize) {
    final width = gestureHitWidth.clamp(0.0, viewSize.width);
    final left = (viewSize.width - width) / 2.0;
    final top = viewSize.height - gestureHitHeight - gestureBottomInset;
    return Rect.fromLTWH(left, top, width, gestureHitHeight);
  }

  static Rect edgePanelGestureRect(Size viewSize) {
    final width = edgePanelGestureWidth.clamp(0.0, viewSize.width);
    final top = viewSize.height - edgePanelGestureHeight - gestureBottomInset;
    return Rect.fromLTWH(
      viewSize.width - width,
      top,
      width,
      edgePanelGestureHeight,
    );
  }

  /// A landscape keyboard has its shortcut keys at its sides.
  static bool oskShortcutsAtSides(Size viewSize) =>
      viewSize.width > viewSize.height;

  /// [shortcuts]: a portrait keyboard shows its row of shortcut keys.
  static double edgePanelHeight(Size viewSize, {required bool shortcuts}) {
    if (viewSize.height <= 0.0) {
      return 0.0;
    }
    // The keys take 30% of the view, 40% of a landscape one; the shortcut
    // row and the suggestion strip add to that.
    final landscape = oskShortcutsAtSides(viewSize);
    final share = landscape ? 0.40 : 0.30;
    final keys = (viewSize.height * share).clamp(0.0, edgePanelKeysMaxHeight);
    final row = shortcuts && !landscape ? oskShortcutRowExtent : 0.0;
    return (keys + row + oskSuggestionStripHeight)
        .clamp(0.0, viewSize.height)
        .toDouble();
  }

  static Rect edgePanelRect(
    Size viewSize,
    double progress, {
    required bool shortcuts,
  }) {
    final height =
        edgePanelHeight(viewSize, shortcuts: shortcuts) *
        progress.clamp(0.0, 1.0);
    return Rect.fromLTWH(0, viewSize.height - height, viewSize.width, height);
  }

  static Rect edgePanelScrollStripRect(
    Size viewSize, {
    required bool shortcuts,
  }) {
    final width = edgePanelScrollStripWidth.clamp(0.0, viewSize.width);
    final panelHeight = edgePanelHeight(viewSize, shortcuts: shortcuts);
    return Rect.fromLTWH(
      viewSize.width - width,
      0,
      width,
      (viewSize.height - panelHeight).clamp(0.0, viewSize.height).toDouble(),
    );
  }

  static List<Rect> softwareKeyboardRegions(
    Size viewSize, {
    required double progress,
    required bool scrollStripVisible,
    required bool shortcuts,
  }) {
    final panel = edgePanelRect(viewSize, progress, shortcuts: shortcuts);
    return <Rect>[
      // The opening swipe belongs to the keyboard too: keep the current
      // editor focused before any part of the keyboard is on screen.
      if (!scrollStripVisible)
        edgePanelGestureRect(viewSize).intersect(Offset.zero & viewSize),
      if (panel.height > 0.0) panel,
      if (scrollStripVisible)
        edgePanelScrollStripRect(viewSize, shortcuts: shortcuts),
    ];
  }

  /// Width of the strip inside each side edge where the Back swipe starts.
  static const double backGestureEdgeWidth = 32.0;

  /// The Back strips stop above the bottom gesture area, as on Android.
  static const double backGestureBottomExclusion =
      gestureHitHeight + gestureBottomInset;

  /// The left and right Back strips, between the status bar and [bottom]:
  /// the bottom gesture area, or the keyboard's top edge while it is open.
  static ({Rect left, Rect right}) backGestureRects(
    Size viewSize, {
    double? bottom,
  }) {
    final top = statusDragHeight.clamp(0.0, viewSize.height).toDouble();
    final limit = viewSize.height - backGestureBottomExclusion;
    final strip = Rect.fromLTRB(
      0,
      top,
      backGestureEdgeWidth.clamp(0.0, viewSize.width / 2).toDouble(),
      (bottom == null || bottom > limit ? limit : bottom)
          .clamp(top, viewSize.height)
          .toDouble(),
    );
    return (
      left: strip,
      right: strip.translate(viewSize.width - strip.width, 0),
    );
  }

  /// Where a system overlay of `surface`'s size sits on a phone: centred
  /// across, and down the space between the status bar and the keyboard as
  /// far as it is open.
  static Rect systemOverlayRect(
    Size viewSize,
    Size surface,
    double keyboardProgress, {
    required bool shortcuts,
  }) {
    final bottom = edgePanelRect(
      viewSize,
      keyboardProgress,
      shortcuts: shortcuts,
    ).top;
    final top = statusBarHeight.clamp(0.0, bottom).toDouble();
    return Rect.fromLTWH(
      (viewSize.width - surface.width) / 2.0,
      (top + (bottom - top - surface.height) / 2.0)
          .clamp(0.0, double.infinity)
          .toDouble(),
      surface.width,
      surface.height,
    );
  }

  static Rect statusRect(Size viewSize) {
    return Rect.fromLTWH(
      0,
      0,
      viewSize.width,
      statusDragHeight.clamp(0.0, viewSize.height),
    );
  }
}
