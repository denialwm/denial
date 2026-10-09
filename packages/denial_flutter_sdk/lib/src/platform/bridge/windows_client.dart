import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../models/denial_pet.dart';
import '../../models/denial_window.dart';
import '../../models/denial_window_event.dart';
import '../../models/denial_window_snapshot.dart';
import '../denial_wire.dart' as wire;
import 'context.dart';

final class BridgeWindowsClient {
  BridgeWindowsClient(this._context);

  final BridgeContext _context;
  final _snapshots = StreamController<DenialWindowSnapshot>.broadcast(
    sync: true,
  );
  final _invalidations = StreamController<void>.broadcast(sync: true);
  final Map<int, Completer<DenialWindowSnapshot>> _pendingWindowRequests = {};
  final StreamController<DenialWindowEvent> _windowEvents =
      StreamController<DenialWindowEvent>.broadcast(sync: true);
  final StreamController<int> _windowActivations =
      StreamController<int>.broadcast(sync: true);
  VoidCallback? _onWindowsChanged;
  ValueChanged<DenialWindowSnapshot>? _onWindowSnapshot;
  ValueChanged<int>? _onWindowActivated;
  static const String _windowCloseCompleteChannel =
      'denial/window_close_complete';

  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) {
    final requestId = _context.platform.nextRequestId();
    final completer = Completer<DenialWindowSnapshot>();
    _pendingWindowRequests[requestId] = completer;

    final bytes = _context.codec.encodeWindowRequest(
      wire.WindowRequestKind.ListWindows,
      requestId: requestId,
    );
    final response = _context.platform.send(
      wire.denialWireToNativeChannel,
      ByteData.sublistView(bytes),
    );
    response?.catchError((Object error) {
      final pending = _pendingWindowRequests.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(error);
      }
      return null;
    });

    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingWindowRequests.remove(requestId);
        return DenialWindowSnapshot(sequence: 0, windows: fallback);
      },
    );
  }

  /// Requests a compositor-owned window whose content is built by the
  /// embedded Flutter shell instead of sampled from a client surface.
  bool createLocalWindow({
    required String appId,
    required String title,
    required Rect geometry,
  }) {
    final bytes = _context.codec.encodeCreateLocalWindow(
      appId: appId,
      title: title,
      geometry: geometry,
    );
    if (bytes == null) {
      return false;
    }
    _context.sendWire(bytes);
    return true;
  }

  void closeWindow(DenialWindow window) {
    if (window.windowId <= 0) {
      return;
    }

    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.CloseWindow,
        windowId: window.windowId,
      ),
    );
  }

  /// Releases the native last-frame texture retained for a finished close
  /// animation. Native also owns a bounded watchdog, so a lost message cannot
  /// leak a client buffer or Flutter texture.
  bool completeWindowClose(int windowId) {
    if (windowId <= 0) {
      return false;
    }

    final payload = ByteData(8)..setUint64(0, windowId, Endian.little);
    _context.platform
        .send(_windowCloseCompleteChannel, payload)
        ?.catchError((Object _) => null);
    return true;
  }

  void focusWindow(DenialWindow window) {
    if (window.windowId <= 0) {
      return;
    }
    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.FocusWindow,
        windowId: window.windowId,
      ),
    );
  }

  void switchWorkspace({required int monitorId, required int workspaceId}) {
    if (monitorId < 0 || workspaceId < 1 || workspaceId > 9) {
      return;
    }
    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.SwitchWorkspace,
        monitorId: monitorId,
        workspaceId: workspaceId,
      ),
    );
  }

  /// Names the hold a pet the user drags takes if let go now, or none.
  /// Native keeps it only if the pet accepts it and the window may hold
  /// pets, and applies the latest one when the drag ends.
  void holdPet(int petId, DenialPetHold? hold) {
    if (_context.codec.encodePetHold(petId, hold) case final bytes?) {
      _context.sendWire(bytes);
    }
  }

  /// Tells native how fast a held pet moves on screen, in logical px/s, so
  /// the pet can feel it. Zero when it stops.
  void carryPet(int petId, Offset velocity) {
    if (_context.codec.encodePetCarried(petId, velocity) case final bytes?) {
      _context.sendWire(bytes);
    }
  }

  void moveWindowToWorkspace(
    DenialWindow window, {
    int? monitorId,
    required int workspaceId,
    bool follow = true,
  }) {
    if (window.windowId <= 0 || workspaceId < 1 || workspaceId > 9) {
      return;
    }
    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.MoveWindowToWorkspace,
        windowId: window.windowId,
        monitorId: monitorId ?? -1,
        workspaceId: workspaceId,
        flags: follow ? 1 : 0,
      ),
    );
  }

  /// Commits an overview drop of [window] onto [workspaceId] of
  /// [monitorId], which may be hidden. [point] is the drop position in that
  /// workspace's own scene coordinates; native resolves it to a tile
  /// operation and restores a minimized window on the way.
  void dropWindowOnWorkspace(
    DenialWindow window, {
    required int monitorId,
    required int workspaceId,
    required Offset point,
  }) {
    _sendWorkspaceDrop(
      window,
      monitorId: monitorId,
      workspaceId: workspaceId,
      point: point,
      flags: _workspaceLayoutDrop,
    );
  }

  /// Plans [dropWindowOnWorkspace] without committing it. Native answers with
  /// layout-preview placements, including the dragged window's landing slot.
  /// A null [point] ends the preview.
  void previewWindowDropOnWorkspace(
    DenialWindow window, {
    required int monitorId,
    required int workspaceId,
    Offset? point,
  }) {
    _sendWorkspaceDrop(
      window,
      monitorId: monitorId,
      workspaceId: workspaceId,
      point: point,
      flags: _workspaceDropPreview,
    );
  }

  static const int _workspaceLayoutDrop = 1 << 1;
  static const int _workspaceDropPreview = 1 << 2;

  void _sendWorkspaceDrop(
    DenialWindow window, {
    required int monitorId,
    required int workspaceId,
    required Offset? point,
    required int flags,
  }) {
    if (window.windowId <= 0 ||
        monitorId < 0 ||
        workspaceId < 1 ||
        workspaceId > 9 ||
        (point != null && !point.isFinite)) {
      return;
    }
    // Native resolves only the centre. A scrolling strip may place it left
    // of or above its output.
    final geometry = point == null
        ? null
        : Rect.fromCenter(center: point, width: 2.0, height: 2.0);
    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.MoveWindowToWorkspace,
        windowId: window.windowId,
        monitorId: monitorId,
        workspaceId: workspaceId,
        geometry: geometry,
        flags: flags,
      ),
    );
  }

  void configureWindow(
    DenialWindow window,
    Rect contentRect, {
    bool exact = false,
    bool layoutDrop = false,
  }) {
    assert(!exact || !layoutDrop);
    if (window.windowId <= 0 ||
        contentRect.width < 1.0 ||
        contentRect.height < 1.0) {
      return;
    }
    final geometry = Rect.fromLTWH(
      contentRect.left.round().clamp(0, 16384).toDouble(),
      contentRect.top.round().clamp(0, 16384).toDouble(),
      contentRect.width.round().clamp(64, 16384).toDouble(),
      contentRect.height.round().clamp(64, 16384).toDouble(),
    );
    _context.sendWire(
      _context.codec.encodeWindowRequest(
        wire.WindowRequestKind.ConfigureWindow,
        windowId: window.windowId,
        geometry: geometry,
        flags: (exact ? 1 : 0) | (layoutDrop ? 2 : 0),
      ),
    );
  }

  Stream<DenialWindowEvent> get windowEvents => _windowEvents.stream;

  /// Every native activation, including reactivating the already-focused app.
  Stream<int> get windowActivations => _windowActivations.stream;

  /// Assigns optional window callbacks; transport reception is already active.
  /// Prefer the independent window streams for provider-owned subscriptions.
  void setWindowCallbacks({
    required VoidCallback onWindowsChanged,
    ValueChanged<DenialWindowSnapshot>? onWindowSnapshot,
    required ValueChanged<int> onWindowActivated,
  }) {
    _onWindowsChanged = onWindowsChanged;
    _onWindowSnapshot = onWindowSnapshot;
    _onWindowActivated = onWindowActivated;
  }

  void handleEvent(wire.WindowEvent event) {
    if (event.kind == wire.WindowEventKind.WindowsChanged) {
      _onWindowsChanged?.call();
      if (!_invalidations.isClosed) _invalidations.add(null);
      return;
    }
    if (event.windowId <= 0) {
      return;
    }
    if (event.kind == wire.WindowEventKind.Activated) {
      _onWindowActivated?.call(event.windowId);
      if (!_windowActivations.isClosed) _windowActivations.add(event.windowId);
      return;
    }
    if (event.kind == wire.WindowEventKind.Action && !_windowEvents.isClosed) {
      final action = switch (event.action) {
        wire.WindowActionKind.Minimize => DenialWindowAction.minimize,
        wire.WindowActionKind.Maximize => DenialWindowAction.maximize,
        wire.WindowActionKind.Fullscreen => DenialWindowAction.fullscreen,
        wire.WindowActionKind.Restore => DenialWindowAction.restore,
        wire.WindowActionKind.ToggleMaximize =>
          DenialWindowAction.toggleMaximize,
        wire.WindowActionKind.ToggleFullscreen =>
          DenialWindowAction.toggleFullscreen,
      };
      _windowEvents.add(
        DenialWindowActionEvent(windowId: event.windowId, action: action),
      );
    }
  }

  void completeSnapshot(
    int sequence,
    int requestId,
    wire.WindowSnapshot snapshot,
  ) {
    final windows = _context.codec.decodeWindows(snapshot, sequence: sequence);
    if (windows == null) {
      return;
    }
    final completer = _pendingWindowRequests.remove(requestId);
    final update = DenialWindowSnapshot(sequence: sequence, windows: windows);
    if (completer != null && !completer.isCompleted) {
      completer.complete(update);
    } else if (requestId == 0) {
      // Native publishes this snapshot before marking the corresponding
      // external-texture frame. Keep this synchronous so metadata and EGLImage
      // advance as one ordered transaction.
      _onWindowSnapshot?.call(update);
      if (!_snapshots.isClosed) _snapshots.add(update);
    }
  }

  bool get eventsClosed => _windowEvents.isClosed;
  Stream<DenialWindowSnapshot> get windowSnapshots => _snapshots.stream;
  Stream<void> get windowsChanged => _invalidations.stream;
  void publishPlacement(DenialWindowEvent event) {
    if (!_windowEvents.isClosed) _windowEvents.add(event);
  }

  void reject(int requestId, String? error) {
    final pending = _pendingWindowRequests.remove(requestId);
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        StateError(error ?? 'Denial window request failed'),
      );
    }
  }

  void dispose() {
    for (final pending in _pendingWindowRequests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Denial bridge disposed'));
      }
    }
    _pendingWindowRequests.clear();
    _onWindowsChanged = null;
    _onWindowSnapshot = null;
    _onWindowActivated = null;
    unawaited(_windowEvents.close());
    unawaited(_windowActivations.close());
    unawaited(_snapshots.close());
    unawaited(_invalidations.close());
  }
}
