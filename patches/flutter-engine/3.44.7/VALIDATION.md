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
cea48de505b4997b12dd4e0ff356b37791da6df3514aae08c3848e9dc0561ee2  0001-query-embedder-fbo-capabilities.patch
f9c83149a36f7e1e516d69f5d7750b7190eb6eadac8998b1112584b78440132a  0002-enable-stencil-for-gl-surfaces.patch
7c9fbc369443c7c49c9ac36e36d4eff34d25f82811a982461850ecd6a6b2a3cf  0003-fix-dmsaa-wrapped-fbo-lifetime-and-stencil.patch
d5ce934e52a4ce6975591c584daa3b689287a660899f758bf4ee4ffcf64a9770  0004-wrap-texture-backed-fbos-for-dmsaa-load.patch
a8c1db02b4ead8ced1fcb37d22480645fcce1df24c9e9707791da14cf7ec31d4  0005-describe-xrgb-scanout-as-rgb8.patch
f46588fb2a6acb7507ddf26a72bcc7db6087f80a4c5e577a8e692d781a88960c  0006-use-highp-for-partial-dmsaa-load.patch
8fedf41d4faa0a7f93605eab457214519084ac556bd056a6492cbb952d58ded4  0007-cache-rotating-embedder-gl-surfaces.patch
473854ccc931d29858ca699e373a419b37161ed6cc464a4631cf05c45dd9931a  0008-preserve-partial-damage-for-reused-layer-trees.patch
34845352f7fb4fbfe98771439f15e1f9e6e6de4d12523157295ed044f23ae4b9  0009-damage-only-marked-external-textures.patch
b499d85349229655a1120689e16958d439073a5c91cd6c2794159904f0f4c6ea  0010-decouple-autonomous-damage-from-raster-clip.patch
d60912e35c5370f0997899f6a36617e8301a06151498af03b14a658d366dec7f  0011-schedule-batched-external-texture-frames.patch
```

The SHA-256 of the relative `sha256sum *.patch` manifest is:

```text
e0b3146041cec016b42da18bfd54a76a8f5e94ecca5200c327c5791b1402131d
```

On 2026-07-28, the mail-format `From:` headers were normalized to the
repository identity, `Doctor Logix <doctor.logix@gmail.com>`. This
metadata-only normalization changed the fork-derived patch-file hashes.
Patch 0007 is the later source change validated in the 2026-07-29 addendum
below. The reconstruction proof applies to the fork-derived patches; the
current complete manifest covers those patches plus 0007.

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

1. the source-equivalent normalized patch series listed above was promoted
   into this directory;
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

## 2026-07-29 rotating-FBO cache addendum

Patch 0007 fixes an additional performance defect found on NVIDIA hardware.
Denial rotates a persistent pool of embedder-owned atlas FBOs, but
`GPUSurfaceGLSkia` retained only the current `SkSurface`. Every present
therefore destroyed the old wrapper and recreated its full-atlas stencil and
dynamic-MSAA resources when the next FBO was selected. The patch retains one
wrapper per stable FBO and clears the cache on a surface-size change or engine
teardown.

The ownership contract was audited against Denial's compositor:

- atlas FBO IDs are nonzero and unique within a runtime;
- the pool is fixed and bounded by `MAX_ATLAS_BUFFERS`;
- topology and atlas-size changes create a new Flutter runtime;
- the engine shuts down before `destroy_targets` releases the FBOs;
- external window images already retain their last resolved Flutter image,
  mark only changed texture IDs, and use bounded DMA-BUF/SHM binding caches;
- the remaining native render fence is intentionally one-shot for KMS and
  client-buffer synchronization.

The same patched source overlay produced both runtime modes with their tracked
GN arguments:

| Artifact | SHA-256 | Size |
|---|---|---:|
| Linux x64 profile | `465a0b6c76d9f8561c177db4a76a267527fa2a411ed5d9f34f61739844000bce` | 18,752,880 bytes |
| Linux x64 release | `6e884cbed86f1a60431f8755f1137516610f02d5daf3dd55682b9986d59032f7` | 17,568,592 bytes |

The release artifact has GNU build ID
`453bfc3429c171fbe36d71719dd71ddef05948bc`. Both artifacts retain
`FlutterEngineGetProcAddresses` and
`DenialFlutterEngineScheduleFrameForExternalTextures`. The rebuilt release
`args.gn` is byte-identical to the tracked file with SHA-256
`2510d311b93f02a6738cd129efae5d2d0ef15938b3b21c7cc318d43a1e4c228e`.

The post-patch release source passed:

| Suite | Result |
|---|---|
| `shell_unittests` | 193 passed, 5 skipped, 4 disabled |
| `embedder_unittests` | 179 passed, 6 skipped, 1 disabled |

Hardware validation used the optimized AOT profile runtime on an RTX 4060
Mobile driving 1920×1200 at 144 Hz. Both traces toggled the launcher 14 times
over a representative desktop containing Kitty and Chromium windows:

| Metric | Before 0007 | With 0007 |
|---|---:|---:|
| `GPURasterizer::Draw` p50 | 4.546 ms | 1.517 ms |
| `GPURasterizer::Draw` p95 | 8.595 ms | 2.137 ms |
| `CompositorContext::ScopedFrame::Raster` p50 | 1.717 ms | 0.623 ms |
| `GrDirectContext::flushAndSubmit` p50 | 2.228 ms | 0.713 ms |
| Effective Flutter cadence | 120.20 Hz | 143.81 Hz |
| Scene/display lag events | 75 | 0 |
| Maximum pipeline depth | 2 | 1 |

The final trace contains 320 raster frames. Its maximum total raster time is
4.845 ms against the 6.944 ms display budget, and every in-trace Flutter and
DRM delivery interval remains in the 144 Hz cadence bin.

A six-second raster-thread `perf trace` also separates the fixed churn from
ordinary presentation. NVIDIA `NV_ESC_RM_FREE` time fell from 18.433 ms to
3.497 ms, and `NV_ESC_RM_UNMAP_MEMORY_DMA` time fell from 40.272 ms to
4.170 ms. An idle control recorded only 8–9 calls of each relevant opcode;
the approximately one-per-rendered-frame operations during animation are
consistent with the required native-fence path.

An exact old/new VRAM delta is intentionally not claimed. The native Flutter
library remains resident when only the UI runtime is reloaded, so a hot
profile-mode switch cannot replace the mapped engine for a valid memory A/B.
The patched process fluctuated between 203 and 296 MiB of resident framebuffer
memory under NVIDIA's accounting while composing the representative desktop.
