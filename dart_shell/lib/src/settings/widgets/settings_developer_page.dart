import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../models/ui_development.dart';
import '../../state/ui_development.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import 'settings_controls.dart';

const settingsDeveloperWorkspaceFieldKey = ValueKey<String>(
  'settings-developer-workspace-field',
);
const settingsDeveloperLiveToggleKey = ValueKey<String>(
  'settings-developer-live-toggle',
);

class SettingsDeveloperPage extends StatefulWidget {
  const SettingsDeveloperPage({
    required this.state,
    required this.controller,
    required this.workspaceSetup,
    super.key,
  });

  final DenialUiDevelopmentState state;
  final UiDevelopmentController controller;
  final UiWorkspaceSetupService workspaceSetup;

  @override
  State<SettingsDeveloperPage> createState() => _SettingsDeveloperPageState();
}

class _SettingsDeveloperPageState extends State<SettingsDeveloperPage> {
  late final TextEditingController _workspaceController;
  late final FocusNode _workspaceFocus;
  var _setupRunning = false;
  var _setupError = '';

  @override
  void initState() {
    super.initState();
    _workspaceController = TextEditingController(text: widget.state.workspace);
    _workspaceFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant SettingsDeveloperPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_workspaceFocus.hasFocus &&
        oldWidget.state.workspace != widget.state.workspace &&
        _workspaceController.text != widget.state.workspace) {
      _workspaceController.text = widget.state.workspace;
    }
  }

  @override
  void dispose() {
    _workspaceFocus.dispose();
    _workspaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final controller = widget.controller;
    final l10n = context.l10n;
    final liveControlsEnabled =
        state.activeMode == DenialUiRuntimeMode.liveDevelopment && !state.busy;
    final workspaceControlsEnabled =
        !state.busy &&
        !_setupRunning &&
        state.activeMode != DenialUiRuntimeMode.liveDevelopment &&
        state.desiredMode != DenialUiRuntimeMode.liveDevelopment;
    return SettingsPageLayout(
      icon: Icons.code_rounded,
      eyebrow: l10n.settingsDeveloperSection,
      title: l10n.settingsDeveloperDescription,
      onReset: controller.restoreOfficial,
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsDeveloperRuntimeTitle,
              status: _modeLabel(context, state.activeMode),
              leading: _RuntimeStatusDot(state: state),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RuntimeSummary(state: state),
                  const SizedBox(height: 15),
                  SettingsToggle(
                    key: settingsDeveloperLiveToggleKey,
                    label: l10n.settingsDeveloperEnableTitle,
                    description: l10n.settingsDeveloperEnableDescription,
                    value: state.liveDevelopmentEnabled,
                    enabled:
                        !state.busy &&
                        (state.liveDevelopmentEnabled ||
                            (state.developerComponentsAvailable &&
                                state.workspaceValid)),
                    onChanged: controller.setLiveDevelopmentEnabled,
                  ),
                  const SizedBox(height: 14),
                  _WarningBanner(
                    text: l10n.settingsDeveloperPerformanceWarning,
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsDeveloperWorkspaceTitle,
              status: state.workspaceValid
                  ? l10n.settingsDeveloperWorkspaceReady
                  : l10n.settingsDeveloperWorkspaceNotReady,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _WorkspaceSetupPanel(
                    available: widget.workspaceSetup.available,
                    running: _setupRunning,
                    error: _setupError,
                    enabled: workspaceControlsEnabled,
                    onPressed: _setupWorkspace,
                  ),
                  const SizedBox(height: 15),
                  Divider(height: 1, color: context.shellColors.hairlineSoft),
                  const SizedBox(height: 15),
                  Text(
                    l10n.settingsDeveloperWorkspaceDescription,
                    style: ShellText.base.copyWith(
                      color: context.shellColors.textTertiary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _WorkspaceField(
                    controller: _workspaceController,
                    focusNode: _workspaceFocus,
                    enabled: workspaceControlsEnabled,
                    onSubmitted: _applyWorkspace,
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SettingsTextButton(
                      label: l10n.settingsDeveloperUseWorkspace,
                      onPressed: workspaceControlsEnabled
                          ? _applyWorkspace
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsDeveloperLiveControlsTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsToggle(
                    label: l10n.settingsDeveloperAutoReloadTitle,
                    description: l10n.settingsDeveloperAutoReloadDescription,
                    value: state.autoReload,
                    enabled:
                        state.autoReloadSupported &&
                        state.workspaceValid &&
                        !state.busy,
                    onChanged: controller.setAutoReload,
                  ),
                  const SizedBox(height: 15),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SettingsTextButton(
                        label: l10n.settingsDeveloperHotReload,
                        onPressed: liveControlsEnabled && state.canHotReload
                            ? controller.hotReload
                            : null,
                      ),
                      SettingsTextButton(
                        label: l10n.settingsDeveloperHotRestart,
                        onPressed: liveControlsEnabled && state.canHotRestart
                            ? controller.hotRestart
                            : null,
                      ),
                      SettingsTextButton(
                        label: l10n.settingsDeveloperRefreshStatus,
                        onPressed: state.busy ? null : controller.refresh,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsDeveloperBuildRecoveryTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.settingsDeveloperBuildRecoveryDescription,
                    style: ShellText.base.copyWith(
                      color: context.shellColors.textTertiary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SettingsTextButton(
                        label: l10n.settingsDeveloperBuildOptimized,
                        onPressed: state.canBuildOptimized && !state.busy
                            ? controller.buildAndActivateOptimized
                            : null,
                      ),
                      SettingsTextButton(
                        label: l10n.settingsDeveloperRevertLastWorking,
                        onPressed: state.canRevert && !state.busy
                            ? controller.revertLastWorking
                            : null,
                      ),
                      SettingsTextButton(
                        label: l10n.settingsDeveloperRestoreOfficial,
                        onPressed:
                            state.activeMode !=
                                    DenialUiRuntimeMode.officialOptimized &&
                                !state.busy
                            ? controller.restoreOfficial
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsDeveloperDiagnosticsTitle,
              status: state.generation == 0
                  ? null
                  : '${l10n.settingsDeveloperGeneration} ${state.generation}',
              child: _Diagnostics(state: state),
            ),
          ],
        ),
      ],
    );
  }

  void _applyWorkspace() {
    if (widget.controller.setWorkspace(_workspaceController.text)) {
      _workspaceFocus.unfocus();
    }
  }

  Future<void> _setupWorkspace() async {
    if (_setupRunning) {
      return;
    }
    setState(() {
      _setupRunning = true;
      _setupError = '';
    });
    try {
      await widget.workspaceSetup.setup();
      if (!mounted) {
        return;
      }
      widget.controller.refresh();
      setState(() {
        _setupRunning = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _setupRunning = false;
        _setupError = error.toString();
      });
    }
  }

  String _modeLabel(BuildContext context, DenialUiRuntimeMode mode) {
    final l10n = context.l10n;
    return switch (mode) {
      DenialUiRuntimeMode.officialOptimized =>
        l10n.settingsDeveloperModeOfficial,
      DenialUiRuntimeMode.customOptimized => l10n.settingsDeveloperModeCustom,
      DenialUiRuntimeMode.liveDevelopment => l10n.settingsDeveloperModeLive,
      DenialUiRuntimeMode.unavailable => l10n.settingsDeveloperModeUnavailable,
    };
  }
}

class _WorkspaceSetupPanel extends StatelessWidget {
  const _WorkspaceSetupPanel({
    required this.available,
    required this.running,
    required this.error,
    required this.enabled,
    required this.onPressed,
  });

  final bool available;
  final bool running;
  final String error;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = error.isNotEmpty
        ? error
        : running
        ? l10n.settingsDeveloperSetupRunning
        : !available
        ? l10n.settingsDeveloperSetupUnavailable
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.settingsDeveloperSetupDescription,
          style: ShellText.base.copyWith(
            color: context.shellColors.textSecondary,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: SettingsTextButton(
            label: l10n.settingsDeveloperSetupAction,
            onPressed: available && enabled && !running ? onPressed : null,
          ),
        ),
        if (status.isNotEmpty) ...[
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            label: status,
            child: Text(
              status,
              style: ShellText.base.copyWith(
                color: error.isNotEmpty
                    ? context.shellColors.performanceBad
                    : context.shellColors.textTertiary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
        if (running) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
            minHeight: 4,
            borderRadius: BorderRadius.circular(99),
            color: ShellTheme.of(context).accent,
            backgroundColor: context.shellColors.surfaceContainerHighest,
          ),
        ],
      ],
    );
  }
}

class _WorkspaceField extends StatelessWidget {
  const _WorkspaceField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      textField: true,
      label: context.l10n.settingsDeveloperWorkspaceFieldLabel,
      child: MouseRegion(
        cursor: ShellMouseCursors.text,
        child: TextField(
          key: settingsDeveloperWorkspaceFieldKey,
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmitted(),
          style: ShellText.base.copyWith(
            color: context.shellColors.textPrimary,
            fontFamily: ShellText.systemBarFontFamily,
            fontSize: 12,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: context.l10n.settingsDeveloperWorkspaceHint,
            hintStyle: ShellText.base.copyWith(
              color: context.shellColors.textTertiary,
              fontSize: 12,
            ),
            filled: true,
            fillColor: context.shellColors.surfaceContainerHigh,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 13,
              vertical: 12,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              borderSide: BorderSide(color: context.shellColors.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              borderSide: BorderSide(color: accent),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              borderSide: BorderSide(color: context.shellColors.hairlineSoft),
            ),
          ),
        ),
      ),
    );
  }
}

class _RuntimeStatusDot extends StatelessWidget {
  const _RuntimeStatusDot({required this.state});

  final DenialUiDevelopmentState state;

  @override
  Widget build(BuildContext context) {
    final color = state.error.isNotEmpty
        ? context.shellColors.performanceBad
        : state.busy
        ? context.shellColors.performanceWarning
        : state.activeMode == DenialUiRuntimeMode.liveDevelopment
        ? ShellTheme.of(context).accent
        : context.shellColors.performanceGood;
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _RuntimeSummary extends StatelessWidget {
  const _RuntimeSummary({required this.state});

  final DenialUiDevelopmentState state;

  @override
  Widget build(BuildContext context) {
    final text = state.error.isNotEmpty
        ? state.error
        : state.status.isNotEmpty
        ? state.status
        : context.l10n.settingsDeveloperWaitingForStatus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          text,
          style: ShellText.base.copyWith(
            color: state.error.isNotEmpty
                ? context.shellColors.performanceBad
                : context.shellColors.textSecondary,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        if (state.progress case final progress?) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(99),
            color: ShellTheme.of(context).accent,
            backgroundColor: context.shellColors.surfaceContainerHighest,
          ),
        ],
      ],
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.performanceWarning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.shellColors.performanceWarning.withValues(alpha: 0.28),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.speed_rounded,
              size: 16,
              color: context.shellColors.performanceWarning,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                text,
                style: ShellText.base.copyWith(
                  color: context.shellColors.textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.state});

  final DenialUiDevelopmentState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.vmServiceAvailable && state.vmServiceUri.isNotEmpty) ...[
          Text(
            l10n.settingsDeveloperVmServiceTitle,
            style: ShellText.cardTitle.copyWith(
              color: context.shellColors.textSecondary,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            state.vmServiceUri,
            style: ShellText.base.copyWith(
              color: ShellTheme.of(context).accent,
              fontFamily: ShellText.systemBarFontFamily,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            l10n.settingsDeveloperEditorAttachDescription,
            style: ShellText.base.copyWith(
              color: context.shellColors.textTertiary,
              fontSize: 11,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (state.diagnostics.isEmpty)
          Text(
            l10n.settingsDeveloperNoDiagnostics,
            style: ShellText.base.copyWith(
              color: context.shellColors.textTertiary,
              fontSize: 12,
            ),
          )
        else
          for (final diagnostic in state.diagnostics)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _DiagnosticRow(diagnostic: diagnostic),
            ),
      ],
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.diagnostic});

  final DenialUiDiagnostic diagnostic;

  @override
  Widget build(BuildContext context) {
    final color = switch (diagnostic.severity) {
      DenialUiDiagnosticSeverity.information => ShellTheme.of(context).accent,
      DenialUiDiagnosticSeverity.warning =>
        context.shellColors.performanceWarning,
      DenialUiDiagnosticSeverity.error => context.shellColors.performanceBad,
    };
    final location = diagnostic.path.isEmpty
        ? ''
        : diagnostic.line == 0
        ? diagnostic.path
        : '${diagnostic.path}:${diagnostic.line}:${diagnostic.column}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                diagnostic.message,
                style: ShellText.base.copyWith(
                  color: context.shellColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              if (location.isNotEmpty) ...[
                const SizedBox(height: 3),
                SelectableText(
                  location,
                  style: ShellText.base.copyWith(
                    color: context.shellColors.textTertiary,
                    fontFamily: ShellText.systemBarFontFamily,
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
