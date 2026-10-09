import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/pets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Statically supplied by the application; no runtime discovery or selection.
final desktopSurfacesProvider = Provider<List<ShellSurface>>((ref) => const []);

/// Optional launcher selected by the compiled application.
final desktopLauncherProvider = Provider<ShellLauncher?>((ref) => null);

final desktopActionsProvider = Provider<List<ShellAction>>((ref) => const []);

/// Optional pet holds selected by the compiled application. Without one,
/// desktop pets are only ever let go free.
final desktopPetHoldsProvider = Provider<ShellPetHolds?>((ref) => null);

/// Optional pet shadows selected by the compiled application. Without one,
/// held pets cast nothing on their windows.
final desktopPetShadowsProvider = Provider<ShellPetShadows?>((ref) => null);
