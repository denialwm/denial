import 'dart:async';

import 'package:flutter/services.dart';

import '../../models/denial_cursor_state.dart';
import '../../models/denial_drag_icon.dart';
import '../../models/desktop_notification.dart';
import '../../models/system_tray_item.dart';
import '../denial_bridge_models.dart';
import '../denial_wire.dart' as wire;
import 'configuration_client.dart';
import 'context.dart';
import 'displays_client.dart';
import 'settings_document_client.dart';
import 'windows_client.dart';

final class BridgeEventsClient {
  BridgeEventsClient(
    this._context,
    this._windows,
    this._displays,
    this._documents,
    this._configuration,
  );

  final BridgeContext _context;
  final BridgeWindowsClient _windows;
  final BridgeDisplaysClient _displays;
  final BridgeSettingsDocumentClient _documents;
  final BridgeConfigurationClient _configuration;
  final StreamController<DenialShellActionEvent> _shellActions =
      StreamController<DenialShellActionEvent>.broadcast(sync: true);
  final _pluginActions =
      StreamController<({int generation, String id, int? monitorId})>.broadcast(
        sync: true,
      );
  final StreamController<String> _cursorShapes =
      StreamController<String>.broadcast(sync: true);
  final StreamController<DenialCursorState> _cursorStates =
      StreamController<DenialCursorState>.broadcast(sync: true);
  final StreamController<Offset> _cursorPositions =
      StreamController<Offset>.broadcast(sync: true);
  final StreamController<DenialDragIcon?> _dragIcons =
      StreamController<DenialDragIcon?>.broadcast(sync: true);
  final StreamController<DesktopNotificationEvent> _notificationEvents =
      StreamController<DesktopNotificationEvent>.broadcast(sync: true);
  final StreamController<XEmbedTrayEvent> _xembedTrayEvents =
      StreamController<XEmbedTrayEvent>.broadcast(sync: true);
  final Map<int, SystemTrayItem> _xembedTrayItems = <int, SystemTrayItem>{};
  final StreamController<DenialTextInputState> _textInputStates =
      StreamController<DenialTextInputState>.broadcast(sync: true);
  final StreamController<DenialTextPrediction> _textPredictions =
      StreamController<DenialTextPrediction>.broadcast(sync: true);

  Future<ByteData?> handleMessage(ByteData? data) async {
    if (wire.isDenialPlacementPacket(data)) {
      final event = _context.codec.decodePlacement(data);
      if (event != null && !_windows.eventsClosed) {
        _windows.publishPlacement(event);
      }
      return null;
    }

    if (wire.isDenialDragIconPacket(data)) {
      final update = _context.codec.decodeDragIcon(data);
      if (update != null && !_dragIcons.isClosed) {
        _dragIcons.add(update.icon);
      }
      return null;
    }

    final decoded = _context.codec.decodeStructured(data);
    if (decoded == null) {
      return null;
    }

    try {
      final payload = decoded.payload;
      if (payload is wire.WindowSnapshot) {
        _windows.completeSnapshot(decoded.sequence, decoded.requestId, payload);
      } else if (payload is wire.DisplayLayout) {
        _displays.completeLayout(decoded.requestId, payload);
      } else if (payload is wire.WindowResponse) {
        _handleWindowResponse(decoded.sequence, decoded.requestId, payload);
      } else if (payload is wire.WindowEvent) {
        _windows.handleEvent(payload);
      } else if (payload is wire.PluginActionInvocation) {
        if (payload.id case final id?) {
          if (!_pluginActions.isClosed) {
            _pluginActions.add((
              generation: payload.generation,
              id: id,
              monitorId: payload.monitorId < 0 ? null : payload.monitorId,
            ));
          }
        }
      } else if (payload is wire.ShellAction) {
        final action = switch (payload.action) {
          wire.ShellActionKind.Applications => DenialShellAction.applications,
          wire.ShellActionKind.Dashboard => DenialShellAction.dashboard,
          wire.ShellActionKind.Overview => DenialShellAction.overview,
          wire.ShellActionKind.WindowSwitcherNext =>
            DenialShellAction.windowSwitcherNext,
          wire.ShellActionKind.WindowSwitcherPrevious =>
            DenialShellAction.windowSwitcherPrevious,
          wire.ShellActionKind.WindowSwitcherEnd =>
            DenialShellAction.windowSwitcherEnd,
          wire.ShellActionKind.Clipboard => DenialShellAction.clipboard,
          wire.ShellActionKind.ScreenshotRegion =>
            DenialShellAction.screenshotPrepare,
          wire.ShellActionKind.ScreenshotTextureReady =>
            DenialShellAction.screenshotTextureReady,
          wire.ShellActionKind.ScreenshotDone =>
            DenialShellAction.screenshotDone,
          wire.ShellActionKind.ClientPointerPressed =>
            DenialShellAction.clientPointerPressed,
          wire.ShellActionKind.Wallpaper => DenialShellAction.wallpaper,
          wire.ShellActionKind.OpenSettings => DenialShellAction.openSettings,
          wire.ShellActionKind.WorkspaceChanged =>
            DenialShellAction.workspaceChanged,
          wire.ShellActionKind.FocusLeft => DenialShellAction.focusLeft,
          wire.ShellActionKind.FocusRight => DenialShellAction.focusRight,
          wire.ShellActionKind.FocusUp => DenialShellAction.focusUp,
          wire.ShellActionKind.FocusDown => DenialShellAction.focusDown,
          wire.ShellActionKind.ScreenshotCaptured =>
            DenialShellAction.screenshotCaptured,
        };
        if (!_shellActions.isClosed) {
          _shellActions.add(
            DenialShellActionEvent(
              action: action,
              monitorId: payload.hasMonitorId && payload.monitorId >= 0
                  ? payload.monitorId
                  : null,
              requestId: decoded.requestId,
              textureId: payload.textureId > 0 ? payload.textureId : null,
              workspaceId:
                  payload.action == wire.ShellActionKind.WorkspaceChanged &&
                      payload.workspaceId > 0
                  ? payload.workspaceId
                  : null,
            ),
          );
        }
      } else if (payload is wire.CursorShape) {
        final shape = payload.shape?.trim().toLowerCase();
        if (shape != null && shape.isNotEmpty && !_cursorShapes.isClosed) {
          _cursorShapes.add(shape);
        }
      } else if (payload is wire.CursorState) {
        final state = _context.codec.decodeCursorState(payload);
        if (state != null && !_cursorStates.isClosed) {
          _cursorStates.add(state);
          if (state.kind == DenialCursorStateKind.named &&
              state.shape.isNotEmpty &&
              !_cursorShapes.isClosed) {
            _cursorShapes.add(state.shape);
          } else if (state.kind == DenialCursorStateKind.hidden &&
              !_cursorShapes.isClosed) {
            _cursorShapes.add('none');
          }
        }
      } else if (payload is wire.CursorPosition) {
        if (payload.x.isFinite &&
            payload.y.isFinite &&
            !_cursorPositions.isClosed) {
          _cursorPositions.add(Offset(payload.x, payload.y));
        }
      } else if (payload is wire.TextInputState) {
        if ((!payload.inputPanelVisible || payload.active) &&
            !_textInputStates.isClosed) {
          _textInputStates.add(
            DenialTextInputState(
              active: payload.active,
              inputPanelVisible: payload.inputPanelVisible,
              legacy: payload.legacy,
              contentHint: payload.contentHint,
              contentPurpose: payload.contentPurpose,
              activationSerial: payload.activationSerial,
            ),
          );
        }
      } else if (payload is wire.TextPrediction) {
        if (!_textPredictions.isClosed) {
          _textPredictions.add(
            DenialTextPrediction(
              serial: payload.serial,
              word: payload.word ?? '',
              correction: payload.correction,
              suggestions: List<String>.unmodifiable(
                payload.suggestions ?? const <String>[],
              ),
              languages: List<String>.unmodifiable(
                payload.languages ?? const <String>[],
              ),
            ),
          );
        }
      } else if (payload is wire.DesktopNotificationEvent) {
        final event = _context.codec.decodeNotificationEvent(payload);
        if (event != null && !_notificationEvents.isClosed) {
          _notificationEvents.add(event);
        }
      } else if (payload is wire.XembedTrayEvent) {
        final event = _context.codec.decodeXEmbedTrayEvent(payload);
        if (event != null) {
          if (event.kind == XEmbedTrayEventKind.removed) {
            _xembedTrayItems.remove(event.windowId);
          } else if (event.item case final item?) {
            _xembedTrayItems[event.windowId] = item;
          }
          if (!_xembedTrayEvents.isClosed) {
            _xembedTrayEvents.add(event);
          }
        }
      } else if (payload is wire.SettingsResponse) {
        if (payload.kind == wire.SettingsResponseKind.Document) {
          _documents.handleResponse(decoded.requestId, payload);
        } else {
          _configuration.handleResponse(decoded.requestId, payload);
        }
      }
    } on Object {
      _context.codec.rejectedStructuredMessages += 1;
    }

    return null;
  }

  void _handleWindowResponse(
    int sequence,
    int requestId,
    wire.WindowResponse response,
  ) {
    if (!response.success) {
      _windows.reject(requestId, response.error);
      _displays.reject(requestId);
      return;
    }

    if (response.kind == wire.WindowResponseKind.Windows &&
        response.windows != null) {
      _windows.completeSnapshot(sequence, requestId, response.windows!);
    } else if (response.kind == wire.WindowResponseKind.DisplayLayout &&
        response.displayLayout != null) {
      _displays.completeLayout(requestId, response.displayLayout!);
    }
  }

  void publishPluginActions(int generation, List<Map<String, Object>> actions) {
    if (_context.useControlSocket) return;
    final bytes = _context.codec.encodePluginActionCatalog(generation, actions);
    if (bytes != null) _context.sendWire(bytes);
  }

  bool dismissNotification(int notificationId) {
    return _sendNotificationCommand(
      wire.DesktopNotificationCommandKind.Dismiss,
      notificationId,
    );
  }

  bool invokeNotificationAction(int notificationId, String actionKey) {
    return _sendNotificationCommand(
      wire.DesktopNotificationCommandKind.InvokeAction,
      notificationId,
      actionKey: actionKey,
    );
  }

  bool invokeDefaultNotificationAction(int notificationId) {
    return _sendNotificationCommand(
      wire.DesktopNotificationCommandKind.InvokeDefault,
      notificationId,
    );
  }

  bool invokeXEmbedTrayAction(
    int windowId,
    SystemTrayAction action,
    Offset position,
  ) {
    final kind = switch (action) {
      SystemTrayAction.activate => wire.XembedTrayCommandKind.Activate,
      SystemTrayAction.secondaryActivate =>
        wire.XembedTrayCommandKind.SecondaryActivate,
      SystemTrayAction.contextMenu => wire.XembedTrayCommandKind.ContextMenu,
    };
    final bytes = _context.codec.encodeXEmbedTrayCommand(
      kind,
      windowId,
      position,
    );
    if (bytes == null) {
      return false;
    }
    _context.sendWire(bytes);
    return true;
  }

  bool _sendNotificationCommand(
    wire.DesktopNotificationCommandKind kind,
    int notificationId, {
    String? actionKey,
  }) {
    final bytes = _context.codec.encodeNotificationCommand(
      kind,
      notificationId,
      actionKey: actionKey,
    );
    if (bytes == null) {
      return false;
    }
    _context.sendWire(bytes);
    return true;
  }

  Stream<DenialShellActionEvent> get shellActions => _shellActions.stream;

  Stream<({int generation, String id, int? monitorId})> get pluginActions =>
      _pluginActions.stream;

  Stream<String> get cursorShapes => _cursorShapes.stream;

  Stream<DenialCursorState> get cursorStates => _cursorStates.stream;

  Stream<Offset> get cursorPositions => _cursorPositions.stream;

  Stream<DenialDragIcon?> get dragIcons => _dragIcons.stream;

  Stream<DesktopNotificationEvent> get notificationEvents =>
      _notificationEvents.stream;

  Stream<XEmbedTrayEvent> get xembedTrayEvents => _xembedTrayEvents.stream;

  Map<int, SystemTrayItem> get xembedTrayItems =>
      Map<int, SystemTrayItem>.unmodifiable(_xembedTrayItems);

  Stream<DenialTextInputState> get textInputStates => _textInputStates.stream;

  Stream<DenialTextPrediction> get textPredictions => _textPredictions.stream;
  void dispose() {
    unawaited(_shellActions.close());
    unawaited(_pluginActions.close());
    unawaited(_cursorShapes.close());
    unawaited(_cursorStates.close());
    unawaited(_cursorPositions.close());
    unawaited(_dragIcons.close());
    unawaited(_notificationEvents.close());
    unawaited(_xembedTrayEvents.close());
    unawaited(_textInputStates.close());
    unawaited(_textPredictions.close());
  }
}
