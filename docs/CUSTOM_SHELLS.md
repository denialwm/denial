# Custom Flutter shells

Denial's Flutter code has two explicit layers:

- `package:denial_dart_shell/denial.dart` is the reusable shell framework;
- `package:denial_dart_shell/denial_default_shell.dart` assembles Denial's
  stock launcher, desktop, dashboard, shade, notification, and wallpaper
  features.

Code outside the package should never import `lib/src`. That tree is free to
change while the public framework library remains the custom-shell boundary.

## Minimal entry point

A custom entry point does not need to initialize the native bridge, Riverpod,
startup configuration, telemetry, input publication, cursor, localization,
theme, lock screen, software keyboard, or screenshot selection:

```dart
import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

void main() {
  runDenialShell(
    shell: const DenialShell(
      mobile: DenialShellScene(content: MyMobileShell()),
      desktop: DenialShellScene(content: MyDesktopShell()),
    ),
  );
}

class MyMobileShell extends StatelessWidget {
  const MyMobileShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        ShellWallpaper(),
        Center(child: Text('My mobile shell')),
      ],
    );
  }
}

class MyDesktopShell extends StatelessWidget {
  const MyDesktopShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        ShellWallpaper(),
        Center(child: Text('My desktop shell')),
      ],
    );
  }
}
```

`runDenialShell` is the process bootstrap. `DenialShell` is the reusable
compositor-aware widget host. `DenialShellScene` is feature configuration, not
platform plumbing. The checked
[custom shell example](../dart_shell/example/custom_shell.dart) is compiled by
the normal Dart analyzer and also demonstrates the high-level window helpers.

## Scene slots

Each profile scene has three slots:

- `content` is the main feature scene;
- `chrome` is persistent shell UI, such as a gesture handle or shade, which
  participates in the secure-session transition with the content;
- `overlays` are transient feature layers such as notifications and HUDs.

Denial places all three behind its secure lock stage. It then installs managed
popup surfaces, input publication, the mobile software keyboard, desktop
screenshot selection, Flutter's root overlay, and the native cursor host in
the required order.

For Bluetooth pairing, pass `pairingSurfaceBuilder` to `DenialShell`. Omitting
it is safe: incoming pairing requests are rejected rather than accepted or
left pending without UI. `onLocked` can close feature-owned transient state;
Denial always dismisses its managed popup surfaces itself.

## Reading shell state

The framework exports stable models, semantic actions, theme extensions, and
surface components from the same library. A feature can render the focused
native window without touching Riverpod, the bridge, or protocol messages:

```dart
import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

class FocusedWindow extends StatelessWidget {
  const FocusedWindow({super.key});

  @override
  Widget build(BuildContext context) => const ShellPrimaryWindow();
}
```

Use `ShellWindowsBuilder` when a feature needs the complete user-visible window
list plus focus and close actions; it applies Denial's helper-surface filtering
automatically. Lower-level providers remain exported for features with custom
state-management needs.
`ShellSurfaceHost` and `shellSurfaceControllerProvider` provide managed popup
lifetimes and dismissal policy. `LocalFlutterApplication` registers trusted
built-in applications through the optional `localApplications` callback on
`runDenialShell`.

## Stock composition as an example

The reference assembly is intentionally small and lives in
`lib/src/features/default_shell/default_shell_app.dart`. It constructs a
`DenialShell` from stock mobile and desktop feature widgets. Those features use
the public framework import for core state and components, so the same path is
exercised by the product rather than existing only for third-party code.

An independently built replacement bundle remains trusted session code. Read
the [live UI trust boundary](UI_DEVELOPMENT.md#trust-boundary) and keep
`denialctl ui restore` available while experimenting.
