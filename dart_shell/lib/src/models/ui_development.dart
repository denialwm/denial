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

  factory DenialUiDiagnostic.fromJson(Map<String, Object?> json) {
    return DenialUiDiagnostic(
      severity: _uiEnum(
        DenialUiDiagnosticSeverity.values,
        json['severity'],
        'diagnostic severity',
      ),
      message: _uiString(json, 'message'),
      path: _uiString(json, 'path'),
      line: _uiInt(json, 'line'),
      column: _uiInt(json, 'column'),
    );
  }
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

  factory DenialUiDevelopmentState.fromJson(Map<String, Object?> json) {
    final diagnostics = json['diagnostics'];
    if (diagnostics is! List<Object?>) {
      throw const FormatException('invalid UI diagnostics');
    }
    final progressBasisPoints = json['progress_basis_points'];
    if (progressBasisPoints != null && progressBasisPoints is! int) {
      throw const FormatException('invalid UI operation progress');
    }
    final vmServiceUri = _uiString(json, 'vm_service_uri');
    return DenialUiDevelopmentState(
      activeMode: _uiEnum(
        DenialUiRuntimeMode.values,
        json['active_mode'],
        'active UI mode',
      ),
      desiredMode: _uiEnum(
        DenialUiRuntimeMode.values,
        json['desired_mode'],
        'desired UI mode',
      ),
      operation: _uiEnum(
        DenialUiDevelopmentOperation.values,
        json['operation'],
        'UI operation',
      ),
      developerComponentsAvailable: _uiBool(
        json,
        'developer_components_available',
      ),
      workspaceValid: _uiBool(json, 'workspace_valid'),
      autoReload: _uiBool(json, 'auto_reload'),
      autoReloadSupported: _uiBool(json, 'auto_reload_supported'),
      canHotReload: _uiBool(json, 'can_hot_reload'),
      canHotRestart: _uiBool(json, 'can_hot_restart'),
      canBuildOptimized: _uiBool(json, 'can_build_optimized'),
      canRevert: _uiBool(json, 'can_revert'),
      vmServiceAvailable: vmServiceUri.isNotEmpty,
      generation: _uiInt(json, 'generation'),
      revision: _uiInt(json, 'revision'),
      acknowledgedRequestId: _uiInt(json, 'acknowledged_request_id'),
      workspace: _uiString(json, 'workspace'),
      vmServiceUri: vmServiceUri,
      status: _uiString(json, 'status'),
      error: _uiString(json, 'error'),
      diagnostics: List<DenialUiDiagnostic>.unmodifiable(
        diagnostics.map((entry) {
          if (entry is! Map<String, Object?>) {
            throw const FormatException('invalid UI diagnostic');
          }
          return DenialUiDiagnostic.fromJson(entry);
        }),
      ),
      progress: progressBasisPoints is! int
          ? null
          : (progressBasisPoints / 10000).clamp(0.0, 1.0).toDouble(),
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

T _uiEnum<T extends Enum>(List<T> values, Object? value, String description) {
  if (value is String) {
    final normalized = value.replaceAll('_', '').toLowerCase();
    for (final candidate in values) {
      if (candidate.name.toLowerCase() == normalized) {
        return candidate;
      }
    }
  }
  throw FormatException('invalid $description');
}

String _uiString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('invalid $key');
}

int _uiInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value >= 0) return value;
  throw FormatException('invalid $key');
}

bool _uiBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('invalid $key');
}
