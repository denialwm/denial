import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

/// Smallest complete alternate Denial shell.
///
/// The framework owns compositor integration; this file owns only feature UI.
void main() {
  runDenialShell(
    shell: const DenialShell(
      mobile: DenialShellScene(content: _CustomMobileScene()),
      desktop: DenialShellScene(content: _CustomDesktopScene()),
    ),
  );
}

class _CustomMobileScene extends StatelessWidget {
  const _CustomMobileScene();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [ShellWallpaper(), ShellPrimaryWindow()],
    );
  }
}

class _CustomDesktopScene extends StatelessWidget {
  const _CustomDesktopScene();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ShellWallpaper(),
        ShellWindowsBuilder(
          builder: (context, windows, actions) {
            if (windows.isEmpty) {
              return const Center(child: Text('Custom Denial shell'));
            }
            final window = windows.last;
            return GestureDetector(
              onTap: () => actions.focus(window),
              child: WindowContentRect(window: window, active: true),
            );
          },
        ),
      ],
    );
  }
}
