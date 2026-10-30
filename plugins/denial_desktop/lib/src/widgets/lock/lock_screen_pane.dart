part of 'lock_screen_layer.dart';

class _DesktopLockEntrance extends StatelessWidget {
  const _DesktopLockEntrance({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final progress = Curves.easeOutCubic.transform(animation.value);
        return Opacity(
          opacity: 0.35 + progress * 0.65,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - progress)),
            child: Transform.scale(
              scale: 0.992 + progress * 0.008,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

enum _LockCredential { pin, password, sim }

/// A part of the lock face the always-on picture leaves out: it fades out as
/// the panel goes to the always-on picture and back in as it lights up.
class _AmbientHidden extends StatelessWidget {
  const _AmbientHidden({required this.opacity, required this.child});

  final Animation<double> opacity;

  /// May be positioned: it sits in a full-size stack of its own.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FadeSnapshot(
      opacity: opacity,
      child: Stack(fit: StackFit.expand, children: [child]),
    );
  }
}

class _LockScreenPane extends ConsumerStatefulWidget {
  const _LockScreenPane({
    super.key,
    required this.unlockProgress,
    required this.authenticationEnabled,
    required this.desktop,
    this.ambient = kAlwaysDismissedAnimation,
  });

  final Animation<double> unlockProgress;
  final bool authenticationEnabled;
  final bool desktop;

  /// 1 while the panel shows the always-on picture: the time, the date, the
  /// wallpaper's subject and the fingerprint mark. Everything else fades
  /// with it.
  final Animation<double> ambient;

  @override
  ConsumerState<_LockScreenPane> createState() => _LockScreenPaneState();
}

class _LockScreenPaneState extends ConsumerState<_LockScreenPane>
    with TickerProviderStateMixin {
  static const double _unlockThreshold = 0.46;
  static const double _flingVelocity = 700.0;
  static const Duration _snapDuration = Duration(milliseconds: 210);
  static const Duration _revealDuration = Duration(milliseconds: 340);

  /// Mobile: the clock, notifications and swipe pill move as one face. The
  /// finger drags it, and it slides off the top while a credential is asked
  /// for. Updates move its layers only.
  final ValueNotifier<Offset> _face = ValueNotifier<Offset>(Offset.zero);
  late final Ticker _motion;
  double _motionStart = 0.0;
  double _motionTarget = 0.0;
  Duration _motionDuration = Duration.zero;
  Curve _motionCurve = Curves.linear;
  double _height = 0.0;
  bool _dragging = false;
  final TextEditingController _responseController = TextEditingController();
  final FocusNode _responseFocus = FocusNode(
    debugLabel: 'lock-authentication-response',
  );
  bool _authenticationVisible = false;
  int? _focusedPromptSequence;

  /// The user asked for the account password although a PIN is set.
  bool _usePassword = false;

  /// A credential switch waits for the cancelled attempt to end.
  bool _beginWhenIdle = false;

  /// Mobile: the PIN keypad or the password panel comes up as the face
  /// slides away.
  late final AnimationController _credentialReveal = AnimationController(
    vsync: this,
    duration: _revealDuration,
  )..addStatusListener(_credentialRevealStatusChanged);
  late final Animation<double> _pinStageReveal = CurvedAnimation(
    parent: _credentialReveal,
    curve: const Interval(0.18, 1.0, curve: Motion.standard),
    reverseCurve: const Interval(0.0, 0.72, curve: Curves.easeInCubic),
  );
  bool _credentialShown = false;

  /// Which credential the reveal last showed, so a keypad keeps fading out
  /// after it is dismissed and the password panel never borrows it.
  _LockCredential _revealed = _LockCredential.password;

  /// What deniald last heard: the reader answers only on the fingerprint
  /// face. Null until this pane has said it, and again after a new lock.
  bool? _fingerprintOffered;

  /// The opacity of everything the always-on picture leaves out.
  late Animation<double> _ambientHidden = ReverseAnimation(widget.ambient);

  @override
  void initState() {
    super.initState();
    _motion = createTicker(_syncMotion);
    widget.ambient.addStatusListener(_ambientStatusChanged);
  }

  @override
  void didUpdateWidget(covariant _LockScreenPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ambient != widget.ambient) {
      oldWidget.ambient.removeStatusListener(_ambientStatusChanged);
      widget.ambient.addStatusListener(_ambientStatusChanged);
      _ambientHidden = ReverseAnimation(widget.ambient);
    }
  }

  /// The always-on picture shows the face at home: an open PIN pad or
  /// password panel closes as it starts.
  void _ambientStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.forward && _authenticationVisible) {
      _cancelAuthentication();
    }
  }

  @override
  void dispose() {
    _responseController.clear();
    _responseController.dispose();
    _responseFocus.dispose();
    widget.ambient.removeStatusListener(_ambientStatusChanged);
    _motion.dispose();
    _face.dispose();
    _credentialReveal.dispose();
    super.dispose();
  }

  bool _pinMode(AuthenticationState authentication) =>
      authentication.pinConfigured &&
      !_usePassword &&
      (authentication.prompt?.isPin ?? true);

  void _credentialRevealStatusChanged(AnimationStatus status) {
    if (mounted && status == AnimationStatus.dismissed) {
      setState(() {});
    }
  }

  /// Visibility is derived in build; the controller starts after the frame so
  /// status callbacks never run inside build. The face follows: off the top
  /// while a credential is shown, home otherwise, from wherever it is.
  void _syncCredentialReveal(bool shown) {
    if (shown == _credentialShown) {
      return;
    }
    _credentialShown = shown;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || shown != _credentialShown) {
        return;
      }
      final target = shown && !widget.desktop ? -_height : 0.0;
      if (MediaQuery.disableAnimationsOf(context)) {
        _credentialReveal.value = shown ? 1.0 : 0.0;
        _motion.stop();
        _face.value = Offset(0.0, target);
        return;
      }
      if (shown) {
        _credentialReveal.forward();
      } else {
        _credentialReveal.reverse();
      }
      if (!_dragging) {
        _animateFaceTo(
          target,
          curve: shown ? Curves.easeOutCubic : Motion.standard,
        );
      }
    });
  }

  /// Sent after the frame, so build stays free of platform messages.
  void _syncFingerprintOffer(bool offered) {
    if (offered == _fingerprintOffered) {
      return;
    }
    _fingerprintOffered = offered;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && offered == _fingerprintOffered) {
        ref.read(authenticationProvider.notifier).offerFingerprint(offered);
      }
    });
  }

  void _beginIfIdle(AuthenticationState authentication) {
    if (!_beginWhenIdle ||
        authentication.busy ||
        authentication.rateLimited ||
        !authentication.locked ||
        !authentication.available) {
      return;
    }
    _beginWhenIdle = false;
    ref.read(authenticationProvider.notifier).begin(password: _usePassword);
  }

  void _switchCredential({required bool password}) {
    _responseController.clear();
    setState(() {
      _usePassword = password;
      _beginWhenIdle = true;
      _authenticationVisible = true;
    });
    final authentication = ref.read(authenticationProvider);
    if (authentication.busy) {
      ref.read(authenticationProvider.notifier).cancel();
    } else {
      _beginIfIdle(authentication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authentication = ref.watch(authenticationProvider);
    if (widget.authenticationEnabled) {
      ref.listen<AuthenticationState>(authenticationProvider, (previous, next) {
        // deniald opens every new lock on the fingerprint face; the rebuild
        // this change causes tells it again what the pane shows.
        if (next.locked && !(previous?.locked ?? false)) {
          _fingerprintOffered = null;
        }
        _beginIfIdle(next);
      });
    }
    // A pending SIM PIN comes first and needs no swipe.
    final simPending =
        widget.authenticationEnabled && ref.watch(simPinPendingProvider);
    if (widget.authenticationEnabled) {
      ref.listen<bool>(simPinPendingProvider, (_, pending) {
        if (pending) _cancelAuthentication();
      });
    }
    final pinMode = widget.authenticationEnabled && _pinMode(authentication);
    // Mobile follows the user: a cancelled attempt that deniald has not
    // closed yet must not hold the keypad up or block the next swipe.
    final credentialShown =
        simPending ||
        (!widget.desktop &&
            widget.authenticationEnabled &&
            _authenticationVisible);
    if (credentialShown) {
      _revealed = simPending
          ? _LockCredential.sim
          : pinMode
          ? _LockCredential.pin
          : _LockCredential.password;
    }
    _syncCredentialReveal(credentialShown);
    if (widget.authenticationEnabled) {
      _syncFingerprintOffer(!credentialShown);
    }
    final lockSettings = ref.watch(
      shellSettingsProvider.select((settings) => settings.lockScreen),
    );
    if (widget.authenticationEnabled &&
        authentication.prompt?.sequence != _focusedPromptSequence) {
      _focusedPromptSequence = authentication.prompt?.sequence;
      _responseController.clear();
      if (authentication.prompt?.requiresResponse ?? false) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && (_authenticationVisible || authentication.busy)) {
            _responseFocus.requestFocus();
          }
        });
      }
    }
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final power = ref.watch(effectivePowerStatusProvider);
    final cpu = widget.desktop && lockSettings.showSystemStatus
        ? ref.watch(cpuUsageProvider)
        : LoadSeries.empty;
    final gpus = widget.desktop && lockSettings.showSystemStatus
        ? ref.watch(gpuUsageProvider)
        : const <GpuLoad>[];
    final clock = HomeClockInfo.fromShell(
      now: now,
      locale: ref.watch(clockLocaleProvider),
      power: power,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _height = size.height;
        // Mobile opens only by swiping up; a stray touch leaves the clock,
        // and a double tap turns the screen off, as on home.
        // The face can be caught again while it is still sliding home.
        final allowsSwipe =
            widget.authenticationEnabled && !widget.desktop && !credentialShown;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final revealed = credentialShown || _credentialReveal.value > 0.0
            ? _revealed
            : null;

        final content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.authenticationEnabled && widget.desktop
              ? _showAuthentication
              : null,
          onDoubleTap: allowsSwipe ? _blankDisplays : null,
          onPanStart: allowsSwipe ? (_) => _beginGesture() : null,
          onPanUpdate: allowsSwipe
              ? (details) => _updateGesture(details.delta, size.height)
              : null,
          onPanCancel: allowsSwipe ? _cancelGesture : null,
          onPanEnd: allowsSwipe
              ? (details) => _finishGesture(
                  size.height,
                  details.velocity.pixelsPerSecond.dy,
                )
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CompositedTranslation(
                translation: _face,
                devicePixelRatio: devicePixelRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _LockClockBlock(
                      clock: clock,
                      desktop: widget.desktop,
                      scale: lockSettings.clockScale,
                      showSystemStatus: lockSettings.showSystemStatus,
                      parts: widget.desktop
                          ? const {
                              HomeClockPart.time,
                              HomeClockPart.date,
                              HomeClockPart.status,
                            }
                          : const {HomeClockPart.time},
                    ),
                  ],
                ),
              ),
              // The subject stays put while the clock slides behind it.
              if (!widget.desktop && widget.authenticationEnabled)
                const _LockDepthForeground(),
              // The status icons stay put like a status bar while the face
              // slides.
              if (lockSettings.showSystemStatus)
                _AmbientHidden(
                  opacity: _ambientHidden,
                  child: _LockStatusIcons(
                    power: power,
                    cpu: cpu,
                    gpus: gpus,
                    desktop: widget.desktop,
                  ),
                ),
              // The sensor mark and the swipe pill stay put and fade as the
              // face moves away.
              if (!widget.desktop && widget.authenticationEnabled) ...[
                _AmbientHidden(
                  opacity: _ambientHidden,
                  child: _LockSwipePill(
                    face: _face,
                    fadeDistance: _dragDistance(size.height) * _unlockThreshold,
                  ),
                ),
                _LockFingerprintRing(
                  present: authentication.fingerprintReader,
                  ready: authentication.fingerprintAvailable,
                  scanning: authentication.fingerprintScanning,
                  sensor: authentication.fingerprintSensor,
                  face: _face,
                  fadeDistance: _dragDistance(size.height) * _unlockThreshold,
                ),
              ],
              CompositedTranslation(
                translation: _face,
                devicePixelRatio: devicePixelRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (!widget.desktop) ...[
                      _LockClockBlock(
                        clock: clock,
                        desktop: false,
                        scale: lockSettings.clockScale,
                        showSystemStatus: lockSettings.showSystemStatus,
                        parts: const {HomeClockPart.date},
                      ),
                      _AmbientHidden(
                        opacity: _ambientHidden,
                        child: _LockClockBlock(
                          clock: clock,
                          desktop: false,
                          scale: lockSettings.clockScale,
                          showSystemStatus: lockSettings.showSystemStatus,
                          parts: const {HomeClockPart.status},
                        ),
                      ),
                    ],
                    if (!widget.desktop && widget.authenticationEnabled)
                      _AmbientHidden(
                        opacity: _ambientHidden,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _LockNotifications(
                              scale: lockSettings.clockScale,
                              onOpen: _openAfterUnlock,
                            ),
                            const _LockGlyph(),
                          ],
                        ),
                      ),
                    if (widget.desktop &&
                        widget.authenticationEnabled &&
                        !simPending &&
                        !_authenticationVisible &&
                        !authentication.busy &&
                        authentication.resultMessage == null)
                      _DesktopUnlockPrompt(onBegin: _showAuthentication),
                  ],
                ),
              ),
              if (widget.authenticationEnabled &&
                  !simPending &&
                  (widget.desktop
                      ? _authenticationVisible ||
                            authentication.busy ||
                            authentication.resultMessage != null
                      : credentialShown && !pinMode))
                _LockAuthenticationPanel(
                  desktop: widget.desktop,
                  state: authentication,
                  controller: _responseController,
                  focusNode: _responseFocus,
                  onSubmit: _submitResponse,
                  onBegin: () => ref
                      .read(authenticationProvider.notifier)
                      .begin(password: _usePassword),
                  onCancel: _cancelAuthentication,
                  onSwitchCredential: authentication.pinConfigured
                      ? () => _switchCredential(password: pinMode)
                      : null,
                  usingPin: pinMode,
                ),
              if (revealed == _LockCredential.sim)
                _MobileSimPinStage(
                  key: const ValueKey<String>('mobile-sim-pin-stage'),
                  reveal: _pinStageReveal,
                  interactive: credentialShown,
                  onLater: ref.read(simPinDeferralProvider.notifier).defer,
                ),
              if (revealed == _LockCredential.pin)
                _MobileLockPinStage(
                  key: const ValueKey<String>('mobile-lock-pin-stage'),
                  reveal: _pinStageReveal,
                  interactive: credentialShown,
                  onBegin: () =>
                      ref.read(authenticationProvider.notifier).begin(),
                  onCancel: _cancelAuthentication,
                  onUsePassword: () => _switchCredential(password: true),
                ),
              if (widget.authenticationEnabled)
                _LockFingerprintFeedback(
                  visible: authentication.fingerprintRejected,
                ),
            ],
          ),
        );
        if (!widget.authenticationEnabled) {
          return content;
        }
        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape):
                _cancelAuthentication,
            const SingleActivator(LogicalKeyboardKey.enter):
                _showAuthentication,
          },
          child: Focus(
            autofocus: true,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: context.l10n.lockScreenSemanticsLabel,
              child: content,
            ),
          ),
        );
      },
    );
  }

  double _dragDistance(double height) {
    return math.max(240.0, math.min(380.0, height * 0.34));
  }

  void _blankDisplays() => ref.read(denialBridgeProvider).requestDpmsOff();

  void _beginGesture() {
    if (widget.unlockProgress.value > 0.0) {
      return;
    }

    _motion.stop();
    _dragging = true;
  }

  void _updateGesture(Offset delta, double height) {
    if (!_dragging || widget.unlockProgress.value > 0.0) {
      return;
    }

    _face.value = Offset(
      0.0,
      (_face.value.dy + delta.dy).clamp(-height, 0.0).toDouble(),
    );
  }

  void _finishGesture(double height, double velocity) {
    if (!_dragging || widget.unlockProgress.value > 0.0) {
      return;
    }

    _dragging = false;
    final progress = (-_face.value.dy / _dragDistance(height))
        .clamp(0.0, 1.0)
        .toDouble();
    if (velocity <= -_flingVelocity ||
        (progress >= _unlockThreshold && velocity < _flingVelocity)) {
      // The face carries on off the top as the credential comes up.
      _showAuthentication();
      return;
    }

    _animateFaceTo(0.0, curve: Motion.standard);
  }

  void _showAuthentication() {
    if (!widget.authenticationEnabled ||
        widget.unlockProgress.value > 0.0 ||
        ref.read(simPinPendingProvider)) {
      return;
    }
    final opening = !_authenticationVisible;
    if (opening) {
      setState(() => _authenticationVisible = true);
    }
    final authentication = ref.read(authenticationProvider);
    if (authentication.busy) {
      // On mobile a cancelled attempt may still be closing; open a new one
      // after it.
      if (opening && !widget.desktop) _beginWhenIdle = true;
    } else if (authentication.locked &&
        authentication.available &&
        !authentication.rateLimited) {
      ref.read(authenticationProvider.notifier).begin(password: _usePassword);
    }
  }

  /// A tapped notification opens once the session unlocks; the face leaves
  /// for the PIN as on a swipe.
  void _openAfterUnlock(String groupKey) {
    if (widget.unlockProgress.value > 0.0 || _authenticationVisible) return;
    ref.read(lockNotificationOpenProvider.notifier).request(groupKey);
    _showAuthentication();
  }

  void _submitResponse() {
    final prompt = ref.read(authenticationProvider).prompt;
    if (prompt == null || !prompt.requiresResponse) {
      _showAuthentication();
      return;
    }
    final response = _responseController.text;
    _responseController.clear();
    ref.read(authenticationProvider.notifier).respond(response);
  }

  void _cancelAuthentication() {
    ref.read(lockNotificationOpenProvider.notifier).clear();
    _responseController.clear();
    _responseFocus.unfocus();
    _beginWhenIdle = false;
    final authentication = ref.read(authenticationProvider);
    if (authentication.busy) {
      ref.read(authenticationProvider.notifier).cancel();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _authenticationVisible = false;
      // The next open prefers the PIN again.
      _usePassword = false;
    });
  }

  void _cancelGesture() {
    if (!_dragging || widget.unlockProgress.value > 0.0) {
      return;
    }

    _dragging = false;
    _animateFaceTo(0.0, curve: Motion.standard);
  }

  /// Takes as long as the distance needs: a face released near the top
  /// leaves as quickly as one pushed from home.
  void _animateFaceTo(double target, {required Curve curve}) {
    _motion.stop();
    final distance = (target - _face.value.dy).abs();
    if (distance < 0.5) {
      _face.value = Offset(0.0, target);
      return;
    }
    final fraction = _height > 0.0 ? (distance / _height).clamp(0.0, 1.0) : 1.0;
    _motionStart = _face.value.dy;
    _motionTarget = target;
    _motionDuration = Duration(
      microseconds: math
          .max(
            _snapDuration.inMicroseconds * 0.6,
            _revealDuration.inMicroseconds * fraction,
          )
          .round(),
    );
    _motionCurve = curve;
    _motion.start();
  }

  void _syncMotion(Duration elapsed) {
    final durationMicros = _motionDuration.inMicroseconds;
    final progress = durationMicros <= 0
        ? 1.0
        : (elapsed.inMicroseconds / durationMicros).clamp(0.0, 1.0).toDouble();
    final eased = _motionCurve.transform(progress);
    _face.value = Offset(
      0.0,
      _motionStart + (_motionTarget - _motionStart) * eased,
    );
    if (progress >= 1.0) {
      _motion.stop();
    }
  }
}

class _DesktopUnlockPrompt extends StatelessWidget {
  const _DesktopUnlockPrompt({required this.onBegin});

  final VoidCallback onBegin;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context);
    return Positioned.fill(
      child: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          24,
          24,
          math.max(32.0, size.width * 0.06),
          24,
        ),
        child: Align(
          alignment: Alignment.centerRight,
          child: Semantics(
            button: true,
            label: l10n.lockSignInSemantics,
            onTap: onBegin,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onBegin,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(420.0, size.width * 0.42),
                  ),
                  child: DecoratedBox(
                    key: const ValueKey<String>('desktop-lock-welcome-panel'),
                    decoration: _desktopLockPanelDecoration(
                      theme: theme,
                      accent: accent,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 26, 28, 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.subtle,
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox.square(
                              dimension: 52,
                              child: Icon(
                                Icons.person_outline_rounded,
                                color: accent.primary,
                                size: 26,
                              ),
                            ),
                          ),
                          const SizedBox(height: 42),
                          Text(
                            l10n.lockWelcomeBack,
                            style: ShellText.statusClock.copyWith(fontSize: 27),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.lockDesktopPromptDescription,
                            style: ShellText.base.copyWith(
                              color: context.shellColors.textSecondary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 24),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.primary,
                              borderRadius: context.shellTheme.borderRadius(16),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.lock_open_rounded,
                                    size: 18,
                                    color: accent.onPrimary,
                                  ),
                                  const SizedBox(width: 9),
                                  Text(
                                    l10n.lockUnlock,
                                    style: ShellText.cardTitle.copyWith(
                                      color: accent.onPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
