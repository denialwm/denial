import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_apps/local_flutter_application.dart';
import '../local_apps/local_flutter_window_host.dart';
import '../models/denial_window.dart';

import 'package:denial_flutter_sdk/effects.dart';

import '../theme/shell_theme.dart';

import 'window_backdrop_cache.dart';
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
    this.applyBackdrop = true,
    this.contentPadding = EdgeInsets.zero,
  });

  final DenialWindow window;
  final BorderRadius borderRadius;
  final bool active;
  final bool applyBackdrop;

  /// Insets supplied by the shell for in-bundle application content.
  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!window.isLocalFlutter) {
      return WindowTextureRect(
        window: window,
        borderRadius: borderRadius,
        applyBackdrop: applyBackdrop,
      );
    }

    final application = ref.watch(
      localFlutterApplicationRegistryProvider.select(
        (registry) => registry[window.appId],
      ),
    );
    final layoutSize = _localLayoutSize(window);
    // In-bundle apps receive safe-area information like any inset-aware
    // client; they do not need a separately painted shell header.
    final media = MediaQuery.of(context);
    final translucent = applyBackdrop && (application?.translucent ?? false);
    final cache = translucent ? WindowBackdropCache.maybeOf(context) : null;
    Widget content = FittedBox(
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      child: SizedBox.fromSize(
        size: layoutSize,
        child: MediaQuery(
          data: media.copyWith(
            padding: media.padding + contentPadding,
            viewPadding: media.viewPadding + contentPadding,
          ),
          child: LocalFlutterWindowHost(
            key: LocalFlutterWindowHostKey(window.objectId),
            window: window,
            active: active,
          ),
        ),
      ),
    );
    if (cache != null) {
      // A precomputed backdrop replaces the live glass under the app.
      content = Stack(
        fit: StackFit.expand,
        children: [
          WindowBackdropSlice(
            cache: cache,
            borderRadius: borderRadius,
            glass: ShellTheme.of(context).windowGlassShading,
          ),
          content,
        ],
      );
    }
    return ShellBackdropBlur(
      blur: translucent && cache == null,
      borderRadius: borderRadius,
      child: content,
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
