import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../state/shell_controller.dart';

final systemActionsServiceProvider = Provider<SystemActionsService>((ref) {
  return SystemActionsService(ref.watch(denialBridgeProvider));
});

/// One-shot system actions triggered from the quick-settings shade.
class SystemActionsService {
  const SystemActionsService([this._bridge]);

  final DenialBridge? _bridge;

  Future<void> takeScreenshot() {
    _bridge?.takeScreenshot();
    return Future<void>.value();
  }
}
