@Plugin()
library;

import 'src/features/default_shell/default_shell_app.dart';

import 'package:denial_flutter_sdk/application.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/pets.dart';
import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

/// Reference scene mounts plugin-declared surfaces through the SDK.
@Provides(ShellApplication)
class ReferenceDesktop implements ShellApplication {
  const ReferenceDesktop({
    this.surfaces = const [],
    this.workArea,
    this.launcher,
    this.actions = const [],
    this.petHolds,
    this.petShadows,
  });
  final List<ShellSurface> surfaces;
  final ShellWorkArea? workArea;
  final ShellLauncher? launcher;
  final List<ShellAction> actions;

  /// Which window holds a desktop pet the user drags. Without one, pets are
  /// only ever let go free.
  final ShellPetHolds? petHolds;

  /// What a held pet casts on its window. Without one, nothing.
  final ShellPetShadows? petShadows;

  @override
  Widget createShell() => DenialShellApp(
    desktopSurfaces: surfaces,
    desktopWorkArea: workArea,
    desktopLauncher: launcher,
    actions: actions,
    desktopPetHolds: petHolds,
    desktopPetShadows: petShadows,
  );
}
