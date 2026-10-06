# Tray icon replacement plan

Denial should support a curated built-in tray icon pack and a user-owned icon
pack through one deterministic resolver. Adding a correctly named SVG must be
enough to activate a replacement; neither pack should require a runtime
manifest or an application-specific code path.

The system must preserve dynamic tray state. In particular, an application
that publishes a different unnamed pixmap for each state must be replaceable
one pixmap at a time without Denial knowing what the application or state
means.

## Goals

- Give Denial a coherent, curated set of tray icons.
- Let users override any built-in replacement from an XDG data directory.
- Detect added, changed, and removed user SVGs without restarting Denial.
- Match named icons, exact rendered pixmaps, and deliberate whole-application
  overrides.
- Preserve application-provided dynamic states unless a replacement exists
  for that exact state.
- Provide `denialctl` diagnostics that print the exact replacement filename.
- Keep icon discovery and rendering off the Flutter UI isolate where practical.
- Fall back safely when a file is absent, malformed, unreadable, or removed.

## Non-goals

- Do not replace the user's freedesktop icon theme or write into
  `/usr/share/icons`.
- Do not infer semantic state such as a language, synchronization phase, or
  network condition from image contents.
- Do not add fcitx-, QQ-, Telegram-, or other application-specific adapters.
- Do not use fuzzy or perceptual matching in the first implementation.
- Do not require user icons to carry redistribution metadata. Denial's bundled
  icons still require attribution and compatible licences.
- Do not capture screenshots or perform automated visual judgement. The user
  owns visual validation.

## Pack locations

Denial owns two primary packs with identical filename rules:

1. User pack:

   ```text
   $XDG_DATA_HOME/denial/tray-icons/
   ```

   When `XDG_DATA_HOME` is unset, this resolves to:

   ```text
   ~/.local/share/denial/tray-icons/
   ```

2. Built-in pack:

   ```text
   dart_shell/assets/icons/tray/
   ```

   This directory is declared once in `dart_shell/pubspec.yaml` and is shipped
   in the Flutter asset bundle. Adding a file to it must not require editing a
   Dart source list.

Both directories are flat. Subdirectories are ignored so asset enumeration,
watching, collision detection, and error reporting remain predictable.

The user directory contains data assets rather than preferences, so it belongs
under `XDG_DATA_HOME`, not `XDG_CONFIG_HOME`. Denial may create the directory
when its tray service starts. Failure to create or watch it must not prevent
the tray from operating.

## Filename standard

The initial implementation accepts lowercase `.svg` files in these forms:

```text
name--<canonical-icon-name>.svg
pixmap--<sha256>.svg
app--<canonical-application-id>.svg
xembed--<canonical-wm-class>.svg
```

Examples:

```text
name--nm-vpn-active.svg
pixmap--a93f52d71cb8069f2f495a031f730fa19293ddfd2837c938b429b168013fe812.svg
app--qq.svg
xembed--steam.svg
```

The double hyphen separates the namespace from an identifier that may itself
contain ordinary hyphens.

Canonical textual identifiers are produced as follows:

1. Trim surrounding whitespace and remove one supported image extension.
2. Convert ASCII letters to lowercase.
3. Preserve `a-z`, `0-9`, `.`, `_`, and `-`.
4. Replace each run of other characters with one `-`.
5. Remove leading and trailing separators.
6. Reject an empty result.

Put this algorithm in one tested helper rather than reproducing it in each
resolver. The validator must reject two files whose names canonicalize to the
same key.

### Namespace meanings

`name`

: Matches `IconName` or `AttentionIconName` from StatusNotifier. This is the
  preferred semantic match because applications commonly change the name when
  their state changes.

`pixmap`

: Matches the exact normalized pixels Denial would render. It is the generic
  state-preserving solution for applications that publish an empty icon name
  and change only `IconPixmap`. Each distinct source image receives a distinct
  replacement without application-specific knowledge.

`app`

: Deliberately replaces every otherwise-unmatched state for a stable
  application identity. StatusNotifier's reported `Id` is the first identity
  candidate. Generic process, desktop-entry, and well-known-bus identities may
  be added as additional candidates when they can be established reliably.
  `denialctl` must print the exact candidates Denial is using. A user who wants
  to preserve dynamic states should prefer `name` or `pixmap`.

`xembed`

: Matches the canonical X11 `WM_CLASS` for legacy XEmbed tray clients. Extend
  the native XEmbed snapshot and wire model to retain the class and instance;
  do not match a transient X11 window ID or localized window title.

## Pixmap fingerprint contract

Use the full lowercase hexadecimal SHA-256 digest. It is 32 bytes internally
and 64 characters in a filename.

The versioned preimage is:

```text
ASCII("denial-tray-pixmap-v1\0")
+ width as unsigned 32-bit big-endian
+ height as unsigned 32-bit big-endian
+ width * height * 4 premultiplied RGBA8888 bytes in row-major order
```

Hash the same `SystemTrayIconPixmap` Denial passes to `RawImage`, after the
existing StatusNotifier candidate selection, size limiting, channel conversion,
and premultiplication. Do not hash raw D-Bus ARGB bytes or a PNG encoding.

For XEmbed, hash the validated premultiplied RGBA snapshot delivered to the
Flutter shell using the same function. If XEmbed and StatusNotifier produce the
same normalized dimensions and pixels, they intentionally receive the same
fingerprint.

An exact cryptographic match is preferable to perceptual matching:

- it cannot silently map two similar but semantically different states;
- it has no threshold to tune;
- an application update that changes pixels safely falls back to the original
  icon until the new fingerprint is curated;
- light and dark source variants may be mapped independently.

Store the computed fingerprint on the pixmap model or cache it by immutable
pixmap identity so rebuilds do not repeatedly hash the same bytes.

## Resolver precedence

The user pack is authoritative over the built-in pack. Resolve root-first, then
candidate-first:

```text
for pack in [user, built-in]:
    name match
    pixmap fingerprint match
    application match
    XEmbed class match

application-provided named icon
application-provided pixmap
generic Denial fallback
```

Root-first lookup is intentional. A user may use `app--qq.svg` to replace all
QQ states even if Denial ships a more specific pixmap replacement. A user who
wants only one state replaced uses its `pixmap--<sha256>.svg` instead.

Invalid or unreadable user files do not shadow a valid built-in match. Log the
rejection, omit the invalid entry from the user index, and continue resolving.
Removing a user file immediately reveals the built-in or application fallback.

The existing freedesktop icon-theme resolution remains the application-icon
fallback and must continue to run outside the UI isolate.

## Runtime design

Introduce a tray-specific override layer rather than extending
`AppIconImage` with more implicit path meanings.

Suggested types:

```dart
enum TrayIconOverrideKind { name, pixmap, application, xembed }

sealed class ResolvedTrayIcon {
  const ResolvedTrayIcon();
}

final class BundledTrayIcon extends ResolvedTrayIcon {
  const BundledTrayIcon(this.assetKey);
  final String assetKey;
}

final class UserTrayIcon extends ResolvedTrayIcon {
  const UserTrayIcon(this.path);
  final String path;
}

final class ExternalTrayIcon extends ResolvedTrayIcon {
  const ExternalTrayIcon(this.path);
  final String path;
}

final class PixmapTrayIcon extends ResolvedTrayIcon {
  const PixmapTrayIcon(this.pixmap);
  final SystemTrayIconPixmap pixmap;
}
```

Add a `TrayIconImage` widget that renders each typed source. Bundled SVGs use
the Flutter asset bundle, while user and external SVGs use validated file
paths. Symbolic SVGs receive the system bar's semantic foreground through
`currentColor`; do not reuse the launcher's blue application-fallback colour.
The existing item semantics, attention indicator, passive opacity, hit target,
and menu behavior remain unchanged.

Load the built-in catalogue once from Flutter's asset manifest. Scan and watch
the user directory in a background worker. Publish an immutable catalogue plus
a monotonically increasing generation to Riverpod. A generation change must
invalidate both positive and negative resolution-cache entries.

Keep all filesystem enumeration, stat calls, and file validation out of widget
build methods. Rendering a resolved file may use Flutter's normal image and SVG
caches.

## Live user-pack updates

Watch the user directory for create, modify, move, and delete events. Some
editors save by writing a temporary file and renaming it, so treat every event
as a reason to rebuild the affected directory index rather than assuming an
in-place write.

The watcher must:

- debounce bursts for approximately 100 milliseconds;
- build a complete replacement index before publishing it;
- retain the previous valid index if the directory cannot be scanned;
- reject incomplete or invalid files without disturbing other entries;
- invalidate cached misses as well as cached matches;
- recover if the watched directory is deleted and recreated;
- stop cleanly when its Riverpod owner is disposed.

Atomic replacement is the recommended user workflow. A partially written SVG
must never replace a valid current icon.

## SVG contract and validation

Bundled replacements should normally be symbolic icons:

- `viewBox="0 0 24 24"`;
- designed for Denial's current 18-logical-pixel tray rendering area;
- transparent background and approximately a two-unit optical margin;
- `currentColor` for symbolic foregrounds;
- no scripts, event handlers, external references, embedded fonts, or embedded
  raster images;
- no network or file access;
- bounded file size and XML complexity;
- full-colour artwork only when colour is necessary to preserve identity or
  state.

Apply the same safety checks to user SVGs, but user files do not need to match
the symbolic style. Establish explicit limits before implementation; a
reasonable initial maximum is 256 KiB per file and 1,024 indexed files per
pack. Only regular files are indexed. Do not follow symlinks while scanning.

Add a repository validator for the built-in pack. It must check filename
grammar, canonical-key collisions, SVG safety, the 24-by-24 symbolic contract,
size limits, and attribution coverage. Use the same parser and canonicalization
rules as the runtime wherever possible.

## `denialctl` interface

Add these read-only commands:

```sh
denialctl tray paths
denialctl tray fingerprints
denialctl tray validate
```

`denialctl tray paths` prints the resolved user directory and states that the
built-in pack is embedded.

`denialctl tray fingerprints` lists every live tray item with enough context to
choose a replacement:

```text
APPLICATION  TITLE         SIZE   REPLACEMENT
fcitx        Input Method  32x32  pixmap--<full-sha256>.svg
qq           QQ            32x32  pixmap--<full-sha256>.svg
```

It must print the exact complete filename, never an abbreviated digest. Human
output may additionally show the reported icon name and application identity
candidates.

`denialctl tray validate` validates the current user pack and returns nonzero
when any candidate is invalid. Report every error in one run.

All three commands support the existing global `--json` option. Define stable
JSON fields before implementation, including:

```json
{
  "items": [
    {
      "source": "status_notifier",
      "title": "Input Method",
      "application_ids": ["fcitx"],
      "icon_name": null,
      "pixmap": {
        "width": 32,
        "height": 32,
        "sha256": "...",
        "replacement": "pixmap--....svg"
      },
      "resolved_from": "application_pixmap"
    }
  ]
}
```

The control command must not synchronously depend on a responsive Flutter UI.
Have Flutter publish a bounded tray-diagnostics snapshot when tray state
changes; retain the latest snapshot in `deniald` and expose it through a new
read-only control method such as `tray.icons.get`. An unavailable or stale
snapshot is reported explicitly rather than making `denialctl` wait on
Flutter. Native XEmbed state can be merged into the snapshot in `deniald`.

This requires a bounded wire message containing metadata and fingerprints, not
pixmap bytes. Update the FlatBuffers schema and regenerate its committed Rust
and Dart bindings through the repository's normal generator.

A later, separately reviewed command may export reference PNGs. It is not
required for the first milestone because it introduces file-writing behavior
and potentially large control payloads.

## Built-in pack and attribution

The built-in directory uses the same automatic filename mapping as the user
directory. Runtime matching must not depend on its attribution file.

Maintain machine-checkable attribution for every distributed icon, recording:

- file name;
- source URL or an explicit statement that it is original Denial artwork;
- author and copyright notice;
- SPDX licence identifier;
- whether the artwork was modified.

The build validator fails if a bundled icon lacks attribution or uses an
unapproved licence. User-pack files are outside this check because Denial does
not distribute them.

## Packaging

- Add the built-in tray directory to `dart_shell/pubspec.yaml` once.
- Rely on the existing Flutter asset-bundle copy performed by Denial packaging;
  do not add a second installed copy under `/usr/share`.
- Extend package validation to assert that a known fixture icon and the asset
  manifest entry survive staging.
- Install any built-in attribution document with Denial's other licences and
  asset documentation.
- Do not package or modify the user's XDG tray-icon directory.

## Implementation sequence

### 1. Pure identity helpers

- [ ] Implement and test textual-key canonicalization.
- [ ] Implement and test the versioned pixmap fingerprint.
- [ ] Add the fingerprint to the immutable tray pixmap/model path.
- [ ] Add golden digest fixtures shared by Dart and Rust tests.

### 2. Override catalogue

- [ ] Add the built-in asset directory and one non-production fixture icon.
- [ ] Parse built-in asset names into an immutable catalogue.
- [ ] Resolve the XDG user directory through `RuntimePaths`.
- [ ] Implement bounded user-directory scanning and SVG validation.
- [ ] Implement root-first and candidate-first precedence.
- [ ] Return a typed resolved source rather than overloading nullable paths.

### 3. Rendering

- [ ] Add `TrayIconImage` with bundled-asset, local-file, external-file, and
      raw-pixmap branches.
- [ ] Use the semantic system-bar foreground for symbolic `currentColor`.
- [ ] Preserve semantics, passive opacity, attention state, and repaint
      boundaries.
- [ ] Verify that a missing or invalid replacement returns to the existing
      application icon without a blank frame.

### 4. Live updates

- [ ] Add the background watcher and debounce.
- [ ] Publish atomic catalogue generations.
- [ ] Invalidate positive and negative resolver caches.
- [ ] Cover create, atomic replace, delete, directory recreation, and malformed
      intermediate-file cases.

### 5. Stable application and XEmbed identity

- [ ] Preserve StatusNotifier's reported `Id` independently from the display
      title and transient registration address.
- [ ] Add only generic, explainable application-identity candidates.
- [ ] Read XEmbed `WM_CLASS` class and instance values.
- [ ] Extend the XEmbed wire payload and Dart model with bounded identity
      strings.
- [ ] Print every canonical candidate in diagnostics.

### 6. Diagnostics and CLI

- [ ] Add the bounded Flutter-to-native tray diagnostics snapshot.
- [ ] Add `tray.icons.get` to the native control protocol.
- [ ] Add `tray paths`, `tray fingerprints`, and `tray validate` parsing,
      human output, and JSON output to `denialctl`.
- [ ] Update `docs/DENIALCTL.md`, `docs/protocol/control-v1.md`, and the
      `denialctl(1)` manual.

### 7. Repository and package validation

- [ ] Add the built-in SVG and attribution validator.
- [ ] Run it in the normal build/test path.
- [ ] Verify staged Flutter assets contain the built-in pack.
- [ ] Add contributor documentation with the filename and artwork contracts.

## Test plan

Unit tests must cover:

- exact fingerprint goldens, including width and height changes;
- textual canonicalization and collision rejection;
- named-icon, pixmap, application, and XEmbed candidates;
- user-over-built-in precedence;
- invalid-user-file fallthrough to a valid built-in icon;
- built-in and user fallthrough to the original application icon;
- two unnamed pixmaps from one application resolving to different icons;
- a changed pixmap with no mapping falling back instead of reusing stale state;
- StatusNotifier `NewIcon` invalidating the fingerprint and resolution;
- user-file create, replace, delete, and directory recreation;
- resolver-cache invalidation, including previous misses;
- SVG size, type, path, symlink, and external-resource rejection;
- bounded catalogues and bounded diagnostics snapshots;
- human and JSON `denialctl` output;
- Dart and Rust agreement on the fingerprint fixture.

Widget tests should verify source switching and unchanged semantics without
judging appearance. The user performs visual validation after a development
build; agents must not capture or inspect screenshots or trigger visible test
events.

Run targeted Flutter tests only through:

```sh
tools/denial-pc flutter-test <test paths or arguments>
```

Run the complete compositor and Flutter suite with:

```sh
tools/denial-pc test
```

All `tools/denial-pc` invocations run outside the sandbox as required by the
repository workflow.

## Completion criteria

The first milestone is complete when:

- adding a valid SVG to the user directory changes a matching live tray icon
  without a Denial restart;
- replacing or deleting that SVG updates or restores the fallback immediately;
- user files override built-in files deterministically;
- built-in files require no Dart registration entry;
- an unnamed dynamic pixmap can be replaced per exact state with no
  application-specific code;
- `denialctl tray fingerprints` prints the exact full filename for each live
  pixmap;
- invalid SVGs cannot blank the tray or shadow valid fallbacks;
- packaged builds contain the curated icon pack and its attribution;
- the complete Denial test suite passes;
- the user accepts the rendered icons through their own visual validation.
