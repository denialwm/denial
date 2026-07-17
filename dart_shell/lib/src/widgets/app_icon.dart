import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/tokens.dart';

/// Renders a resolved desktop-app icon with the shell's bundled fallback.
class AppIconImage extends StatelessWidget {
  const AppIconImage({super.key, required this.iconPath});

  static const String fallbackAsset =
      'assets/icons/application-default-icon.svg';

  final String? iconPath;

  @override
  Widget build(BuildContext context) {
    final path = iconPath;
    if (path == null) {
      return const _FallbackAppIcon();
    }
    if (path.toLowerCase().endsWith('.svg')) {
      return SvgPicture.file(
        File(path),
        fit: BoxFit.contain,
        theme: const SvgTheme(currentColor: ShellColors.fallbackAppIcon),
        placeholderBuilder: (_) => const _FallbackAppIcon(),
        errorBuilder: (_, __, ___) => const _FallbackAppIcon(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth =
            constraints.hasBoundedWidth ? constraints.maxWidth : 85.0;
        final cacheWidth =
            (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(85, 512)
                .toInt();
        return Image.file(
          File(path),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const _FallbackAppIcon(),
        );
      },
    );
  }
}

class _FallbackAppIcon extends StatelessWidget {
  const _FallbackAppIcon();

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      AppIconImage.fallbackAsset,
      fit: BoxFit.contain,
    );
  }
}
