/// Visual treatment used when a desktop client disappears from the native
/// window snapshot.
///
/// Set `DENIA_DESKTOP_WINDOW_CLOSE_EFFECT` to `explosion`, `implode`, `fade`, or
/// `none` to choose the startup value. Settings owns runtime selection.
enum DesktopWindowCloseEffect {
  explosion,
  implode,
  fade,
  none;

  static DesktopWindowCloseEffect? tryParse(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'explosion' || 'explode' || 'particles' => explosion,
      'implode' || 'implosion' || 'shrink' => implode,
      'fade' => fade,
      'none' || 'off' || 'disabled' => none,
      _ => null,
    };
  }

  static DesktopWindowCloseEffect fromEnvironment(
    Map<String, String> environment,
  ) {
    return tryParse(environment['DENIA_DESKTOP_WINDOW_CLOSE_EFFECT']) ??
        explosion;
  }
}
