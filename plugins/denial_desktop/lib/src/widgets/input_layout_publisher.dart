import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';

import '../state/over_lock_window.dart';
import '../state/phone_desk.dart';

class InputLayoutPublisher extends ConsumerStatefulWidget {
  const InputLayoutPublisher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<InputLayoutPublisher> createState() =>
      _InputLayoutPublisherState();
}

class _InputLayoutPublisherState extends ConsumerState<InputLayoutPublisher> {
  bool _scheduled = false;
  bool _forcePublish = true;
  Size _viewSize = Size.zero;
  late final ValueListenable<bool> _appsMoving = ref
      .read(referenceShellProvider.notifier)
      .deck
      .presenting;

  @override
  void initState() {
    super.initState();
    _appsMoving.addListener(_appsMovingChanged);
  }

  @override
  void dispose() {
    _appsMoving.removeListener(_appsMovingChanged);
    super.dispose();
  }

  void _appsMovingChanged() {
    if (mounted && !_viewSize.isEmpty) _schedulePublish(_viewSize);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      referenceShellProvider.select(
        (state) => (
          overviewVisible: state.overviewVisible,
          inputWindow: state.inputWindow,
          launchRequestId: state.launchRequest?.requestId,
          launchingObjectId: state.launchingObjectId,
          // The shade's input region does not follow its drag.
          quickSettingsActive: state.quickSettingsEngaged,
          edgePanelVisible: state.edgePanelVisible,
          edgePanelProgress: state.edgePanelDragProgress,
          edgePanelViewportScroll: state.edgePanelViewportScroll,
          lockLayerVisible: state.lockLayerVisible,
          systemOverlay: state.systemOverlay,
        ),
      ),
    );
    ref.watch(shellInteractionRegistryProvider);
    ref.watch(overLockWindowProvider);
    ref.watch(mobilePresentationTopInsetProvider);
    // Beside a desk the phone's regions move into the scene.
    ref.watch(phoneDeskProvider);
    _viewSize = MediaQuery.sizeOf(context);
    _schedulePublish(_viewSize);
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
          .read(referenceShellProvider.notifier)
          .publishInputLayout(
            viewSize,
            ref.read(shellInteractionRegistryProvider),
            topInset: ref.read(mobilePresentationTopInsetProvider),
            force: _forcePublish,
          );
      _forcePublish = false;
    });
  }
}
