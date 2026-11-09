import 'dart:async';

import 'package:flutter/material.dart'
    show CircularProgressIndicator, Icons, LinearProgressIndicator;
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
import '../../widgets/edge_panel_layer.dart';
import '../../widgets/lock/lock_screen_layer.dart' show PinKeypad;
import '../mobile/mobile_application_scene.dart'
    show mobileWallpaperGlassProvider;
import 'first_user_account.dart';

/// The device's first start: before it has a person's account, the shell
/// shows this over everything instead of its lock screen and home, and asks
/// for the language, Wi-Fi, time zone, the person's name, username and
/// password, a lock PIN on the lock screen's keypad, and the device's name. Finishing makes the account;
/// with a PIN and a fingerprint reader it then offers a fingerprint. The
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
      _step = _Step.values[_step.index - 1];
      if (_step == _Step.pin) _restartPin();
    });
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
        _step = _Step.device;
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
      if (error == null) _step = _Step.values[_step.index + 1];
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
            _step = _Step.fingerprint;
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
    if (!_accountMade) ref.watch(fingerprintDeviceProvider);
    const margin = EdgeInsets.fromLTRB(24, 32, 24, 24);
    Widget column(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: child,
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        const _SetupBackdrop(),
        if (_starting)
          const Center(child: _Starting())
        else ...[
          MobileKeyboardViewport(
            child: SafeArea(
              minimum: margin,
              child: column(
                Padding(
                  // The buttons ride on the keyboard below the page.
                  padding: const EdgeInsets.only(
                    bottom: _SetupButton.height + 16,
                  ),
                  child: _page(context),
                ),
              ),
            ),
          ),
          SafeArea(
            minimum: margin,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: column(
                KeyboardRide(
                  clearance: MediaQuery.paddingOf(context).bottom
                      .clamp(margin.bottom, double.infinity),
                  child: _buttons(context),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _page(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.shellColors;
    final (title, body) = switch (_step) {
      _Step.language => (l10n.setupWelcome, l10n.setupLanguageBody),
      _Step.wifi => (l10n.setupWifiTitle, l10n.setupWifiBody),
      _Step.timeZone => (l10n.setupTimeZoneTitle, null),
      _Step.person => (l10n.setupPersonTitle, null),
      _Step.password => (l10n.setupPasswordTitle, l10n.setupPasswordBody),
      _Step.pin => (l10n.setupPinTitle, l10n.setupPinBody),
      _Step.device => (l10n.setupDeviceTitle, l10n.setupDeviceBody),
      _Step.fingerprint => (
        l10n.setupFingerprintTitle,
        l10n.setupFingerprintBody,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Progress(current: _step.index, count: _Step.values.length),
        const SizedBox(height: 28),
        Text(
          title,
          style: ShellText.base.copyWith(
            color: colors.textPrimary,
            fontSize: 30,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (body != null) ...[
          const SizedBox(height: 8),
          Text(
            body,
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 15,
            ),
          ),
        ],
        const SizedBox(height: 24),
        Expanded(
          child: KeyedSubtree(key: ValueKey(_step), child: _content(context)),
        ),
        if (_error case final error?) ...[
          const SizedBox(height: 12),
          Text(
            error,
            style: ShellText.base.copyWith(
              color: colors.performanceBad,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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
    final nextLabel = switch (_step) {
      _Step.wifi when !connected => l10n.setupSkip,
      _Step.pin => l10n.setupSkip,
      _Step.device => l10n.setupFinish,
      _ => l10n.setupNext,
    };
    return Row(
      children: [
        if (_step.index > 0 && !_accountMade)
          _SetupButton(label: l10n.setupBack, onPressed: _busy ? null : _back),
        const Spacer(),
        _SetupButton(
          label: nextLabel,
          emphasized: true,
          busy: _busy,
          onPressed: _canContinue ? _next : null,
        ),
      ],
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
            _SetupChoice(
              label: l10n.settingsLanguageEnglish,
              selected: language == SetupLanguage.english,
              onTap: () => _chooseLanguage(SetupLanguage.english),
            ),
            const SizedBox(height: 10),
            _SetupChoice(
              label: l10n.settingsLanguageSimplifiedChinese,
              selected: language == SetupLanguage.simplifiedChinese,
              onTap: () => _chooseLanguage(SetupLanguage.simplifiedChinese),
            ),
          ],
        );
      case _Step.wifi:
        return WifiDetailSurface(onClose: _next);
      case _Step.timeZone:
        return _timeZones(context);
      case _Step.person:
        return ListView(
          children: [
            _SetupField(
              label: l10n.setupName,
              controller: _name,
              autofocus: true,
              keyboardType: TextInputType.name,
              onSubmitted: _next,
            ),
            const SizedBox(height: 16),
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
          children: [
            _SetupField(
              label: l10n.setupPassword,
              controller: _password,
              autofocus: true,
              obscure: true,
              onSubmitted: _next,
            ),
            const SizedBox(height: 16),
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
              Text(
                _pinFirst == null ? l10n.setupPin : l10n.setupPinAgain,
                textAlign: TextAlign.center,
                style: ShellText.cardTitle.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
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
          const SizedBox(height: 12),
          Icon(Icons.fingerprint_rounded, size: 88, color: accent),
          const SizedBox(height: 20),
          ?statusText,
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _fingerprintAdded ? 1 : session.completed / session.total,
              minHeight: 4,
              color: accent,
              backgroundColor: colors.hairline,
            ),
          ),
          const SizedBox(height: 8),
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
              dimension: 32,
              child: CircularProgressIndicator(strokeWidth: 3, color: accent),
            ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.fingerprintChooseFinger,
          style: ShellText.cardTitle.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            itemCount: fingerprintNames.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final finger = fingerprintNames[index];
              return _SetupChoice(
                label: fingerprintLabel(context, finger),
                selected: finger == _finger,
                onTap: () => setState(() => _finger = finger),
              );
            },
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
    return Row(
      children: [
        if (!added)
          _SetupButton(label: l10n.setupSkip, onPressed: _busy ? null : _start),
        const Spacer(),
        if (added)
          _SetupButton(
            label: l10n.setupFinish,
            emphasized: true,
            busy: _busy,
            onPressed: _busy ? null : _start,
          )
        else
          _SetupButton(
            label: l10n.setupFingerprintAdd,
            emphasized: true,
            busy:
                session != null &&
                (session.authenticating || session.enrolling),
            onPressed: canAdd && !_busy ? _addFingerprint : null,
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
          keyboardType: TextInputType.text,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            itemCount: shown.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final zone = shown[index];
              return _SetupChoice(
                label: TimeZoneChoices.label(zone),
                selected: zone == _zone,
                onTap: () => setState(() => _zone = zone),
              );
            },
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

class _Starting extends StatelessWidget {
  const _Starting();

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 36,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: ShellTheme.of(context).accent,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.l10n.setupStarting,
          style: ShellText.base.copyWith(
            color: colors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
    final rest = context.shellColors.hairline;
    return Semantics(
      label: '${current + 1} / $count',
      child: Row(
        children: [
          for (var index = 0; index < count; index++) ...[
            if (index > 0) const SizedBox(width: 6),
            Expanded(
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Motion.pill,
                height: 4,
                decoration: BoxDecoration(
                  color: index <= current ? accent : rest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
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
    this.autofocus = false,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.onSubmitted,
  });

  final String label;
  final String? hint;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.label,
          style: ShellText.cardTitle.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 6),
        Semantics(
          textField: true,
          obscured: widget.obscure,
          label: widget.label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focus.requestFocus,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: context.shellTheme.borderRadius(14),
                border: Border.all(
                  color: _focus.hasFocus ? theme.accent : colors.hairline,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                child: EditableText(
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
                  style: context.shellTheme.text.base.copyWith(fontSize: 17),
                  cursorColor: theme.accent,
                  backgroundCursorColor: colors.textSecondary,
                  selectionColor: context.shellTheme.accentPalette.container,
                ),
              ),
            ),
          ),
        ),
        if (widget.hint case final hint?) ...[
          const SizedBox(height: 6),
          Text(
            hint,
            style: ShellText.base.copyWith(
              color: colors.textTertiary,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

class _SetupChoice extends StatelessWidget {
  const _SetupChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : Motion.pill,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? context.shellTheme.accentPalette.container
                : colors.surfaceContainerHigh,
            borderRadius: context.shellTheme.borderRadius(14),
            border: Border.all(
              color: selected ? theme.accent : colors.hairlineSoft,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.base.copyWith(
                    color: selected
                        ? context.shellTheme.accentPalette.onContainer
                        : colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: context.shellTheme.accentPalette.onContainer,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupButton extends StatelessWidget {
  const _SetupButton({
    required this.label,
    required this.onPressed,
    this.emphasized = false,
    this.busy = false,
  });

  /// Its height, which the page leaves free under itself.
  static const double height = 48;

  final String label;
  final VoidCallback? onPressed;
  final bool emphasized;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final palette = context.shellTheme.accentPalette;
    final enabled = onPressed != null;
    final foreground = emphasized ? palette.onContainer : colors.textPrimary;
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: AnimatedOpacity(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            opacity: enabled || busy ? 1 : 0.45,
            child: Container(
              constraints: const BoxConstraints(
                minWidth: 96,
                minHeight: height,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 22),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: emphasized
                    ? palette.container
                    : colors.surfaceContainerHighest,
                borderRadius: context.shellTheme.borderRadius(14),
                border: Border.all(color: colors.hairlineSoft),
              ),
              child: busy
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: foreground,
                      ),
                    )
                  : Text(
                      label,
                      style: ShellText.cardTitle.copyWith(
                        color: foreground,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
