# Denial application materials

Scope: desktop applications. Native phone apps follow [MOBILE_APP_MATERIALS.md](MOBILE_APP_MATERIALS.md).

Status: repository-local API under active design. Plugins is the first consumer.
This implements [GLASS_UI_DESIGN_SKILL.md](GLASS_UI_DESIGN_SKILL.md).
The latest user direction supersedes the earlier side-by-side desktop-glass
sidebar and attached toolbar composition.

## Composition contract

The upper region reveals Denial's desktop instead of displaying a stock hero
image. Its backing follows `glass.windowOpacity`, with a minimum coverage of
3/255 (about 1.2%) to prevent floating shadows becoming isolated frosted patches
at a zero compositor cutoff. This floor belongs only to the window background;
functional panels have no opacity floor. The app does not override the compositor
pixel-alpha cutoff. A cutoff above the backing can still leave it unfiltered. The lower content sheet is opaque and continuous across the window,
extending behind the navigation card with no visible inset content-card corners.
Navigation is an inset, rounded, blurred card spanning both regions. Commands
float in separate glass groups over the revealed desktop. Never place a full-width
translucent toolbar sheet behind those groups or make the lower content transparent.

Use `package:denial_flutter_sdk/materials.dart`:

- `DenialApplicationTheme.fromShell(shell)` owns colors and Material themes.
  Preserve the user's accent, font, roundness and motion preferences.
- `DenialApplicationFrame(navigation:, toolbar:, content:, footer:, compact:)` owns the
  faintly backed upper region and scrolling lower content sheet. Desktop navigation
  floats 8 logical pixels from the edges, with readable content beside it. The
  backdrop area uses 36% of the client height, bounded to 160–280 logical pixels.
  Compact navigation and commands size themselves above content, conserving height.
- `DenialMaterial(role:, floating: true, child:)` gives navigation or command
  groups a fine edge and subtle shadow. Geometry comes from the containing
  surface, with `inset:` declaring the distance in logical pixels.
- `DenialContentPane(sliversBuilder:)` owns one viewport containing the leading
  reveal gap and a `DecoratedSliver` around content. Decoration spans underneath
  navigation; the builder receives readable width excluding the sidebar inset.
  The background and content move together. Never restore a fixed opaque backing
  around an independently scrolling list. A trailing sliver makes the sheet at
  least one viewport tall, so short/empty pages can also collapse the reveal gap.
- `DenialContentPane(leadingOverlap:)` optionally raises content into the reveal
  gap while preserving the sheet's edge. The overlap is capped by the available
  gap and moves with the sheet. Settings → You uses 80 logical pixels for its
  single profile card; the default is zero for all other pages.
- The frame measures toolbar height through normal layout. The whole content
  sheet scrolls without any opacity gradient or fade. Compact layout starts with
  a 24-pixel reveal gap. Do not reintroduce a fade without a new user request.
- `footer` is fixed below the scrolling sheet, on an opaque canvas spanning the
  full width (including all padding and the area under navigation). Use it for
  actionable errors and pending-apply status. Do not expose the desktop behind
  this region. In very short windows it may scroll within at most half the body
  height, preserving a content viewport.
- `DenialContentSwitcher(contentKey:, child:)` fades outgoing page contents before
  bringing in the new contents. `DenialContentPane` consumes this animation only
  around its content slivers; the decorated sheet stays opaque. Never wrap the
  whole pane in `AnimatedSwitcher`/`FadeTransition`: that exposes the desktop
  through the charcoal backing. Set duration zero for reduced motion. Rapid tab
  changes use the latest requested page; returning to the outgoing tab cancels
  the pending switch. No first-build fade is applied.
- Ordinary controls inside a functional group remain transparent. Do not give
  each button another blur or material layer.

Welcome uses the frame's `horizontalNavigation` variant: a floating progress
group above the same measured reveal gap and scrolling sheet. Wizard commands
overlay the bottom corners, with clearance only at the end of the scroll content.
Their ordinary filled buttons have no glass wrappers. Its reveal area uses 42%
of the client height, bounded to 180–320 logical pixels; this is Welcome-only.
The other applications keep their sidebar layout and status footer.

Welcome locally computes contrasting accent foregrounds and readable outlined
button text against its opaque surfaces. These overrides do not change Settings
or Plugins. Its default body text style is explicitly installed for sheet content.

| Role | Backing | Backdrop | Appearance |
| --- | --- | --- | --- |
| `window` | Chrome tint at window opacity (minimum coverage 3/255) | Compositor desktop only | Application |
| `content` | Opaque canvas | None | Application |
| `card` | Opaque raised surface | None | Application |
| `sidebar` | Chrome tint at app-panel opacity | Application content / exposed desktop | Application |
| `toolbar` | Chrome tint at app-panel opacity | Application content / exposed desktop | Application |
| `dialog`, `popover` | Opaque raised surface | None | Application |

Both sidebar and toolbar use `ShellBackdropBlur(separateChild: true)`.
Settings and Plugins retain the existing application optical profile (zero edge
strength, light intensity, refraction and dispersion). `preserveGlassEffects: true`
is an explicit per-surface opt-in to the unchanged saved glass configuration;
Welcome uses it for the progress surface. Native transparency is unchanged.

Client-side filters sample available application pixels; they cannot read another
Wayland client's pixels. Where the app remains translucent in the upper region,
Denial's compositor supplies the desktop backdrop. Where lower content is opaque,
the client-side material samples that content. Never copy wallpaper into the app
or render another client there. Do not add photographs or fake content to show blur.
The native host must preserve client alpha and avoid claiming an opaque window.
GTK hosts use an app-paintable RGBA window and explicitly clear its dirty region
to transparent before drawing the Flutter view. Drawing transparent pixels over
an old opaque frame cannot restore alpha; the clear must replace those pixels.

Standalone Rust and GTK app runners disable Mesa's `GL_EXT_shader_framebuffer_fetch`
before graphics startup, preserving other `MESA_EXTENSION_OVERRIDE` entries.
The engine's final backdrop-filter buffer transition otherwise loses earlier
layers on .188. Disabling the capability preserves transparency and glass;
it is scoped to app processes and does not change the compositor's capabilities.

The model distinguishes application and compositor backdrops as described by
[NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview).
It is not AppKit integration. Pixel-adaptive vibrancy and background extension
are not implemented. Do not duplicate the content tree to fake them.

## Nested geometry

`R_child = max(R_min, R_container - d)` is the application nesting contract.
The default minimum is **4 logical pixels**. Resolve the container radius from
Denial first, then subtract the actual layout inset. Do not scale the result,
inset or minimum again. The minimum keeps inner cards rounded even when their
parent is square or the inset exceeds its radius.

`DenialSurfaceGeometry.radiusOf(context)` defaults to `ShellTheme.windowRadius`,
the shared, user-scaled token used by Denial's window frame. A containing surface
publishes its resolved radius through `DenialSurfaceGeometry`.
`nestedRadius(context, inset:, minimumRadius:)` and `borderRadiusOf` apply the
formula; `minimumRadius` defaults to `defaultMinimumRadius` (4). `DenialMaterial`
uses this geometry by default and publishes its result for descendants. An
already-inset scope must not subtract the same padding a second time.

`DenialApplicationFrame.defaultInset` is **8 logical pixels**, shared by the
sidebar placement and Plugins' top command padding and radius derivation. At the
current 14-pixel window radius, these surfaces resolve to `max(4, 14 - 8) = 6`.
The lower notices retain their existing 16-pixel edge inset and resolve to 4.
Navigation selection subtracts its 12-pixel inset from the sidebar radius, with
the same floor. The content sheet keeps square outer geometry; nested content
cards get the 4-pixel minimum. Card padding propagates geometry to descendants.
Shape, clip, blur bounds, edge and shadow use the same resolved radius. Live
roundness changes rebuild the inherited geometry.

## Palette

The requested dark canvas is **#22211F**, sampled from every pixel of the user's
supplied swatch. Raised content is #2C2B29; controls #383734; floating chrome tint
#000000; foreground #F2F1EF; secondary text #BBB9B5. Functional glass is neutral black; the warm charcoal palette is reserved for
opaque content.

Light equivalents are canvas #F7F6F3, raised #FFFFFF, control #EEECE7, chrome
#FFFFFF, foreground #292825 and secondary #625F59. The SDK owns these values;
individual apps select semantic roles rather than copying hex constants.

Application overlays use a stable application appearance while spanning the
revealed desktop and content. Saved desktop-glass appearance continues to govern
shell surfaces and the compositor through existing APIs. Pixel-adaptive foreground
contrast is not implemented; do not claim arbitrary-wallpaper contrast validation.

## Transparency

In glass mode, `glass.windowOpacity` controls the application frame's background.
`glass.appPanelOpacity` controls compatible application sidebars and toolbars.
`glass.opacity` is reserved for Denial shell surfaces: launcher, Dashboard, taskbar
and top cards. All three values remain independent; changing shell opacity must
not change compatible application materials, and changing window opacity must not
change app-panel tint or filtering policy. Panel appearance will naturally
include the background it is composited over. The UI displays opacity directly: 0% is clear, 100% is opaque.
Legacy settings initialize missing window/app-panel fields from shared opacity,
then serialize all three so subsequent changes remain independent. Blur mode retains
the legacy effective panel-opacity behavior and faint window coverage.

Consumers pass the original `ShellThemeData` into the application theme; do not
call the legacy `forWindowSurfaces()` remapping, which replaces panel opacity.

The `window` role paints tint only. The compositor supplies its desktop blur;
do not add a second full-window client-side backdrop filter. The background keeps
a minimum alpha of 3/255 for coverage, while panel alpha may reach zero.

Content, cards, dialogs, menus and the full footer region use opaque backing.
Transparency off makes every surface opaque. A fully opaque window background
uses canvas; fully opaque panels independently skip their client-side filtering.
Nonfinite opacity falls back to opaque; finite
out-of-range values clamp. Existing shell material helpers and unmigrated apps
retain their behavior. New application consumers do not use the shell helper
`panelColor`, which substitutes black/white for their palette RGB.

## Validation

Analyze SDK and consumer; run pure-Dart material-policy/glass-configuration tests;
release-build with the existing locked engine. Do not build a development engine
for routine UI work. Verify foreground contrast against opaque palette surfaces.
Rendered validation belongs to the user: do not capture screenshots, launch the
app for inspection, or synthesize UI events without the required explicit request.
A successful build is not visual acceptance.
