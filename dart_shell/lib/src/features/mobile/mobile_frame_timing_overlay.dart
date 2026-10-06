import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/shell_frame_time_overlay.dart';

/// Optional diagnostics overlay for the stock mobile scene.
class MobileFrameTimingOverlay extends ConsumerWidget {
  const MobileFrameTimingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(shellFrameTimingOverlayProvider)) {
      return const SizedBox.shrink();
    }
    return const Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.only(top: 12, left: 12),
        child: ShellFrameTimeOverlay(),
      ),
    );
  }
}
