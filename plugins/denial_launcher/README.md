# App Launcher

The reference desktop's application launcher, compiled as an independently
selectable Denial plugin. It provides `ShellLauncher` from
`package:denial_flutter_sdk/launcher.dart` and depends only on public SDKs and
Flutter.

The plugin owns search, recent-app suggestions, tile presentation, scrolling,
keyboard navigation and search reset on reopening. The runtime supplies the
localized application catalog (including local Flutter applications), history,
icons, cursor roles, focus node and launch/dismiss actions. It retains native
input ownership, placement and surface transitions.

The built-in default preset and handwritten development entry point select this
plugin. Existing saved selections are preserved: select **App Launcher** and
apply the composition to include it. Disabling it removes the desktop launcher
and its edge trigger; launcher shortcuts and panel actions do nothing until a
launcher provider is selected. The mobile home grid is unchanged.

An alternative implements `ShellLauncher` and supplies `@Provides(ShellLauncher)`
in a `@Plugin()` library. The reference desktop accepts zero or one launcher;
conflicting providers fail composition. Do not depend on this package merely to
implement an alternative—depend on the SDK contract instead.

Validation uses Dart analysis, `denial-plugins plan` with the launcher selected
and without it, and a release bundle build. Visual validation belongs to the
user; planning does not launch any UI or use a debug engine.
