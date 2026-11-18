part of 'lock_screen_layer.dart';

class _LockBackdrop extends ConsumerStatefulWidget {
  const _LockBackdrop({this.output, this.onPainted});

  final DisplayOutput? output;

  /// Reports the whole backdrop, blur and dim included, after it or the
  /// wallpaper inside it repaints.
  final ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  ConsumerState<_LockBackdrop> createState() => _LockBackdropState();
}

class _LockBackdropState extends ConsumerState<_LockBackdrop> {
  final _boundary = GlobalKey();

  /// The wallpaper repaints within its own boundary, which leaves this one's
  /// paint untouched.
  void _wallpaperPainted(RenderRepaintBoundary _) {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is RenderRepaintBoundary) widget.onPainted?.call(boundary);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      shellSettingsProvider.select((value) => value.lockScreen),
    );
    final output = widget.output;
    final onPainted = widget.onPainted;
    final custom = WallpaperResource.fromPersistenceValue(settings.wallpaper);
    final desktopWallpaper = output == null
        ? ShellWallpaper(
            onPainted: onPainted == null ? null : _wallpaperPainted,
          )
        : ShellOutputWallpaper(output: output);
    return _PaintedBoundary(
      key: _boundary,
      onPainted: onPainted,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _LockFillPainter(color: context.shellColors.background),
          ),
          ClipRect(
            child: ImageFiltered(
              key: ValueKey<String>(
                output == null
                    ? 'lock-wallpaper-blur'
                    : 'lock-wallpaper-blur-${output.monitorId}',
              ),
              imageFilter: ImageFilter.blur(
                sigmaX: settings.blurRadius,
                sigmaY: settings.blurRadius,
                tileMode: TileMode.clamp,
              ),
              child: custom == null
                  ? desktopWallpaper
                  : LayoutBuilder(
                      builder: (context, constraints) => Image(
                        image: wallpaperImageProvider(
                          custom,
                          targetPixelSize:
                              output?.pixelSize ??
                              constraints.biggest *
                                  MediaQuery.devicePixelRatioOf(context),
                        ),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => desktopWallpaper,
                      ),
                    ),
            ),
          ),
          CustomPaint(
            painter: _LockFillPainter(
              color: ShellMediaColors.darkness.withValues(
                alpha: settings.dimAmount,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaintedBoundary extends SingleChildRenderObjectWidget {
  const _PaintedBoundary({super.key, this.onPainted, super.child});

  final ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintedBoundary()..onPainted = onPainted;

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPaintedBoundary).onPainted = onPainted;
  }
}

class _RenderPaintedBoundary extends RenderRepaintBoundary {
  ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPainted?.call(this);
  }
}

/// Uses round-rect geometry with an imperceptible radius so the backdrop obeys
/// lock-stage transforms without entering Impeller's UberSDF rect path.
class _LockFillPainter extends CustomPainter {
  const _LockFillPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(0.01)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _LockFillPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _LockStatusIcons extends StatelessWidget {
  const _LockStatusIcons({
    required this.power,
    required this.cpu,
    required this.gpus,
    required this.desktop,
  });

  final ShellPowerStatus power;
  final LoadSeries cpu;
  final List<GpuLoad> gpus;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    if (desktop) {
      return Positioned(
        top: math.max(24.0, topPadding + 18.0),
        right: 34,
        child: _DesktopLockStatusBar(cpu: cpu, gpus: gpus),
      );
    }
    // The operator sits opposite the icons, as far in from the left edge as
    // the battery is from the right.
    return Positioned(
      top: math.max(22.0, topPadding + 18.0),
      left: 28,
      right: 28,
      child: Opacity(
        opacity: 0.92,
        child: Row(
          children: [
            const Expanded(child: _LockOperatorName()),
            const SizedBox(width: 16),
            StatusIconCluster(battery: power.batteryStatus),
          ],
        ),
      ),
    );
  }
}

class _LockOperatorName extends ConsumerWidget {
  const _LockOperatorName();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(
      mobileNetworkProvider.select(
        (discovery) => discovery.isLoading || discovery.hasError
            ? ''
            : discovery.value?.operatorName ?? '',
      ),
    );
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: ShellText.base.copyWith(
        color: context.shellColors.textPrimary,
        fontSize: 15,
        height: 1,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    );
  }
}

class _DesktopLockStatusBar extends StatelessWidget {
  const _DesktopLockStatusBar({required this.cpu, required this.gpus});

  final LoadSeries cpu;
  final List<GpuLoad> gpus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.lockPerformanceStatusLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellTheme.panelColor(
            context.shellColors.panelBackground,
          ),
          borderRadius: context.shellTheme.borderRadius(16),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DesktopPerformanceMetric(
                icon: Icons.memory_rounded,
                label: l10n.lockCpuLabel,
                series: cpu,
              ),
              for (final gpu in gpus) ...[
                const SizedBox(width: 8),
                _DesktopPerformanceMetric(
                  icon: Icons.developer_board_rounded,
                  label: gpu.label,
                  series: gpu.series,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopPerformanceMetric extends StatelessWidget {
  const _DesktopPerformanceMetric({
    required this.icon,
    required this.label,
    required this.series,
  });

  final IconData icon;
  final String label;
  final LoadSeries series;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final usage = series.current;
    final value = usage == null
        ? l10n.lockMetricUnavailable
        : l10n.settingsPercent((usage * 100).round());
    final temperature = series.temperatureC;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: context.shellTheme.borderRadius(11),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: context.shellColors.textTertiary),
            const SizedBox(width: 7),
            Text(
              l10n.lockPerformanceMetric(label, value),
              style: ShellText.cardTitle.copyWith(fontSize: 11),
            ),
            if (temperature != null) ...[
              const SizedBox(width: 7),
              Text(
                l10n.lockTemperature(temperature.round()),
                style: ShellText.base.copyWith(
                  color: context.shellColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Where the mobile lock face lays out its clock and notifications. A phone
/// and a portrait tablet keep the clock near the top, centred. A landscape
/// tablet keeps a third for the PIN pad on the side the user chose and puts
/// the clock where the user placed it in the rest, at the tablet's own size.
class _MobileFace {
  const _MobileFace._({
    required this.area,
    required this.pad,
    required this.clock,
    required this.scale,
    required this.tablet,
  });

  factory _MobileFace.of(
    Size size,
    ShellLockScreenSettings settings, {
    required bool padReserved,
  }) {
    if (!isTablet(size)) {
      final top = math.max(48.0, size.height * 0.25 - 96.0);
      final height = math.min(250.0, size.height * 0.34);
      return _MobileFace._(
        area: Offset.zero & size,
        pad: null,
        clock: Rect.fromLTWH(0, top, size.width, height),
        scale: settings.clockScale,
        tablet: false,
      );
    }
    return _MobileFace.tablet(
      size,
      padSide: settings.tabletPadSide,
      padReserved: padReserved,
      clockX: settings.tabletClockX,
      clockY: settings.tabletClockY,
      scale: settings.tabletClockScale,
    );
  }

  factory _MobileFace.tablet(
    Size size, {
    required LockPadSide padSide,
    required bool padReserved,
    required double clockX,
    required double clockY,
    required double scale,
  }) {
    final third = size.width / 3;
    final pad = !padReserved
        ? null
        : padSide == LockPadSide.left
        ? Rect.fromLTWH(0, 0, third, size.height)
        : Rect.fromLTWH(size.width - third, 0, third, size.height);
    final area = pad == null
        ? Offset.zero & size
        : padSide == LockPadSide.left
        ? Rect.fromLTRB(third, 0, size.width, size.height)
        : Rect.fromLTRB(0, 0, size.width - third, size.height);
    final s = scale
        .clamp(
          ShellLockScreenSettings.minimumTabletClockScale,
          ShellLockScreenSettings.maximumTabletClockScale,
        )
        .toDouble();
    final block = Size(
      math.min(area.width, _tabletClockWidth),
      math.min(250.0, size.height * 0.34),
    );
    final halfWidth = block.width * s / 2;
    final halfHeight = block.height * s / 2;
    final x = _within(
      area.left + clockX * area.width,
      area.left + halfWidth,
      area.right - halfWidth,
    );
    // The lock glyph keeps the top; the date and battery row sit above
    // the time.
    final y = _within(
      clockY * size.height,
      size.height / 16 + 30.0 + _detailsAbove * s + halfHeight,
      size.height * 0.95 - halfHeight,
    );
    return _MobileFace._(
      area: area,
      pad: pad,
      clock: Rect.fromCenter(
        center: Offset(x, y),
        width: block.width,
        height: block.height,
      ),
      scale: s,
      tablet: true,
    );
  }

  /// A landscape screen whose shorter side is a tablet's.
  static bool isTablet(Size size) =>
      size.width > size.height && size.shortestSide >= 600.0;

  /// The tablet clock block's width before scaling: wide enough for the
  /// time and date at any size.
  static const double _tabletClockWidth = 480.0;

  /// About how far the date and battery row reach above the time block.
  static const double _detailsAbove = 90.0;

  static double _within(double value, double low, double high) =>
      low > high ? (low + high) / 2 : value.clamp(low, high).toDouble();

  /// Where the clock and notifications go: the whole screen, or the part
  /// beside the PIN pad.
  final Rect area;

  /// The PIN pad's third, when the lock keeps one.
  final Rect? pad;

  /// The time block before [scale], which scales it about its centre.
  final Rect clock;
  final double scale;
  final bool tablet;

  double get clockBottom => clock.center.dy + clock.height * scale / 2;

  /// The top of the date and battery row above the time.
  double get clockReach =>
      clock.center.dy - clock.height * scale / 2 - _detailsAbove * scale;

  /// Where notifications go, and whether that is above the clock. A
  /// phone's go under the clock, down to the fingerprint ring. A tablet's
  /// take the area narrowed on both sides, under the clock down to near the
  /// bottom, or above it when more room is there.
  (Rect, bool) notifications(
    Size size, {
    required double gap,
    required EdgeInsets padding,
  }) {
    final sideMargin = tablet ? area.width * _tabletSideMargin : 0.0;
    var top = clockBottom + gap;
    var bottom = size.height * (tablet ? 0.92 : 0.7);
    var above = false;
    if (tablet) {
      final aboveTop = size.height / 16 + 30.0;
      final aboveBottom = clockReach - gap;
      if (aboveBottom - aboveTop > bottom - top) {
        above = true;
        top = aboveTop;
        bottom = aboveBottom;
      }
    }
    return (
      Rect.fromLTRB(
        math.max(padding.left, area.left + sideMargin),
        top,
        math.min(size.width - padding.right, area.right - sideMargin),
        math.max(top, bottom),
      ),
      above,
    );
  }

  /// The share of a tablet's area notifications leave free on each side.
  static const double _tabletSideMargin = 0.08;

  /// The clock's centre as fractions of the area's width and the screen's
  /// height, as the settings keep it.
  (double, double) clockFractions(Size size) => (
    area.width > 0 ? (clock.center.dx - area.left) / area.width : 0.5,
    size.height > 0 ? clock.center.dy / size.height : 0.5,
  );
}

class _LockClockBlock extends StatelessWidget {
  const _LockClockBlock({
    required this.clock,
    required this.desktop,
    required this.scale,
    required this.showSystemStatus,
    this.caption,
    this.block,
    this.parts = const {
      HomeClockPart.time,
      HomeClockPart.date,
      HomeClockPart.status,
    },
  });

  final HomeClockInfo clock;
  final bool desktop;
  final double scale;
  final bool showSystemStatus;

  /// A line over the date.
  final String? caption;

  /// Mobile: the time block, from [_MobileFace.clock].
  final Rect? block;

  /// Mobile draws the time under the wallpaper's subject and the date and
  /// battery row over it, as two blocks with the same layout.
  final Set<HomeClockPart> parts;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final block =
        this.block ??
        Rect.fromLTRB(
          math.max(48.0, size.width * 0.065),
          math.max(72.0, size.height * 0.22),
          size.width * 0.52,
          math.max(72.0, size.height * 0.22) +
              math.min(280.0, size.height * 0.36),
        );

    // Mobile stretches the time upward with the date on top, painted above
    // the block, which reserves room for them.
    final reserve = desktop ? 0.0 : block.height;
    return Positioned(
      left: block.left,
      width: block.width,
      top: block.top - reserve,
      height: block.height + reserve,
      child: Padding(
        padding: EdgeInsets.only(top: reserve),
        child: Transform.scale(
          alignment: Alignment.center,
          scale: scale,
          child: Padding(
            padding: desktop
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 24),
            child: RepaintBoundary(
              child: HomeClockWidget(
                clock: clock,
                showStatus: showSystemStatus,
                timeStretch: desktop ? 1.0 : 2.0,
                detailsAbove: !desktop,
                dateColor: desktop
                    ? ShellMediaColors.lightForegroundSecondary
                    : ShellMediaColors.lightForeground,
                caption: caption,
                parts: parts,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The lock glyph centred near the top of the mobile face.
class _LockGlyph extends StatelessWidget {
  const _LockGlyph({required this.area});

  static const double _size = 26.0;

  /// The part of the screen it centres in.
  final Rect area;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: area.left,
      width: area.width,
      top: MediaQuery.sizeOf(context).height / 16 - _size / 2,
      child: const Center(
        child: Icon(
          Icons.lock_rounded,
          size: _size,
          color: ShellMediaColors.lightForeground,
        ),
      ),
    );
  }
}

/// The swipe-up pill of the mobile face: as wide as the navigation pill and
/// centred where it sits. It stays put and fades out as the face is swiped
/// away.
class _LockSwipePill extends StatelessWidget {
  const _LockSwipePill({
    required this.face,
    required this.fadeDistance,
    required this.area,
  });

  final ValueListenable<Offset> face;
  final double fadeDistance;

  /// The part of the screen it centres in.
  final Rect area;

  @override
  Widget build(BuildContext context) {
    // BottomGestureHandle centres the navigation pill below the top 20 px of
    // its hit area.
    return Positioned(
      left: area.left,
      width: area.width,
      bottom: ReferenceShellMetrics.gestureBottomInset,
      height: ReferenceShellMetrics.gestureHitHeight,
      child: Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Center(
          child: IgnorePointer(
            child: CustomPaint(
              size: const Size(180, 5),
              painter: _LockSwipePillPainter(
                face: face,
                fadeDistance: fadeDistance,
                color: context.shellColors.gesturePill,
                radius: context.shellTheme.borderRadius(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockSwipePillPainter extends CustomPainter {
  _LockSwipePillPainter({
    required this.face,
    required this.fadeDistance,
    required this.color,
    required this.radius,
  }) : super(repaint: face);

  final ValueListenable<Offset> face;
  final double fadeDistance;
  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = 1.0 - _swiped(face, fadeDistance);
    if (alpha <= 0.0) {
      return;
    }
    canvas.drawRRect(
      radius.toRRect(Offset.zero & size),
      Paint()
        ..isAntiAlias = true
        ..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _LockSwipePillPainter oldDelegate) =>
      oldDelegate.face != face ||
      oldDelegate.fadeDistance != fadeDistance ||
      oldDelegate.color != color ||
      oldDelegate.radius != radius;
}

/// How far the face has been swiped toward gone for marks that stay put:
/// 0 at rest, 1 once it has moved [fadeDistance] up.
double _swiped(ValueListenable<Offset> face, double fadeDistance) =>
    fadeDistance > 0.0 ? (-face.value.dy / fadeDistance).clamp(0.0, 1.0) : 0.0;

/// Depth effect: the subject cut out of the lock wallpaper, drawn over the
/// clock so the clock sits behind it. The mask comes from the optional
/// `wallpaper-depth` program ([wallpaperDepthProvider]):
/// `lock-mask.png` (alpha marks the subject, in wallpaper space) with a
/// sidecar naming the wallpaper it belongs to. This layer is the backdrop
/// again, kept where the mask is, with the mask blurred like the backdrop:
/// away from the clock it matches the backdrop under it exactly.
class _LockDepthForeground extends ConsumerStatefulWidget {
  const _LockDepthForeground({this.spread = 0.0});

  /// Blur beyond the backdrop's, in logical pixels: a spread mask lights
  /// the scene around the subject instead of cutting the subject out.
  final double spread;

  @override
  ConsumerState<_LockDepthForeground> createState() =>
      _LockDepthForegroundState();
}

class _LockDepthForegroundState extends ConsumerState<_LockDepthForeground> {
  String? _wallpaper;
  int? _masks;
  ui.Image? _source;
  ui.Image? _mask;
  (double, Size)? _maskKey;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _source?.dispose();
    _mask?.dispose();
    super.dispose();
  }

  void _forget() {
    _generation++;
    _source?.dispose();
    _mask?.dispose();
    _source = null;
    _mask = null;
    _maskKey = null;
  }

  Future<void> _load(String wallpaper) async {
    final generation = _generation;
    ui.Image? image;
    try {
      final directory = wallpaperDepthDirectory(ref.read(runtimePathsProvider));
      final sidecar = jsonDecode(
        await File('$directory/lock-mask.json').readAsString(),
      );
      if (sidecar is Map && sidecar['wallpaper'] == wallpaper) {
        final codec = await ui.instantiateImageCodec(
          await File('$directory/lock-mask.png').readAsBytes(),
        );
        image = (await codec.getNextFrame()).image;
        codec.dispose();
      }
    } on Object {
      image = null;
    }
    if (!mounted || generation != _generation) {
      image?.dispose();
      return;
    }
    setState(() => _source = image);
  }

  /// Blurs the mask once with the backdrop's blur, in mask pixels.
  Future<void> _bake(ui.Image source, double sigma, Size size) async {
    final key = (sigma, size);
    _maskKey = key;
    final generation = _generation;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      source,
      Offset.zero,
      Paint()
        ..imageFilter = ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    final picture = recorder.endRecording();
    final result = await picture.toImage(source.width, source.height);
    picture.dispose();
    if (!mounted || generation != _generation || _maskKey != key) {
      result.dispose();
      return;
    }
    setState(() {
      _mask?.dispose();
      _mask = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      shellSettingsProvider.select((value) => value.lockScreen),
    );
    final outputName = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context))
          .select((layout) => layout?.mainOutput?.name),
    );
    final assignment = ref.watch(
      wallpaperControllerProvider.select((state) => state.assignment),
    );
    final custom = WallpaperResource.fromPersistenceValue(settings.wallpaper);
    final resource =
        custom ??
        (outputName == null
            ? assignment.all
            : assignment.forOutput(outputName));
    final alignment = custom != null
        ? const WallpaperSpanAlignment()
        : outputName == null
        ? assignment.spanAlignment
        : assignment.alignmentForOutput(outputName);
    final zoom = custom != null
        ? 1.0
        : outputName == null
        ? assignment.zoom
        : assignment.zoomForOutput(outputName);
    final wallpaper = resource.kind == WallpaperResourceKind.file
        ? resource.path
        : null;
    // A new mask may be for this wallpaper: read the cache again.
    final masks = ref.watch(wallpaperDepthProvider);
    if (wallpaper != _wallpaper || masks != _masks) {
      _wallpaper = wallpaper;
      _masks = masks;
      _forget();
      if (wallpaper != null) {
        _load(wallpaper);
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final source = _source;
        final size = constraints.biggest;
        if (source == null || size.isEmpty) {
          return const SizedBox.shrink();
        }
        // Covered, then zoomed about the alignment's point, as the
        // wallpaper is drawn.
        final cover =
            math.max(size.width / source.width, size.height / source.height) *
            zoom;
        final sigma = (settings.blurRadius + widget.spread) / cover;
        if (sigma > 0.0 && _maskKey != (sigma, size)) {
          _bake(source, sigma, size);
        }
        final mask = sigma > 0.0 ? _mask : source;
        if (mask == null) {
          return const SizedBox.shrink();
        }
        final matrix = Matrix4.diagonal3Values(cover, cover, 1.0)
          ..setTranslationRaw(
            (size.width - source.width * cover) * (alignment.x + 1) / 2,
            (size.height - source.height * cover) * (alignment.y + 1) / 2,
            0.0,
          );
        return IgnorePointer(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (_) => ImageShader(
              mask,
              TileMode.clamp,
              TileMode.clamp,
              matrix.storage,
              filterQuality: FilterQuality.medium,
            ),
            child: const _LockBackdrop(),
          ),
        );
      },
    );
  }
}

/// The phone's notifications under the clock, as many as fit, newest first,
/// unless the lock screen settings hide them. They slide with the face and
/// let drags through to the swipe; a tap asks for the PIN, then opens.
class _LockNotifications extends ConsumerWidget {
  const _LockNotifications({required this.face, required this.onOpen});

  /// Where they go: [_MobileFace.notifications].
  final _MobileFace face;

  /// The tapped group's key.
  final ValueChanged<String> onOpen;

  static const int _shown = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(desktopNotificationsProvider);
    final notifications = ref.read(desktopNotificationsProvider.notifier);
    if (state.lockPreview == NotificationPreviewMode.hidden) {
      return const SizedBox.shrink();
    }
    // The shade's history: a notification stays after its popup is gone.
    // A stacked group is one card with its app and count.
    final groups = state.groups.take(_shown).toList(growable: false);
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final metrics = MobileUiMetrics.of(context);
    final (rect, above) = face.notifications(
      MediaQuery.sizeOf(context),
      gap: metrics.visual(24),
      padding: MediaQuery.viewPaddingOf(context),
    );
    return Positioned.fromRect(
      rect: rect,
      child: ClipRect(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          // Above the clock, the newest card sits next to it.
          reverse: above,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final group in above ? groups.reversed : groups)
                Padding(
                  key: ValueKey(group.key),
                  padding: EdgeInsets.fromLTRB(
                    metrics.visual(MobileNotificationCard.horizontalMargin),
                    0,
                    metrics.visual(MobileNotificationCard.horizontalMargin),
                    metrics.visual(MobileNotificationMetrics.rowSpacing),
                  ),
                  // Swiped toward the start edge, it leaves the history; a
                  // swipe up still opens the phone.
                  child: Dismissible(
                    key: ValueKey(group.key),
                    direction: group.clearable
                        ? DismissDirection.endToStart
                        : DismissDirection.none,
                    confirmDismiss: (_) async {
                      // The controller drops the rows when it can.
                      notifications.dismissGroupFromHistory(group.key);
                      return false;
                    },
                    child: _LockNotificationPress(
                      onTap: () {
                        ref.read(hapticsServiceProvider).pulse();
                        onOpen(group.key);
                      },
                      child: MobileNotificationCard(
                        notification: group.newest.notification,
                        group: group,
                        interactive: false,
                        previewMode: state.lockPreview,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card gives under the finger and springs back as the face leaves for
/// the PIN.
class _LockNotificationPress extends StatefulWidget {
  const _LockNotificationPress({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_LockNotificationPress> createState() => _LockNotificationPressState();
}

class _LockNotificationPressState extends State<_LockNotificationPress>
    with SingleTickerProviderStateMixin {
  static const double _pressedScale = 0.95;

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: const Duration(milliseconds: 380),
  );

  // The release overshoots a little past full size before settling.
  late final Animation<double> _scale = CurvedAnimation(
    parent: _press,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeInBack,
  ).drive(Tween<double>(begin: 1.0, end: _pressedScale));

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _release() => _press.reverse();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      onTap: widget.onTap,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          _LiftTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<_LiftTapGestureRecognizer>(
                _LiftTapGestureRecognizer.new,
                (recognizer) => recognizer
                  ..onTapDown = ((_) => _press.forward())
                  ..onTapCancel = _release
                  ..onTap = () {
                    // A quick tap still shows the press before the release.
                    _press.forward().whenCompleteOrCancel(_release);
                    widget.onTap();
                  },
              ),
        },
        child: ScaleTransition(scale: _scale, child: widget.child),
      ),
    );
  }
}

/// Takes the tap as the finger lifts instead of waiting out the face's
/// double tap, so the PIN comes up at once.
class _LiftTapGestureRecognizer extends TapGestureRecognizer {
  @override
  void handlePrimaryPointer(PointerEvent event) {
    super.handlePrimaryPointer(event);
    if (event is PointerUpEvent) resolve(GestureDisposition.accepted);
  }
}
