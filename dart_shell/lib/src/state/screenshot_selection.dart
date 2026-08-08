import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ScreenshotSelectionPhase { preparing, selecting, finishing }

@immutable
class ScreenshotSelectionSession {
  const ScreenshotSelectionSession({
    required this.requestId,
    required this.phase,
    this.textureId,
    this.anchor,
    this.current,
  });

  final int requestId;
  final ScreenshotSelectionPhase phase;
  final int? textureId;
  final Offset? anchor;
  final Offset? current;

  bool get hidesCursor => phase == ScreenshotSelectionPhase.preparing;

  Rect? get selection {
    final start = anchor;
    final end = current;
    return start == null || end == null ? null : Rect.fromPoints(start, end);
  }

  ScreenshotSelectionSession copyWith({
    ScreenshotSelectionPhase? phase,
    int? textureId,
    Offset? anchor,
    Offset? current,
    bool clearDrag = false,
  }) {
    return ScreenshotSelectionSession(
      requestId: requestId,
      phase: phase ?? this.phase,
      textureId: textureId ?? this.textureId,
      anchor: clearDrag ? null : anchor ?? this.anchor,
      current: clearDrag ? null : current ?? this.current,
    );
  }
}

final screenshotSelectionProvider =
    NotifierProvider<
      ScreenshotSelectionController,
      ScreenshotSelectionSession?
    >(ScreenshotSelectionController.new);

class ScreenshotSelectionController
    extends Notifier<ScreenshotSelectionSession?> {
  @override
  ScreenshotSelectionSession? build() => null;

  bool prepare(int requestId) {
    if (requestId <= 0 || state != null) {
      return false;
    }
    state = ScreenshotSelectionSession(
      requestId: requestId,
      phase: ScreenshotSelectionPhase.preparing,
    );
    return true;
  }

  bool textureReady(int requestId, int textureId) {
    final session = state;
    if (requestId <= 0 ||
        textureId <= 0 ||
        session?.requestId != requestId ||
        session?.phase != ScreenshotSelectionPhase.preparing) {
      return false;
    }
    state = session!.copyWith(
      phase: ScreenshotSelectionPhase.selecting,
      textureId: textureId,
    );
    return true;
  }

  void start(Offset point) {
    final session = state;
    if (session?.phase != ScreenshotSelectionPhase.selecting) {
      return;
    }
    state = session!.copyWith(anchor: point, current: point);
  }

  void update(Offset point) {
    final session = state;
    if (session?.phase != ScreenshotSelectionPhase.selecting ||
        session?.anchor == null) {
      return;
    }
    state = session!.copyWith(current: point);
  }

  void resetDrag() {
    final session = state;
    if (session?.phase == ScreenshotSelectionPhase.selecting) {
      state = session!.copyWith(clearDrag: true);
    }
  }

  Rect? complete({double minimumExtent = 2}) {
    final selection = state?.selection;
    if (selection == null ||
        selection.width < minimumExtent ||
        selection.height < minimumExtent) {
      resetDrag();
      return null;
    }
    return selection;
  }

  void finishLocally(int requestId) {
    final session = state;
    if (session?.requestId == requestId) {
      state = session!.copyWith(
        phase: ScreenshotSelectionPhase.finishing,
        clearDrag: true,
      );
    }
  }

  void done(int requestId) {
    if (state?.requestId == requestId) {
      state = null;
    }
  }
}
