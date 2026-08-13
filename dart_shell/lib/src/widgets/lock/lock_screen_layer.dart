import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../input/shell_interaction_registry.dart';
import '../../localization/denial_localizations.dart';
import '../../models/shell_clock_info.dart';
import '../../models/shell_power_status.dart';
import '../../platform/authentication_protocol.dart';
import '../../settings/settings_controller.dart';
import '../../state/authentication.dart';
import '../../state/display_layout.dart';
import '../../state/shell_profile.dart';
import '../../state/system_status.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../edge_panel_layer.dart';
import '../shell_wallpaper.dart';
import '../shade/status_glyphs.dart';

class LockScreenLayer extends ConsumerStatefulWidget {
  const LockScreenLayer({
    super.key,
    required this.unlockProgress,
    this.animateDesktopEntrance = true,
  });

  /// Transition progress is intentionally a listenable rather than a scalar.
  /// Gesture handlers need its current value, but the lock-screen subtree does
  /// not need to rebuild for each transition tick.
  final Animation<double> unlockProgress;
  final bool animateDesktopEntrance;

  @override
  ConsumerState<LockScreenLayer> createState() => _LockScreenLayerState();
}

class _LockScreenLayerState extends ConsumerState<LockScreenLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    if (widget.animateDesktopEntrance) {
      _entrance.forward();
    }
  }

  @override
  void didUpdateWidget(covariant LockScreenLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.animateDesktopEntrance && widget.animateDesktopEntrance) {
      _entrance.forward(from: 0.0);
    } else if (oldWidget.animateDesktopEntrance &&
        !widget.animateDesktopEntrance) {
      _entrance.stop();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(displayLayoutProvider);
    final shellProfile = ref.watch(shellProfileProvider);
    final animateEntrance = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.animations.animateLockScreen,
      ),
    );
    return ShellInputRegion(
      debugLabel: 'secure lock screen',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvas = Offset.zero & constraints.biggest;
          final outputs = (layout?.outputs ?? const [])
              .map(
                (output) => (
                  output: output,
                  rect: output.logicalRect.intersect(canvas),
                ),
              )
              .where((entry) => !entry.rect.isEmpty)
              .toList(growable: false);
          final desktop =
              shellProfile == ShellProfile.desktop ||
              canvas.width >= 900 ||
              outputs.length > 1;
          late final Widget scene;
          if (outputs.length <= 1) {
            scene = Stack(
              fit: StackFit.expand,
              children: [
                const _LockBackdrop(),
                _LockScreenPane(
                  unlockProgress: widget.unlockProgress,
                  authenticationEnabled: true,
                  desktop: desktop,
                ),
              ],
            );
          } else {
            final authenticationMonitorId = layout?.mainOutput?.monitorId;
            scene = Stack(
              fit: StackFit.expand,
              children: [
                const _LockBackdrop(),
                for (final entry in outputs)
                  Positioned.fromRect(
                    rect: entry.rect,
                    child: ClipRect(
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          size: entry.rect.size,
                          padding: EdgeInsets.zero,
                          viewPadding: EdgeInsets.zero,
                        ),
                        child: _LockScreenPane(
                          key: ValueKey<int>(entry.output.monitorId),
                          unlockProgress: widget.unlockProgress,
                          authenticationEnabled:
                              entry.output.monitorId == authenticationMonitorId,
                          desktop: true,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }
          if (!widget.animateDesktopEntrance ||
              !desktop ||
              !animateEntrance ||
              MediaQuery.disableAnimationsOf(context)) {
            return scene;
          }
          return _DesktopLockEntrance(animation: _entrance, child: scene);
        },
      ),
    );
  }
}

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
    final clock = ShellClockInfo(
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
                    const ColoredBox(color: Color(0x300b0f12)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x1effffff),
                            Color(0x08000000),
                            Color(0x00000000),
                          ],
                          stops: [0.0, 0.28, 1.0],
                        ),
                      ),
                    ),
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: 1,
                      child: ColoredBox(color: Color(0x22ffffff)),
                    ),
                    Positioned(
                      left: size.width * 0.14,
                      right: size.width * 0.14,
                      top: 22,
                      height: 1,
                      child: const ColoredBox(color: Color(0x16ffffff)),
                    ),
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
                    decoration: BoxDecoration(
                      color: theme.panelColor(const Color(0xff171b22)),
                      borderRadius: BorderRadius.circular(theme.panelRadius),
                      border: Border.all(color: accent.outline),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x99000000),
                          blurRadius: 42,
                          spreadRadius: 4,
                          offset: Offset(0, 18),
                        ),
                      ],
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
                              color: ShellColors.textSecondary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 24),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.primary,
                              borderRadius: BorderRadius.circular(16),
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

class _LockAuthenticationPanel extends StatelessWidget {
  const _LockAuthenticationPanel({
    required this.desktop,
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onBegin,
    required this.onCancel,
  });

  final bool desktop;
  final AuthenticationState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  final VoidCallback onBegin;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prompt = state.prompt;
    final message =
        state.resultMessage ??
        state.statusMessage ??
        prompt?.message ??
        (state.busy ? l10n.lockWaitingForAuthentication : null);
    final error =
        state.resultIsError || prompt?.style == AuthenticationPromptStyle.error;
    final canRespond =
        state.available && state.busy && (prompt?.requiresResponse ?? false);
    final canBegin =
        state.available && state.locked && !state.busy && !state.rateLimited;
    final cooldownSeconds = (state.cooldown.inMilliseconds / 1000).ceil().clamp(
      1,
      30,
    );
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final size = MediaQuery.sizeOf(context);

    if (!desktop) {
      return _MobileLockAuthenticationPanel(
        state: state,
        controller: controller,
        focusNode: focusNode,
        onSubmit: onSubmit,
        onBegin: onBegin,
        onCancel: onCancel,
      );
    }

    return Positioned.fill(
      child: SafeArea(
        minimum: desktop
            ? EdgeInsets.fromLTRB(24, 24, math.max(32.0, size.width * 0.06), 24)
            : const EdgeInsets.fromLTRB(16, 16, 16, 30),
        child: Align(
          alignment: desktop ? Alignment.centerRight : Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktop ? math.min(460.0, size.width * 0.42) : 520,
              maxHeight: math.max(220.0, size.height * (desktop ? 0.86 : 0.72)),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xf21a1e25),
                borderRadius: BorderRadius.circular(theme.panelRadius),
                border: Border.all(color: accent.outline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 42,
                    spreadRadius: 4,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: FocusTraversalGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.subtle,
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox(
                              width: 42,
                              height: 42,
                              child: Icon(
                                Icons.lock_outline_rounded,
                                size: 21,
                                color: accent.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.lockUnlockDenial,
                                  style: ShellText.statusClock.copyWith(
                                    fontSize: 20,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  state.available
                                      ? l10n.lockPamVerified
                                      : l10n.lockAuthenticationUnavailable,
                                  style: ShellText.base.copyWith(
                                    color: ShellColors.textTertiary,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (state.busy)
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent.primary,
                              ),
                            ),
                        ],
                      ),
                      if (message != null && message.isNotEmpty) ...[
                        const SizedBox(height: 15),
                        Semantics(
                          liveRegion: true,
                          label: message,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: error
                                  ? const Color(0x24ff5c6c)
                                  : accent.subtle,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: error
                                    ? const Color(0x66ff5c6c)
                                    : accent.outline,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 10,
                              ),
                              child: Text(
                                message,
                                style: ShellText.base.copyWith(
                                  color: error
                                      ? const Color(0xffffa8b0)
                                      : ShellColors.textSecondary,
                                  fontSize: 13,
                                  height: 1.25,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (state.rateLimited) ...[
                        const SizedBox(height: 10),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            l10n.lockRetryInSeconds(cooldownSeconds),
                            textAlign: TextAlign.center,
                            style: ShellText.base.copyWith(
                              color: ShellColors.performanceWarning,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                      if (canRespond) ...[
                        const SizedBox(height: 14),
                        Semantics(
                          label: prompt!.obscure
                              ? l10n.lockPasswordObscured
                              : l10n.lockAuthenticationResponse,
                          textField: true,
                          obscured: prompt.obscure,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x80101318),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: focusNode.hasFocus
                                    ? accent.primary
                                    : ShellColors.hairline,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 4,
                              ),
                              child: EditableText(
                                controller: controller,
                                focusNode: focusNode,
                                style: ShellText.base.copyWith(
                                  fontSize: 16,
                                  letterSpacing: prompt.obscure ? 2.5 : 0,
                                ),
                                cursorColor: accent.primary,
                                backgroundCursorColor: ShellColors.textTertiary,
                                selectionColor: accent.selection,
                                obscureText: prompt.obscure,
                                obscuringCharacter: '•',
                                autocorrect: false,
                                enableSuggestions: false,
                                enableInteractiveSelection: false,
                                keyboardType: TextInputType.visiblePassword,
                                textInputAction: TextInputAction.done,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(1024),
                                ],
                                onSubmitted: (_) => onSubmit(),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 15),
                      Row(
                        children: [
                          Expanded(
                            child: _LockActionButton(
                              label: l10n.commonCancel,
                              icon: Icons.close_rounded,
                              onPressed: onCancel,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _LockActionButton(
                              label: canRespond
                                  ? l10n.lockUnlock
                                  : state.busy
                                  ? l10n.lockAuthenticating
                                  : state.rateLimited
                                  ? l10n.lockPleaseWait
                                  : l10n.lockTryAgain,
                              icon: Icons.arrow_forward_rounded,
                              primary: true,
                              enabled: canRespond || canBegin,
                              onPressed: canRespond ? onSubmit : onBegin,
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _MobileLockAuthenticationPanel extends StatelessWidget {
  const _MobileLockAuthenticationPanel({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onBegin,
    required this.onCancel,
  });

  final AuthenticationState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  final VoidCallback onBegin;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prompt = state.prompt;
    final error =
        state.resultIsError || prompt?.style == AuthenticationPromptStyle.error;
    final canRespond =
        state.available && state.busy && (prompt?.requiresResponse ?? false);
    final canBegin =
        state.available && state.locked && !state.busy && !state.rateLimited;
    final promptLabel = prompt?.message.trim();
    final message =
        state.resultMessage ??
        state.statusMessage ??
        (error ? promptLabel : null) ??
        (!canRespond && state.busy ? l10n.lockWaitingForAuthentication : null);
    final cooldownSeconds = (state.cooldown.inMilliseconds / 1000).ceil().clamp(
      1,
      30,
    );
    final accent = ShellTheme.of(context).accentPalette;
    final size = MediaQuery.sizeOf(context);

    return Positioned.fill(
      child: MobileKeyboardViewport(
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 480,
                maxHeight: math.max(210.0, size.height * 0.58),
              ),
              child: DecoratedBox(
                key: const ValueKey<String>('mobile-lock-authentication-panel'),
                decoration: BoxDecoration(
                  color: ShellColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: ShellColors.hairline),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                  child: FocusTraversalGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.lockUnlockDenial,
                                style: ShellText.base.copyWith(
                                  fontSize: 23,
                                  height: 1.1,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.35,
                                ),
                              ),
                            ),
                            if (state.busy && !canRespond) ...[
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accent.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            _MobileLockCancelButton(
                              label: l10n.commonCancel,
                              onPressed: onCancel,
                            ),
                          ],
                        ),
                        if (!state.available) ...[
                          const SizedBox(height: 7),
                          Text(
                            l10n.lockAuthenticationUnavailable,
                            style: ShellText.base.copyWith(
                              color: ShellColors.textTertiary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        if (message != null && message.isNotEmpty) ...[
                          const SizedBox(height: 13),
                          Semantics(
                            liveRegion: true,
                            label: message,
                            child: Text(
                              message,
                              style: ShellText.base.copyWith(
                                color: error
                                    ? ShellColors.performanceBad
                                    : ShellColors.textSecondary,
                                fontSize: 13,
                                height: 1.3,
                                fontWeight: error
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                        if (state.rateLimited) ...[
                          const SizedBox(height: 10),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              l10n.lockRetryInSeconds(cooldownSeconds),
                              style: ShellText.base.copyWith(
                                color: ShellColors.performanceWarning,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        if (canRespond) ...[
                          const SizedBox(height: 16),
                          Text(
                            (promptLabel == null ||
                                    promptLabel.isEmpty ||
                                    error)
                                ? l10n.lockAuthenticationResponse
                                : promptLabel,
                            style: ShellText.base.copyWith(
                              color: ShellColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Semantics(
                            label: prompt!.obscure
                                ? l10n.lockPasswordObscured
                                : l10n.lockAuthenticationResponse,
                            textField: true,
                            obscured: prompt.obscure,
                            child: TextFieldTapRegion(
                              child: AnimatedBuilder(
                                animation: focusNode,
                                builder: (context, child) => DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: ShellColors.background.withValues(
                                      alpha: 0.72,
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: focusNode.hasFocus
                                          ? accent.primary
                                          : ShellColors.hairline,
                                    ),
                                  ),
                                  child: child,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    15,
                                    5,
                                    6,
                                    5,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: EditableText(
                                          key: const ValueKey<String>(
                                            'lock-authentication-field',
                                          ),
                                          controller: controller,
                                          focusNode: focusNode,
                                          style: ShellText.base.copyWith(
                                            fontSize: 17,
                                            letterSpacing: prompt.obscure
                                                ? 2.2
                                                : 0,
                                          ),
                                          cursorColor: accent.primary,
                                          backgroundCursorColor:
                                              ShellColors.textTertiary,
                                          selectionColor: accent.selection,
                                          obscureText: prompt.obscure,
                                          obscuringCharacter: '•',
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          enableInteractiveSelection: false,
                                          keyboardType:
                                              TextInputType.visiblePassword,
                                          textInputAction: TextInputAction.done,
                                          inputFormatters: [
                                            LengthLimitingTextInputFormatter(
                                              1024,
                                            ),
                                          ],
                                          onSubmitted: (_) => onSubmit(),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      _MobileLockSubmitButton(
                                        label: l10n.lockUnlock,
                                        onPressed: onSubmit,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 16),
                          _MobileLockPrimaryButton(
                            label: state.busy
                                ? l10n.lockAuthenticating
                                : state.rateLimited
                                ? l10n.lockPleaseWait
                                : l10n.lockTryAgain,
                            enabled: canBegin,
                            onPressed: onBegin,
                          ),
                        ],
                      ],
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

class _MobileLockCancelButton extends StatelessWidget {
  const _MobileLockCancelButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          child: Text(
            label,
            style: ShellText.base.copyWith(
              color: ShellColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileLockSubmitButton extends StatelessWidget {
  const _MobileLockSubmitButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: accent.primary,
            borderRadius: BorderRadius.circular(11),
          ),
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 19,
              color: accent.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileLockPrimaryButton extends StatelessWidget {
  const _MobileLockPrimaryButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: enabled ? accent.primary : accent.subtle,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: enabled ? accent.onPrimary : ShellColors.textTertiary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockActionButton extends StatefulWidget {
  const _LockActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;
  final bool enabled;

  @override
  State<_LockActionButton> createState() => _LockActionButtonState();
}

class _LockActionButtonState extends State<_LockActionButton> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _highlighted;
    final accent = ShellTheme.of(context).accentPalette;
    final foreground = widget.enabled
        ? (widget.primary ? accent.onPrimary : ShellColors.textPrimary)
        : ShellColors.textTertiary.withValues(alpha: 0.55);
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _highlighted = value),
        onShowHoverHighlight: (value) => setState(() => _highlighted = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.enabled) {
                widget.onPressed();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.tile,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: widget.primary
                  ? (widget.enabled ? accent.primary : accent.subtle)
                  : (active
                        ? ShellColors.surfaceContainerHighest
                        : ShellColors.surfaceContainerHigh),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: active ? accent.primary : ShellColors.hairlineSoft,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 17, color: foreground),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.base.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w800,
                    ),
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

class _LockBackdrop extends ConsumerWidget {
  const _LockBackdrop();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(
      shellSettingsProvider.select((value) => value.lockScreen),
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xff171a1f),
                  Color(0xff0b0d12),
                  Color(0xff050608),
                ],
                stops: [0.0, 0.54, 1.0],
              ),
            ),
          ),
          if (settings.useSystemWallpaper)
            ClipRect(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: settings.blurRadius,
                  sigmaY: settings.blurRadius,
                ),
                child: const ShellWallpaper(),
              ),
            ),
          ColoredBox(
            color: const Color(
              0xff000000,
            ).withValues(alpha: settings.dimAmount),
          ),
        ],
      ),
    );
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
    return Positioned(
      top: math.max(22.0, topPadding + 18.0),
      right: 28,
      child: Opacity(
        opacity: 0.92,
        child: StatusIconCluster(battery: power.batteryStatus),
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
          color: const Color(0x8a101318),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ShellColors.hairlineSoft),
          boxShadow: const [
            BoxShadow(
              color: Color(0x48000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
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
        color: ShellColors.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: ShellColors.textTertiary),
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
                  color: ShellColors.textTertiary,
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
  });

  final ShellClockInfo clock;
  final bool desktop;
  final double scale;
  final bool showSystemStatus;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = desktop
        ? math.max(72.0, size.height * 0.22)
        : math.max(48.0, size.height * 0.25 - 96.0);
    final horizontalInset = desktop ? math.max(48.0, size.width * 0.065) : 0.0;

    return Positioned(
      left: horizontalInset,
      right: desktop ? size.width * 0.48 : 0,
      top: top,
      child: Transform.scale(
        alignment: desktop ? Alignment.topLeft : Alignment.topCenter,
        scale: scale,
        child: Padding(
          padding: desktop
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: desktop
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  localizedTime(context, clock.now),
                  style: ShellText.lockClock,
                ),
              ),
              const SizedBox(height: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  localizedLongDate(context, clock.now),
                  style: ShellText.lockDate,
                ),
              ),
              if (showSystemStatus &&
                  (clock.power.capacity != null ||
                      clock.thermalReadings.isNotEmpty)) ...[
                const SizedBox(height: 18),
                _LockClockStatus(
                  power: clock.power,
                  thermalReadings: clock.thermalReadings,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LockClockStatus extends StatelessWidget {
  const _LockClockStatus({required this.power, required this.thermalReadings});

  final ShellPowerStatus power;
  final List<ShellThermalReading> thermalReadings;

  @override
  Widget build(BuildContext context) {
    final displayLine = localizedBatteryLine(
      context.l10n,
      power.state,
      power.capacity,
    );
    final accentColor = _batteryAccentColor(
      power,
      ShellTheme.of(context).accentPalette.primary,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (displayLine.isNotEmpty)
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _LockBatteryGlyph(
                    level: power.batteryLevel,
                    color: accentColor,
                  ),
                  if (power.chargeProtocol != null) ...[
                    const SizedBox(width: 10),
                    _LockProtocolLabel(power: power, color: accentColor),
                  ],
                  const SizedBox(width: 10),
                  Text(
                    displayLine,
                    maxLines: 1,
                    softWrap: false,
                    style: ShellText.lockStatus.copyWith(
                      color: accentColor.withValues(alpha: 0.95),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (thermalReadings.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 5,
            children: [
              for (final reading in thermalReadings)
                _LockThermalText(reading: reading),
            ],
          ),
        ],
      ],
    );
  }
}

class _LockProtocolLabel extends StatelessWidget {
  const _LockProtocolLabel({required this.power, required this.color});

  final ShellPowerStatus power;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final protocol = power.chargeProtocol;
    if (protocol == null) {
      return const SizedBox.shrink();
    }
    final watts = power.chargeProtocolWatts;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          localizedChargeProtocol(context.l10n, protocol),
          maxLines: 1,
          softWrap: false,
          style: ShellText.lockChip.copyWith(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (watts != null) ...[
          const SizedBox(width: 5),
          Text(
            context.l10n.powerWatts(watts),
            maxLines: 1,
            softWrap: false,
            style: ShellText.lockChip.copyWith(
              color: ShellColors.textPrimary.withValues(alpha: 0.9),
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _LockThermalText extends StatelessWidget {
  const _LockThermalText({required this.reading});

  final ShellThermalReading reading;

  @override
  Widget build(BuildContext context) {
    final color = _temperatureColor(reading.deciC);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          localizedThermalSensor(context.l10n, reading.sensor),
          maxLines: 1,
          softWrap: false,
          style: ShellText.lockChip.copyWith(
            color: ShellColors.textSecondary.withValues(alpha: 0.8),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 5),
        Text(
          context.l10n.temperatureCelsius((reading.deciC / 10).round()),
          maxLines: 1,
          softWrap: false,
          style: ShellText.lockChip.copyWith(
            color: color,
            fontSize: 13,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _LockBatteryGlyph extends StatelessWidget {
  const _LockBatteryGlyph({required this.level, required this.color});

  final double level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 20,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 2,
            width: 35,
            height: 16,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0x12000000),
                border: Border.all(color: color),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Positioned(
            left: 3,
            top: 5,
            width: math.max(0.0, 29.0 * level),
            height: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Positioned(
            left: 37,
            top: 7,
            width: 4,
            height: 7,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockSwipePill extends StatelessWidget {
  const _LockSwipePill({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;

    return Positioned(
      left: 0,
      right: 0,
      bottom:
          math.max(34.0, MediaQuery.sizeOf(context).height * 0.034) +
          bottomPadding,
      child: Center(
        child: Opacity(
          opacity: 0.76 + progress * 0.2,
          child: Transform.translate(
            offset: Offset(0.0, -8.0 * progress),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xd8ffffff),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const SizedBox(width: 132, height: 5),
            ),
          ),
        ),
      ),
    );
  }
}

Color _batteryAccentColor(ShellPowerStatus power, Color shellAccent) {
  if (power.voocCharging ||
      power.ppsCharging ||
      power.pdCharging ||
      power.fastCharge ||
      power.state == 'charging') {
    return shellAccent;
  }
  final capacity = power.capacity;
  if (capacity == null || capacity >= 20) {
    return ShellColors.textPrimary;
  }
  if (capacity >= 15) {
    return const Color(0xffffd166);
  }
  return const Color(0xffff6b6b);
}

Color _temperatureColor(int deciC) {
  if (deciC >= 620) {
    return const Color(0xffff6b6b);
  }
  if (deciC >= 500) {
    return const Color(0xffffd166);
  }
  return ShellColors.textSecondary.withValues(alpha: 0.95);
}
