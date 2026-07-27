enum DenialUiRuntimeMode {
  officialOptimized,
  customOptimized,
  liveDevelopment,
  unavailable,
}

enum DenialUiDevelopmentOperation {
  idle,
  validatingWorkspace,
  switchingRuntime,
  hotReloading,
  hotRestarting,
  buildingOptimized,
  reverting,
}

enum DenialUiDiagnosticSeverity { information, warning, error }

class DenialUiDiagnostic {
  const DenialUiDiagnostic({
    required this.severity,
    required this.message,
    this.path = '',
    this.line = 0,
    this.column = 0,
  });

  final DenialUiDiagnosticSeverity severity;
  final String message;
  final String path;
  final int line;
  final int column;
}

class DenialUiDevelopmentState {
  const DenialUiDevelopmentState({
    required this.activeMode,
    required this.desiredMode,
    required this.operation,
    required this.developerComponentsAvailable,
    required this.workspaceValid,
    required this.autoReload,
    required this.autoReloadSupported,
    required this.canHotReload,
    required this.canHotRestart,
    required this.canBuildOptimized,
    required this.canRevert,
    required this.vmServiceAvailable,
    required this.generation,
    required this.revision,
    required this.acknowledgedRequestId,
    required this.workspace,
    required this.vmServiceUri,
    required this.status,
    required this.error,
    required this.diagnostics,
    this.progress,
  });

  factory DenialUiDevelopmentState.connecting() {
    return const DenialUiDevelopmentState(
      activeMode: DenialUiRuntimeMode.unavailable,
      desiredMode: DenialUiRuntimeMode.officialOptimized,
      operation: DenialUiDevelopmentOperation.idle,
      developerComponentsAvailable: false,
      workspaceValid: false,
      autoReload: true,
      autoReloadSupported: false,
      canHotReload: false,
      canHotRestart: false,
      canBuildOptimized: false,
      canRevert: false,
      vmServiceAvailable: false,
      generation: 0,
      revision: 0,
      acknowledgedRequestId: 0,
      workspace: '',
      vmServiceUri: '',
      status: '',
      error: '',
      diagnostics: <DenialUiDiagnostic>[],
    );
  }

  final DenialUiRuntimeMode activeMode;
  final DenialUiRuntimeMode desiredMode;
  final DenialUiDevelopmentOperation operation;
  final bool developerComponentsAvailable;
  final bool workspaceValid;
  final bool autoReload;
  final bool autoReloadSupported;
  final bool canHotReload;
  final bool canHotRestart;
  final bool canBuildOptimized;
  final bool canRevert;
  final bool vmServiceAvailable;
  final int generation;
  final int revision;
  final int acknowledgedRequestId;
  final String workspace;
  final String vmServiceUri;
  final String status;
  final String error;
  final List<DenialUiDiagnostic> diagnostics;

  /// Null means the current operation has no meaningful finite progress.
  final double? progress;

  bool get liveDevelopmentEnabled =>
      activeMode == DenialUiRuntimeMode.liveDevelopment ||
      desiredMode == DenialUiRuntimeMode.liveDevelopment;

  bool get busy => operation != DenialUiDevelopmentOperation.idle;
}
