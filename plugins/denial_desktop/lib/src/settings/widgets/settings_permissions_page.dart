import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/materials.dart';

import 'settings_controls.dart';

/// Each app's stored answer for each permission it asked for.
class SettingsPermissionsPage extends ConsumerStatefulWidget {
  const SettingsPermissionsPage({required this.applications, super.key});

  /// Names and icons for the apps' IDs.
  final List<DesktopApp> applications;

  @override
  ConsumerState<SettingsPermissionsPage> createState() =>
      _SettingsPermissionsPageState();
}

class _SettingsPermissionsPageState
    extends ConsumerState<SettingsPermissionsPage> {
  bool _saveFailed = false;

  Future<void> _set(
    AppPermission permission,
    String appId,
    AppPermissionAnswer answer,
  ) async {
    setState(() => _saveFailed = false);
    try {
      await ref
          .read(appPermissionsServiceProvider)
          .set(permission, appId, answer);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final answers = ref.watch(appPermissionsProvider);
    return SettingsPageLayout(
      icon: Icons.shield_outlined,
      eyebrow: l10n.settingsPermissionsSection,
      title: l10n.settingsPermissionsTitle,
      footer: SettingsErrorNotice(
        message: _saveFailed ? l10n.settingsPermissionsSaveFailed : null,
      ),
      children: [
        for (final permission in AppPermission.values)
          _PermissionCard(
            permission: permission,
            answers: answers,
            applications: widget.applications,
            onChanged: (appId, answer) =>
                unawaited(_set(permission, appId, answer)),
          ),
      ],
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.permission,
    required this.answers,
    required this.applications,
    required this.onChanged,
  });

  final AppPermission permission;
  final AsyncValue<AppPermissionAnswers> answers;
  final List<DesktopApp> applications;
  final void Function(String appId, AppPermissionAnswer answer) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (title, description) = switch (permission) {
      AppPermission.keyboardShortcuts => (
        l10n.settingsPermissionsKeyboardShortcutsTitle,
        l10n.settingsPermissionsKeyboardShortcutsDescription,
      ),
    };
    final apps = [
      for (final MapEntry(key: appId, value: answer)
          in (answers.value?[permission] ?? const {}).entries)
        (appId: appId, app: _desktopApp(appId), answer: answer),
    ]..sort((a, b) => _name(a.app, a.appId).compareTo(_name(b.app, b.appId)));
    final String? notice;
    if (answers.hasError && !answers.hasValue) {
      notice = l10n.settingsPermissionsUnavailable;
    } else if (answers.hasValue && apps.isEmpty) {
      notice = l10n.settingsPermissionsNone;
    } else {
      notice = null;
    }
    return SettingsCardGroup(
      title: title,
      description: description,
      children: [
        if (notice != null)
          SettingsCardPadding(
            child: Text(
              notice,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: context.applicationColors.secondary),
            ),
          ),
        for (final entry in apps)
          SettingsCardPadding(
            key: ValueKey<String>(
              'permission-${permission.name}-${entry.appId}',
            ),
            child: SettingsControlRow(
              leading: SizedBox.square(
                dimension: 32,
                child: AppIconImage(iconPath: entry.app?.iconPath),
              ),
              label: _name(entry.app, entry.appId),
              description: entry.app == null ? '' : entry.appId,
              control: SettingsSegmentedControl<AppPermissionAnswer>(
                value: entry.answer,
                choices: [
                  SettingsChoice(
                    AppPermissionAnswer.ask,
                    l10n.settingsPermissionAsk,
                  ),
                  SettingsChoice(
                    AppPermissionAnswer.allow,
                    l10n.settingsPermissionAllow,
                  ),
                  SettingsChoice(
                    AppPermissionAnswer.deny,
                    l10n.settingsPermissionDeny,
                  ),
                ],
                onChanged: (answer) {
                  if (answer != entry.answer) onChanged(entry.appId, answer);
                },
              ),
            ),
          ),
      ],
    );
  }

  /// The desktop entry of the app that asked, matched by its Wayland app ID.
  DesktopApp? _desktopApp(String appId) {
    final id = appId.toLowerCase();
    for (final app in applications) {
      if (app.id.toLowerCase().replaceFirst(RegExp(r'\.desktop$'), '') == id ||
          app.startupWmClass?.toLowerCase() == id) {
        return app;
      }
    }
    return null;
  }

  static String _name(DesktopApp? app, String appId) => app?.name ?? appId;
}
