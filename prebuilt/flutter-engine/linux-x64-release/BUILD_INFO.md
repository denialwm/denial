# Flutter Engine — Linux x64 release

`libflutter_engine.so` is Denial's pinned raw Flutter Embedder library. The
official Flutter Linux release artifact is the GTK embedding library rather
than this raw AOT embedder ABI, so Denial builds the release library
separately. The generated library is intentionally ignored by Git; this
directory tracks its exact source identity, build recipe, expected checksum,
and licensing material. `tools/denial-pc` verifies a local rebuild before
copying it into the shell bundle.

- Flutter: `3.44.7`
- Flutter source revision: `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`
  (see `FLUTTER_REVISION`)
- Coupled engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd` (see `ENGINE_REVISION`)
- Engine content hash: `7076f47b1d1a3a0edfd8837b17dc15be6abab661`
- Dart source revision: `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
  (Dart SDK `3.12.2`)
- Skia revision: `e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465`
- Public Flutter review branch:
  [`denialwm/flutter@5498828ee023a05ae2c6677a1dee3eae7007eebc`](https://github.com/denialwm/flutter/commit/5498828ee023a05ae2c6677a1dee3eae7007eebc)
- Public Skia review branch:
  [`denialwm/skia@5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414`](https://github.com/denialwm/skia/commit/5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414)
- Official embedder header SHA-256:
  `166626fb689d4e77e720c925f18e814a3cd55280999a443d9d1cc244384e37af`
- Patched Denial embedder header SHA-256:
  `a4760b81a90ee44dc1a10199042129073a0087394b51acd9b5cf037793c4b9f8`
- Engine patches applied: the ordered series under
  `patches/flutter-engine/3.44.7/`. Patches 0001 through 0006 enable and repair
  stencil-backed dynamic MSAA for Denial's borrowed texture FBOs; patch 0008
  restores partial damage for autonomous external-texture frames; patch 0009
  restricts those frames to the texture IDs that requested them; patch 0010
  keeps that precise frame damage for output routing while rasterizing reused
  autonomous layer trees without a partial DMSAA preservation clip; patch 0011
  publishes one batched texture transaction through Denial's versioned
  embedder API and preserves its IDs across frame coalescing. Diagnostic-only
  experiments are not included in the release series.
- GN configuration: `args.gn`, copied verbatim from the build output
- Integrity: `libflutter_engine.so.sha256`; session startup rejects any bundle
  engine that does not match it

The validated reference binary was rebuilt from those review histories. The
normalized series reconstructs both branch-tip Git trees exactly, compiles
successfully for x86_64, and passes the relevant engine unit-test suites and
real-hardware compositor validation. Compared with the former bootstrap
engine, it has identical dynamic exports, ELF sections, SONAME, dependencies,
and size; the only 29 differing byte positions are its 20-byte build ID and
nine formatter-shifted diagnostic source-line values. The [validation
report](../../../patches/flutter-engine/3.44.7/VALIDATION.md) records the
evidence.

The normalized patches, reference checksum, and metadata were promoted
together after validation. The Stage 1 engine/app package split and Pacman
transactions, routine-engine reuse, and live package-installed login are
complete. Signed fork tags remain provenance work before later release stages.

## Rebuild

Start from a clean gclient checkout of the official Flutter monorepo at
`FLUTTER_REVISION` with Skia at the revision above. Put the pinned
`depot_tools` on `PATH`, sync the checkout, then apply and build from the
gclient root:

```sh
cd /path/to/flutter-gclient-root
for patch_file in <repo>/patches/flutter-engine/3.44.7/*.patch; do
  git apply --check "$patch_file"
  git apply "$patch_file"
done
cd engine/src
./flutter/tools/gn --runtime-mode=release --target-dir=denial_host_release
/usr/bin/ninja -C out/denial_host_release -j 8 libflutter_engine.so
```

The generated `out/denial_host_release/args.gn` must match the tracked
`args.gn`. Verify that the library exports `FlutterEngineGetProcAddresses` and
`DenialFlutterEngineScheduleFrameForExternalTextures`, copy it to
`prebuilt/flutter-engine/linux-x64-release/libflutter_engine.so`, and run
`sha256sum --check --strict libflutter_engine.so.sha256` from this directory.
Investigate any mismatch; change the tracked reference checksum only as part
of a controlled engine-generation update. Refresh `LICENSE.third_party` and
regenerate the standard Rust ABI from the pristine official header at the
pinned Flutter revision:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

The generator allowlists Flutter's standard `FlutterEngine*` API. Denial's
versioned extension is loaded and typed separately in
`compositor/flutter-engine/src/lib.rs`; its declaration and implementation are
part of patch 0011.

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
