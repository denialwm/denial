import 'package:flutter/widgets.dart';

/// Where a window should be, as a rule the compositor turns into pixels.
///
/// The shell names the place and never computes the rectangle: the frame it
/// draws, the window's size limits, the layout and the work area are applied
/// by the compositor, and a share of the work area is resolved again when the
/// work area changes.
@immutable
sealed class DenialWindowPlace {
  const DenialWindowPlace();

  /// The window's outer frame at [frame], in scene coordinates.
  const factory DenialWindowPlace.free(Rect frame) = DenialFreeWindowPlace;

  /// A share of an output's work area. [share] is in fractions of that area:
  /// `Rect.fromLTWH(0, 0, 0.5, 1)` is its left half. Shares that touch in
  /// fractions touch in pixels. A null [monitorId] is the window's own
  /// output.
  const factory DenialWindowPlace.area(Rect share, {int? monitorId}) =
      DenialAreaWindowPlace;

  /// The whole work area of [monitorId], or of the window's own output.
  const factory DenialWindowPlace.maximized({int? monitorId}) =
      DenialAreaWindowPlace.whole;

  /// The whole of output [monitorId], or of the window's own.
  const factory DenialWindowPlace.fullscreen({int? monitorId}) =
      DenialFullscreenWindowPlace;

  /// Back to the last free place.
  const factory DenialWindowPlace.restore() = DenialRestoreWindowPlace;
}

@immutable
final class DenialFreeWindowPlace extends DenialWindowPlace {
  const DenialFreeWindowPlace(this.frame);

  final Rect frame;

  @override
  bool operator ==(Object other) =>
      other is DenialFreeWindowPlace && other.frame == frame;

  @override
  int get hashCode => frame.hashCode;
}

@immutable
final class DenialAreaWindowPlace extends DenialWindowPlace {
  const DenialAreaWindowPlace(this.share, {this.monitorId});

  const DenialAreaWindowPlace.whole({this.monitorId})
    : share = const Rect.fromLTWH(0.0, 0.0, 1.0, 1.0);

  final Rect share;
  final int? monitorId;

  @override
  bool operator ==(Object other) =>
      other is DenialAreaWindowPlace &&
      other.share == share &&
      other.monitorId == monitorId;

  @override
  int get hashCode => Object.hash(share, monitorId);
}

@immutable
final class DenialFullscreenWindowPlace extends DenialWindowPlace {
  const DenialFullscreenWindowPlace({this.monitorId});

  final int? monitorId;

  @override
  bool operator ==(Object other) =>
      other is DenialFullscreenWindowPlace && other.monitorId == monitorId;

  @override
  int get hashCode => monitorId.hashCode;
}

@immutable
final class DenialRestoreWindowPlace extends DenialWindowPlace {
  const DenialRestoreWindowPlace();

  @override
  bool operator ==(Object other) => other is DenialRestoreWindowPlace;

  @override
  int get hashCode => 0;
}

enum DenialWindowPlaceStatus {
  /// The window is, or would be, exactly where the place says.
  applied,

  /// The window is, or would be, at [DenialWindowPlaceResult.frame], which
  /// differs from the place: its size limits or its layout decided.
  adjusted,

  /// Nothing changed and there is no rectangle to report.
  refused,
}

/// The compositor's answer to one place request.
@immutable
final class DenialWindowPlaceResult {
  const DenialWindowPlaceResult({
    required this.windowId,
    required this.status,
    required this.frame,
    required this.contentRect,
    required this.monitorId,
  });

  const DenialWindowPlaceResult.refused(this.windowId)
    : status = DenialWindowPlaceStatus.refused,
      frame = Rect.zero,
      contentRect = Rect.zero,
      monitorId = null;

  final int windowId;
  final DenialWindowPlaceStatus status;

  /// The window's outer rectangle in scene coordinates, frame included.
  final Rect frame;

  /// The client's content inside [frame].
  final Rect contentRect;

  /// The output the window is on, when the compositor knows it.
  final int? monitorId;

  bool get refused => status == DenialWindowPlaceStatus.refused;

  @override
  bool operator ==(Object other) =>
      other is DenialWindowPlaceResult &&
      other.windowId == windowId &&
      other.status == status &&
      other.frame == frame &&
      other.contentRect == contentRect &&
      other.monitorId == monitorId;

  @override
  int get hashCode =>
      Object.hash(windowId, status, frame, contentRect, monitorId);
}

/// The edge or corner a resize drags.
enum DenialWindowResizeEdge {
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// What the shell draws around a decorated window's content, in logical
/// pixels per side. The compositor subtracts it to find the content.
@immutable
final class DenialWindowFrameMargins {
  const DenialWindowFrameMargins({
    this.left = 0.0,
    this.top = 0.0,
    this.right = 0.0,
    this.bottom = 0.0,
  });

  const DenialWindowFrameMargins.all(double value)
    : left = value,
      top = value,
      right = value,
      bottom = value;

  static const DenialWindowFrameMargins none = DenialWindowFrameMargins();

  /// The widest side the compositor accepts.
  static const double max = 256.0;

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get isValid => [
    left,
    top,
    right,
    bottom,
  ].every((value) => value.isFinite && value >= 0.0 && value <= max);

  @override
  bool operator ==(Object other) =>
      other is DenialWindowFrameMargins &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}
