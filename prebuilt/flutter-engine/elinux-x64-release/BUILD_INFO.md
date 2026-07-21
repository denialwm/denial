# Flutter Engine — Linux x64 release

`libflutter_engine.so` is Denial's pinned raw Flutter Embedder library. The
official Flutter Linux release artifact is the GTK embedding library rather
than this raw AOT embedder ABI, so Denial builds the release library once and
commits it. `tools/denial-pc` verifies its checksum and copies it directly into
the shell bundle; normal contributor builds need neither C++ tools nor an
engine checkout.

- Flutter: `3.44.7`
- Flutter source revision: `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`
  (see `FLUTTER_REVISION`)
- Coupled engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd` (see `ENGINE_REVISION`)
- Engine content hash: `7076f47b1d1a3a0edfd8837b17dc15be6abab661`
- Dart source revision: `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
  (Dart SDK `3.12.2`)
- Skia revision: `e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465`
- Engine patches applied: none. This is the clean upstream performance
  baseline; `patches/flutter-engine/` is historical and must be selectively
  ported and remeasured before reuse.
- GN configuration: `args.gn`, copied verbatim from the build output
- Integrity: `libflutter_engine.so.sha256`; session startup rejects any bundle
  engine that does not match it

## Rebuild

The validated build tree is
`/mnt/exty/denial-flutter-engine-3.44.7/engine/src`, checked out from the
official Flutter monorepo at `FLUTTER_REVISION` with no source changes. Put a
current `depot_tools` on `PATH`, sync the checkout with `gclient`, then run:

```sh
cd /mnt/exty/denial-flutter-engine-3.44.7/engine/src
./flutter/tools/gn --runtime-mode=release --target-dir=denial_host_release
/usr/bin/ninja -C out/denial_host_release -j 8 libflutter_engine.so
```

The generated `out/denial_host_release/args.gn` must match the committed
`args.gn`. Verify that the library exports `FlutterEngineGetProcAddresses`,
copy it here, update its SHA-256, refresh `LICENSE.third_party`, and regenerate
the committed Rust ABI from the exact source header:

```sh
DENIAL_FLUTTER_EMBEDDER_HEADER=/path/to/flutter/shell/platform/embedder/embedder.h \
  tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

Keep `FLUTTER_REVISION`, `ENGINE_REVISION`, the SDK pin in `tools/denial-pc`,
the AOT `libapp.so`, and the generated bindings coupled. A library built from
a different engine release is not a compatible drop-in merely because its C
symbols have the same names.

## Licensing

Flutter Engine is BSD 3-Clause; binary redistribution is permitted.
`LICENSE.flutter` is the engine license for the pinned source revision and
`LICENSE.third_party` is the cumulative third-party license file from
`flutter/sky/packages/sky_engine/LICENSE`. Ship both with any release that
contains this binary. Nothing here implies endorsement by Google or the
Flutter contributors.
