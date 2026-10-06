import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/shell_font_catalog.dart';

final shellFontCatalogProvider = Provider<ShellFontCatalog>(
  (ref) => const ShellFontCatalog(),
);

final availableShellFontFamiliesProvider = FutureProvider<List<String>>(
  (ref) => ref.watch(shellFontCatalogProvider).discover(),
);
