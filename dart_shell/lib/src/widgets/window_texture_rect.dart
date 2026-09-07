import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';
import 'shell_backdrop_blur.dart';
import 'window_surface_tree.dart';

class WindowTextureRect extends StatelessWidget {
  const WindowTextureRect({
    super.key,
    required this.window,
    this.borderRadius = BorderRadius.zero,
    this.applyBackdrop = true,
  });

  final DenialWindow window;
  final BorderRadius borderRadius;
  final bool applyBackdrop;

  @override
  Widget build(BuildContext context) {
    assert(
      !window.isLocalFlutter,
      'Local Flutter windows must be rendered through WindowContentRect.',
    );
    return ShellBackdropBlur(
      blur: applyBackdrop && !window.isOpaque,
      borderRadius: borderRadius,
      child: FittedBox(
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: window.width.toDouble(),
          height: window.height.toDouble(),
          child: WindowSurfaceTree(
            window: window,
            includePopups: true,
            filterQuality: FilterQuality.low,
          ),
        ),
      ),
    );
  }
}
