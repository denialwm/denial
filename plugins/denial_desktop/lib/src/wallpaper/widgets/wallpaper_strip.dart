import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

/// The name announced for [candidate] by the selector's strips and gallery.
String wallpaperCandidateLabel(
  BuildContext context,
  WallpaperCandidate candidate,
) {
  return candidate.id == 'default'
      ? context.l10n.wallpaperDefault
      : candidate.width > 0 && candidate.height > 0
      ? context.l10n.wallpaperDimensions(candidate.width, candidate.height)
      : candidate.label;
}

class WallpaperStrip extends StatefulWidget {
  const WallpaperStrip({
    super.key,
    required this.candidate,
    required this.current,
    required this.downloading,
    required this.downloadProgress,
    required this.onTapUp,
  });

  final WallpaperCandidate candidate;
  final bool current;
  final bool downloading;
  final double downloadProgress;
  final ValueChanged<Offset> onTapUp;

  @override
  State<WallpaperStrip> createState() => _WallpaperStripState();
}

class _WallpaperStripState extends State<WallpaperStrip>
    with AutomaticKeepAliveClientMixin<WallpaperStrip> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final label = wallpaperCandidateLabel(context, widget.candidate);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheHeight =
            (constraints.maxHeight * MediaQuery.devicePixelRatioOf(context))
                .ceil();
        final image = wallpaperCandidateImageProvider(
          widget.candidate,
          cacheHeight: cacheHeight,
        );
        return Semantics(
          button: true,
          selected: widget.current,
          label: context.l10n.wallpaperApplyCandidate(label),
          child: MouseRegion(
            cursor: ShellMouseCursors.link,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => widget.onTapUp(details.globalPosition),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (image != null)
                    Image(
                      image: image,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (context, error, stackTrace) =>
                          const WallpaperTilePlaceholder(
                            icon: Icons.broken_image_rounded,
                          ),
                    )
                  else
                    const WallpaperTilePlaceholder(icon: Icons.image_rounded),
                  if (widget.downloading)
                    WallpaperDownloadOverlay(progress: widget.downloadProgress),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Fills a wallpaper tile whose preview is missing or failed to decode.
class WallpaperTilePlaceholder extends StatelessWidget {
  const WallpaperTilePlaceholder({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.shellColors.surfaceContainerHigh,
      child: Icon(icon, color: context.shellColors.textTertiary),
    );
  }
}

class WallpaperDownloadOverlay extends StatelessWidget {
  const WallpaperDownloadOverlay({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.shellColors.overviewScrim,
      child: Center(
        child: SizedBox.square(
          dimension: 42,
          child: CircularProgressIndicator(
            value: progress > 0.0 ? progress : null,
            color: ShellTheme.of(context).accentPalette.primary,
            backgroundColor: context.shellColors.surfaceContainerHighest,
            strokeWidth: 4,
          ),
        ),
      ),
    );
  }
}
