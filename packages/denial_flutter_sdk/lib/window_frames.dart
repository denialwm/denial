/// What the desktop draws around a decorated window: title bars, borders and
/// their controls.
///
/// A frame is a widget around a hole. The desktop puts the window's content in
/// the hole the [ShellWindowFrame.margins] leave, hands the frame's own area to
/// the shell's input, and tells the compositor the margins, so placing,
/// maximizing, tiling and resizing already account for them. The frame acts on
/// its window with the bridge's own calls: `beginWindowMove`,
/// `beginWindowResize`, `placeWindow`, `minimizeWindow`, `closeWindow`.
library;

import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'services.dart';
import 'src/models/denial_window.dart' show DenialWindow;
import 'src/models/denial_window_place.dart' show DenialWindowFrameMargins;

export 'services.dart' show ShellServices;
export 'src/models/denial_window.dart' show DenialWindow;
export 'src/models/denial_window_place.dart'
    show
        DenialWindowFrameMargins,
        DenialWindowPlace,
        DenialWindowPlaceResult,
        DenialWindowPlaceStatus,
        DenialWindowResizeEdge;

/// One window's frame, as the desktop shows it now.
@immutable
final class ShellWindowFrameContext {
  const ShellWindowFrameContext({
    required this.window,
    required this.active,
    required this.maximized,
    required this.interactive,
    required this.margins,
    required this.services,
  });

  /// The window inside the frame, with its title and application.
  final DenialWindow window;

  /// The window has the keyboard.
  final bool active;

  /// The window fills its work area; [margins] are then the frame's
  /// [ShellWindowFrame.maximizedMargins].
  final bool maximized;

  /// False while the desktop shows the window as a picture: in the overview,
  /// the window switcher, and while it minimizes or closes. The frame then
  /// receives no input and should draw its resting look.
  final bool interactive;

  /// The margins around the content in this build. The frame's widget covers
  /// the content and these margins together.
  final DenialWindowFrameMargins margins;

  /// Application icons, cursors and the other host services.
  final ShellServices services;
}

/// Draws the frame of every decorated window. Windows that decorate
/// themselves and fullscreen windows have none.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrOne)
abstract interface class ShellWindowFrame {
  /// What the frame takes around the content, in logical pixels per side.
  /// Read once when the shell starts: return the same value every time.
  DenialWindowFrameMargins get margins;

  /// What the frame takes around a maximized window's content, read once as
  /// [margins]. Null draws a maximized window without a frame, except in a
  /// tiling layout, which keeps [margins].
  DenialWindowFrameMargins? get maximizedMargins;

  /// The frame, laid out over the content and its margins together. It is
  /// painted under the content and receives input only on its margins. Paint
  /// only on the margins: a translucent window shows whatever lies under it.
  Widget build(BuildContext context, {required ShellWindowFrameContext frame});
}
