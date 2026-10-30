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
    return _PaintedBoundary(
      key: _boundary,
      onPainted: onPainted,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _LockFillPainter(color: context.shellColors.background),
          ),
          if (settings.useSystemWallpaper)
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
                  // The lock wallpaper fills the output. Clamping keeps the
                  // blur kernel from sampling transparent pixels beyond that
                  // boundary and exposing a bright halo around the display.
                  tileMode: TileMode.clamp,
                ),
                child: output == null
                    ? ShellWallpaper(
                        onPainted: onPainted == null ? null : _wallpaperPainted,
                      )
                    : ShellOutputWallpaper(output: output),
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

class _LockClockBlock extends StatelessWidget {
  const _LockClockBlock({
    required this.clock,
    required this.desktop,
    required this.scale,
    required this.showSystemStatus,
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

  /// Mobile draws the time under the wallpaper's subject and the date and
  /// battery row over it, as two blocks with the same layout.
  final Set<HomeClockPart> parts;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = desktop
        ? math.max(72.0, size.height * 0.22)
        : math.max(48.0, size.height * 0.25 - 96.0);
    final horizontalInset = desktop ? math.max(48.0, size.width * 0.065) : 0.0;
    final height = desktop
        ? math.min(280.0, size.height * 0.36)
        : math.min(250.0, size.height * 0.34);

    // Mobile stretches the time upward with the date on top, painted above
    // the block, which reserves room for them.
    final reserve = desktop ? 0.0 : height;
    return Positioned(
      left: horizontalInset,
      right: desktop ? size.width * 0.48 : 0,
      top: top - reserve,
      height: height + reserve,
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
  const _LockGlyph();

  static const double _size = 26.0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
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

/// The swipe-up pill of the mobile face: wider than the navigation pill and
/// centred where it sits. Like the fingerprint ring it stays put and fades
/// out as the face is swiped away.
class _LockSwipePill extends StatelessWidget {
  const _LockSwipePill({required this.face, required this.fadeDistance});

  final ValueListenable<Offset> face;
  final double fadeDistance;

  @override
  Widget build(BuildContext context) {
    // BottomGestureHandle centres the navigation pill below the top 20 px of
    // its hit area.
    return Positioned(
      left: 0,
      right: 0,
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

/// Marks the fingerprint sensor: on an under-display sensor the ring sits on
/// the sensor, otherwise near the bottom edge. It stays on the sensor and
/// fades out as the face is swiped away. Red while the reader is not
/// listening, after a rejected scan or while it re-arms, so the user waits
/// for white.
class _LockFingerprintRing extends StatefulWidget {
  const _LockFingerprintRing({
    required this.present,
    required this.ready,
    required this.scanning,
    required this.sensor,
    required this.face,
    required this.fadeDistance,
  });

  final bool present;
  final bool ready;
  final bool scanning;

  /// Panel fractions in the panel's native orientation.
  final Rect? sensor;

  /// The face's offset; the ring is gone once it has moved [fadeDistance] up.
  final ValueListenable<Offset> face;
  final double fadeDistance;

  @override
  State<_LockFingerprintRing> createState() => _LockFingerprintRingState();
}

class _LockFingerprintRingState extends State<_LockFingerprintRing>
    with TickerProviderStateMixin {
  late final AnimationController _present = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.present ? 1.0 : 0.0,
  );

  /// 1 white, 0 red: it turns red at once and back to white gently.
  late final AnimationController _ready = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 90),
    value: widget.ready ? 1.0 : 0.0,
  );

  late final AnimationController _scanning = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 220),
    value: widget.scanning ? 1.0 : 0.0,
  );

  @override
  void didUpdateWidget(covariant _LockFingerprintRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    final still = MediaQuery.disableAnimationsOf(context);
    if (oldWidget.present != widget.present) {
      if (still) {
        _present.value = widget.present ? 1.0 : 0.0;
      } else if (widget.present) {
        _present.forward();
      } else {
        _present.reverse();
      }
    }
    if (oldWidget.scanning != widget.scanning) {
      if (still) {
        _scanning.value = widget.scanning ? 1.0 : 0.0;
      } else if (widget.scanning) {
        _scanning.forward();
      } else {
        _scanning.reverse();
      }
    }
    if (oldWidget.ready != widget.ready) {
      if (still) {
        _ready.value = widget.ready ? 1.0 : 0.0;
      } else if (widget.ready) {
        _ready.forward();
      } else {
        _ready.reverse();
      }
    }
  }

  @override
  void dispose() {
    _present.dispose();
    _ready.dispose();
    _scanning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _LockFingerprintRingPainter(
          present: _present,
          ready: _ready,
          scanning: _scanning,
          face: widget.face,
          fadeDistance: widget.fadeDistance,
          sensor: widget.sensor,
        ),
      ),
    );
  }
}

class _LockFingerprintRingPainter extends CustomPainter {
  _LockFingerprintRingPainter({
    required this.present,
    required this.ready,
    required this.scanning,
    required this.face,
    required this.fadeDistance,
    required this.sensor,
  }) : super(repaint: Listenable.merge([present, ready, scanning, face]));

  final Animation<double> present;
  final Animation<double> ready;
  final Animation<double> scanning;
  final ValueListenable<Offset> face;
  final double fadeDistance;
  final Rect? sensor;

  static const double _radius = 13.0;
  static const double _stroke = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = present.value * (1.0 - _swiped(face, fadeDistance));
    if (alpha <= 0.0) {
      return;
    }
    final sensor = this.sensor;
    // Sensor fractions follow the panel's native portrait orientation; a
    // landscape lock screen falls back to the bottom edge.
    final center = sensor != null && size.height >= size.width
        ? Offset(sensor.center.dx * size.width, sensor.center.dy * size.height)
        : Offset(size.width / 2, size.height * 0.88);
    final ink = Color.lerp(
      ShellTelemetryColors.danger,
      ShellMediaColors.lightForeground,
      ready.value,
    )!;
    canvas.drawCircle(
      center,
      _radius * (1.0 + 0.35 * scanning.value),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = ink.withValues(alpha: 0.92 * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _LockFingerprintRingPainter oldDelegate) =>
      oldDelegate.present != present ||
      oldDelegate.ready != ready ||
      oldDelegate.scanning != scanning ||
      oldDelegate.face != face ||
      oldDelegate.fadeDistance != fadeDistance ||
      oldDelegate.sensor != sensor;
}

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
      displayLayoutProvider.select((layout) => layout?.mainOutput?.name),
    );
    final assignment = ref.watch(
      wallpaperControllerProvider.select((state) => state.assignment),
    );
    final resource = outputName == null
        ? assignment.all
        : assignment.forOutput(outputName);
    final alignment = outputName == null
        ? assignment.spanAlignment
        : assignment.alignmentForOutput(outputName);
    final wallpaper =
        settings.useSystemWallpaper &&
            resource.kind == WallpaperResourceKind.file
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
            assignment.zoom;
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
  const _LockNotifications({required this.scale, required this.onOpen});

  /// The clock's scale, which moves its lower edge.
  final double scale;

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
    // The same block _LockClockBlock lays the mobile time out in.
    final size = MediaQuery.sizeOf(context);
    final clockTop = math.max(48.0, size.height * 0.25 - 96.0);
    final clockHeight = math.min(250.0, size.height * 0.34);
    final clockBottom = clockTop + clockHeight * (1 + scale) / 2;
    final metrics = MobileUiMetrics.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return Positioned(
      left: padding.left,
      right: padding.right,
      top: clockBottom + metrics.visual(24),
      // The fingerprint ring and the swipe pill keep the lower part.
      bottom: size.height * 0.3,
      child: ClipRect(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final group in groups)
                Padding(
                  key: ValueKey(group.key),
                  padding: EdgeInsets.fromLTRB(
                    metrics.visual(MobileNotificationCard.horizontalMargin),
                    0,
                    metrics.visual(MobileNotificationCard.horizontalMargin),
                    metrics.visual(MobileNotificationMetrics.rowSpacing),
                  ),
                  // Swiped aside, it leaves the history; a swipe up
                  // still opens the phone.
                  child: Dismissible(
                    key: ValueKey(group.key),
                    direction: group.clearable
                        ? DismissDirection.horizontal
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
