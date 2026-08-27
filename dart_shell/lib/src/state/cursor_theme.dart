import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../launcher/runtime_paths.dart';
import '../theme/cursor_theme_repository.dart';
import '../theme/cursor_themes.dart';

final cursorThemeRepositoryProvider = Provider<CursorThemeRepository>((ref) {
  final environment = ref.watch(startupEnvironmentProvider).values;
  return CursorThemeRepository(
    dataHome: RuntimePaths(environment: environment).dataHome,
  );
});

final cursorThemeCatalogProvider =
    AsyncNotifierProvider<
      CursorThemeCatalogController,
      List<ShellCursorThemeData>
    >(CursorThemeCatalogController.new);

class CursorThemeCatalogController
    extends AsyncNotifier<List<ShellCursorThemeData>> {
  @override
  Future<List<ShellCursorThemeData>> build() {
    return ref.watch(cursorThemeRepositoryProvider).discover();
  }

  Future<void> refresh() async {
    final repository = ref.read(cursorThemeRepositoryProvider);
    final refreshed = await repository.discover();
    state = AsyncData(refreshed);
  }

  Future<ShellCursorThemeData> importZip(String path) async {
    final repository = ref.read(cursorThemeRepositoryProvider);
    final imported = await repository.importWindowsCursorZip(path);
    state = AsyncData(await repository.discover());
    return imported;
  }

  Future<void> remove(ShellCursorThemeData theme) async {
    final repository = ref.read(cursorThemeRepositoryProvider);
    await repository.remove(theme);
    state = AsyncData(await repository.discover());
  }
}

final availableShellCursorThemesProvider = Provider<List<ShellCursorThemeData>>(
  (ref) =>
      ref.watch(cursorThemeCatalogProvider).asData?.value ??
      ShellCursorThemes.all,
);

final shellCursorThemeProvider = Provider<ShellCursorThemeData>((ref) {
  final selectedId = ref
      .watch(startupEnvironmentProvider)['DENIA_CURSOR_THEME']
      ?.trim()
      .toLowerCase();
  return resolveShellCursorTheme(ShellCursorThemes.all, selectedId ?? '');
});

ShellCursorThemeData resolveShellCursorTheme(
  Iterable<ShellCursorThemeData> themes,
  String selectedId,
) {
  for (final theme in themes) {
    if (theme.id == selectedId) {
      return theme;
    }
  }
  return ShellCursorThemes.bibataModernIce;
}
