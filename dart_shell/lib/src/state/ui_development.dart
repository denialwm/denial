import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ui_development.dart';
import '../platform/denial_bridge.dart';
import 'shell_controller.dart';

final uiDevelopmentProvider =
    NotifierProvider<UiDevelopmentController, DenialUiDevelopmentState>(
      UiDevelopmentController.new,
    );

final uiWorkspaceSetupProvider = Provider<UiWorkspaceSetupService>(
  (_) => const SystemUiWorkspaceSetupService(),
);

abstract interface class UiWorkspaceSetupService {
  bool get available;

  Future<void> setup();
}

class SystemUiWorkspaceSetupService implements UiWorkspaceSetupService {
  const SystemUiWorkspaceSetupService();

  static const _controlTool = '/usr/bin/denialctl';
  static const _developmentTool = '/usr/bin/denial-ui';

  @override
  bool get available =>
      File(_controlTool).existsSync() && File(_developmentTool).existsSync();

  @override
  Future<void> setup() async {
    if (!available) {
      throw const UiWorkspaceSetupException(
        'Install denial-ui-development before creating an editable UI.',
      );
    }
    final result = await Process.run(_controlTool, const <String>[
      '--json',
      'ui',
      'setup',
    ]);
    if (result.exitCode == 0) {
      return;
    }
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    throw UiWorkspaceSetupException(
      stderr.isNotEmpty
          ? stderr
          : stdout.isNotEmpty
          ? stdout
          : 'denialctl exited with status ${result.exitCode}.',
    );
  }
}

class UiWorkspaceSetupException implements Exception {
  const UiWorkspaceSetupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UiDevelopmentController extends Notifier<DenialUiDevelopmentState> {
  StreamSubscription<DenialUiDevelopmentState>? _subscription;
  late DenialBridge _bridge;

  @override
  DenialUiDevelopmentState build() {
    _bridge = ref.watch(denialBridgeProvider);
    unawaited(_subscription?.cancel());
    _subscription = _bridge.uiDevelopmentStates.listen((next) {
      state = next;
    });
    ref.onDispose(() {
      unawaited(_subscription?.cancel());
      _subscription = null;
    });
    scheduleMicrotask(() {
      _bridge.queryUiDevelopmentState();
    });
    return DenialUiDevelopmentState.connecting();
  }

  void refresh() {
    _bridge.queryUiDevelopmentState();
  }

  void setLiveDevelopmentEnabled(bool enabled) {
    if (enabled) {
      _bridge.enableLiveUiDevelopment();
    } else {
      _bridge.disableLiveUiDevelopment();
    }
  }

  bool setWorkspace(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return _bridge.setUiDevelopmentWorkspace(normalized) != 0;
  }

  void setAutoReload(bool enabled) {
    _bridge.setUiDevelopmentAutoReload(enabled);
  }

  void hotReload() {
    _bridge.hotReloadUi();
  }

  void hotRestart() {
    _bridge.hotRestartUi();
  }

  void buildAndActivateOptimized() {
    _bridge.buildAndActivateOptimizedUi();
  }

  void revertLastWorking() {
    _bridge.revertLastWorkingUi();
  }

  void restoreOfficial() {
    _bridge.restoreOfficialUi();
  }
}
