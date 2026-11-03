import 'dart:async';
import 'dart:io';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent.dart';
import 'card.dart';
import 'controls.dart';
import 'glass.dart';
import 'identity.dart';
import 'secret_field.dart';

/// The authentication card, centered in a transparent overlay canvas.
///
/// Layers, from the desktop up: compositor glass under the card, the card's
/// translucent body and accent aurora, then the reply field and actions on
/// the floating toolbar material that application search fields and actions
/// use, which blurs the aurora at the user's app panel opacity.
class AuthenticationDialog extends StatefulWidget {
  const AuthenticationDialog({
    required this.session,
    required this.appearanceReady,
    required this.durationScale,
    super.key,
  });

  final AgentSession session;

  /// Settings and the accent are known; the card can appear in final colors.
  final bool appearanceReady;
  final double durationScale;

  @override
  State<AuthenticationDialog> createState() => _AuthenticationDialogState();
}

class _AuthenticationDialogState extends State<AuthenticationDialog>
    with SingleTickerProviderStateMixin {
  static const _avatarSize = 72.0;
  static const _accountWidth = 96.0;
  static const _gap = 16.0;

  /// Never keep an authentication request invisible for long, even when the
  /// appearance or the agent's request is late.
  static const _revealDeadline = Duration(milliseconds: 900);

  late final _shake = AnimationController(vsync: this);
  final _secret = TextEditingController();
  final _secretFocus = FocusNode(debugLabel: 'Authentication reply');
  final _profiles = <int, Future<IdentityProfile>>{};
  Timer? _deadline;
  bool _revealed = false;
  bool _capsLock = HardwareKeyboard.instance.lockModesEnabled.contains(
    KeyboardLockMode.capsLock,
  );
  bool _closing = false;
  int _pendingLength = 0;
  int _seenRejections = 0;
  int _seenPrompts = 0;

  AgentSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_sessionChanged);
    _secret.addListener(_secretEdited);
    HardwareKeyboard.instance.addHandler(_keyboard);
    _deadline = Timer(_revealDeadline, () {
      if (mounted) setState(_reveal);
    });
    _syncSession();
  }

  @override
  void didUpdateWidget(AuthenticationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealWhenReady();
  }

  @override
  void dispose() {
    _deadline?.cancel();
    HardwareKeyboard.instance.removeHandler(_keyboard);
    _session.removeListener(_sessionChanged);
    _shake.dispose();
    _secret
      ..clear()
      ..dispose();
    _secretFocus.dispose();
    super.dispose();
  }

  void _revealWhenReady() {
    if (widget.appearanceReady && _session.phase != AgentPhase.connecting) {
      _reveal();
    }
  }

  /// Callers rebuild; the card appears whole, without an entrance.
  void _reveal() {
    if (_revealed) return;
    _revealed = true;
    _deadline?.cancel();
    _focusForPhase();
  }

  void _sessionChanged() => setState(_syncSession);

  void _syncSession() {
    final session = _session;
    if (session.prompts != _seenPrompts) {
      _seenPrompts = session.prompts;
      _pendingLength = 0;
      _secret.clear();
      _focusForPhase();
    }
    if (session.rejections != _seenRejections) {
      _seenRejections = session.rejections;
      _pendingLength = 0;
      _reject();
    }
    if (session.phase == AgentPhase.unavailable) _pendingLength = 0;
    _revealWhenReady();
  }

  void _focusForPhase() {
    if (!_revealed || _session.phase != AgentPhase.prompting) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _session.phase == AgentPhase.prompting) {
        _secretFocus.requestFocus();
      }
    });
  }

  void _reject() {
    if (widget.durationScale == 0) return;
    _shake.duration = Duration(
      milliseconds: (480 * widget.durationScale).round(),
    );
    unawaited(_shake.forward(from: 0));
  }

  void _secretEdited() {
    if (_secret.text.isNotEmpty &&
        _session.notice?.kind == AgentNoticeKind.error) {
      _session.dismissNotice();
    }
  }

  bool _keyboard(KeyEvent event) {
    final capsLock = HardwareKeyboard.instance.lockModesEnabled.contains(
      KeyboardLockMode.capsLock,
    );
    if (capsLock != _capsLock && mounted) setState(() => _capsLock = capsLock);
    return false;
  }

  void _submit() {
    final session = _session;
    switch (session.phase) {
      case AgentPhase.choosing:
        session.start();
      case AgentPhase.prompting:
        final text = _secret.text;
        _pendingLength = session.echo ? 0 : text.characters.length;
        session.respond(text);
        _secret.clear();
      default:
        return;
    }
  }

  /// The agent closes this process after cancellation.
  void _cancel() {
    if (_closing) return;
    _closing = true;
    _session.cancel();
  }

  Future<IdentityProfile> _profile(AgentIdentity identity) =>
      _profiles[identity.uid] ??= loadIdentityProfile(
        identity,
        Platform.environment,
      );

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final palette = PromptPalette.of(theme);
    final session = _session;
    final unavailable = session.phase == AgentPhase.unavailable;
    final prompting = session.phase == AgentPhase.prompting;
    final choosing =
        session.phase == AgentPhase.choosing && session.identities.length > 1;
    final identity = session.selectedIdentity;
    final (described, messageTimeout) = _splitTimeout(session.message.trim());
    final (label, labelTimeout) = _splitTimeout(session.promptLabel);
    final l10n = context.l10n;
    final command = session.command;
    final runAs = session.runAs;
    // With a command to run, say so plainly in the user's language; the
    // requester's own text is kept for every other action.
    final message = command != null
        ? (runAs == null || runAs == 'root'
              ? l10n.polkitRunCommandAsAdministrator
              : l10n.polkitRunCommandAsUser(runAs))
        : described.isNotEmpty
        ? described
        : unavailable
        ? l10n.polkitAuthenticationUnavailable
        : l10n.polkitAuthenticationRequired;

    final account = identity == null ? null : _profile(identity);
    var notice = session.notice;
    var timeout = labelTimeout ?? messageTimeout;
    var locked = false;
    // PAM reports lockout countdowns as a message wrapped in parentheses.
    if (notice != null) {
      final text = notice.text.trim();
      if (text.length > 2 && text.startsWith('(') && text.endsWith(')')) {
        timeout = text.substring(1, text.length - 1).trim();
        notice = null;
        // The account is locked out; no reply can succeed meanwhile.
        locked = true;
      }
    }
    final Widget? reply = unavailable
        ? null
        : choosing
        ? _IdentityList(
            identities: session.identities,
            selectedUid: session.selectedUid,
            profile: _profile,
            onChoose: session.choose,
            onContinue: (uid) {
              session.choose(uid);
              session.start();
            },
          )
        : SecretField(
            controller: _secret,
            focusNode: _secretFocus,
            placeholder: label.isEmpty || label.toLowerCase() == 'password'
                ? l10n.polkitPassword
                : label,
            echo: session.echo,
            enabled: prompting && !locked,
            locked: locked,
            busy: session.phase == AgentPhase.verifying,
            error: notice?.kind == AgentNoticeKind.error,
            pendingLength: _pendingLength,
            capsLock: _capsLock,
            durationScale: widget.durationScale,
            onSubmitted: _submit,
          );

    // Two columns: the account on the leading side; the description, reply
    // and actions beside it. The name shares a row with the reply.
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: _accountWidth,
              child: Center(
                child: _AccountPicture(
                  identity: identity,
                  profile: account,
                  size: _avatarSize,
                ),
              ),
            ),
            const SizedBox(width: _gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    message,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.42,
                      color: palette.foreground,
                    ),
                  ),
                  if (command != null) ...[
                    const SizedBox(height: 10),
                    _CommandLine(command: command),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (reply != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: _accountWidth,
                child: identity == null
                    ? null
                    : _AccountName(identity: identity, profile: account),
              ),
              const SizedBox(width: _gap),
              Expanded(child: reply),
            ],
          ),
        ],
        if (notice != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: _accountWidth + _gap,
            ),
            child: _NoticeLine(notice: notice, palette: palette),
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: timeout == null ? null : _TimeoutBadge(text: timeout),
              ),
            ),
            const SizedBox(width: 20),
            PromptButton(
              label: unavailable ? l10n.polkitClose : l10n.commonCancel,
              autofocus: unavailable,
              onPressed: _cancel,
            ),
            if (!unavailable) ...[
              const SizedBox(width: 10),
              PromptButton(
                label: choosing ? l10n.polkitContinue : l10n.polkitConfirm,
                primary: true,
                // Verification keeps the action legible while inert.
                held: session.phase == AgentPhase.verifying,
                onPressed: (prompting && !locked) || choosing ? _submit : null,
              ),
            ],
          ],
        ),
      ],
    );

    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _cancel();
            return null;
          },
        ),
      },
      child: FocusScope(
        autofocus: true,
        child: PromptCanvas(revealed: _revealed, shake: _shake, child: content),
      ),
    );
  }
}

/// The account's picture, above its name.
class _AccountPicture extends StatelessWidget {
  const _AccountPicture({
    required this.identity,
    required this.profile,
    required this.size,
  });

  final AgentIdentity? identity;
  final Future<IdentityProfile>? profile;
  final double size;

  @override
  Widget build(BuildContext context) => FutureBuilder<IdentityProfile>(
    future: profile,
    builder: (context, snapshot) =>
        _Avatar(identity: identity, profile: snapshot.data, size: size),
  );
}

/// The account's name, level with the reply.
class _AccountName extends StatelessWidget {
  const _AccountName({required this.identity, required this.profile});

  final AgentIdentity identity;
  final Future<IdentityProfile>? profile;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    return FutureBuilder<IdentityProfile>(
      future: profile,
      builder: (context, snapshot) {
        final name = snapshot.data?.displayName ?? identity.name;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: palette.foreground,
              ),
            ),
            if (name != identity.name)
              Text(
                identity.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: palette.tertiary),
              ),
          ],
        );
      },
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.identity,
    required this.profile,
    required this.size,
  });

  /// Absent until the agent names the accounts it accepts.
  final AgentIdentity? identity;
  final IdentityProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final identity = this.identity;
    final name = profile?.displayName ?? identity?.name ?? '';
    final administrator = identity?.uid == 0;
    final monogram = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: administrator ? palette.warning : palette.accent,
      ),
      child: Center(
        child: identity == null || administrator || name.characters.isEmpty
            ? Icon(
                administrator ? Icons.shield_rounded : Icons.lock_rounded,
                size: size * .5,
                color: administrator
                    ? Colors.black.withValues(alpha: .72)
                    : palette.onAccent,
              )
            : Text(
                name.characters.first.toUpperCase(),
                style: TextStyle(
                  fontSize: size * .42,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: palette.onAccent,
                ),
              ),
      ),
    );
    final avatar = profile?.avatar;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: palette.rimTop, width: 1),
        ),
        child: ClipOval(
          child: avatar == null
              ? monogram
              : Image.memory(
                  avatar,
                  fit: BoxFit.cover,
                  cacheWidth: (size * devicePixelRatio).ceil(),
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) => monogram,
                ),
        ),
      ),
    );
  }
}

/// Polkit offers several accounts, such as members of an administrator
/// group. Polkit accepts one selection, so choosing precedes the reply.
/// It takes the reply's place; the account beside it follows the selection.
class _IdentityList extends StatelessWidget {
  const _IdentityList({
    required this.identities,
    required this.selectedUid,
    required this.profile,
    required this.onChoose,
    required this.onContinue,
  });

  static const _rowHeight = 46.0;

  final List<AgentIdentity> identities;
  final int? selectedUid;
  final Future<IdentityProfile> Function(AgentIdentity identity) profile;
  final ValueChanged<int> onChoose;
  final ValueChanged<int> onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = context.applicationColors;
    return DenialMaterial(
      role: DenialMaterialRole.toolbar,
      floating: true,
      inset: DenialApplicationFrame.defaultInset,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _rowHeight * 3),
        child: SingleChildScrollView(
          child: Column(
            children: [
              for (final (index, identity) in identities.indexed) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 50,
                    color: colors.separator,
                  ),
                FutureBuilder<IdentityProfile>(
                  future: profile(identity),
                  builder: (context, snapshot) => _IdentityRow(
                    identity: identity,
                    profile: snapshot.data,
                    height: _rowHeight,
                    selected: identity.uid == selectedUid,
                    onSelect: () => onChoose(identity.uid),
                    onActivate: () => onContinue(identity.uid),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({
    required this.identity,
    required this.profile,
    required this.height,
    required this.selected,
    required this.onSelect,
    required this.onActivate,
  });

  final AgentIdentity identity;
  final IdentityProfile? profile;
  final double height;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    final colors = context.applicationColors;
    final name = profile?.displayName ?? identity.name;
    return Pressable(
      autofocus: selected,
      semanticLabel: name,
      onPressed: onSelect,
      onActivate: onActivate,
      onDoubleTap: onActivate,
      // Selection follows keyboard focus, like a radio group.
      onFocus: onSelect,
      builder: (context, state) => Container(
        height: height,
        color: pressOverlay(colors, state),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _Avatar(identity: identity, profile: profile, size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: selected ? palette.accent : colors.foreground,
                      ),
                    ),
                    if (name != identity.name)
                      TextSpan(
                        text: '  ${identity.name}',
                        style: TextStyle(color: colors.secondary),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 18, color: palette.accent),
          ],
        ),
      ),
    );
  }
}

/// Info and error messages from the PAM conversation and the agent.
class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.notice, required this.palette});

  final AgentNotice notice;
  final PromptPalette palette;

  @override
  Widget build(BuildContext context) {
    final error = notice.kind == AgentNoticeKind.error;
    final color = error ? palette.danger : palette.secondary;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 10, start: 4),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                error
                    ? Icons.error_rounded
                    : notice.text.toLowerCase().contains('finger')
                    ? Icons.fingerprint_rounded
                    : Icons.info_outline_rounded,
                size: 16,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                notice.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 1.35, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _trailingTimeout = RegExp(
  r'\s*\(([^()]*(?:time|expire)[^()]*)\)\s*:?\s*$',
  caseSensitive: false,
);

/// Splits a trailing parenthetical about time, such as "(timeout 30s)", from
/// a message or prompt, so it can be shown as a badge.
(String, String?) _splitTimeout(String text) {
  final match = _trailingTimeout.firstMatch(text);
  if (match == null) return (text, null);
  return (text.substring(0, match.start).trimRight(), match.group(1)!.trim());
}

/// A small corner badge for time limits.
class _TimeoutBadge extends StatelessWidget {
  const _TimeoutBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: palette.warning.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 13, color: palette.warning),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: palette.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The command to run, on one monospace line that scrolls sideways.
class _CommandLine extends StatefulWidget {
  const _CommandLine({required this.command});

  final String command;

  @override
  State<_CommandLine> createState() => _CommandLineState();
}

class _CommandLineState extends State<_CommandLine> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // The wheel turns vertically; this line only moves sideways.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final position = _scroll.position;
    _scroll.jumpTo(
      (_scroll.offset + delta).clamp(0.0, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.applicationColors;
    return Semantics(
      label: widget.command,
      child: Listener(
        onPointerSignal: _wheel,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.foreground.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
            ),
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text(
                widget.command,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontFamily: ShellText.systemBarFontFamily,
                  fontSize: 12.5,
                  height: 1.2,
                  color: colors.foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
