import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:flutter/widgets.dart';

/// The app in front, filling the screen at rest. Whenever the apps move,
/// the app deck draws them instead and this stage stays laid out but
/// transparent, so the app keeps its surface and backdrop.
///
/// A window opened over apps, such as a dialog, draws over them: [behind]
/// holds them, the farthest first.
class MobilePrimaryWindowStage extends StatelessWidget {
  const MobilePrimaryWindowStage({
    super.key,
    required this.currentWindow,
    this.behind = const <DenialWindow>[],
    required this.opacity,
  });

  final DenialWindow currentWindow;
  final List<DenialWindow> behind;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final window = currentWindow;
    // The parent chain stays stable whether the deck or the stage shows the
    // app: rebuilding it would recreate a transparent app's glass.
    return Opacity(
      opacity: opacity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final app in behind)
            WindowContentRect(
              contentPadding: const EdgeInsets.only(
                top: ReferenceShellMetrics.statusBarHeight,
              ),
              key: ValueKey<int>(app.objectId),
              window: app,
            ),
          WindowContentRect(
            contentPadding: const EdgeInsets.only(
              top: ReferenceShellMetrics.statusBarHeight,
            ),
            key: ValueKey<int>(window.objectId),
            window: window,
            active: true,
            // Glass would hide the apps it opened over.
            applyBackdrop: behind.isEmpty,
          ),
        ],
      ),
    );
  }
}
