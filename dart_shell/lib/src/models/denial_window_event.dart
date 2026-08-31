import 'package:flutter/widgets.dart';

sealed class DenialWindowEvent {
  const DenialWindowEvent({required this.windowId});

  final int windowId;
}

enum DenialWindowPlacementPhase { begin, update, end }

enum DenialWindowPlacementChange { move, resize, layoutPreview }

@immutable
class DenialWindowPlacementEvent extends DenialWindowEvent {
  const DenialWindowPlacementEvent({
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
  final DenialWindowPlacementPhase phase;
  final DenialWindowPlacementChange change;
}

enum DenialWindowAction {
  minimize,
  maximize,
  restore,
  toggleMaximize,
  toggleFullscreen,
}

@immutable
class DenialWindowActionEvent extends DenialWindowEvent {
  const DenialWindowActionEvent({
    required super.windowId,
    required this.action,
  });

  final DenialWindowAction action;
}
