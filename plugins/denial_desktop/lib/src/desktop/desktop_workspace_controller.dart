part of 'desktop_workspace.dart';

class _NativeWindowRevisions {
  _NativeWindowRevisions({required this.geometry, required this.metadata});

  int geometry;
  int metadata;
  bool placementTransactionActive = false;
}

final desktopWorkspaceProvider =
    NotifierProvider<DesktopWorkspaceController, DesktopWorkspaceState>(
      DesktopWorkspaceController.new,
    );

class DesktopWorkspaceController extends Notifier<DesktopWorkspaceState> {
  @override
  DesktopWorkspaceState build() => DesktopWorkspaceState.initial();

  final Map<int, Offset> _moveRemainders = <int, Offset>{};
  // Rectangles initiated by a real Flutter interaction may be presented
  // optimistically until the compositor acknowledges them. Compositor action
  // notifications must never populate this map: their authoritative geometry
  // is already on the native snapshot/placement stream.
  final Map<int, Rect> _pendingFlutterProposedFrames = <int, Rect>{};
  // Geometry packets are frame-batched while ownership/state snapshots are
  // immediate. They therefore require independent revision clocks: one newer
  // metadata snapshot must neither discard queued geometry nor let that older
  // geometry revert output/workspace ownership when it is finally reduced.
  final Map<int, _NativeWindowRevisions> _nativeRevisions =
      <int, _NativeWindowRevisions>{};
  final Map<int, ({Rect frame, int z})> _overviewDragOrigins =
      <int, ({Rect frame, int z})>{};
  // Workspace overview drops are presented before the compositor echoes
  // them. A snapshot encoded before Rust received the move must not briefly
  // return the window to its previous card.
  final Map<int, int> _pendingWorkspaceMoves = <int, int>{};
  // Native layout previews for a workspace-overview drag, in scene
  // coordinates. Rust plans them on the target workspace's real layout and
  // the cards project them. An ended preview keeps its final rectangle until
  // a snapshot carries the same geometry.
  final Map<int, Rect> _overviewPreviewFrames = <int, Rect>{};
  final Set<int> _settlingOverviewFrames = <int>{};
  // The dragged window's planned rectangle on the workspace it was planned
  // for; presented as the landing slot.
  ({int objectId, int workspaceId, Rect frame})? _overviewDropSlot;
  int? _overviewDropWorkspace;
  List<DenialWindow>? _lastSyncedWindows;
  int _lastSyncedSnapshotSequence = -1;
  double _devicePixelRatio = 1.0;
  Map<int, Rect> _workAreas = const <int, Rect>{};
  DesktopWindowLayout _windowLayout = DesktopWindowLayout.stacking;
  Set<int> _localFlutterWindowIds = const <int>{};
  Map<int, int> _transientParentObjectIds = const <int, int>{};
  int _workspaceTransitionSerial = 0;

  void syncWorkspaceConfiguration({
    required bool enabled,
    required int count,
    required Iterable<int> monitorIds,
    Map<int, int> authoritativeActiveWorkspaces = const <int, int>{},
  }) {
    final safeCount = count.clamp(2, 9).toInt();
    final monitors = monitorIds.toSet();
    final active = <int, int>{
      for (final monitorId in monitors)
        monitorId: enabled
            ? (authoritativeActiveWorkspaces[monitorId] ??
                      state.activeWorkspaces[monitorId] ??
                      1)
                  .clamp(1, safeCount)
                  .toInt()
            : 1,
    };
    if (state.workspacesEnabled == enabled &&
        state.workspaceCount == safeCount &&
        mapEquals(state.activeWorkspaces, active)) {
      return;
    }
    final structureChanged =
        state.workspacesEnabled != enabled || state.workspaceCount != safeCount;
    state = state.copyWith(
      workspacesEnabled: enabled,
      workspaceCount: safeCount,
      activeWorkspaces: active,
      workspaceTransitions: const <int, DesktopWorkspaceTransition>{},
      // A workspace overview already shows every workspace, so a new active
      // workspace only moves its highlight. Changing their number does not.
      clearOverview:
          state.overviewActive &&
          (structureChanged || state.overview!.workspaces == null),
    );
  }

  void applyWorkspaceChanged(int monitorId, int workspaceId) {
    if (!state.workspacesEnabled ||
        workspaceId < 1 ||
        workspaceId > state.workspaceCount) {
      return;
    }
    final previous = state.activeWorkspaceFor(monitorId);
    // Repeated requests at a workspace boundary must not cancel live exits.
    if (previous == workspaceId) return;
    final active = Map<int, int>.of(state.activeWorkspaces)
      ..[monitorId] = workspaceId;
    final overview = state.overview;
    if (overview?.workspaces != null) {
      if (overview!.monitorId == monitorId) {
        // Both workspaces are already on screen as cards. Closing the
        // overview zooms into the new one instead of sliding it in.
        final transitions = Map<int, DesktopWorkspaceTransition>.of(
          state.workspaceTransitions,
        )..remove(monitorId);
        state = state.copyWith(
          activeWorkspaces: active,
          workspaceTransitions: transitions,
          panel: DesktopPanel.none,
        );
        return;
      }
    }
    final transitions = Map<int, DesktopWorkspaceTransition>.of(
      state.workspaceTransitions,
    );
    final preceding = transitions[monitorId];
    final retainedExits = <int, DesktopWorkspaceTransition>{
      ...?preceding?.retainedExits,
    };
    if (preceding != null) {
      // Keep only the individual exit, not a recursive history of switches.
      retainedExits[preceding.fromWorkspace] = DesktopWorkspaceTransition(
        monitorId: preceding.monitorId,
        fromWorkspace: preceding.fromWorkspace,
        toWorkspace: preceding.toWorkspace,
        serial: preceding.serial,
      );
    }
    // The latest pair owns its motion, including reversals into an older exit.
    retainedExits.remove(previous);
    retainedExits.remove(workspaceId);
    transitions[monitorId] = DesktopWorkspaceTransition(
      monitorId: monitorId,
      fromWorkspace: previous,
      toWorkspace: workspaceId,
      serial: ++_workspaceTransitionSerial,
      retainedExits: Map.unmodifiable(retainedExits),
    );
    state = state.copyWith(
      activeWorkspaces: active,
      workspaceTransitions: transitions,
      panel: DesktopPanel.none,
      clearOverview: state.overviewActive && overview!.workspaces == null,
    );
  }

  void finishWorkspaceTransition(int monitorId, int serial) {
    final transition = state.workspaceTransitions[monitorId];
    if (transition == null || transition.serial != serial) {
      return;
    }
    final transitions = Map<int, DesktopWorkspaceTransition>.of(
      state.workspaceTransitions,
    )..remove(monitorId);
    state = state.copyWith(workspaceTransitions: transitions);
  }

  /// Publishes per-monitor work areas (output rect minus the system bar).
  /// Maximized windows are reconciled immediately so a late display-layout
  /// load or a bar change never leaves a window under the bar.
  void syncWorkAreas(Map<int, Rect> workAreas) {
    if (mapEquals(_workAreas, workAreas)) {
      return;
    }
    _workAreas = Map<int, Rect>.unmodifiable(workAreas);
    if (state.viewSize.isEmpty) {
      return;
    }
    var changed = false;
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    for (final placement in state.placements.values) {
      if (!placement.maximized || placement.fullscreen) {
        continue;
      }
      if (_windowLayout == DesktopWindowLayout.scrolling &&
          !_localFlutterWindowIds.contains(placement.objectId)) {
        // Native scrolling maximize remains a tile in the strip. Rust will
        // publish its new padded-work-area placement after the work area changes;
        // forcing the visible work-area rectangle here would turn it back into
        // an overlay and prevent it from scrolling off-screen.
        continue;
      }
      final frame = _maximizedFrame(placement.monitorId, state.viewSize);
      if (frame != placement.frame) {
        _pendingFlutterProposedFrames[placement.objectId] = frame;
        next[placement.objectId] = placement.copyWith(frame: frame);
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(placements: next);
    }
  }

  Rect _maximizedFrame(int monitorId, Size viewSize) {
    final workArea = _workAreas[monitorId]?.intersect(Offset.zero & viewSize);
    if (workArea == null || workArea.isEmpty) {
      return DesktopMetrics.windowWorkArea(viewSize);
    }
    return workArea;
  }

  void syncWindows(
    List<DenialWindow> windows,
    Size viewSize,
    double devicePixelRatio, {
    int snapshotSequence = 0,
    DesktopWindowLayout windowLayout = DesktopWindowLayout.stacking,
  }) {
    if (viewSize.width <= 0.0 || viewSize.height <= 0.0) {
      return;
    }

    final serverFrameWhileMaximized =
        windowLayout != DesktopWindowLayout.stacking;
    final nextPixelRatio = devicePixelRatio.isFinite && devicePixelRatio > 0.0
        ? devicePixelRatio
        : 1.0;
    final pixelRatioChanged = nextPixelRatio != _devicePixelRatio;
    final windowLayoutChanged = _windowLayout != windowLayout;
    if (identical(windows, _lastSyncedWindows) &&
        snapshotSequence == _lastSyncedSnapshotSequence &&
        !pixelRatioChanged &&
        state.viewSize == viewSize &&
        _windowLayout == windowLayout) {
      return;
    }
    _lastSyncedWindows = windows;
    _lastSyncedSnapshotSequence = snapshotSequence;
    _windowLayout = windowLayout;
    _localFlutterWindowIds = {
      for (final window in windows)
        if (window.isLocalFlutter) window.objectId,
    };
    final viewMetricsChanged = pixelRatioChanged || state.viewSize != viewSize;
    if (pixelRatioChanged) {
      _devicePixelRatio = nextPixelRatio;
      _moveRemainders.clear();
    }

    final userWindows = windows.where((window) => window.isUserApp).toList();
    final activeIds = {for (final window in userWindows) window.objectId};
    _transientParentObjectIds = <int, int>{
      for (final window in userWindows)
        if (window.transientParentObjectId case final parentId?)
          if (parentId != window.objectId && activeIds.contains(parentId))
            window.objectId: parentId,
    };
    _moveRemainders.removeWhere((objectId, _) => !activeIds.contains(objectId));
    _pendingFlutterProposedFrames.removeWhere(
      (objectId, _) => !activeIds.contains(objectId),
    );
    _nativeRevisions.removeWhere(
      (objectId, _) => !activeIds.contains(objectId),
    );
    _pendingWorkspaceMoves.removeWhere(
      (objectId, _) => !activeIds.contains(objectId),
    );
    final next = <int, DesktopWindowPlacement>{
      for (final entry in state.placements.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    var nextZ = state.nextZ;
    var changed = viewMetricsChanged || next.length != state.placements.length;

    for (final window in userWindows) {
      final existing = next[window.objectId];
      if (existing == null) {
        final nativeGeometry = window.geometry;
        if (nativeGeometry == null) {
          continue;
        }
        next[window.objectId] = DesktopWindowPlacement(
          objectId: window.objectId,
          frame: window.fullscreen
              ? nativeGeometry.intersect(Offset.zero & viewSize)
              : _initialFrame(
                  nativeGeometry,
                  serverSideDecorated: window.serverSideDecorated,
                  expanded: window.maximized && !serverFrameWhileMaximized,
                ),
          z: nextZ++,
          monitorId: window.monitorId,
          workspaceId: window.workspaceId,
          minimized: window.minimized,
          maximized: window.maximized,
          fullscreen: window.fullscreen,
          serverSideDecorated: window.serverSideDecorated,
          serverFrameWhileMaximized: serverFrameWhileMaximized,
        );
        _nativeRevisions[window.objectId] = _NativeWindowRevisions(
          geometry: snapshotSequence,
          metadata: snapshotSequence,
        );
        changed = true;
        continue;
      }

      var current = existing;
      final nativeGeometry = window.geometry;
      final revisions = _nativeRevisions.putIfAbsent(
        window.objectId,
        () => _NativeWindowRevisions(geometry: 0, metadata: 0),
      );
      final geometryIsNew = snapshotSequence > revisions.geometry;
      final metadataIsNew = snapshotSequence > revisions.metadata;
      if (geometryIsNew || metadataIsNew || windowLayoutChanged) {
        var frame = existing.frame;
        var fullscreenRestoreFrame = existing.fullscreenRestoreFrame;
        var monitorId = existing.monitorId;
        var consumedNativeGeometry = false;
        // Local Flutter windows own their state in this controller. Managed
        // protocol clients have already been normalized by the compositor and
        // must all consume the same authoritative state fields here.
        final nativeFullscreen = window.isLocalFlutter
            ? existing.fullscreen
            : metadataIsNew
            ? window.fullscreen
            : existing.fullscreen;
        final nativeMaximized = window.isLocalFlutter
            ? existing.maximized
            : metadataIsNew
            ? window.maximized
            : existing.maximized;
        final nativeServerSideDecorated = metadataIsNew
            ? window.serverSideDecorated
            : existing.serverSideDecorated;
        final nativeMonitorId = metadataIsNew
            ? window.monitorId
            : existing.monitorId;
        if (metadataIsNew) {
          // Output and workspace are one ownership record. Never hold one
          // half back behind an unrelated geometry acknowledgement.
          monitorId = nativeMonitorId;
        }
        if (nativeFullscreen && !existing.fullscreen) {
          fullscreenRestoreFrame ??= existing.frame;
        }
        final decorationChanged =
            existing.serverSideDecorated != nativeServerSideDecorated;
        // Rust owns geometry throughout a native grab. A presentation or
        // metadata snapshot (for example, an animating title) can carry the
        // latest native rectangle before Flutter receives the matching
        // placement packet. Rebasing the workspace here would combine that
        // rectangle with the retained live-move delta and visibly apply the
        // motion twice. Placement packets remain the only geometry authority
        // until their end phase commits the final frame.
        if ((geometryIsNew ||
                (windowLayoutChanged && !window.isLocalFlutter)) &&
            !existing.dragging &&
            !revisions.placementTransactionActive &&
            !existing.layoutPreviewing &&
            nativeGeometry != null) {
          final nativeFrame = nativeFullscreen
              ? nativeGeometry.intersect(Offset.zero & viewSize)
              : _initialFrame(
                  nativeGeometry,
                  serverSideDecorated: nativeServerSideDecorated,
                  expanded: nativeMaximized && !serverFrameWhileMaximized,
                );
          final pendingFrame = _pendingFlutterProposedFrames[window.objectId];
          final nativeAcknowledgedPending =
              pendingFrame != null &&
              _framesApproximatelyEqual(nativeFrame, pendingFrame);
          if (nativeAcknowledgedPending) {
            _pendingFlutterProposedFrames.remove(window.objectId);
          }

          // Shell-authored maximize/restore geometry crosses the native bridge
          // asynchronously. A newer texture or metadata snapshot can still
          // describe the preceding native frame; keep the requested frame and
          // its monitor ownership until Rust echoes the complete rectangle.
          if (pendingFrame == null || nativeAcknowledgedPending) {
            if (!nativeFrame.isEmpty) {
              if (nativeFullscreen && nativeMonitorId != existing.monitorId) {
                final delta = nativeFrame.topLeft - existing.frame.topLeft;
                fullscreenRestoreFrame = fullscreenRestoreFrame?.shift(delta);
              }
              frame = nativeFrame;
              consumedNativeGeometry = true;
            }
          }
        } else if (!existing.dragging &&
            !revisions.placementTransactionActive &&
            !existing.layoutPreviewing &&
            decorationChanged &&
            !nativeFullscreen) {
          frame = _initialFrame(
            existing.contentRect,
            serverSideDecorated: nativeServerSideDecorated,
            expanded: nativeMaximized && !serverFrameWhileMaximized,
          );
        }
        final pendingWorkspace = _pendingWorkspaceMoves[window.objectId];
        final holdsPendingWorkspace =
            metadataIsNew &&
            pendingWorkspace != null &&
            (window.workspaceId != pendingWorkspace || window.minimized);
        if (metadataIsNew &&
            pendingWorkspace != null &&
            !holdsPendingWorkspace) {
          _pendingWorkspaceMoves.remove(window.objectId);
        }
        final adoptsNativeWorkspace = metadataIsNew && !holdsPendingWorkspace;
        current = existing.copyWith(
          frame: frame,
          monitorId: monitorId,
          serverSideDecorated: nativeServerSideDecorated,
          workspaceId: adoptsNativeWorkspace
              ? window.workspaceId
              : existing.workspaceId,
          minimized: adoptsNativeWorkspace
              ? window.minimized
              : existing.minimized,
          maximized: nativeMaximized,
          fullscreen: nativeFullscreen,
          fullscreenRestoreFrame: fullscreenRestoreFrame,
          clearFullscreenRestoreFrame: !nativeFullscreen && existing.fullscreen,
        );
        // A scene snapshot can overtake frame-batched scrolling placement
        // packets. Only advance the geometry sequence when this snapshot
        // actually consumed its rectangle; otherwise those packets must stay
        // eligible to move every tile with the layout viewport.
        if (consumedNativeGeometry) {
          revisions.geometry = snapshotSequence;
          if (_settlingOverviewFrames.remove(window.objectId)) {
            _overviewPreviewFrames.remove(window.objectId);
            changed = true;
          }
        }
        if (metadataIsNew) {
          revisions.metadata = snapshotSequence;
        }
        if (current.frame != existing.frame ||
            current.monitorId != existing.monitorId ||
            current.serverSideDecorated != existing.serverSideDecorated ||
            current.workspaceId != existing.workspaceId ||
            current.minimized != existing.minimized ||
            current.maximized != existing.maximized ||
            current.fullscreen != existing.fullscreen ||
            current.fullscreenRestoreFrame != existing.fullscreenRestoreFrame) {
          next[window.objectId] = current;
          changed = true;
        }
      }

      if (current.serverFrameWhileMaximized != serverFrameWhileMaximized) {
        current = current.copyWith(
          serverFrameWhileMaximized: serverFrameWhileMaximized,
        );
        next[window.objectId] = current;
        changed = true;
      }

      if (!viewMetricsChanged) {
        continue;
      }

      final frame = current.fullscreen
          ? _clampFrame(current.frame, viewSize)
          : current.maximized &&
                (_windowLayout != DesktopWindowLayout.scrolling ||
                    _localFlutterWindowIds.contains(current.objectId))
          ? _maximizedFrame(current.monitorId, viewSize)
          : current.maximized
          ? current.frame
          : _clampFrame(current.frame, viewSize);
      if (frame != current.frame) {
        // A metrics change reaches Flutter before the matching native scene
        // snapshot. This clamp is only a safe interim presentation of the old
        // rectangle; it was not sent to the compositor as a geometry request.
        // Recording it as pending would reject the authoritative re-tiled
        // rectangle when that snapshot arrives, leaving the client texture
        // permanently stretched into this stale frame.
        next[window.objectId] = current.copyWith(frame: frame);
        changed = true;
      }
    }

    var nextOverview = state.overview;
    if (nextOverview != null && changed) {
      final workspaces = nextOverview.workspaces;
      if (state.viewSize != Size.zero && state.viewSize != viewSize) {
        nextOverview = null;
      } else if (workspaces != null) {
        nextOverview = _rearrangedWorkspaceOverview(next, nextOverview);
      } else {
        final overviewItems = <DesktopOverviewItem>[
          for (final placement in next.values)
            if (nextOverview.contains(placement.objectId))
              DesktopOverviewItem(
                objectId: placement.objectId,
                frame: placement.frame,
                z: placement.z,
              ),
        ];
        final frames = Map<int, Rect>.of(
          DesktopOverviewLayout.arrange(
            items: overviewItems,
            bounds: nextOverview.bounds,
          ),
        );
        for (final placement in next.values) {
          if (placement.dragging &&
              frames.containsKey(placement.objectId) &&
              nextOverview.frames.containsKey(placement.objectId)) {
            frames[placement.objectId] =
                nextOverview.frames[placement.objectId]!;
          }
        }
        if (frames.isEmpty) {
          nextOverview = null;
        } else {
          nextOverview = DesktopOverviewState(
            monitorId: nextOverview.monitorId,
            bounds: nextOverview.bounds,
            backgroundBounds: nextOverview.backgroundBounds,
            selectedObjectId: frames.containsKey(nextOverview.selectedObjectId)
                ? nextOverview.selectedObjectId
                : _nearestOverviewObjectId(
                    frames,
                    nextOverview.frames[nextOverview.selectedObjectId]?.center,
                  ),
            frames: frames,
          );
        }
      }
    }

    if (!changed) {
      return;
    }
    if (state.overview != null && nextOverview == null) {
      for (final entry in next.entries.toList(growable: false)) {
        if (entry.value.dragging) {
          next[entry.key] = entry.value.copyWith(
            z: _overviewDragOrigins[entry.key]?.z,
            dragging: false,
          );
        }
      }
      _overviewDragOrigins.clear();
    }
    state = state.copyWith(
      placements: next,
      nextZ: nextZ,
      viewSize: viewSize,
      overview: nextOverview,
      clearOverview: nextOverview == null,
    );
  }

  void activate(int objectId) {
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    final family = orderTransientFamily(
      activatedObjectId: objectId,
      placements: state.placements,
      parentIds: _transientParentObjectIds,
      zOrder: (placement) => placement.z,
    );
    final topVisibleZ = state.placements.values
        .where((candidate) => !candidate.minimized)
        .fold<int>(0, (top, candidate) => math.max(top, candidate.z));
    if (!state.overviewActive &&
        family.length == 1 &&
        !placement.minimized &&
        placement.z == topVisibleZ) {
      return;
    }

    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    var nextZ = state.nextZ;
    for (final memberId in family) {
      final member = state.placements[memberId]!;
      final activated = memberId == objectId;
      next[member.objectId] = member.copyWith(
        z: nextZ++,
        minimized: activated ? false : member.minimized,
        workspaceId: activated && member.minimized
            ? state.activeWorkspaceFor(member.monitorId)
            : member.workspaceId,
      );
    }
    state = state.copyWith(
      placements: next,
      nextZ: nextZ,
      clearOverview: state.overviewActive,
    );
  }

  void toggleOverview({
    required int monitorId,
    required Rect bounds,
    required Rect backgroundBounds,
    Set<int>? objectIds,
    int? selectedObjectId,
  }) {
    if (state.overviewActive) {
      closeOverview();
      return;
    }
    if (bounds.width <= 0.0 || bounds.height <= 0.0) {
      return;
    }

    _moveRemainders.clear();
    _overviewDragOrigins.clear();
    final settledPlacements = <int, DesktopWindowPlacement>{
      for (final placement in state.placements.values)
        placement.objectId: placement.dragging
            ? placement.copyWith(dragging: false)
            : placement,
    };
    final items = <DesktopOverviewItem>[
      for (final placement in settledPlacements.values)
        if ((objectIds?.contains(placement.objectId) ?? false) ||
            (objectIds == null && bounds.contains(placement.frame.center)))
          DesktopOverviewItem(
            objectId: placement.objectId,
            frame: placement.frame,
            z: placement.z,
          ),
    ];
    final frames = DesktopOverviewLayout.arrange(items: items, bounds: bounds);
    if (frames.isEmpty) {
      return;
    }
    final fallbackSelection = items
        .where((item) => frames.containsKey(item.objectId))
        .reduce((left, right) => left.z >= right.z ? left : right)
        .objectId;

    state = state.copyWith(
      placements: settledPlacements,
      panel: DesktopPanel.none,
      overview: DesktopOverviewState(
        monitorId: monitorId,
        bounds: bounds,
        backgroundBounds: backgroundBounds,
        selectedObjectId: frames.containsKey(selectedObjectId)
            ? selectedObjectId!
            : fallbackSelection,
        frames: frames,
      ),
    );
  }

  /// Opens the managed-layout overview: every workspace of [monitorId] as a
  /// true-to-layout card, with minimized windows on a shelf below.
  ///
  /// Unlike the stacking spread, it opens even without windows so empty
  /// workspaces remain one click away.
  void openWorkspaceOverview({
    required int monitorId,
    required Rect bounds,
    required Rect backgroundBounds,
    required Rect viewport,
    required WorkspaceSwitchingOrientation orientation,
    int? selectedObjectId,
  }) {
    if (state.overviewActive || bounds.isEmpty || viewport.isEmpty) {
      return;
    }
    _moveRemainders.clear();
    _overviewDragOrigins.clear();
    _clearOverviewDropPreview();
    final settledPlacements = <int, DesktopWindowPlacement>{
      for (final placement in state.placements.values)
        placement.objectId: placement.dragging
            ? placement.copyWith(dragging: false)
            : placement,
    };
    final overview = _workspaceOverviewFor(
      placements: settledPlacements,
      monitorId: monitorId,
      bounds: bounds,
      backgroundBounds: backgroundBounds,
      viewport: viewport,
      orientation: orientation,
      selectedObjectId: selectedObjectId,
    );
    if (overview == null) {
      return;
    }
    state = state.copyWith(
      placements: settledPlacements,
      panel: DesktopPanel.none,
      overview: overview,
    );
  }

  DesktopOverviewState? _workspaceOverviewFor({
    required Map<int, DesktopWindowPlacement> placements,
    required int monitorId,
    required Rect bounds,
    required Rect backgroundBounds,
    required Rect viewport,
    required WorkspaceSwitchingOrientation orientation,
    required int? selectedObjectId,
    Map<int, Rect> retainedFrames = const <int, Rect>{},
  }) {
    final count = state.workspacesEnabled ? state.workspaceCount : 1;
    final activeWorkspace = state.activeWorkspaceFor(monitorId);
    final slot = _overviewDropSlot;
    final items = <DesktopWorkspaceOverviewItem>[
      for (final placement in placements.values)
        if ((placement.monitorId == monitorId ||
                (placement.monitorId < 0 &&
                    backgroundBounds.contains(placement.frame.center))) &&
            DesktopOverviewLayout.isUsefulPreview(placement.frame))
          DesktopWorkspaceOverviewItem(
            objectId: placement.objectId,
            frame:
                _overviewPreviewFrames[placement.objectId] ?? placement.frame,
            z: placement.z,
            workspaceId: !state.workspacesEnabled
                ? 1
                : placement.workspaceId >= 1 && placement.workspaceId <= count
                ? placement.workspaceId
                : activeWorkspace,
            minimized: placement.minimized,
          ),
    ];
    final arrangement = DesktopWorkspaceOverviewLayout.arrange(
      bounds: bounds,
      viewport: viewport,
      workspaceCount: count,
      orientation: orientation,
      items: items,
      landing:
          slot == null ||
              slot.workspaceId < 1 ||
              slot.workspaceId > count ||
              !placements.containsKey(slot.objectId)
          ? null
          : (workspaceId: slot.workspaceId, frame: slot.frame),
    );
    if (arrangement.cards.isEmpty) {
      return null;
    }
    final frames = Map<int, Rect>.of(arrangement.frames);
    for (final entry in retainedFrames.entries) {
      if (frames.containsKey(entry.key)) {
        frames[entry.key] = entry.value;
      }
    }
    return DesktopOverviewState(
      monitorId: monitorId,
      bounds: bounds,
      backgroundBounds: backgroundBounds,
      selectedObjectId: frames.containsKey(selectedObjectId)
          ? selectedObjectId
          : _preferredOverviewSelection(items, frames, activeWorkspace),
      frames: frames,
      workspaces: DesktopWorkspaceOverview(
        viewport: viewport,
        orientation: orientation,
        cards: arrangement.cards,
        shelf: arrangement.shelf,
        dropSlot: arrangement.landing,
      ),
    );
  }

  /// Re-arranges an open workspace overview after its inputs changed while
  /// keeping dragged previews under the pointer.
  DesktopOverviewState? _rearrangedWorkspaceOverview(
    Map<int, DesktopWindowPlacement> placements,
    DesktopOverviewState previous,
  ) {
    final workspaces = previous.workspaces!;
    return _workspaceOverviewFor(
      placements: placements,
      monitorId: previous.monitorId,
      bounds: previous.bounds,
      backgroundBounds: previous.backgroundBounds,
      viewport: workspaces.viewport,
      orientation: workspaces.orientation,
      selectedObjectId: previous.selectedObjectId,
      retainedFrames: <int, Rect>{
        for (final placement in placements.values)
          if (placement.dragging)
            placement.objectId: ?previous.frames[placement.objectId],
      },
    );
  }

  /// Resolves the workspace card under [objectId]'s dragged preview and the
  /// preview centre in that workspace's own scene coordinates. The native
  /// layout preview answering this plan is presented on that card.
  ({int workspaceId, Offset point})? planOverviewDrop(int objectId) {
    final workspaces = state.overview?.workspaces;
    final preview = state.overview?.frames[objectId];
    final card = preview == null ? null : workspaces?.cardAt(preview.center);
    final dragging = state.placements[objectId]?.dragging ?? false;
    _overviewDropWorkspace = dragging ? card?.workspaceId : null;
    if (!dragging || card == null) {
      return null;
    }
    return (
      workspaceId: card.workspaceId,
      point: card
          .unproject(
            Rect.fromCenter(center: preview!.center, width: 0, height: 0),
          )
          .center,
    );
  }

  /// Presents a native layout preview inside the workspace overview. The
  /// dragged window's own planned rectangle becomes its landing slot; every
  /// other affected tile moves within its card.
  bool _applyOverviewLayoutPreview(
    int objectId,
    DenialWindowPlacementEvent event,
  ) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    if (overview == null || overview.workspaces == null || placement == null) {
      return false;
    }
    final frame = _initialFrame(
      event.contentRect,
      serverSideDecorated: placement.serverSideDecorated,
      expanded: placement.maximized && !placement.serverFrameWhileMaximized,
    );
    final ending = event.phase == DenialWindowPlacementPhase.end;
    if (placement.dragging) {
      final workspaceId = _overviewDropWorkspace;
      _overviewDropSlot = ending || workspaceId == null
          ? null
          : (objectId: objectId, workspaceId: workspaceId, frame: frame);
    } else if (ending && _framesApproximatelyEqual(frame, placement.frame)) {
      _overviewPreviewFrames.remove(objectId);
      _settlingOverviewFrames.remove(objectId);
    } else {
      _overviewPreviewFrames[objectId] = frame;
      if (ending) {
        _settlingOverviewFrames.add(objectId);
      } else {
        _settlingOverviewFrames.remove(objectId);
      }
    }
    state = state.copyWith(
      overview:
          _rearrangedWorkspaceOverview(state.placements, overview) ?? overview,
    );
    return true;
  }

  void _clearOverviewDropPreview() {
    _overviewPreviewFrames.clear();
    _settlingOverviewFrames.clear();
    _overviewDropSlot = null;
    _overviewDropWorkspace = null;
  }

  /// Prefers the topmost window on the active workspace, then any workspace,
  /// and only then the minimized shelf.
  int? _preferredOverviewSelection(
    List<DesktopWorkspaceOverviewItem> items,
    Map<int, Rect> frames,
    int activeWorkspace,
  ) {
    int rank(DesktopWorkspaceOverviewItem item) => item.minimized
        ? 0
        : item.workspaceId == activeWorkspace
        ? 2
        : 1;
    DesktopWorkspaceOverviewItem? best;
    for (final item in items) {
      if (!frames.containsKey(item.objectId)) {
        continue;
      }
      if (best == null ||
          rank(item) > rank(best) ||
          (rank(item) == rank(best) && item.z > best.z)) {
        best = item;
      }
    }
    return best?.objectId;
  }

  /// Presents an overview drop on [workspaceId]'s card before the compositor
  /// echoes it. A planned landing slot is exactly where Rust will place the
  /// window, so it lands there directly; without one, a move to another
  /// workspace (or a restore from the shelf) joins that card and a drop on
  /// its own workspace returns to its tile. The caller sends the native drop.
  bool dropOverviewWindowOnWorkspace(int objectId, int workspaceId) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    if (overview == null ||
        overview.workspaces == null ||
        placement == null ||
        !placement.dragging) {
      return false;
    }
    final slot = _overviewDropSlot;
    final landing =
        slot != null &&
            slot.objectId == objectId &&
            slot.workspaceId == workspaceId
        ? slot.frame
        : null;
    _overviewDropSlot = null;
    _overviewDropWorkspace = null;
    final moves =
        landing != null ||
        placement.minimized ||
        (state.workspacesEnabled && workspaceId != placement.workspaceId);
    if (!moves) {
      _restoreOverviewDrag(objectId, placement, overview);
      return true;
    }
    final origin = _overviewDragOrigins.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(
      z: origin?.z,
      workspaceId: workspaceId,
      minimized: false,
      dragging: false,
    );
    _pendingWorkspaceMoves[objectId] = workspaceId;
    if (landing != null) {
      _overviewPreviewFrames[objectId] = landing;
      _settlingOverviewFrames.remove(objectId);
    }
    final rearranged = _workspaceOverviewFor(
      placements: next,
      monitorId: overview.monitorId,
      bounds: overview.bounds,
      backgroundBounds: overview.backgroundBounds,
      viewport: overview.workspaces!.viewport,
      orientation: overview.workspaces!.orientation,
      selectedObjectId: objectId,
    );
    state = state.copyWith(placements: next, overview: rearranged ?? overview);
    return true;
  }

  bool moveOverviewSelection(DesktopOverviewDirection direction) {
    final overview = state.overview;
    if (overview == null || overview.frames.isEmpty) {
      return false;
    }
    final fromObjectId = overview.selectedObjectId;
    if (fromObjectId == null) {
      final first = overview.frames.entries.reduce((left, right) {
        final order = left.value.top.compareTo(right.value.top);
        if (order != 0) {
          return order < 0 ? left : right;
        }
        return left.value.left <= right.value.left ? left : right;
      });
      state = state.copyWith(
        overview: overview.copyWith(selectedObjectId: first.key),
      );
      return true;
    }
    final selectedObjectId = desktopOverviewNeighbor(
      frames: overview.frames,
      fromObjectId: fromObjectId,
      direction: direction,
    );
    if (selectedObjectId == null) {
      return false;
    }
    state = state.copyWith(
      overview: overview.copyWith(selectedObjectId: selectedObjectId),
    );
    return true;
  }

  void closeOverview() {
    if (!state.overviewActive) {
      return;
    }
    final next = <int, DesktopWindowPlacement>{
      for (final placement in state.placements.values)
        placement.objectId: placement.dragging
            ? placement.copyWith(
                z: _overviewDragOrigins[placement.objectId]?.z,
                dragging: false,
              )
            : placement,
    };
    _overviewDragOrigins.clear();
    _clearOverviewDropPreview();
    state = state.copyWith(placements: next, clearOverview: true);
  }

  void beginOverviewDrag(int objectId) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    final previewFrame = overview?.frames[objectId];
    if (overview == null ||
        placement == null ||
        previewFrame == null ||
        placement.dragging) {
      return;
    }
    _overviewDragOrigins[objectId] = (frame: previewFrame, z: placement.z);
    _overviewDropSlot = null;
    _overviewDropWorkspace = null;
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(z: state.nextZ, dragging: true);
    state = state.copyWith(placements: next, nextZ: state.nextZ + 1);
  }

  void moveOverviewBy(int objectId, Offset delta) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    final previewFrame = overview?.frames[objectId];
    if (overview == null ||
        placement == null ||
        !placement.dragging ||
        previewFrame == null ||
        delta == Offset.zero) {
      return;
    }
    final frames = Map<int, Rect>.of(overview.frames);
    frames[objectId] = _clampFrame(previewFrame.shift(delta), state.viewSize);
    state = state.copyWith(overview: overview.copyWith(frames: frames));
  }

  bool endOverviewDrag(
    int objectId, {
    required Map<int, Rect> outputBounds,
    required Map<int, Rect> workAreas,
  }) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    final previewFrame = overview?.frames[objectId];
    if (overview == null ||
        placement == null ||
        !placement.dragging ||
        previewFrame == null) {
      _overviewDragOrigins.remove(objectId);
      return false;
    }

    int? targetMonitorId;
    for (final entry in outputBounds.entries) {
      if (entry.value.contains(previewFrame.center)) {
        targetMonitorId = entry.key;
        break;
      }
    }
    final targetOutput = outputBounds[targetMonitorId];
    if (targetMonitorId == null ||
        targetOutput == null ||
        targetOutput.isEmpty) {
      _restoreOverviewDrag(objectId, placement, overview);
      return false;
    }

    final targetWorkArea = workAreas[targetMonitorId] ?? targetOutput;
    final sourceOutput =
        outputBounds[placement.monitorId] ?? overview.backgroundBounds;
    final outputDelta = targetOutput.topLeft - sourceOutput.topLeft;
    Rect? shiftedRestoreFrame(Rect? frame) {
      if (frame == null) {
        return null;
      }
      return _clampFrame(
        frame.shift(outputDelta),
        state.viewSize,
        bounds: targetWorkArea,
      );
    }

    final destinationFrame = placement.fullscreen
        ? targetOutput
        : placement.maximized
        ? targetWorkArea
        : _clampFrame(
            Rect.fromCenter(
              center: previewFrame.center,
              width: placement.frame.width,
              height: placement.frame.height,
            ),
            state.viewSize,
            bounds: targetWorkArea,
          );
    final fullscreenRestoreFrame = placement.fullscreen && placement.maximized
        ? targetWorkArea
        : shiftedRestoreFrame(placement.fullscreenRestoreFrame);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    final transferred = placement.copyWith(
      frame: destinationFrame,
      monitorId: targetMonitorId,
      minimized: false,
      dragging: false,
      restoreFrame: shiftedRestoreFrame(placement.restoreFrame),
      fullscreenRestoreFrame: fullscreenRestoreFrame,
    );
    next[objectId] = transferred;
    _pendingFlutterProposedFrames[objectId] = destinationFrame;
    _overviewDragOrigins.clear();
    state = state.copyWith(placements: next, clearOverview: true);
    return true;
  }

  void cancelOverviewDrag(int objectId) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    if (overview == null || placement == null || !placement.dragging) {
      _overviewDragOrigins.remove(objectId);
      return;
    }
    _restoreOverviewDrag(objectId, placement, overview);
  }

  void _restoreOverviewDrag(
    int objectId,
    DesktopWindowPlacement placement,
    DesktopOverviewState overview,
  ) {
    final frames = Map<int, Rect>.of(overview.frames);
    final origin = _overviewDragOrigins.remove(objectId);
    if (origin != null) {
      frames[objectId] = origin.frame;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(z: origin?.z, dragging: false);
    if (overview.workspaces != null) {
      // A landing slot already moved this window to another card in the
      // arrangement. Re-arranging without it returns the window to its tile.
      if (_overviewDropSlot?.objectId == objectId) {
        _overviewDropSlot = null;
      }
      state = state.copyWith(
        placements: next,
        overview: _rearrangedWorkspaceOverview(next, overview) ?? overview,
      );
      return;
    }
    state = state.copyWith(
      placements: next,
      overview: overview.copyWith(frames: frames),
    );
  }

  int _nearestOverviewObjectId(Map<int, Rect> frames, Offset? origin) {
    if (origin == null) {
      return frames.keys.first;
    }
    return frames.entries.reduce((left, right) {
      final leftDistance = (left.value.center - origin).distanceSquared;
      final rightDistance = (right.value.center - origin).distanceSquared;
      if (leftDistance != rightDistance) {
        return leftDistance < rightDistance ? left : right;
      }
      return left.key < right.key ? left : right;
    }).key;
  }

  void moveBy(int objectId, Offset delta) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null ||
        placement.maximized ||
        placement.fullscreen ||
        placement.minimized) {
      return;
    }

    final pendingDelta = (_moveRemainders[objectId] ?? Offset.zero) + delta;
    final snappedDelta = _snapOffset(pendingDelta);
    if (snappedDelta == Offset.zero) {
      _moveRemainders[objectId] = pendingDelta;
      return;
    }

    final frame = _clampFrame(
      placement.frame.shift(snappedDelta),
      state.viewSize,
    );
    final appliedDelta = frame.topLeft - placement.frame.topLeft;
    var remainder = pendingDelta - appliedDelta;
    if ((appliedDelta.dx - snappedDelta.dx).abs() > 0.000001) {
      remainder = Offset(0.0, remainder.dy);
    }
    if ((appliedDelta.dy - snappedDelta.dy).abs() > 0.000001) {
      remainder = Offset(remainder.dx, 0.0);
    }
    _moveRemainders[objectId] = remainder;

    if (frame == placement.frame) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(frame: frame);
    _pendingFlutterProposedFrames[objectId] = frame;
    state = state.copyWith(placements: next);
  }

  void beginMove(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null ||
        placement.maximized ||
        placement.fullscreen ||
        placement.minimized) {
      return;
    }
    _moveRemainders[objectId] = Offset.zero;
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(dragging: true);
    state = state.copyWith(placements: next);
  }

  void endMove(int objectId) {
    if (state.overviewActive) {
      return;
    }
    _moveRemainders.remove(objectId);
    final placement = state.placements[objectId];
    if (placement == null || !placement.dragging) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(dragging: false);
    state = state.copyWith(placements: next);
  }

  bool applyNativePlacement(int objectId, DenialWindowPlacementEvent event) {
    if (state.overviewActive) {
      return event.change == DenialWindowPlacementChange.layoutPreview &&
          _applyOverviewLayoutPreview(objectId, event);
    }
    final layoutPreview =
        event.change == DenialWindowPlacementChange.layoutPreview;
    var placement = state.placements[objectId];
    if (placement == null) {
      return false;
    }
    final revisions = _nativeRevisions.putIfAbsent(
      objectId,
      () => _NativeWindowRevisions(geometry: 0, metadata: 0),
    );
    final geometryIsNew = event.sequence > revisions.geometry;
    final metadataIsNew = event.sequence > revisions.metadata;
    if (!geometryIsNew && !metadataIsNew) {
      return false;
    }
    if (event.phase == DenialWindowPlacementPhase.begin &&
        !layoutPreview &&
        geometryIsNew) {
      activate(objectId);
      // Activation restacks the whole transient family. Writing back the
      // placement read before it would put a dialog below its parent again.
      placement = state.placements[objectId]!;
    }
    if (geometryIsNew) {
      _pendingFlutterProposedFrames.remove(objectId);
      if (!layoutPreview) {
        revisions.placementTransactionActive =
            event.phase != DenialWindowPlacementPhase.end;
      }
    }

    final monitorChanged =
        metadataIsNew && event.monitorId != placement.monitorId;
    final dragging = geometryIsNew
        ? layoutPreview
              ? placement.dragging
              : switch (event.phase) {
                  DenialWindowPlacementPhase.begin =>
                    event.change == DenialWindowPlacementChange.move,
                  DenialWindowPlacementPhase.update => placement.dragging,
                  DenialWindowPlacementPhase.end => false,
                }
        : placement.dragging;
    // Sibling tiles receive resize updates without a begin packet. Every
    // affected tile must bypass easing until its native transaction ends.
    final resizing = geometryIsNew && !layoutPreview
        ? event.change == DenialWindowPlacementChange.resize &&
              event.phase != DenialWindowPlacementPhase.end
        : placement.resizing;

    if (placement.fullscreen) {
      final fullscreenFrame = event.contentRect.intersect(
        Offset.zero & state.viewSize,
      );
      if (geometryIsNew && fullscreenFrame.isEmpty) {
        return false;
      }
      final delta = fullscreenFrame.topLeft - placement.frame.topLeft;
      final updated = placement.copyWith(
        frame: geometryIsNew ? fullscreenFrame : placement.frame,
        monitorId: metadataIsNew ? event.monitorId : placement.monitorId,
        workspaceId: metadataIsNew ? event.workspaceId : placement.workspaceId,
        dragging: dragging,
        resizing: resizing,
        layoutPreviewing: geometryIsNew
            ? layoutPreview
                  ? event.phase != DenialWindowPlacementPhase.end
                  : placement.layoutPreviewing
            : placement.layoutPreviewing,
        fullscreenRestoreFrame: monitorChanged
            ? placement.fullscreenRestoreFrame?.shift(delta)
            : placement.fullscreenRestoreFrame,
      );
      if (geometryIsNew) {
        revisions.geometry = event.sequence;
      }
      if (metadataIsNew) {
        revisions.metadata = event.sequence;
      }
      state = state._replacePlacement(updated);
      return true;
    }

    // This is compositor-owned geometry. Mirror it exactly, including
    // intentional off-screen popup animation, rather than applying another
    // Flutter-side placement policy.
    final frame = geometryIsNew
        ? _initialFrame(
            event.contentRect,
            serverSideDecorated: placement.serverSideDecorated,
            expanded:
                placement.maximized && !placement.serverFrameWhileMaximized,
          )
        : placement.frame;
    final updated = placement.copyWith(
      frame: frame,
      monitorId: metadataIsNew ? event.monitorId : placement.monitorId,
      workspaceId: metadataIsNew ? event.workspaceId : placement.workspaceId,
      minimized: metadataIsNew ? false : placement.minimized,
      maximized:
          metadataIsNew &&
              (_windowLayout != DesktopWindowLayout.scrolling ||
                  _localFlutterWindowIds.contains(objectId))
          ? false
          : placement.maximized,
      fullscreen: metadataIsNew ? false : placement.fullscreen,
      dragging: dragging,
      resizing: resizing,
      layoutPreviewing: geometryIsNew
          ? layoutPreview
                ? event.phase != DenialWindowPlacementPhase.end
                : placement.layoutPreviewing
          : placement.layoutPreviewing,
      clearRestoreFrame:
          metadataIsNew &&
          (_windowLayout != DesktopWindowLayout.scrolling ||
              _localFlutterWindowIds.contains(objectId)),
      clearFullscreenRestoreFrame: metadataIsNew,
    );
    if (geometryIsNew) {
      revisions.geometry = event.sequence;
    }
    if (metadataIsNew) {
      revisions.metadata = event.sequence;
    }
    state = state._replacePlacement(updated);
    return true;
  }

  /// Applies an action only when Flutter owns the window implementation.
  ///
  /// Protocol-backed windows have already been changed by Rust before their
  /// action notification arrives. Returning false for them prevents the Dart
  /// presentation model from inventing a competing geometry transaction.
  bool applyFlutterOwnedWindowAction(
    DenialWindow window,
    DenialWindowAction action, {
    required Rect maximizeBounds,
    required Rect fullscreenBounds,
  }) {
    if (!window.isLocalFlutter) {
      return false;
    }
    final objectId = window.objectId;
    switch (action) {
      case DenialWindowAction.minimize:
        _minimize(objectId);
      case DenialWindowAction.maximize:
        _maximize(objectId, bounds: maximizeBounds);
      case DenialWindowAction.fullscreen:
        _fullscreen(objectId, bounds: fullscreenBounds);
      case DenialWindowAction.restore:
        _restore(objectId);
      case DenialWindowAction.toggleMaximize:
        _toggleMaximized(objectId, bounds: maximizeBounds);
      case DenialWindowAction.toggleFullscreen:
        final placement = state.placements[objectId];
        if (placement?.fullscreen ?? false) {
          _restore(objectId);
        } else {
          _fullscreen(objectId, bounds: fullscreenBounds);
        }
    }
    return true;
  }

  void _minimize(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null || placement.minimized) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(minimized: true, dragging: false);
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void _maximize(int objectId, {Rect? bounds}) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null || placement.maximized || placement.fullscreen) {
      return;
    }
    _toggleMaximized(objectId, bounds: bounds);
  }

  void _restore(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    if (placement.minimized) {
      activate(objectId);
    } else if (placement.fullscreen) {
      _exitFullscreen(objectId, placement);
    } else if (placement.maximized) {
      _toggleMaximized(objectId);
    }
  }

  void toggleMinimized(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(minimized: !placement.minimized);
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void _toggleMaximized(int objectId, {Rect? bounds}) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    _moveRemainders.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    if (placement.fullscreen) {
      final canvas = Offset.zero & state.viewSize;
      final requestedBounds = bounds?.intersect(canvas);
      final maximizedFrame = placement.maximized
          ? placement.fullscreenRestoreFrame ?? placement.frame
          : requestedBounds == null || requestedBounds.isEmpty
          ? _maximizedFrame(placement.monitorId, state.viewSize)
          : requestedBounds;
      final normalFrame = placement.maximized
          ? placement.restoreFrame ?? maximizedFrame
          : placement.fullscreenRestoreFrame ?? placement.frame;
      final maximized = placement.copyWith(
        frame: maximizedFrame,
        maximized: true,
        minimized: false,
        fullscreen: false,
        dragging: false,
        restoreFrame: normalFrame,
        clearFullscreenRestoreFrame: true,
      );
      next[objectId] = maximized;
      _pendingFlutterProposedFrames[objectId] = maximized.frame;
    } else if (placement.maximized) {
      final restored = placement.copyWith(
        frame: _clampFrame(
          placement.restoreFrame ?? placement.frame,
          state.viewSize,
        ),
        maximized: false,
        dragging: false,
        clearRestoreFrame: true,
      );
      next[objectId] = restored;
      _pendingFlutterProposedFrames[objectId] = restored.frame;
    } else {
      final canvas = Offset.zero & state.viewSize;
      final requestedBounds = bounds?.intersect(canvas);
      final maximizedFrame = requestedBounds == null || requestedBounds.isEmpty
          ? _maximizedFrame(placement.monitorId, state.viewSize)
          : requestedBounds;
      final maximized = placement.copyWith(
        frame: maximizedFrame,
        maximized: true,
        minimized: false,
        dragging: false,
        restoreFrame: placement.frame,
      );
      next[objectId] = maximized;
      _pendingFlutterProposedFrames[objectId] = maximized.frame;
    }
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void _fullscreen(int objectId, {required Rect bounds}) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    if (placement.fullscreen) {
      return;
    }

    final fullscreenFrame = bounds.intersect(Offset.zero & state.viewSize);
    if (fullscreenFrame.isEmpty) {
      return;
    }

    _moveRemainders.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    final fullscreen = placement.copyWith(
      frame: fullscreenFrame,
      minimized: false,
      fullscreen: true,
      dragging: false,
      fullscreenRestoreFrame: placement.frame,
    );
    next[objectId] = fullscreen;
    _pendingFlutterProposedFrames[objectId] = fullscreen.frame;
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void _exitFullscreen(int objectId, DesktopWindowPlacement placement) {
    _moveRemainders.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    final restored = placement.copyWith(
      frame: _clampFrame(
        placement.fullscreenRestoreFrame ?? placement.frame,
        state.viewSize,
      ),
      fullscreen: false,
      dragging: false,
      clearFullscreenRestoreFrame: true,
    );
    next[objectId] = restored;
    _pendingFlutterProposedFrames[objectId] = restored.frame;
    state = state.copyWith(placements: next);
  }

  void showPanel(DesktopPanel panel) {
    if (state.overviewActive || state.panel == panel) {
      return;
    }
    state = state.copyWith(panel: panel, clearOverview: state.overviewActive);
  }

  void closePanels() {
    showPanel(DesktopPanel.none);
  }

  Rect _initialFrame(
    Rect contentRect, {
    required bool serverSideDecorated,
    bool expanded = false,
  }) {
    if (!serverSideDecorated || expanded) {
      return contentRect;
    }
    return Rect.fromLTRB(
      contentRect.left - DesktopMetrics.frameBorder,
      contentRect.top - DesktopMetrics.frameBorder,
      contentRect.right + DesktopMetrics.frameBorder,
      contentRect.bottom + DesktopMetrics.frameBorder,
    );
  }

  Rect _clampFrame(Rect frame, Size viewSize, {Rect? bounds}) {
    final canvas = Offset.zero & viewSize;
    final requestedBounds = bounds?.intersect(canvas);
    final workArea = requestedBounds == null || requestedBounds.isEmpty
        ? DesktopMetrics.windowWorkArea(viewSize)
        : requestedBounds;
    final workLeft = _snapToPixel(workArea.left);
    final workTop = _snapToPixel(workArea.top);
    final workRight = _snapToPixel(workArea.right);
    final workBottom = _snapToPixel(workArea.bottom);
    final width = _snapToPixel(math.min(frame.width, workRight - workLeft));
    final height = _snapToPixel(math.min(frame.height, workBottom - workTop));
    final left = _snapToPixel(frame.left)
        .clamp(workLeft, math.max(workLeft, workRight - width))
        .toDouble();
    final top = _snapToPixel(frame.top)
        .clamp(workTop, math.max(workTop, workBottom - height))
        .toDouble();
    return Rect.fromLTWH(left, top, width, height);
  }

  Offset _snapOffset(Offset offset) {
    return Offset(_snapToPixel(offset.dx), _snapToPixel(offset.dy));
  }

  double _snapToPixel(double value) {
    return (value * _devicePixelRatio).roundToDouble() / _devicePixelRatio;
  }
}

bool _framesApproximatelyEqual(Rect first, Rect second) {
  const tolerance = 1.0;
  return (first.left - second.left).abs() <= tolerance &&
      (first.top - second.top).abs() <= tolerance &&
      (first.width - second.width).abs() <= tolerance &&
      (first.height - second.height).abs() <= tolerance;
}
