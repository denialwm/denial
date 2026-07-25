# Bibata Modern Ice cursor assets

Denial bundles one unchanged 32 × 32 frame for each cursor role from
**Bibata Modern Ice 2.0.7**. The artwork was hand-designed by
[Abdulkaiz Khatri](https://github.com/ful1e5) and is distributed under
`GPL-3.0-only`.

- Upstream repository: <https://github.com/ful1e5/Bibata_Cursor>
- Release: <https://github.com/ful1e5/Bibata_Cursor/releases/tag/v2.0.7>
- Tag commit: `35ccfe209a808e40d6c2ca60a46cbe4faf68b690`
- Linux artifact: `Bibata-Modern-Ice.tar.xz`
- Linux SHA-256:
  `a68cae60c4dc706350e194ebc91c5fe48bc7bc9d59e119555834a2a7ee5078ef`
- Windows artifact: `Bibata-Modern-Ice-Windows.zip`
- Windows SHA-256:
  `0045e40324da5b540b3bee260f53d0792df62be9cdef91655a024ae9f151bd04`

The Linux XCursor release supplies fifteen roles. Its native 32 × 32 entry is
decoded without resampling. The Linux release does not contain `person` or
`pin`, so those two embedded 32 × 32 PNGs are extracted unchanged from the
official regular-size Windows release. Denial does not resize, recolor, redraw,
or otherwise modify any frame.

Bibata is registered as a static standard-size theme: every role declares its
own canvas and hotspot and uses `frameCount: 1`. The same renderer contract
also supports expressive themes without a platform-plugin fork. A future
theme may declare a larger per-role canvas, sequential `00.png`, `01.png`, …
frames, a frame count, and a frame duration; Wayland and Flutter cursor names
continue to resolve through the same semantic roles.

| Denial role | Upstream cursor | Hotspot |
| --- | --- | --- |
| `normal` | `left_ptr` | 6, 2 |
| `help` | `question_arrow` | 5, 10 |
| `working` | `left_ptr_watch` | 6, 2 |
| `text` | `xterm` | 16, 16 |
| `link` | `hand2` | 14, 2 |
| `busy` | `wait` | 16, 16 |
| `precision` | `crosshair` | 16, 16 |
| `handwriting` | `pencil` | 5, 26 |
| `unavailable` | `crossed_circle` | 16, 16 |
| `vertical_resize` | `sb_v_double_arrow` | 16, 16 |
| `horizontal_resize` | `sb_h_double_arrow` | 16, 16 |
| `diagonal_nwse` | `bd_double_arrow` | 16, 16 |
| `diagonal_nesw` | `fd_double_arrow` | 16, 16 |
| `move` | `move` | 16, 16 |
| `alternate` | `dnd-link` | 12, 8 |
| `person` | Windows `Person.cur` | 4, 1 |
| `pin` | Windows `Pin.cur` | 4, 1 |

The exact imported files are recorded in
`dart_shell/assets/cursors/bibata_modern_ice.sha256`. Reproduce the import with
`tools/import-bibata-cursor` and the two release artifacts named above. The
script verifies both archives before extracting the frames.

The corresponding upstream source archive is retained at
`third_party/bibata/Bibata_Cursor-v2.0.7-source.tar.gz`. It is the GitHub source
snapshot for the pinned tag commit and has SHA-256
`a7aa077fd573956bc26aa889637164ce84d876df86d34076508a7fb1ef0bec86`.

Upstream also credits
[Wedge Loading Animation](https://loading.io/spinner/wedges/-pie-wedge-pizza-circle-round-rotate),
[Adwaita](https://github.com/GNOME/adwaita-icon-theme),
[DMZ](https://github.com/GalliumOS/dmz-cursor-theme), and
[Yaru](https://github.com/ubuntu/yaru).
