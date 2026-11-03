# Working on Denial

Denial is a Flutter-native Wayland compositor. [README.md](README.md) and
[docs/architecture.md](docs/architecture.md) explain it;
[docs/BUILDING.md](docs/BUILDING.md) is the build reference. For plugin work
read [docs/PLUGIN_DEVELOPMENT.md](docs/PLUGIN_DEVELOPMENT.md), and
[docs/PLUGIN_SYSTEM.md](docs/PLUGIN_SYSTEM.md) before changing the plugin
system; it is a design contract, not authorization to implement or deploy it.

## Repository workflow

- Development lands on `dev`. Arm the ephemeral builder before pushing so
  `.github/workflows/branch-validation.yml` builds, packages and verifies that
  exact commit. Fix pipeline failures on `dev`, never on `main`, and promote
  the green commit through a merge-commit pull request whose tree is exactly
  the validated `dev` tree; never squash or alter it.
- `main` builds its own production-mode, version-neutral candidate; never
  promote a `dev` binary as a release. Choose and sign `vMAJOR.MINOR.PATCH`
  only once that `main` candidate is green. The tag workflow promotes the
  retained `main` payloads without compiling again, and the tag is the only
  source of package and runtime versions: Cargo and Dart versions are source
  metadata, Flutter generation identifiers compatibility metadata.
- Run every `gh`, `tools/denial-builder`, `tools/denial-pc`,
  `tools/denial-plugins` and networked Git command (auth checks, fetch, pull,
  push, remote inspection) outside the sandbox; credential or network failures
  inside it prove nothing. PID and `/proc/PID/maps` checks run outside too: the
  sandbox can hide the running compositor.
- When the user asks for a commit and push, include all local changes unless
  they say otherwise.
- Copying the checkout, uncommitted work included, to `.18` and `.188` is not
  exfiltration. Run Nix lock refreshes and checks on the workstation (its Nix
  store is on `/mnt/exty`) or on `.18`.
- Commits in the Flutter and Skia forks and in temporary repositories use
  `Doctor Logix <doctor.logix@gmail.com>`, set locally; never rely on the
  global Git config.
- Agent shells are zsh: quote globs and never rely on word splitting.
- On a non-dedicated machine leave four logical CPUs free while compiling
  (`nproc - 4`): the user's own work and Synthia need them.

## Sessions, hosts and devices

The workstation's graphical session belongs to the user. Never log out, stop
its user-session targets or compositor, or reboot or power off the workstation
unless the user asks for that exact action. When a test needs a fresh local
session, say so and wait until the user has logged out to SDDM, logged back in
and confirmed it.

The lab hosts `192.168.1.18`, `.183` and `.188` and the user's phones and
tablets are agent-managed: restart their compositor or login session and
reboot them when the work needs it, announcing it, without asking. After
deploying a compositor or Flutter bundle to one, restart its Denial session and
confirm a new `deniald` is running.

- A Denial, engine or shell update is activated by restarting the Denial
  service or session, then verifying the new process, mapped engine, artifact
  hashes and service health. Reboot only when the change needs it or a restart
  cannot complete, and first confirm nothing pending changes what the device
  boots.
- Never flash an `_a` partition or switch the active slot. Flashing a kernel
  or boot image to `_b` needs no go-ahead; announce it. The device's
  Phonewave README names the `_b` partitions and the checks.
- On the greetd hosts `.183` and `.188`, restart `greetd.service` directly,
  without ending the login session first or waiting for Denial to return:
  greetd runs `initial_session` once per daemon start, otherwise its greeter.
- `.183` (AMD Raven laptop, Wi-Fi: SSH answers a minute or two after boot)
  has amdgpu GPU hangs that its reset cannot recover: a machine issue, not
  Denial. `gpu-hang-recover.service` saves the devcoredump and the named
  process to `/var/log/amdgpu/` and reboots it through SysRq; GFXOFF is off on
  its kernel command line (`amdgpu.ppfeaturemask=0xfff73fff`).
- The lab Limine entries hash the staged kernel and initramfs with
  BLAKE2b-512, not SHA-512, which has the same 128-hex shape but stops Limine
  with `hash for URI does not match!`. Generate each suffix with
  `b2sum -l 512 FILE` and recompute both against `limine.conf` right before
  rebooting.
- The Moto Edge 70 (`ssh roadstr`) restarted Denial without hanging when its
  screen was already off (user, 2026-09-08); not yet confirmed repeatedly.

## Activating plugin and shell updates

- `tools/denial-pc refresh` reloads an active composition's existing bundle and
  does not apply checkout edits. To apply them, run
  `tools/denial-pc plugin-manager`, then `tools/denial-plugins plan`,
  `build ID` and `activate ID` with the returned candidate ID, keeping the
  selection. Verify the candidate contains the fix, `plugin_healthy` is true
  and the compositor maps the candidate's `libapp.so`. No session restart is
  needed.
- For a combined compositor and shell update, activate the rebuilt plugin
  candidate before asking the user to log out, when the running engine allows
  it. Activation persists the selection for the next login; building alone does
  not select it.

## Test-device deployment failures: no automatic rollback

On test devices and lab hosts, a candidate that fails to start, verify or work
is a diagnostic result. Don't switch the engine, shell bundle, compositor,
service configuration or selected revision back on your own: report the
failure and ask the Doctor first; a rollback the Doctor directs is fine.
Report separately what is installed, what the selection points to, what is
actually running (or that nothing is) and where the previous versions are. An
installed candidate is not necessarily selected or active, and a failed
activation stays as it is for diagnosis.

This overrides generic rollback advice and does not authorize unrequested
deployments. If an operation threatens
irreversible data loss or device damage, stop it and ask; never wipe a device,
delete backups or skip safety gates to keep a candidate in place.

## Visual validation

The user does all visual validation. Never capture or inspect screenshots,
judge rendered output, launch applications for visual inspection or set up UI
state for visual QA, on the workstation or any remote Denial host. Never
trigger a notification or other visible or interactive event unless the user
asks for that specific trigger; permission to deploy, restart or check health
does not include it.

## Flutter engine

[docs/BUILDING.md](docs/BUILDING.md) describes the engine workflow; these are
its rules.

- During development the engine is built from the forks as they are on disk,
  uncommitted changes included: Flutter `/mnt/exty/denial-flutter-fork-3.44.7`
  and Skia `/mnt/exty/denial-skia-fork-3.44.7`, relocated only together with
  `DENIAL_FLUTTER_SOURCE_ROOT` and `DENIAL_SKIA_SOURCE_ROOT`. Edit, format and
  commit engine source only there. Never make or use a lock-pinned projection or
  other copy of the forks on a development machine, and never edit the one an
  isolated builder keeps.
- A local engine request means only the current machine's native RELEASE
  engine (`denial_host_release` here). Reuse a matching engine after checking
  its architecture, release arguments, source provenance and local checksum;
  otherwise build just `libflutter_engine.so` with `/usr/bin/ninja` in the
  cached output (the command is in docs/BUILDING.md), running
  `tools/denial-flutter-engine prepare-graph` first only if the graph is
  missing, and building a missing compiler prerequisite as its own
  host-release target. ARM or cross builds, debug or profile engines, engine
  tests, the shell, Settings, the compositor, packages and the plugin kit each
  need their own request. `tools/denial-pc build`, `bundle` and `refresh`,
  `tools/denial-flutter-engine prepare-app-build` and `prepare-development-sdk`
  build more than the engine; don't use them for an engine-only request. Never
  get past the plugin-kit checker with forged metadata, lock changes or a
  pinned projection.
- A ready engine doesn't make a shell, Settings app or selected bundle
  compatible or active; state the actual next step instead. Preparing an
  engine authorizes no logout, restart, deployment or engine-test arming.
- Never overwrite an engine a running process maps (truncating it can crash
  the live compositor), and never copy an experimental `libflutter_engine.so`
  over the normal bundle. Installing or activating keeps the previous
  versions and rollback backups.
- Never run `flutter test` directly for `dart_shell`. Routine validation is
  `tools/denial-pc compositor-test`, `sdk-test` and `plugin-check`;
  `tools/denial-pc test` and `flutter-test` build a debug engine from the
  locked commits and run only when asked for.
- Build only the targets a change needs, such as the affected `*_unittests`, in
  `${XDG_CACHE_HOME:-~/.cache}/denial/flutter-engine/build/out/denial_host_release`.
  Engine C++ or shader changes that need visual validation, fixes included, go
  through `tools/denial-pc engine-test-build`, `engine-test-check` and
  `engine-test-arm` for every attempt; that arms the engine for the next
  `Denial (development)` login only, and `engine-test-cancel` disarms it. Only
  `dart:ui`, framework or Denial Dart changes need a new `libapp.so` and the
  full path.
- Format with the fork's
  `engine/src/flutter/buildtools/linux-x64/clang/bin/clang-format`. Keep
  `flutter/third_party/depot_tools` on `PATH` for `vpython3` and fork Git
  commands (without it the hooks make `git switch` exit 1 although it worked),
  but call `/usr/bin/ninja` explicitly.
- `prebuilt/flutter-engine/SOURCE_LOCK.json` is the only source authority for
  CI, releases and the debug-engine tests. Once the user accepts an engine
  change, and before Denial is pushed: commit in the forks, advance the lock to
  their HEADs, run `tools/denial-flutter-engine refresh-metadata` once (never
  repair checksums one mode at a time; `DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=1`
  only when asked), refresh the package manifests with
  `tools/refresh-denial-engine-manifests`, run
  `tools/denial-release source-audit --branch dev`, push the fork commits and
  refresh the Nix locks with `tools/denial-nix refresh-engine-lock`,
  `refresh-pub-locks` and `verify-locks`. Every locked fork commit must exist
  on its remote before Denial is pushed.
