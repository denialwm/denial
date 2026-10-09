import 'package:denial_flutter_sdk/localization.dart';

import 'controller.dart';
import 'job_feedback.dart';
import 'selection_status.dart';
import 'setup_status.dart';

/// Backend labels are protocol values, not translations or UI fallbacks.
/// Unknown future phases retain localized generic copy; diagnostics remain
/// available verbatim in Technical details and Build log.
String progressLabel(AppLocalizations l10n, String label) => switch (label) {
  'Waiting to start' => l10n.pluginsWaitingStart,
  'Preparing your plugins' => l10n.pluginsPreparingPlugins,
  'Checking plugin compatibility' => l10n.pluginsCheckingCompatibility,
  'Preparing your desktop build' => l10n.pluginsPreparingBuild,
  'Compiling Dart sources' => l10n.pluginsCompilingSources,
  'Optimizing and generating native code' => l10n.pluginsOptimizing,
  'Preparing assets' => l10n.pluginsPreparingAssets,
  'Loading your saved desktop' => l10n.pluginsLoadingDesktop,
  'Compiling your desktop' => l10n.pluginsCompilingDesktop,
  'Verifying your desktop' => l10n.pluginsVerifyingDesktop,
  'Switching when you pause' => l10n.pluginsSwitchingPause,
  'Applying and checking your desktop' => l10n.pluginsApplyingDesktop,
  'Verifying plugin tools' => l10n.pluginsVerifyingTools,
  'Preparing plugin tools' => l10n.pluginsPreparingTools,
  'Completed' => l10n.pluginsCompleted,
  _ => l10n.pluginsWorking,
};

String progressStage(AppLocalizations l10n, OperationProgress progress) =>
    progress.total == null
    ? l10n.pluginsCloseWhileWorking
    : progress.completed == progress.total
    ? l10n.pluginsCompleted
    : l10n.pluginsStep(
        progress.completed! + 1,
        progress.total!,
        progressLabel(l10n, progress.label),
      );

String progressDescription(
  AppLocalizations l10n,
  OperationProgress progress,
  DateTime now,
) {
  final stage = progressStage(l10n, progress);
  final clock = progress.elapsedClockAt(now);
  return clock == null ? stage : l10n.pluginsElapsed(stage, clock);
}

String localizedFailureSummary(AppLocalizations l10n, String error) =>
    switch (failureKind(error)) {
      FailureKind.engine => l10n.pluginsFailureEngine,
      FailureKind.version => l10n.pluginsFailureVersion,
      FailureKind.declaration => l10n.pluginsFailureDeclaration,
      FailureKind.conflict => l10n.pluginsFailureConflict,
      FailureKind.panel => l10n.pluginsFailurePanel,
      FailureKind.missing => l10n.pluginsFailureMissing,
      FailureKind.login => l10n.pluginsFailureLogin,
      FailureKind.worker => l10n.pluginsFailureWorker,
      FailureKind.download => l10n.pluginsFailureDownload,
      FailureKind.toolsUnavailable => l10n.pluginsToolsUnavailable,
      FailureKind.generic => l10n.pluginsFailureGeneric,
    };

String setupTitle(AppLocalizations l10n, SetupNotice notice) =>
    switch (notice.problem) {
      SetupProblem.missingDart => l10n.pluginsDartRequired,
      SetupProblem.incompatibleDart => l10n.pluginsDartCompatible,
      SetupProblem.tools => l10n.pluginsToolsAttention,
    };

String setupDescription(AppLocalizations l10n, SetupNotice notice) =>
    switch (notice.problem) {
      SetupProblem.missingDart => l10n.pluginsDartInstall(notice.expected!),
      SetupProblem.incompatibleDart => l10n.pluginsDartIncompatible(
        notice.installed!,
        notice.constraint!,
      ),
      SetupProblem.tools => l10n.pluginsSetupFailed,
    };

String? applyLabel(AppLocalizations l10n, ManagerController controller) =>
    !controller.needsApply
    ? null
    : controller.pendingRebuild != null
    ? l10n.pluginsRebuild
    : controller.draft.dirty
    ? l10n.pluginsApplyChanges
    : l10n.pluginsApplyPending;

String applyDescription(AppLocalizations l10n, ManagerController controller) {
  if (controller.pendingRebuild case final rebuild?) {
    final version = rebuildVersion(rebuild);
    return l10n.pluginsRebuildDescription(
      version == null
          ? l10n.pluginsUpdated
          : l10n.pluginsInstalledVersion(version),
    );
  }
  return controller.draft.dirty
      ? selectionNeedsApply(controller.state)
            ? l10n.pluginsApplySelectionUpdates
            : l10n.pluginsApplySelection
      : l10n.pluginsApplyUnchanged;
}

/// Use structured preflight facts. Package names and plugin-authored contract
/// labels remain metadata; do not translate them by guessing English text.
String compatibilitySummary(AppLocalizations l10n, Map<String, Object?> issue) {
  final requirement = issue['requirement'] as Map? ?? const {};
  final feature =
      requirement['contract'] ==
              'package:denial_flutter_sdk/application.dart#ShellApplication' &&
          requirement['owner'] == 'Denial'
      ? l10n.pluginsDesktopFeature
      : requirement['label'] as String? ?? issue['contract'] as String? ?? '';
  final plugins = (issue['plugins'] as List? ?? const []).join(', ');
  final owner = requirement['owner'] as String? ?? 'Denial';
  return switch (issue['code']) {
    'stale_selection' => l10n.pluginsStaleSelection,
    'too_many_providers' => l10n.pluginsProviderConflict(
      feature,
      plugins,
      owner,
      requirement['max']! as int,
    ),
    'missing_provider' => l10n.pluginsProviderMissing(
      owner,
      requirement['min']! as int,
      feature,
    ),
    'invalid_declaration' => l10n.pluginsInvalidDeclaration(plugins),
    _ => l10n.pluginsFailureGeneric,
  };
}
