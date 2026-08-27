import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/denial_window.dart';
import '../state/shell_controller.dart';

/// The user-facing application windows currently known to the compositor.
///
/// Custom shell features can watch this provider without reproducing Denial's
/// filtering rules for protocol helper surfaces.
final userAppWindowsProvider = Provider<List<DenialWindow>>((ref) {
  final windows = ref.watch(
    shellControllerProvider.select((state) => state.windows),
  );
  return List<DenialWindow>.unmodifiable(
    windows.where((window) => window.isUserApp),
  );
});
