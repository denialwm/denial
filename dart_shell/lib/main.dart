import 'denial.dart';
import 'denial_default_shell.dart';

Future<void> main() async {
  await runDenialShell(shell: const DenialShellApp());
}
