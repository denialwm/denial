# Denial Flutter Engine 3.44.7 patch series

## Status

Source recovery, logical commit preparation, public branch publication,
normalized reconstruction, a pristine-source x86_64 compile, engine unit
tests, and real-hardware compositor validation are complete. The ordered patch
series in this directory is the normalized release representation of the
published Flutter and Skia branch tips and the source of the current pinned
x86_64 engine. The Stage 1 package prototype, transactions, routine-engine
reuse, and live Pacman-owned login are complete. Signed generation tags remain
follow-up provenance work.

## Pinned bases

- Flutter: `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`
- Skia: `e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465`
- Dart: `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
- Engine artifact: `69c8c61792f04cc809dfef0c910414fb9afc06cd`

The standard generated Rust ABI uses the pristine official `embedder.h`:

```text
166626fb689d4e77e720c925f18e814a3cd55280999a443d9d1cc244384e37af
```

After patch 0011, the versioned Denial header is:

```text
a4760b81a90ee44dc1a10199042129073a0087394b51acd9b5cf037793c4b9f8
```

The binding generator deliberately allowlists Flutter's standard
`FlutterEngine*` API. The Denial extension is loaded and typed separately in
`compositor/flutter-engine/src/lib.rs`.

The patches currently use paths relative to `engine/src` and are applied in
filename order:

```sh
DENIAL_ROOT=/path/to/denial
(
  cd "$DENIAL_ROOT/patches/flutter-engine/3.44.7"
  sha256sum --check --strict series.sha256
)

for patch_file in "$DENIAL_ROOT"/patches/flutter-engine/3.44.7/*.patch; do
  git apply --check "$patch_file"
  git apply "$patch_file"
done
```

Run the loop from the pinned Flutter checkout's `engine/src` directory. The
SHA-256 of `series.sha256` is also pinned in the engine generation manifest.

The top-level [engine patch documentation](../README.md) describes the
rendering problems and validation requirements in detail.
The [2026-07-25 validation report](VALIDATION.md) records the published-tree
equality proof, candidate build, binary comparison, and unit-test results.

## Published fork histories

Flutter and Skia are separate Git checkouts in Flutter's dependency layout.
Their modifications therefore cannot truthfully be represented by one Flutter
fork branch.

The Flutter history is published at
[`denialwm/flutter`](https://github.com/denialwm/flutter) on
[`denial/3.44.7-r1`](https://github.com/denialwm/flutter/tree/denial/3.44.7-r1):

```text
Worktree: /mnt/exty/denial-flutter-fork-3.44.7
Branch:   denial/3.44.7-r1
Base:     84fc5cbb223bc12f83d65b647ff8a56caf779ffd
Tip:      5498828ee023a05ae2c6677a1dee3eae7007eebc
```

| Commit | Change |
|---|---|
| `3cd8f5b5ee3beb0915b5dfe24a6549a57232c367` | Query embedder FBO capabilities |
| `9353c04c284bc1628bc09298b7b85de70e1da294` | Enable stencil for embedder GL surfaces |
| `bb098bcf0a256f39761fa3ce1f58d47d15ba6bb4` | Wrap texture-backed FBOs for GLES DMSAA loads |
| `7520e08db822506fb79baf7533bb44e0765b3173` | Describe XRGB scanout textures as RGB8 |
| `ef8d243f38bbe499268ae39083946555efd2d956` | Preserve partial damage for reused layer trees |
| `21460af54b51d6632be5196a78118748149dd4dd` | Damage only marked textures in autonomous frames |
| `cf6d28175ad4d635c7d7d96d3c2c48b797db5c06` | Decouple autonomous damage from the raster clip |
| `5498828ee023a05ae2c6677a1dee3eae7007eebc` | Schedule batched external-texture frames |

The Skia history is published at
[`denialwm/skia`](https://github.com/denialwm/skia) on
[`denial/3.44.7-r1`](https://github.com/denialwm/skia/tree/denial/3.44.7-r1):

```text
Worktree: /mnt/exty/denial-skia-fork-3.44.7
Branch:   denial/3.44.7-r1
Base:     e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465
Tip:      5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414
```

| Commit | Change |
|---|---|
| `9c5b4af03ef9b5bfc193838c449c042c6c47312e` | Fix DMSAA lifetime and stencil continuity on wrapped GL FBOs |
| `5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414` | Use highp coordinates for partial DMSAA loads |

Both published branch tips are clean. All 19 changed Flutter C/C++ files pass
the pinned Flutter formatter, and all three changed Skia files pass Skia's
changed-lines-only `git clang-format` check. Publication folded formatter-only
line wrapping into two Flutter files and the changed lines of all three Skia
files. The public tips are therefore source-equivalent, but intentionally not
byte-for-byte identical, to the recovered working checkout.

The patch files are mechanically generated from those formatter-normalized
histories. They pass sequential apply checks, exact Git-tree equality with
both public tips, a pristine-source x86_64 compile, static artifact comparison,
the relevant engine unit tests, and real-hardware compositor validation. The
series and tested engine were promoted together on 2026-07-25. The original
working checkout remains untouched as recovery evidence. Signed fork tags
remain required before a packaged release.

The local source repositories are shallow at their pinned bases. Both public
forks contain the exact upstream base commits, and the remote branch tips were
independently verified after publication on 2026-07-25.

## Recovery evidence

The recovery audit used the known working checkout at
`/mnt/exty/denial-flutter-engine-3.44.7`. It inspected every Git checkout
listed in `.gclient_entries`. Only the Flutter monorepo root and its pinned
Skia checkout contained source modifications:

- 20 modified Flutter files;
- 3 modified Skia files;
- no untracked source files;
- no modifications in the other dependency checkouts.

The recovery-form patches 0001 through 0010 reproduced 12 Flutter files and
all 3 Skia files byte-for-byte. Two other Flutter files contained additional
changes beyond those patches, and 6 more Flutter files were newly modified.
That residual 8-file delta formed one coupled change:

- batched `DenialFlutterEngineScheduleFrameForExternalTextures` embedder API;
- shell-side publication of one external-texture transaction;
- rasterizer handling when that request coalesces with a framework frame;
- preservation of pending texture IDs when no reusable layer tree exists;
- export-list publication of the Denial ABI.

That residual is captured without source changes in
`0011-schedule-batched-external-texture-frames.patch`.

Before formatter normalization, applying the ten recovery-form patches to
pristine pinned Flutter and Skia checkouts produced the same 23-file modified
set as the working checkout byte-for-byte. The now-committed normalized series
instead produces Git trees exactly equal to both published fork tips. The
formatter-only differences and both tree objects are recorded in
[VALIDATION.md](VALIDATION.md).

The already-built library in that checkout and the former bootstrap library
matched:

```text
SHA-256: 0e78a515707bb8cfb5db64c1efdea33a92af5b39b85a20f50f3d537f68deda67
```

The promoted source rebuild is:

```text
SHA-256: acc47606f2c905b089a55cc8f1af6e52dfcbd4a7dc8c7133f462c2f0791bc0cc
```

[VALIDATION.md](VALIDATION.md) explains every binary difference and records
the successful source-build, unit-test, and real-hardware gates.
