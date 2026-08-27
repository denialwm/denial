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

class _LockScreenPane extends ConsumerStatefulWidget {
  const _LockScreenPane({
    super.key,
    required this.unlockProgress,
    required this.authenticationEnabled,
    required this.desktop,
  });

  final Animation<double> unlockProgress;
  final bool authenticationEnabled;
  final bool desktop;

  @override
  ConsumerState<_LockScreenPane> createState() => _LockScreenPaneState();
}

class _LockScreenPaneState extends ConsumerState<_LockScreenPane>
    with SingleTickerProviderStateMixin {
  static const double _unlockThreshold = 0.46;
  static const Duration _snapDuration = Duration(milliseconds: 210);

  late final Ticker _motion;
  VoidCallback? _onMotionComplete;
  double _motionStart = 0.0;
  double _motionTarget = 0.0;
  Duration _motionDuration = Duration.zero;
  Curve _motionCurve = Curves.linear;
  double _slideOffset = 0.0;
  bool _dragging = false;
  final TextEditingController _responseController = TextEditingController();
  final FocusNode _responseFocus = FocusNode(
    debugLabel: 'lock-authentication-response',
  );
  bool _authenticationVisible = false;
  int? _focusedPromptSequence;

  @override
  void initState() {
    super.initState();
    _motion = createTicker(_syncMotion);
  }

  @override
  void dispose() {
    _responseController.clear();
    _responseController.dispose();
    _responseFocus.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authentication = ref.watch(authenticationProvider);
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
        final dragDistance = _dragDistance(size.height);
        final progress = (-_slideOffset / dragDistance)
            .clamp(0.0, 1.0)
            .toDouble();
        final allowsSwipe = widget.authenticationEnabled && !widget.desktop;

        final content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.authenticationEnabled ? _showAuthentication : null,
          onPanStart: allowsSwipe ? (_) => _beginGesture() : null,
          onPanUpdate: allowsSwipe
              ? (details) => _updateGesture(details.delta, size.height)
              : null,
          onPanCancel: allowsSwipe ? _cancelGesture : null,
          onPanEnd: allowsSwipe ? (_) => _finishGesture(size.height) : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.translate(
                offset: Offset(0.0, _slideOffset),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (lockSettings.showSystemStatus)
                      _LockStatusIcons(
                        power: power,
                        cpu: cpu,
                        gpus: gpus,
                        desktop: widget.desktop,
                      ),
                    _LockClockBlock(
                      clock: clock,
                      desktop: widget.desktop,
                      scale: lockSettings.clockScale,
                      showSystemStatus: lockSettings.showSystemStatus,
                    ),
                    if (!widget.desktop) _LockSwipePill(progress: progress),
                    if (widget.desktop &&
                        widget.authenticationEnabled &&
                        !_authenticationVisible &&
                        !authentication.busy &&
                        authentication.resultMessage == null)
                      _DesktopUnlockPrompt(onBegin: _showAuthentication),
                    if (widget.authenticationEnabled &&
                        (_authenticationVisible ||
                            authentication.busy ||
                            authentication.resultMessage != null))
                      _LockAuthenticationPanel(
                        desktop: widget.desktop,
                        state: authentication,
                        controller: _responseController,
                        focusNode: _responseFocus,
                        onSubmit: _submitResponse,
                        onBegin: ref
                            .read(authenticationProvider.notifier)
                            .begin,
                        onCancel: _cancelAuthentication,
                      ),
                  ],
                ),
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

  void _beginGesture() {
    if (widget.unlockProgress.value > 0.0) {
      return;
    }

    _motion.stop();
    _onMotionComplete = null;
    _dragging = true;
  }

  void _updateGesture(Offset delta, double height) {
    if (!_dragging || widget.unlockProgress.value > 0.0) {
      return;
    }

    setState(() {
      _slideOffset = (_slideOffset + delta.dy)
          .clamp(-height - 48.0, 0.0)
          .toDouble();
    });
  }

  void _finishGesture(double height) {
    if (!_dragging || widget.unlockProgress.value > 0.0) {
      return;
    }

    _dragging = false;
    final progress = (-_slideOffset / _dragDistance(height))
        .clamp(0.0, 1.0)
        .toDouble();
    if (progress >= _unlockThreshold) {
      _showAuthentication();
      _animateSlideTo(0.0, duration: _snapDuration, curve: Motion.standard);
      return;
    }

    _animateSlideTo(0.0, duration: _snapDuration, curve: Motion.standard);
  }

  void _showAuthentication() {
    if (!widget.authenticationEnabled || widget.unlockProgress.value > 0.0) {
      return;
    }
    if (!_authenticationVisible) {
      setState(() => _authenticationVisible = true);
    }
    final authentication = ref.read(authenticationProvider);
    if (authentication.locked &&
        authentication.available &&
        !authentication.busy &&
        !authentication.rateLimited) {
      ref.read(authenticationProvider.notifier).begin();
    }
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
    _responseController.clear();
    _responseFocus.unfocus();
    final authentication = ref.read(authenticationProvider);
    if (authentication.busy) {
      ref.read(authenticationProvider.notifier).cancel();
    }
    if (mounted) {
      setState(() => _authenticationVisible = false);
    }
  }

  void _cancelGesture() {
    if (!_dragging || widget.unlockProgress.value > 0.0) {
      return;
    }

    _dragging = false;
    _animateSlideTo(0.0, duration: _snapDuration, curve: Motion.standard);
  }

  void _animateSlideTo(
    double target, {
    required Duration duration,
    required Curve curve,
    VoidCallback? onComplete,
  }) {
    _motion.stop();
    _motionStart = _slideOffset;
    _motionTarget = target;
    _motionDuration = duration;
    _motionCurve = curve;
    _onMotionComplete = onComplete;
    _motion.start();
  }

  void _syncMotion(Duration elapsed) {
    final durationMicros = _motionDuration.inMicroseconds;
    final progress = durationMicros <= 0
        ? 1.0
        : (elapsed.inMicroseconds / durationMicros).clamp(0.0, 1.0).toDouble();
    final eased = _motionCurve.transform(progress);

    setState(() {
      _slideOffset = _motionStart + (_motionTarget - _motionStart) * eased;
    });

    if (progress >= 1.0) {
      _motion.stop();
      final onComplete = _onMotionComplete;
      _onMotionComplete = null;
      onComplete?.call();
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
