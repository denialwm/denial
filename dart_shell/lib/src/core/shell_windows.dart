import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/denial_window.dart';
import '../state/shell_controller.dart';
import '../widgets/window_content_rect.dart';
import 'shell_window_providers.dart';

/// Semantic window actions for custom shell features.
///
/// This facade keeps feature code independent from [ShellController]'s state
/// machine and exposes only operations that make sense at the UI boundary.
@immutable
class ShellWindowActions {
  const ShellWindowActions._(this._controller);

  final ShellController _controller;

  void focus(DenialWindow window) => _controller.focusWindow(window);

  void close(DenialWindow window) => _controller.closeWindow(window);

  void releaseFocus(DenialWindow window) =>
      _controller.releaseWindowFocus(window);
}

typedef ShellWindowsWidgetBuilder =
    Widget Function(
      BuildContext context,
      List<DenialWindow> windows,
      ShellWindowActions actions,
    );

/// Rebuilds custom UI with filtered application windows and semantic actions.
class ShellWindowsBuilder extends ConsumerWidget {
  const ShellWindowsBuilder({super.key, required this.builder});

  final ShellWindowsWidgetBuilder builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return builder(
      context,
      ref.watch(userAppWindowsProvider),
      ShellWindowActions._(ref.read(shellControllerProvider.notifier)),
    );
  }
}

/// Displays Denial's current primary application surface.
///
/// The widget owns native-surface selection and returns [empty] when no window
/// is active, which is sufficient for many custom mobile and kiosk shells.
class ShellPrimaryWindow extends ConsumerWidget {
  const ShellPrimaryWindow({
    super.key,
    this.empty = const SizedBox.shrink(),
    this.active = true,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget empty;
  final bool active;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = ref.watch(
      shellControllerProvider.select((state) => state.primaryWindow),
    );
    if (window == null) {
      return empty;
    }
    return WindowContentRect(
      key: ValueKey<int>(window.objectId),
      window: window,
      active: active,
      borderRadius: borderRadius,
    );
  }
}
