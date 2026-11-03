import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:flutter/widgets.dart';

/// The app in front, filling the screen at rest. Whenever the apps move,
/// the app deck draws them instead and this stage stays laid out but
/// transparent, so the app keeps its surface and backdrop.
class MobilePrimaryWindowStage extends StatelessWidget {
  const MobilePrimaryWindowStage({
    super.key,
    required this.currentWindow,
    required this.opacity,
  });

  final DenialWindow currentWindow;
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
          WindowContentRect(
            contentPadding: EdgeInsets.only(
              top: ReferenceShellMetrics.appStatusInset(
                MediaQuery.sizeOf(context),
              ),
            ),
            key: ValueKey<int>(window.objectId),
            window: window,
            active: true,
          ),
        ],
      ),
    );
  }
}
