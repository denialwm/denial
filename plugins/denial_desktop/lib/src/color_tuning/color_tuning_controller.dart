import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/state.dart';

import 'color_grade.dart';

/// What the editor grades: the desktop when [appId] is null.
@immutable
class ColorTuningTarget {
  const ColorTuningTarget.desktop() : appId = null;
  const ColorTuningTarget.app(String this.appId);

  final String? appId;

  bool get isDesktop => appId == null;

  @override
  bool operator ==(Object other) =>
      other is ColorTuningTarget && other.appId == appId;

  @override
  int get hashCode => appId.hashCode;
}

/// A `.cube` file the editor offers as a base look.
@immutable
class ColorBase {
  const ColorBase(this.path, this.title);

  final String path;
  final String title;
}

@immutable
class ColorTuningState {
  const ColorTuningState({
    this.visible = false,
    this.target = const ColorTuningTarget.desktop(),
    this.focusedAppId,
    this.grade = ColorGrade.neutral,
    this.baseTitle,
    this.bases = const <ColorBase>[],
    this.comparing = false,
    this.failed = false,
    this.revision = 0,
  });

  final bool visible;
  final ColorTuningTarget target;

  /// The app window the user focused last; the app chip grades it.
  final String? focusedAppId;
  final ColorGrade grade;
  final String? baseTitle;
  final List<ColorBase> bases;

  /// The target shows without its grade while the user holds Before.
  final bool comparing;
  final bool failed;

  /// Advances when the grade changes from outside the controls (a target
  /// switch, a reset, a reload), so the controls retarget their springs.
  final int revision;

  ColorTuningState copyWith({
    bool? visible,
    ColorTuningTarget? target,
    String? focusedAppId,
    ColorGrade? grade,
    String? baseTitle,
    bool clearBaseTitle = false,
    List<ColorBase>? bases,
    bool? comparing,
    bool? failed,
    int? revision,
  }) => ColorTuningState(
    visible: visible ?? this.visible,
    target: target ?? this.target,
    focusedAppId: focusedAppId ?? this.focusedAppId,
    grade: grade ?? this.grade,
    baseTitle: clearBaseTitle ? null : baseTitle ?? this.baseTitle,
    bases: bases ?? this.bases,
    comparing: comparing ?? this.comparing,
    failed: failed ?? this.failed,
    revision: revision ?? this.revision,
  );
}

/// Where base looks are found.
String? colorBaseDirectory() {
  final data = Platform.environment['XDG_DATA_HOME'];
  final home = Platform.environment['HOME'];
  if (data != null && data.startsWith('/')) return '$data/denial/luts';
  if (home == null) return null;
  return '$home/.local/share/denial/luts';
}

/// A readable name for an app ID: `org.mozilla.firefox` is Firefox.
String colorTuningAppName(String appId) {
  final last = appId
      .split('.')
      .lastWhere((part) => part.isNotEmpty, orElse: () => appId);
  return last.isEmpty ? appId : last[0].toUpperCase() + last.substring(1);
}

final colorTuningProvider =
    NotifierProvider<ColorTuningController, ColorTuningState>(
      ColorTuningController.new,
    );

/// The app ID of the app window the user focused last.
String? _foregroundAppId(ShellState shell) {
  final id = shell.foregroundObjectId;
  final window = id == null ? null : shell.openAppWindowsByObjectId[id];
  return window == null || window.appId.isEmpty ? null : window.appId;
}

class ColorTuningController extends Notifier<ColorTuningState> {
  ({ColorTuningTarget target, ColorGrade grade, bool save})? _queued;
  bool _sending = false;

  /// The grade shown differs from the one saved: a change made while
  /// comparing, or a scroll that has not paused yet.
  bool _unsaved = false;

  @override
  ColorTuningState build() {
    ref.listen<String?>(shellControllerProvider.select(_foregroundAppId), (
      _,
      appId,
    ) {
      if (appId == null || appId == state.focusedAppId) return;
      final followed = !state.target.isDesktop;
      state = state.copyWith(focusedAppId: appId);
      // An app target follows the window the user taps.
      if (followed && state.visible) {
        unawaited(selectTarget(ColorTuningTarget.app(appId)));
      }
    });
    return ColorTuningState(
      focusedAppId: _foregroundAppId(ref.read(shellControllerProvider)),
    );
  }

  /// Shows the editor once the desktop is ready to be graded live. When
  /// readying it restarts the shell, deniald opens the editor again after.
  Future<void> open() async {
    final bridge = ref.read(denialBridgeProvider);
    try {
      if (!await bridge.prepareColorTuning()) return;
    } on Object {
      state = state.copyWith(visible: true, failed: true);
      return;
    }
    state = state.copyWith(visible: true, failed: false, bases: _listBases());
    await _load(state.target);
  }

  void close() {
    if (state.comparing) compare(false);
    _flush();
    state = state.copyWith(visible: false);
  }

  void toggle() => state.visible ? close() : unawaited(open());

  Future<void> selectTarget(ColorTuningTarget target) async {
    if (target == state.target) return;
    if (state.comparing) compare(false);
    _flush();
    state = state.copyWith(target: target);
    await _load(target);
  }

  /// A control moved; [save] once it is let go.
  void setGrade(ColorGrade grade, {required bool save}) {
    state = state.copyWith(grade: grade);
    if (state.comparing) {
      _unsaved = true;
      return;
    }
    _unsaved = !save;
    _send(state.target, grade, save: save);
  }

  void reset() {
    state = state.copyWith(
      grade: ColorGrade.neutral,
      revision: state.revision + 1,
      comparing: false,
    );
    _unsaved = false;
    _send(state.target, ColorGrade.neutral, save: true);
  }

  /// While held, the target shows without the grade; nothing is saved.
  void compare(bool holding) {
    if (holding == state.comparing) return;
    state = state.copyWith(comparing: holding);
    if (holding) {
      _send(state.target, ColorGrade.neutral, save: false);
    } else {
      _send(state.target, state.grade, save: _unsaved);
      _unsaved = false;
    }
  }

  /// Saves what the target shows, if it was not saved yet.
  void _flush() {
    if (!_unsaved) return;
    _unsaved = false;
    _send(state.target, state.grade, save: true);
  }

  Future<void> selectBase(ColorBase? base) async {
    final target = state.target;
    try {
      await ref
          .read(denialBridgeProvider)
          .setColorBase(appId: target.appId, path: base?.path);
    } on Object {
      state = state.copyWith(failed: true);
      return;
    }
    if (target == state.target) await _load(target, keepGrade: true);
  }

  Future<void> _load(ColorTuningTarget target, {bool keepGrade = false}) async {
    final Map<String, Object?> result;
    try {
      result = await ref
          .read(denialBridgeProvider)
          .readColorGrade(appId: target.appId);
    } on Object {
      state = state.copyWith(failed: true);
      return;
    }
    if (target != state.target) return;
    final base = result['base'];
    state = state.copyWith(
      grade: keepGrade ? null : ColorGrade.fromJson(result['grade']),
      baseTitle: base is String ? base : null,
      clearBaseTitle: base is! String,
      failed: false,
      revision: keepGrade ? null : state.revision + 1,
    );
  }

  /// One request at a time; while one is out, only the newest grade waits.
  /// A save is never dropped: it rides on the next request.
  void _send(ColorTuningTarget target, ColorGrade grade, {required bool save}) {
    final queued = _queued;
    final keepSave = queued != null && queued.target == target && queued.save;
    _queued = (target: target, grade: grade, save: save || keepSave);
    if (!_sending) unawaited(_drain());
  }

  Future<void> _drain() async {
    _sending = true;
    final bridge = ref.read(denialBridgeProvider);
    for (var next = _queued; next != null; next = _queued) {
      _queued = null;
      try {
        await bridge.writeColorGrade(
          appId: next.target.appId,
          grade: next.grade.toJson(),
          save: next.save,
        );
        if (state.failed) state = state.copyWith(failed: false);
      } on Object {
        state = state.copyWith(failed: true);
      }
    }
    _sending = false;
  }

  List<ColorBase> _listBases() {
    final directory = colorBaseDirectory();
    if (directory == null) return const <ColorBase>[];
    try {
      final bases = <ColorBase>[
        for (final entry in Directory(directory).listSync())
          if (entry is File && entry.path.toLowerCase().endsWith('.cube'))
            ColorBase(
              entry.path,
              entry.uri.pathSegments.last.replaceAll(
                RegExp(r'\.cube$', caseSensitive: false),
                '',
              ),
            ),
      ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      return bases;
    } on FileSystemException {
      return const <ColorBase>[];
    }
  }
}
