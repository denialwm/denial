import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/surfaces.dart' show ShellScaleViewport;
import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/default_shell/panel_composition.dart';
import '../widgets/desktop_visibility_transition.dart';

/// A window inside the frame the selected [ShellWindowFrame] draws.
///
/// The frame is laid out over the whole window and painted first; the
/// [child], the window's content, sits in the hole its [margins] leave. The
/// frame is hit only on its margins: what reaches the shell inside the
/// content belongs to whatever lies below the window.
///
/// The frame is built in the shell's own units and drawn [scale] times as
/// large; the margins and reach it is told are this widget's divided by
/// [scale], so it fills exactly the margins the compositor knows.
class DesktopPluginWindowFrame extends StatelessWidget {
  const DesktopPluginWindowFrame({
    super.key,
    required this.frame,
    required this.window,
    required this.active,
    required this.maximized,
    required this.interactive,
    required this.margins,
    this.reach = EdgeInsets.zero,
    this.scale = 1.0,
    required this.child,
  });

  final ShellWindowFrame frame;
  final DenialWindow window;
  final bool active;
  final bool maximized;
  final bool interactive;
  final EdgeInsets margins;

  /// The band outside the frame that [DesktopWindowFrameReach] gives it now.
  final EdgeInsets reach;

  /// The shell's own scale where the window is.
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final frameMargins = margins / scale;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        DesktopVisibilityFade(
          child: IgnorePointer(
            ignoring: !interactive,
            child: ShellScaleViewport(
              scale: scale,
              child: DesktopFrameMarginsHitTest(
                margins: frameMargins,
                child: Builder(
                  builder: (context) => frame.build(
                    context,
                    frame: ShellWindowFrameContext(
                      window: window,
                      active: active,
                      maximized: maximized,
                      interactive: interactive,
                      margins: _frameMargins(frameMargins),
                      reach: _frameMargins(reach / scale),
                      services: ShellServicesScope.of(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(padding: margins, child: child),
      ],
    );
  }
}

DenialWindowFrameMargins _frameMargins(EdgeInsets insets) =>
    DenialWindowFrameMargins(
      left: insets.left,
      top: insets.top,
      right: insets.right,
      bottom: insets.bottom,
    );

/// The band outside a resting window's frame where the selected
/// [ShellWindowFrame] takes presses, such as resize handles.
///
/// It is a layer of its own, right under its window: a window's box, and all
/// that animates it, is exactly its frame, and Flutter offers a widget no
/// pointer outside its box. The band is hit only outside the frame.
class DesktopWindowFrameReach extends ConsumerWidget {
  const DesktopWindowFrameReach({
    super.key,
    required this.window,
    required this.frame,
    required this.active,
    required this.margins,
    required this.reach,
    this.scale = 1.0,
  });

  final DenialWindow window;

  /// The window's frame rectangle, as its own layer draws it.
  final Rect frame;
  final bool active;
  final EdgeInsets margins;
  final EdgeInsets reach;

  /// The shell's own scale where the window is, as for its frame.
  final double scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pluginFrame = ref.watch(desktopWindowFrameProvider);
    final frameReach = reach / scale;
    return Positioned.fromRect(
      rect: reach.inflateRect(frame),
      child: pluginFrame == null
          ? const SizedBox.shrink()
          : ShellScaleViewport(
              scale: scale,
              child: DesktopFrameMarginsHitTest(
                margins: frameReach,
                child: Builder(
                  builder: (context) => pluginFrame.buildReach(
                    context,
                    frame: ShellWindowFrameContext(
                      window: window,
                      active: active,
                      maximized: false,
                      interactive: true,
                      margins: _frameMargins(margins / scale),
                      reach: _frameMargins(frameReach),
                      services: ShellServicesScope.of(context),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Lets pointers reach [child] only on the [margins] of its box, and nowhere
/// with null [margins]. With [enabled] false it does nothing: every pointer
/// is offered to [child].
class DesktopFrameMarginsHitTest extends SingleChildRenderObjectWidget {
  const DesktopFrameMarginsHitTest({
    super.key,
    required this.margins,
    this.enabled = true,
    super.child,
  });

  /// The sides of the box that take pointers. Null takes none.
  final EdgeInsets? margins;
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFrameMarginsHitTest(margins: margins, enabled: enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderFrameMarginsHitTest)
      ..margins = margins
      ..enabled = enabled;
  }
}

class _RenderFrameMarginsHitTest extends RenderProxyBox {
  _RenderFrameMarginsHitTest({required this.margins, required this.enabled});

  EdgeInsets? margins;
  bool enabled;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (enabled) {
      final margins = this.margins;
      if (margins == null ||
          margins.deflateRect(Offset.zero & size).contains(position)) {
        return false;
      }
    }
    return super.hitTest(result, position: position);
  }
}
