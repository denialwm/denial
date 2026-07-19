import 'package:flutter/widgets.dart';

import '../input/input_layout.dart';
import '../models/denial_window.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'window_surface_tree.dart';

class WindowTextureRect extends StatelessWidget {
  const WindowTextureRect({
    super.key,
    required this.window,
    this.borderRadius = BorderRadius.zero,
  });

  final DenialWindow window;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final targetSize = constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight &&
                constraints.maxWidth > 0.0 &&
                constraints.maxHeight > 0.0
            ? constraints.biggest
            : null;
        return _buildTexture(context, targetSize);
      },
    );
  }

  Widget _buildTexture(BuildContext context, Size? targetSize) {
    final textureWidth = window.width.toDouble();
    final textureHeight = window.height.toDouble();
    final visualStatusBarHeight =
        MediaQuery.paddingOf(context).top + ShellMetrics.appStatusBarHeight;
    final statusBarHeight = ShellMetrics.appStatusBarTextureHeight(
      window,
      targetSize: targetSize,
      visualHeight: visualStatusBarHeight,
    );
    final statusBarColor = window.statusColorArgb == null
        ? ShellColors.background
        : Color(window.statusColorArgb!);

    final textureBody = SizedBox(
      width: textureWidth,
      height: textureHeight,
      child: WindowSurfaceTree(
        window: window,
        includePopups: true,
      ),
    );
    Widget texture = textureBody;

    if (statusBarHeight > 0.0) {
      texture = SizedBox(
        width: textureWidth,
        height: textureHeight + statusBarHeight,
        child: Column(
          children: [
            SizedBox(
              width: textureWidth,
              height: statusBarHeight,
              child: AnimatedContainer(
                duration: Motion.cardSettle,
                curve: Motion.standard,
                color: statusBarColor,
              ),
            ),
            SizedBox(
              width: textureWidth,
              height: textureHeight,
              child: textureBody,
            ),
          ],
        ),
      );
    }

    final fittedTexture = FittedBox(
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      child: texture,
    );

    if (borderRadius == BorderRadius.zero) {
      return fittedTexture;
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: fittedTexture,
    );
  }
}
