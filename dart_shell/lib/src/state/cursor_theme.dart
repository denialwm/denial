import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../theme/cursor_themes.dart';

final availableShellCursorThemesProvider = Provider<List<ShellCursorThemeData>>(
  (ref) => ShellCursorThemes.all,
);

final shellCursorThemeProvider =
    NotifierProvider<ShellCursorThemeController, ShellCursorThemeData>(
      ShellCursorThemeController.new,
    );

class ShellCursorThemeController extends Notifier<ShellCursorThemeData> {
  @override
  ShellCursorThemeData build() {
    final initialId = ref.watch(
      startupEnvironmentProvider,
    )['DENIA_CURSOR_THEME'];
    return ShellCursorThemes.find(initialId?.trim().toLowerCase() ?? '') ??
        ShellCursorThemes.yangyangXuanling;
  }

  bool select(String id) {
    final next = ShellCursorThemes.find(id.trim().toLowerCase());
    if (next == null) {
      return false;
    }
    state = next;
    return true;
  }
}
