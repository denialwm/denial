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

import '../../widgets/connectivity/wifi_detail_surface.dart';
import '../../widgets/edge_panel_layer.dart';
import 'first_user_account.dart';

/// The device's first start: before it has a person's account, the shell
/// shows this over everything instead of its lock screen and home, and asks
/// for the language, Wi-Fi, time zone, the person's name, username and
/// password, and the device's name. Finishing makes the account; the session
/// then starts again as that person. Nothing shows without the session's
/// [firstUserHelperProvider].
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

enum _Step { language, wifi, timeZone, person, password, device }

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
  SetupLanguage? _language;
  TimeZoneChoices? _zones;
  var _zone = '';

  /// The person typed a username: the name no longer suggests one.
  var _usernameTyped = false;
  var _settingUsername = false;

  String? _error;
  var _busy = false;
  var _made = false;

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
    _ => true,
  };

  void _back() {
    if (_step.index == 0 || _busy) return;
    setState(() {
      _error = null;
      _step = _Step.values[_step.index - 1];
    });
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
      case _Step.device:
        unawaited(_finish());
        return;
      default:
    }
    setState(() {
      _error = error;
      if (error == null) _step = _Step.values[_step.index + 1];
    });
  }

  Future<void> _finish() async {
    final l10n = context.l10n;
    final language = _currentLanguage(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await makeFirstUser(
      widget.helper,
      FirstUserAccount(
        username: _username.text,
        fullName: _name.text,
        password: _password.text,
        deviceName: _deviceName.text,
        language: language,
        timeZone: _zone,
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result.outcome) {
        case FirstUserOutcome.made:
          // The session ends and starts again as the new account.
          _made = true;
          _password.clear();
          _passwordAgain.clear();
        case FirstUserOutcome.exists:
          _error = l10n.setupAccountExists;
        case FirstUserOutcome.notAllowed:
          _error = l10n.setupNotAllowed;
        case FirstUserOutcome.failed:
          _error = l10n.setupFailed(result.message);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ShellWallpaper(),
        ColoredBox(color: colors.overviewScrim),
        MobileKeyboardViewport(
          child: SafeArea(
            minimum: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _made ? const _Starting() : _page(context),
              ),
            ),
          ),
        ),
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
      _Step.device => (l10n.setupDeviceTitle, l10n.setupDeviceBody),
    };
    final connected = ref.watch(
      networkConnectivityProvider.select(
        (state) => state.snapshot.connectedNetwork != null,
      ),
    );
    final nextLabel = switch (_step) {
      _Step.wifi when !connected => l10n.setupSkip,
      _Step.device => l10n.setupFinish,
      _ => l10n.setupNext,
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
        const SizedBox(height: 16),
        Row(
          children: [
            if (_step.index > 0)
              _SetupButton(
                label: l10n.setupBack,
                onPressed: _busy ? null : _back,
              ),
            const Spacer(),
            _SetupButton(
              label: nextLabel,
              emphasized: true,
              busy: _busy,
              onPressed: _canContinue ? _next : null,
            ),
          ],
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
    }
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
              constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
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
