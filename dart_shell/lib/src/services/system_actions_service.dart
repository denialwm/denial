import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../state/shell_controller.dart';

final systemActionsServiceProvider = Provider<SystemActionsService>((ref) {
  return SystemActionsService(ref.read(denialBridgeProvider));
});

/// One-shot system actions triggered from the quick-settings shade.
class SystemActionsService {
  const SystemActionsService([this._bridge]);

  final DenialBridge? _bridge;

  /// Toggles the on-screen keyboard. Signals an already-running instance first,
  /// otherwise launches the toggle helper detached.
  Future<void> toggleKeyboard() {
    _bridge?.toggleKeyboard();
    return Future<void>.value();
  }

  Future<void> takeScreenshot() {
    _bridge?.takeScreenshot();
    return Future<void>.value();
  }
}
