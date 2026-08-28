import 'package:flutter/widgets.dart';

import '../input/input_layout.dart';
import '../input/shell_interaction_registry.dart';
import '../models/denial_window.dart';
import '../platform/denial_bridge.dart';
import 'shell_state.dart';

/// Publishes the mobile shell's immutable native input-routing snapshot.
class ShellInputLayoutCoordinator {
  ShellInputLayoutCoordinator(this._bridge);

  final DenialBridge _bridge;
  int _inputLayoutEpoch = 0;
  InputLayoutSnapshot? _lastInputLayoutSnapshot;

  void invalidate() {
    _lastInputLayoutSnapshot = null;
  }

  void publish({
    required ShellState state,
    required Size viewSize,
    required ShellInteractionSnapshot interactions,
  }) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return;
    }

    final quickSettingsActive =
        state.quickSettingsVisible || state.quickSettingsDragProgress > 0.0;
    final edgePanelActive =
        state.edgePanelVisible || state.edgePanelDragProgress > 0.0;
    final edgePanelProgress = state.edgePanelDragProgress;
    final edgePanelRect = ShellMetrics.edgePanelRect(
      viewSize,
      edgePanelProgress,
    );
    final softwareKeyboardRegions = ShellMetrics.softwareKeyboardRegions(
      viewSize,
      progress: edgePanelProgress,
      scrollStripVisible: state.edgePanelVisible,
    );
    if (state.lockLayerVisible) {
      final lockBackgroundWindow = state.primaryWindow;
      _publishInputLayout(
        viewSize: viewSize,
        shellRegions: <Rect>[Offset.zero & viewSize],
        windows: <InputWindowRegion>[
          if (lockBackgroundWindow != null)
            InputWindowRegion(
              window: lockBackgroundWindow,
              rect: Offset.zero & viewSize,
              sourceRect: Offset.zero & viewSize,
              z: 0,
              hitTest: false,
            ),
        ],
        softwareKeyboardRegions: softwareKeyboardRegions,
        keyboardCapture: true,
        exclusiveShellMode: true,
      );
      return;
    }

    final contentOffset = edgePanelActive
        ? (edgePanelRect.height - state.edgePanelViewportScroll)
              .clamp(0.0, edgePanelRect.height)
              .toDouble()
        : 0.0;
    final inputBottom = edgePanelActive
        ? edgePanelRect.top.clamp(0.0, viewSize.height).toDouble()
        : viewSize.height;
    final inputWindow = state.inputWindow;
    final canvas = Offset.zero & viewSize;
    final shellRegions = <Rect>[
      if (inputWindow == null ||
          state.overviewVisible ||
          state.launchTransitionActive ||
          quickSettingsActive ||
          interactions.capturesFullScene)
        canvas
      else if (edgePanelActive) ...[
        ShellMetrics.statusRect(viewSize),
        if (edgePanelRect.height > 0.0) edgePanelRect,
        if (state.edgePanelVisible)
          ShellMetrics.edgePanelScrollStripRect(viewSize),
      ] else ...[
        ShellMetrics.statusRect(viewSize),
        ShellMetrics.gestureRect(viewSize),
        ShellMetrics.edgePanelGestureRect(viewSize),
      ],
      for (final region in interactions.childRegions)
        if (!region.intersect(canvas).isEmpty) region.intersect(canvas),
    ];

    final inputRegions = inputWindow == null
        ? const <InputWindowRegion>[]
        : _inputRegionsForWindow(
            window: inputWindow,
            viewSize: viewSize,
            contentOffset: contentOffset,
            inputBottom: inputBottom,
          );

    _publishInputLayout(
      viewSize: viewSize,
      shellRegions: shellRegions,
      windows: inputRegions,
      softwareKeyboardRegions: softwareKeyboardRegions,
      keyboardCapture: quickSettingsActive || interactions.capturesKeyboard,
      exclusiveShellMode: interactions.compositorExclusive,
    );
  }

  List<InputWindowRegion> _inputRegionsForWindow({
    required DenialWindow window,
    required Size viewSize,
    required double contentOffset,
    required double inputBottom,
  }) {
    final frameTop = -contentOffset;
    final contentTop =
        frameTop + (window.isUserApp ? ShellMetrics.appStatusBarHeight : 0.0);
    final contentBottom = frameTop + viewSize.height;
    final visibleTop = contentTop.clamp(0.0, viewSize.height).toDouble();
    final visibleBottom = contentBottom.clamp(0.0, inputBottom).toDouble();
    if (visibleBottom <= visibleTop) {
      return const <InputWindowRegion>[];
    }

    final rect = Rect.fromLTRB(0, visibleTop, viewSize.width, visibleBottom);
    final sourceRect = Rect.fromLTWH(
      0,
      rect.top - contentTop,
      viewSize.width,
      rect.height,
    );
    final fullContentRect = Rect.fromLTRB(
      0.0,
      contentTop,
      viewSize.width,
      contentBottom,
    );
    final regions = <InputWindowRegion>[];
    for (final popup in window.popupRoots.toList(growable: false).reversed) {
      final popupRect = window.mapSurfaceRect(popup, fullContentRect);
      final clipped = popupRect.intersect(
        Rect.fromLTRB(0.0, visibleTop, viewSize.width, visibleBottom),
      );
      if (clipped.isEmpty ||
          popupRect.width <= 0.0 ||
          popupRect.height <= 0.0) {
        continue;
      }
      final scaleX = popup.surfaceWidth / popupRect.width;
      final scaleY = popup.surfaceHeight / popupRect.height;
      regions.add(
        InputWindowRegion(
          window: window,
          surfaceId: popup.surfaceId,
          rect: clipped,
          sourceRect: Rect.fromLTWH(
            (clipped.left - popupRect.left) * scaleX,
            (clipped.top - popupRect.top) * scaleY,
            clipped.width * scaleX,
            clipped.height * scaleY,
          ),
          z: popup.compositionOrder + 1,
          geometryLocked: true,
        ),
      );
    }
    regions.add(
      InputWindowRegion(
        window: window,
        // Route through the toplevel root so native hit testing can select an
        // input-capable subsurface rather than the current primary texture.
        surfaceId: window.objectId,
        rect: rect,
        sourceRect: sourceRect,
        z: 0,
        geometryLocked: true,
      ),
    );
    return regions;
  }

  void _publishInputLayout({
    required Size viewSize,
    required List<Rect> shellRegions,
    required List<InputWindowRegion> windows,
    List<Rect> softwareKeyboardRegions = const <Rect>[],
    bool keyboardCapture = false,
    bool exclusiveShellMode = false,
  }) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return;
    }

    final snapshot = InputLayoutSnapshot(
      epoch: _inputLayoutEpoch + 1,
      shellRegions: shellRegions,
      windows: windows,
      softwareKeyboardRegions: softwareKeyboardRegions,
      visibleSurfaceIds: <int>{
        for (final region in windows) ...region.window.visibleSurfaceIds,
      }.toList(growable: false),
      keyboardCapture: keyboardCapture,
      exclusiveShellMode: exclusiveShellMode,
    );
    if (_lastInputLayoutSnapshot?.hasSameRoutingAs(snapshot) ?? false) {
      return;
    }

    if (!_bridge.publishInputLayout(snapshot)) {
      return;
    }
    _inputLayoutEpoch = snapshot.epoch;
    _lastInputLayoutSnapshot = snapshot;
  }
}
