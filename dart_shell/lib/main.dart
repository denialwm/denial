import 'denial.dart';
import 'denial_default_shell.dart';
import 'src/settings/settings_application.dart';

void main() {
  runDenialShell(
    shell: const DenialShellApp(),
    localApplications: (environment) => environment.flag('DENIA_EMBED_SETTINGS')
        ? <LocalFlutterApplication>[denialSettingsApplication]
        : const <LocalFlutterApplication>[],
  );
}
