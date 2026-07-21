import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_apps/local_flutter_application.dart';
import '../localization/denial_localizations.dart';
import '../state/shell_appearance.dart';
import '../state/display_layout.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'widgets/focused_border_color_picker.dart';
import 'widgets/settings_appearance_page.dart';

const denialSettingsApplication = LocalFlutterApplication(
  id: 'dev.denial.settings',
  title: 'Settings',
  defaultSize: Size(760, 540),
  minimumSize: Size(480, 360),
  icon: Icons.settings_rounded,
  categories: <String>['Settings', 'System', 'Appearance', 'Preferences'],
  localizedTitle: _localizedSettingsTitle,
  localizedCategories: _localizedSettingsCategories,
  builder: _buildSettingsApplication,
);

String _localizedSettingsTitle(BuildContext context) {
  return context.l10n.settingsApplicationTitle;
}

List<String> _localizedSettingsCategories(BuildContext context) {
  final l10n = context.l10n;
  return <String>[
    l10n.settingsApplicationTitle,
    l10n.settingsApplicationCategorySystem,
    l10n.settingsApplicationCategoryAppearance,
    l10n.settingsApplicationCategoryPreferences,
  ];
}

Widget _buildSettingsApplication(
  BuildContext context,
  LocalFlutterWindowHandle window,
) {
  return const DenialSettingsApplication();
}

class DenialSettingsApplication extends ConsumerStatefulWidget {
  const DenialSettingsApplication({super.key});

  @override
  ConsumerState<DenialSettingsApplication> createState() =>
      _DenialSettingsApplicationState();
}

class _DenialSettingsApplicationState
    extends ConsumerState<DenialSettingsApplication> {
  var _pickerOpen = false;

  void _openPicker() => setState(() => _pickerOpen = true);

  void _closePicker() => setState(() => _pickerOpen = false);

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(shellAppearanceProvider);
    final controller = ref.read(shellAppearanceProvider.notifier);
    final displayLayout = ref.watch(displayLayoutProvider);
    final displayLayoutController = ref.read(displayLayoutProvider.notifier);
    final l10n = context.l10n;
    return Semantics(
      container: true,
      role: .main,
      label: l10n.settingsApplicationSemanticsLabel,
      child: ColoredBox(
        color: ShellColors.background,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SettingsHeader(),
                const Divider(height: 1, color: ShellColors.hairlineSoft),
                Expanded(
                  child: SettingsAppearancePage(
                    focusedBorderColor: appearance.focusedWindowBorderColor,
                    onOpenColorPicker: _openPicker,
                    displayLayout: displayLayout,
                    onSystemBarChanged: (side, monitorIds) {
                      unawaited(
                        displayLayoutController.configureSystemBar(
                          side: side,
                          monitorIds: monitorIds,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: Motion.cardSettle,
                reverseDuration: Motion.tile,
                switchInCurve: Motion.md3EmphasizedDecelerate,
                switchOutCurve: Motion.md3EmphasizedAccelerate,
                child: _pickerOpen
                    ? FocusedBorderColorPicker(
                        key: settingsFocusedBorderColorPickerKey,
                        color: appearance.focusedWindowBorderColor,
                        onChanged: controller.setFocusedWindowBorderColor,
                        onReset: controller.resetFocusedWindowBorderColor,
                        onClose: _closePicker,
                      )
                    : const SizedBox.shrink(
                        key: ValueKey<String>('settings-color-picker-closed'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 22, 16),
      child: Row(
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              color: ShellColors.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(
              dimension: 38,
              child: ExcludeSemantics(
                child: Icon(
                  Icons.settings_rounded,
                  size: 21,
                  color: ShellColors.onPrimaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.settingsApplicationTitle,
              style: ShellText.statusClock,
            ),
          ),
          Text(
            l10n.settingsHeaderContext,
            style: ShellText.cardTitle.copyWith(
              color: ShellColors.textTertiary,
              fontSize: 9,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
