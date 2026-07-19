# Patched Flutter Engine — elinux-x64-release

`libflutter_engine.so` in this directory is the Denial-patched Flutter Engine
described in `patches/flutter-engine/README.md`. It is the binary that
`tools/denial-pc` installs into the Dart bundle after every
`flutter-elinux build`, replacing the stock Sony prebuilt.

- Engine revision: `cb4b5fff73850b2e42bd4de7cb9a4310a78ac40d` (see
  `ENGINE_REVISION`; Skia revision `6062afaa505bf7e6c727a20cafe4c7bee0f02df8`
  via DEPS)
- Patches applied: `patches/flutter-engine/0001`–`0006`, verified to
  reproduce the build tree byte-for-byte
- GN configuration: `args.gn` in this directory (copied verbatim from the
  build output directory)
- Integrity: `libflutter_engine.so.sha256` — `tools/denial-pc` refuses to
  run a session whose bundle engine does not match this hash

## Where it was built

Build tree (kept, not disposable): `/mnt/exty/denial-flutter-engine/`

- `src/` — engine checkout at the pinned revision with the patch series
  applied to `src/flutter` (0001, 0002, 0004, 0005) and
  `src/flutter/third_party/skia` (0003, 0006)
- `depot_tools/` — must be on `PATH` for ninja actions (`vpython3`) and the
  repo's git hooks
- `rollback/` — timestamped copies of previous engine binaries

Rebuild command:

```sh
export PATH=/mnt/exty/denial-flutter-engine/depot_tools:$PATH
cd /mnt/exty/denial-flutter-engine/src
flutter/third_party/ninja/ninja -C out/denial_host_release libflutter_engine.so
```

Then copy the result here and refresh the checksum:

```sh
cp src/out/denial_host_release/libflutter_engine.so <repo>/prebuilt/flutter-engine/elinux-x64-release/
cd <repo>/prebuilt/flutter-engine/elinux-x64-release
sha256sum libflutter_engine.so > libflutter_engine.so.sha256
```

If the exty build tree is ever lost, recreate it with a standard engine
checkout (`gclient`) at the pinned revision, apply the patch series per
`patches/flutter-engine/README.md`, write `args.gn` from this directory into
`src/out/denial_host_release/`, and run `gn gen` + the ninja command above.
Run the full validation checklist in `patches/flutter-engine/README.md`
before replacing the binary here.

## Licensing

Flutter Engine is BSD 3-Clause; binary redistribution is permitted.
`LICENSE.flutter` is the engine license for the pinned revision and
`LICENSE.third_party` is the cumulative third-party license file from
`flutter/sky/packages/sky_engine/LICENSE`. Ship both with any release that
contains this binary. Nothing here implies endorsement by Google or the
Flutter contributors.
