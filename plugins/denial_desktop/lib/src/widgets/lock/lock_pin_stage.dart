part of 'lock_screen_layer.dart';

/// Mobile PIN entry: dots and a numeric keypad over the lock backdrop.
///
/// Digits stay in this widget until the PIN is complete, then reach deniald
/// as one response; the length comes from deniald, so the last digit submits.
/// Motion follows the shell rules: the stage fades through a snapshot and
/// moves its layer, and the shake only moves the dots' layer.
/// While it leaves, touches go through to the face behind it.
class _MobileLockPinStage extends ConsumerStatefulWidget {
  const _MobileLockPinStage({
    super.key,
    required this.reveal,
    required this.interactive,
    required this.onBegin,
    required this.onCancel,
    required this.onUsePassword,
  });

  /// 0 hidden, 1 fully shown; already curved.
  final Animation<double> reveal;

  /// False once the stage is dismissed, while it still fades out.
  final bool interactive;
  final VoidCallback onBegin;
  final VoidCallback onCancel;
  final VoidCallback onUsePassword;

  @override
  ConsumerState<_MobileLockPinStage> createState() =>
      _MobileLockPinStageState();
}

class _MobileLockPinStageState extends ConsumerState<_MobileLockPinStage>
    with SingleTickerProviderStateMixin {
  /// Character codes, scrubbed as soon as they are sent or dropped.
  final List<int> _digits = <int>[];
  final FocusNode _keys = FocusNode(debugLabel: 'lock-pin-keys');
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: _pinShakeDuration,
  );
  late final Animation<Offset> _shakeOffset = _shake.drive(
    const _PinShakeOffset(),
  );
  late final Animation<Offset> _rise = widget.reveal.drive(_pinStageRise);

  /// The app a tapped notification opens after unlocking; kept while the
  /// stage fades out.
  String? _opens;

  /// Dots shown filled; stays full while deniald checks a submitted PIN.
  int _filled = 0;
  bool _submitted = false;
  bool _pendingSubmit = false;
  bool _wrong = false;

  @override
  void dispose() {
    _scrub();
    _keys.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _scrub() {
    _digits.fillRange(0, _digits.length, 0);
    _digits.clear();
  }

  bool _acceptsInput(AuthenticationState state) =>
      state.locked &&
      state.available &&
      !state.rateLimited &&
      !_submitted &&
      !_shake.isAnimating;

  void _press(int digit) {
    final state = ref.read(authenticationProvider);
    if (!_acceptsInput(state) || _digits.length >= state.pinLength) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.add(0x30 + digit);
      _filled = _digits.length;
      _wrong = false;
    });
    // A failed attempt ends deniald's prompt; the next digit opens another.
    if (!state.busy) {
      widget.onBegin();
    }
    if (_digits.length == state.pinLength) {
      _submit();
    }
  }

  void _delete() {
    if (_submitted || _digits.isEmpty || _shake.isAnimating) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.last = 0;
      _digits.removeLast();
      _filled = _digits.length;
    });
  }

  void _clear() {
    if (_submitted || _digits.isEmpty || _shake.isAnimating) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _scrub();
      _filled = 0;
    });
  }

  void _submit() {
    final state = ref.read(authenticationProvider);
    final prompt = state.prompt;
    if (!state.busy || prompt == null || !prompt.isPin) {
      // The prompt is still on its way; submit as soon as it lands.
      _pendingSubmit = true;
      return;
    }
    _pendingSubmit = false;
    final pin = String.fromCharCodes(_digits);
    _scrub();
    setState(() => _submitted = true);
    ref.read(authenticationProvider.notifier).respond(pin);
  }

  void _attemptFinished(AuthenticationState state) {
    _submitted = false;
    if (!state.locked) {
      return;
    }
    if (!state.resultIsError || state.resultMessage == null) {
      // Cancelled or timed out: start over quietly.
      setState(() => _filled = 0);
      return;
    }
    setState(() => _wrong = true);
    _rejectPin(
      context: context,
      haptics: ref.read(hapticsServiceProvider),
      shake: _shake,
      settle: () {
        if (mounted) setState(() => _filled = 0);
      },
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) => _handlePinKey(
    event,
    onDigit: _press,
    onDelete: _delete,
    onCancel: widget.onCancel,
  );

  @override
  Widget build(BuildContext context) {
    final authentication = ref.watch(authenticationProvider);
    ref.listen<AuthenticationState>(authenticationProvider, (previous, next) {
      if (_pendingSubmit && next.busy && (next.prompt?.isPin ?? false)) {
        _submit();
      }
      if (_submitted && (previous?.busy ?? false) && !next.busy) {
        _attemptFinished(next);
      }
    });
    final l10n = context.l10n;
    if (widget.interactive) {
      final groupKey = ref.watch(lockNotificationOpenProvider);
      final opening = groupKey == null
          ? null
          : ref.watch(
              desktopNotificationsProvider.select(
                (state) => state.groups
                    .where((group) => group.key == groupKey)
                    .firstOrNull
                    ?.newest
                    .notification,
              ),
            );
      _opens = opening == null ? null : notificationAppName(opening, l10n);
    }
    final opens = _opens;
    final cooldownSeconds = (authentication.cooldown.inMilliseconds / 1000)
        .ceil()
        .clamp(1, 30);
    final (message, messageColor) = authentication.rateLimited
        ? (
            l10n.lockRetryInSeconds(cooldownSeconds),
            ShellTelemetryColors.warning,
          )
        : _wrong
        ? (l10n.lockWrongPin, ShellTelemetryColors.danger)
        : !authentication.available
        ? (
            authentication.statusMessage ?? l10n.lockAuthenticationUnavailable,
            ShellMediaColors.lightForegroundSecondary,
          )
        : (null, ShellMediaColors.lightForegroundSecondary);

    return _PinStageFrame(
      reveal: widget.reveal,
      interactive: widget.interactive,
      rise: _rise,
      focusNode: _keys,
      onKeyEvent: _handleKey,
      icon: Icons.lock_rounded,
      title: opens == null ? l10n.lockEnterPin : l10n.lockEnterPinToOpen(opens),
      shakeOffset: _shakeOffset,
      length: authentication.pinLength.clamp(1, 12),
      filled: _filled,
      error: _wrong,
      message: message,
      messageColor: messageColor,
      enabled: _acceptsInput(authentication),
      onDigit: _press,
      trailing: (keySize) => _filled == 0 || _submitted
          ? _PinTextKey(
              size: keySize,
              label: l10n.commonCancel,
              onPressed: widget.onCancel,
            )
          : _PinIconKey(
              size: keySize,
              icon: Icons.backspace_outlined,
              label: l10n.lockPinDelete,
              onPressed: _delete,
              onLongPress: _clear,
            ),
      link: _PinLink(
        label: l10n.lockUsePassword,
        onPressed: widget.onUsePassword,
        color: ShellMediaColors.lightForegroundSecondary,
      ),
    );
  }
}

/// The same keypad for the modem's SIM PIN, which takes 4 to 8 digits, so the
/// user confirms it instead of the last digit submitting.
///
/// The SIM PIN goes to the modem only; it never authenticates the session.
class _MobileSimPinStage extends ConsumerStatefulWidget {
  const _MobileSimPinStage({
    super.key,
    required this.reveal,
    required this.interactive,
    required this.onLater,
  });

  /// 0 hidden, 1 fully shown; already curved.
  final Animation<double> reveal;

  /// False once the stage is dismissed, while it still fades out.
  final bool interactive;
  final VoidCallback onLater;

  @override
  ConsumerState<_MobileSimPinStage> createState() => _MobileSimPinStageState();
}

class _MobileSimPinStageState extends ConsumerState<_MobileSimPinStage>
    with SingleTickerProviderStateMixin {
  static const int _minLength = 4;
  static const int _maxLength = 8;

  /// Character codes, scrubbed as soon as they are sent or dropped.
  final List<int> _digits = <int>[];
  final FocusNode _keys = FocusNode(debugLabel: 'sim-pin-keys');
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: _pinShakeDuration,
  );
  late final Animation<Offset> _shakeOffset = _shake.drive(
    const _PinShakeOffset(),
  );
  late final Animation<Offset> _rise = widget.reveal.drive(_pinStageRise);

  /// Dots shown filled; stays full while the modem checks a submitted PIN.
  int _filled = 0;
  bool _busy = false;
  bool _wrong = false;

  @override
  void dispose() {
    _scrub();
    _keys.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _scrub() {
    _digits.fillRange(0, _digits.length, 0);
    _digits.clear();
  }

  MobileNetworkSnapshot get _sim =>
      ref.read(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();

  bool _acceptsInput(MobileNetworkSnapshot sim) =>
      sim.pinRequired && sim.pinRetries != 0 && !_busy && !_shake.isAnimating;

  void _press(int digit) {
    if (!_acceptsInput(_sim) || _digits.length >= _maxLength) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.add(0x30 + digit);
      _filled = _digits.length;
      _wrong = false;
    });
  }

  void _delete() {
    if (_busy || _digits.isEmpty || _shake.isAnimating) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.last = 0;
      _digits.removeLast();
      _filled = _digits.length;
    });
  }

  void _clear() {
    if (_busy || _digits.isEmpty || _shake.isAnimating) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _scrub();
      _filled = 0;
    });
  }

  void _later() {
    if (_busy) {
      return;
    }
    _scrub();
    widget.onLater();
  }

  Future<void> _submit() async {
    final sim = _sim;
    if (!_acceptsInput(sim) || _digits.length < _minLength) {
      return;
    }
    final pin = String.fromCharCodes(_digits);
    _scrub();
    setState(() => _busy = true);
    try {
      await ref.read(mobileNetworkServiceProvider).sendPin(sim.simPath!, pin);
    } on Object {
      if (mounted) {
        setState(() => _wrong = true);
        _rejectPin(
          context: context,
          haptics: ref.read(hapticsServiceProvider),
          shake: _shake,
          settle: () {
            if (mounted) setState(() => _filled = 0);
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) => _handlePinKey(
    event,
    onDigit: _press,
    onDelete: _delete,
    onCancel: _later,
    onSubmit: _submit,
  );

  @override
  Widget build(BuildContext context) {
    final sim =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    final l10n = context.l10n;
    final retries = sim.pinRetries;
    final (message, messageColor) = sim.unlockRequired == 4
        ? (l10n.simPukRequired, ShellTelemetryColors.danger)
        : !sim.pinRequired
        ? (l10n.simLocked, ShellTelemetryColors.danger)
        : retries != null
        ? (
            l10n.simPinRetries(retries),
            _wrong
                ? ShellTelemetryColors.danger
                : ShellMediaColors.lightForegroundSecondary,
          )
        : _wrong
        ? (l10n.lockWrongPin, ShellTelemetryColors.danger)
        : (null, ShellMediaColors.lightForegroundSecondary);

    return _PinStageFrame(
      reveal: widget.reveal,
      interactive: widget.interactive,
      rise: _rise,
      focusNode: _keys,
      onKeyEvent: _handleKey,
      icon: Icons.sim_card_rounded,
      title: l10n.simPinTitle,
      shakeOffset: _shakeOffset,
      length: _filled.clamp(_minLength, _maxLength),
      filled: _filled,
      error: _wrong,
      message: message,
      messageColor: messageColor,
      enabled: _acceptsInput(sim),
      onDigit: _press,
      leading: (keySize) => _filled >= _minLength && !_busy
          ? _PinIconKey(
              size: keySize,
              icon: Icons.check_rounded,
              label: l10n.simPinUnlock,
              onPressed: _submit,
            )
          : SizedBox.square(dimension: keySize),
      trailing: (keySize) => _busy
          ? SizedBox.square(dimension: keySize)
          : _filled == 0
          ? _PinTextKey(
              size: keySize,
              label: l10n.simPinLater,
              onPressed: _later,
            )
          : _PinIconKey(
              size: keySize,
              icon: Icons.backspace_outlined,
              label: l10n.lockPinDelete,
              onPressed: _delete,
              onLongPress: _clear,
            ),
    );
  }
}

const Duration _pinShakeDuration = Duration(milliseconds: 440);

final Animatable<Offset> _pinStageRise = Tween<Offset>(
  begin: const Offset(0, 28),
  end: Offset.zero,
);

/// A double buzz and the dots' shake, then [settle] empties them.
void _rejectPin({
  required BuildContext context,
  required HapticsService haptics,
  required AnimationController shake,
  required VoidCallback settle,
}) {
  haptics.pulse();
  Future<void>.delayed(const Duration(milliseconds: 110), haptics.pulse);
  if (MediaQuery.disableAnimationsOf(context)) {
    settle();
  } else {
    shake.forward(from: 0).whenCompleteOrCancel(settle);
  }
}

KeyEventResult _handlePinKey(
  KeyEvent event, {
  required ValueChanged<int> onDigit,
  required VoidCallback onDelete,
  required VoidCallback onCancel,
  VoidCallback? onSubmit,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;
  final digit = _digitKeys.indexOf(key);
  final numpad = _numpadKeys.indexOf(key);
  if (digit >= 0 || numpad >= 0) {
    onDigit(digit >= 0 ? digit : numpad);
  } else if (key == LogicalKeyboardKey.backspace) {
    onDelete();
  } else if (key == LogicalKeyboardKey.escape) {
    onCancel();
  } else if (onSubmit != null &&
      (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter)) {
    onSubmit();
  } else {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}

/// The keypad stage's layout, shared by the device PIN and the SIM PIN.
class _PinStageFrame extends StatelessWidget {
  const _PinStageFrame({
    required this.reveal,
    required this.interactive,
    required this.rise,
    required this.focusNode,
    required this.onKeyEvent,
    required this.icon,
    required this.title,
    required this.shakeOffset,
    required this.length,
    required this.filled,
    required this.error,
    required this.message,
    required this.messageColor,
    required this.enabled,
    required this.onDigit,
    required this.trailing,
    this.leading,
    this.link,
  });

  final Animation<double> reveal;
  final bool interactive;
  final Animation<Offset> rise;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final IconData icon;
  final String title;
  final Animation<Offset> shakeOffset;
  final int length;
  final int filled;
  final bool error;
  final String? message;
  final Color messageColor;
  final bool enabled;
  final ValueChanged<int> onDigit;
  final Widget Function(double keySize) trailing;
  final Widget Function(double keySize)? leading;
  final Widget? link;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    final scrim = ShellMediaColors.darkness.withValues(alpha: 0.42);
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: CustomPaint(
              painter: _PinStageScrimPainter(reveal: reveal, color: scrim),
            ),
          ),
          // The rise moves the layer outside the snapshots: a translation
          // inside one would be frozen at its start for the whole fade, and
          // the stage would jump into place when it ends.
          CompositedTranslation(
            translation: rise,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            child: IgnorePointer(
              ignoring: !interactive,
              child: Focus(
                focusNode: focusNode,
                autofocus: true,
                onKeyEvent: onKeyEvent,
                child: SafeArea(
                  minimum: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final keySize = math
                          .min(
                            constraints.maxWidth * 0.25,
                            constraints.maxHeight * 0.11,
                          )
                          .clamp(64.0, 92.0)
                          .toDouble();
                      final compact = constraints.maxHeight < 600;
                      return Column(
                        children: [
                          Spacer(flex: compact ? 1 : 3),
                          FadeSnapshot(
                            opacity: reveal,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  icon,
                                  size: 20,
                                  color:
                                      ShellMediaColors.lightForegroundSecondary,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: ShellText.base.copyWith(
                                    color: ShellMediaColors.lightForeground,
                                    fontSize: 21,
                                    height: 1.15,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 22),
                                CompositedTranslation(
                                  translation: shakeOffset,
                                  devicePixelRatio:
                                      MediaQuery.devicePixelRatioOf(context),
                                  child: _PinDots(
                                    length: length,
                                    filled: filled,
                                    error: error,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                SizedBox(
                                  height: 18,
                                  child: message == null
                                      ? null
                                      : Semantics(
                                          liveRegion: true,
                                          child: Text(
                                            message,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: ShellText.base.copyWith(
                                              color: messageColor,
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                          Spacer(flex: compact ? 1 : 2),
                          _PinPad(
                            keySize: keySize,
                            reveal: reveal,
                            rise: rise,
                            scrim: scrim,
                            enabled: enabled,
                            onDigit: onDigit,
                            leading:
                                leading?.call(keySize) ??
                                SizedBox.square(dimension: keySize),
                            trailing: trailing(keySize),
                          ),
                          SizedBox(height: compact ? 10 : 22),
                          if (link case final link?)
                            FadeSnapshot(opacity: reveal, child: link),
                          SizedBox(height: compact ? 4 : 10),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const List<LogicalKeyboardKey> _digitKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

const List<LogicalKeyboardKey> _numpadKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
];

/// A damped side-to-side shake, three swings that settle back to zero.
class _PinShakeOffset extends Animatable<Offset> {
  const _PinShakeOffset();

  @override
  Offset transform(double t) =>
      Offset(math.sin(t * math.pi * 6) * 13 * (1 - t), 0);
}

/// Dims the wallpaper toward the theme background as the stage appears,
/// repainting only this layer.
class _PinStageScrimPainter extends CustomPainter {
  _PinStageScrimPainter({required this.reveal, required this.color})
    : super(repaint: reveal);

  final Animation<double> reveal;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final opacity = reveal.value.clamp(0.0, 1.0);
    if (opacity == 0) {
      return;
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: color.a * opacity),
    );
  }

  @override
  bool shouldRepaint(covariant _PinStageScrimPainter oldDelegate) =>
      oldDelegate.reveal != reveal || oldDelegate.color != color;
}

/// One dot per digit. A new digit pops its dot full with a ripple; a deleted
/// digit drains its dot with a small bump, the last first when several go at
/// once. Each dot repaints only its own layer.
class _PinDots extends StatefulWidget {
  const _PinDots({
    required this.length,
    required this.filled,
    required this.error,
  });

  final int length;
  final int filled;
  final bool error;

  @override
  State<_PinDots> createState() => _PinDotsState();
}

class _PinDotsState extends State<_PinDots> {
  /// Dots drained by the last change wait this long per dot after them.
  static const Duration _stagger = Duration(milliseconds: 45);

  late int _previous = widget.filled;

  @override
  void didUpdateWidget(covariant _PinDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    _previous = oldWidget.filled;
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final ink = widget.error
        ? ShellTelemetryColors.danger
        : ShellMediaColors.lightForeground;
    return Semantics(
      label: context.l10n.lockPinProgress(widget.filled, widget.length),
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: ink),
          duration: still ? Duration.zero : const Duration(milliseconds: 150),
          builder: (context, ink, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < widget.length; index++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  child: _PinDot(
                    filled: index < widget.filled,
                    ink: ink!,
                    still: still,
                    drainDelay: index < _previous
                        ? _stagger * (_previous - 1 - index)
                        : Duration.zero,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinDot extends StatefulWidget {
  const _PinDot({
    required this.filled,
    required this.ink,
    required this.still,
    required this.drainDelay,
  });

  final bool filled;
  final Color ink;
  final bool still;
  final Duration drainDelay;

  @override
  State<_PinDot> createState() => _PinDotState();
}

class _PinDotState extends State<_PinDot> with TickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 220),
    value: widget.filled ? 1.0 : 0.0,
  );
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _disc = CurvedAnimation(
    parent: _fill,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _drain;

  @override
  void didUpdateWidget(covariant _PinDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filled == widget.filled) {
      return;
    }
    _drain?.cancel();
    _drain = null;
    if (widget.still) {
      _fill.value = widget.filled ? 1.0 : 0.0;
    } else if (widget.filled) {
      _fill.forward();
      _ripple.forward(from: 0.0);
    } else if (widget.drainDelay == Duration.zero) {
      _fill.reverse();
    } else {
      _drain = Timer(widget.drainDelay, () {
        if (mounted && !widget.filled) _fill.reverse();
      });
    }
  }

  @override
  void dispose() {
    _drain?.cancel();
    _fill.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: const Size.square(13),
        painter: _PinDotPainter(
          fill: _fill,
          disc: _disc,
          ripple: _ripple,
          ink: widget.ink,
        ),
      ),
    );
  }
}

class _PinDotPainter extends CustomPainter {
  _PinDotPainter({
    required this.fill,
    required this.disc,
    required this.ripple,
    required this.ink,
  }) : super(repaint: Listenable.merge([fill, ripple]));

  final AnimationController fill;
  final Animation<double> disc;
  final Animation<double> ripple;
  final Color ink;

  static const double _stroke = 1.4;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final level = fill.value;
    // Draining, the outline bumps out once as the ink leaves it.
    final bump = fill.status == AnimationStatus.reverse
        ? math.sin(math.pi * level) * 0.18
        : 0.0;
    final outline = radius * (0.84 + 0.16 * level + bump) - _stroke / 2;
    canvas.drawCircle(
      center,
      outline,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = ink.withValues(alpha: ink.a * (0.55 + 0.45 * level)),
    );
    final discRadius = radius * disc.value;
    if (discRadius > 0.0) {
      canvas.drawCircle(
        center,
        discRadius,
        Paint()
          ..isAntiAlias = true
          ..color = ink.withValues(alpha: ink.a * level.clamp(0.0, 1.0)),
      );
    }
    final wave = ripple.value;
    if (wave > 0.0 && wave < 1.0) {
      final fade = (1.0 - wave) * (1.0 - wave);
      canvas.drawCircle(
        center,
        radius * (1.0 + 1.2 * Curves.easeOutCubic.transform(wave)),
        Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke
          ..color = ink.withValues(alpha: ink.a * 0.5 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PinDotPainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.disc != disc ||
      oldDelegate.ripple != ripple ||
      oldDelegate.ink != ink;
}

/// The keys' glass is drawn from the lock backdrop's cached frost, beneath
/// a snapshot of their labels. A live glass filter shows nothing inside the
/// fading snapshot, and would appear only once the stage stopped fading.
class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.keySize,
    required this.reveal,
    required this.rise,
    required this.scrim,
    required this.enabled,
    required this.onDigit,
    required this.leading,
    required this.trailing,
  });

  final double keySize;
  final Animation<double> reveal;
  final Animation<Offset> rise;

  /// The stage's scrim beneath the keys, at full reveal.
  final Color scrim;
  final bool enabled;
  final ValueChanged<int> onDigit;
  final Widget leading;
  final Widget trailing;

  static const List<String> _letters = <String>[
    '',
    '',
    'ABC',
    'DEF',
    'GHI',
    'JKL',
    'MNO',
    'PQRS',
    'TUV',
    'WXYZ',
  ];

  /// Digits by slot, row by row; the empty slots hold [leading] and
  /// [trailing].
  /// The keys' glass depth, of their diameter: a rim around a flat face.
  static const double _glassDepth = 0.14;

  static const _slots = <int?>[1, 2, 3, 4, 5, 6, 7, 8, 9, null, 0, null];

  Widget _grid(Widget Function(int slot) key) {
    final columnGap = keySize * 0.3;
    final rowGap = keySize * 0.18;
    Widget row(int first) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        key(first),
        SizedBox(width: columnGap),
        key(first + 1),
        SizedBox(width: columnGap),
        key(first + 2),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(0),
        SizedBox(height: rowGap),
        row(3),
        SizedBox(height: rowGap),
        row(6),
        SizedBox(height: rowGap),
        row(9),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final glass =
        theme.effectivePanelOpacity < 1.0 &&
        WindowBackdropCache.maybeOf(context) != null;
    final keys = _grid((slot) {
      final digit = _slots[slot];
      if (digit == null) return slot == 9 ? leading : trailing;
      return _PinDigitKey(
        size: keySize,
        digit: digit,
        letters: _letters[digit],
        enabled: enabled,
        glass: glass,
        onPressed: () => onDigit(digit),
      );
    });
    if (!glass) {
      return FadeSnapshot(opacity: reveal, child: keys);
    }
    final radius = BorderRadius.circular(keySize / 2);
    final shading = theme.windowGlassShading;
    final keyGlass = shading?.withThickness(
      math.min(shading.thickness, keySize * _glassDepth),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        WindowBackdropMotion(
          motion: rise,
          child: Builder(
            builder: (context) {
              final moving = WindowBackdropCache.maybeOf(context)!;
              // The keys sit over the stage's scrim, which fades in with them.
              final cache = WindowBackdropCache(
                backdrop: moving.backdrop,
                motion: moving.motion,
                overlayColor: scrim,
                overlayOpacity: reveal,
                child: const SizedBox.shrink(),
              );
              return _grid(
                (slot) => SizedBox.square(
                  dimension: keySize,
                  child: _slots[slot] == null
                      ? null
                      : WindowBackdropSlice(
                          cache: cache,
                          borderRadius: radius,
                          glass: keyGlass,
                          opacity: reveal,
                        ),
                ),
              );
            },
          ),
        ),
        FadeSnapshot(opacity: reveal, child: keys),
      ],
    );
  }
}

/// Responds on touch-down, like a dial pad: the highlight appears at once and
/// fades after release. Only the key's own layer repaints.
class _PinKeyPress extends StatefulWidget {
  const _PinKeyPress({
    required this.size,
    required this.enabled,
    required this.label,
    required this.onPressed,
    required this.builder,
    this.onLongPress,
  });

  final double size;
  final bool enabled;
  final String label;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final Widget Function(BuildContext context, Animation<double> press) builder;

  @override
  State<_PinKeyPress> createState() => _PinKeyPressState();
}

class _PinKeyPressState extends State<_PinKeyPress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _release() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _press.value = 0;
    } else {
      _press.animateTo(0, curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      onTap: widget.enabled ? widget.onPressed : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: widget.enabled ? widget.onLongPress : null,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              if (!widget.enabled) return;
              _press.value = 1;
              widget.onPressed();
            },
            onPointerUp: (_) => _release(),
            onPointerCancel: (_) => _release(),
            child: SizedBox.square(
              dimension: widget.size,
              child: RepaintBoundary(child: widget.builder(context, _press)),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinDigitKey extends StatelessWidget {
  const _PinDigitKey({
    required this.size,
    required this.digit,
    required this.letters,
    required this.enabled,
    required this.glass,
    required this.onPressed,
  });

  final double size;
  final int digit;
  final String letters;
  final bool enabled;

  /// The pad draws this key's glass beneath it; the key adds only the press.
  final bool glass;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ink = enabled
        ? ShellMediaColors.lightForeground
        : ShellMediaColors.lightForeground.withValues(alpha: 0.38);
    return _PinKeyPress(
      size: size,
      enabled: enabled,
      label: '$digit',
      onPressed: onPressed,
      builder: (context, press) => CustomPaint(
        painter: _PinKeyFillPainter(
          press: press,
          rest: ShellMediaColors.lightForeground.withValues(
            alpha: glass ? 0 : (enabled ? 0.11 : 0.06),
          ),
          pressed: ShellMediaColors.lightForeground.withValues(
            alpha: glass ? 0.24 : 0.32,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$digit',
                style: ShellText.base.copyWith(
                  color: ink,
                  fontSize: size * 0.42,
                  height: 1.0,
                  fontWeight: FontWeight.w300,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              SizedBox(
                height: size * 0.15,
                child: letters.isEmpty
                    ? null
                    : Text(
                        letters,
                        style: ShellText.base.copyWith(
                          color: ink.withValues(alpha: ink.a * 0.72),
                          fontSize: size * 0.12,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: size * 0.024,
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

class _PinIconKey extends StatelessWidget {
  const _PinIconKey({
    required this.size,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.onLongPress,
  });

  final double size;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return _PinKeyPress(
      size: size,
      enabled: true,
      label: label,
      onPressed: onPressed,
      onLongPress: onLongPress,
      builder: (context, press) => CustomPaint(
        painter: _PinKeyFillPainter(
          press: press,
          rest: ShellMediaColors.lightForeground.withValues(alpha: 0),
          pressed: ShellMediaColors.lightForeground.withValues(alpha: 0.16),
        ),
        child: Center(
          child: Icon(
            icon,
            size: size * 0.32,
            color: ShellMediaColors.lightForeground,
          ),
        ),
      ),
    );
  }
}

class _PinTextKey extends StatelessWidget {
  const _PinTextKey({
    required this.size,
    required this.label,
    required this.onPressed,
  });

  final double size;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _PinKeyPress(
      size: size,
      enabled: true,
      label: label,
      onPressed: onPressed,
      builder: (context, press) => CustomPaint(
        painter: _PinKeyFillPainter(
          press: press,
          rest: ShellMediaColors.lightForeground.withValues(alpha: 0),
          pressed: ShellMediaColors.lightForeground.withValues(alpha: 0.16),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: ShellText.base.copyWith(
              color: ShellMediaColors.lightForeground,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PinKeyFillPainter extends CustomPainter {
  _PinKeyFillPainter({
    required this.press,
    required this.rest,
    required this.pressed,
  }) : super(repaint: press);

  final Animation<double> press;
  final Color rest;
  final Color pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color.lerp(rest, pressed, press.value)!;
    if (color.a == 0) {
      return;
    }
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2,
      Paint()
        ..isAntiAlias = true
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _PinKeyFillPainter oldDelegate) =>
      oldDelegate.press != press ||
      oldDelegate.rest != rest ||
      oldDelegate.pressed != pressed;
}

class _PinLink extends StatelessWidget {
  const _PinLink({required this.label, required this.onPressed, this.color});

  final String label;
  final VoidCallback onPressed;

  /// Theme ink by default; the PIN stage passes its fixed light ink.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                label,
                style: ShellText.base.copyWith(
                  color: color ?? context.shellColors.textSecondary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
