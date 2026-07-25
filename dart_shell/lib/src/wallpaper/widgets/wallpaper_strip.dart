import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../wallpaper.dart';
import 'wallpaper_image.dart';

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
    final accent = ShellTheme.of(context).accentPalette;
    final candidate = widget.candidate;
    final label = candidate.id == 'default'
        ? context.l10n.wallpaperDefault
        : candidate.width > 0 && candidate.height > 0
        ? context.l10n.wallpaperDimensions(candidate.width, candidate.height)
        : candidate.label;
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
                          const ColoredBox(
                            color: ShellColors.surfaceContainerHigh,
                            child: Icon(
                              Icons.broken_image_rounded,
                              color: ShellColors.textTertiary,
                            ),
                          ),
                    )
                  else
                    const ColoredBox(
                      color: ShellColors.surfaceContainerHigh,
                      child: Icon(
                        Icons.image_rounded,
                        color: ShellColors.textTertiary,
                      ),
                    ),
                  if (widget.downloading)
                    ColoredBox(
                      color: ShellColors.overviewScrim,
                      child: Center(
                        child: SizedBox.square(
                          dimension: 42,
                          child: CircularProgressIndicator(
                            value: widget.downloadProgress > 0.0
                                ? widget.downloadProgress
                                : null,
                            color: accent.primary,
                            backgroundColor:
                                ShellColors.surfaceContainerHighest,
                            strokeWidth: 4,
                          ),
                        ),
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
