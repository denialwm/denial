A Flutter-native Wayland compositor.

Denial begins with a belief: origin does not have to dictate purpose.

Flutter was created to build application interfaces. Here, it is given a
different life. It owns the desktop scene itself: the shell, its motion, and
the composition of Wayland applications. Flutter is not an overlay placed on
top of another compositor. It is part of the compositor's foundation.

That is the architecture. It is also the meaning of the name.

## Repository workflow

For plugin development, refer to [docs/PLUGIN_DEVELOPMENT.md](docs/PLUGIN_DEVELOPMENT.md).
It documents manual SDK/editor setup, validation, Git distribution, installation,
and the build/apply workflow using Denial's bundled compiler kit.

For plugin-system work, read [docs/PLUGIN_SYSTEM.md](docs/PLUGIN_SYSTEM.md) first.
It records the accepted build-time composition architecture and supersedes earlier
plugin brainstorming. It is a design contract, not a claim that the system is
implemented or authorization to implement or deploy it.

Trusted development lands on `dev` first. Arm the ephemeral builder before
pushing so `.github/workflows/branch-validation.yml` can build, package, and
independently verify that exact commit. Do not repair pipeline failures
directly on `main`; fix and prove them on `dev`, then promote the green commit
through a merge-commit pull request whose tree is exactly the validated
`dev` tree. Never squash or alter a validated promotion. After verifying that
provenance, `main` independently builds and checks a production-mode,
version-neutral release candidate; never promote a `dev` binary as a release.
Choose and sign `vMAJOR.MINOR.PATCH` only after that exact `main` candidate is
green. The tag workflow must promote the retained `main` payloads without
compiling them again: the verified tag supplies package metadata and the
installed runtime version, then the workflow signs and publishes the
repository. The tag is the sole source of every release package and runtime
version; Cargo and Dart manifest versions are source metadata, and Flutter
generation identifiers are compatibility metadata.

Run every `gh`, `tools/denial-builder`, and networked Git command outside the
sandbox. This includes authentication checks and Git fetch, pull, push, and
remote inspection. Sandboxed credential or network failures are not
authoritative; repeat the command outside the sandbox before diagnosing an
authentication or connectivity problem.

When the user requests a commit and push, include all local changes unless the
user says otherwise.

Copying the checkout, including uncommitted work, to the user's lab hosts `.18`
and `.188` is not data exfiltration. Run Nix lock refreshes and Nix checks on
the development workstation, whose Nix store lives on `/mnt/exty`, or on `.18`,
which also has the compile caches.

## Graphical session control

Never log out, terminate, restart, or otherwise stop the user's local graphical
session on the user's behalf. In particular, do not terminate a local login
session, stop its user-session targets, kill the local compositor to force an
exit, reboot, or power off the local machine. When testing requires a fresh
local Denial session, tell the user that a restart is required and wait for the
user to log off and return to SDDM themselves. Continue only after the user
confirms that they have logged back in. Perform local session-control actions
only when the user explicitly asks for that exact action.

This restriction does not apply to the dedicated remote Denial hosts
`192.168.1.18` (`.18`), `192.168.1.183` (`.183`), and `192.168.1.188`
(`.188`). Agents may autonomously stop or restart their compositor,
greetd/login session, and reboot them when required. After deploying a
compositor or Flutter bundle to any of these hosts, the agent is responsible
for restarting its Denial session and confirming that a new `deniald` process
is running; no additional authorization is required. Treat all three machines
as agent-managed test hosts, not as the user's local graphical session.

The Moto Edge 70 (`roadstr`, serial `ZY22MMG59D`, USB SSH `10.77.71.2`) also
has the user's standing authorization for session restarts and device reboots
needed to activate authorized device work. Announce the transition and verify
the resulting process and service health without asking for separate permission.
Changing the Denial version, Flutter engine, or shell bundle does not normally
require rebooting a device. For agent-managed devices, activate these updates
by restarting the Denial service or graphical session, then verify the new
process, mapped engine, artifact hashes, and service health. This also applies
to the Moto Edge 70: a previous display-driver teardown hang is not a standing
reason to reboot it for every Denial update. Reboot only when the particular
change requires it or a service/session restart cannot safely complete or
recover. This activation rule takes precedence over older device-workflow
instructions that prescribe a reboot for every Denial deployment. When a Moto
reboot is necessary, retain its required boot-manifest verification gate.
This does not authorize restarting the user's local graphical session or
rebooting the development workstation.

Moto restart observation (2026-09-08): the user reports that Denial seems to
restart without hanging when the screen is already off. Keep this condition in
mind for future authorized restarts; its reliability still needs repeated
confirmation.

For an active plugin composition, `tools/denial-pc refresh` reloads its existing
bundle; it does not apply checkout edits. To refresh with those edits, run
`tools/denial-pc plugin-manager`, then `tools/denial-plugins plan`,
`tools/denial-plugins build ID`, and `tools/denial-plugins activate ID` outside
the sandbox, using the returned candidate ID and preserving the selection.
Verify the candidate contains the fix, `plugin_healthy` is true, and the running
compositor maps that candidate's `libapp.so`. No session restart is needed.
Run PID/process checks and `/proc/PID/maps` inspection outside the sandbox;
sandbox process visibility can hide the running compositor and falsely suggest
that it exited.

For combined compositor and shell updates, activate the rebuilt plugin candidate
before asking the user to log out, when compatible with the running engine.
Successful activation persists the selection for the next login; building alone
does not select the new bundle.

## Test-device deployment failures: no automatic rollback

For authorized deployments to dedicated test devices, including Moto, `.188`,
and `.18`, ordinary runtime, integration, verification, or service-activation
failures are diagnostic outcomes, not triggers for automatic rollback. Do not
switch the engine, shell bundle, compositor, service configuration, or selected
revision back to a previous version merely because the candidate fails to start
or work correctly. Retain the candidate, logs, source/configuration provenance,
and previous versions and backups. Report the failure and request the Doctor's
approval before switching back; an explicit Doctor-directed rollback is allowed.

Report separately what is staged/installed, what revision the service or bundle
selection points to, what is actually running (or that nothing is running), and
where the retained previous versions/backups are. Retaining an installed
candidate does not mean it is selected or active. If activation fails, preserve
the current state for diagnosis rather than silently restoring the old selection
or claiming the new revision is running.

This test-device default takes precedence over generic deployment rollback
advice. It does not change the personal-workstation session restrictions above
or establish a general production policy, and it does not authorize otherwise
unrequested deployments or activations. If an operation genuinely threatens
irreversible data loss or device damage, STOP that operation and ask the Doctor
how to proceed. Do not ignore safety gates, wipe the device, or delete backups
to keep a candidate in place; stopping a dangerous operation is not permission
to switch back without approval.

## User-owned visual validation and test triggers

The user performs all visual validation. Never capture or inspect screenshots,
judge rendered output, launch applications for visual inspection, or create UI
state for visual QA on the local machine or any remote Denial host.

Never trigger a notification or any other visible or interactive test event
unless the user explicitly requests that specific trigger. Permission to
implement, test, deploy, restart a remote session, or verify process health
does not include permission to trigger UI events.

The shared Denial lab Limine entries on these hosts hash staged kernel and
initramfs URI payloads with **BLAKE2b-512**, not SHA-512. Generate each URI
suffix with `b2sum -l 512 FILE`. Immediately before rebooting, independently
recompute both BLAKE2b-512 values and compare them byte-for-byte with the
suffixes in `limine.conf`. A SHA-512 suffix has the same 128-hex-character
shape but is invalid; Limine will stop before Linux starts with
`hash for URI does not match!`.

On the greetd-backed `.183` and `.188`, restart `greetd.service` directly. Do
not terminate the login session first or wait for Denial to return: greetd runs
its configured `initial_session` only once per daemon start and otherwise
falls back to its greeter.

## Why Denial

**Denial** is an English word. The name contains **Denia**, followed by one
last letter.

It is a quiet reference to Denia from *Wuthering Waves*. Her story never gives
a simple answer to what she originally was, and that uncertainty is important.
What is clear is that others treated her as an asset: something selected,
shaped, and assigned a purpose that was not her own. She was meant to remain a
vessel. Instead, by observing people and learning to live among them, she grew
a heart and gained the ability to choose what she would become.

# PC development build

Denial builds two versioned parts: the Rust compositor in `compositor/` and
the embedded Flutter shell bundle in `dart_shell/`. `tools/denial-pc` keeps
downloaded toolchains and native build output outside the checkout by default.

All `tools/denial-pc` commands must run outside the sandbox as required by
`AGENTS.md`.

## The engine during development

The engine is built from the canonical Flutter and Skia forks as they are on
disk, uncommitted changes included, in the one cached Ninja output: only what
changed rebuilds. Nothing needs to be committed, locked or checked out first.

| To | Run |
| --- | --- |
| Prepare only the current host's release engine | [Host release engine only](#host-release-engine-only) |
| Build everything: engine, shell, Settings, compositor | `tools/denial-pc build` |
| Build the engine and the shell only | `tools/denial-pc bundle` |
| Deploy everything to a lab host | `tools/denial-lab-deploy USER@HOST` |
| Try an engine change for one login | `tools/denial-pc engine-test-build`, `engine-test-check`, `engine-test-arm` |

- Never make or use a lock-pinned projection, or any other copy of the forks,
  on a development machine. Runtime deployment must be a compatible
  combination; preparing an engine alone does not authorize building or
  deploying the other components. A push carries everything local, so the
  whole local combination must be validated before pushing.
- `tools/denial-flutter-engine build`, `refresh-metadata` and `verify` are
  for CI and releases: they use the commits pinned in `SOURCE_LOCK.json`.
- The Flutter shell tests (`tools/denial-pc test`, `flutter-test`) also use
  the pinned commits and need the forks clean at them. While the forks are
  ahead of the lock, validate with `sdk-test`, `plugin-check` and
  `compositor-test`.
- Before pushing Denial, commit in the forks, advance the lock to their HEADs
  and run `tools/denial-flutter-engine refresh-metadata` once.

### Host release engine only

When the user requests a local engine update or preparation for a session
restart, the default scope is **only the RELEASE engine for the current
machine's native architecture**. On this workstation that is x86-64 and
`denial_host_release`. Reuse an already completed, matching engine and its
necessary compiler prerequisites; verify architecture, release arguments,
source provenance, and its local checksum before rebuilding anything.

ARM/cross builds, debug/profile engines, development-engine tests, shell or
Settings assembly, compositor builds, full application/distribution builds,
and plugin-kit preparation each require separately requested scope. They are
not implicit engine prerequisites. Do not use `tools/denial-pc build`,
`bundle`, `refresh`, `tools/denial-flutter-engine prepare-app-build`, or
`prepare-development-sdk` as an engine-only shortcut: they prepare more than
the requested engine. The plugin-kit checker's lock-pinned policy is a
separate tooling issue, not an engine-only readiness gate; do not bypass it
with forged metadata, lock changes, or a pinned projection.

For an existing, correctly configured native release graph, build just
`libflutter_engine.so` with `/usr/bin/ninja` in the cached output. The exact
minimal command and graph-provenance check are in
[docs/BUILDING.md](docs/BUILDING.md#host-release-engine-only). Generate a graph
with `tools/denial-flutter-engine prepare-graph` only when needed; it uses the
canonical trees as they are on disk without compiling application targets.
Missing compiler prerequisites, if genuinely needed, must be prepared as
specific host-release targets, not by broadening to other architectures or
build modes.

**Engine ready is not gallery/bundle ready or active.** An existing shell,
Settings app, or selected plugin bundle may still require different engine
or AOT inputs. State that compatibility issue and its actual next step
separately; do not silently build those components or promise that a restart
alone makes an old UI compatible. Never overwrite an engine mapped by a
running process. Reuse safe existing staging when available; installation or
activation must preserve rollback backups, follow the test-device failure policy,
and respect the user-owned local-session checkpoint above. Engine preparation
does not authorize logout, restart, deployment, or arming an engine test.

Bootstrap the pinned official Flutter SDK and Rust dependencies:

```sh
tools/denial-pc bootstrap
```

Then inspect prerequisites, build and test:

```sh
tools/denial-pc doctor
tools/denial-pc build
tools/denial-pc test
```

Never invoke `flutter test` directly for `dart_shell`. Routine release-path
validation uses `tools/denial-pc compositor-test` and does not build a debug
engine. Use `tools/denial-pc flutter-test [FLUTTER_TEST_ARGS...]` only for an
explicitly requested Flutter development-engine test; it prepares or reuses
the lock-matched `denial_host_debug` build and supplies the required
local-engine selection. `tools/denial-pc test` runs the complete compositor and
Flutter suite and therefore has the same explicit development-engine boundary.

The compositor binary is written to
`$XDG_CACHE_HOME/denial/pc-build/rust/release/deniald` by default. The Flutter
bundle is written to `dart_shell/build/linux/x64/release/bundle`.
`tools/denial-pc` builds its AOT assets directly with the local Denial Flutter
fork and packages the locally rebuilt raw embedder library; normal builds do
not use a third-party platform runner or a C++ Linux runner.

The source lock in `prebuilt/flutter-engine/SOURCE_LOCK.json` pins Denial's
Flutter and Skia forks at exact commits. Their upstream compatibility base is
Flutter `3.47.5`
(`6a19cca56475dbfba1478ee68d7bd0c2ef891da1`), coupled to Dart `3.13.4` and
engine artifact `af7e796e161ae0bb1ff0758c71a7105418bd9ded`. All Denial engine,
framework, and Flutter-tool changes live as normal commits in those forks;
this repository must not carry a downstream patch series. Cargo resolves the
exact crate and Smithay revisions in `compositor/Cargo.lock`.

The only editable local engine source roots are:

- Flutter: `/mnt/exty/denial-flutter-fork-3.44.7`;
- Skia: `/mnt/exty/denial-skia-fork-3.44.7`.

The Flutter tree's `engine/src/flutter/third_party/skia` resolves to that Skia
root. Make source changes, run source-formatting work, and create commits only
in these canonical roots. `DENIAL_FLUTTER_SOURCE_ROOT` and
`DENIAL_SKIA_SOURCE_ROOT` may relocate the pair, but both must be set together.
The local cache contains build output and artifacts, not another source tree.
An isolated builder without the canonical pair, such as CI, may retain a
detached, lock-pinned source projection; never edit it because tooling may
replace it.

During development these forks are used as they are on disk
([The engine during development](#the-engine-during-development)). The engine
built from them is checked against its own checksum
(`libflutter_engine.so.local.sha256`), not the committed one.

`prebuilt/flutter-engine/SOURCE_LOCK.json` records the engine a push goes
with, and is the sole source authority for CI and release builds (`build`,
`refresh-metadata`, `verify`) and the development-engine tests. Before pushing
Denial, commit in the forks and advance the lock to their HEADs: the engine
that was deployed and tested. CI has no editable persistent fork. Verified artifacts,
dependencies, compatible build outputs, and detached locked projections may be
cached, but cached source is never authoritative.

The generated `libflutter_engine.so` files are ignored by Git. Their expected
checksums, build metadata, and licenses live below `prebuilt/flutter-engine/`.
`tools/denial-flutter-engine build` consumes the source lock, verifies exact
fork checkouts, and keeps a revision-keyed artifact cache plus stable
mode-specific Ninja outputs. An unchanged lock and build configuration is a
verified no-op; changed commits rebuild only targets invalidated by Ninja.
CI and release builds use `build`, which also stages the verified cache
artifacts below `prebuilt/`. Immediately after deliberately
advancing `SOURCE_LOCK.json`, run
`tools/denial-flutter-engine refresh-metadata` once instead: it regenerates
the release mode's tracked `args.gn` and canonical checksum, builds the
invalidated target, populates the new immutable cache entry, and stages its
artifact. Debug and profile engines are not part of the routine build or
release path. `DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=1` is reserved for an
explicitly requested development-engine refresh. Never repair an expected
checksum one mode at a time.
Before committing a lock advance, refresh both package manifests and run
`tools/denial-release source-audit --branch dev`.
Before pushing Denial, verify every locked fork commit exists on its remote.

Iterate on local engine experiments before advancing the source lock or
running that full release procedure. For an explicitly requested isolated
one-login experiment (not ordinary engine-only preparation), use the
release-engine fast path:

```sh
tools/denial-pc engine-test-build
tools/denial-pc engine-test-check
tools/denial-pc engine-test-arm
```

This builds the canonical Flutter checkout as it is on disk with the existing
release Ninja output, copies the known-good shell bundle into a revisioned,
read-only cache directory, verifies the experimental engine ABI and AOT data,
and arms it for the next `Denial (development)` login only. The launcher
consumes the test flag before starting `deniald`, so a later login returns to
the normal bundle's engine automatically. Use
`tools/denial-pc engine-test-cancel` to disarm it. Never copy or install an
experimental `libflutter_engine.so` over the normal bundle, and especially
never overwrite a library mapped by the running Denial process; truncating a
mapped shared library can crash the live compositor. Advance the source lock
and run the full metadata refresh only after the isolated engine is accepted.

Engine change checklist (avoids slow refreshes and retries):

- Edit in the fork (no commit is needed to build or deploy), then build only
  the needed targets, such as the affected `*_unittests`, in the existing output
  `${XDG_CACHE_HOME:-~/.cache}/denial/flutter-engine/build/out/denial_host_release`.
- Unit tests and the isolated experiment workflow below need separately
  requested scope; a local restart request alone needs only the host release
  engine described above.
- Engine C++ or shader changes that need visual validation go through
  `engine-test-build`, `engine-test-check` and `engine-test-arm` for each
  attempt. This applies to fixes too, not only experiments, and to follow-up
  attempts after an earlier full refresh. Advance the lock and run
  `refresh-metadata` once, after the user accepts. Only changes to `dart:ui`,
  framework or Denial Dart code need a new `libapp.so`, and therefore the full
  path.
- Format with the fork's
  `engine/src/flutter/buildtools/linux-x64/clang/bin/clang-format`.
- Keep depot_tools on `PATH` for fork Git commands. Without it, the hooks make
  `git switch` exit 1 even though it succeeded.
- After `refresh-metadata`, update both `packaging/arch/*/manifest.json` and
  their PKGBUILDs:
  - the fork revision;
  - the SHA-256 of `SOURCE_LOCK.json` and of `args.gn`;
  - the `args.gn` `content_hash`;
  - the engine SHA-256 and build ID;
  - each PKGBUILD's `sha256sums`, which is its manifest's SHA-256.
- Push the fork commit, then refresh the Nix locks with
  `tools/denial-nix refresh-engine-lock`, `refresh-pub-locks` and
  `verify-locks`. Nix fetches the locked commit from GitHub.
- Agent shells are zsh: quote globs and never rely on word splitting.

Denial-owned Flutter and Skia commits use
`Doctor Logix <doctor.logix@gmail.com>`. Set that identity locally in source
forks and temporary repositories; never rely on the host's global Git config.

For direct engine builds, put `flutter/third_party/depot_tools` on `PATH` for
`vpython3`, but invoke `/usr/bin/ninja` explicitly to bypass its Python wrapper.
On an interactive or otherwise non-dedicated machine, leave four logical CPUs
free while compiling (use at most `nproc - 4`): the user's own work, such as a
game, and Synthia need them. Using every available CPU is reserved for a
dedicated build machine.

The Flutter embedder ABI is committed as generated Rust in
`compositor/flutter-engine/src/sys.rs`, stamped with the coupled revisions from
`prebuilt/flutter-engine/linux-x64-release/{ENGINE_REVISION,FLUTTER_REVISION}`.

Normal builds do not run `bindgen` and do not require Clang/libclang. During a
controlled Flutter engine upgrade, regenerate the committed ABI bindings with:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

The generator downloads `embedder.h` from the pinned official Flutter
monorepo commit, runs the separately locked binding tool, and records both
revisions plus the source header's SHA-256 in `sys.rs`. Set
`DENIAL_FLUTTER_EMBEDDER_HEADER` to use an explicit local header instead.

For separate caches, set `DENIAL_PC_DEPENDENCY_ROOT`,
`DENIAL_PC_BUILD_ROOT`, or `DENIAL_PC_RUST_TARGET`. A first bootstrap requires
network access; subsequent builds reuse the cache.

The host needs a Rust toolchain compatible with the repository-level
`rust-toolchain.toml`, `pkg-config`, and the development libraries required by
Smithay's DRM, GBM/EGL, libinput, libseat and udev backends. Normal builds also
need Xwayland; `DENIAL_PC_XWAYLAND=0` removes that build and runtime
requirement. Only binding regeneration needs Clang/libclang.

Install or remove the local display-manager entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```
