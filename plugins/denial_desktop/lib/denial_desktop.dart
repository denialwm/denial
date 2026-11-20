@Plugin()
library;

import 'src/desktop/desktop_workspace.dart' show DesktopMetrics;
import 'src/features/default_shell/default_shell_app.dart';

import 'package:denial_flutter_sdk/application.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/pets.dart';
import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/window_frames.dart';
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
    this.windowFrame,
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

  /// What draws the frame of decorated windows. Without one, the desktop
  /// draws its own border.
  final ShellWindowFrame? windowFrame;

  @override
  Widget createShell() {
    // Every frame rectangle the desktop computes follows these margins, so
    // they are fixed before anything is laid out.
    DesktopMetrics.useWindowFrameMargins(
      windowFrame?.margins,
      maximized: windowFrame?.maximizedMargins,
      reach: windowFrame?.reach,
    );
    return DenialShellApp(
      desktopSurfaces: surfaces,
      desktopWorkArea: workArea,
      desktopLauncher: launcher,
      actions: actions,
      desktopPetHolds: petHolds,
      desktopPetShadows: petShadows,
      desktopWindowFrame: windowFrame,
    );
  }
}
