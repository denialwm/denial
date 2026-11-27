---
name: denial-glass-ui
description: Refactor Denial Flutter apps to the accepted Plugins design: floating neutral glass navigation and commands, a scrolling opaque content sheet, inherited corner geometry, and content-only transitions.
---

# Denial application design contract

## Authority and use

This is the accepted application design established with Plugins on 2026-09-27.
The user approved the result shown in `Screenshot-1790537490-943.png`. That image
was supplied in the conversation; it is not a packaged asset or a required local
file for future agents. The rules below describe the implementation that produced
it. They supersede this document's earlier speculative glass guidance.

Use this contract for the next Denial app refactor. Preserve the target app's
behavior, navigation, keyboard access and settings integration. Reuse the SDK;
do not copy Plugins widgets wholesale or invent another material system.

Read [APPLICATION_MATERIALS.md](APPLICATION_MATERIALS.md) for the SDK contract.
Implementation references, relative to the repository root:

- `packages/denial_flutter_sdk/lib/materials.dart`: public application API.
- `packages/denial_flutter_sdk/lib/src/theme/application_theme.dart`: palette.
- `packages/denial_flutter_sdk/lib/src/theme/application_material_policy.dart`:
  opacity and filter policy.
- `packages/denial_flutter_sdk/lib/src/widgets/application_material.dart`:
  materials, frame, scrolling sheet and footer.
- `packages/denial_flutter_sdk/lib/src/widgets/surface_geometry.dart`: radii.
- `packages/denial_flutter_sdk/lib/src/widgets/content_switcher.dart`: transitions.

A new user instruction may revise the design. Keep this guide and the SDK
contract aligned when that happens. This file does not authorize deployment,
application launches, screenshots, session control or unrelated feature changes.

## Settings and Plugins alignment (2026-09-28)

The user reaffirmed the Plugins composition after the three independent opacity
controls were added, and requested the same layout for Settings. Both apps use
`DenialApplicationFrame` and `DenialContentPane` in their default sheet mode.
Settings titles and descriptions belong on the opaque sheet; commands use small
floating glass groups. Keep Appearance's grouped cards, collapsible controls and
separate shell/window/app-panel opacity settings within that composition. Do not
enable the experimental `separatedCards` layout or move page titles into a full
width glass header for these apps.

Settings → You is a deliberate exception to placing every card below the sheet
edge: its single opaque profile card crosses the glass/content boundary using
`DenialContentPane(leadingOverlap: 80)`, capped by the compact reveal gap. The
card and boundary scroll together. Other Settings tabs retain the default layout.

### Wallpaper presentation

Settings puts Wallpaper first, with a landscape preview and a named image.
Read mapped wallpaper-client status per display. When a live or app-managed
background is present, identify the supplying app and explicitly label the saved
still image and chooser as fallback. Do not display a still image as though it
were a preview of live content. If runtime status is unavailable, say so without
claiming that the desktop is static. The card stacks at narrow widths and large
text scales; it remains on the opaque content material.

## Composition: the desktop participates in the window

### Welcome wizard refinement (2026-09-28)

Welcome uses `DenialApplicationFrame(horizontalNavigation: true)` with inset
floating glass progress across the upper region and `DenialContentPane` for its
scrolling opaque sheet. Its Exit/Previous and Next/Finish controls are ordinary filled
buttons at the bottom corners, without glass wrappers. The step indicator uses
numbered circles with labels underneath, as in the original Welcome design. They overlay the
viewport; there is no permanently reserved footer. Only the end of the scroll
content includes clearance so the last row can be brought above the controls.
Welcome's occasional error notice accompanies those commands on opaque material.
Settings and Plugins retain their existing sidebar and error-footer composition.

Shortcut groups use adaptive two-column rows, with resize and move first, then
desktop essentials, workspaces, and tiling/keyboard controls. Thin horizontal
rules separate concepts. Large text or narrow windows fall back to one column.

Keep donation content neutral and opaque. Show only the Stripe destination for
the active English/Chinese language, alongside Sponsors and the repository link.
Welcome accent fills use a measured contrasting foreground, and its outlined
button text is adjusted when contrast is below 4.5:1. Selected option borders
and checkmarks use the accent. The Stripe action is simply labeled Donate in
the current language. Welcome supplies a default body text style for its sheet;
changing Theme alone does not establish DefaultTextStyle.


Build these layers in this order:

1. A barely opaque backing reveals Denial's desktop through the upper area.
2. An opaque warm charcoal content sheet begins below that area and spans the
   entire client width, continuing underneath the sidebar.
3. An inset glass navigation card spans the upper backdrop and lower content.
4. Small glass command groups float at the top, with visible backdrop between
   groups. Search is one group; related actions share another.
5. Errors and pending-operation controls live at the bottom, on an opaque
   continuation of the content surface.

The main content sheet has no visible inset frame or rounded outer corners.
Only its readable content is reserved to the right of desktop navigation; the
sheet's background really extends behind navigation. Do not recreate a two-column
layout with unrelated left and right background surfaces.

The upper area reveals the real desktop through client alpha. Do not insert a
stock hero photograph, copy the wallpaper, render another client into the app,
or add decorative gradients to demonstrate blur. Denial supplies the backdrop.

The sidebar is a freestanding rounded card, close to the window edges. It must
not become a flat full-height strip attached to the window border. Top actions
must not become an attached full-width toolbar sheet. Page headings belong to
content; they are not another row of unbacked text over the desktop.

This is Denial's design. Keep the material hierarchy and care of the reference;
do not add imitation macOS traffic lights, branding or unrelated imagery.

## Material assignment

Import `package:denial_flutter_sdk/materials.dart` and choose by purpose.

| Surface | SDK role | Backing |
| --- | --- | --- |
| Main content sheet | `content` / `DenialContentPane` | Opaque canvas |
| Content cards, forms and informational groups | `card` | Opaque raised surface |
| Navigation card | `sidebar`, `floating: true` | Neutral glass tint |
| Search, action groups, bottom notice | `toolbar`, `floating: true` | Neutral glass tint |
| Dialogs and popup menus | `dialog`, `popover` / shared Material theme | Opaque raised surface |
| Entire region behind bottom notices | Frame footer backing | Opaque canvas, including padding |

Glass belongs to navigation and commands. Lists, plugin entries, settings forms,
tables and long reading surfaces stay opaque. An ordinary button or switch inside
a material does not receive another blur. Selection, hover and focus use a subtle
fill or normal control treatment within that material.

Group related actions on one glass surface. In Plugins, Add Plugin and its
overflow menu share a group with a short separator. The search field is unfilled
inside its own glass group. Do not give each button an independent glass panel.

Menus stay anchored to the originating control and use grouped, consistent action
names. The implemented menus and dialogs are opaque; do not silently turn them
into glass based on earlier aspirational guidance. Focused tasks need stable
readability. Reserve accent color for actions, selection and status.

## Glass, alpha and shadows

Use Denial's shared material/filter implementation, not an app-local blur recipe.
Client-side filters sample available application pixels. They cannot sample the
desktop behind another Wayland surface. The compositor supplies the desktop glass
where the submitted client pixels are translucent. Over opaque content, the
client-side material samples that content.

The native client must preserve alpha: the Plugins GTK host has an RGBA visual,
a transparent Flutter clear color and no claimed opaque window region.
A client refactor must not accidentally reintroduce an opaque root Scaffold or
native background over the intended revealed area.

The revealed background follows the window-opacity setting, with minimum alpha
**3/255** (approximately **1.2% opacity**). Its RGB follows the neutral glass tint.
This backing covers the full client area underneath other surfaces.

Denial skips glass for fully transparent client pixels. With a zero pixel-alpha
cutoff, even faint shadow pixels receive glass. A zero-alpha background therefore
made soft shadows produce isolated frosted patches surrounded by clear areas.
The accepted fix is to keep the shadows and retain at least 3/255 uniform backing.
The window transparency setting now controls opacity above that coverage floor.
Do not remove shadows to hide that artifact or revert the backing to zero alpha.
A compositor cutoff above the selected backing alpha can leave it unfiltered;
the app must not change the user's cutoff to compensate.

The faint backing is coverage for the existing window composition, not another
full-window client-side blur panel. Do not wrap the whole app in an extra blur,
or stack independent glass surfaces inside the same functional group.

`DenialMaterial` uses `ShellBackdropBlur(separateChild: true)` so foreground text
and controls paint after the filter. Settings and Plugins retain their established
application optical profile and reveal geometry; Welcome refinements must not
change them. Welcome's progress surface opts into `preserveGlassEffects: true`
to inherit the saved refraction, dispersion, edge strength and lighting unchanged.
The native transparency path remains unchanged.

Keep the current shared floating-surface treatment:

| Property | Dark | Light |
| --- | --- | --- |
| Shadow | Black at 0.18 alpha | Black at 0.08 alpha |
| Shadow blur / offset | 24 / `(0, 6)` logical pixels | Same |
| Edge width | 0.75 logical pixels | Same |
| Edge color | Foreground at 0.12 alpha | Foreground at 0.10 alpha |

Shape, clipping, blur bounds, edge and shadow use the same resolved radius.
These values belong in the SDK, not scattered through application widgets.

## Palette and appearance

Use `DenialApplicationTheme.fromShell`, `context.applicationTheme` and
`context.applicationColors`. Do not hardcode these colors in app widgets.

| Token | Dark | Light |
| --- | --- | --- |
| Canvas | `#22211F` | `#F7F6F3` |
| Raised content | `#2C2B29` | `#FFFFFF` |
| Control fill | `#383734` | `#EEECE7` |
| Functional glass tint | **`#000000`** | `#FFFFFF` |
| Foreground | `#F2F1EF` | `#292825` |
| Secondary text | `#BBB9B5` | `#625F59` |
| Separator, ARGB | `0x24B5B2AB` | `0x28625F59` |

The dark canvas is the exact color sampled from the user's reference swatch.
Black glass and warm opaque content are distinct materials. Do not tint the
sidebar and controls with the charcoal/raised-content RGB. Do not restore the
older blue-gray palette or nearly black main content surface.

Preserve the user's accent, font and application light/dark preference. Functional
application overlays currently use stable application appearance. Automatic
per-pixel brightness adaptation, AppKit vibrancy and background extension are
not implemented. Do not promise them or invent wallpaper-driven appearance
switching. The approved screenshot validates the dark composition; light tokens
exist but are not evidence of user acceptance across every background.

In glass mode, **`glass.windowOpacity` controls the application window background**.
**`glass.appPanelOpacity` controls compatible application sidebars and toolbars**.
**`glass.opacity` controls only Denial shell surfaces**, including the launcher,
Dashboard, taskbar and top cards. Sliders display **opacity** directly, increasing
from clear to opaque. Keep all three mappings independent; do not use shell or
window opacity to adjust app-panel tint. Preserve migration from shared opacity
and live updates, including atomic replacement via `FileSystemMoveEvent.destination`.

The window background follows the saved opacity with minimum coverage of 3/255
for the shadow/filter behavior described above. Panel materials have no minimum.
The compositor supplies window-background blur; do not add a whole-window client
filter. Transparency off makes all surfaces opaque. Fully opaque window and panel
values affect their own backing/filter policy independently. Content cards and
footer backing stay opaque. Blur mode retains effective panel opacity and the
faint window backing.

Do not use legacy shell `panelColor` for application content: it substitutes
black/white in glass mode. Existing shell panels and unmigrated apps retain their
own behavior until deliberately migrated.

## Geometry: derive nested corners from Denial

Use the accepted rule:

```text
R_child = max(R_min, R_container - d)
R_min   = 4 logical pixels by default
```

`R_container` is the already-resolved containing-surface radius. At the app
boundary it defaults to `ShellTheme.windowRadius`, the shared Denial token with
the user's roundness scale already applied. `d` is the actual layout inset.
Do not scale the subtraction result, inset or minimum a second time.

Use `DenialSurfaceGeometry.radiusOf`, `nestedRadius` and `borderRadiusOf`.
`DenialMaterial(inset: ...)` derives its geometry and publishes the result to
children. A containing card's padding must propagate the inset geometry before
building nested surfaces. Use a descendant `Builder` when a control needs the
material's inherited radius. Never subtract the same inset twice.

The 4-pixel floor is intentional, including for cards inside the square main
content sheet. Do not restore the rejected `max(0, ...)` rule: it made nested
surfaces square with the user's settings. The main sheet itself remains square;
the minimum applies to nested surfaces. Do not independently assign large
component radii or size-based squircle radii to these nested surfaces.

At the approved settings, Denial's window radius is 14 pixels:

| Surface | Derivation | Radius |
| --- | --- | --- |
| Sidebar and top groups | `max(4, 14 - 8)` | 6 |
| Bottom notice at 16-pixel inset | `max(4, 14 - 16)` | 4 |
| Navigation selection, inset 12 from sidebar | `max(4, 6 - 12)` | 4 |
| Card inside square content sheet | `max(4, 0 - d)` | 4 |

These are examples, not fixed app radii. Changing Denial's roundness must update
the inherited geometry. The SDK exposes `minimumRadius` for explicit variations;
do not silently vary it in individual widgets during a refactor.

## Reference dimensions and responsive behavior

All dimensions below are logical pixels. Preserve these defaults when adopting
the frame; they describe the accepted Plugins composition rather than a new
screen-size-independent constraint on every application.

| Element | Reference layout |
| --- | --- |
| Sidebar width | 216 |
| Sidebar top, bottom and outer side inset | **8**, via `DenialApplicationFrame.defaultInset` |
| Top command-area padding | **8 on all sides**, using that same constant |
| Initial content-sheet top | 36% of client height, clamped to 160–280; Welcome uses 42%, clamped to 180–320 |
| Actual scroll reveal gap | Initial sheet top minus measured toolbar height, minimum 56 |
| Readable desktop-content start | Sidebar width + outer inset; background spans full width |
| Sidebar item horizontal inset / minimum target | 12 / 44 |
| Search group maximum width | 320 |
| Gap between search region and actions | 24 |
| Search wrapping gap | 12 |
| Content horizontal inset | 24 below 560 available width, otherwise 32 |
| Wide-content centering | `max(inset, (availableWidth - 920) / 2)` |
| Content top / bottom padding | 28 / 32 |
| Ordinary content-card padding | 20 |
| Bottom error notice padding | Left/right 24, top 0, bottom 16 |
| Pending-operation group padding | Left/right 24, top 8, bottom 16 |

Plugins selects compact layout below 800 client pixels or when a 14-pixel text
sample scales above 21. Compact layout uses inset horizontal navigation, then
self-sizing command groups and the remaining area for content. The reveal gap is
32. Navigation can scroll horizontally. Do not squeeze labels to retain a desktop
sidebar at large text scales.

Search shares the top row when the available command width is at least
`440 * (scaled14 / 14)`; otherwise it moves below the action group. Activity has
no search. Do not hardcode a toolbar height. Its measured height determines the
reveal gap, preserving layout under text scaling and wrapping.

## Scrolling, transitions and bottom notices

**Scroll the entire sheet.** One `DenialContentPane` viewport owns the leading
reveal gap and a `DecoratedSliver` around content. Its background and content move
together. Do not put an opaque, stationary card around a separately scrolling
list. The trailing fill gives the sheet at least one viewport of height excluding
the reveal gap, so short and empty pages can also scroll the sheet upward.

Keep the sidebar and top groups fixed. Keep the sheet opaque while scrolling.
**There is no top-edge fade, gradient mask or whole-card opacity animation.**
The previous scroll-edge fade was explicitly removed.

For tab changes use `DenialContentSwitcher(contentKey:, child:)`. It fades the
outgoing contents and then the incoming contents; the decorated sheet remains
opaque throughout. The default is 160 ms total (80 out, 80 in), with no initial
page fade. `SliverFadeTransition` applies to content slivers, not their backing.
Do not wrap a whole pane in `AnimatedSwitcher` or `FadeTransition`; that exposed
the desktop through the main card during tab changes.

Set transition duration to zero for reduced motion. Rapid navigation must resolve
to the latest requested page; returning to the outgoing tab cancels the pending
switch. Do not leave stale outgoing controls interactive during a switch.

**Errors belong at the bottom.** Use an actionable notice with details and dismiss
controls. It remains available while content scrolls and sits below any pending
operation group. Do not move it back into the top command area or auto-open an
error dialog. Plugins exposes Apply in the overflow menu and only shows its
operation group when busy or changes actually need applying.

The entire footer region has opaque canvas backing across the full window width,
including padding and the portion under navigation. A glass notice on that opaque
backing is valid; a transparent footer strip revealing the desktop is not.
In very short windows, footer contents may scroll within at most half the available
body height so a content viewport remains available.

## Content presentation and interaction

Use the inherited typeface and a quiet hierarchy: a semibold page heading,
secondary explanatory copy, clear section labels and restrained separators.
Plugins uses `headlineSmall`, weight 600 and letter spacing -0.4 for page titles;
body descriptions use approximately 1.5–1.6 line height. Do not force another font
or add promotional sidebar copy and decorative headings during migration.

Installed items use separated rows; Discover uses adaptive content cards. Keep
an empty state truthful: icon, short title, useful explanation and one clear next
action. Do not populate fake data or install plugins just to improve a screenshot.
Center narrow empty-state copy (reference maximum 360 pixels) within the content
area, with deliberate spacing around its action.

Keep focus traversal, tooltips, selected semantics, keyboard navigation and
minimum touch targets. Plugins retains Ctrl+F for search and Ctrl+1/2/3 for pages.
The target app should retain its equivalent interactions and application behavior.
Do not replace working backend, dependency, activation or settings logic as part
of a visual migration.

## Refactor procedure and acceptance

1. Read the target app and the SDK references above. Identify its real content,
   navigation, commands, errors and long-running operations.
2. Adopt the shared application theme and preserve live appearance settings.
3. Compose `DenialApplicationFrame` with navigation, grouped toolbar, content and
   footer. Preserve native alpha for the revealed upper area.
4. Move pages to `DenialContentPane(sliversBuilder:)`; the builder receives the
   readable width excluding navigation. Use lazy slivers for long collections.
5. Use `DenialContentSwitcher` for page transitions. Keep all persistent material
   backings outside content opacity animations.
6. Derive nested radii with the minimum-radius rule and real insets. Reuse shared
   edge spacing, palette, opacity and shadow tokens instead of local copies.
7. Review narrow layouts, text scaling, reduced motion, keyboard access, empty
   states and errors in code. Preserve capabilities and truthful state.
8. Run appropriate analysis and authorized checks. Routine release builds reuse
   the locked engine; do not build a debug/development engine for UI validation
   unless explicitly requested. Documentation-only changes do not need a build.
9. Follow the repository's current visual-validation and session-control rules.
   The user owns visual validation. Do not launch apps, take screenshots, create
   UI states or trigger notifications for QA without the required explicit request.
   User-supplied references do not authorize fresh captures. A build passing is
   not visual acceptance. Never stop the user's local graphical session.

Before handing off, verify these invariants:

- Neutral black glass in dark appearance; warm charcoal reserved for content.
- Sidebar and top groups close to the edges with matching inset-derived corners.
- Shadows preserved and the 3/255 backdrop backing retained.
- Content background continues under navigation and scrolls with content.
- No scroll fade; only page contents fade during tab changes.
- Bottom errors, with an opaque full-width footer behind them.
- Window transparency and shell-panel transparency remain separate settings.
- No claims of adaptive vibrancy, universal wallpaper contrast or unperformed
  visual validation.

## Operation feedback inside the footer

For background operations, place a linear progress bar inside the existing bottom
indicator, below its status and actions. Animate the line while work is running;
show actual completed stages and the current substep in text. A compiler does not
report a meaningful completion percentage, so do not fabricate one.

A failed or interrupted operation replaces the ready state with a persistent,
actionable explanation in the same indicator. Provide selectable technical details
and explicit dismissal. Polling must not erase a new failure or resurrect one the
user dismissed. Keep the footer's opaque backing, shared materials and inherited
radii. Do not add a second floating notification or a transparent bottom strip.

Compatibility problems belong in the existing bottom indicator before Apply.
Name the conflicting plugins and tell the user how to fix their selection;
disable Apply while known conflicts exist. Switches edit a window-local draft
and run cached compatibility checks synchronously in memory; do not show a
loading state or create backend jobs for toggles. Apply saves and performs the
batched operation. Offer Discard for an unapplied draft; background polling must
not overwrite it.
Error dialogs lead with an explanation and put selectable technical diagnostics
and build output into separate collapsed sections. Progress lines must not be
presented as part of an error sentence. Keep long raw output monospaced and
scrollable, and load full logs only when the user opens them.


Compilation activity refinement: while an operation is running, animate the
bottom indicator line continuously using an indeterminate progress indicator.
Keep real stage counts in the adjacent text. During compilation show the actual
source-compilation, native-code generation, or asset-preparation substep and its
elapsed time; no fabricated completion percentage or estimated countdown. Update
the elapsed text once per second without more backend polling, and exclude clock
ticks from live screen-reader announcements. Apply the same behavior to running
Activity entries. Stop the animation and dispose the clock when work ends.
