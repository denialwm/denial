import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/tokens.dart';

const SvgTheme _desktopAppSvgTheme = SvgTheme(
  currentColor: ShellColors.fallbackAppIcon,
);

/// Loads a desktop SVG with a cache identity based on its stable file path.
///
/// [SvgFileLoader] compares [File] instances by object identity. App icons
/// create a fresh [File] for precache and paint, so the default loader starts
/// duplicate isolate work for the same path. This loader lets both phases, and
/// later launcher openings, share one decoded cache entry.
@immutable
class DesktopAppSvgLoader extends SvgLoader<void> {
  const DesktopAppSvgLoader(this.path) : super(theme: _desktopAppSvgTheme);

  final String path;

  @override
  String provideSvg(void message) {
    return utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
  }

  @override
  int get hashCode => Object.hash(path, theme, colorMapper);

  @override
  bool operator ==(Object other) {
    return other is DesktopAppSvgLoader &&
        other.path == path &&
        other.theme == theme &&
        other.colorMapper == colorMapper;
  }
}

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
      return SvgPicture(
        DesktopAppSvgLoader(path),
        fit: BoxFit.contain,
        placeholderBuilder: (_) => const _FallbackAppIcon(),
        errorBuilder: (_, _, _) => const _FallbackAppIcon(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 85.0;
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
          errorBuilder: (_, _, _) => const _FallbackAppIcon(),
        );
      },
    );
  }
}

/// Keeps icon file work out of the launcher's first layout and paint.
///
/// Only an icon whose lazily-built tile exists starts loading. The fixed-size
/// placeholder is rendered first, then this widget alone rebuilds once its
/// bytes are ready.
class DeferredAppIcon extends StatefulWidget {
  const DeferredAppIcon({super.key, required this.iconPath});

  final String? iconPath;

  @override
  State<DeferredAppIcon> createState() => _DeferredAppIconState();
}

class _DeferredAppIconState extends State<DeferredAppIcon> {
  var _ready = false;
  var _failed = false;
  var _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _deferLoad();
  }

  @override
  void didUpdateWidget(covariant DeferredAppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.iconPath == oldWidget.iconPath) {
      return;
    }
    _ready = false;
    _failed = false;
    _deferLoad();
  }

  void _deferLoad() {
    final generation = ++_loadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      unawaited(_load(generation));
    });
  }

  Future<void> _load(int generation) async {
    var failed = false;
    var fallbackReady = false;
    try {
      await _precacheAppIcon(context, widget.iconPath);
    } on Object {
      failed = true;
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      try {
        await _precacheAppIcon(context, null);
        fallbackReady = true;
      } on Object {
        // The transparent placeholder remains if even the bundled fallback
        // cannot be decoded.
      }
    }
    if (!mounted || generation != _loadGeneration) {
      return;
    }
    setState(() {
      _ready = !failed || fallbackReady;
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox.expand();
    }
    return _failed
        ? const _FallbackAppIcon()
        : AppIconImage(iconPath: widget.iconPath);
  }
}

Future<void> _precacheAppIcon(BuildContext context, String? iconPath) async {
  final path = iconPath;
  if (path == null) {
    await const SvgAssetLoader(AppIconImage.fallbackAsset).loadBytes(context);
    return;
  }
  if (path.toLowerCase().endsWith('.svg')) {
    await DesktopAppSvgLoader(path).loadBytes(context);
    return;
  }

  const logicalSize = 54.0;
  final cacheWidth = (logicalSize * MediaQuery.devicePixelRatioOf(context))
      .ceil()
      .clamp(85, 512)
      .toInt();
  final provider = ResizeImage.resizeIfNeeded(
    cacheWidth,
    null,
    FileImage(File(path)),
  );
  await precacheImage(
    provider,
    context,
    size: const Size.square(logicalSize),
    onError: (_, _) {},
  );
}

class _FallbackAppIcon extends StatelessWidget {
  const _FallbackAppIcon();

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(AppIconImage.fallbackAsset, fit: BoxFit.contain);
  }
}
