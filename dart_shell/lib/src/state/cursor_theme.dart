import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../theme/cursor_themes.dart';

final availableShellCursorThemesProvider =
    Provider<List<ShellCursorThemeData>>((ref) => ShellCursorThemes.all);

final shellCursorThemeProvider =
    StateNotifierProvider<ShellCursorThemeController, ShellCursorThemeData>(
        (ref) {
  return ShellCursorThemeController(
    initialId: ref.watch(startupEnvironmentProvider)['DENIA_CURSOR_THEME'],
  );
});

class ShellCursorThemeController extends StateNotifier<ShellCursorThemeData> {
  ShellCursorThemeController({String? initialId})
      : super(
          ShellCursorThemes.find(initialId?.trim().toLowerCase() ?? '') ??
              ShellCursorThemes.yangyangXuanling,
        );

  bool select(String id) {
    final next = ShellCursorThemes.find(id.trim().toLowerCase());
    if (next == null) {
      return false;
    }
    state = next;
    return true;
  }
}
