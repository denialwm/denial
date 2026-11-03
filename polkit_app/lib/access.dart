import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

import 'card.dart';
import 'controls.dart';
import 'glass.dart';

/// The Access choice that makes an answer "always" or "never".
const _rememberChoice = 'remember';

/// One of the caller's choices. Without options it is a boolean.
class AccessChoice {
  AccessChoice({
    required this.id,
    required this.label,
    required this.options,
    required this.value,
  });

  final String id;
  final String label;
  final List<(String, String)> options;
  String value;

  bool get boolean => options.isEmpty;
}

enum AccessPhase { connecting, asking, unavailable }

/// Schema-1 client of the Access backend in `denial-portal`.
///
/// The caller decides what the answer means and keeps it; this only shows
/// the question and relays the user's answer.
class AccessSession extends ChangeNotifier {
  Socket? _socket;
  bool _answered = false;

  AccessPhase phase = AccessPhase.connecting;
  String appId = '';
  String title = '';
  String subtitle = '';
  String body = '';
  String grantLabel = '';
  String denyLabel = '';
  List<AccessChoice> choices = const [];

  /// Once-or-always buttons for both answers, instead of a checkbox.
  bool get remembers =>
      choices.any((choice) => choice.id == _rememberChoice && choice.boolean);

  Future<void> connect() async {
    try {
      final path = Platform.environment['DENIAL_ACCESS_SOCKET'];
      final token = Platform.environment['DENIAL_ACCESS_TOKEN'];
      if (path == null || token == null) {
        throw StateError('Start this dialog through denial-portal.');
      }
      final connection = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      _socket = connection;
      _send({'type': 'hello', 'token': token});
      connection
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _receive,
            // The backend ends the dialog once it has the answer.
            onDone: () => exit(0),
            onError: (Object _) => exit(1),
          );
    } catch (_) {
      phase = AccessPhase.unavailable;
      notifyListeners();
    }
  }

  void _send(Map<String, Object?> value) {
    try {
      _socket?.write('${jsonEncode(value)}\n');
    } on SocketException {
      exit(1);
    }
  }

  void _receive(String line) {
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      return;
    }
    if (event['type'] != 'request') return;
    appId = event['appId'] as String? ?? '';
    title = event['title'] as String? ?? '';
    subtitle = event['subtitle'] as String? ?? '';
    body = event['body'] as String? ?? '';
    grantLabel = event['grantLabel'] as String? ?? '';
    denyLabel = event['denyLabel'] as String? ?? '';
    choices = [
      for (final choice in event['choices'] as List? ?? const [])
        if (choice case {
          'id': final String id,
          'label': final String label,
          'initial': final String initial,
        })
          AccessChoice(
            id: id,
            label: label,
            options: [
              for (final option in choice['options'] as List? ?? const [])
                if (option case {
                  'id': final String id,
                  'label': final String label,
                })
                  (id, label),
            ],
            value: initial,
          ),
    ];
    phase = AccessPhase.asking;
    notifyListeners();
  }

  void choose(AccessChoice choice, String value) {
    choice.value = value;
    notifyListeners();
  }

  /// Grants, remembering the answer when [always] says so.
  void grant({bool always = false}) => _answer(grant: true, always: always);

  /// Denies, remembering the answer when [always] says so.
  void deny({bool always = false}) {
    if (_socket == null) exit(0);
    _answer(grant: false, always: always);
  }

  void _answer({required bool grant, required bool always}) {
    if (_answered) return;
    _answered = true;
    _send({
      'type': 'answer',
      'grant': grant,
      'choices': {
        for (final choice in choices)
          choice.id: choice.id == _rememberChoice && remembers
              ? '$always'
              : choice.value,
      },
    });
  }

  @override
  void dispose() {
    _socket?.destroy();
    super.dispose();
  }
}

/// The app's desktop entry, matched by its app ID.
Future<DesktopApp?> _desktopApp(String appId) async {
  if (appId.isEmpty) return null;
  final apps = await DesktopAppsRepository(
    paths: RuntimePaths(environment: Platform.environment),
  ).loadApplications();
  final lower = appId.toLowerCase();
  for (final app in apps) {
    if (app.id == '$appId.desktop' ||
        app.id == appId ||
        app.startupWmClass?.toLowerCase() == lower) {
      return app;
    }
  }
  return null;
}

/// Asks whether an app may have something, in the authentication card's
/// look: the app on the leading side, the question and answers beside it.
class AccessDialog extends StatefulWidget {
  const AccessDialog({
    required this.session,
    required this.appearanceReady,
    super.key,
  });

  final AccessSession session;

  /// Settings and the accent are known; the card can appear in final colors.
  final bool appearanceReady;

  @override
  State<AccessDialog> createState() => _AccessDialogState();
}

class _AccessDialogState extends State<AccessDialog> {
  static const _iconSize = 64.0;
  static const _appWidth = 96.0;
  static const _gap = 16.0;

  /// Never keep a request invisible for long, even when the appearance or
  /// the request is late.
  static const _revealDeadline = Duration(milliseconds: 900);

  Timer? _deadline;
  bool _revealed = false;
  Future<DesktopApp?>? _app;

  AccessSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_sessionChanged);
    _deadline = Timer(_revealDeadline, () {
      if (mounted) setState(_reveal);
    });
  }

  @override
  void didUpdateWidget(AccessDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealWhenReady();
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _session.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() => setState(() {
    if (_session.phase == AccessPhase.asking) {
      _app ??= _desktopApp(_session.appId);
    }
    _revealWhenReady();
  });

  void _revealWhenReady() {
    if (widget.appearanceReady && _session.phase != AccessPhase.connecting) {
      _reveal();
    }
  }

  void _reveal() {
    if (_revealed) return;
    _revealed = true;
    _deadline?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    final l10n = context.l10n;
    final session = _session;
    final asking = session.phase == AccessPhase.asking;
    final remembers = session.remembers;
    final shownChoices = [
      for (final choice in session.choices)
        if (!(remembers && choice.id == _rememberChoice)) choice,
    ];

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _appWidth,
              child: _AppIdentity(
                app: _app,
                appId: session.appId,
                size: _iconSize,
              ),
            ),
            const SizedBox(width: _gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    session.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.32,
                      fontWeight: FontWeight.w600,
                      color: palette.foreground,
                    ),
                  ),
                  if (session.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      session.subtitle,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.42,
                        color: palette.foreground,
                      ),
                    ),
                  ],
                  if (session.body.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      session.body,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: palette.secondary,
                      ),
                    ),
                  ],
                  for (final choice in shownChoices)
                    _ChoiceRow(
                      choice: choice,
                      onChanged: (value) => session.choose(choice, value),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (remembers)
          // "Allow once" is the colored answer: allowing for good is there,
          // but takes a deliberate choice.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ButtonRow(
                children: [
                  PromptButton(
                    label: l10n.accessAlwaysAllow,
                    onPressed: asking
                        ? () => session.grant(always: true)
                        : null,
                  ),
                  PromptButton(
                    label: l10n.accessAllowOnce,
                    primary: true,
                    onPressed: asking ? session.grant : null,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _ButtonRow(
                children: [
                  PromptButton(
                    label: l10n.accessNeverAllow,
                    onPressed: asking ? () => session.deny(always: true) : null,
                  ),
                  PromptButton(
                    label: l10n.accessDeclineOnce,
                    onPressed: session.deny,
                  ),
                ],
              ),
            ],
          )
        else
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 10,
            children: [
              PromptButton(
                label: session.denyLabel.isNotEmpty
                    ? session.denyLabel
                    : l10n.accessDecline,
                onPressed: session.deny,
              ),
              PromptButton(
                label: session.grantLabel.isNotEmpty
                    ? session.grantLabel
                    : l10n.accessAllow,
                primary: true,
                onPressed: asking ? session.grant : null,
              ),
            ],
          ),
      ],
    );

    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            session.deny();
            return null;
          },
        ),
      },
      child: FocusScope(
        autofocus: true,
        child: PromptCanvas(revealed: _revealed, child: content),
      ),
    );
  }
}

/// Buttons sharing a row's width equally.
class _ButtonRow extends StatelessWidget {
  const _ButtonRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) const SizedBox(width: 10),
        Expanded(child: children[index]),
      ],
    ],
  );
}

/// The app's icon, above its name.
class _AppIdentity extends StatelessWidget {
  const _AppIdentity({
    required this.app,
    required this.appId,
    required this.size,
  });

  final Future<DesktopApp?>? app;
  final String appId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    return FutureBuilder<DesktopApp?>(
      future: app,
      builder: (context, snapshot) {
        final app = snapshot.data;
        final name =
            app?.name ??
            (appId.isEmpty ? context.l10n.accessUnknownApp : appId);
        return Column(
          children: [
            SizedBox.square(
              dimension: size,
              child: AppIconImage(iconPath: app?.iconPath),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: palette.secondary,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A caller's choice: a switch for a boolean, otherwise one option of a row.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.choice, required this.onChanged});

  final AccessChoice choice;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    final label = Text(
      choice.label,
      style: TextStyle(fontSize: 13.5, color: palette.foreground),
    );
    if (choice.boolean) {
      final on = choice.value == 'true';
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            Expanded(child: label),
            Switch(
              value: on,
              activeThumbColor: palette.accent,
              onChanged: (value) => onChanged('$value'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (id, optionLabel) in choice.options)
                PromptButton(
                  label: optionLabel,
                  primary: id == choice.value,
                  onPressed: () => onChanged(id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
