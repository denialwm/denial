part of 'desktop_system_bar.dart';

/// Rebuilds only the media card when MPRIS state changes.
class _MediaStatusProviderModule extends ConsumerWidget {
  const _MediaStatusProviderModule({required this.accent, required this.side});

  final WallpaperAccent accent;
  final SystemBarSide side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(
      mediaPlaybackProvider.select((media) {
        final playback = media.value;
        return (
          available: playback?.available ?? false,
          playing: playback?.playing ?? false,
        );
      }),
    );
    return _MediaStatusModule(
      accent: accent,
      side: side,
      available: summary.available,
      playing: summary.playing,
    );
  }
}

/// Rebuilds only the battery card on its slower status cadence.
class _BatteryStatusCard extends ConsumerWidget {
  const _BatteryStatusCard({required this.accent, required this.onPressed});

  final WallpaperAccent accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _BatteryActionCard(
      accent: accent,
      status: ref.watch(batteryProvider),
      onPressed: onPressed,
    );
  }
}

/// Rebuilds the GPU group without rebuilding the neighbouring cards.
class _GpuStatusCards extends ConsumerWidget {
  const _GpuStatusCards({
    required this.accent,
    required this.horizontal,
    required this.cpuVisible,
  });

  final WallpaperAccent accent;
  final bool horizontal;
  final bool cpuVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gpus = ref.watch(gpuUsageProvider);
    return Flex(
      direction: horizontal ? Axis.horizontal : Axis.vertical,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < gpus.length; i += 1)
          _SystemBarEntrance(
            key: ValueKey('system-bar-gpu-${gpus[i].id}'),
            index: (cpuVisible ? 1 : 0) + (gpus.length - i),
            horizontal: horizontal,
            child: Padding(
              padding: horizontal
                  ? const EdgeInsets.only(right: DesktopSystemBar._cardGap)
                  : const EdgeInsets.only(bottom: DesktopSystemBar._cardGap),
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
      ],
    );
  }
}

/// Rebuilds the CPU meter only when a fresh sample is published.
class _CpuStatusCard extends ConsumerWidget {
  const _CpuStatusCard({required this.accent, required this.horizontal});

  final WallpaperAccent accent;
  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SystemBarEntrance(
      key: const ValueKey('system-bar-cpu'),
      index: 1,
      horizontal: horizontal,
      child: Padding(
        padding: horizontal
            ? const EdgeInsets.only(right: DesktopSystemBar._cardGap)
            : const EdgeInsets.only(bottom: DesktopSystemBar._cardGap),
        child: _SystemBarCard(
          accent: accent,
          child: _MeterModule(
            accent: accent,
            label: context.l10n.metricCpu,
            series: ref.watch(cpuUsageProvider),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds the clock card only at the minute boundary.
class _ClockStatusModule extends ConsumerWidget {
  const _ClockStatusModule({required this.accent});

  final WallpaperAccent accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    return _ClockModule(accent: accent, now: now);
  }
}

class _MediaStatusModule extends ConsumerStatefulWidget {
  const _MediaStatusModule({
    required this.accent,
    required this.side,
    required this.available,
    required this.playing,
  });

  final WallpaperAccent accent;
  final SystemBarSide side;
  final bool available;
  final bool playing;

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
    if (!widget.available) {
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
    MprisPlaybackState playback,
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
              playback: playback,
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
    final playback = _portal.isShowing
        ? ref.watch(mediaPlaybackProvider).value ?? service.current
        : service.current;
    return ShellInputRegion(
      debugLabel: 'System bar media control',
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: _portal,
        overlayChildBuilder: (context, layout) =>
            _buildPopup(context, layout, service, playback),
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
                      ? context.shellTheme.accent.withValues(alpha: 0.18)
                      : ShellMediaColors.transparentDark,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.playing
                      ? Icons.graphic_eq_rounded
                      : Icons.music_note_rounded,
                  size: 17,
                  color: context.shellTheme.accent,
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
    final theme = ShellTheme.of(context);
    final radius = theme.borderRadius(24);
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
        blur: theme.effectiveCardOpacity < 1.0,
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
                theme.cardColor(
                  Color.alphaBlend(
                    context.shellTheme.accent.withValues(alpha: 0.13),
                    context.shellColors.panelBackground.withValues(alpha: 1),
                  ),
                ),
                theme.cardColor(context.shellColors.surfaceContainerLow),
              ],
            ),
            borderRadius: radius,
            border: Border.all(
              color: context.shellTheme.accent.withValues(alpha: 0.3),
            ),
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
                          color: context.shellTheme.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          context.l10n.mediaNowPlaying.toUpperCase(),
                          style: ShellText.systemBarCaption.copyWith(
                            color: context.shellTheme.accent,
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
                        color: context.shellColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    Semantics(
                      value:
                          '${_formatMediaTime(position)} / ${_formatMediaTime(length)}',
                      child: ClipRRect(
                        borderRadius: context.shellTheme.borderRadius(99),
                        child: LinearProgressIndicator(
                          minHeight: 4,
                          value: progress,
                          color: context.shellTheme.accent,
                          backgroundColor:
                              context.shellColors.surfaceContainerHighest,
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
                              color: context.shellColors.textTertiary,
                            ),
                          ),
                        ),
                        Text(
                          _formatMediaTime(length),
                          style: ShellText.systemBarCaption.copyWith(
                            color: context.shellColors.textTertiary,
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
                    ? context.shellColors.surfaceContainerHighest
                    : context.shellColors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.icon,
                size: widget.prominent ? 20 : 17,
                color: widget.enabled
                    ? widget.prominent
                          ? accent.onPrimary
                          : context.shellColors.textPrimary
                    : context.shellColors.glyphInactive,
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
          borderRadius: context.shellTheme.borderRadius(18),
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
            context.shellTheme.accent.withValues(alpha: 0.64),
            context.shellColors.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 48,
          color: context.shellColors.textPrimary,
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
