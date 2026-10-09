# Developing Denial plugins

Read [PLUGIN_SYSTEM.md](PLUGIN_SYSTEM.md) for the architecture and
[PLUGIN_MANAGER.md](PLUGIN_MANAGER.md) when changing the manager or distribution
workflow. Follow [AGENTS.md](../AGENTS.md) for execution and session-control rules.
This guide documents the manual workflow for developing a plugin, distributing
its source through Git, and installing it. The SDK is supplied by Denial; neither
the SDK nor your plugin needs publication to pub.dev. Ordinary third-party Dart
dependencies can still come from pub.dev.

## 1. Find Denial's development tools

Install the optional `denial-plugin-manager` package that exactly matches the
installed `denial` version. The normal `denial` package does not contain the app,
backend, or compiler kit. On Arch Linux, CachyOS, and Omarchy:

```sh
sudo pacman -S denial-plugin-manager
```

The package includes Denial's matching Flutter tools, public SDK sources,
generated protocol package, and release compiler inputs. It uses a compatible
system Dart SDK instead of shipping a private copy. The Arch package declares
`dart` as a dependency. On package formats without a suitable native Dart
package, install Dart with the system's supported package source and make sure
`dart` is available in `PATH`. Plugins shows an install warning when Dart is
missing and a compatibility warning when its version does not match Denial.

On native Linux packages the installed kit is at
`/usr/lib/denial/plugin-build-kit`; Nix and source builds locate it through
installation metadata. You do not need to clone Denial to author a plugin.
If `denial-plugins` or its installed kit is missing, update/repair that Denial
Plugin Manager package or use the source-checkout procedure below.

On NixOS, enable the separate package declaratively:

```nix
programs.denial.plugins.enable = true;
```

`denial-ui-development` is optional for live JIT development, hot reload, and
DevTools. This guide uses release compilation and Apply, so it does not require
that package or a debug/profile engine. See [UI development](UI_DEVELOPMENT.md)
for that separate workflow and the current engine-generation availability.

Prepare the kit synchronously:

```sh
denial-plugins prepare
```

This verifies the installed kit and prepares a writable copy for your user.
It does not activate a plugin or replace the running shell. Initial setup seeds
the built-in selection only if no selection has previously been initialized.
Do not run Flutter tools directly from the package-managed `/usr/lib` directory;
Flutter writes cache locks and metadata.

The examples below use Bash and `jq` to read the paths already recorded by the
manager. Run this in the terminal you will use for development:

```sh
DENIAL_PLUGIN_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/denial/plugins"
DENIAL_PLUGIN_FLUTTER="$(jq -er '.flutter' "$DENIAL_PLUGIN_STATE/configuration.json")"
DENIAL_PLUGIN_RUNTIME="$(jq -er '.runtime' "$DENIAL_PLUGIN_STATE/configuration.json")"
DENIAL_PLUGIN_FLUTTER_ROOT="$(dirname "$(dirname "$DENIAL_PLUGIN_FLUTTER")")"
DENIAL_PLUGIN_DART="$(command -v dart)"
DENIAL_PLUGIN_DART_ROOT="$(jq -er '."dart-sdk"' "$DENIAL_PLUGIN_STATE/configuration.json")"
```

These are terminal variables used by the examples, not Plugin Manager settings
or required infrastructure overrides. Alternatively, copy the `flutter` and
`runtime` values printed by `prepare` into those two variables and derive the
other paths as above. Use the matching pair from the same prepared kit.

If you work from a Denial source checkout, first run these commands from its
root, outside the sandbox:

```sh
tools/denial-pc plugin-manager
tools/denial-plugins prepare
```

Then use the same path-reading commands above. For manager commands throughout
this guide, use `tools/denial-plugins` from that checkout instead of the installed
`denial-plugins`. No plugin-project creation/setup command is required.

## 2. Create the package

Create an ordinary Dart package manually:

```sh
mkdir -p "$HOME/Projects/example_plugin/lib"
cd "$HOME/Projects/example_plugin"
```

Create `pubspec.yaml`:

```yaml
name: example_plugin
description: An example Denial action plugin.
publish_to: none
version: 0.0.0
environment:
  sdk: ^3.13.0
  flutter: 3.47.5
dependencies:
  flutter:
    sdk: flutter
  denial_sdk: '0.0.0'
  denial_flutter_sdk: '0.0.0'
```

These are the current SDK source versions and Flutter/Dart requirements, not
invented publication versions. Check both SDK `pubspec.yaml` files under
`$DENIAL_PLUGIN_RUNTIME/packages` when targeting a different Denial build.
Version `0.0.0` is source metadata, not a stable SDK compatibility guarantee.
The manager also checks the installed source, engine, and native compatibility.
Use an explicitly defined supported SDK range when API versioning is established;
do not replace constraints with `any` to hide an incompatibility.

Give your package a unique name. Declare ordinary library and plugin dependencies
in `dependencies` too. A dependency hosted in another Git repository uses Pub's
normal `git` descriptor. Development dependencies do not contribute plugins to
the installed composition.

## 3. Point the project at the installed SDK

Print the SDK source directory:

```sh
printf '%s\n' "$DENIAL_PLUGIN_RUNTIME/packages"
```

Create `pubspec_overrides.yaml` beside `pubspec.yaml`. Replace `/ABSOLUTE/RUNTIME`
with the actual value of `DENIAL_PLUGIN_RUNTIME` from step 1:

```yaml
dependency_overrides:
  denial_sdk:
    path: /ABSOLUTE/RUNTIME/packages/denial_sdk
  denial_flutter_sdk:
    path: /ABSOLUTE/RUNTIME/packages/denial_flutter_sdk
```

Use absolute paths. YAML does not expand shell variables such as
`$DENIAL_PLUGIN_RUNTIME`. The Flutter SDK's relative dependency on the generated
protocol package is already satisfied within the prepared kit.

Add these entries to `.gitignore`:

```gitignore
.dart_tool/
build/
.flutter-plugins*
pubspec_overrides.yaml
.vscode/settings.json
```

The overrides are local authoring configuration. Commit the SDK constraints in
`pubspec.yaml`, and keep the machine-specific paths out of Git. When someone
installs the plugin, Plugin Manager supplies its own installed SDK pair before
Pub resolution and separately checks the declared constraints. It does not need
your override file or a hosted copy of either Denial SDK.

Pub documents [dependency overrides and local override files](https://dart.dev/tools/pub/dependencies#dependency-overrides).
Plain Pub commands in a fresh clone need this local setup; the SDK dependencies
in the committed manifest are supplied by Denial, not downloaded from pub.dev.

## 4. Configure the editor manually

For VSCodium/VS Code with the Dart and Flutter extensions, print the tool paths:

```sh
printf '%s\n' "$DENIAL_PLUGIN_FLUTTER_ROOT" "$DENIAL_PLUGIN_DART_ROOT"
```

Create `.vscode/settings.json` in the plugin project. Replace
`/ABSOLUTE/FLUTTER` and `/ABSOLUTE/DART` with the printed paths:

```json
{
  "dart.flutterSdkPath": "/ABSOLUTE/FLUTTER",
  "dart.sdkPath": "/ABSOLUTE/DART"
}
```

For another editor, select those same Flutter and Dart SDK directories in its
language-server settings. The Dart SDK is the compatible system installation;
the Flutter path is Denial's prepared compiler kit with its generated `dart:ui`
declarations. An unrelated system Flutter installation can report missing Denial APIs.
Reload the editor's analysis server after changing SDK paths.

After upgrading Denial, run `prepare` again, read the new paths, and update your
local overrides and editor settings. Prepared kit directories are keyed by
identity; an old path does not automatically follow the installed release.

## 5. Write and check a contribution

Mark each contribution library with `@Plugin()`. Implement a public contract and
annotate the implementation with `@Provides(ContractType)`. For example, an action
contribution belongs in `lib/example_plugin.dart`:

```dart
@Plugin()
library;

import 'package:denial_sdk/composition.dart';
import 'package:denial_flutter_sdk/actions.dart';
import 'package:flutter/widgets.dart';

@Provides(ShellAction)
final class OpenPowerPreferences implements ShellAction {
  const OpenPowerPreferences();

  @override
  String get id => 'example_plugin.openPowerPreferences';
  @override
  String get provider => 'Example plugin';
  @override
  String label(BuildContext context) => 'Open power preferences';
  @override
  String description(BuildContext context) => 'Show power settings';
  @override
  void invoke(ShellActionContext context) {
    context.services.openPowerSettings();
  }
}
```

The manager analyzes annotations and resolved Dart types; it does not execute
plugin code to discover contributions. Use public, concrete, non-generic provider
classes with public unnamed constructors. Constructor parameters can request
other contracts, nullable optional providers, or ordered `List<Contract>`
collections. Missing providers, dependency cycles, and exclusive-provider
ambiguities are rejected before compilation.

For quick compatibility feedback in Plugins, add advisory metadata to the same
Pub manifest:

```yaml
denial_plugin:
  schema: 1
  name: Example plugin
  provides:
    - contract: package:denial_flutter_sdk/actions.dart#ShellAction
      count: 1
```

Use fully qualified library/type identities and keep claims consistent with the
actual contributions. This metadata does not replace Pub dependencies or typed
analysis. See [the manifest contract](PLUGIN_MANAGER.md#16-selection-preflight-and-error-presentation-2026-09-28)
for declaring required contracts and contribution counts.

From the plugin project directory, resolve dependencies, format, and analyze:

```sh
"$DENIAL_PLUGIN_FLUTTER" pub get
"$DENIAL_PLUGIN_DART" format lib
"$DENIAL_PLUGIN_DART" analyze lib
```

Use the Dart analyzer for the plugin directory. The curated release kit omits
Flutter's own `dev/` projects, which the `flutter analyze` command tries to scan.
`dart analyze lib` uses the resolved package configuration and the kit's matching
Flutter and `dart:ui` declarations.

If you add pure Dart tests, declare `test` in `dev_dependencies`, resolve again,
and run them with `"$DENIAL_PLUGIN_DART" test`. Tests that import Flutter widgets
or `dart:ui` need the separate Flutter development-engine workflow. Do not invoke
`flutter test` or prepare a debug engine for the routine release workflow.

A contribution is rendered or invoked by a compatible consumer in the selected
composition. The action example needs a shell that hosts `ShellAction` providers;
the reference desktop does so. Defining a provider does not launch a standalone
Flutter application. For a desktop surface use `ShellSurface` as described below.
Continue with [local installation and Apply](#install-a-local-plugin-and-apply-edits)
to compile the contribution into your desktop.

## Integrate functionality through contracts

Use public interfaces from `denial_sdk`, `denial_flutter_sdk`, or a plugin's API
package. Obtain native-backed operations through supplied services; do not import
private shell controllers or duplicate native resource ownership inside a plugin.
Use the shared theme/material/input APIs for shell UI, and dispose subscriptions,
controllers, and other resources through their ordinary widget or owner lifecycle.
Annotations do not arrange cleanup.

### Declare your own position and visibility

Contribute `ShellSurface` from `package:denial_flutter_sdk/surfaces.dart`. The
reference desktop accepts `List<ShellSurface>`; it has no panel slot or clock
special case. Each contribution has a unique stable `id`, a `layer`, a
`place(environment)` method, and a widget `build(context, surface: ...)` method.
For example (inside a `@Plugin()` library, with the usual SDK/Flutter imports):

```dart
@Provides(ShellSurface)
final class MyDesktopWidget implements ShellSurface {
  const MyDesktopWidget();
  String get id => 'my_plugin.desktop_widget';
  ShellSurfaceLayer get layer => ShellSurfaceLayer.desktop;

  ShellSurfacePlacement? place(ShellSurfaceEnvironment env) {
    if (!env.isMainOutput) return null;
    return ShellSurfacePlacement(
      bounds: Rect.fromLTWH(env.workArea.left + 24,
          env.workArea.top + 24, 240, 120),
      visible: !env.locked && !env.wallpaperSelectorVisible,
      occupiesDesktop: true,
    );
  }

  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      const Center(child: Text('My desktop widget'));
}
```

Add `package:denial_flutter_sdk/surfaces.dart#ShellSurface` to advisory `provides`.
Bounds are arbitrary logical rectangles in the Flutter scene, not output-local
coordinates. Use `env.output.logicalRect` for an edge-attached surface or
`env.workArea` to avoid native reserved space. `ShellSurfacePlacement.edgeBounds`
is an optional helper. The host clips each instance to its output; a plugin
can build multiple internal widgets or contribute multiple surfaces. Layer order
is `desktop` (behind windows/previews), `desktopControls` (above the overview
barrier, below application windows), then `aboveWindows`. Security and platform
session overlays always remain above these layers. Within a layer, contribution
order determines painting order; overlapping declarations are not auto-packed.

`place` receives current output geometry, work area, main/default-output selection,
active workspace, fullscreen, overview, show-desktop, wallpaper-selector, lock,
and settings facts. It must be pure. Choose your own output and hide/show policy:
fullscreen is a fact, not a command to hide. Return `null` to opt out of an output
(disposes that instance); return `visible: false` to retain it through a temporary
hide. `occupiesDesktop: true` keeps minimized desktop previews out of its visible
bounds; it does not change native maximized window geometry.

Widgets rebuild with `surface.environment`; `surface.events` broadcasts subsequent
environments asynchronously for timers and side effects. Subscribe once during
widget initialization, use the snapshot for initial state, and cancel on disposal.
The stream belongs to the surface/output instance and closes when it is removed.
Events are distinct environment snapshots: unrelated host rebuilds do not emit
updates. Output values are compared rather than native snapshot identities.
`surface.services` exposes the host's public operations.

The SDK retains temporarily hidden surface state, suppresses input, focus and
semantics immediately, then stops painting/ticking after the fade. Use
`ShellSurfacePresentation.visibleOf(context)` to dismiss owned overlays. Ordinary
surfaces receive the SDK fade. Glass surfaces declare
`fade: ShellSurfaceFade.custom` in their placement and pass
`ShellSurfacePresentation.opacityOf(context)` to `ShellBackdropBlur.opacity` with
`separateChild: true`. This fades glass and foreground separately, preserving the
backdrop. Do not add a second whole-surface fade.

### Authoring, hosting, and temporary popups

Keep plugin imports focused: `surfaces.dart` exposes the contribution contract,
placement/context models, fade presentation, and the types used in their signatures.
`ShellSurface` and `ShellWorkArea` keep their canonical contract identities in that
library, including for manifests. No host widgets are re-exported there.

Root shell authors additionally import `surface_hosting.dart`. Call
`resolveShellSurfaces` once with the selected contributions and output environments,
then feed its immutable entries to `ShellSurfacePlane` for each scene layer. The
host owns retained state, event delivery, clipping and input suppression. Plugins
do not instantiate that lifecycle themselves.

For short-lived menus/dialogs, use `popups.dart`: `ShellPopupHost`,
`shellPopupControllerProvider` and `ShellPopupHandle` manage dismissal, focus and
input lifetimes. They create temporary UI instances, not plugin contributions.
`rendering.dart` contains native-window rendering primitives; `ShellOverlayHost`
from `shell.dart` supplies Flutter's root Overlay. These APIs have separate roles.
Do not add a new host slot for each new desktop widget: contribute a `ShellSurface`.
The specialized `ShellLauncher` remains a launcher-content contract, not a generic
placement API for new UI.

### Reserve space for native windows

Widget placement and native work areas are separate. A plugin needing reserved
space also contributes `ShellWorkArea` and implements
`reserve(ShellLayoutSettings) -> ShellWorkAreaReservation?`. Declare its edge,
total reserved thickness (including any desired window gap), and output names;
return null for no reservation. Hidden edges, nonpositive/invalid thicknesses
are rejected, and output-name lists are copied into immutable storage. Empty
output names use native configured defaults.
Add `package:denial_flutter_sdk/surfaces.dart#ShellWorkArea` to advisory `provides`.

The current native protocol supports **one shared edge/thickness/output selection**,
so `ShellWorkArea` is optional and exclusive. Competing providers are a composition
error; they are never silently discarded. Multiple unreserved UI surfaces are
supported. Different simultaneous native reservations per output/edge require a
future native protocol extension. The reference desktop applies the selected
reservation through the SDK; it does not decide the surface's painted rectangle.

For window UI, subscribe to `services.windows(monitorId)` and use
`activateWindow(id)`, `buildApplicationIcon(context, appId)`, and
`buildWindowPreview(context, id)`. A preview fits live client textures into its
constraints without resizing the client or forwarding pointer input. Overlay a
title and your own activation control in the plugin. Missing textures and local
in-bundle Flutter applications use an icon fallback; do not instantiate another
copy of the application's widget tree. The reference desktop keeps current
workspace and minimized surfaces presentation-visible. Custom shells must also
publish visibility for any native surfaces they show.

For a temporary preview hover effect, call
`services.emphasizeWindow(windowId, monitorId: monitorId)`
and retain its returned release callback. The reference desktop fades other
application windows and their popups on that monitor's current workspace,
leaving the target and other monitors/workspaces at their normal opacity.
Windows pinned to all workspaces participate on their own monitor. Pass the
hosting panel's monitor, not a workspace inferred from a minimized preview.
Its window surface and shadow fade separately so glass keeps its backdrop.
Call the callback on hover exit, popup dismissal, activation and owner disposal;
it is idempotent and cannot cancel a newer owner's request. Keep any hover delay
in the plugin. Emphasis does not focus, raise or unminimize a window. The host
clears it on target closure, activation, workspace/overview changes, Show Desktop,
window switching and locking. Reduced motion and animation scaling are respected.

Window enumeration is not a creation-order guarantee. Retain session-local
ordering in the plugin when focus changes should not reorder controls. Use
`services.applications` for launchable catalog entries, and persist their opaque
`id` when pinning an application. `appId` selects its icon; `windowAppIds` contains
host-provided aliases for matching running windows. Prefer exact app IDs over
aliases and avoid guessing when multiple entries match. Launch a saved entry
with `launchApplication(id, monitorId: ...)`, checking the returned success flag.
An entry may disappear after uninstalling its app; retain enough display metadata
to let the user remove a stale pin. Keep plugin preferences and ordering in the
plugin, and never persist or execute desktop command lines yourself.

Use
`monitorBounds(monitorId)` to constrain overlays to their output rather than the
whole multi-monitor scene. Register interactive overlay bounds with
`ShellInputRegion`. The shared tray accepts an optional `foregroundColor` for
its attention indicator; application-supplied icon colors remain intact.
Subscribe to `trayItemIds` and pass an ordered `itemIds` subset to
`buildSystemTray` when splitting tray icons between inline and overflow areas.
Omitting the subset renders all items; removed IDs are ignored. Keep activation
and context menus in the shared renderer rather than duplicating native handling.

`toggleDesktop()` and `desktopVisible` expose the reference desktop's temporary
reveal mode. It suppresses application painting and input across outputs while
retaining window geometry, stacking, and minimized state. Selecting/launching an
app, switching workspace, or opening overview/window switching exits the mode.
This is presentation state, not a native minimize command; custom desktop scenes
must consume the corresponding presentation and SDK input state too.

If an existing contract cannot express the feature, define a public interface
with `@ExtensionPoint` in an appropriate API package. Choose its cardinality:
`exactlyOne`, `zeroOrOne`, or `zeroOrMore`. Consumers request the interface through
constructor injection, and implementations declare `@Provides` with that type.
The consumer still needs to render or invoke its injected contributions; defining
an interface alone does not integrate behavior into a shell.

Provider selection and constructor wiring happen at build time. The result is one
compiled Flutter shell. Do not introduce runtime plugin scanning, reflection,
dynamic Dart modules, or a registry that decides which plugins to enable.
Ordinary dispatch to already selected handlers is fine.

## Animate without per-frame GPU allocations

A partly transparent `Opacity`, `FadeTransition` or `AnimatedOpacity` usually
renders its subtree into an offscreen layer. Denial reuses that layer while it
slides or changes size slightly, but a layer that keeps growing allocates new
GPU memory at each larger size, about 36 bytes per pixel, or 18 MB for a
640×800 panel. See
[the known issue](KNOWN_ISSUES.md#growing-animated-layers-allocate-gpu-memory)
for the details.

- **Fading in place or sliding is fine.** `Transform.translate` keeps the size,
  and an opacity of exactly 0 or 1 creates no layer.
- **To fade and scale, use `ShellFadeScale`** from
  `package:denial_flutter_sdk/rendering.dart` instead of combining `Opacity` or
  `FadeTransition` with `Transform.scale`, `ScaleTransition` or `AnimatedScale`.
  It renders the content once at its own size and scales the finished image,
  so one layer serves the whole animation:

  ```dart
  AnimatedBuilder(
    animation: reveal,
    child: const MyPanelContent(),
    builder: (context, child) => ShellFadeScale(
      opacity: reveal.value,
      scale: 0.95 + 0.05 * reveal.value,
      child: child!,
    ),
  );
  ```

- **When layout changes the size, fade the paint.** For content in a resizing
  rectangle or a growing clip, multiply the alpha of its colors instead of
  wrapping it in `Opacity`:

  ```dart
  DecoratedBox(
    decoration: BoxDecoration(
      color: colors.surfaceContainer.withValues(alpha: 0.42 * t),
      border: Border.all(
        color: colors.hairline.withValues(alpha: colors.hairline.a * t),
      ),
    ),
  );
  ```

- **Keep glass out of fades and `ShellFadeScale`.** Inside such a layer,
  `ShellBackdropBlur`, other backdrop filters and window surfaces sample the
  layer instead of the scene behind it. A plain `Transform.scale` or
  translation keeps them live; fade those leaves individually.

## Access lower-level platform capabilities

The SDK is the only Denial platform API. Do not depend on `denial_dart_shell`,
import another package's `lib/src`, or copy its bridge/controllers into a plugin.
Planning rejects private SDK imports and old runtime dependencies for every
plugin, including first-party packages. Public `state.dart`, `platform.dart`,
`models.dart`, `rendering.dart`, `input.dart` and `system_services.dart` expose the
same capabilities used by the stock UI.

For example, inside an SDK-bootstrapped `ConsumerWidget`, read
`ref.watch(shellControllerProvider)` for the current window snapshot, use
`ref.read(shellControllerProvider.notifier).closeWindow(window)` for semantic
close, and obtain `ref.read(denialBridgeProvider)` for native operations such as
`configureWindow`, `moveWindowToWorkspace` and output configuration. Use the
shared bridge/provider; creating another embedded bridge would replace native
channel handlers. Import providers from `state.dart` and typed models from
`models.dart`. Configuration and system-service providers preserve their existing
subscription/disposal lifetimes.

Reading `denialBridgeProvider` connects native reply channels immediately.
Display/settings/shortcut providers do not require `shellControllerProvider`.
Window consumers can subscribe to `windowSnapshots`, `windowsChanged` and
`windowActivations`; retain and cancel subscriptions with their owner.
`bridge.start` remains available for callback compatibility.

`ShellState` carries native snapshots, focus and authoritative security state.
Root plugins own their gestures, overlays, keyboard and transition policies;
reference profile/geometry types are internal to `denial_desktop`. Window hosting
widgets accept `contentPadding` for shell-specific in-bundle application insets.
Audio/brightness/screenshot command sends return `void`; native reads and event
streams supply their responses.

Public namespaces use explicit export lists. Import `service_backends.dart` for
backend construction/injection contracts, `lifecycle.dart` for plugin-owned
notifier guards and deferred event dispatch, and `workers.dart` for reusable
background isolates. Raw native codecs and channel definitions live in
`wire.dart`; ordinary operations remain on `platform.dart`'s shared typed bridge.
Implementation reducers, protocol parsers and test helpers are not plugin APIs.

A small component should use its supplied `ShellServices` when possible. A root
plugin implements `ShellApplication` and composes the SDK primitives directly.
It is responsible for its chosen layouts, window decorations, transient UI and
lock presentation. Native authentication/resource ownership remain enforced by
the compositor. See [custom shells](CUSTOM_SHELLS.md) for input, visibility,
lock-frame and lifetime responsibilities. Bootstrap mounts no hidden default UI.

`services.dart` also exposes focused window, application, desktop, workspace,
telemetry, media, presentation and tray interfaces. Accept the smallest capability
in your feature constructors/helpers, such as `ShellWindowServices` for previews
or `ShellMediaServices` for playback controls. The supplied `ShellServices` bundle
implements all of them, so existing plugin calls remain valid.

`rendering.dart` exposes live window surfaces and the native window-plane layer;
`input.dart` exposes input regions, coordinate transforms and visibility layout.
These are low-level APIs: keep published client geometry synchronized with the
painted surfaces. `wire.dart` supplies protocol codecs when working on platform
integration; ordinary UI should prefer typed bridge/controller operations. Use a
prefix for raw wire types because they differ from application models.

SDK assets use `packages/denial_flutter_sdk/...` keys. They are included through
Pub dependencies, so plugins and standalone clients need no runtime asset copies.
New plugin-owned assets belong in that plugin's manifest and package namespace.
For low-level analysis use `tools/denial-pc plugin-check`: upstream Flutter's cached
`dart:ui` declarations do not contain Denial's native window-plane API.

## Make an action available to shortcuts

Implement `ShellAction` as in the example above. A package can contribute multiple
actions, whether or not it provides a visual surface. The reference desktop
receives the generated action list automatically; no per-plugin Rust enum, wire
message, or Settings picker entry is needed.

Use your package name as the action ID prefix and keep IDs stable across releases.
The saved mapping contains the ID, not the class name or localized label. Labels
and descriptions can use localization from `BuildContext`; the provider name
identifies the action's source in Settings. Handlers may return `Future<void>` and
can call plugin-owned controllers or public `context.services` operations. Keep
synchronous work short and handle a nullable `context.monitorId`.

IDs must match `[a-z0-9_]+\.[A-Za-z0-9_.-]+`, be at most 256 ASCII characters,
and be unique in the composition. `native.*` is reserved. Labels and provider
names must be nonempty and at most 256 UTF-8 bytes each; descriptions may be empty
and are limited to 2048 bytes. Text cannot contain control characters. Catalogs
are limited to 256 actions and 128 KiB of JSON.

After enabling and applying the plugin, choose its action under Settings →
Shortcuts → Denial actions and assign a key or supported gesture. Declaring an
action does **not** automatically assign a shortcut or overwrite a user's mapping.
A persisted target has this form:

```json
{"type":"pluginAction","id":"example_plugin.openPowerPreferences"}
```

Disabling the provider removes its action from the available catalog and stops
its saved bindings from dispatching. The bindings remain so enabling the same ID
restores them. Do not add a fallback that invokes disabled plugin functionality.

A custom shell must host its generated action list using the SDK's `shell.dart`
`ShellActionsBinding`, supplying `ShellServices` inside Denial's platform/provider
bootstrap. Mount one catalog owner; publication replaces the complete catalog.
Do not assume an alternative shell consumes a contract merely because a plugin
provides it.

The binding publishes descriptors and routes generation-tagged calls to handlers.
Shell replacement clears old registrations and queued calls. Locked sessions
cannot dispatch plugin actions, and handlers remain subject to native service
policy. Reuse this bridge when adding actions; it does not grant new native
capabilities that the underlying services do not implement.

## Let windows hold desktop pets

Desktop pets are layer surfaces that use the `denial-pet-v1` protocol: the
user can drop one on a window's edge or corner, and the window carries it.
[The protocol](protocol/pet-v1.md) keeps every window's geometry from the
pet's client, but for roughly where a pet lands, which the speed it is
dragged at tells it from version 3. The shell decides which window holds a dragged pet, and a
plugin supplies that rule through the optional, exclusive `ShellPetHolds`
contract (`package:denial_flutter_sdk/pets.dart`).

```dart
@Provides(ShellPetHolds)
final class BottomEdgesOnly implements ShellPetHolds {
  const BottomEdgesOnly();

  @override
  DenialPetHold? holdFor(PetDrag drag) {
    if (!(drag.pet.pet?.accepts(DenialWindowHold.bottom) ?? false)) {
      return null;
    }
    for (final (index, target) in drag.targets.indexed) {
      final frame = target.frame;
      if (!target.holdsPets || frame == null) continue;
      final near = (drag.anchor.dy - frame.bottom).abs() < 24 &&
          drag.anchor.dx >= frame.left &&
          drag.anchor.dx <= frame.right;
      final point = Offset(drag.anchor.dx, frame.bottom);
      if (near && !drag.coveredBefore(index, point) && drag.onScreen(point)) {
        return DenialPetHold(
          windowId: target.window!,
          hold: DenialWindowHold.bottom,
          share: (drag.anchor.dx - frame.left) / frame.width,
        );
      }
    }
    return null;
  }
}
```

- While the user drags a pet, the desktop calls `holdFor` whenever the pet or
  the scene changes.
- `PetDrag.targets` lists what the user sees, front to back.
- Return null to leave the pet free.
- Denial drops a hold the pet does not accept, or one on a window that is
  fullscreen or maximized. It applies the last hold when the user lets go.

What a held pet casts on its window, such as a shadow, comes from the
optional, exclusive `ShellPetShadows` contract. The reference desktop asks it
for each pet stacked above its window, and draws the answer over the pet's
rectangle, under every pet the window holds, clipped to the window's visible
frame. `PetShadow.surface` is the pet's surface as drawn, to shape the
shadow from its pixels; nothing reaches the pet's client.

```dart
@Provides(ShellPetShadows)
final class SoftShadows implements ShellPetShadows {
  const SoftShadows();

  @override
  Widget? shadowFor(PetShadow shadow) => Transform.translate(
    offset: const Offset(0, 3),
    child: ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: ColorFiltered(
        colorFilter: const ColorFilter.mode(Color(0x40000000), BlendMode.srcIn),
        child: shadow.surface,
      ),
    ),
  );
}
```

The built-in `denial_pets` plugin provides the default rule and a contact
shadow. Deselect it before selecting another provider of either. The
reference desktop draws held pets with their windows and reports their
on-screen velocity to the pet. A custom shell that hosts pets does that
itself, through `DenialBridge.holdPet` and `DenialBridge.carryPet`.

## Install a local plugin and apply edits

Inspect the existing selection first, then add your project by absolute path:

```sh
denial-plugins status
denial-plugins --local add "$HOME/Projects/example_plugin"
```

`add` selects the package. Preserve unrelated choices; do not reset to defaults
as a setup step. In the GUI, choose Plugins → Add plugin, expand Local development,
enable Use a local development checkout, enter the directory, and click Find
plugins. Choose the package, click Add plugin, then Apply. A surface/action needs
a compatible selected consumer; leave the reference desktop enabled when using
the example above.

To compile without activating, then explicitly apply the result:

```sh
denial-plugins plan
# Replace CANDIDATE_ID with the id returned by plan.
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

Wait for each command to succeed before running the next. Planning snapshots your
local source and uses the installed SDK pair, resolves dependencies through Pub,
checks constraints and typed contributions, and generates the composition.
Build compiles a new release bundle. Activate requests native-controlled shell
replacement. A changed selection invalidates an older plan.

For the combined operation, use Apply in Plugins or submit a background job:

```sh
denial-plugins submit apply
denial-plugins status
```

`submit` returns a job ID before completion. Inspect `status` until that job
succeeds or fails; `denial-plugins job-details JOB_ID` returns its diagnostic/log.
Do not submit a dependent operation while the previous job is running.

Edit your original project and repeat plan/build/activate or Apply. Local source
edits are captured on each plan; ordinary planning preserves resolved Git and Pub
pins. This is an AOT rebuild of the selected shell composition, not plugin hot
reload. Build failures leave the active bundle running. Native startup checks and
packaged-shell recovery protect activation; they do not prove plugin correctness.

Plugin-only changes use live shell refresh without rebuilding or restarting Rust.
A change needing a new native capability can require an initial native update;
an older compositor may report that logout/login is needed. Follow `AGENTS.md`
for that session transition. Never overwrite a library mapped by a live process.

### Changes inside the Denial checkout

Run `tools/denial-pc` and `tools/denial-plugins` outside the sandbox. When editing
Denial's SDK, runtime, or bundled plugins, prepare matching build inputs first:

```sh
tools/denial-pc plugin-manager
tools/denial-plugins plan
# Replace CANDIDATE_ID with the id returned by plan.
tools/denial-plugins build CANDIDATE_ID
tools/denial-plugins activate CANDIDATE_ID
```

Read the prepared tool paths again and refresh your local authoring paths after
the kit changes. Editing `dart_shell/lib/main.dart` alone cannot change the
generated entry point of an active Plugin Manager composition.
`tools/denial-pc refresh` reloads its existing bundle; it does not compile checkout
edits into it. Edit canonical source, never generated workspaces, kit snapshots,
or sealed candidates.

### Build-input provenance

`denial-pc plugin-manager` selects explicit **development** provenance when
using the canonical local Flutter/Skia trees. The kit records their actual HEADs
and SHA-256 hashes of tracked/untracked dirty inputs, Denial's source state,
release GN arguments, engine ELF architecture/build ID/checksum, generated
`dart:ui` declarations, Dart frontend and exact release compiler input hashes.
Flutter's real framework revision is preserved; the unchanged source lock is
retained only as CI/release reference metadata, not development source authority.
The generated runtime checksum describes the copied development engine; no
committed checksum or source metadata is rewritten.

For a separately requested kit-only operation with an already prepared native
release graph, run (x86-64 example):

```sh
tools/prepare-denial-plugin-kit --provenance development \
  --flutter-root /mnt/exty/denial-flutter-fork-3.44.7 \
  --engine-root "${XDG_CACHE_HOME:-$HOME/.cache}/denial/flutter-engine/build" \
  --engine-target denial_host_release --platform linux-x64 \
  --output /ABSOLUTE/NEW-KIT-DIRECTORY
```

This command never rebuilds prerequisites. It rejects a stale/noncanonical
graph, wrong architecture/mode, inconsistent local checksum or metadata, and
source/compiler movement while copying. Relocated Flutter and Skia roots must
both be declared with the existing source-root environment variables. A stale
graph requires a scoped prerequisite decision, not a full distribution build.

Composition compilation verifies this explicit identity and compiler inventory,
including the exact Dart frontend, instead of claiming a dirty fork matches the
lock. The source identity is preserved in the sealed candidate and remains
subject to native installed-source, engine-hash and startup-health gates. These
hashes identify inputs; they are not signatures or proof that plugins are safe.

The default `--provenance locked-release` path keeps the existing source-lock
and committed release-engine checks, including the Nix packager's explicit
locked Flutter attestation. Development mode forbids those packager attestations
and CI use. Existing schema-1 release kits remain supported unchanged.

## Distribute a plugin through Git

1. Commit `pubspec.yaml`, your contribution libraries under `lib/`, assets, and
   documentation. Keep local SDK overrides and editor paths ignored.
2. Declare the SDK constraints in `pubspec.yaml`; do not replace them with your
   filesystem paths. Declare other plugin dependencies with their actual Pub
   source descriptors, including Git URLs/refs/paths where needed.
3. Push the source to a Git repository and share its URL. A root-level plugin
   needs only that URL; a plugin in a monorepo also needs its package path. You
   can provide a Git tag/commit for a specific revision. No pub.dev account or
   SDK/plugin publication step is required.

Each independently selectable plugin is a separate Dart package. Do not commit
an SDK copy inside your plugin. The user supplies their installation's SDK and
toolchain through Plugin Manager. A fresh clone used for authoring repeats steps
1–4 of this guide before resolving dependencies or opening the editor.

## Install a Git-distributed plugin

The default collection is
[`denialwm/denial-plugins`](https://github.com/denialwm/denial-plugins).
Plugins lists its catalog automatically. To work on one of its plugins, clone
the repository, enter `plugins/PACKAGE_NAME`, and follow this guide's manual SDK
and editor setup in that package directory. The collection root is not a Pub
project; each plugin keeps its own manifest and local overrides.

In Plugins, choose Add plugin, enter the Git URL, and click Find plugins. Choose
the package and click Add plugin, then review the composition and press Apply.
Use Advanced options in the add dialog if you want a particular branch, tag, or
commit. Users do not configure SDK overrides or editor paths to install a plugin.

The CLI equivalent for a package at the repository root is:

```sh
denial-plugins status
denial-plugins add https://example.org/example_plugin.git
denial-plugins submit apply
```

For a package under `packages/example_plugin`, optionally at a chosen Git ref:

```sh
denial-plugins --path packages/example_plugin --ref PLUGIN_REF add https://example.org/plugins.git
denial-plugins submit apply
```

The published taskbar is a concrete collection example:

```sh
denial-plugins --path plugins/denial_taskbar add https://github.com/denialwm/denial-plugins.git
```

Before applying, disable the top bar or explicitly choose one `ShellWorkArea`
provider: both bars reserve native window space through that exclusive contract.
Preserve the reference desktop and other unrelated selections.

Wait for the Apply job to finish and inspect its status as above. Plugin Manager
supplies the installed SDK pair before Pub resolution, validates the package
constraints and providers, and compiles/activates the full selection. Required
plugin dependencies follow their Pub declarations. The catalog is optional for
direct Git installation.

Ordinary Apply retains exact Git commits and resolved dependencies. Deliberately
advance them with:

```sh
denial-plugins submit update
```

To remove the example from the composition:

```sh
denial-plugins remove example_plugin
denial-plugins submit apply
```

Resolve any dependent-plugin requirements before applying removal. A user can
request the previous working composition with `denial-plugins submit revert`, or
the packaged recovery shell with `denial-plugins submit restore`.

## Validate changes

Use the pinned Dart/Flutter toolchain. Format and analyze changed packages, run
relevant pure Dart tests, and compile the generated release composition. Test
provider absence, conflicting providers, dependency injection, and stable action
IDs when those behaviors change. Use `tools/denial-pc plugin-check` for the broader
SDK/plugin checks and `tools/denial-pc compositor-test` for native changes.

Do not invoke `flutter test` directly for `dart_shell` or build a debug engine for
routine plugin validation. Flutter development-engine tests require the explicit
request and wrapper described in `AGENTS.md`.

After an authorized activation, inspect `denialctl --json ui status`: the expected
bundle should be active with `plugin_healthy: true`. Check the candidate manifest
and `/proc/PID/maps` to confirm the process maps that candidate's `libapp.so`.
Run PID and mapping checks outside the sandbox. A shell-only refresh should keep
the compositor PID unchanged.

The user performs visual validation. Do not launch applications, press shortcuts,
invoke example actions, send notifications, or capture screenshots for testing
without the specific authorization required by `AGENTS.md`. Distinguish successful
build/process checks from user-confirmed interaction behavior.
