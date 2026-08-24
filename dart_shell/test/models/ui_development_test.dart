import 'package:denial_dart_shell/src/models/ui_development.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes control-v1 UI development state', () {
    final state = DenialUiDevelopmentState.fromJson(<String, Object?>{
      'active_mode': 'live_development',
      'desired_mode': 'live_development',
      'operation': 'hot_reloading',
      'developer_components_available': true,
      'workspace_valid': true,
      'auto_reload': true,
      'auto_reload_supported': true,
      'can_hot_reload': true,
      'can_hot_restart': true,
      'can_build_optimized': false,
      'can_revert': true,
      'vm_service_uri': 'ws://127.0.0.1/example',
      'generation': 4,
      'revision': 12,
      'acknowledged_request_id': 31,
      'workspace': '/home/example/DenialUI',
      'status': 'Reloading',
      'error': '',
      'diagnostics': <Object?>[
        <String, Object?>{
          'severity': 'warning',
          'message': 'Example warning',
          'path': 'lib/main.dart',
          'line': 8,
          'column': 2,
        },
      ],
      'progress_basis_points': 6250,
    });

    expect(state.activeMode, DenialUiRuntimeMode.liveDevelopment);
    expect(state.operation, DenialUiDevelopmentOperation.hotReloading);
    expect(state.vmServiceAvailable, isTrue);
    expect(state.acknowledgedRequestId, 31);
    expect(state.progress, 0.625);
    expect(
      state.diagnostics.single.severity,
      DenialUiDiagnosticSeverity.warning,
    );
  });
}
