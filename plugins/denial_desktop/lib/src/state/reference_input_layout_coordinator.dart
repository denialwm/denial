import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/input.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/platform.dart';

import 'phone_desk_input.dart';
import 'reference_shell_state.dart';
import 'reference_shell_metrics.dart';

/// Publishes the mobile shell's immutable native input-routing snapshot.
class ReferenceInputLayoutCoordinator {
  ReferenceInputLayoutCoordinator(this._bridge);

  final DenialBridge _bridge;
  int _inputLayoutEpoch = 0;

  /// Beside a desk the phone's layout goes to the composer, from the phone's
  /// origin in the scene.
  Offset _sceneOrigin = Offset.zero;
  PhoneDeskInputComposer? _composer;
  InputLayoutSnapshot? _lastInputLayoutSnapshot;

  void invalidate() {
    _lastInputLayoutSnapshot = null;
  }

  void publish({
    required ReferenceShellState state,
    required Size viewSize,
    required ShellInteractionSnapshot interactions,
    double topInset = 0.0,
    bool appsMoving = false,
    DenialWindow? overLockWindow,
    Offset sceneOrigin = Offset.zero,
    PhoneDeskInputComposer? composer,
  }) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return;
    }
    _sceneOrigin = sceneOrigin;
    _composer = composer;

    final quickSettingsActive = state.quickSettingsEngaged;
    final edgePanelActive =
        state.edgePanelVisible || state.edgePanelDragProgress > 0.0;
    final edgePanelProgress = state.edgePanelDragProgress;
    final edgePanelRect = ReferenceShellMetrics.edgePanelRect(
      viewSize,
      edgePanelProgress,
    );
    List<Rect> softwareKeyboardRegions({required bool scrollStripVisible}) =>
        ReferenceShellMetrics.softwareKeyboardRegions(
          viewSize,
          progress: edgePanelProgress,
          scrollStripVisible: scrollStripVisible,
        );
    // The calls app's window over the lock screen takes its touches; the
    // keyboard stays with the lock screen.
    if (state.lockLayerVisible && overLockWindow != null) {
      _publishInputLayout(
        viewSize: viewSize,
        shellRegions: const <Rect>[],
        windows: _inputRegionsForWindow(
          window: overLockWindow,
          viewSize: viewSize,
          contentOffset: 0.0,
          inputBottom: viewSize.height,
          topInset: 0.0,
        ),
        keyboardCapture: true,
      );
      return;
    }
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
        softwareKeyboardRegions: softwareKeyboardRegions(
          scrollStripVisible: state.edgePanelVisible,
        ),
        keyboardCapture: true,
        exclusiveShellMode: true,
      );
      return;
    }

    // Denial's own overlay is modal: it takes the touches inside its card's
    // canvas, the shell those around it, and the app none.
    final overlay = state.systemOverlay;
    if (overlay != null) {
      final rect = ReferenceShellMetrics.systemOverlayRect(
        viewSize,
        overlay.geometry!.size,
        edgePanelProgress,
      );
      _publishInputLayout(
        viewSize: viewSize,
        shellRegions: <Rect>[
          Rect.fromLTRB(0, 0, viewSize.width, rect.top),
          Rect.fromLTRB(0, rect.bottom, viewSize.width, viewSize.height),
          Rect.fromLTRB(0, rect.top, rect.left, rect.bottom),
          Rect.fromLTRB(rect.right, rect.top, viewSize.width, rect.bottom),
        ].where((region) => !region.isEmpty).toList(growable: false),
        windows: <InputWindowRegion>[
          InputWindowRegion(
            window: overlay,
            rect: rect,
            sourceRect: Offset.zero & rect.size,
            z: 0,
            geometryLocked: true,
          ),
        ],
        softwareKeyboardRegions: softwareKeyboardRegions(
          scrollStripVisible: state.edgePanelVisible,
        ),
      );
      return;
    }

    // An app laid out around the keyboard stays in place, so its input
    // regions do too, and there is no lifted scene for the strip to pan.
    final appLifted = !state.primaryWindowHandlesKeyboard;
    final contentOffset = edgePanelActive && appLifted
        ? state.edgePanelViewportScroll
              .clamp(0.0, edgePanelRect.height)
              .toDouble()
        : 0.0;
    final inputBottom = edgePanelActive
        ? edgePanelRect.top.clamp(0.0, viewSize.height).toDouble()
        : viewSize.height;
    final inputWindow = state.inputWindow;
    final canvas = Offset.zero & viewSize;
    final shellOwnsCanvas =
        inputWindow == null ||
        state.overviewVisible ||
        // While the apps move no app takes a touch, as in Launcher3's
        // recents animation: the shell holds them until they rest.
        appsMoving ||
        state.launchTransitionActive ||
        quickSettingsActive ||
        interactions.capturesFullScene;
    final scrollStripVisible =
        state.edgePanelVisible && (shellOwnsCanvas || appLifted);
    // A landscape view shows no status bar, so over an app its strip lets
    // touches through and claims only a pull down from the top edge.
    final statusEdge = !ReferenceShellMetrics.statusBarShown(viewSize);
    final shellRegions = <Rect>[
      if (shellOwnsCanvas)
        canvas
      else if (edgePanelActive) ...[
        if (!statusEdge) ReferenceShellMetrics.statusRect(viewSize),
        if (edgePanelRect.height > 0.0) edgePanelRect,
        if (scrollStripVisible)
          ReferenceShellMetrics.edgePanelScrollStripRect(viewSize),
      ] else ...[
        if (!statusEdge) ReferenceShellMetrics.statusRect(viewSize),
        ReferenceShellMetrics.gestureRect(viewSize),
        ReferenceShellMetrics.edgePanelGestureRect(viewSize),
      ],
      // Child regions are in scene coordinates.
      for (final region in interactions.childRegions)
        if (!region.shift(-_sceneOrigin).intersect(canvas).isEmpty)
          region.shift(-_sceneOrigin).intersect(canvas),
    ];

    // Back swipes and landscape pull-downs start over the app and are handed
    // to the shell's strips once they move inward. Elsewhere the shell owns
    // the whole canvas.
    final edgeSwipeRegions = shellRegions.contains(canvas)
        ? const <InputEdgeSwipeRegion>[]
        : <InputEdgeSwipeRegion>[
            ..._backGestureRegions(viewSize, inputBottom),
            if (statusEdge)
              InputEdgeSwipeRegion(
                rect: ReferenceShellMetrics.statusRect(viewSize),
                edge: InputEdge.top,
              ),
          ];

    final inputRegions = inputWindow == null
        ? const <InputWindowRegion>[]
        : _inputRegionsForWindow(
            window: inputWindow,
            viewSize: viewSize,
            contentOffset: contentOffset,
            inputBottom: inputBottom,
            topInset: topInset,
          );

    _publishInputLayout(
      viewSize: viewSize,
      shellRegions: shellRegions,
      windows: inputRegions,
      softwareKeyboardRegions: softwareKeyboardRegions(
        scrollStripVisible: scrollStripVisible,
      ),
      edgeSwipeRegions: edgeSwipeRegions,
      keyboardCapture: quickSettingsActive || interactions.capturesKeyboard,
      exclusiveShellMode: interactions.compositorExclusive,
    );
  }

  static List<InputEdgeSwipeRegion> _backGestureRegions(
    Size viewSize,
    double bottom,
  ) {
    final strips = ReferenceShellMetrics.backGestureRects(
      viewSize,
      bottom: bottom,
    );
    return <InputEdgeSwipeRegion>[
      if (!strips.left.isEmpty)
        InputEdgeSwipeRegion(rect: strips.left, edge: InputEdge.left),
      if (!strips.right.isEmpty)
        InputEdgeSwipeRegion(rect: strips.right, edge: InputEdge.right),
    ];
  }

  List<InputWindowRegion> _inputRegionsForWindow({
    required DenialWindow window,
    required Size viewSize,
    required double contentOffset,
    required double inputBottom,
    required double topInset,
  }) {
    final frame = window.presentationCoordinateRect;
    final content = window.contentCoordinateRect;
    if (frame.isEmpty || content.isEmpty) {
      return const <InputWindowRegion>[];
    }
    // Match the texture's top-centred BoxFit.cover, including the interval
    // between an output configure and the client's replacement buffer.
    final widthScale = viewSize.width / frame.width;
    final heightScale =
        (viewSize.height - topInset).clamp(0.0, viewSize.height) / frame.height;
    final scale = widthScale > heightScale ? widthScale : heightScale;
    final frameLeft = (viewSize.width - frame.width * scale) / 2.0;
    final frameTop = topInset - contentOffset;
    final fullContentRect = Rect.fromLTWH(
      frameLeft,
      frameTop,
      frame.width * scale,
      frame.height * scale,
    );
    final clientRect = Rect.fromLTWH(
      frameLeft + (content.left - frame.left) * scale,
      frameTop + (content.top - frame.top) * scale,
      content.width * scale,
      content.height * scale,
    );
    final clip = Rect.fromLTRB(0, topInset, viewSize.width, inputBottom);
    final rect = clientRect.intersect(clip);
    if (rect.isEmpty) {
      return const <InputWindowRegion>[];
    }
    final sourceRect = Rect.fromLTWH(
      content.left + (rect.left - clientRect.left) / scale,
      content.top + (rect.top - clientRect.top) / scale,
      rect.width / scale,
      rect.height / scale,
    );
    final regions = <InputWindowRegion>[];
    for (final popup in window.popupRootsFrontToBack) {
      final popupRect = window.mapSurfaceRect(popup, fullContentRect);
      final clipped = popupRect.intersect(rect);
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
    List<InputEdgeSwipeRegion> edgeSwipeRegions =
        const <InputEdgeSwipeRegion>[],
    bool keyboardCapture = false,
    bool exclusiveShellMode = false,
  }) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return;
    }

    final visibleSurfaceIds = <int>{};
    DenialWindow? previousWindow;
    for (final region in windows) {
      // Popup regions share their toplevel's complete surface tree. Traverse
      // it once for adjacent regions instead of once per popup.
      if (!identical(region.window, previousWindow)) {
        visibleSurfaceIds.addAll(region.window.visibleSurfaceIds);
        previousWindow = region.window;
      }
    }
    final snapshot = InputLayoutSnapshot(
      epoch: _inputLayoutEpoch + 1,
      shellRegions: shellRegions,
      windows: windows,
      softwareKeyboardRegions: softwareKeyboardRegions,
      edgeSwipeRegions: edgeSwipeRegions,
      visibleSurfaceIds: visibleSurfaceIds.toList(growable: false),
      keyboardCapture: keyboardCapture,
      exclusiveShellMode: exclusiveShellMode,
      mobilePresentation: true,
    );
    if (_lastInputLayoutSnapshot?.hasSameRoutingAs(snapshot) ?? false) {
      return;
    }

    final composer = _composer;
    if (!(composer?.publishPhone(snapshot, _sceneOrigin) ??
        _bridge.publishInputLayout(snapshot))) {
      return;
    }
    _inputLayoutEpoch = snapshot.epoch;
    _lastInputLayoutSnapshot = snapshot;
  }
}
