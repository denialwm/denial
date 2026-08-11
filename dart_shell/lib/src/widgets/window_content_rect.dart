import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_apps/local_flutter_application.dart';
import '../local_apps/local_flutter_window_host.dart';
import '../input/input_layout.dart';
import '../models/denial_window.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'shell_backdrop_blur.dart';
import 'window_texture_rect.dart';

/// Presents either compositor texture content or an in-bundle Flutter app.
///
/// Mobile shell transitions all consume this boundary so a local application
/// follows the same primary, launch, switch, and overview lifecycle as a
/// Wayland-backed window. The stable host key preserves the local widget tree
/// when it moves between those mutually-exclusive presentation sites.
class WindowContentRect extends ConsumerWidget {
  const WindowContentRect({
    super.key,
    required this.window,
    this.borderRadius = BorderRadius.zero,
    this.active = false,
  });

  final DenialWindow window;
  final BorderRadius borderRadius;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!window.isLocalFlutter) {
      return WindowTextureRect(window: window, borderRadius: borderRadius);
    }

    final application = ref.watch(
      localFlutterApplicationRegistryProvider.select(
        (registry) => registry[window.appId],
      ),
    );
    final layoutSize = _localLayoutSize(window);
    return LayoutBuilder(
      builder: (context, constraints) {
        final targetSize =
            constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight &&
                constraints.maxWidth > 0 &&
                constraints.maxHeight > 0
            ? constraints.biggest
            : null;
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
        return ShellBackdropBlur(
          blur: application?.translucent ?? false,
          borderRadius: borderRadius,
          child: FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: layoutSize.width,
              height: layoutSize.height + statusBarHeight,
              child: Column(
                children: [
                  SizedBox(
                    width: layoutSize.width,
                    height: statusBarHeight,
                    child: AnimatedContainer(
                      duration: Motion.cardSettle,
                      color: statusBarColor,
                    ),
                  ),
                  SizedBox.fromSize(
                    size: layoutSize,
                    child: LocalFlutterWindowHost(
                      key: LocalFlutterWindowHostKey(window.objectId),
                      window: window,
                      active: active,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

Size _localLayoutSize(DenialWindow window) {
  final width = window.geometryWidth > 0
      ? window.geometryWidth
      : window.width.toDouble();
  final height = window.geometryHeight > 0
      ? window.geometryHeight
      : window.height.toDouble();
  return Size(
    width.clamp(64.0, 16384.0).toDouble(),
    height.clamp(64.0, 16384.0).toDouble(),
  );
}
