import 'package:denial_clock/denial_clock.dart';
import 'package:denial_desktop/denial_desktop.dart';
import 'package:denial_flutter_sdk/shell.dart';
import 'package:denial_launcher/denial_launcher.dart';
import 'package:denial_pets/denial_pets.dart';
import 'package:denial_top_bar/denial_top_bar.dart';

Future<void> main() async {
  await runDenialShell(
    shell: const ReferenceDesktop(
      surfaces: [TopBarPlugin(), DesktopClockPlugin()],
      workArea: TopBarWorkArea(),
      launcher: LauncherPlugin(),
      actions: [OpenApplicationsAction()],
      petHolds: PerchHolds(),
      petShadows: ContactShadows(),
    ).createShell(),
  );
}
