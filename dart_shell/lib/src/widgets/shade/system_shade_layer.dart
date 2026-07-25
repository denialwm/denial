import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/shell_controller.dart';
import '../../theme/motion.dart';
import 'quick_settings_panel.dart';
import 'status_bar.dart';

/// Top-level coordinator for the status bar and the quick-settings shade.
///
/// It owns a single controller whose value mirrors the shade's open fraction:
/// it tracks the drag 1:1 while the user is pulling, and settles with a spring
/// once released. All control state lives in providers, so this widget stays a
/// thin animation host.
class SystemShadeLayer extends ConsumerStatefulWidget {
  const SystemShadeLayer({super.key});

  @override
  ConsumerState<SystemShadeLayer> createState() => _SystemShadeLayerState();
}

class _SystemShadeLayerState extends ConsumerState<SystemShadeLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final state = ref.read(shellControllerProvider);
    _controller = AnimationController.unbounded(
      vsync: this,
      value: state.quickSettingsVisible ? 1.0 : state.quickSettingsDragProgress,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onShadeChanged((bool, double, bool) signal) {
    final (visible, drag, dragActive) = signal;
    if (dragActive) {
      // Live drag: follow the finger exactly.
      _controller.stop();
      _controller.value = drag;
    } else {
      // Released: settle open or closed.
      springTo(
        _controller,
        visible ? 1.0 : 0.0,
        spring: Motion.gentle,
        telemetryLabel: 'shade_settle',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<(bool, double, bool)>(
      shellControllerProvider.select(
        (state) => (
          state.quickSettingsVisible,
          state.quickSettingsDragProgress,
          state.quickSettingsDragActive,
        ),
      ),
      (_, next) => _onShadeChanged(next),
    );

    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ShadeStatusBar(),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final progress = unit(_controller.value);
              if (progress <= 0.001) {
                return const SizedBox.expand();
              }
              return QuickSettingsShade(progress: progress);
            },
          ),
        ],
      ),
    );
  }
}
