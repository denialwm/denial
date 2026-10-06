import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';
import 'window_content_rect.dart';

/// A window's live content rendered with rounded corners and an optional
/// hairline border, filling its parent. This is the single building block for
/// every place the mobile shell shows a window: launch, overview cards, the
/// foreground-to-overview hero, focus zoom, and the primary stage.
class WindowSurface extends StatelessWidget {
  const WindowSurface({
    super.key,
    required this.window,
    this.radius = 0.0,
    this.borderColor,
    this.addRepaintBoundary = true,
  });

  final DenialWindow window;
  final double radius;

  /// When non-null, a 1px hairline is drawn over the texture in this colour.
  final Color? borderColor;
  final bool addRepaintBoundary;

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = window.serverSideDecorated ? radius : 0.0;
    final borderRadius = effectiveRadius <= 0.0
        ? BorderRadius.zero
        : BorderRadius.circular(effectiveRadius);

    Widget content = WindowContentRect(
      window: window,
      borderRadius: borderRadius,
      // A launch/recents hero presents the app's surface. Sampling the shell
      // behind it adds an invisible glass pass that invalidates on every move.
      // The primary app stage owns the normal window backdrop separately.
      applyBackdrop: false,
    );

    final border = window.serverSideDecorated ? borderColor : null;
    if (border != null) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: border, width: 1),
            ),
          ),
        ],
      );
    }

    return addRepaintBoundary ? RepaintBoundary(child: content) : content;
  }
}
