# Live Flutter UI development

Denial's reference desktop is a Flutter program, not a fixed compositor
decoration layer. Live UI development is intended to let a user open that
program in VSCodium, change any Dart-owned desktop behavior, save, and see the
running shell update without ending the Wayland session.

The boundary is architectural rather than artificial: Dart can change
anything implemented by the shell or exposed through Denial's native
protocols. A feature which needs new Wayland, DRM, input, or privileged native
behavior still needs a Rust and protocol change.

## Runtime model

The compositor owns the selected shell runtime and its recovery state. The
Flutter Settings application is a client of that state; it is not the only
way to recover the session.

Denial distinguishes three runtime modes:

- **Official optimized** — the packaged AOT shell and the normal default.
- **Custom optimized** — an AOT bundle built from the selected workspace.
- **Live development** — a JIT bundle with debug checks and an authenticated
  loopback Dart VM service.

Changing between AOT and JIT is a full Flutter-engine replacement. Wayland
clients, native compositor state, KMS ownership, and the graphical session
remain alive while the old Flutter runtime shuts down and the new one starts.
If a custom or JIT runtime cannot be prepared or started, the launcher tries
the packaged AOT bundle instead.

The native engine library itself is a process-lifetime component. Dart source,
kernel, and asset changes can be rebuilt and reloaded without ending the
session, but installing or rebuilding a different `libflutter_engine.so`
requires one Denial session restart. Denial fingerprints the first JIT engine
loaded by a session and refuses to activate different native engine bytes in
that process instead of silently reusing a resident library.

The native controller starts every login with the official optimized UI.
Persisting a custom runtime across login should wait for crash-loop detection
and a pre-UI recovery mechanism.

## Current implementation

The initial vertical slice contains:

- a Developer destination in Denial Settings;
- source-workspace validation for `pubspec.yaml` and `lib/main.dart`;
- a bounded, versioned binary platform protocol for commands, runtime state,
  progress, errors, and source diagnostics;
- native persistence of the selected workspace and future auto-reload
  preference in `~/.config/denial/ui-development.json`;
- AOT and JIT project modes in the raw Flutter embedder;
- loopback-only VM-service startup with Dart service authentication codes
  retained and mDNS publication disabled;
- VM-service discovery from the embedder log and publication through both the
  Settings state channel and
  `$XDG_RUNTIME_DIR/denial/flutter-vm-service.json`;
- an in-process full Flutter-engine replacement for runtime-mode changes;
- packaged-AOT fallback if JIT preparation or startup fails;
- the native `denial-ui` client for inspecting, preparing, and attaching to
  the live workspace;
- `denialctl` as a shell-independent status and packaged-UI recovery path;
- and a VSCodium launch profile which waits for Denial's VM-service file, attaches
  through Flutter's own debug adapter, and requests hot reload for changed
  files when they are saved.

The protocol exposes unavailable actions as disabled. It does not pretend that
the following work is complete:

- a Denial-owned VM-service client for the Settings **Hot reload** button;
- native file watching for the **Reload when files change** switch;
- background optimized builds, validation, activation, and last-working
  rollback;
- a versioned shell-bundle manifest and native capability negotiation.

Until the VM-service client is added, VSCodium or `flutter attach` owns Dart
compilation, DevFS synchronization, hot reload, and source error reporting.
This is useful rather than throwaway work: those are the same Flutter
semantics the final Denial tooling bridge must drive. A successful hot reload
preserves application state, replaces the changed Dart code, reassembles the
complete existing Flutter element tree, and schedules the refreshed frame.
The packaged editor connection deliberately does not expose debugger pause,
breakpoint, stepping, or expression-evaluation control: suspending the shell
isolate would suspend the complete interactive desktop. Flutter Inspector and
other non-pausing DevTools remain available.

## Development package

Live development is intentionally optional. The normal `denial` package keeps
shipping only the optimized runtime; the version-coupled
`denial-ui-development` package owns the patched JIT engine, pinned Flutter
and Dart toolchain, native development client, metadata, and licenses.

Install it from the Denial repository:

```sh
sudo pacman -S denial-ui-development
```

This is a self-contained, Denial-scoped toolchain rather than a dependency on
an arbitrary system Flutter installation. Flutter, Dart, the engine ABI, and
Denial's engine extensions remain one tested generation. The package retains
the Dart executables, compiler and service snapshots, standard-library
sources, Flutter framework and tool sources, engine artifacts, dependency
metadata, and license material exercised by Denial's assembly, editor, and
attach workflows. It also contains the locked source bodies required to
compile Denial's own Flutter shell offline. The editor profile points Dart
Code at this scoped SDK. Its pinned AOT and JIT analysis-server snapshots
and Flutter's generated `sky_engine` source map provide normal Dart and
`dart:ui` diagnostics and navigation through both Dart's CLI and Dart Code's
SDK discovery contract. The package does not ship browser DevTools, GTK runner
artifacts, SDK test trees, or unused Pub source trees.

The immutable installation does not rely on the builder's home directory or a
user's existing Pub cache. Its executable interface is native Rust; the
package does not install a Denial-owned Bash wrapper. `denial-flutter` is an
editor-compatible entry point to the same compiled binary.

The Flutter command-line tool in that SDK is a deterministic AOT image run by
the pinned `dartaotruntime`. This only optimizes and stabilizes the tooling
that prepares and attaches to the shell; the live Denial UI still uses its
separate debug JIT engine and retains hot reload.

None of it is installed for users who keep the normal optimized Denial
runtime.

The current validated package sizes are reported by
`cargo xtask ui-development-package`; both the compressed archive and
installed development runtime are enforced by explicit size budgets.

## One-command setup

After installing the optional package, create and start an editable copy of
Denial's UI with:

```sh
denialctl ui setup
```

The command clones the branch or release recorded by the installed package
from `https://github.com/denialwm/denial.git` into `~/DenialUI`, verifies its
exact commit, overlays the matching packaged UI source, prepares its JIT bundle
offline with the pinned toolchain, selects `~/DenialUI/dart_shell` in the
native controller, and enters live development. The checkout starts on `main`
with the official repository as `origin`; normal Git commands can change
either. It never overwrites an existing checkout or user edits.
Choose another destination when desired:

```sh
denialctl ui setup /absolute/path/to/DenialUI
```

Open the created `dart_shell` directory—not the repository root—in VSCodium
and start **Attach to Denial live UI**. The included editor profile connects
to the authenticated VM service and requests hot reload when a changed Dart
file is saved. Keeping the editor workspace scoped to the Flutter shell makes
the live-edit boundary explicit: Rust compositor changes still require a
normal build and session restart.

The same automatic setup is available from **Settings → Developer → Create
and start editable UI**. The command-line path remains available from a
terminal or VT even when edited Flutter code cannot render Settings.

To build the optional package from a prepared Denial checkout:

```sh
cargo xtask ui-development-package
sudo pacman -U \
  "$XDG_CACHE_HOME/denial/pc-build/packages/denial-ui-development-"*.pkg.tar.zst
```

The Rust `xtask` creates the builder-neutral AOT Flutter tool, stages the
curated SDK runtime, locked dependency source cache, source revision metadata,
and UI source snapshot; builds the native client; creates the Pacman archive;
and validates its metadata, checksums, permissions, licenses, size budget, and
absence of builder-home paths. Its isolated smoke test clones the recorded
revision from a local repository, overlays the packaged UI source, and
prepares the real Denial JIT bundle with networking disabled.

For a manually managed source tree, inspect and prepare the JIT assets
explicitly:

```sh
denial-ui doctor
denial-ui prepare /absolute/path/to/denial/dart_shell
```

The repository also exposes these as **Denial UI: Inspect live development**
and **Denial UI: Prepare live bundle** in VSCodium's **Run Task** menu. The
prepare task is explicit; attaching to a running shell never starts a build
implicitly.

In **Settings → Developer**, select the same source workspace and enable live
UI development. Denial verifies that the debug bundle was prepared from that
workspace, replaces the AOT shell with the JIT shell, and displays the
authenticated VM-service URI when it is ready. Return to the official
optimized shell before selecting a different workspace; Denial enforces this
so an attached editor and the running JIT bundle cannot silently refer to
different source trees.

`denial-ui prepare` resolves the packaged lockfile offline. If a customization
adds a new Pub dependency, fetch it deliberately through the pinned tool first,
then prepare again:

```sh
cd /absolute/path/to/DenialUI/dart_shell
denial-ui flutter pub get
denial-ui prepare
```

To use the Flutter CLI:

```sh
denial-ui attach /absolute/path/to/denial-ui
```

For the built-in Denial shell, open the repository's `dart_shell` directory
in VSCodium, select **Attach to Denial live UI** in **Run and Debug**, and
start the attachment. The checked-in launch profile waits for Denial's
VM-service file and uses the package-pinned Flutter entry point. It is a
non-pausing development session, not a Dart debugger: the supported profile
cannot suspend the desktop isolate with breakpoints, stepping, pause, or
expression evaluation. The workspace setting requests hot reload for every
save which actually changed a Dart file.

Normal Flutter development semantics still apply: most widget and Dart logic
changes hot reload in place, while initialization or native-plugin changes may
need VSCodium's **Hot Restart** command or a newly prepared bundle. Neither
operation restarts the Wayland session.

After upgrading `denial-ui-development` or intentionally rebuilding its
native JIT engine, restart the Denial session once before enabling live
development. Re-running `denial-ui prepare` for ordinary Dart and asset edits
does not require a session restart.

At any point, including when edited Flutter code no longer presents a usable
Settings application, restore the packaged shell from a terminal or VT:

```sh
denialctl ui restore
```

For another Flutter workspace, use `denial-ui attach` in an integrated
terminal or copy the same `vmServiceInfoFile` attach configuration into that
workspace.

The VM service binds to `127.0.0.1`, retains its unpredictable authentication
path, and is not advertised through mDNS. The runtime service-info file is
created with mode `0600` below the per-user runtime directory, uses Flutter's
standard JSON shape, and is removed when the live runtime ends.

## Trust boundary

A custom Flutter shell is trusted session code. It can observe compositor
state and invoke every native action granted by the Denial shell protocol.
Debug mode also exposes a powerful Dart VM service to the local user. Neither
is a sandbox for untrusted code.

The packaged UI remains the recovery root. `denialctl ui restore` is the
native escape path and does not depend on the custom Flutter UI rendering
successfully. Future custom-bundle activation must still add compatibility
validation, a last-working bundle, startup health confirmation, and bounded
crash-loop recovery.
