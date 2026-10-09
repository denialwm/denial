/// Read-only interpretation of the manager's existing status protocol.
/// Never treat a successful build as proof that the compositor activated it.
String? compositionStartupError(Map<String, Object?> state) {
  final native = state['native'];
  if (native is! Map ||
      native['available'] == false ||
      native['active_mode'] != 'official_optimized') {
    return null;
  }
  final error = native['error'];
  return error is String && error.trim().isNotEmpty ? error : null;
}

/// What deniald waits to rebuild after Denial itself was updated, or null.
/// The packaged shell runs meanwhile; this is neither an error nor a pending
/// selection change.
Map<String, Object?>? pluginRebuild(Map<String, Object?> state) {
  final native = state['native'];
  if (native is! Map || native['available'] == false) return null;
  final rebuild = native['plugin_rebuild'];
  return rebuild is Map<String, Object?> && rebuild['bundle'] is String
      ? rebuild
      : null;
}

/// The release version the plugins are rebuilt for, or null for a development
/// build. Presentation supplies the localized update introduction.
String? rebuildVersion(Map<String, Object?> rebuild) {
  final version = rebuild['version'];
  return version is String && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)
      ? version
      : null;
}

bool selectionNeedsApply(Map<String, Object?> state) {
  Map<String, Object?> map(Object? value) =>
      value is Map<String, Object?> ? value : {};
  final selection = map(state['selection']);
  final plan = map(state['plan']);
  final build = map(state['build']);
  final native = map(state['native']);
  final active = map(state['active']);
  final hasSelection =
      map(selection['roots']).isNotEmpty ||
      ((selection['revision'] as num?) ?? 0) > 0;
  if (!hasSelection) return false;
  final currentPlan =
      selection['revision'] != null &&
      plan['selectionRevision'] == selection['revision'];
  final activated =
      build['bundle'] is String &&
      (native['plugin_bundle'] == build['bundle'] ||
          (build['reusedFrom'] is String &&
              build['reusedFrom'] == active['id'] &&
              native['plugin_bundle'] == active['bundle']));
  // A previously confirmed composition failing startup is a recovery problem,
  // not new background work. The UI must show the native error instead. A new
  // selection or candidate still needs applying even while recovery is visible.
  final previouslyApplied =
      build['bundle'] is String &&
      (build['bundle'] == active['bundle'] ||
          (build['reusedFrom'] is String &&
              build['reusedFrom'] == active['id']));
  if (currentPlan &&
      build['status'] == 'built' &&
      previouslyApplied &&
      compositionStartupError(state) != null) {
    return false;
  }
  return !(currentPlan &&
      build['status'] == 'built' &&
      activated &&
      native['plugin_healthy'] == true &&
      native['active_mode'] == 'custom_optimized');
}
