# Flutter tool snapshot — 3.44.7

`denial-ui-development` runs Flutter's own tool snapshot for project
resolution, kernel assembly, debug-adapter integration, and `flutter attach`.
The snapshot is rebuilt from the pinned Flutter SDK rather than committed as a
binary. Before snapshotting, Denial applies the ordered SDK patch series in
`patches/flutter/`. The tooling patches permit an explicit VM-service attach
to a raw-embedder Flutter project without fabricating a generated Linux runner
and make Denial's supported editor connection non-pausing. Hot reload and
DevTools remain available, while DAP cannot freeze the complete desktop with a
breakpoint or step operation.

- Flutter: `3.44.7`
- Flutter revision: `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`
- Dart: `3.12.2`
- Dart revision: `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
- Flutter tool lockfile:
  `packages/flutter_tools/pubspec.lock` from the pinned Flutter revision
- Snapshot kind: Dart `app-jit`
- Snapshot CPU target: generic x86-64 (`--target-unknown-cpu`)
- Expected output: `flutter_tools.snapshot.sha256`

Flutter's ordinary bootstrap snapshot records absolute paths to the SDK and
the build user's Pub cache. Denial's Rust `xtask` rebuilds it inside an
unprivileged Bubblewrap mount namespace. Flutter and every locked Pub package
appear below the stable virtual root `/opt/denial-build/ui-development`, and
Dart's deterministic snapshot mode is enabled from a neutral directory which
is not itself a Flutter project. The namespace clears the complete ambient
environment, then supplies fixed `HOME`, XDG, `PATH`, locale, timezone, CI,
Git, temporary-directory, and `SOURCE_DATE_EPOCH` values. Dart's snapshot
layout changes with some of those inputs even in deterministic mode. The
canonical package map also fixes `flutterRoot`, `pubCache`, and the optional
`flutterVersion` metadata to the pinned SDK values. Flutter may omit
`flutterVersion` in a fresh tool bootstrap while retaining it in an already
initialized SDK; leaving that incidental difference in the map changes the
snapshot bytes. The snapshot command additionally selects Dart's generic CPU
target so a newer x86-64 host cannot specialize the tool snapshot beyond the
baseline used by another x86-64 machine. The resulting diagnostic source URIs
contain no builder identity or home directory, and the snapshot does not
retain the Flutter tool sources as its default project.

The optional Pacman package records all 102 package roots resolved by this
Flutter tool lockfile in a generated runtime package map using only relative
paths below `/usr/lib/denial/ui-development`. For those tool dependencies it
retains the root package metadata and license/notice files needed by Flutter's
startup and attribution paths, while omitting source bodies that Denial's
assembly and attach workflows never open. It neither records the builder's Pub
cache nor depends on a user's existing cache.

The package also carries the `lib/` sources and hosted-cache hash records for
the exact Pub packages resolved by Denial's own `dart_shell/pubspec.lock`.
Those packages seed a Denial-scoped writable user cache, allowing the packaged
source snapshot to run `pub get --offline` without consulting the network or a
pre-existing user cache.

The package separately stages the small Flutter and Dart runtime slice
exercised by Denial: the Flutter framework, localization, test API, and tool
sources; Dart executables and compiler/service snapshots; material assets;
shader tools and libraries; and engine inputs for `copy_flutter_bundle`.
It includes Dart's standard-library sources and both pinned analysis-server
snapshots: Dart's CLI can use the AOT server, while Dart Code requires the JIT
snapshot when validating an SDK before it will select that SDK for analysis.
It also includes Flutter's generated `sky_engine/lib` sources and embedder map,
which teach the analyzer about Flutter-only libraries such as `dart:ui`. This
provides diagnostics, completion, and navigation without a system Flutter
installation. An isolated validation copies the version-matched source
snapshot, prepares Denial's real shell offline, and analyzes a probe using
`Color` and `VoidCallback` from the finished archive. Browser DevTools, the GTK
runner, SDK test trees, and unused Pub source trees are rejected.

Build and validate the complete development package from the Denial
repository root:

```sh
cargo xtask ui-development-package
```

The command verifies this checksum before makepkg can consume the snapshot,
then verifies the same bytes in the finished package. A mismatch must be
investigated as a source, dependency, Dart, or snapshot-generation change;
do not update this checksum independently.
