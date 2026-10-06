import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../fingerprint/fingerprint_service.dart';
import 'settings_controls.dart';

class SettingsFingerprintPage extends ConsumerStatefulWidget {
  const SettingsFingerprintPage({super.key});
  @override
  ConsumerState<SettingsFingerprintPage> createState() =>
      _SettingsFingerprintPageState();
}

class _SettingsFingerprintPageState
    extends ConsumerState<SettingsFingerprintPage> {
  final _password = TextEditingController();
  String? _selected;
  bool _adding = false;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  void _authenticate(FingerprintSettingsSession session) {
    final password = _password.text;
    _password.clear();
    session.authenticate(password);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(fingerprintSessionProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final l10n = context.l10n;
        if (!session.authorized) {
          // This branch contains no fingerprint names, counts or enrollment UI.
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.fingerprintPasswordPrompt,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enabled: !session.authenticating,
                      autofocus: true,
                      maxLength: 1024,
                      decoration: InputDecoration(
                        labelText: l10n.fingerprintSudoPassword,
                        counterText: '',
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _authenticate(session),
                    ),
                    if (session.status != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _status(context, session.status!),
                          style: TextStyle(
                            color: context.shellColors.performanceBad,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: session.authenticating
                          ? null
                          : () => _authenticate(session),
                      child: session.authenticating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.fingerprintContinue),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final available = fingerprintNames
            .where((finger) => !session.fingers.contains(finger))
            .toList();
        if (!available.contains(_selected)) _selected = available.firstOrNull;
        return SettingsPageLayout(
          icon: Icons.fingerprint_rounded,
          eyebrow: l10n.fingerprintSection,
          title: l10n.fingerprintDescription,
          children: [
            SettingsCardGroup(
              children: [
                if (session.fingers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.fingerprintEmptyTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.fingerprintEmptyDescription),
                      ],
                    ),
                  )
                else
                  for (final finger in session.fingers)
                    ListTile(
                      leading: const Icon(Icons.fingerprint_rounded),
                      title: Text(fingerprintLabel(context, finger)),
                      trailing: Icon(
                        Icons.check_circle_outline_rounded,
                        color: context.shellTheme.accent,
                      ),
                    ),
              ],
            ),
            if (session.status != null)
              Semantics(
                liveRegion: true,
                child: Text(_status(context, session.status!)),
              ),
            if (session.enrolling) ...[
              LinearProgressIndicator(value: session.completed / session.total),
              Text(l10n.fingerprintProgress(session.completed, session.total)),
              OutlinedButton(
                onPressed: session.cancelEnrollment,
                child: Text(l10n.commonCancel),
              ),
            ] else if (available.isNotEmpty) ...[
              if (_adding || session.fingers.isEmpty) ...[
                DropdownButtonFormField<String>(
                  initialValue: _selected,
                  key: ValueKey(_selected),
                  decoration: InputDecoration(
                    labelText: l10n.fingerprintChooseFinger,
                  ),
                  items: [
                    for (final finger in available)
                      DropdownMenuItem(
                        value: finger,
                        child: Text(fingerprintLabel(context, finger)),
                      ),
                  ],
                  onChanged: (finger) => setState(() => _selected = finger),
                ),
                FilledButton.icon(
                  onPressed: _selected == null
                      ? null
                      : () {
                          setState(() => _adding = false);
                          session.enroll(_selected!);
                        },
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: Text(l10n.fingerprintEnroll),
                ),
              ] else
                FilledButton.icon(
                  onPressed: () => setState(() => _adding = true),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(l10n.fingerprintAdd),
                ),
            ],
          ],
        );
      },
    );
  }
}

String fingerprintLabel(BuildContext context, String finger) {
  final l10n = context.l10n;
  return switch (finger) {
    'left-thumb' => l10n.fingerprintLeftThumb,
    'left-index-finger' => l10n.fingerprintLeftIndex,
    'left-middle-finger' => l10n.fingerprintLeftMiddle,
    'left-ring-finger' => l10n.fingerprintLeftRing,
    'left-little-finger' => l10n.fingerprintLeftLittle,
    'right-thumb' => l10n.fingerprintRightThumb,
    'right-index-finger' => l10n.fingerprintRightIndex,
    'right-middle-finger' => l10n.fingerprintRightMiddle,
    'right-ring-finger' => l10n.fingerprintRightRing,
    'right-little-finger' => l10n.fingerprintRightLittle,
    _ => finger,
  };
}

String _status(BuildContext context, String status) {
  final l10n = context.l10n;
  return switch (status) {
    'authentication-failed' => l10n.fingerprintAuthenticationFailed,
    'expired' => l10n.fingerprintExpired,
    'preparing' => l10n.fingerprintPreparing,
    'started' || 'enroll-stage-passed' => l10n.fingerprintTouchSensor,
    'enroll-completed' => l10n.fingerprintEnrolled,
    'cancelled' => l10n.fingerprintCancelled,
    'enroll-duplicate' || 'already-enrolled' => l10n.fingerprintDuplicate,
    'enroll-retry-scan' ||
    'enroll-swipe-too-short' ||
    'enroll-too-fast' ||
    'enroll-finger-not-centered' ||
    'enroll-remove-and-retry' => l10n.fingerprintRetry,
    _ => l10n.fingerprintUnavailable,
  };
}
