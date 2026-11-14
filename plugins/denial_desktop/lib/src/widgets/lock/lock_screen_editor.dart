part of 'lock_screen_layer.dart';

/// The tablet lock screen's layout, edited in place: the clock is dragged
/// where it should sit and pinched to its size, and the PIN pad moves to
/// the other side. Settings opens it through deniald
/// (`shell.lockScreen.edit`), which refuses while the session is locked. Only
/// a landscape tablet has this layout: an upright one is asked to turn.
class LockScreenEditorLayer extends ConsumerStatefulWidget {
  const LockScreenEditorLayer({super.key});

  @override
  ConsumerState<LockScreenEditorLayer> createState() =>
      _LockScreenEditorLayerState();
}

class _LockScreenEditorLayerState extends ConsumerState<LockScreenEditorLayer> {
  /// How near the area's centre line the clock snaps to it.
  static const double _snapDistance = 24.0;

  late final StreamSubscription<DenialShellActionEvent> _shellActions;
  bool _open = false;

  LockPadSide _padSide = LockPadSide.right;
  double _clockX = 0.5;
  double _clockY = ShellLockScreenSettings.defaultTabletClockY;
  double _scale = ShellLockScreenSettings.defaultTabletClockScale;

  /// The finger's clock centre, kept inside the area but not snapped, so
  /// leaving the centre line takes the same distance as reaching it.
  Offset _dragCenter = Offset.zero;
  double _startScale = 1.0;
  bool _snapped = false;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _shellActions = ref.read(denialBridgeProvider).shellActions.listen((event) {
      if (event.action == DenialShellAction.lockScreenEditor) _start();
    });
  }

  @override
  void dispose() {
    unawaited(_shellActions.cancel());
    super.dispose();
  }

  void _start() {
    if (!mounted || ref.read(referenceShellProvider).lockLayerVisible) return;
    final settings = ref.read(shellSettingsProvider).lockScreen;
    setState(() {
      _open = true;
      _snapped = false;
      _padSide = settings.tabletPadSide;
      _clockX = settings.tabletClockX;
      _clockY = settings.tabletClockY;
      _scale = settings.tabletClockScale;
    });
  }

  void _close() {
    if (mounted) setState(() => _open = false);
  }

  _MobileFace _face(Size size) => _MobileFace.tablet(
    size,
    padSide: _padSide,
    padReserved: true,
    clockX: _clockX,
    clockY: _clockY,
    scale: _scale,
  );

  void _save() {
    if (_MobileFace.isTablet(_size)) {
      final face = _face(_size);
      final (x, y) = face.clockFractions(_size);
      ref
          .read(shellSettingsProvider.notifier)
          .setTabletLockLayout(
            padSide: _padSide,
            clockX: x,
            clockY: y,
            clockScale: face.scale,
          );
    }
    _close();
  }

  void _reset() => setState(() {
    _snapped = false;
    _padSide = LockPadSide.right;
    _clockX = 0.5;
    _clockY = ShellLockScreenSettings.defaultTabletClockY;
    _scale = ShellLockScreenSettings.defaultTabletClockScale;
  });

  void _swapSides() => setState(() {
    _padSide = _padSide == LockPadSide.left
        ? LockPadSide.right
        : LockPadSide.left;
  });

  void _scaleStart(ScaleStartDetails details) {
    _dragCenter = _face(_size).clock.center;
    _startScale = _scale;
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    final size = _size;
    final area = _face(size).area;
    final raw = _dragCenter + details.focalPointDelta;
    final scale = (_startScale * details.scale)
        .clamp(
          ShellLockScreenSettings.minimumTabletClockScale,
          ShellLockScreenSettings.maximumTabletClockScale,
        )
        .toDouble();
    // The face keeps the clock inside the area; the finger's centre is
    // held there too.
    final held = _MobileFace.tablet(
      size,
      padSide: _padSide,
      padReserved: true,
      clockX: (raw.dx - area.left) / area.width,
      clockY: raw.dy / size.height,
      scale: scale,
    );
    _dragCenter = held.clock.center;
    final snapped = (_dragCenter.dx - area.center.dx).abs() < _snapDistance;
    if (snapped && !_snapped) ref.read(hapticsServiceProvider).pulse();
    final (x, y) = held.clockFractions(size);
    setState(() {
      _snapped = snapped;
      _clockX = snapped ? 0.5 : x;
      _clockY = y;
      _scale = scale;
    });
  }

  void _scaleEnd(ScaleEndDetails details) {
    if (_snapped) setState(() => _snapped = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      referenceShellProvider.select((state) => state.lockLayerVisible),
      (_, locked) {
        if (locked) _close();
      },
    );
    if (!_open) return const SizedBox.shrink();
    return ShellInputRegion(
      debugLabel: 'lock screen editor',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _close,
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _size = constraints.biggest;
              return Stack(
                fit: StackFit.expand,
                children: [
                  const _LockBackdrop(),
                  if (_MobileFace.isTablet(_size))
                    ..._layout(context, _face(_size))
                  else
                    _portrait(context),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _layout(BuildContext context, _MobileFace face) {
    final l10n = context.l10n;
    final clock = HomeClockInfo.fromShell(
      now: ref.watch(clockProvider).value ?? DateTime.now(),
      locale: ref.watch(clockLocaleProvider),
      power: ref.watch(effectivePowerStatusProvider),
    );
    final showStatus = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.lockScreen.showSystemStatus,
      ),
    );
    final (notifications, _) = face.notifications(
      _size,
      gap: MobileUiMetrics.of(context).visual(24),
      padding: MediaQuery.viewPaddingOf(context),
    );
    final pad = face.pad!;
    final outline = ShellMediaColors.lightForeground.withValues(alpha: 0.5);
    final radius = context.shellTheme.borderRadius(ShellRadii.chip);
    Widget block(Set<HomeClockPart> parts) => _LockClockBlock(
      clock: clock,
      desktop: false,
      scale: face.scale,
      showSystemStatus: showStatus,
      block: face.clock,
      parts: parts,
    );
    return [
      block(const {HomeClockPart.time}),
      const _LockDepthForeground(),
      block(const {HomeClockPart.date}),
      block(const {HomeClockPart.status}),
      Positioned.fromRect(
        rect: notifications,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: outline),
            ),
            child: Center(
              child: Text(
                l10n.lockEditorNotifications,
                style: ShellText.cardTitle.copyWith(color: outline),
              ),
            ),
          ),
        ),
      ),
      if (_snapped)
        Positioned(
          left: face.area.center.dx - 0.75,
          width: 1.5,
          top: 0,
          bottom: 0,
          child: const IgnorePointer(
            child: ColoredBox(color: ShellMediaColors.lightForeground),
          ),
        ),
      // Anywhere over the face moves the clock: one finger drags it, two
      // pinch it.
      Positioned.fromRect(
        rect: face.area,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _scaleStart,
          onScaleUpdate: _scaleUpdate,
          onScaleEnd: _scaleEnd,
        ),
      ),
      Positioned.fromRect(
        rect: pad.deflate(32),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShellMediaColors.darkness.withValues(alpha: 0.32),
            borderRadius: context.shellTheme.borderRadius(28),
            border: Border.all(color: outline),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.lockEditorHint,
                  textAlign: TextAlign.center,
                  style: ShellText.base.copyWith(
                    color: ShellMediaColors.lightForegroundSecondary,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
                const Spacer(),
                const Icon(
                  Icons.dialpad_rounded,
                  size: 56,
                  color: ShellMediaColors.lightForeground,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.lockEditorPinPad,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellMediaColors.lightForeground,
                  ),
                ),
                const Spacer(),
                _LockEditorButton(
                  icon: Icons.swap_horiz_rounded,
                  label: l10n.lockEditorSwapSides,
                  onPressed: _swapSides,
                ),
                const SizedBox(height: 10),
                _LockEditorButton(
                  icon: Icons.restart_alt_rounded,
                  label: l10n.lockEditorReset,
                  onPressed: _reset,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _LockEditorButton(
                        icon: Icons.close_rounded,
                        label: l10n.lockEditorCancel,
                        onPressed: _close,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _LockEditorButton(
                        icon: Icons.check_rounded,
                        label: l10n.lockEditorDone,
                        onPressed: _save,
                        primary: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Widget _portrait(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.screen_rotation_rounded,
              size: 48,
              color: ShellMediaColors.lightForeground,
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.lockEditorPortrait,
              textAlign: TextAlign.center,
              style: ShellText.cardTitle.copyWith(
                color: ShellMediaColors.lightForeground,
              ),
            ),
            const SizedBox(height: 24),
            _LockEditorButton(
              icon: Icons.close_rounded,
              label: context.l10n.lockEditorCancel,
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }
}

class _LockEditorButton extends StatelessWidget {
  const _LockEditorButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final foreground = primary
        ? accent.onContainer
        : context.shellColors.textPrimary;
    return Semantics(
      excludeSemantics: true,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: primary
                ? accent.container
                : context.shellColors.surfaceContainerHigh,
            borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
            border: Border.all(
              color: primary ? accent.primary : context.shellColors.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
