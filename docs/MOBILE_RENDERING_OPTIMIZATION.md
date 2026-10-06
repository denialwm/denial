# Mobile rendering optimization, 2026-09-07

Target: Moto Edge 70 (`roadstr`). The reported stress case is swiping home
pages full of icons; the optimization also targets shared rendering work.

## Shared GLES command submission

The canonical Flutter fork's `impeller/renderer/backend/gles/render_pass_gles.cc`
already avoids repeated blend, depth, stencil and culling configuration.
Viewport, scissor and shader program setup previously still reached GLES on
each draw that supplied them. Rebinding a program also required another
reactor handle lookup.

The experimental `RenderPassStateGLES` retains those three settings only for
one uninterrupted render pass, after `ResetGLState`. Every new pass initializes
its state independently, including offscreen passes and successive frames.
Uniform and vertex buffer binding still runs for every draw. This applies to
all scenes using the Impeller GLES backend, including home, shade, recents,
notifications and application transitions.

Changed viewport rectangles and depth ranges are applied independently.
Returning to a command's default viewport restores the render target viewport;
an unclipped command disables the preceding scissor. Program identity uses the
reactor handle rather than a pipeline pointer, since pipeline variants can
share a shader program.

The headless driver-call test sends 100 identical sets of state through each
of two passes. Each pass emits one viewport call, one depth-range call, one
scissor enable, one scissor rectangle and one shader bind. Separate tests
verify changed state order, depth-free passes and dead-program rejection.
These counts verify eliminated work, not a measured phone frame-time gain.

## Shared SVG app icons

`AppIconImage` now uses `RenderingStrategy.raster` for SVG files and the bundled
fallback. Under the pinned engine, `GPUSurfaceGLImpeller::EnableRasterCache`
returns false: retaining a Flutter paint layer alone still replays its vector
draws. Explicit SVG rasters replace repeated path, clip and gradient work with
an image draw at the requested physical size.

The existing `vector_graphics` dependency becomes direct without a version
upgrade. Its live raster cache shares equal asset/size entries and releases an
entry when the last consumer is disposed. Color/theme is part of the SVG
loader's asset key. PNG and other bitmap icon handling is unchanged.

The resource-lifetime test checks sharing between two mounted icons, no new
image allocation during translation, retention after removing one consumer,
replacement after a device-pixel-ratio change, and disposal after unmounting.
It does not capture or inspect rendered pixels.

## Dart mobile scene work

The second pass traces the Dart paths separately from GPU command submission.
Retaining a raster or display list cannot compensate for rebuilding and laying
out a live application on every animation frame.

| Path | Previous repeated work | Change |
| --- | --- | --- |
| Home page boundary | `HomeSurface` watched the entire grid state, rebuilding the visible page widgets when only `page` changed | Select slots/loading/error/drag state separately; only the page dots watch the current page |
| Horizontal app switch | `adjacentOpenAppWindow` scanned the window snapshot on each gesture/provider update | Index the filtered app order when a new window snapshot arrives and share that index across gesture copies |
| Switch start/cancel/commit | Entering the switch inserted a `LayoutBuilder`/`Stack` above the current surface; promoting the target also lost its parent identity | Keep the parent chain fixed and key the direct Stack children by object ID, retaining both the current and promoted surface |
| Cold launch | `AnimatedBuilder` reconstructed the launch hierarchy and `Positioned.fromRect` resized live content every frame | Lay out the app at its final size; retained clip/transform and render-object fades handle zoom/reveal; the icon keeps its logical size |
| Landscape overview entry | One animated widget builder per card per frame | Drive each retained render translation directly from the shared animation, preserving the stagger curve |
| Empty overview entry | Reconstructed the translated/faded text tree each frame | Retained translation and render-object opacity |
| Software keyboard | Rebuilt the panel hierarchy on each spring tick and remounted the keyboard on each open | Retain the sheet and keys, update translation directly, rebuild only at visibility/scroll-strip thresholds |
| Keyboard viewport pan | Provider updates rebuilt `MobileKeyboardViewport` and its layout builder | A provider listener updates a retained render translation; layout changes still recompute the keyboard height |

`RetainedScale` provides the same no-widget-build path for scale as
`RetainedTranslation` does for translation. Flutter's `ScaleTransition` and
`SlideTransition` in the pinned framework are animated widgets; replacing a
local `AnimatedBuilder` with those would still build transforms on every tick.
`FadeTransition`, by contrast, updates render opacity directly.

The retained window-motion render object skips unchanged configurations,
evaluates its interpolated rect only once per paint, supports an unscaled
overlay inside the moving clip, and applies that clip to hit testing as well.
Geometry is still resolved from current ancestors when global launcher bounds
are used; it is not cached across unrelated ancestor movement.

Keeping the keyboard mounted has a bounded memory cost: its widget/render tree
survives close. Its hidden subtree has tickers disabled, releases held native
keys, clears the glow, and resets keyboard layer/modifiers. Closing it must not
leave a repeat key or hidden animation running. There is no additional bitmap
snapshot cache for live applications in this pass.

Regression coverage includes a 1000-window snapshot over 1200 gesture updates;
60-frame overview, cold-launch, keyboard and retained-transform sequences;
home page/content updates; app-switch cancellation and target promotion; and
held-key release when a retained keyboard becomes inactive. These are headless
checks of work counts, lifecycle and geometry, not screenshots or phone frame
timings.

The new checks pass with these bounds:

| Headless sequence | Observed result |
| --- | --- |
| 1000-window snapshot, 1200 gesture updates and neighbor lookups | Zero reads of the original window list after indexing |
| 30 landscape previews, 60 progress updates | Zero widget builds; preview positions change |
| Cold launch with a window arriving during zoom, 60 subsequent pumps | Zero widget builds; the app retains 400×800 layout and the icon retains its logical size |
| Keyboard slide and viewport pan, 60 updates between phase thresholds | Zero builds inside either UI subtree; keyboard identity and viewport displacement are preserved |
| Retained scale/window-motion probes, 60 updates | Child layout and paint counts stay at their initial values |
| Switch start, cancel, and target promotion | Existing surface elements survive; idle translation returns to zero |
| Home with 100 installed app entries | Page notifications retain the PageView and mounted grid widgets; dots and later content edits still update |

Riverpod still flushes provider notifications through its root scope on state
updates. The keyboard count specifically measures the UI subtrees below that
scheduler. These assertions do not mean the entire Flutter frame has zero CPU
or GPU work.

For future mobile features, distinguish continuous motion from structural
state. Keep drag/progress listeners at the render boundary, select only the
fields that change a widget's content, and keep live app constraints and keyed
ancestors stable during movement. Add a frame-sequence regression when a new
transition contains many children. A paint-only path can still be limited by
GPU fill, backdrop sampling, rasterization or texture bandwidth; those require
device traces rather than conclusions from widget-build counts.

## Validation and rollout

The engine experiment is committed in the canonical Flutter fork as
`fc5e119c550ce86d5cafec6d273eab9f85127d31` (`Avoid redundant GLES viewport,
scissor and program updates`). The fork worktree is clean.

Validation completed:

- 12 selected headless GLES tests, including the three new state-cache tests.
- 42 targeted Flutter tests covering launcher, window indexing, SVG resources,
  launches, retained motion, keyboard, overview and shade. The consolidated
  passing run is recorded in `/tmp/denial-dart-mobile-final-tests.log`.
- Static analysis of all Dart files changed in this pass, plus the final test
  fixture changes; `git diff --check` passes.

The Dart suite runs through `tools/denial-pc flutter-test`. This pass reused the
clean, detached, lock-pinned Flutter projection already prepared by another
build, with both source-root overrides set together. An empty `LUCI_CONTEXT`
selects HEAD-based content hashing for that detached projection; otherwise
Flutter's development-branch hash logic selects its upstream merge base and
fails the expected GN-arguments check. The experimental canonical Flutter
branch and Denial source lock were left at their existing commits.

The cache test initially found that the SVG raster strategy used intrinsic
dimensions when width/height were omitted. Explicit layout dimensions fix
that: the 85-logical-pixel square test icon now allocates 170×170 at DPR 2 and
255×255 at DPR 3. Translation creates no new raster images.

`SOURCE_LOCK.json` remains pinned to Flutter `9f9691d29cc14310d68f77445a7f2f15f97c5847`.
The engine experiment must be accepted before advancing the source lock or
refreshing release metadata. Any workstation candidate is built only through
`tools/denial-pc engine-test-build` and checked without starting a session.

The check command previously filtered for a missing
`loads_the_bundled_flutter_engine_abi` test. The new explicit `bundle_abi`
integration test loads all required Flutter/Denial entry points and creates
and releases AOT data. It is ignored by ordinary unit-test runs and explicitly
selected by `engine-test-check`, which requires the isolated bundle path.
It does not run a Flutter engine or prove full Dart runtime compatibility.

The isolated x64 candidate was built, verified, and left inactive at:

```
~/.cache/denial/engine-test/mobile-render-state/fc5e119c550ce86d5cafec6d273eab9f85127d31-32358b4f788b0db9/bundle
```

Engine SHA-256:
`32358b4f788b0db9f6e987262d47232ff658b2fb305f8392ddf39aec9a21d820`.
The retained baseline shell AOT SHA-256 is
`534ec436a3bc608906847885d840d2b40dc8a0794bf3ce66fa1043d6b999bad9`;
this engine-only candidate does not include the new Dart icon change.
The explicit ABI/AOT test ran one test and passed. A separate temporary bundle
with a deliberately invalid AOT ELF was rejected as expected.

The current checkout's normal bundle contained a different engine from the
tracked pinned checksum. A private copy of that shell bundle, paired with the
verified pinned engine, supplied the test builder's baseline. Neither the
original bundle nor the global one-shot engine selection was modified.

### Moto Edge 70 installation (2026-09-08)

The current Denial and Dart worktree snapshot was cross-built and installed on
`roadstr` using the device workspace's SSH key. Build inputs, immutable package,
hashes, build commands and activation evidence are retained under
`/mnt/development/moto70edge/build/denial-mobile-20260908`.

The installed candidate is `mobile-20260908-60605d9abd`, based on Denial commit
`2fd1753deaffd098be6d92e6ab564d166262bbeb` plus the captured working changes.
Its source snapshot SHA-256 is
`60605d9abd2599de7462da3acb386a303e5c7e77656581c3ac1114296ef81790`.
The ARM64 release engine, framework and shell AOT use the locked Flutter
`9f9691d29cc14310d68f77445a7f2f15f97c5847`; AOT was generated by that ARM64
engine build's host snapshot compiler. The experimental GLES commit `fc5e119`
remains inactive, and the source lock is unchanged.

The device's explicit ABI/AOT loader test passed before activation. Both
native dependency checks passed without missing libraries or unresolved
symbols. The mandatory reboot gate independently verified all 247 boot-critical
files against the installed `init_boot_b` manifest before rebooting.

After reboot, `denial-moto70.service` was active with PID 1066 on boot
`1827d73c-ae5c-46f8-854a-71d92a7954cd`. Its running executable hash matches
the package; its process maps contain the engine and AOT from the same
candidate directory. All 40 packaged files passed their SHA-256 checks.
Flutter started with Impeller OpenGLES without a snapshot compatibility error,
and no systemd services were failed. The hardware, refresh, memory, battery
and Wi-Fi services were active.

Selection is controlled by `99-moto70-mobile-ui.conf` under the service's
drop-in directory. The previous `power-lock1` candidate is retained for
rollback. On-device CPU/raster/GPU and presentation measurements remain
pending; installation and headless checks establish compatibility, not a
speedup percentage. The user owns visual validation and interactive tests.

### Recents interaction follow-up (2026-09-08)

Native activation events no longer dismiss an open recents view. A native
client closing can activate a surviving window before or after its removal
snapshot; both orderings now leave the carousel in control of presentation.
The existing retained reflow moves surviving cards into the gap. Selecting a
card still focuses it, and dismissing the final card returns home.

When a foreground app enters portrait recents, its older neighbor starts just
outside the physical left edge. Its travel is the exposed preview edge rather
than a full screen width: on a 400-pixel-wide view with a 280-pixel card and
16-pixel gap, this is 44 pixels instead of 400. Previously the neighbor stayed
off-screen until roughly 89% progress. It now enters from the first part of
the drag and remains tied directly to the foreground transition through the
existing retained translation. Home entry retains its full carousel slide.

The same upward flick threshold now opens recents from home and sends the
foreground app home. Long pulls and cancelled drags retain their behavior.

All 37 targeted tests pass through `tools/denial-pc flutter-test`, covering
the new controller/gesture interactions, carousel entry and removal, retained
window motion, keyboard and landscape previews. The early-entry sequence
checks continuously advancing preview positions with zero widget rebuilds;
release into recents preserves the current position. Static analysis of the
changed production and test files passes. No visual QA was performed.

The follow-up package and installation evidence are retained under
`/mnt/development/moto70edge/build/denial-recents-20260908`. It reuses the
verified installed ARM64 compositor, engine and ICU; native source hashes and
the engine's AOT compiler hashes are unchanged in the package. Native source
provenance comes from the retained installed snapshot because concurrent
CPU-scheduling work changed the checkout's native inputs during this pass.
After USB access returned, `recents-20260908-3aeb801649` passed the on-device
ABI/AOT and dependency checks and was activated through the required reboot
gate (all 247 boot-critical files matched). PID 1065 on boot
`3c78f357-d47a-4f98-be18-17dafd37c578` maps the expected engine and new shell
AOT; its executable and all 40 package file hashes match. No runtime snapshot
compatibility errors were found. The `99-moto70-recents.conf` service drop-in
selects this pair; removing that drop-in and using the gated reboot restores
the retained `mobile-20260908-60605d9abd` candidate.

### Home content fade during recents (2026-09-08)

The launcher now uses the overview controller's actual progress for its
icons, widgets and page indicators: content opacity is `1 - progress`.
Dragging, releasing, cancelling and reversing share that value, so the home
content does not start a separate animation or disappear at a visibility
threshold. The backdrop stays outside the content fade.

`OverviewLayer` publishes continuous progress separately from presentation
phase changes. A `ValueNotifier` feeds `FadeTransition` directly, retaining
the home grid without rebuilding it on animation ticks. Home stays mounted
through recents; its content is not painted at zero opacity. Interaction and
tickers remain disabled until the closing transition completes. Standalone
home surfaces omit the optional fade layer.

Headless regression coverage includes a populated home with a clock and 50
apps, 30 incremental drag frames without home widget rebuilds, release
continuity, cancellation and reversal, and returning home from recents that
was opened over an app. It also checks that home cannot accept taps during
the fade and that the backdrop is outside the animated opacity subtree.

All 41 targeted Flutter tests and static analysis pass. The required test
wrapper recompiled one GLES object and relinked the local debug test engine
when switching back to the locked source revision; the phone's ARM release
engine was reused without recompilation. The ARM shell was assembled using
that engine build's verified host snapshot compiler.

`home-fade-20260908-fefc64872c` was installed through Wi-Fi SSH
`192.168.1.154` and activated by the supported `SIGUSR1` bundle refresh.
The configured bundle directory was atomically exchanged with a symlink to
the new immutable bundle, retaining every previously mapped file. No reboot
or compositor/session restart occurred. PID `1051`, boot ID
`892ef115-620e-4a6e-a528-fa719c75c14d`, and the newer capacity compositor
(`a6929e76638c835aa52845a4e5cedb6d1bb989617a26005c69ad2395063e77ff`)
are unchanged. The runtime reports generation 3, official optimized mode,
idle operation and no runtime error; its 120 Hz output remains enabled.

The mapped shell AOT hash is
`f0958042a384e7a12423b5ae951af75b61d11a828c0579ee420a1ea9dd38bcfd`.
The mapped release engine still has hash
`a47c9728e1a019c07b9203bfa1bc492aac22e6cc448f16eaa3e08e9a97036262`.
All 38 packaged file checks and the device's headless ABI/AOT probe pass.
Evidence and rollback paths are recorded under
`/mnt/development/moto70edge/build/denial-home-fade-20260908`.

The initial service-unit journal query missed the refresh completion because
later compositor messages are indexed outside that unit. Querying `_PID=1051`
found the completion at device time `2026-09-07 23:53:02 UTC`; no second
refresh was sent. Existing embedder backing-store errors occur both before
and after activation. The refresh also logged an EGL context cleanup error,
then created new output targets and completed successfully. These native
renderer diagnostics remain unresolved; no visual validation was performed.
