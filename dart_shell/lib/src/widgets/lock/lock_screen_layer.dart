import 'dart:math' as math;

import 'package:flutter/material.dart'
    show CircularProgressIndicator, Icons, Tooltip;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/shell_clock_info.dart';
import '../../models/shell_power_status.dart';
import '../../platform/authentication_protocol.dart';
import '../../state/authentication.dart';
import '../../state/display_layout.dart';
import '../../state/system_status.dart';
import '../../input/shell_interaction_registry.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../shell_wallpaper.dart';
import '../shade/status_glyphs.dart';

class LockScreenLayer extends ConsumerWidget {
  const LockScreenLayer({
    super.key,
    required this.unlockProgress,
  });

  final double unlockProgress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(displayLayoutProvider);
    return ShellInputRegion(
      debugLabel: 'secure lock screen',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvas = Offset.zero & constraints.biggest;
          final outputs = (layout?.outputs ?? const [])
              .map((output) =>
                  (output: output, rect: output.logicalRect.intersect(canvas)))
              .where((entry) => !entry.rect.isEmpty)
              .toList(growable: false);
          if (outputs.length <= 1) {
            return _LockScreenPane(
              unlockProgress: unlockProgress,
              authenticationEnabled: true,
            );
          }

          final authenticationMonitorId = layout?.mainOutput?.monitorId;
          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: ShellColors.background),
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
                        unlockProgress: unlockProgress,
                        authenticationEnabled:
                            entry.output.monitorId == authenticationMonitorId,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _LockScreenPane extends ConsumerStatefulWidget {
  const _LockScreenPane({
    super.key,
    required this.unlockProgress,
    required this.authenticationEnabled,
  });

  final double unlockProgress;
  final bool authenticationEnabled;

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
  final FocusNode _responseFocus =
      FocusNode(debugLabel: 'lock-authentication-response');
  bool _authenticationVisible = false;
  bool _oskVisible = false;
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
    final power = ref.watch(powerStatusProvider);
    final clock = ShellClockInfo(
      now: now,
      locale: ref.watch(clockLocaleProvider),
      power: power,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final dragDistance = _dragDistance(size.height);
        final progress =
            (-_slideOffset / dragDistance).clamp(0.0, 1.0).toDouble();
        final unlockProgress = widget.unlockProgress;
        final backdropOpacity = 1.0 - interval(unlockProgress, 0.08, 0.66);
        final panelGlassOpacity = 1.0 - interval(unlockProgress, 0.16, 0.74);

        final content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.authenticationEnabled ? _showAuthentication : null,
          onPanStart:
              widget.authenticationEnabled ? (_) => _beginGesture() : null,
          onPanUpdate: widget.authenticationEnabled
              ? (details) => _updateGesture(details.delta, size.height)
              : null,
          onPanCancel: widget.authenticationEnabled ? _cancelGesture : null,
          onPanEnd: widget.authenticationEnabled
              ? (_) => _finishGesture(size.height)
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: backdropOpacity,
                child: const _LockBackdrop(),
              ),
              if (unlockProgress > 0.0)
                _UnlockRevealBackdrop(progress: unlockProgress),
              Transform.translate(
                offset: Offset(0.0, _slideOffset),
                child: Transform(
                  alignment: Alignment.topCenter,
                  transform: _unlockPanelTransform(unlockProgress),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Color.lerp(
                          const Color(0x300b0f12),
                          const Color(0x000b0f12),
                          unlockProgress,
                        )!,
                      ),
                      Opacity(
                        opacity: panelGlassOpacity,
                        child: const DecoratedBox(
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
                      ),
                      if (unlockProgress > 0.0)
                        _UnlockSweep(progress: unlockProgress),
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
                      _LockStatusIcons(
                        power: power,
                        unlockProgress: unlockProgress,
                      ),
                      _LockClockBlock(
                        clock: clock,
                        unlockProgress: unlockProgress,
                      ),
                      _LockSwipePill(
                        progress: progress,
                        unlockProgress: unlockProgress,
                      ),
                      if (widget.authenticationEnabled &&
                          (_authenticationVisible ||
                              authentication.busy ||
                              authentication.resultMessage != null))
                        _LockAuthenticationPanel(
                          state: authentication,
                          controller: _responseController,
                          focusNode: _responseFocus,
                          oskVisible: _oskVisible,
                          onToggleOsk: () {
                            setState(() => _oskVisible = !_oskVisible);
                          },
                          onInsertText: _insertText,
                          onBackspace: _backspace,
                          onSubmit: _submitResponse,
                          onBegin:
                              ref.read(authenticationProvider.notifier).begin,
                          onCancel: _cancelAuthentication,
                        ),
                    ],
                  ),
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
              label: 'Denial secure lock screen',
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
    if (widget.unlockProgress > 0.0) {
      return;
    }

    _motion.stop();
    _onMotionComplete = null;
    _dragging = true;
  }

  void _updateGesture(Offset delta, double height) {
    if (!_dragging || widget.unlockProgress > 0.0) {
      return;
    }

    setState(() {
      _slideOffset =
          (_slideOffset + delta.dy).clamp(-height - 48.0, 0.0).toDouble();
    });
  }

  void _finishGesture(double height) {
    if (!_dragging || widget.unlockProgress > 0.0) {
      return;
    }

    _dragging = false;
    final progress =
        (-_slideOffset / _dragDistance(height)).clamp(0.0, 1.0).toDouble();
    if (progress >= _unlockThreshold) {
      _showAuthentication();
      _animateSlideTo(
        0.0,
        duration: _snapDuration,
        curve: Motion.standard,
      );
      return;
    }

    _animateSlideTo(
      0.0,
      duration: _snapDuration,
      curve: Motion.standard,
    );
  }

  void _showAuthentication() {
    if (!widget.authenticationEnabled || widget.unlockProgress > 0.0) {
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
    setState(() => _oskVisible = false);
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
      setState(() {
        _authenticationVisible = false;
        _oskVisible = false;
      });
    }
  }

  void _insertText(String text) {
    final value = _responseController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    final next = value.text.replaceRange(start, end, text);
    _responseController.value = value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  void _backspace() {
    final value = _responseController.value;
    if (value.text.isEmpty) {
      return;
    }
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    var start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    if (start == end && start > 0) {
      start -= 1;
    }
    final next = value.text.replaceRange(start, end, '');
    _responseController.value = value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: start),
      composing: TextRange.empty,
    );
  }

  void _cancelGesture() {
    if (!_dragging || widget.unlockProgress > 0.0) {
      return;
    }

    _dragging = false;
    _animateSlideTo(
      0.0,
      duration: _snapDuration,
      curve: Motion.standard,
    );
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

  Matrix4 _unlockPanelTransform(double progress) {
    final tilt = -0.018 * Curves.easeOutCubic.transform(progress);
    return Matrix4.identity()
      ..setEntry(3, 2, 0.0007)
      ..rotateX(tilt);
  }
}

class _LockAuthenticationPanel extends StatelessWidget {
  const _LockAuthenticationPanel({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.oskVisible,
    required this.onToggleOsk,
    required this.onInsertText,
    required this.onBackspace,
    required this.onSubmit,
    required this.onBegin,
    required this.onCancel,
  });

  final AuthenticationState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool oskVisible;
  final VoidCallback onToggleOsk;
  final ValueChanged<String> onInsertText;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;
  final VoidCallback onBegin;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final prompt = state.prompt;
    final message = state.resultMessage ??
        state.statusMessage ??
        prompt?.message ??
        (state.busy ? 'Waiting for system authentication…' : null);
    final error =
        state.resultIsError || prompt?.style == AuthenticationPromptStyle.error;
    final canRespond =
        state.available && state.busy && (prompt?.requiresResponse ?? false);
    final canBegin =
        state.available && state.locked && !state.busy && !state.rateLimited;
    final cooldownSeconds =
        (state.cooldown.inMilliseconds / 1000).ceil().clamp(1, 30);

    return Positioned.fill(
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 16, 16, 30),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: math.max(
                220,
                MediaQuery.sizeOf(context).height * 0.72,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xf21a1e25),
                borderRadius: BorderRadius.circular(ShellRadii.panel),
                border: Border.all(color: const Color(0x5278dce8)),
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
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0x2678dce8),
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox(
                              width: 42,
                              height: 42,
                              child: Icon(
                                Icons.lock_outline_rounded,
                                color: ShellColors.lockAccent,
                                size: 21,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Unlock Denial',
                                  style: ShellText.statusClock.copyWith(
                                    fontSize: 20,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  state.available
                                      ? 'Verified by the system PAM stack'
                                      : 'System authentication unavailable',
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
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: ShellColors.lockAccent,
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
                                  : const Color(0x1878dce8),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: error
                                    ? const Color(0x66ff5c6c)
                                    : const Color(0x3378dce8),
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
                            'Retry available in about $cooldownSeconds second${cooldownSeconds == 1 ? '' : 's'}.',
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
                              ? 'Password, obscured'
                              : 'Authentication response',
                          textField: true,
                          obscured: prompt.obscure,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x80101318),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: focusNode.hasFocus
                                    ? ShellColors.lockAccent
                                    : ShellColors.hairline,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: EditableText(
                                      controller: controller,
                                      focusNode: focusNode,
                                      style: ShellText.base.copyWith(
                                        fontSize: 16,
                                        letterSpacing: prompt.obscure ? 2.5 : 0,
                                      ),
                                      cursorColor: ShellColors.lockAccent,
                                      backgroundCursorColor:
                                          ShellColors.textTertiary,
                                      selectionColor:
                                          ShellColors.primaryContainer,
                                      obscureText: prompt.obscure,
                                      obscuringCharacter: '•',
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      enableInteractiveSelection: false,
                                      keyboardType:
                                          TextInputType.visiblePassword,
                                      textInputAction: TextInputAction.done,
                                      inputFormatters: [
                                        LengthLimitingTextInputFormatter(1024),
                                      ],
                                      onSubmitted: (_) => onSubmit(),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _LockIconButton(
                                    label: oskVisible
                                        ? 'Hide on-screen keyboard'
                                        : 'Show on-screen keyboard',
                                    icon: oskVisible
                                        ? Icons.keyboard_hide_rounded
                                        : Icons.keyboard_rounded,
                                    active: oskVisible,
                                    onPressed: onToggleOsk,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (oskVisible && canRespond) ...[
                        const SizedBox(height: 12),
                        _LockOnScreenKeyboard(
                          onText: onInsertText,
                          onBackspace: onBackspace,
                          onSubmit: onSubmit,
                        ),
                      ],
                      const SizedBox(height: 15),
                      Row(
                        children: [
                          Expanded(
                            child: _LockActionButton(
                              label: 'Cancel',
                              icon: Icons.close_rounded,
                              onPressed: onCancel,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _LockActionButton(
                              label: canRespond
                                  ? 'Unlock'
                                  : state.busy
                                      ? 'Authenticating…'
                                      : state.rateLimited
                                          ? 'Please wait'
                                          : 'Try again',
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
    final foreground = widget.enabled
        ? (widget.primary ? ShellColors.onAccent : ShellColors.textPrimary)
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
                  ? (widget.enabled
                      ? ShellColors.lockAccent
                      : ShellColors.lockAccent.withValues(alpha: 0.18))
                  : (active
                      ? ShellColors.surfaceContainerHighest
                      : ShellColors.surfaceContainerHigh),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color:
                    active ? ShellColors.lockAccent : ShellColors.hairlineSoft,
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

class _LockIconButton extends StatelessWidget {
  const _LockIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.active,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  onPressed();
                  return null;
                },
              ),
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: active
                    ? const Color(0x3378dce8)
                    : ShellColors.surfaceContainerHigh,
                shape: BoxShape.circle,
                border: Border.all(color: ShellColors.hairlineSoft),
              ),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  icon,
                  size: 19,
                  color: active
                      ? ShellColors.lockAccent
                      : ShellColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockOnScreenKeyboard extends StatefulWidget {
  const _LockOnScreenKeyboard({
    required this.onText,
    required this.onBackspace,
    required this.onSubmit,
  });

  final ValueChanged<String> onText;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  @override
  State<_LockOnScreenKeyboard> createState() => _LockOnScreenKeyboardState();
}

class _LockOnScreenKeyboardState extends State<_LockOnScreenKeyboard> {
  bool _shift = false;
  bool _symbols = false;

  static const List<List<String>> _letters = <List<String>>[
    <String>['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    <String>['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    <String>['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];
  static const List<List<String>> _symbolKeys = <List<String>>[
    <String>['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    <String>['!', '@', '#', r'$', '%', '^', '&', '*', '(', ')'],
    <String>['-', '_', '=', '+', '[', ']', '{', '}', '?'],
  ];

  @override
  Widget build(BuildContext context) {
    final rows = _symbols ? _symbolKeys : _letters;
    return Semantics(
      container: true,
      label: 'On-screen keyboard',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x66101318),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ShellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final key in row)
                      Expanded(
                        child: _LockKeyboardKey(
                          label: _shift && !_symbols ? key.toUpperCase() : key,
                          onPressed: () => widget.onText(
                            _shift && !_symbols ? key.toUpperCase() : key,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              Row(
                children: [
                  _LockKeyboardKey(
                    label: _symbols ? 'ABC' : '?123',
                    wide: true,
                    onPressed: () => setState(() => _symbols = !_symbols),
                  ),
                  const SizedBox(width: 4),
                  _LockKeyboardKey(
                    label: 'Shift',
                    icon: Icons.arrow_upward_rounded,
                    active: _shift,
                    onPressed: () => setState(() => _shift = !_shift),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _LockKeyboardKey(
                      label: 'Space',
                      onPressed: () => widget.onText(' '),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _LockKeyboardKey(
                    label: 'Backspace',
                    icon: Icons.backspace_outlined,
                    onPressed: widget.onBackspace,
                  ),
                  const SizedBox(width: 4),
                  _LockKeyboardKey(
                    label: 'Unlock',
                    icon: Icons.keyboard_return_rounded,
                    active: true,
                    onPressed: widget.onSubmit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LockKeyboardKey extends StatefulWidget {
  const _LockKeyboardKey({
    required this.label,
    required this.onPressed,
    this.icon,
    this.active = false,
    this.wide = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool active;
  final bool wide;

  @override
  State<_LockKeyboardKey> createState() => _LockKeyboardKeyState();
}

class _LockKeyboardKeyState extends State<_LockKeyboardKey> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final child = Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (value) {
            setState(() => _highlighted = value);
          },
          onShowHoverHighlight: (value) {
            setState(() => _highlighted = value);
          },
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.active
                    ? const Color(0x4078dce8)
                    : _highlighted
                        ? ShellColors.surfaceContainerHighest
                        : ShellColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: _highlighted
                      ? ShellColors.lockAccent
                      : ShellColors.hairlineSoft,
                ),
              ),
              child: SizedBox(
                height: 34,
                child: Center(
                  child: widget.icon == null
                      ? Text(
                          widget.label,
                          style: ShellText.base.copyWith(
                            fontSize: widget.label.length == 1 ? 14 : 10,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : Icon(
                          widget.icon,
                          size: 16,
                          color: widget.active
                              ? ShellColors.lockAccent
                              : ShellColors.textSecondary,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return SizedBox(width: widget.wide ? 52 : 38, child: child);
  }
}

class _LockBackdrop extends StatelessWidget {
  const _LockBackdrop();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
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
        ShellWallpaper(),
      ],
    );
  }
}

class _LockStatusIcons extends StatelessWidget {
  const _LockStatusIcons({
    required this.power,
    required this.unlockProgress,
  });

  final ShellPowerStatus power;
  final double unlockProgress;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    final exit = Curves.easeOutCubic.transform(
      interval(unlockProgress, 0.0, 0.58),
    );
    return Positioned(
      top: math.max(22.0, topPadding + 18.0),
      right: 28,
      child: Transform.translate(
        offset: Offset(34.0 * exit, -10.0 * exit),
        child: Transform.scale(
          scale: 1.0 - 0.08 * exit,
          child: Opacity(
            opacity: 0.92 * (1.0 - exit),
            child: StatusIconCluster(battery: power.batteryStatus),
          ),
        ),
      ),
    );
  }
}

class _LockClockBlock extends StatelessWidget {
  const _LockClockBlock({
    required this.clock,
    required this.unlockProgress,
  });

  final ShellClockInfo clock;
  final double unlockProgress;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = math.max(48.0, size.height * 0.25 - 96.0);
    final lift = Curves.easeOutCubic.transform(unlockProgress);
    final fade = 1.0 - interval(unlockProgress, 0.52, 0.92);

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Transform.translate(
        offset: Offset(0.0, -44.0 * lift),
        child: Transform.scale(
          scale: 1.0 - 0.035 * lift,
          child: Opacity(
            opacity: fade,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _UnlockTimeLine(
                      text: clock.timeLine,
                      progress: unlockProgress,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(clock.dateLine, style: ShellText.lockDate),
                  ),
                  if (clock.power.displayLine.isNotEmpty ||
                      clock.thermalReadings.isNotEmpty) ...[
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
        ),
      ),
    );
  }
}

class _UnlockTimeLine extends StatelessWidget {
  const _UnlockTimeLine({
    required this.text,
    required this.progress,
  });

  final String text;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var index = 0; index < text.length; index++)
          _UnlockTimeGlyph(
            character: text[index],
            index: index,
            progress: progress,
          ),
      ],
    );
  }
}

class _UnlockTimeGlyph extends StatelessWidget {
  const _UnlockTimeGlyph({
    required this.character,
    required this.index,
    required this.progress,
  });

  final String character;
  final int index;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final phase = Curves.easeOutCubic.transform(
      interval(progress, 0.04 + index * 0.035, 0.56 + index * 0.035),
    );
    final opacity = 1.0 - interval(phase, 0.34, 1.0);

    return Transform.translate(
      offset: Offset((index - 2) * 3.5 * phase, -32.0 * phase),
      child: Transform.scale(
        scale: 1.0 - 0.025 * phase,
        child: Opacity(
          opacity: opacity,
          child: Text(
            character,
            style: ShellText.lockClock.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _LockClockStatus extends StatelessWidget {
  const _LockClockStatus({
    required this.power,
    required this.thermalReadings,
  });

  final ShellPowerStatus power;
  final List<ShellThermalReading> thermalReadings;

  @override
  Widget build(BuildContext context) {
    final displayLine = power.displayLine;
    final accentColor = _batteryAccentColor(power);

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
                  if (power.protocolLabel.isNotEmpty) ...[
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
    final detail = power.protocolDetail;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          power.protocolLabel,
          maxLines: 1,
          softWrap: false,
          style: ShellText.lockChip.copyWith(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (detail.isNotEmpty) ...[
          const SizedBox(width: 5),
          Text(
            detail,
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
          reading.label,
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
          reading.value,
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
  const _LockSwipePill({
    required this.progress,
    required this.unlockProgress,
  });

  final double progress;
  final double unlockProgress;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final release = Curves.easeOutCubic.transform(
      interval(unlockProgress, 0.0, 0.46),
    );
    final fade = 1.0 - interval(unlockProgress, 0.36, 0.72);
    final width = 132.0 + 96.0 * release;
    final height = 5.0 - 2.0 * release;

    return Positioned(
      left: 0,
      right: 0,
      bottom: math.max(34.0, MediaQuery.sizeOf(context).height * 0.034) +
          bottomPadding,
      child: Center(
        child: Opacity(
          opacity: (0.76 + progress * 0.2) * fade,
          child: Transform.translate(
            offset: Offset(0.0, -8.0 * progress - 18.0 * release),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xd8ffffff),
                borderRadius: BorderRadius.circular(3),
              ),
              child: SizedBox(width: width, height: height),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnlockRevealBackdrop extends StatelessWidget {
  const _UnlockRevealBackdrop({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _UnlockRevealPainter(progress: progress),
        ),
      ),
    );
  }
}

class _UnlockRevealPainter extends CustomPainter {
  const _UnlockRevealPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final wake = Curves.easeOutCubic.transform(progress);
    final clear = interval(progress, 0.28, 1.0);
    final rect = Offset.zero & size;

    final wash = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          ShellColors.lockAccent.withValues(alpha: 0.10 * (1.0 - clear)),
          ShellColors.accent.withValues(alpha: 0.05 * (1.0 - clear)),
          const Color(0x00000000),
        ],
        stops: const [0.0, 0.46, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, wash);

    final y = size.height * (0.94 - 0.72 * wake);
    final lineOpacity = 1.0 - interval(progress, 0.68, 1.0);
    final linePaint = Paint()
      ..color = ShellColors.lockAccent.withValues(alpha: 0.18 * lineOpacity)
      ..strokeWidth = 1.1;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }

  @override
  bool shouldRepaint(covariant _UnlockRevealPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _UnlockSweep extends StatelessWidget {
  const _UnlockSweep({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _UnlockSweepPainter(progress: progress),
        ),
      ),
    );
  }
}

class _UnlockSweepPainter extends CustomPainter {
  const _UnlockSweepPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Curves.easeOutCubic.transform(progress);
    final opacity = 1.0 - interval(progress, 0.72, 1.0);
    final y = size.height * (0.86 - 0.72 * p);
    final bandHeight = size.height * (0.09 + 0.08 * p);
    final bandRect = Rect.fromLTWH(
      0,
      y - bandHeight * 0.5,
      size.width,
      bandHeight,
    );

    final bandPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0x00000000),
          ShellColors.lockAccent.withValues(alpha: 0.14 * opacity),
          ShellColors.textPrimary.withValues(alpha: 0.09 * opacity),
          const Color(0x00000000),
        ],
        stops: const [0.0, 0.42, 0.52, 1.0],
      ).createShader(bandRect);
    canvas.drawRect(bandRect, bandPaint);

    final edgePaint = Paint()
      ..color = ShellColors.textPrimary.withValues(alpha: 0.28 * opacity)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), edgePaint);

    final shardPaint = Paint()
      ..color = ShellColors.lockAccent.withValues(alpha: 0.16 * opacity)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < 5; i++) {
      final x = size.width * (0.14 + i * 0.18) +
          math.sin(progress * math.pi + i) * 18.0;
      canvas.drawLine(
        Offset(x, y + bandHeight * 0.16),
        Offset(x + size.width * 0.12, y + bandHeight * 0.72),
        shardPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UnlockSweepPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

Color _batteryAccentColor(ShellPowerStatus power) {
  if (power.voocCharging) {
    return const Color(0xff5ff38a);
  }
  if (power.ppsCharging) {
    return const Color(0xffbd8cff);
  }
  if (power.pdCharging) {
    return const Color(0xff7aa8ff);
  }
  if (power.fastCharge || power.state == 'charging') {
    return ShellColors.lockAccent;
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
