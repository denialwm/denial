import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../models/display_layout.dart';
import '../localization/denial_localizations.dart';
import '../services/media_player_service.dart';
import '../state/system_status.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import '../widgets/notification_media.dart';
import '../widgets/shell_backdrop_blur.dart';
import '../widgets/shell_cursor.dart';

/// The desktop system bar. Its strip is reserved from the window work area,
/// so windows maximize beside it while true fullscreen covers it.
///
/// The strip itself paints nothing: modules float as borderless pill cards
/// over the bare wallpaper, and every card follows the wallpaper's extracted
/// accent. Cards cluster at the trailing edge of the strip and spring in one
/// after another when the bar mounts.
class DesktopSystemBar extends ConsumerWidget {
  const DesktopSystemBar({required this.side, super.key});

  static const double _edgePadding = 8.0;
  static const double _cardMargin = 5.0;
  static const double _cardGap = 8.0;

  final SystemBarSide side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(shellAccentProvider);
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final cpu = ref.watch(cpuUsageProvider);
    final gpus = ref.watch(gpuUsageProvider);
    final media =
        ref.watch(mediaPlaybackProvider).value ??
        MprisPlaybackState.unavailable();
    final horizontal = side.isHorizontal;
    final cpuVisible = cpu.current != null;
    final mediaVisible = media.available;
    return Padding(
      padding: horizontal
          ? const EdgeInsets.symmetric(
              horizontal: _edgePadding,
              vertical: _cardMargin,
            )
          : const EdgeInsets.symmetric(
              horizontal: _cardMargin,
              vertical: _edgePadding,
            ),
      child: Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (mediaVisible)
            _SystemBarEntrance(
              key: const ValueKey('system-bar-media'),
              index: (cpuVisible ? 1 : 0) + gpus.length + 1,
              horizontal: horizontal,
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _SystemBarCard(
                  accent: accent,
                  child: _MediaStatusModule(
                    accent: accent,
                    side: side,
                    playback: media,
                  ),
                ),
              ),
            ),
          for (int i = 0; i < gpus.length; i += 1)
            _SystemBarEntrance(
              key: ValueKey('system-bar-gpu-${gpus[i].id}'),
              index: (cpuVisible ? 1 : 0) + (gpus.length - i),
              horizontal: horizontal,
              // The gap rides inside the entrance so the neighbouring pill
              // slides over smoothly when this one appears.
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _SystemBarCard(
                  accent: accent,
                  child: _MeterModule(
                    accent: accent,
                    label: gpus[i].label,
                    series: gpus[i].series,
                  ),
                ),
              ),
            ),
          if (cpuVisible)
            _SystemBarEntrance(
              key: const ValueKey('system-bar-cpu'),
              index: 1,
              horizontal: horizontal,
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _SystemBarCard(
                  accent: accent,
                  child: _MeterModule(
                    accent: accent,
                    label: context.l10n.metricCpu,
                    series: cpu,
                  ),
                ),
              ),
            ),
          _SystemBarEntrance(
            key: const ValueKey('system-bar-clock'),
            index: 0,
            horizontal: horizontal,
            child: _SystemBarCard(
              accent: accent,
              child: _ClockModule(accent: accent, now: now),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaStatusModule extends ConsumerStatefulWidget {
  const _MediaStatusModule({
    required this.accent,
    required this.side,
    required this.playback,
  });

  final WallpaperAccent accent;
  final SystemBarSide side;
  final MprisPlaybackState playback;

  @override
  ConsumerState<_MediaStatusModule> createState() => _MediaStatusModuleState();
}

class _MediaStatusModuleState extends ConsumerState<_MediaStatusModule>
    with SingleTickerProviderStateMixin {
  static const Duration _closeDelay = Duration(milliseconds: 180);
  static const Duration _positionInterval = Duration(seconds: 1);
  static const double _popupGap = 9;

  final OverlayPortalController _portal = OverlayPortalController();
  late final AnimationController _popupMotion;
  late final CurvedAnimation _popupCurve;
  Timer? _closeTimer;
  Timer? _positionTimer;
  bool _hovered = false;
  DateTime _popupNow = DateTime.now();

  @override
  void initState() {
    super.initState();
    _popupMotion = AnimationController(
      vsync: this,
      duration: Motion.cardSettle,
      reverseDuration: Motion.tile,
    );
    _popupCurve = CurvedAnimation(
      parent: _popupMotion,
      curve: Motion.md3EmphasizedDecelerate,
      reverseCurve: Motion.md3EmphasizedAccelerate,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _popupMotion
      ..duration = reduceMotion ? Duration.zero : Motion.cardSettle
      ..reverseDuration = reduceMotion ? Duration.zero : Motion.tile;
  }

  void _show() {
    _closeTimer?.cancel();
    _closeTimer = null;
    if (!_portal.isShowing) {
      _portal.show();
      _popupMotion.forward(from: 0);
    } else if (!_popupMotion.isCompleted) {
      _popupMotion.forward();
    }
    _popupNow = DateTime.now();
    _positionTimer ??= Timer.periodic(_positionInterval, (_) {
      if (mounted && _portal.isShowing) {
        setState(() => _popupNow = DateTime.now());
      }
    });
    if (!_hovered) {
      setState(() => _hovered = true);
    }
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(_closeDelay, () {
      _closeTimer = null;
      unawaited(_close());
    });
  }

  Future<void> _close() async {
    if (!mounted || !_portal.isShowing) {
      return;
    }
    _positionTimer?.cancel();
    _positionTimer = null;
    if (_hovered) {
      setState(() => _hovered = false);
    }
    try {
      await _popupMotion.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || _hovered || !_portal.isShowing) {
      return;
    }
    _portal.hide();
  }

  @override
  void didUpdateWidget(covariant _MediaStatusModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.playback.available) {
      _portal.hide();
      _popupMotion.reset();
      _positionTimer?.cancel();
      _positionTimer = null;
      _hovered = false;
    }
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    _positionTimer?.cancel();
    _popupCurve.dispose();
    _popupMotion.dispose();
    super.dispose();
  }

  Widget _animatePopup(Widget child) {
    final (entryOffset, scaleAlignment) = switch (widget.side) {
      SystemBarSide.top => (const Offset(0, -10), Alignment.topCenter),
      SystemBarSide.bottom => (const Offset(0, 10), Alignment.bottomCenter),
      SystemBarSide.left => (const Offset(-10, 0), Alignment.centerLeft),
      SystemBarSide.right ||
      SystemBarSide.hidden => (const Offset(10, 0), Alignment.centerRight),
    };
    return AnimatedBuilder(
      animation: _popupCurve,
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final progress = _popupCurve.value;
        return Transform.translate(
          offset: Offset.lerp(entryOffset, Offset.zero, progress)!,
          child: Transform.scale(
            scale: 0.94 + 0.06 * progress,
            alignment: scaleAlignment,
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildPopup(
    BuildContext context,
    OverlayChildLayoutInfo layout,
    MediaPlayerService service,
  ) {
    if (layout.childPaintTransform.determinant() == 0) {
      return const SizedBox.shrink();
    }
    final anchor = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final popupSize = Size(
      math.min(_MediaPlaybackPopup.size.width, layout.overlaySize.width),
      math.min(_MediaPlaybackPopup.size.height, layout.overlaySize.height),
    );
    late final Offset preferredOrigin;
    switch (widget.side) {
      case SystemBarSide.top:
        preferredOrigin = Offset(
          anchor.center.dx - popupSize.width / 2,
          anchor.bottom + _popupGap,
        );
      case SystemBarSide.bottom:
        preferredOrigin = Offset(
          anchor.center.dx - popupSize.width / 2,
          anchor.top - popupSize.height - _popupGap,
        );
      case SystemBarSide.left:
        preferredOrigin = Offset(
          anchor.right + _popupGap,
          anchor.center.dy - popupSize.height / 2,
        );
      case SystemBarSide.right:
      case SystemBarSide.hidden:
        preferredOrigin = Offset(
          anchor.left - popupSize.width - _popupGap,
          anchor.center.dy - popupSize.height / 2,
        );
    }
    final origin = Offset(
      preferredOrigin.dx
          .clamp(0.0, math.max(0.0, layout.overlaySize.width - popupSize.width))
          .toDouble(),
      preferredOrigin.dy
          .clamp(
            0.0,
            math.max(0.0, layout.overlaySize.height - popupSize.height),
          )
          .toDouble(),
    );
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: popupSize.width,
      height: popupSize.height,
      child: ShellInputRegion(
        debugLabel: 'System bar media popup',
        child: MouseRegion(
          onEnter: (_) => _show(),
          onExit: (_) => _scheduleClose(),
          child: _animatePopup(
            _MediaPlaybackPopup(
              accent: widget.accent,
              playback: widget.playback,
              now: _popupNow,
              onPrevious: () => unawaited(service.previous()),
              onPlayPause: () => unawaited(service.playPause()),
              onNext: () => unawaited(service.next()),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.read(mediaPlayerServiceProvider);
    return ShellInputRegion(
      debugLabel: 'System bar media control',
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: _portal,
        overlayChildBuilder: (context, layout) =>
            _buildPopup(context, layout, service),
        child: Semantics(
          button: true,
          label: context.l10n.mediaControls,
          child: MouseRegion(
            cursor: ShellMouseCursors.link,
            onEnter: (_) => _show(),
            onExit: (_) => _scheduleClose(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _show,
              child: AnimatedContainer(
                duration: Motion.pill,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: _hovered
                      ? widget.accent.color.withValues(alpha: 0.18)
                      : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.playback.playing
                      ? Icons.graphic_eq_rounded
                      : Icons.music_note_rounded,
                  size: 17,
                  color: widget.accent.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaPlaybackPopup extends StatelessWidget {
  const _MediaPlaybackPopup({
    required this.accent,
    required this.playback,
    required this.now,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
  });

  final WallpaperAccent accent;
  final MprisPlaybackState playback;
  final DateTime now;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  static const Size size = Size(380, 168);

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(24));
    final position = playback.positionAt(now);
    final length = playback.length;
    final progress = length > Duration.zero
        ? (position.inMilliseconds / length.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble()
        : 0.0;
    final secondary = playback.artistLabel.isNotEmpty
        ? playback.artistLabel
        : playback.album.isNotEmpty
        ? playback.album
        : playback.identity;
    return Material(
      type: MaterialType.transparency,
      child: ShellBackdropBlur(
        borderRadius: radius,
        child: Container(
          width: size.width,
          height: size.height,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  accent.color.withValues(alpha: 0.13),
                  ShellColors.panelBackground.withValues(alpha: 0.96),
                ),
                ShellColors.surfaceContainerLow.withValues(alpha: 0.93),
              ],
            ),
            borderRadius: radius,
            border: Border.all(color: accent.color.withValues(alpha: 0.3)),
            boxShadow: const [
              BoxShadow(
                color: ShellColors.shadow,
                blurRadius: 34,
                spreadRadius: 2,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Row(
            children: [
              _MediaArtwork(playback: playback, accent: accent, size: 140),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.graphic_eq_rounded,
                          size: 14,
                          color: accent.color,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          context.l10n.mediaNowPlaying.toUpperCase(),
                          style: ShellText.systemBarCaption.copyWith(
                            color: accent.color,
                            letterSpacing: 1.05,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      playback.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShellText.statusClock.copyWith(fontSize: 16),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShellText.base.copyWith(
                        color: ShellColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    Semantics(
                      value:
                          '${_formatMediaTime(position)} / ${_formatMediaTime(length)}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          minHeight: 4,
                          value: progress,
                          color: accent.color,
                          backgroundColor: ShellColors.surfaceContainerHighest,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _formatMediaTime(position),
                            style: ShellText.systemBarCaption.copyWith(
                              color: ShellColors.textTertiary,
                            ),
                          ),
                        ),
                        Text(
                          _formatMediaTime(length),
                          style: ShellText.systemBarCaption.copyWith(
                            color: ShellColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _MediaControlButton(
                          label: context.l10n.mediaPrevious,
                          icon: Icons.skip_previous_rounded,
                          enabled: playback.canGoPrevious,
                          onPressed: onPrevious,
                        ),
                        const SizedBox(width: 8),
                        _MediaControlButton(
                          label: playback.playing
                              ? context.l10n.mediaPause
                              : context.l10n.mediaPlay,
                          icon: playback.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          prominent: true,
                          enabled: playback.playing
                              ? playback.canPause
                              : playback.canPlay,
                          onPressed: onPlayPause,
                        ),
                        const SizedBox(width: 8),
                        _MediaControlButton(
                          label: context.l10n.mediaNext,
                          icon: Icons.skip_next_rounded,
                          enabled: playback.canGoNext,
                          onPressed: onNext,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaControlButton extends StatefulWidget {
  const _MediaControlButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
    this.prominent = false,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;
  final bool prominent;

  @override
  State<_MediaControlButton> createState() => _MediaControlButtonState();
}

class _MediaControlButtonState extends State<_MediaControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final size = widget.prominent ? 32.0 : 28.0;
    return Tooltip(
      message: widget.label,
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: widget.label,
        child: MouseRegion(
          cursor: widget.enabled
              ? ShellMouseCursors.link
              : ShellMouseCursors.normal,
          onEnter: widget.enabled
              ? (_) => setState(() => _hovered = true)
              : null,
          onExit: widget.enabled
              ? (_) => setState(() => _hovered = false)
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onPressed : null,
            child: AnimatedContainer(
              duration: Motion.tile,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: widget.prominent
                    ? accent.primary
                    : _hovered
                    ? ShellColors.surfaceContainerHighest
                    : ShellColors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.icon,
                size: widget.prominent ? 20 : 17,
                color: widget.enabled
                    ? widget.prominent
                          ? accent.onPrimary
                          : ShellColors.textPrimary
                    : ShellColors.glyphInactive,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaArtwork extends ConsumerWidget {
  const _MediaArtwork({
    required this.playback,
    required this.accent,
    required this.size,
  });

  final MprisPlaybackState playback;
  final WallpaperAccent accent;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uri = Uri.tryParse(playback.artUrl);
    Widget artwork = _MediaArtworkFallback(accent: accent);
    if (uri?.scheme == 'file') {
      String? path;
      try {
        path = uri!.toFilePath();
      } on UnsupportedError {
        path = null;
      }
      if (path != null) {
        final bytes = ref.watch(notificationStaticImageProvider(path)).value;
        if (bytes != null) {
          artwork = Image.memory(
            bytes,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            cacheWidth: 320,
            cacheHeight: 320,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _MediaArtworkFallback(accent: accent),
          );
        }
      }
    } else if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      artwork = Image.network(
        playback.artUrl,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        cacheWidth: 320,
        cacheHeight: 320,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _MediaArtworkFallback(accent: accent),
      );
    }
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: artwork,
        ),
      ),
    );
  }
}

class _MediaArtworkFallback extends StatelessWidget {
  const _MediaArtworkFallback({required this.accent});

  final WallpaperAccent accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.color.withValues(alpha: 0.64),
            ShellColors.surfaceContainerHighest,
          ],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 48,
          color: ShellColors.textPrimary,
        ),
      ),
    );
  }
}

String _formatMediaTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 7 * 24 * 60 * 60);
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60) % 60;
  final remainder = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}

/// Date caption plus the ticking clock. The caption re-tints with the
/// wallpaper accent; minute changes crossfade with a small upward slide.
class _ClockModule extends StatelessWidget {
  const _ClockModule({required this.accent, required this.now});

  final WallpaperAccent accent;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final time = localizedTime(context, now);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: Motion.wallpaperReveal,
          curve: Motion.standard,
          style: ShellText.systemBarCaption.copyWith(
            color: accent.captionColor,
          ),
          child: Text(localizedShortDate(context, now)),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: Motion.cardSettle,
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.25),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Text(
            time,
            key: ValueKey<String>(time),
            style: ShellText.systemBarValue,
          ),
        ),
      ],
    );
  }
}

/// One load meter: a caption tag naming the source, a sparkline of the recent
/// history, the animated percentage, and an optional direct sensor reading.
/// Identity comes from the tag, never from the line color alone.
class _MeterModule extends StatelessWidget {
  const _MeterModule({
    required this.accent,
    required this.label,
    required this.series,
  });

  final WallpaperAccent accent;
  final String label;
  final LoadSeries series;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: Motion.wallpaperReveal,
          curve: Motion.standard,
          style: ShellText.systemBarCaption.copyWith(
            color: accent.captionColor,
          ),
          child: Text(label),
        ),
        const SizedBox(width: 6),
        RepaintBoundary(
          child: CustomPaint(
            size: const Size(38, 14),
            painter: _SparklinePainter(
              history: series.history,
              accent: accent.color,
            ),
          ),
        ),
        const SizedBox(width: 7),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: series.current ?? 0.0),
          duration: Motion.pill,
          curve: Motion.standard,
          builder: (context, value, _) => SizedBox(
            width: 34,
            child: Text.rich(
              TextSpan(
                text: context.l10n.numberValue((value * 100).round()),
                style: ShellText.systemBarValue,
                children: [
                  TextSpan(
                    text: context.l10n.percentSign,
                    style: ShellText.systemBarCaption.copyWith(
                      color: accent.captionColor,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
        ),
        if (series.temperatureC case final temperature?) ...[
          const SizedBox(width: 7),
          _TemperatureValue(accent: accent, temperatureC: temperature),
        ],
      ],
    );
  }
}

class _TemperatureValue extends StatelessWidget {
  const _TemperatureValue({required this.accent, required this.temperatureC});

  final WallpaperAccent accent;
  final double temperatureC;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: context.l10n.numberValue(temperatureC.round()),
        style: ShellText.systemBarValue,
        children: [
          TextSpan(
            text: context.l10n.celsiusUnit,
            style: ShellText.systemBarCaption.copyWith(
              color: accent.captionColor,
            ),
          ),
        ],
      ),
      maxLines: 1,
    );
  }
}

/// A borderless translucent pill hosting one system bar module. The softly
/// top-lit gradient animates between wallpaper accents at the wallpaper
/// reveal's pace so the bar re-themes as part of the same gesture.
class _SystemBarCard extends StatelessWidget {
  const _SystemBarCard({required this.accent, required this.child});

  final WallpaperAccent accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(999));
    return ShellBackdropBlur(
      borderRadius: radius,
      child: AnimatedContainer(
        duration: Motion.wallpaperReveal,
        curve: Motion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [accent.cardFillTop, accent.cardFill],
          ),
          borderRadius: radius,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// One-shot mount transition for a pill: it springs in from the trailing
/// edge, staggered by [index], while its main-axis extent grows so the
/// neighbouring pills glide instead of jumping. Costs nothing once settled.
class _SystemBarEntrance extends StatefulWidget {
  const _SystemBarEntrance({
    required this.index,
    required this.horizontal,
    required this.child,
    super.key,
  });

  final int index;
  final bool horizontal;
  final Widget child;

  @override
  State<_SystemBarEntrance> createState() => _SystemBarEntranceState();
}

class _SystemBarEntranceState extends State<_SystemBarEntrance>
    with SingleTickerProviderStateMixin {
  static const double _slideDistance = 12.0;
  static const Duration _stagger = Duration(milliseconds: 60);

  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(_stagger * widget.index, () {
      if (mounted) {
        springTo(_controller, 1.0, telemetryLabel: 'system_bar_entrance');
      }
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final travel = (1.0 - t) * _slideDistance;
        return Align(
          alignment: widget.horizontal
              ? Alignment.centerRight
              : Alignment.bottomCenter,
          widthFactor: widget.horizontal ? unit(t) : null,
          heightFactor: widget.horizontal ? null : unit(t),
          child: Opacity(
            opacity: unit(t),
            child: Transform.translate(
              offset: widget.horizontal
                  ? Offset(travel, 0.0)
                  : Offset(0.0, travel),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Paints the CPU load history as an accent polyline over a gradient fill.
/// The newest sample hugs the trailing edge and the line slides left as the
/// window fills. Plain path drawing only — no mask filters, no save layers.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.history, required this.accent});

  final List<double> history;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final points = sparklinePoints(history, size);
    if (points.length < 2) {
      return;
    }
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      line.lineTo(point.dx, point.dy);
    }
    final fill = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.35),
            accent.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.history != history || oldDelegate.accent != accent;
  }
}

/// Maps [history] (oldest first, 0-1 values) onto sparkline points inside
/// [size]. The newest sample sits on the right edge; a partial history leaves
/// the left side empty so the line grows leftward as samples arrive.
@visibleForTesting
List<Offset> sparklinePoints(List<double> history, Size size) {
  if (history.isEmpty || size.isEmpty) {
    return const <Offset>[];
  }
  final step = size.width / (LoadSeries.capacity - 1);
  return List<Offset>.generate(history.length, (index) {
    final fromEnd = history.length - 1 - index;
    return Offset(
      size.width - fromEnd * step,
      size.height * (1.0 - history[index].clamp(0.0, 1.0)),
    );
  }, growable: false);
}
