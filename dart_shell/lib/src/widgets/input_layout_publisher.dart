import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/input_layout.dart';
import '../input/shell_interaction_registry.dart';
import '../state/shell_controller.dart';

class InputLayoutPublisher extends ConsumerStatefulWidget {
  const InputLayoutPublisher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<InputLayoutPublisher> createState() =>
      _InputLayoutPublisherState();
}

class _InputLayoutPublisherState extends ConsumerState<InputLayoutPublisher> {
  bool _scheduled = false;
  final MobileWindowConfigureTracker _configureTracker =
      MobileWindowConfigureTracker();

  @override
  Widget build(BuildContext context) {
    ref.watch(
      shellControllerProvider.select(
        (state) => (
          overviewVisible: state.overviewVisible,
          inputObjectId: state.inputWindow?.objectId,
          launchRequestId: state.launchRequest?.requestId,
          launchingObjectId: state.launchingObjectId,
          quickSettingsVisible: state.quickSettingsVisible,
          quickSettingsProgress: state.quickSettingsDragProgress,
          edgePanelVisible: state.edgePanelVisible,
          edgePanelProgress: state.edgePanelDragProgress,
          edgePanelViewportScroll: state.edgePanelViewportScroll,
          lockLayerVisible: state.lockLayerVisible,
        ),
      ),
    );
    ref.watch(shellInteractionRegistryProvider);
    _schedulePublish(MediaQuery.sizeOf(context));
    return widget.child;
  }

  void _schedulePublish(Size viewSize) {
    if (_scheduled) {
      return;
    }

    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) {
        return;
      }
      _configureMobileWindows(viewSize);
      ref
          .read(shellControllerProvider.notifier)
          .publishInputLayout(
            viewSize,
            ref.read(shellInteractionRegistryProvider),
          );
    });
  }

  void _configureMobileWindows(Size viewSize) {
    final windows = ref.read(shellControllerProvider).windows;
    final activeObjectIds = <int>{};
    final bridge = ref.read(denialBridgeProvider);
    for (final window in windows) {
      if (!window.isUserApp || window.isLocalFlutter) {
        continue;
      }
      activeObjectIds.add(window.objectId);
      final geometry = _configureTracker.update(
        window.objectId,
        viewSize,
        reserveStatusBar: window.isUserApp,
      );
      if (geometry != null) {
        bridge.configureWindow(window, geometry, exact: true);
      }
    }
    _configureTracker.retainWindowIds(activeObjectIds);
  }
}

/// Publishes one exact client viewport per mobile window and output size.
///
/// The native compositor retains this contract across later client-authored
/// geometry requests. This tracker only prevents duplicate wire traffic while
/// Flutter rebuilds the same scene.
class MobileWindowConfigureTracker {
  final Map<int, ({int left, int top, int width, int height})> _configured =
      <int, ({int left, int top, int width, int height})>{};

  Rect? update(int objectId, Size viewSize, {required bool reserveStatusBar}) {
    final top = reserveStatusBar ? ShellMetrics.appStatusBarHeight : 0.0;
    final geometry = (
      left: 0,
      top: top.round(),
      width: viewSize.width.round().clamp(64, 16384),
      height: (viewSize.height - top).round().clamp(64, 16384),
    );
    if (_configured[objectId] == geometry) {
      return null;
    }
    _configured[objectId] = geometry;
    return Rect.fromLTWH(
      geometry.left.toDouble(),
      geometry.top.toDouble(),
      geometry.width.toDouble(),
      geometry.height.toDouble(),
    );
  }

  void retainWindowIds(Set<int> activeObjectIds) {
    _configured.removeWhere(
      (objectId, _) => !activeObjectIds.contains(objectId),
    );
  }
}
