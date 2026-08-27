# Cursor surfaces and cursor-theme plan

Status: implemented; Wayland and Xwayland client cursors and imported animated
themes have been accepted in manual development-host testing.

## Outcome and invariants

- Keep every cursor software-composited by Flutter into Denial's primary-plane
  frame. Never introduce a DRM hardware-cursor plane or a second cursor
  renderer.
- Preserve the existing themed cursor path, including animated frame playback,
  Bibata, cursor sizing, semantic shape mapping, drag icons, and touch hiding.
- Add client-owned Wayland cursor surfaces. Xwayland uses this same path because
  it translates X11 cursors into `wl_pointer.set_cursor` surfaces.
- Add `allowClientCursorSurfaces` to appearance settings, defaulting to `true`.
  It gates only client-owned surface artwork; named cursor shapes continue to
  select roles from the user's chosen Denial theme. When disabled, a client's
  surface request falls back to the selected theme's normal role.

## Import source and storage

Use `/home/logix/Scaricati/Windows  YangyangXuanling- BLZ.zip` as the development
fixture. It is the complete animated source: `install.inf` maps all 17 roles and
each `.ani` contains 12 frames. The Sticker ZIP lacks roles, Static is not
animated, and Mac uses a less suitable nested format.

Yangyang is a local import fixture only. Its readme prohibits redistribution,
so do not commit its frames, archive, or derived files. Keep the existing
gitignore rule and never package it.

- Import ZIPs into `$XDG_DATA_HOME/denial/cursors/<content-hash>/` with a
  versioned `theme.json` and normalized PNG frames. Reject traversal, links,
  oversized archives/images, duplicate roles, unsupported formats, and themes
  without a normal cursor. Write through a temporary directory and atomically
  rename only after complete validation.
- Initially accept Windows cursor-theme ZIPs containing `.ani` files plus
  `install.inf`; parse RIFF/ACON frame order, per-frame rates, dimensions,
  hotspots, transparency, and role mapping. The persisted Denial manifest is
  platform-neutral and is the future extension point for other import formats.
- Discover bundled and imported manifests at startup. Remember imports across
  restarts; settings store only the selected stable theme ID and the client
  cursor switch, not archive paths.

## Settings integration

- Expand Appearance > Cursor into a selector with cards for bundled Bibata and
  every imported theme. Each card previews the main states (normal, link,
  text, working/busy) with their real animation, isolated by
  `RepaintBoundary`. Keep the size slider.
- Add **Import cursor ZIP**. The standalone GTK settings runner opens a ZIP-only
  file chooser through its existing method-channel boundary, then the Dart
  importer validates and installs the selected archive. Show progress and a
  concise error; refresh the catalog and select the successful import.
- Add **Allow applications to show their own cursor**, enabled by default, with
  explanatory text that it applies to both Wayland and X11 applications.
- Add a remove action for imported themes. Do not remove the active theme until
  selection has atomically fallen back to Bibata. Bundled themes cannot be
  removed.

## Keep and extend animated cursors

- Generalize `ShellCursorRoleData` from one `frameDuration` to ordered frame
  records with individual durations and hotspots. Preserve the existing
  `frameCount`/fixed-duration behavior as the bundled-theme compatibility path.
- Load bundled frames with `AssetImage` and imported frames with `FileImage`
  behind one theme-frame abstraction. Continue precaching, `gaplessPlayback`,
  `FilterQuality.none`, output-aware physical sizing, hotspot scaling, and the
  retained translation used by `ShellCursorHost`.
- Replace the fixed periodic timer with rescheduling based on the active
  frame's duration (or an equivalent elapsed-time controller). Reset playback
  on role/theme changes and stop it while hidden, but never discard imported
  theme state when a client cursor temporarily overrides it.
- Cursor rendering has one atomic priority decision:
  hidden/touch policy, then drag policy, then an allowed client surface, else
  the selected themed role. Never draw a themed cursor and a client cursor in
  the same frame. When focus returns from a client, resume the selected
  animated theme immediately.

## Wayland and Xwayland surface integration

- Replace the shape-only wire update with an appended atomic `CursorState`:
  hidden, named, or surface tree with logical hotspot and existing
  `SurfaceLayer` records. Keep cursor position as its separate fast stream.
- Retain Smithay's exact `CursorImageStatus::Surface`; reuse Denial's current
  SHM/DMA-BUF snapshot, damage, transform, scale, viewport, fence, and external
  texture pipeline for the complete cursor surface/subsurface tree. A surface
  with no attached buffer renders nothing, not a default arrow.
- On cursor commits, apply root `buffer_delta` to the hotspot, publish
  metadata only when geometry changes, and use texture-only updates for frame
  changes. Send cursor-tree frame callbacks so native Wayland and Xwayland
  animated cursors advance correctly.
- Track cursor output enter/leave, preferred fractional scale, and repaint
  membership as the hotspot crosses outputs. Replay active cursor state after
  a Flutter-engine restart.
- Maintain active and retired cursor texture IDs separately from window scene
  IDs. Register sources before publishing state; unregister old textures only
  after Flutter acknowledges a post-frame cursor epoch, preventing sampling of
  a released texture during rapid switches.

## Minimal core verification

- Rust: cursor-state wire round trip; surface/named/hidden arbitration and the
  default-enabled setting; hotspot plus `buffer_delta`; frame-callback and
  texture-retirement behavior.
- Dart: `.ani` fixture parser/validation and manifest persistence; per-frame
  timing; renderer priority proving exactly one of imported theme or client
  surface is visible.
- One native Wayland integration client and one X11 animated-cursor client,
  including the disabled-switch fallback. Confirm DRM commits still use only
  the primary plane.

Do not add broad UI or golden tests; cover only these core contracts.
