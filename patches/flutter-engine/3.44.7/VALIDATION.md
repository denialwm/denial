# Denial Flutter Engine 3.44.7 validation

## Checkpoint

This report records the x86_64 Stage 1 source-reconstruction and build
checkpoint completed on 2026-07-25.

The published Flutter and Skia histories were converted into a normalized
patch series, applied to pristine upstream revisions, compared with the
published branch tips, compiled, and exercised with the relevant engine
unit-test suites. The exact rebuilt engine then passed real-hardware
compositor validation. The series and engine were promoted together after all
of those gates passed.

Temporary paths named below are diagnostic workspaces, not release artifacts.

## Immutable inputs

| Input | Revision |
|---|---|
| Flutter upstream base | `84fc5cbb223bc12f83d65b647ff8a56caf779ffd` |
| Flutter Denial tip | `5498828ee023a05ae2c6677a1dee3eae7007eebc` |
| Skia upstream base | `e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465` |
| Skia Denial tip | `5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414` |
| Dart | `d684a576a6aa954ae107a03b2b4e1d61c3bebe93` |
| Engine artifact revision | `69c8c61792f04cc809dfef0c910414fb9afc06cd` |

Both published histories are linear from their stated bases. The Flutter
history contains eight Denial commits and the Skia history contains two.

## Candidate patch generation

The candidate was generated directly from the two published commit ranges
with `git format-patch --no-signature --full-index --binary`. Skia paths were
prefixed with `engine/src/flutter/third_party/skia/`, Flutter paths remained
relative to the Flutter monorepo root, and the two streams were combined in
their reviewed logical order.

The generated files have these SHA-256 values:

```text
ea7c3dfdaf58230d0d5b47d04e64b22d3ff8b16841f6e4b4ba35870fc8e6565d  0001-query-embedder-fbo-capabilities.patch
9765a2521abee1187c0e1b1e4178fca4d4dffeb487b50fce9a336392156535e3  0002-enable-stencil-for-gl-surfaces.patch
d3bee059f073fa7b6d1049d05df40177605350fe03252cf531cc1786d5859d74  0003-fix-dmsaa-wrapped-fbo-lifetime-and-stencil.patch
4f023b894db1b64d2814b6510d69b6995a3a287526c74c418ff69d5d4cbe7735  0004-wrap-texture-backed-fbos-for-dmsaa-load.patch
4baa88346d48979449d91249580f79aceb00a1e09d4563d652080324a5ccf9bf  0005-describe-xrgb-scanout-as-rgb8.patch
97436b657733e2228e81cce3d8dd989f3896a2ef130966cb1484e3d2c77d098c  0006-use-highp-for-partial-dmsaa-load.patch
7693823a1e9b61449a492430fcab134e4f2326c5491560c66772b93edde7d02f  0008-preserve-partial-damage-for-reused-layer-trees.patch
0e2a91e4eda4eaf5375b7346a880d910f6705c7260ae3c7a13aff01f57ebc598  0009-damage-only-marked-external-textures.patch
691fdae5b74c73b1f3c5a1deb9183144baba1d2a52abab9d89ea1e6becffe1ec  0010-decouple-autonomous-damage-from-raster-clip.patch
38636c7bd941f744419f522a1f0f1f1cc50489820850b04bc3a91552d315cfe9  0011-schedule-batched-external-texture-frames.patch
```

The SHA-256 of the relative `sha256sum *.patch` manifest is:

```text
ae429d568466e528e7b2a83e3a2597ad819855a780288b362304c2dbb265ff81
```

The validation copy was generated in
`/tmp/denial-engine-patches-3.44.7.Q2Q7vZ/combined`. After the build and
hardware gates passed, those exact patch files replaced the committed
byte-exact recovery series.

## Reconstruction proof

A pristine Flutter checkout at the upstream base and a nested pristine Skia
checkout at its upstream base were created below:

```text
/tmp/denial-engine-verify-3.44.7.dYYRLR/
```

Every candidate patch passed `git apply --check` and applied in sequence. The
result contained exactly the expected 20 changed Flutter files and 3 changed
Skia files.

The resulting Git tree objects exactly equal the published fork-tip trees:

| Tree | Candidate | Published tip |
|---|---|---|
| Flutter | `46b9338313d360954fb46cb9138b86c4c8c27aa3` | `46b9338313d360954fb46cb9138b86c4c8c27aa3` |
| Skia | `a2211168339849c702b7cd8212f668b85a51b1e0` | `a2211168339849c702b7cd8212f668b85a51b1e0` |

This is an object-level equality check, not a textual similarity claim.

## Prototype build

The patched pristine source tree was configured with:

```sh
./flutter/tools/gn --runtime-mode=release \
  --target-dir=denial_host_release
/usr/bin/ninja -C out/denial_host_release -j 8 \
  libflutter_engine.so
```

The build completed all 3,893 Ninja actions. Its generated `args.gn` was
byte-identical to both the committed configuration and the known working
build:

```text
2510d311b93f02a6738cd129efae5d2d0ef15938b3b21c7cc318d43a1e4c228e
```

To avoid copying the approximately 26 GiB known checkout, the disposable
pristine source tree reused its already-pinned gclient dependency closure
through symlinks while build output remained in the disposable tree. No
dependency acquisition was needed during the build. This proves that the
reviewed source state compiles with the known pinned closure; it does not yet
prove a portable, self-contained, network-disabled source closure. That is a
Stage 2 and Stage 3 concern.

## Artifact comparison

| Property | Candidate rebuild | Bootstrap engine |
|---|---|---|
| SHA-256 | `acc47606f2c905b089a55cc8f1af6e52dfcbd4a7dc8c7133f462c2f0791bc0cc` | `0e78a515707bb8cfb5db64c1efdea33a92af5b39b85a20f50f3d537f68deda67` |
| Size | `17,566,192` bytes | `17,566,192` bytes |
| GNU build ID | `81a2d25ef8f0e565a9171d6c14555ae5ee24dfd8` | `ed34d960249151b799400952e7c622705f1fd9f0` |

Both libraries export:

```text
FlutterEngineGetProcAddresses
DenialFlutterEngineScheduleFrameForExternalTextures
```

Their complete dynamic export tables, ELF section tables, SONAME, and dynamic
dependencies are identical. A byte comparison found only 29 differing byte
positions:

- 20 bytes are the content-derived GNU build ID;
- 9 bytes are one-byte source-line immediates used by diagnostic logging.

The nine diagnostic values are each one lower in the formatted source build.
Disassembly traces them to `SkDebugf` or `fml::LogMessage` calls in
`GrGLFinishCallbacks`, `GrGLGpu`, `GrGLSemaphore`, and
`GPUSurfaceGLSkia::AcquireFrame`. They result from formatter-condensed source
lines and do not change the rendering operations around those calls.

The different SHA-256 is therefore explained and expected. It must still be
recorded as a new artifact if the candidate is promoted.

## Engine tests

| Suite | Result |
|---|---|
| Targeted `TextureLayerDiffTest.AutonomousFrameDamagesOnlyMarkedTextures` | 1 passed |
| `flow_unittests` from the required `engine/src` working directory | 270 passed |
| `shell_unittests` | 193 passed, 5 skipped, 4 disabled |
| `embedder_unittests` | 179 passed, 6 skipped, 1 disabled |

The three complete suites report 642 passed tests and no failures. The
targeted test was run once on its own and then again as part of the 270 flow
tests. The full flow suite was rerun from `engine/src` after an initial
invocation from the output directory could not locate its golden test data.
Shell and embedder test compilation was resumed after supplying the pinned
checkout's generated Dart package configuration. Both were test-harness
prerequisites, not product failures.

## Real-hardware validation

At 2026-07-25 13:36:12 CEST, Denial was restarted from SDDM with the candidate
engine installed in its development bundle. The new `deniald` process mapped
the bundle file with SHA-256
`acc47606f2c905b089a55cc8f1af6e52dfcbd4a7dc8c7133f462c2f0791bc0cc`.

The session logs establish:

- atomic KMS acceptance for both 2560×1440 DisplayPort outputs;
- a hardware GLES 3.2 compositor context;
- hardware GLES 3.2 Flutter raster and resource contexts;
- Linux DMA-BUF v4 feedback and native-fence synchronization;
- import of a five-buffer 5120×1440 GBM atlas pool;
- Flutter embedder startup at the 240.001 Hz atlas refresh rate;
- successful Wayland, Xwayland, Kitty, and Chromium client composition.

The user exercised window movement, resizing, animation, and composition
across the live desktop and reported no black frames, stale regions, flicker,
corruption, hangs, or crashes. The one Smithay “surface missing from known
popups” message also occurred repeatedly with the former bootstrap engine and
is not a candidate regression.

## Promotion result

After the hardware result:

1. the exact normalized patch files listed above were promoted into this
   directory;
2. the exact tested engine replaced the former bootstrap engine;
3. `libflutter_engine.so.sha256` was updated to the tested artifact hash;
4. the ordinary development bundle retained that same tested artifact;
5. strict pinned-engine validation was restored in `tools/denial-pc`.

The package prototype is complete through archive, transaction, upgrade,
removal, installed-layout preflight, and a live Pacman-owned login. Signed
Flutter and Skia generation tags remain.

## Post-promotion integration

After promotion, the ordinary `tools/denial-pc` workflow accepted the
source-built engine through its strict pinned checksum without a validation
exception. It rebuilt the Flutter AOT bundle and release compositor, then
passed all 306 Rust compositor and embedder tests, including dynamic loading
of the bundled engine ABI.

The engine was subsequently packaged as the independent
`denial-flutter-engine=3.44.7.denial1-1` prototype. Its archive payload retains
the exact hardware-tested engine SHA-256. The
[Arch package validation report](../../../docs/packaging/arch/VALIDATION.md)
records the package split, transaction tests, and routine-engine-reuse proof.
It also records the successful live package-installed session using this exact
engine.
