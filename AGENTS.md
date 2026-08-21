A Flutter-native Wayland compositor.

Denial begins with a belief: origin does not have to dictate purpose.

Flutter was created to build application interfaces. Here, it is given a
different life. It owns the desktop scene itself: the shell, its motion, and
the composition of Wayland applications. Flutter is not an overlay placed on
top of another compositor. It is part of the compositor's foundation.

That is the architecture. It is also the meaning of the name.

## Repository workflow

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
`192.168.1.18` (`.18`) and `192.168.1.183` (`.183`). Agents may autonomously
stop or restart their compositor, greetd/login session, launch test
applications, and reboot them when required. After deploying a compositor or
Flutter bundle to either host, the agent is responsible for restarting its
Denial session and confirming that a new `deniald` process is running; no
additional authorization is required. Treat both machines as agent-managed
test hosts, not as the user's local graphical session.

The shared Denial lab Limine entries on these hosts hash staged kernel and
initramfs URI payloads with **BLAKE2b-512**, not SHA-512. Generate each URI
suffix with `b2sum -l 512 FILE`. Immediately before rebooting, independently
recompute both BLAKE2b-512 values and compare them byte-for-byte with the
suffixes in `limine.conf`. A SHA-512 suffix has the same 128-hex-character
shape but is invalid; Limine will stop before Linux starts with
`hash for URI does not match!`.

On the greetd-backed `.183`, restart `greetd.service` directly. Do not
terminate the login session first or wait for Denial to return: greetd runs its
configured `initial_session` only once per daemon start and otherwise falls
back to its greeter.

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

The compositor binary is written to
`$XDG_CACHE_HOME/denial/pc-build/rust/release/deniald` by default. The Flutter
bundle is written to `dart_shell/build/linux/x64/release/bundle`.
`tools/denial-pc` builds its AOT assets directly with the locked Denial Flutter
fork and packages the locally rebuilt raw embedder library; normal builds do
not use a third-party platform runner or a C++ Linux runner.

The source lock in `prebuilt/flutter-engine/SOURCE_LOCK.json` pins Denial's
Flutter and Skia forks at exact commits. Their upstream compatibility base is
Flutter `3.44.7`
(`84fc5cbb223bc12f83d65b647ff8a56caf779ffd`), coupled to Dart `3.12.2` and
engine artifact `69c8c61792f04cc809dfef0c910414fb9afc06cd`. All Denial engine,
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
An isolated builder without the canonical pair may retain a detached,
lock-pinned source projection; never edit it because tooling may replace it.

`prebuilt/flutter-engine/SOURCE_LOCK.json` is the sole source authority for an
engine build. Treat it as immutable for that build: dirty canonical worktrees
and arbitrary local revisions are not inputs. Commit changes in the canonical
forks, then deliberately advance the lock to their exact commits. CI has no
editable persistent fork. Verified artifacts, dependencies, compatible build
outputs, and detached locked projections may be cached, but cached source is
never authoritative.

The generated `libflutter_engine.so` files are ignored by Git. Their expected
checksums, build metadata, and licenses live below `prebuilt/flutter-engine/`.
`tools/denial-flutter-engine build` consumes the source lock, verifies exact
fork checkouts, and keeps a revision-keyed artifact cache plus stable
mode-specific Ninja outputs. An unchanged lock and build configuration is a
verified no-op; changed commits rebuild only targets invalidated by Ninja.
Routine builds use `build`, which also stages the verified cache artifacts
below `prebuilt/` for `tools/denial-pc`. Immediately after deliberately
advancing `SOURCE_LOCK.json`, run
`tools/denial-flutter-engine refresh-metadata` once instead: it regenerates
all modes' tracked `args.gn` and canonical checksums, builds the invalidated
targets, populates the new immutable cache entry, and stages its artifacts.
Never repair an expected checksum one mode at a time.

Iterate on local engine experiments before advancing the source lock or
running that full release procedure. Use only the release-engine fast path:

```sh
tools/denial-pc engine-test-build
tools/denial-pc engine-test-check
tools/denial-pc engine-test-arm
```

This builds the current clean canonical Flutter checkout with the existing
release Ninja output, copies the known-good shell bundle into a revisioned,
read-only cache directory, verifies the experimental engine ABI and AOT data,
and arms it for the next `Denial (development)` login only. The launcher
consumes the test flag before starting `deniald`, so a later login returns to
the pinned known-good engine automatically. Use
`tools/denial-pc engine-test-cancel` to disarm it. Never copy or install an
experimental `libflutter_engine.so` over the normal bundle, and especially
never overwrite a library mapped by the running Denial process; truncating a
mapped shared library can crash the live compositor. Advance the source lock
and run the full metadata refresh only after the isolated engine is accepted.

Denial-owned Flutter and Skia commits use
`Doctor Logix <doctor.logix@gmail.com>`. Set that identity locally in source
forks and temporary repositories; never rely on the host's global Git config.

For direct engine builds, put `flutter/third_party/depot_tools` on `PATH` for
`vpython3`, but invoke `/usr/bin/ninja` explicitly to bypass its Python wrapper.
On an interactive or otherwise non-dedicated machine, leave at least one and
preferably two logical CPUs free while compiling (normally use at most
`nproc - 2`). Using every available CPU is reserved for a dedicated build
machine.

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
`rust-toolchain.toml`,
`pkg-config`, Xwayland, and the development libraries required by Smithay's
DRM, GBM/EGL, libinput, libseat and udev backends. Only binding regeneration
needs Clang/libclang.

Install or remove the local display-manager entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```
