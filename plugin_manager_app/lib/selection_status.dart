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
  // `active` is what deniald runs, when this manager built it. A composition
  // that failed to start is not running, so applying it again stays offered
  // beside the native error.
  final activated =
      build['bundle'] is String &&
      (native['plugin_bundle'] == build['bundle'] ||
          (build['reusedFrom'] is String &&
              build['reusedFrom'] == active['id'] &&
              native['plugin_bundle'] == active['bundle']));
  return !(currentPlan &&
      build['status'] == 'built' &&
      activated &&
      native['plugin_healthy'] == true &&
      native['active_mode'] == 'custom_optimized');
}
