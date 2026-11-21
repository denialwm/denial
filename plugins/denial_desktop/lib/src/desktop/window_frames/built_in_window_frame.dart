import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter/widgets.dart';

import 'frame_reach.dart';
import 'window_frame.dart';

/// Denial's own window frames, which the stacking layout draws when
/// `layout.windowFrames` is on: a title bar with the application's icon and
/// title, and minimize, maximize or restore, and close buttons.
final class BuiltInWindowFrame implements ShellWindowFrame {
  const BuiltInWindowFrame();

  /// The title bar, with the border above it.
  static const titleBarHeight = 40.0;

  /// The border on the other three sides.
  static const border = 1.0;

  /// How far outside the border a press still resizes the window.
  static const resizeReach = 12.0;

  @override
  DenialWindowFrameMargins get margins => const DenialWindowFrameMargins(
    left: border,
    top: titleBarHeight,
    right: border,
    bottom: border,
  );

  /// A maximized window keeps its title bar and loses its border.
  @override
  DenialWindowFrameMargins get maximizedMargins =>
      const DenialWindowFrameMargins(top: titleBarHeight);

  /// An invisible band around the window to resize it by, wide enough for a
  /// finger.
  @override
  DenialWindowFrameMargins get reach => const DenialWindowFrameMargins(
    left: resizeReach,
    top: resizeReach,
    right: resizeReach,
    bottom: resizeReach,
  );

  @override
  Widget build(BuildContext context, {required ShellWindowFrameContext frame}) {
    return WindowsWindowFrame(frame: frame);
  }

  @override
  Widget buildReach(
    BuildContext context, {
    required ShellWindowFrameContext frame,
  }) {
    return WindowsFrameReach(frame: frame);
  }
}
