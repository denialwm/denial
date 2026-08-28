import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/shell_frame_time_overlay.dart';

/// Optional diagnostics overlay for the stock mobile scene.
class MobileFrameTimingOverlay extends ConsumerWidget {
  const MobileFrameTimingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(shellFrameTimingOptionsProvider);
    if (!options.showOverlay) {
      return const SizedBox.shrink();
    }
    final windows = ref.watch(
      shellControllerProvider.select((state) => state.windows),
    );
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, left: 12),
        child: ShellFrameTimingOverlayStack(
          windows: windows,
          showImportedTextureCharts: options.showImportedTextureCharts,
        ),
      ),
    );
  }
}
