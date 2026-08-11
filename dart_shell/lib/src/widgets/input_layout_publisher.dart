import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      ref
          .read(shellControllerProvider.notifier)
          .publishInputLayout(
            viewSize,
            ref.read(shellInteractionRegistryProvider),
          );
    });
  }
}
