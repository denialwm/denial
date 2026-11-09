import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../../settings/widgets/settings_fingerprint_page.dart'
    show fingerprintLabel, fingerprintStatus, isFingerprintError;
import '../../widgets/connectivity/wifi_detail_surface.dart';
import '../../widgets/denial_wordmark.dart';
import '../../widgets/edge_panel_layer.dart';
import '../../widgets/lock/lock_screen_layer.dart' show PinKeypad;
import '../mobile/mobile_application_scene.dart'
    show mobileWallpaperGlassProvider;
import 'first_user_account.dart';

/// The device's first start: before it has a person's account, the shell
/// shows this over everything instead of its lock screen and home, and asks
/// for the language, Wi-Fi, time zone, the person's name, username and
/// password, a lock PIN on the lock screen's keypad, and the device's name.
/// Finishing makes the account; with a PIN and a fingerprint reader it then
/// offers a fingerprint. The
/// session then starts again as that person. The PIN and the fingerprint may
/// be skipped. Nothing shows without the session's [firstUserHelperProvider].
class FirstUserSetupLayer extends ConsumerWidget {
  const FirstUserSetupLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final helper = ref.watch(firstUserHelperProvider);
    if (helper == null) return const SizedBox.shrink();
    return ShellInputRegion(
      debugLabel: 'First user setup',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: _FirstUserSetup(helper: helper),
    );
  }
}

/// The widest the steps grow on a large screen.
const double _maxWidth = 480;

/// How long a step takes to slide in.
const Duration _pageMotion = Duration(milliseconds: 340);

enum _Step {
  language,
  wifi,
  timeZone,
  person,
  password,
  pin,
  device,
  fingerprint,
}

class _FirstUserSetup extends ConsumerStatefulWidget {
  const _FirstUserSetup({required this.helper});

  final String helper;

  @override
  ConsumerState<_FirstUserSetup> createState() => _FirstUserSetupState();
}

class _FirstUserSetupState extends ConsumerState<_FirstUserSetup> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passwordAgain = TextEditingController();
  final _deviceName = TextEditingController();
  final _zoneSearch = TextEditingController();

  var _step = _Step.language;

  /// The last step change went forward: the pages slide in from the right.
  var _forward = true;

  /// The PIN step: digits typed, the first entry while it is typed again,
  /// and the PIN both entries agreed on; empty sets none.
  var _pinEntry = '';
  String? _pinFirst;
  var _pinChosen = '';
  var _pinWrong = false;
  SetupLanguage? _language;
  TimeZoneChoices? _zones;
  var _zone = '';

  /// The person typed a username: the name no longer suggests one.
  var _usernameTyped = false;
  var _settingUsername = false;

  String? _error;
  var _busy = false;

  /// The account exists: there is no going back to change it.
  var _accountMade = false;

  /// The session is starting again as the account.
  var _starting = false;

  /// The fingerprint step's session, opened by the PIN set a step before,
  /// which stays here to open it again when it expires.
  FingerprintSettingsSession? _fingerprints;
  var _fingerprintPin = '';
  var _finger = 'right-index-finger';

  /// Where the sensor is under the screen, for the ring while a finger is
  /// added; null without one.
  Rect? _sensor;

  @override
  void initState() {
    super.initState();
    _name.addListener(_nameChanged);
    _username.addListener(_usernameChanged);
    for (final field in [_password, _passwordAgain, _deviceName]) {
      field.addListener(_clearError);
    }
    _zoneSearch.addListener(() => setState(() {}));
    unawaited(
      TimeZoneChoices.read().then((zones) {
        if (mounted) {
          setState(() {
            _zones = zones;
            _zone = zones.current;
          });
        }
      }),
    );
    unawaited(
      readFingerprintSensor().then((sensor) {
        if (mounted) setState(() => _sensor = sensor);
      }),
    );
    unawaited(
      readDeviceModel().then((model) {
        if (mounted && _deviceName.text.isEmpty) _deviceName.text = model;
      }),
    );
  }

  @override
  void dispose() {
    for (final field in [
      _name,
      _username,
      _password,
      _passwordAgain,
      _deviceName,
      _zoneSearch,
    ]) {
      field.dispose();
    }
    _fingerprints?.dispose();
    super.dispose();
  }

  /// Every edit can change what the buttons allow.
  void _clearError() => setState(() => _error = null);

  void _nameChanged() {
    _clearError();
    if (_usernameTyped) return;
    _settingUsername = true;
    _username.text = FirstUserAccount.suggestUsername(_name.text);
    _settingUsername = false;
  }

  void _usernameChanged() {
    _clearError();
    if (!_settingUsername) _usernameTyped = _username.text.isNotEmpty;
  }

  SetupLanguage _currentLanguage(BuildContext context) =>
      _language ??
      (Localizations.localeOf(context).languageCode == 'zh'
          ? SetupLanguage.simplifiedChinese
          : SetupLanguage.english);

  void _chooseLanguage(SetupLanguage language) {
    setState(() => _language = language);
    ref.read(shellSettingsProvider.notifier).setLocalePreference(
      switch (language) {
        SetupLanguage.english => ShellLocalePreference.english,
        SetupLanguage.simplifiedChinese =>
          ShellLocalePreference.simplifiedChinese,
      },
    );
  }

  bool get _canContinue => switch (_step) {
    _Step.person => _name.text.trim().isNotEmpty && _username.text.isNotEmpty,
    _Step.password => _password.text.isNotEmpty,
    _Step.device => _deviceName.text.trim().isNotEmpty && !_busy,
    _Step.fingerprint => !_busy,
    _ => true,
  };

  void _back() {
    if (_step.index == 0 || _busy || _accountMade) return;
    setState(() {
      _error = null;
      _show(_Step.values[_step.index - 1]);
      if (_step == _Step.pin) _restartPin();
    });
  }

  void _show(_Step step) {
    _forward = step.index >= _step.index;
    _step = step;
  }

  /// The PIN step starts over each time it shows.
  void _restartPin() {
    _pinEntry = '';
    _pinFirst = null;
    _pinChosen = '';
    _pinWrong = false;
  }

  void _pinDigit(int digit) {
    if (_pinEntry.length >= FirstUserAccount.pinLength) return;
    setState(() {
      _error = null;
      _pinWrong = false;
      _pinEntry += '$digit';
      if (_pinEntry.length < FirstUserAccount.pinLength) return;
      final first = _pinFirst;
      if (first == null) {
        _pinFirst = _pinEntry;
      } else if (first == _pinEntry) {
        _pinChosen = first;
        _pinFirst = null;
        _show(_Step.device);
      } else {
        _pinFirst = null;
        _pinWrong = true;
        _error = context.l10n.setupPinMismatch;
      }
      _pinEntry = '';
    });
  }

  void _pinDelete() {
    if (_pinEntry.isEmpty) return;
    setState(() => _pinEntry = _pinEntry.substring(0, _pinEntry.length - 1));
  }

  KeyEventResult _pinKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final digit = int.tryParse(event.character ?? '');
    if (digit != null && digit >= 0 && digit <= 9) {
      _pinDigit(digit);
    } else if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _pinDelete();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _next() {
    if (!_canContinue) return;
    final l10n = context.l10n;
    String? error;
    switch (_step) {
      case _Step.person:
        if (!FirstUserAccount.validFullName(_name.text)) {
          error = l10n.setupNameRules;
        } else if (!FirstUserAccount.validUsername(_username.text)) {
          error = l10n.setupUsernameRules;
        }
      case _Step.password:
        if (_password.text != _passwordAgain.text) {
          error = l10n.setupPasswordMismatch;
        }
      case _Step.pin:
        // Skipped: no PIN.
        _restartPin();
      case _Step.device:
        unawaited(_accountMade ? _start() : _finish());
        return;
      case _Step.fingerprint:
        unawaited(_start());
        return;
      default:
    }
    setState(() {
      _error = error;
      if (error == null) _show(_Step.values[_step.index + 1]);
      if (_step == _Step.pin) _restartPin();
    });
  }

  Future<void> _finish() async {
    final l10n = context.l10n;
    final language = _currentLanguage(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final pin = _pinChosen;
    final result = await makeFirstUser(
      widget.helper,
      FirstUserAccount(
        username: _username.text,
        fullName: _name.text,
        password: _password.text,
        pin: pin,
        deviceName: _deviceName.text,
        language: language,
        timeZone: _zone,
      ),
    );
    if (!mounted) return;
    switch (result.outcome) {
      case FirstUserOutcome.madeWithoutPin:
        // The account stands; the person finishes knowing the PIN is not set.
        _password.clear();
        _passwordAgain.clear();
        _pinChosen = '';
        setState(() {
          _accountMade = true;
          _busy = false;
          _error = l10n.setupPinNotSet;
        });
      case FirstUserOutcome.made ||
          // Setup stopped after making it: start as it now.
          FirstUserOutcome.exists:
        _accountMade = true;
        _password.clear();
        _passwordAgain.clear();
        _pinChosen = '';
        final reader = ref.read(fingerprintDeviceProvider).value == true;
        if (result.outcome == FirstUserOutcome.made &&
            pin.isNotEmpty &&
            reader) {
          _fingerprintPin = pin;
          _fingerprints = firstUserFingerprints(widget.helper)
            ..addListener(() => setState(() {}))
            ..authenticate(pin);
          setState(() {
            _busy = false;
            _show(_Step.fingerprint);
          });
        } else {
          await _start();
        }
      case FirstUserOutcome.notAllowed:
        setState(() {
          _busy = false;
          _error = l10n.setupNotAllowed;
        });
      case FirstUserOutcome.failed:
        setState(() {
          _busy = false;
          _error = l10n.setupFailed(result.message);
        });
    }
  }

  /// Starts the session again as the account; this layer ends with it.
  Future<void> _start() async {
    _fingerprints?.dispose();
    _fingerprints = null;
    _fingerprintPin = '';
    setState(() {
      _busy = true;
      _error = null;
      _starting = true;
    });
    final failure = await startFirstUser(widget.helper);
    if (!mounted || failure == null) return;
    setState(() {
      _busy = false;
      _starting = false;
      _error = context.l10n.setupStartFailed(failure);
    });
  }

  bool get _fingerprintAdded {
    final session = _fingerprints;
    return session != null &&
        (session.fingers.isNotEmpty || session.status == 'enroll-completed');
  }

  void _addFingerprint() {
    final session = _fingerprints;
    if (session == null || session.enrolling) return;
    if (session.authorized) {
      session.enroll(_finger);
    } else {
      // Its five minutes ran out: open it again.
      session.authenticate(_fingerprintPin);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Kept alive until the account is made, which asks it whether to offer
    // a fingerprint.
    final reader = _accountMade
        ? _fingerprints != null
        : ref.watch(fingerprintDeviceProvider).value == true;
    const margin = EdgeInsets.fromLTRB(20, 12, 20, 20);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final steps = _Step.values.length - (reader ? 0 : 1);
    return Stack(
      fit: StackFit.expand,
      children: [
        const _SetupBackdrop(),
        AnimatedSwitcher(
          duration: animate ? _pageMotion : Duration.zero,
          child: _starting
              ? _Starting(key: const ValueKey('starting'), name: _name.text)
              : Stack(
                  key: const ValueKey('steps'),
                  fit: StackFit.expand,
                  children: [
                    MobileKeyboardViewport(
                      child: SafeArea(
                        minimum: margin,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _maxWidth,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _Header(
                                  current: _step.index,
                                  count: steps,
                                  backLabel: context.l10n.setupBack,
                                  showBack: _step.index > 0 && !_accountMade,
                                  onBack: _busy ? null : _back,
                                ),
                                const SizedBox(height: 28),
                                Expanded(child: _pages(context, animate)),
                                if (_error case final error?) ...[
                                  const SizedBox(height: 14),
                                  _Notice(error),
                                ],
                                // The buttons ride on the keyboard below.
                                const SizedBox(
                                  height: _SetupButton.height + 16,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The whole layer rides, so its bounds follow the
                    // buttons up and touches reach them over the keyboard.
                    SafeArea(
                      minimum: margin,
                      child: KeyboardRide(
                        clearance: MediaQuery.paddingOf(context).bottom
                            .clamp(margin.bottom, double.infinity),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: _maxWidth,
                            ),
                            child: SizedBox(
                              height: _SetupButton.height,
                              child: _buttons(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_sensor case final sensor?
                        when _step == _Step.fingerprint &&
                            (_fingerprints?.enrolling ?? false))
                      _SensorRing(sensor),
                  ],
                ),
        ),
      ],
    );
  }

  /// The current step, sliding in from the side the person is heading to.
  Widget _pages(BuildContext context, bool animate) {
    final step = ValueKey(_step);
    final forward = _forward;
    return AnimatedSwitcher(
      duration: animate ? _pageMotion : Duration.zero,
      reverseDuration: animate ? _pageMotion * 0.6 : Duration.zero,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        final from = (child.key == step) == forward ? 0.14 : -0.14;
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: Offset(from, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: step, child: _page(context)),
    );
  }

  Widget _page(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.shellColors;
    final (title, body, icon) = switch (_step) {
      _Step.language => (l10n.setupWelcome, l10n.setupLanguageBody, null),
      _Step.wifi => (
        l10n.setupWifiTitle,
        l10n.setupWifiBody,
        Icons.wifi_rounded,
      ),
      _Step.timeZone => (l10n.setupTimeZoneTitle, null, Icons.public_rounded),
      _Step.person => (l10n.setupPersonTitle, null, Icons.person_rounded),
      _Step.password => (
        l10n.setupPasswordTitle,
        l10n.setupPasswordBody,
        Icons.lock_rounded,
      ),
      // The keypad and the fingerprint ring are these steps' pictures.
      _Step.pin => (l10n.setupPinTitle, l10n.setupPinBody, null),
      _Step.device => (
        l10n.setupDeviceTitle,
        l10n.setupDeviceBody,
        Icons.smartphone_rounded,
      ),
      _Step.fingerprint => (
        l10n.setupFingerprintTitle,
        l10n.setupFingerprintBody,
        null,
      ),
    };
    final welcome = _step == _Step.language;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (welcome)
          const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 32,
              width: 32 * denialWordmarkAspectRatio,
              child: DenialWordmark(
                semanticsLabel: 'Denial',
                alignment: Alignment.centerLeft,
              ),
            ),
          )
        else if (icon != null)
          Align(alignment: Alignment.centerLeft, child: _HeroIcon(icon)),
        if (welcome || icon != null) const SizedBox(height: 24),
        Text(
          title,
          style: ShellText.base.copyWith(
            color: colors.textPrimary,
            fontSize: welcome ? 38 : 30,
            fontWeight: FontWeight.w700,
            height: 1.12,
            letterSpacing: welcome ? -0.8 : -0.4,
          ),
        ),
        if (body != null) ...[
          const SizedBox(height: 10),
          Text(
            body,
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 16,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 28),
        Expanded(child: _content(context)),
      ],
    );
  }

  Widget _buttons(BuildContext context) {
    if (_step == _Step.fingerprint) return _fingerprintButtons(context);
    final l10n = context.l10n;
    final connected = ref.watch(
      networkConnectivityProvider.select(
        (state) => state.snapshot.connectedNetwork != null,
      ),
    );
    final skip = switch (_step) {
      _Step.wifi => !connected,
      _Step.pin => true,
      _ => false,
    };
    return _SetupButton(
      label: skip
          ? l10n.setupSkip
          : _step == _Step.device
          ? l10n.setupFinish
          : l10n.setupNext,
      primary: !skip,
      busy: _busy,
      onPressed: _canContinue ? _next : null,
    );
  }

  Widget _content(BuildContext context) {
    final l10n = context.l10n;
    switch (_step) {
      case _Step.language:
        final language = _currentLanguage(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Island(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ChoiceRow(
                    label: l10n.settingsLanguageEnglish,
                    selected: language == SetupLanguage.english,
                    divider: true,
                    onTap: () => _chooseLanguage(SetupLanguage.english),
                  ),
                  _ChoiceRow(
                    label: l10n.settingsLanguageSimplifiedChinese,
                    selected: language == SetupLanguage.simplifiedChinese,
                    onTap: () =>
                        _chooseLanguage(SetupLanguage.simplifiedChinese),
                  ),
                ],
              ),
            ),
          ],
        );
      case _Step.wifi:
        return WifiDetailSurface(onClose: _next);
      case _Step.timeZone:
        return _timeZones(context);
      case _Step.person:
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _SetupField(
              label: l10n.setupName,
              controller: _name,
              autofocus: true,
              keyboardType: TextInputType.name,
              onSubmitted: _next,
            ),
            const SizedBox(height: 12),
            _SetupField(
              label: l10n.setupUsername,
              controller: _username,
              keyboardType: TextInputType.visiblePassword,
              hint: l10n.setupUsernameRules,
              onSubmitted: _next,
            ),
          ],
        );
      case _Step.password:
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _SetupField(
              label: l10n.setupPassword,
              controller: _password,
              autofocus: true,
              obscure: true,
              onSubmitted: _next,
            ),
            const SizedBox(height: 12),
            _SetupField(
              label: l10n.setupPasswordAgain,
              controller: _passwordAgain,
              obscure: true,
              onSubmitted: _next,
            ),
          ],
        );
      case _Step.pin:
        final colors = context.shellColors;
        return Focus(
          autofocus: true,
          onKeyEvent: _pinKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Motion.cardSettle,
                child: Text(
                  _pinFirst == null ? l10n.setupPin : l10n.setupPinAgain,
                  key: ValueKey(_pinFirst == null),
                  textAlign: TextAlign.center,
                  style: ShellText.cardTitle.copyWith(
                    color: colors.textSecondary,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: PinKeypad(
                    length: FirstUserAccount.pinLength,
                    filled: _pinEntry.length,
                    error: _pinWrong,
                    ink: colors.textPrimary,
                    deleteLabel: l10n.lockPinDelete,
                    onDigit: _pinDigit,
                    onDelete: _pinDelete,
                    onClear: () => setState(() => _pinEntry = ''),
                  ),
                ),
              ),
            ],
          ),
        );
      case _Step.device:
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _SetupField(
              label: l10n.setupDeviceTitle,
              controller: _deviceName,
              autofocus: true,
              onSubmitted: _next,
            ),
          ],
        );
      case _Step.fingerprint:
        return _fingerprintContent(context);
    }
  }

  Widget _fingerprintContent(BuildContext context) {
    final session = _fingerprints;
    if (session == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final colors = context.shellColors;
    final accent = ShellTheme.of(context).accent;
    final status = session.status;
    final statusText = status == null
        ? null
        : Text(
            fingerprintStatus(
              context,
              status,
              retryMilliseconds: session.retryMilliseconds,
            ),
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(
              color: isFingerprintError(status)
                  ? colors.performanceBad
                  : colors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          );
    if (session.enrolling || _fingerprintAdded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: _FingerprintRing(
              progress: _fingerprintAdded
                  ? 1
                  : session.completed / session.total,
            ),
          ),
          const SizedBox(height: 24),
          ?statusText,
          if (!_fingerprintAdded) ...[
            const SizedBox(height: 6),
            Text(
              l10n.setupFingerprintHold,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: colors.textSecondary,
                fontSize: 15,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            l10n.fingerprintProgress(session.completed, session.total),
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(color: colors.textSecondary),
          ),
        ],
      );
    }
    if (!session.authorized) {
      // Opening the session with the PIN, or what stopped it.
      return Center(
        child:
            statusText ??
            SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 3, color: accent),
            ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Caption(l10n.fingerprintChooseFinger),
        const SizedBox(height: 8),
        Flexible(
          child: _Island(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: fingerprintNames.length,
              itemBuilder: (context, index) {
                final finger = fingerprintNames[index];
                return _ChoiceRow(
                  label: fingerprintLabel(context, finger),
                  selected: finger == _finger,
                  divider: index < fingerprintNames.length - 1,
                  onTap: () => setState(() => _finger = finger),
                );
              },
            ),
          ),
        ),
        if (statusText != null) ...[const SizedBox(height: 12), statusText],
      ],
    );
  }

  Widget _fingerprintButtons(BuildContext context) {
    final l10n = context.l10n;
    final session = _fingerprints;
    final added = _fingerprintAdded;
    final canAdd =
        session != null &&
        !session.enrolling &&
        (session.authorized ||
            (!session.authenticating && session.status == 'expired'));
    if (added) {
      return _SetupButton(
        label: l10n.setupFinish,
        primary: true,
        busy: _busy,
        onPressed: _busy ? null : _start,
      );
    }
    return Row(
      children: [
        Expanded(
          child: _SetupButton(
            label: l10n.setupSkip,
            onPressed: _busy ? null : _start,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SetupButton(
            label: l10n.setupFingerprintAdd,
            primary: true,
            busy:
                session != null &&
                (session.authenticating || session.enrolling),
            onPressed: canAdd && !_busy ? _addFingerprint : null,
          ),
        ),
      ],
    );
  }

  Widget _timeZones(BuildContext context) {
    final zones = _zones;
    if (zones == null) return const SizedBox.shrink();
    final search = _zoneSearch.text.trim().toLowerCase();
    final shown = [
      for (final zone in zones.zones)
        if (search.isEmpty ||
            TimeZoneChoices.label(zone).toLowerCase().contains(search))
          zone,
    ];
    // The chosen zone stays in sight above the list.
    if (search.isEmpty && _zone.isNotEmpty) {
      shown
        ..remove(_zone)
        ..insert(0, _zone);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetupField(
          label: context.l10n.setupTimeZoneSearch,
          controller: _zoneSearch,
          icon: Icons.search_rounded,
          keyboardType: TextInputType.text,
        ),
        const SizedBox(height: 12),
        if (shown.isNotEmpty)
          Flexible(
            child: _Island(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: shown.length,
                itemBuilder: (context, index) {
                  final zone = shown[index];
                  return _ChoiceRow(
                    label: TimeZoneChoices.label(zone),
                    selected: zone == _zone,
                    divider: index < shown.length - 1,
                    onTap: () => setState(() => _zone = zone),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// The wallpaper as the phone's app windows show it: the theme's frosted
/// glass and window tint, or its opaque background without transparency.
class _SetupBackdrop extends ConsumerWidget {
  const _SetupBackdrop();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.shellTheme;
    final background = context.shellColors.background;
    return ValueListenableBuilder<FrostedBackdrop?>(
      valueListenable: ref.watch(mobileWallpaperGlassProvider),
      builder: (context, backdrop, _) {
        if (backdrop == null) return ColoredBox(color: background);
        return WindowBackdropCache(
          backdrop: backdrop,
          motion: const AlwaysStoppedAnimation<double>(0),
          child: Builder(
            builder: (context) => Stack(
              fit: StackFit.expand,
              children: [
                WindowBackdropSlice(
                  cache: WindowBackdropCache.maybeOf(context)!,
                  glass: theme.windowGlassShading,
                ),
                ColoredBox(
                  color: theme.forWindowSurfaces().panelColor(background),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The ring around the sensor under the screen while a finger is added, as
/// Settings draws it. Nothing marks it otherwise while the phone is
/// unlocked.
class _SensorRing extends StatelessWidget {
  const _SensorRing(this.sensor);

  /// Panel fractions in its native portrait orientation.
  final Rect sensor;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.width > size.height) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: sensor.left * size.width,
      top: sensor.top * size.height,
      width: sensor.width * size.width,
      height: sensor.height * size.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.shellTheme.accent, width: 3),
          ),
        ),
      ),
    );
  }
}

/// Back, and where the person is among the steps.
class _Header extends StatelessWidget {
  const _Header({
    required this.current,
    required this.count,
    required this.backLabel,
    required this.showBack,
    required this.onBack,
  });

  static const double _size = 44;

  final int current;
  final int count;
  final String backLabel;
  final bool showBack;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _size,
      child: Row(
        children: [
          AnimatedOpacity(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.cardSettle,
            opacity: showBack ? 1 : 0,
            child: IgnorePointer(
              ignoring: !showBack,
              child: _RoundButton(
                size: _size,
                icon: Icons.arrow_back_rounded,
                label: backLabel,
                onPressed: onBack,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _Progress(current: current, count: count),
            ),
          ),
          const SizedBox.square(dimension: _size),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.current, required this.count});

  final int current;
  final int count;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final rest = context.shellColors.textTertiary.withValues(alpha: 0.4);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.cardSettle;
    return Semantics(
      label: '${current + 1} / $count',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < count; index++) ...[
            if (index > 0) const SizedBox(width: 6),
            AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              width: index == current ? 22 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: index < current
                    ? accent.withValues(alpha: 0.55)
                    : index == current
                    ? accent
                    : rest,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The step's picture: its symbol on the accent.
class _HeroIcon extends StatelessWidget {
  const _HeroIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final palette = theme.accentPalette;
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: palette.container,
        borderRadius: theme.borderRadius(20),
      ),
      child: Icon(icon, size: 30, color: palette.onContainer),
    );
  }
}

/// A group's label above its island.
class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: ShellText.base.copyWith(
          color: context.shellColors.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A smoke panel on the frost, as the phone's apps group their content.
class _Island extends StatelessWidget {
  const _Island({required this.child, this.focused = false});

  final Widget child;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final radius = theme.borderRadius(18);
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.tile,
      decoration: BoxDecoration(
        color: theme.cardColor(colors.chip),
        borderRadius: radius,
        border: Border.all(
          color: focused ? theme.accent : colors.hairlineSoft,
          width: 1.5,
        ),
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}

/// What went wrong, on its own red island.
class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.performanceBad.withValues(alpha: 0.16),
        borderRadius: theme.borderRadius(14),
        border: Border.all(color: colors.performanceBad.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: colors.performanceBad,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: ShellText.base.copyWith(
                color: colors.textPrimary,
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Starting extends StatelessWidget {
  const _Starting({required this.name, super.key});

  /// The person's name, whose initial the phone greets them with.
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final palette = theme.accentPalette;
    final trimmed = name.trim();
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.9, end: 1),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.primary,
                shape: BoxShape.circle,
              ),
              child: trimmed.isEmpty
                  ? Icon(
                      Icons.person_rounded,
                      size: 48,
                      color: palette.onPrimary,
                    )
                  : Text(
                      trimmed.characters.first.toUpperCase(),
                      style: ShellText.base.copyWith(
                        color: palette.onPrimary,
                        fontSize: 42,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
            const SizedBox(height: 28),
            Text(
              context.l10n.setupStarting,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: colors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How far the fingerprint is: a ring that fills around the finger.
class _FingerprintRing extends StatelessWidget {
  const _FingerprintRing({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final palette = theme.accentPalette;
    return SizedBox.square(
      dimension: 176,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: progress),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => SizedBox.expand(
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 6,
                strokeCap: StrokeCap.round,
                color: theme.accent,
                backgroundColor: context.shellColors.hairline,
              ),
            ),
          ),
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              color: palette.container,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.fingerprint_rounded,
              size: 76,
              color: palette.onContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupField extends StatefulWidget {
  const _SetupField({
    required this.label,
    required this.controller,
    this.hint,
    this.icon,
    this.autofocus = false,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.onSubmitted,
  });

  final String label;
  final String? hint;
  final IconData? icon;
  final TextEditingController controller;
  final bool autofocus;
  final bool obscure;
  final TextInputType keyboardType;
  final VoidCallback? onSubmitted;

  @override
  State<_SetupField> createState() => _SetupFieldState();
}

class _SetupFieldState extends State<_SetupField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    final focused = _focus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          textField: true,
          obscured: widget.obscure,
          label: widget.label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focus.requestFocus,
            child: _Island(
              focused: focused,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(
                  children: [
                    if (widget.icon case final icon?) ...[
                      Icon(icon, size: 22, color: colors.textSecondary),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.label,
                            style: ShellText.base.copyWith(
                              color: focused
                                  ? theme.accent
                                  : colors.textSecondary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          EditableText(
                            controller: widget.controller,
                            focusNode: _focus,
                            autofocus: widget.autofocus,
                            obscureText: widget.obscure,
                            enableSuggestions: false,
                            autocorrect: false,
                            keyboardType: widget.obscure
                                ? TextInputType.visiblePassword
                                : widget.keyboardType,
                            textInputAction: TextInputAction.next,
                            onSubmitted: (_) => widget.onSubmitted?.call(),
                            style: theme.text.base.copyWith(
                              color: colors.textPrimary,
                              fontSize: 17,
                            ),
                            cursorColor: theme.accent,
                            backgroundCursorColor: colors.textSecondary,
                            selectionColor: theme.accentPalette.container,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.hint case final hint?) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              hint,
              style: ShellText.base.copyWith(
                color: colors.textTertiary,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One row of a choice island, with its mark on the right.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.divider = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// A hairline under it, to the next row.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.tile;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: duration,
          color: selected
              ? theme.accent.withValues(alpha: 0.10)
              : const Color(0x00000000),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.base.copyWith(
                          color: colors.textPrimary,
                          fontSize: 16,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AnimatedContainer(
                      duration: duration,
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: selected
                            ? theme.accent
                            : const Color(0x00000000),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? theme.accent : colors.textTertiary,
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? Icon(
                              Icons.check_rounded,
                              size: 15,
                              color: theme.accentPalette.onPrimary,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
              if (divider)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: SizedBox(
                    height: 1,
                    child: ColoredBox(color: colors.hairlineSoft),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shrinks a little under the finger, as the phone's controls do.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  var _down = false;

  void _press(bool down) {
    if (widget.onTap != null && down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Motion.pill,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.size,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final double size;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: _Pressable(
        onTap: onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: theme.cardColor(colors.chip),
            shape: BoxShape.circle,
            border: Border.all(color: colors.hairlineSoft),
          ),
          child: Icon(icon, size: 22, color: colors.textPrimary),
        ),
      ),
    );
  }
}

class _SetupButton extends StatelessWidget {
  const _SetupButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.busy = false,
  });

  /// Its height, which the page leaves free under itself.
  static const double height = 56;

  final String label;
  final VoidCallback? onPressed;

  /// The step's way forward, on the accent; otherwise a smoke pill.
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final palette = theme.accentPalette;
    final enabled = onPressed != null;
    final foreground = primary ? palette.onPrimary : colors.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onPressed?.call();
              return null;
            },
          ),
        },
        child: _Pressable(
          onTap: onPressed,
          child: AnimatedOpacity(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            opacity: enabled || busy ? 1 : 0.4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: primary ? palette.primary : theme.cardColor(colors.chip),
                borderRadius: BorderRadius.circular(height / 2),
                border: primary ? null : Border.all(color: colors.hairlineSoft),
              ),
              child: SizedBox(
                height: height,
                child: Center(
                  child: busy
                      ? SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: foreground,
                          ),
                        )
                      : Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ShellText.cardTitle.copyWith(
                            color: foreground,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
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
