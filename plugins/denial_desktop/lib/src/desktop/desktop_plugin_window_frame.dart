import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../widgets/desktop_visibility_transition.dart';

/// A window inside the frame the selected [ShellWindowFrame] draws.
///
/// The frame is laid out over the whole window and painted first; the
/// [child], the window's content, sits in the hole its [margins] leave. The
/// frame is hit only on its margins: what reaches the shell inside the
/// content belongs to whatever lies below the window.
class DesktopPluginWindowFrame extends StatelessWidget {
  const DesktopPluginWindowFrame({
    super.key,
    required this.frame,
    required this.window,
    required this.active,
    required this.maximized,
    required this.interactive,
    required this.margins,
    required this.child,
  });

  final ShellWindowFrame frame;
  final DenialWindow window;
  final bool active;
  final bool maximized;
  final bool interactive;
  final EdgeInsets margins;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        DesktopVisibilityFade(
          child: IgnorePointer(
            ignoring: !interactive,
            child: DesktopFrameMarginsHitTest(
              margins: margins,
              child: frame.build(
                context,
                frame: ShellWindowFrameContext(
                  window: window,
                  active: active,
                  maximized: maximized,
                  interactive: interactive,
                  margins: DenialWindowFrameMargins(
                    left: margins.left,
                    top: margins.top,
                    right: margins.right,
                    bottom: margins.bottom,
                  ),
                  services: ShellServicesScope.of(context),
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
