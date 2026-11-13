part of 'lock_screen_layer.dart';

/// The sheet a client opens to ask for the screen lock, such as an Android
/// app through Droidloom: the PIN keypad of the lock screen, or the account
/// password, over everything but the keyboard.
///
/// deniald hands what the user types to the client that asked, which checks
/// it and answers; the sheet only shows the answer. It waits while the
/// session is locked.
///
/// When the client also takes a fingerprint, the sheet starts folded: a
/// small card says so, over the sensor the shell marks, with a button to
/// the PIN or password. It opens when the user takes that button, types a
/// digit, or the fingerprint gives way.
class UserVerificationSheet extends ConsumerStatefulWidget {
  const UserVerificationSheet({super.key});

  @override
  ConsumerState<UserVerificationSheet> createState() =>
      _UserVerificationSheetState();
}

class _UserVerificationSheetState extends ConsumerState<UserVerificationSheet>
    with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _shown = CurvedAnimation(
    parent: _reveal,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<Offset> _rise = _shown.drive(_pinStageRise);
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: _pinShakeDuration,
  );
  late final Animation<Offset> _shakeOffset = _shake.drive(
    const _PinShakeOffset(),
  );
  final FocusNode _keys = FocusNode(debugLabel: 'user-verification-keys');
  final FocusNode _field = FocusNode(debugLabel: 'user-verification-field');
  final TextEditingController _password = TextEditingController();

  /// Character codes, scrubbed as soon as they are sent or dropped.
  final List<int> _digits = <int>[];
  StreamSubscription<DenialUserVerificationEvent>? _events;
  Timer? _retry;

  /// The sheet showing, kept while it fades out.
  DenialUserVerification? _request;
  bool _open = false;
  bool _folded = false;
  bool _usePassword = false;
  bool _busy = false;
  bool _wrong = false;
  int _filled = 0;
  DateTime? _retryAt;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(denialBridgeProvider);
    _events = bridge.userVerifications.listen(_event);
    bridge.syncUserVerification();
  }

  @override
  void dispose() {
    _events?.cancel();
    _retry?.cancel();
    _scrub();
    _password.dispose();
    _keys.dispose();
    _field.dispose();
    _shake.dispose();
    _reveal.dispose();
    super.dispose();
  }

  void _scrub() {
    _digits.fillRange(0, _digits.length, 0);
    _digits.clear();
  }

  void _event(DenialUserVerificationEvent event) {
    if (!mounted) return;
    switch (event) {
      case DenialUserVerificationShown(:final request):
        _retry?.cancel();
        _scrub();
        _password.clear();
        setState(() {
          _request = request;
          _open = true;
          _folded = request.fingerprint;
          _usePassword = !request.pinAllowed;
          _busy = false;
          _wrong = false;
          _filled = 0;
          _retryAt = null;
        });
        _reveal.forward();
      case DenialUserVerificationRejected(:final id, :final retry)
          when id == _request?.id && _open:
        _rejected(retry);
      case DenialUserVerificationOpened(:final id)
          when id == _request?.id && _open:
        _unfold();
      case DenialUserVerificationClosed(:final id) when id == _request?.id:
        _close();
      default:
    }
  }

  void _rejected(Duration retry) {
    _password.clear();
    setState(() {
      _busy = false;
      _wrong = true;
      _retryAt = retry > Duration.zero ? DateTime.now().add(retry) : null;
    });
    _retry?.cancel();
    if (_retryAt != null) {
      _retry = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        if (!_waiting) timer.cancel();
        setState(() {});
      });
    }
    if (_usePassword) {
      ref.read(hapticsServiceProvider).pulse();
      return;
    }
    _rejectPin(
      context: context,
      haptics: ref.read(hapticsServiceProvider),
      shake: _shake,
      settle: () {
        if (mounted) setState(() => _filled = 0);
      },
    );
  }

  void _close() {
    _retry?.cancel();
    _scrub();
    _password.clear();
    setState(() {
      _open = false;
      _busy = false;
    });
    _reveal.reverse().whenCompleteOrCancel(() {
      if (mounted && !_open) setState(() => _request = null);
    });
  }

  bool get _waiting => _retryAt != null && DateTime.now().isBefore(_retryAt!);

  bool get _acceptsInput => _open && !_busy && !_waiting && !_shake.isAnimating;

  void _cancel() {
    final request = _request;
    if (request == null || !_open) return;
    ref.read(denialBridgeProvider).cancelUserVerification(request.id);
    _close();
  }

  void _press(int digit) {
    final request = _request;
    if (request == null ||
        !_acceptsInput ||
        _digits.length >= request.pinLength) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.add(0x30 + digit);
      _filled = _digits.length;
      _wrong = false;
    });
    if (_digits.length == request.pinLength) {
      _submit(String.fromCharCodes(_digits), pin: true);
      _scrub();
    }
  }

  void _delete() {
    if (!_acceptsInput || _digits.isEmpty) return;
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.last = 0;
      _digits.removeLast();
      _filled = _digits.length;
    });
  }

  void _clear() {
    if (!_acceptsInput || _digits.isEmpty) return;
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _scrub();
      _filled = 0;
    });
  }

  void _submitPassword() {
    final secret = _password.text;
    if (!_acceptsInput || secret.isEmpty) return;
    _password.clear();
    _submit(secret, pin: false);
  }

  void _submit(String secret, {required bool pin}) {
    final request = _request;
    if (request == null) return;
    setState(() => _busy = true);
    ref
        .read(denialBridgeProvider)
        .submitUserVerification(request.id, pin: pin, secret: secret);
  }

  void _switch(bool password) {
    if (_busy) return;
    _scrub();
    _password.clear();
    setState(() {
      _usePassword = password;
      _wrong = false;
      _filled = 0;
    });
    if (password) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _usePassword) _field.requestFocus();
      });
    }
  }

  void _unfold() {
    if (!_folded) return;
    setState(() => _folded = false);
    if (_usePassword) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _usePassword) _field.requestFocus();
      });
    }
  }

  /// A digit typed on the folded sheet is the PIN's first.
  KeyEventResult _handleFoldedKey(FocusNode node, KeyEvent event) =>
      _handlePinKey(
        event,
        onDigit: (digit) {
          if (_usePassword) return;
          _unfold();
          _press(digit);
        },
        onDelete: () {},
        onCancel: _cancel,
      );

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) => _handlePinKey(
    event,
    onDigit: _press,
    onDelete: _delete,
    onCancel: _cancel,
  );

  @override
  Widget build(BuildContext context) {
    final request = _request;
    final locked = ref.watch(referenceShellProvider.select((s) => s.locked));
    if (request == null || locked) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final app = request.app.isEmpty ? request.title : request.app;
    final title = request.title.isNotEmpty && request.title != app
        ? request.title
        : l10n.userVerificationTitle;
    final waiting = _waiting;
    final seconds = waiting
        ? (_retryAt!.difference(DateTime.now()).inMilliseconds / 1000).ceil()
        : 0;
    final (message, messageColor) = waiting
        ? (l10n.lockRetryInSeconds(seconds), ShellTelemetryColors.warning)
        : _wrong
        ? (
            _usePassword
                ? l10n.userVerificationWrongPassword
                : l10n.lockWrongPin,
            ShellTelemetryColors.danger,
          )
        : (
            _usePassword
                ? l10n.userVerificationAsksPassword(app)
                : l10n.userVerificationAsksPin(app),
            ShellMediaColors.lightForegroundSecondary,
          );
    // The app underneath gets no touch or key while the sheet is up.
    return Positioned.fill(
      child: ShellInputRegion(
        debugLabel: 'User verification',
        active: _open,
        pointerPolicy: ShellPointerPolicy.fullScene,
        keyboardPolicy: ShellKeyboardPolicy.capture,
        compositorPolicy: ShellCompositorPolicy.exclusive,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The app behind stays visible, dimmed, and takes no touches.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: _usePassword || _folded
                  ? IgnorePointer(
                      child: CustomPaint(
                        painter: _PinStageScrimPainter(
                          reveal: _shown,
                          color: ShellMediaColors.darkness.withValues(
                            alpha: _folded ? 0.24 : 0.42,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            if (_folded)
              _UserVerificationFingerprintPanel(
                reveal: _shown,
                rise: _rise,
                focusNode: _keys,
                onKeyEvent: _handleFoldedKey,
                title: title,
                message: l10n.userVerificationAsksFingerprint(app),
                switchLabel: _usePassword
                    ? l10n.lockUsePassword
                    : l10n.lockUsePin,
                onSwitch: _unfold,
                onCancel: _cancel,
              )
            else if (_usePassword)
              _UserVerificationPasswordPanel(
                reveal: _shown,
                rise: _rise,
                title: title,
                message: message,
                error: _wrong || waiting,
                controller: _password,
                focusNode: _field,
                enabled: _acceptsInput,
                onSubmit: _submitPassword,
                onCancel: _cancel,
                onUsePin: request.pinAllowed ? () => _switch(false) : null,
              )
            else
              _PinStageFrame(
                reveal: _shown,
                interactive: _open,
                rise: _rise,
                focusNode: _keys,
                onKeyEvent: _handleKey,
                icon: Icons.lock_rounded,
                title: title,
                shakeOffset: _shakeOffset,
                length: request.pinLength,
                filled: _filled,
                error: _wrong,
                message: message,
                messageColor: messageColor,
                enabled: _acceptsInput,
                onDigit: _press,
                trailing: (keySize) => _busy
                    ? SizedBox.square(dimension: keySize)
                    : _filled == 0
                    ? _PinTextKey(
                        size: keySize,
                        label: l10n.commonCancel,
                        onPressed: _cancel,
                      )
                    : _PinIconKey(
                        size: keySize,
                        icon: Icons.backspace_outlined,
                        label: l10n.lockPinDelete,
                        onPressed: _delete,
                        onLongPress: _clear,
                      ),
                link: request.passwordAllowed
                    ? _PinLink(
                        label: l10n.lockUsePassword,
                        onPressed: () => _switch(true),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

/// The folded sheet: a card at the top, clear of the sensor the shell marks
/// near the bottom, with the way to the PIN or password.
class _UserVerificationFingerprintPanel extends StatelessWidget {
  const _UserVerificationFingerprintPanel({
    required this.reveal,
    required this.rise,
    required this.focusNode,
    required this.onKeyEvent,
    required this.title,
    required this.message,
    required this.switchLabel,
    required this.onSwitch,
    required this.onCancel,
  });

  final Animation<double> reveal;
  final Animation<Offset> rise;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final String title;
  final String message;
  final String switchLabel;
  final VoidCallback onSwitch;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Positioned.fill(
      child: Focus(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: onKeyEvent,
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Align(
            alignment: Alignment.topCenter,
            child: CompositedTranslation(
              translation: rise,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              child: FadeSnapshot(
                opacity: reveal,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.shellColors.surfaceContainerLow,
                      borderRadius: context.shellTheme.borderRadius(24),
                      border: Border.all(color: context.shellColors.hairline),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.fingerprint_rounded,
                                size: 24,
                                color: context.shellColors.textSecondary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  title,
                                  style: ShellText.base.copyWith(
                                    fontSize: 21,
                                    height: 1.15,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                              ),
                              _MobileLockCancelButton(
                                label: l10n.commonCancel,
                                onPressed: onCancel,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              message,
                              style: ShellText.base.copyWith(
                                color: context.shellColors.textSecondary,
                                fontSize: 13,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Center(
                            child: _PinLink(
                              label: switchLabel,
                              onPressed: onSwitch,
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

/// The account password, in the lock screen's field style, on a card.
class _UserVerificationPasswordPanel extends StatelessWidget {
  const _UserVerificationPasswordPanel({
    required this.reveal,
    required this.rise,
    required this.title,
    required this.message,
    required this.error,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSubmit,
    required this.onCancel,
    required this.onUsePin,
  });

  final Animation<double> reveal;
  final Animation<Offset> rise;
  final String title;
  final String message;
  final bool error;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;
  final VoidCallback? onUsePin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accentPalette;
    return Positioned.fill(
      child: MobileKeyboardViewport(
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: CompositedTranslation(
              translation: rise,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              child: FadeSnapshot(
                opacity: reveal,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.shellColors.surfaceContainerLow,
                      borderRadius: context.shellTheme.borderRadius(24),
                      border: Border.all(color: context.shellColors.hairline),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: ShellText.base.copyWith(
                                    fontSize: 21,
                                    height: 1.15,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                              ),
                              _MobileLockCancelButton(
                                label: l10n.commonCancel,
                                onPressed: onCancel,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              message,
                              style: ShellText.base.copyWith(
                                color: error
                                    ? context.shellColors.performanceBad
                                    : context.shellColors.textSecondary,
                                fontSize: 13,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Semantics(
                            label: l10n.lockPasswordObscured,
                            textField: true,
                            obscured: true,
                            child: TextFieldTapRegion(
                              child: AnimatedBuilder(
                                animation: focusNode,
                                builder: (context, child) => DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: context.shellColors.background
                                        .withValues(alpha: 0.72),
                                    borderRadius: context.shellTheme
                                        .borderRadius(14),
                                    border: Border.all(
                                      color: focusNode.hasFocus
                                          ? accent.primary
                                          : context.shellColors.hairline,
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
                                          controller: controller,
                                          focusNode: focusNode,
                                          autofocus: true,
                                          readOnly: !enabled,
                                          style: context.shellTheme.text.base
                                              .copyWith(
                                                fontSize: 17,
                                                letterSpacing: 2.2,
                                              ),
                                          cursorColor: accent.primary,
                                          backgroundCursorColor:
                                              context.shellColors.textTertiary,
                                          selectionColor: accent.selection,
                                          obscureText: true,
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
                                        label: l10n.userVerificationConfirm,
                                        onPressed: onSubmit,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (onUsePin case final onUsePin?) ...[
                            const SizedBox(height: 8),
                            Center(
                              child: _PinLink(
                                label: l10n.lockUsePin,
                                onPressed: onUsePin,
                              ),
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
      ),
    );
  }
}
