# Denial Arch package prototype validation

## Checkpoint

This report records the completed x86_64 Stage 1 package prototype validated
on 2026-07-25. It covers local prototype artifacts only; their dirty
development version, unsigned state, and cache-backed online build make them
unsuitable for publication.

The prototype generation is:

```text
flutter-3.44.7-engine-69c8c617-denial-r1
```

Its runtime capability is:

```text
denial-flutter-engine-abi=3.44.7.denial1
```

The engine's source reconstruction, compilation, unit tests, binary comparison,
and real-hardware validation are recorded in the
[engine validation report](../../../patches/flutter-engine/3.44.7/VALIDATION.md).

## Package artifacts

`tools/denial-pc arch-package` built:

| Package | SHA-256 |
|---|---|
| `denial-flutter-engine-3.44.7.denial1-1-x86_64.pkg.tar.zst` | `d959a17493f080a79bede75c1d477a4e93fb2c2b31a1911babd95aa2124ae6e3` |
| `denial-0.1.0.r52.ge9318467.dirty-2-x86_64.pkg.tar.zst` | `64b0e1c6f6bd0a9249c06ffc1d169d3705fb15ffb837b8002f327bd12e438878` |
| `denial-0.1.0.r52.ge9318467.dirty-3-x86_64.pkg.tar.zst` | `3824ac24a1994d02ce2f0334a5e719080b09e3cd2b286362da863e20948fd778` |

These files remain below
`$XDG_CACHE_HOME/denial/pc-build/packages/`. They are validation artifacts,
not release assets.

## Ownership split

`denial-flutter-engine` owns:

```text
/usr/lib/denial/flutter/lib/libflutter_engine.so
/usr/lib/denial/flutter/data/icudtl.dat
/usr/share/denial/flutter-engine/
/usr/share/doc/denial-flutter-engine/
/usr/share/licenses/denial-flutter-engine/
```

`denial` owns:

```text
/usr/bin/deniald
/usr/bin/denial-session
/usr/lib/denial/flutter/lib/libapp.so
/usr/lib/denial/flutter/data/flutter_assets/
/usr/share/wayland-sessions/denial.desktop
/usr/share/xdg-desktop-portal/denial-portals.conf
/etc/denial/
/etc/xdg/xdg-desktop-portal-wlr/Denial
```

An archive-level comparison found no overlapping payload files. Pacman
reported the engine and ICU files as owned by `denial-flutter-engine`, and the
AOT application and compositor as owned by `denial`.

The `denial` metadata contains both:

```text
depend = denial-flutter-engine
depend = denial-flutter-engine-abi=3.44.7.denial1
```

The engine metadata provides the exact matching capability. Direct native
runtime dependencies now include `ddcutil`, `libpulse`, and PAM. The obsolete
`bluez-utils` and `brightnessctl` suggestions and the informational
post-install hook were removed.

## Artifact identity

The packaged runtime files match their build inputs byte-for-byte:

| File | SHA-256 |
|---|---|
| `libflutter_engine.so` | `acc47606f2c905b089a55cc8f1af6e52dfcbd4a7dc8c7133f462c2f0791bc0cc` |
| `icudtl.dat` | `998367809a821d595928089c197b3f7959f0420f81f79d4d0daee53378492ed5` |
| `deniald` | `9be49fea3de0d37361e5fd04fdaadbb6ff95b687f82cf1b31c2480776637585b` |
| `libapp.so` | `11367138c516899ec33ca73cb965a350af2fab30c398a95649fc745a5162cb71` |

The packaged engine and the live hardware-tested engine have the same hash.
The complete generation metadata is installed as
`/usr/share/denial/flutter-engine/manifest.json`.

## Build and test results

The ordinary promoted-generation workflow completed:

- Flutter AOT assembly;
- isolated bundle construction;
- release `deniald` compilation;
- 306 Rust compositor and embedder tests;
- dynamic loading of the packaged engine ABI;
- ELF architecture and linked-library checks.

No test failed and no linked native library was unresolved.

## Pacman transaction tests

The two packages were installed together into fresh disposable fakeroot
Pacman roots. The tests established:

1. local transaction resolution accepts the concrete and virtual generation
   dependency;
2. both packages install without file conflicts;
3. removing `denial` leaves the independently owned engine generation intact;
4. removing the engine afterward leaves no package payload files;
5. upgrading `denial` from package release 2 to 3 leaves
   `denial-flutter-engine` at `3.44.7.denial1-1`;
6. the installed engine hash remains unchanged across that routine Denial
   upgrade.

The second package build printed:

```text
Reusing validated Flutter generation package:
denial-flutter-engine-3.44.7.denial1-1-x86_64.pkg.tar.zst
```

Its package archive SHA-256 was
`d959a17493f080a79bede75c1d477a4e93fb2c2b31a1911babd95aa2124ae6e3`
both before and after the Denial rebuild.

A read-only Bubblewrap overlay placed the package-installed `/usr` and `/etc`
payloads over the host without modifying it. In that environment,
`denial-session --check` successfully found:

- `/usr/bin/deniald`;
- the split Flutter bundle;
- package-owned output configuration;
- the real `/dev/dri/card2`;
- Xwayland and UWSM.

## Live Pacman-owned session

At 2026-07-25 13:59:38 CEST, SDDM started the installed `Denial` session from:

```text
/usr/bin/denial-session
```

The active compositor command was:

```text
/usr/bin/deniald
  --device /dev/dri/card2
  --output-config /etc/denial/outputs.conf
  --wayland
  --flutter-bundle /usr/lib/denial/flutter
```

Pacman reported:

```text
denial 0.1.0.r52.ge9318467.dirty-3
denial-flutter-engine 3.44.7.denial1-1
```

It owns the executable, launcher, session entry, AOT application, engine, and
ICU files through their intended packages. `/proc/<deniald>/maps` confirmed
that the running process mapped the Pacman-owned
`/usr/lib/denial/flutter/lib/libflutter_engine.so`, whose SHA-256 remained:

```text
acc47606f2c905b089a55cc8f1af6e52dfcbd4a7dc8c7133f462c2f0791bc0cc
```

The packaged session completed:

- atomic KMS validation for both 2560×1440 outputs;
- hardware GLES 3.2 compositor, Flutter raster, and resource contexts;
- Linux DMA-BUF v4 feedback and native-fence synchronization;
- import of the five-buffer 5120×1440 GBM atlas;
- Flutter startup from `/usr/lib/denial/flutter` at 280 Hz;
- UWSM finalization, Xwayland startup, and Wayland client composition.

The user confirmed that the packaged desktop was fully functional. No new
engine, rendering, or package-path error appeared. The startup warnings were
the same display-manager handoff and X11 socket warnings observed in the
development sessions.

## Stage 1 result

All Stage 1 gates now pass:

- pristine source plus the committed patches reconstructs the required engine;
- the source-built engine compiles, passes unit tests, and renders correctly;
- the exact engine/app generation is enforced across two packages;
- install, ownership, startup, upgrade, removal, and cleanup are validated;
- a routine Denial release reuses the unchanged engine package.

## Explicitly unclaimed

Stage 1 does not claim:

- clean-chroot construction;
- an immutable packaged Flutter AOT toolchain;
- offline dependency closure;
- deterministic or reproducible packages;
- signed source tags, packages, or repository databases;
- public repository readiness;
- AArch64 support.

## Package release 4 display persistence correction

After the initial package checkpoint, `nwg-displays` exposed a launcher-level
ownership error. Package release 3 passed the root-owned
`/etc/denial/outputs.conf` to the compositor. Denial correctly persists output
transactions through a temporary file and atomic rename in the target
directory, so a desktop user could apply a runtime configuration but could not
persist it below `/etc/denial/`.

Prototype package release 4 keeps `/etc/denial/outputs.conf` as the
administrator-controlled seed and initializes:

```text
$XDG_CONFIG_HOME/denial/outputs.conf
```

or `$HOME/.config/denial/outputs.conf` when `XDG_CONFIG_HOME` is unset. The
launcher creates the per-user file with mode `0600`, never overwrites an
existing file, rejects symbolic links, and verifies that its parent directory
supports atomic persistence. The package SHA-256 is:

```text
0c32421c12247c72733c66cbc9b4e14ae42cc54582edc40fd11b5696f3c2fb08
  denial-0.1.0.r52.ge9318467.dirty-4-x86_64.pkg.tar.zst
```

The engine package was reused unchanged at SHA-256
`d959a17493f080a79bede75c1d477a4e93fb2c2b31a1911babd95aa2124ae6e3`.
Launcher tests covered initialization, mode, preservation, `HOME` fallback,
invalid relative XDG paths, and rejection of the read-only `/etc` parent.

After installation and a fresh SDDM login, the active compositor command used:

```text
--output-config /home/logix/.config/denial/outputs.conf
```

The file was owned by `logix:logix`, retained mode `0600`, and was not owned by
a Pacman package. `nwg-displays` successfully persisted the two-output
configuration through Denial's output-control transaction, and the user
confirmed the resulting session worked.

## Package release 6 asset-permission correction

The first signed private pipeline rehearsal exposed a packaging difference
between an interactive developer build and the confined owner-operated
runner. The runner deliberately uses `UMask=0077`, and Flutter's generated
asset tree inherited modes `0700` for directories and `0600` for files.
`cp -a` preserved those modes in package release 5. The signatures and
checksums were valid, but an ordinary desktop user would not have been able to
traverse the root-owned asset tree after installation.

Package release 6 normalizes only the packaged Flutter asset tree:

- every directory is mode `0755`;
- every regular file is mode `0644`;
- symbolic links and other unexpected entry types are rejected.

`tools/package-denial-arch` now extracts the completed package into an
isolated temporary directory and enforces those invariants before reporting
success. A local package build under the same pinned inputs passed the new
archive-level gate, and direct archive inspection confirmed readable modes for
the manifest, wallpaper, cursor, font, icon, and shader assets.
