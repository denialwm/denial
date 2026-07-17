import 'package:flutter/widgets.dart';

sealed class HyprWindowEvent {
  const HyprWindowEvent({required this.windowId});

  final int windowId;
}

enum HyprWindowPlacementPhase { begin, update, end }

enum HyprWindowPlacementChange { move, resize }

@immutable
class HyprWindowPlacementEvent extends HyprWindowEvent {
  const HyprWindowPlacementEvent({
    required this.sequence,
    required super.windowId,
    required this.contentRect,
    required this.monitorId,
    required this.workspaceId,
    required this.phase,
    required this.change,
  });

  final int sequence;
  final Rect contentRect;
  final int monitorId;
  final int workspaceId;
  final HyprWindowPlacementPhase phase;
  final HyprWindowPlacementChange change;
}

enum HyprWindowAction {
  minimize,
  maximize,
  restore,
  toggleMaximize,
  toggleFullscreen,
}

@immutable
class HyprWindowActionEvent extends HyprWindowEvent {
  const HyprWindowActionEvent({
    required super.windowId,
    required this.action,
  });

  final HyprWindowAction action;
}
