# Denial Plugin Manager: agent implementation contract

Status: accepted product/distribution direction; implementation and integration validation underway.
Decision date: 2026-09-27.
Audience: agents implementing the manager, SDK distribution, catalog, or builder.

Read [PLUGIN_SYSTEM.md](PLUGIN_SYSTEM.md) first. This document extends that
contract with the agreed distribution and management model. It supersedes the
earlier proposal that plugin authors must publish their plugins to pub.dev.
It does not authorize implementation, publication, or deployment. Follow
`AGENTS.md` for all execution and validation constraints.

MUST/MUST NOT denote requirements. Examples use illustrative package names,
versions, URLs, and field names; they are not published packages, assigned
repository locations, or a finalized storage/IPC schema.

## 1. Accepted shape

- Plugin Manager is a separate Flutter application, analogous to Settings.
- Define and implement the backend before the store UI.
- Initial external plugin installation accepts a Git repository URL.
- Plugin authors MUST NOT need a pub.dev account or publication step.
- Plugins remain ordinary Dart packages with `pubspec.yaml` and annotated Dart
  contribution libraries. Git distribution does not eliminate package structure.
- Supply Denial's public SDK packages in the installed release compiler kit so
  authors can reference them without cloning Denial or requiring pub.dev hosting.
- Show built-in plugins and entries from a Denial-owned catalog repository.
- Support direct Git installation independently of catalog inclusion.
- A repository may contain multiple independently selectable plugin packages.
- Pub remains the dependency authority. Activation remains compile-time.

Hosted-plugin sources can fit the backend model later; Git and local-directory
sources are supported. SDK publication on pub.dev is optional. The installed SDK
is the supported input for composition and authoring. The 2026-09-30 decision
supersedes the earlier publication requirement: document manual author SDK/editor
setup in [plugin development](PLUGIN_DEVELOPMENT.md), without a new setup helper.

## 2. Authority boundaries

| Concern | Authority |
| --- | --- |
| Built-in availability and matching source versions | Installed Denial release manifest |
| External catalog membership | Denial-owned catalog |
| Explicitly selected plugins | User composition configuration |
| Package names, dependencies, version constraints | Package pubspecs |
| Exact resolved dependency graph and Git commits | Pub resolution and retained application lockfile |
| Contributions and contract identities | Static analysis of annotated libraries |
| Denial runtime, engine, and toolchain identity | Installed release/source compatibility metadata |
| Active bundle and recovery | Existing native shell-control infrastructure |

Catalog inclusion MUST NOT activate a plugin. Removing a catalog entry MUST NOT
silently uninstall or disable an existing selection. Treat explicit removal,
update, and any future revocation policy as separate operations.

Keep selected roots distinguishable from dependencies. If a selected plugin
depends on another plugin, Pub brings that package into the graph and static
discovery includes its contributions automatically. An ordinary library remains
a library. Do not require separate user enablement of plugin dependencies.

## 3. Git sources and revisions

The common author layout is:

```text
my_taskbar/
  pubspec.yaml
  lib/
    my_taskbar.dart
```

A URL alone MUST be sufficient when there is one plugin package at the root.
The default branch supplies the initial revision. Optional selection can specify
a branch, tag, commit, or package subdirectory.

Retain these concepts separately:

- Requested source: repository URL, package path, and requested ref/default-branch
  policy. This expresses what the user follows for updates.
- Resolved source: package name, actual Git commit, package path, and resolved
  dependency graph. This identifies the input used for a particular build.

The manager must read the package pubspec to obtain its name; a repository name
is not necessarily the Dart package name. Verify that generated dependency keys
match the selected packages. Do not execute package code to discover metadata.

Generated dependency example:

```yaml
dependencies:
  my_taskbar:
    git:
      url: https://github.com/example/desktop_plugins.git
      path: taskbar
      ref: <resolved-commit>
```

Retain the lockfile alongside the generated composition. Rebuild/apply MUST NOT
implicitly advance previously locked Git revisions. Updating deliberately resolves
new revisions and creates a new candidate. A moving branch or tag alone is not
sufficient build provenance. Record resolved commits for transitive Git packages
as well as roots, using Pub's result rather than a second dependency resolver.

Pub supports Git refs and repository-relative package paths. It also supports
version selection from matching tags via `tag_pattern`; adopting a tag convention
is optional future work, not an author requirement for initial installation.
See [Pub Git dependencies](https://dart.dev/tools/pub/dependencies#git-packages).

## 4. Multiple plugins in one repository

```text
desktop_plugins/
  taskbar/
    pubspec.yaml                 # name: my_taskbar
    lib/
  window_decorations/
    pubspec.yaml                 # name: my_window_decorations
    lib/
  shared/
    pubspec.yaml                 # ordinary shared library
    lib/
```

The package is the enable/disable unit; the repository is a source container.
Several annotated contribution libraries/classes within one package activate
together. Independently selectable plugins MUST be separate packages, even when
they share a repository.

For a pasted URL containing multiple plugin packages, inspect the repository's
package candidates and offer the plugin packages individually. Do not implicitly
enable every package in the repository. Ordinary shared libraries and development
fixtures MUST NOT appear as plugins merely because they have a pubspec.

Repository discovery and compilation discovery are distinct:

- Repository inspection finds installable package candidates without executing
  their code; resolved annotation identities establish actual plugin declarations.
- Compilation discovery examines only the resolved application dependency closure
  for the selected composition, excluding dev/build tooling.

Packages in the same repository declare dependencies through their pubspecs.
Do not infer dependencies from sibling directories or add a catalog dependency
list. A taskbar depending on the decorations plugin brings it in automatically;
a taskbar not depending on it leaves it independently selectable.

Source identity must include repository URL and package path, with exact revision
recorded per resolution. Pub's package-name identity still applies: two sources
declaring the same package name cannot be treated as unrelated namespaced plugins.
Report source/version conflicts instead of silently selecting a winner.

## 5. Catalog and built-ins

The default catalog is
[`denialwm/denial-plugins/plugins.yaml`](https://github.com/denialwm/denial-plugins/blob/main/plugins.yaml).
The repository is a collection: each independently selectable plugin lives in
`plugins/PACKAGE_NAME/`; ordinary shared libraries may live in `packages/`.
Its root is not a Dart package. The initial entry is `plugins/denial_taskbar`.

First use fetches this catalog automatically. Later reads use cached results;
Refresh deliberately fetches again. An initial network failure is cached as a
catalog error so ordinary polling remains usable offline; Refresh retries it.
Built-ins remain available. Preparation adds defaults to existing installations
without replacing explicit custom catalog settings or a disabled catalog, and
discovery does not enable packages or change the selected composition.

The catalog schema is:

```yaml
schema: 1
plugins:
  - git: https://github.com/example/single_plugin.git
  - git: https://github.com/example/desktop_plugins.git
    path: taskbar
  - git: https://github.com/example/desktop_plugins.git
    path: window_decorations
```

Catalog entries identify sources/packages. The catalog MUST NOT duplicate Pub's
dependency graph, SDK constraints, or Dart contribution definitions. Prefer package
metadata for names/descriptions/documentation. Categories, featured entries, version
restrictions, and review status may be added later with explicit semantics.

Built-ins use the same SDK and composition rules as external plugins. Their exact
source identities come from the installed release rather than a moving repository
branch. Preserve the packaged default shell as the recovery root. Shipping/caching
built-in source and dependency artifacts is desirable for offline default rebuilds;
do not claim that capability until the complete toolchain/input set is available.

## 6. SDK distribution and compatibility

Ship these existing package boundaries in the matching release compiler kit:

- `denial_sdk`: Dart-only public types and contribution metadata.
- `denial_flutter_sdk`: Flutter contracts, shared presentation, and input APIs.

Plugin dependencies for the current source metadata versions:

```yaml
dependencies:
  flutter:
    sdk: flutter
  denial_sdk: '0.0.0'
  denial_flutter_sdk: '0.0.0'
```

The manager supplies one installed SDK snapshot through root Pub overrides before
resolution. It validates each resolved package's declared SDK constraints
separately, because overrides bypass Pub's normal constraint enforcement. Reject
incompatible combinations; do not silently force them. All contributions must
share the resolved SDK type identities. Pub still resolves the package graph;
there is no second dependency manifest/resolver.

Authors manually point their project at the prepared SDK pair through an ignored
`pubspec_overrides.yaml`, and configure their editor to use the paired Flutter/Dart
tools. See [plugin development](PLUGIN_DEVELOPMENT.md) for exact commands and
files. Committed SDK dependencies express compatibility; a fresh author clone
requires that local setup. Installation through Plugin Manager supplies the SDK
automatically and does not need the author's paths or publication to pub.dev.

Current SDKs use `publish_to: none` and source metadata version `0.0.0`. This is
not a stable API compatibility promise. SDK API versioning and supported ranges
still require an explicit policy independent of Denial's signed release version.
The installed source/runtime/toolchain identity remains mandatory even if package
versions match. Each release must identify its supported SDK inputs and matching
runtime/toolchain. Optional future hosting does not change this authority.

The kit supplies Denial's matching Flutter fork and release compiler inputs.
Compilation of fork-dependent APIs requires that toolchain; do not substitute
stock Flutter merely because Pub successfully resolves a package graph. The
optional `denial-ui-development` package is for the separate live-development
workflow, not a prerequisite for plugin installation or release builds.

## 7. Backend and application boundary

The backend owns resolution, planning, generation, builds, and activation requests.
The separate GUI presents catalog/state, user selections, progress, and failures.
Provide a CLI path to the same backend so recovery does not depend on shell UI.
Build jobs should survive closing the GUI; worker lifetime and IPC remain to be
specified. Do not put long-running compilation exclusively inside a widget process.

Proposed operations, not finalized method names or an implemented API:

| Operation | Responsibility |
| --- | --- |
| Catalog/status | Available packages, selected roots, required dependencies, active build, job state |
| Plan(selection) | Resolve a candidate, report dependency changes and composition conflicts |
| Build(plan) | Generate direct typed wiring, compile, emit progress, retain validated artifacts |
| Activate(build) | Ask existing native control to switch to the prepared compatible bundle |
| Restore | Ask existing native control to restore the packaged shell |

The manager owns a generated application workspace based on the installed Denial
source revision. It MUST NOT edit the installed checkout or an arbitrary user's
development project when changing plugin selections. Persist selection intent
separately from generated files and exact successful build provenance.

Candidate pipeline:

1. Identify release/runtime/toolchain and obtain matching build inputs.
2. Materialize a candidate generated project from selection and retained lock.
3. Resolve via `flutter pub get` using Denial's pinned toolchain.
4. Inspect typed contributions, validate contracts, generate direct composition.
5. Compile and validate a new immutable bundle.
6. Request activation through existing native control; retain previous working
   artifacts and packaged recovery.

Failed resolution, generation, or compilation MUST leave the active bundle
usable. Keep apply/rebuild and update operations distinct. Persistent custom
composition integration and recovery use the existing native refresh path;
implementation and validation evidence are recorded below.

## 8. Prerequisites, first milestone, and unresolved decisions

The runtime dependency boundary excludes optional panels. Both bars remain dev
dependencies for the handwritten local entry point and tests; `main.dart` keeps
the sibling taskbar selected. Generated applications introduce selected roots as
runtime dependencies. The runtime receives the panel through its constructor.

First backend milestone: resolve a selection containing either existing bar,
discover its typed contribution, generate the wiring, build, and activate through
the existing control path. Exercise a Git package at the repository root and a
package selected by subdirectory. Keep the original plugin architecture's broader
contracts; this milestone MUST NOT turn the manager into a taskbar-specific tool.

Implemented decisions:

- Backend: pure Dart CLI, detached worker processes, durable JSON jobs/selection,
  and an OS mutation lock. The separate Flutter app invokes this interface.
- Catalog: schema 1 with Git URL, optional package path/ref; explicit refresh,
  cached metadata, and no automatic activation or revision advance.
- Discovery/generation: resolve annotation types through Pub's package graph,
  inject public unnamed constructors, validate cardinality/order/cycles, and emit
  direct constructor calls. See the backend README for supported signatures.
- Git sources: retain requested refs separately from resolved commits; ordinary
  apply preserves pins, and update explicitly resolves them again.
- Recovery: sealed immutable candidates, native startup confirmation, persisted
  previous selection/pins and packaged-shell fallback. Stale plans and overlapping
  activation requests are rejected.

Decisions still open or explicitly deferred:

- SDK API compatibility versions, stability policy, release compatibility metadata;
- optional tag/version conventions;
- handling coordinated updates of several packages from one repository;
- authentication UX for private Git sources;
- source provenance/review/revocation policy and build-script execution rules.

Do not convert these open choices into requirements without a design decision.
Do not claim catalog listing, Git hosting, or pub.dev hosting provides runtime
isolation: plugins compile into the shell's process and failure domain.

## 9. Implementation progress (2026-09-27)

Implementation is authorized and underway. The pre-manager checkpoint is Denial
`cbed587` and the sibling taskbar repository's `e776434`; neither was pushed.

Implemented so far:

- `packages/denial_plugin_manager`: pure Dart backend, actual-type analyzer
  discovery, constructor-injection validation, deterministic direct Dart emission,
  Git root/subdirectory inspection and pinning, source snapshots, candidate planning,
  release compilation, JSON state, OS mutation lock, detached job submission.
  The regular `tools/denial-pc plugin-check` runs the backend test suite.
- `tools/denial-plugins`: JSON CLI for those operations. See the backend README.
- `ShellApplication` is a required exclusive SDK contract for complete shell
  composition. `plugins/denial_desktop` supplies the reference composition.
- Runtime package dependencies no longer include either panel. Panels remain dev
  dependencies for the handwritten local entry point/tests, which keep the external
  taskbar selected. Generated applications introduce selected roots explicitly.
- `DenialShellApp` accepts its panel through its constructor; a missing panel has
  no reserved work area. The runtime does not select plugins.
- A real local taskbar/reference-desktop plan compiled to an isolated release
  bundle using the pinned engine. Real Git/Pub planning was also validated for
  root and subdirectory packages with explicit development SDK substitution.
  No shell was activated during that validation.

Additional implementation now present:

- Native `denialctl ui activate BUNDLE`, release-mode runtime replacement using
  the existing native refresh path and packaged engine, sealed hash validation,
  installed-source identity matching, frame/startup confirmation, persistent
  last-working selection, rollback, interrupted-start recovery and bounded rapid
  startups. A concurrent external activation cannot overwrite a pending one.
- `plugin_manager_app`: separate native Wayland/Flutter app with selected plugins, built-ins,
  configurable Git catalog, root/subdirectory inspection, job progress/errors,
  prepare, plan, apply, update, previous composition and packaged restore.
- Rollback restores roots, provider selections, ordering, and the lockfile/pins
  used as the basis of subsequent ordinary apply. Repeated activation retains
  previous history. Plan validation fingerprints assets, package mapping and
  resolved package sources as well as generated code and local snapshots.
- `tools/prepare-denial-plugin-kit`: relocatable source snapshot, vendored Flutter
  tool dependencies, a preferred Dart version and supported version constraint,
  and existing release compiler artifacts. The
  manager's `prepare` operation verifies the manifest and copies tools into a
  user-owned cache, then links the Dart SDK resolved from `PATH` into the two
  internal locations expected by Flutter. It never rebuilds Rust/the engine or
  modifies installed tools.
- Native packages distribute the manager app, CLI, and compiler kit as
  `denial-plugin-manager`, separate from `denial`. Arch declares `dart` directly;
  Nix supplies its exact Dart derivation; other formats rely on the app's missing
  or incompatible Dart warning where no simple native Dart dependency exists.
- The compiled CLI successfully planned and built the reference desktop/top bar
  with the original Flutter checkout and engine output hidden; compilation ran
  without network access. The real sealed bundle passed native validation against
  the packaged engine and exact source marker. The separate app and staged CLI
  built successfully; staged ELF requirements are within GLIBC 2.39.
- Backend tests pass for Git packages, typed discovery, generation,
  stale sources/assets, rollback and provisioning. Native targeted tests cover
  sealed artifacts, exact installed source identity, startup health, concurrent
  requests, persistence and recovery. Broader verification is still required.

Remaining validation/publication boundaries (updated after the audits below):

- Nix build verification requires publishing the already-pinned Flutter source
  and refreshing the verified Nix lock; native package checks are recorded below;
- SDK API versioning (explicitly deferred while SDK source versions remain `0.0.0`);
- user-owned visual validation; agents do not launch the app or inspect screenshots.

The user subsequently requested deployment of all current changes to `.188`.
The deployment is active at
`/home/logix/.cache/denial/lab/artifacts/plugin-manager-95d275298746d52b`.
The compositor, shell, Settings, Plugins app, CLI, compiler kit and adapted local
taskbar source are installed. The per-user manager is prepared and selects
`denial_desktop` plus `denial_taskbar`; the top bar remains disabled. Local SDK
substitution is explicitly configured for the still-unpublished SDKs.

Deployment verification found and fixed the CLI's unsupported `--wait` argument:
`denialctl` waits by default, with `--no-wait` as its opt-out. Live manager/native
status and catalog access now succeed. New `deniald` PID 9086 replaced PID 624;
its executable hash is `30eda3049c4a8925990d15520960abea8f677d1191f527cec58107db06d6f6f1`.
The original toolkit-isolation/native-bundle tests did not cover this real CLI
invocation, so retain live protocol integration coverage in the final audit.

On this host the installed `greetd(5)` manual says `/run/greetd.run` suppresses
initial-session startup even across daemon restarts. The first restart therefore
entered the greeter. Removing that ephemeral marker and restarting
`greetd.service` directly started the configured Denial session. No reboot was
needed. Visual validation remains exclusively the user's responsibility; no app
was launched for inspection and no screenshot was captured. Do not mark the
manager complete based only on discovery tests or standalone compilation.


Deployment follow-up (2026-09-27): the user reports `.188` dies under sustained
moderate/heavy CPU load and directs further deployment/build validation to `.18`.
Do not resume the abandoned `.188` apply job as part of this work. Its last
observed phase was typed discovery; SSH subsequently reset connections and timed
out, so its final state is unverified.

The latest deployment is now on `.18` at
`/home/logix/.cache/denial/lab/artifacts/plugin-manager-632aab94a9e7e413`.
It includes the read-only source snapshot fix, compiler launcher engine selection
for Pub commands, built-in source migration across kit upgrades, and complete
worker failure diagnostics. The kit manifest SHA-256 is
`6a09bf49965ffa53b4ca3af617b621642d0b2f72e1a664ea40c8beac5ce6ac2d`.
The compiled backend SHA-256 is
`5a6e1c3b814a67fdbdf19f99a7b7a89b74d3d96e76c2e44a0f412c9bb96dd6ed`.
Native PID 2339 replaced the old experimental compositor PID 1285; the native
binary hash remains the one recorded above. The manager is prepared with the
reference desktop and taskbar selected, top bar disabled. The initial greetd
restart raced with teardown of the old UWSM session; a second direct restart
after teardown, clearing its configured `/run/greetd-denial-initial-session`
marker, started the new session. Previous binaries and configurations are retained
under the deployment's `previous-native/` directory.

`tools/denial-pc compositor-test` passes after the native activation changes
(332 main binary tests, with the separate library/CLI/integration tests also
passing; opt-in artifact tests remain ignored in the regular suite). A Nix
application/backend derivation evaluation was attempted using the locked Nixpkgs
in an isolated container. It stops at the pre-existing engine-lock mismatch:
`SOURCE_LOCK.json` selects Flutter `2a731ef8427d07683160dd35a5bd02e767a11467`,
while `nix/flutter-engine-lock.json` still selects
`17ce3edf38ef4b948542dc4b3a3cd27c6076e4bc`. Neither lock was changed by the manager
work. Nix packaging remains incomplete/unverified; do not suppress the assertion
or replace expected hashes merely to make evaluation pass.

The `.18` installed-manager end-to-end apply succeeded:
job `1790512401130373-2593`, candidate `1790512401147456-2602`, approximately
88 seconds from submission through activation. Native status reports
`custom_optimized`, generation 2, `plugin_healthy: true`, `operation: idle` and
no error. Manager `active.json` identifies that exact candidate. `/proc/2339/maps`
confirms the new candidate's `libapp.so` and the unchanged packaged
`libflutter_engine.so`; the compositor PID remains 2339. The runtime dependency
closure discovers only `denial_desktop` and `denial_taskbar` as plugins, with no
top-bar contribution. The session prerequisite check passes and the error-priority
journal has no entries since the new session started. This validates installed
Pub resolution, typed discovery, Dart AOT compilation, sealing, native activation
and startup acknowledgement together. No engine or Rust compilation occurred on
`.18`. App rendering remains user-validated; no screenshots or visual test events
were produced.

User-reported first-launch bug on `.18`: the initial GTK activation constructed a
hidden window and waited for `first-frame`, but did not realize the Flutter view.
The second activation called `gtk_window_present`, which finally realized it.
The Plugins runner now explicitly realizes the view after connecting `first-frame`,
matching the established Settings startup sequence. The release app rebuilt
successfully. Its new runner SHA-256 is
`d908fb7fa19f18f2c8429805ceab538549403fb34ddd9330d8fda5f7697d8d5c`;
`.18` now selects the verified immutable app directory
`/home/logix/.cache/denial/lab/artifacts/plugin-manager-app-d908fb7fa19f18f2`.
No running app or desktop process was terminated. The user must close their old
Plugins window and reopen it to exercise the corrected first activation; visual
confirmation is pending with the user.

## 10. App presentation and apply performance (2026-09-27)

The standalone app uses `denial_flutter_sdk` ShellTheme tokens, Denial's wordmark,
Settings-style navigation and grouped rounded surfaces. It observes saved
appearance preferences (light/dark, custom accent, font and roundness). Primary
pages are My plugins, Discover and Activity; compiler paths and local SDK options
belong under developer options. Required plugins are read-only and explained by
the resolved dependency chain. Selection switches stage choices; Apply changes
performs one composition change for the batch. Do not imply that a staged switch
has already changed the running shell.

Implementation invariants for acceleration:

- `enable NAME` restores an installed plugin's retained Git revision; it does not
  implicitly fetch a newer branch. Update remains explicit. Pub remains the
  dependency authority and still resolves each planned composition.
- Packaged Flutter tooling is compiled to a kernel snapshot once when preparing
  the build kit. The launcher runs that snapshot with the vendored package map
  and explicit local release-engine selection. The snapshot is in the kit's
  manifest and compiler fingerprint. Never run Flutter tooling from Dart source
  for every operation: this cost about 12 seconds per invocation on `.18`.
- Discovery caches resolved declarations by package contents, language metadata,
  dependency chains, SDK version/libraries and discovery format version. Static
  discovery resolves library elements and types; it does not analyze every widget
  method body. Generated wiring and method bodies are checked by the AOT compiler
  before activation. Bump cache formats when generation/discovery semantics change.
- Bundle cache keys cover composition inputs, Pub lock, runtime/SDK identity,
  generated wiring, ordering, platform, compiler inputs and raw engine checksum.
  A cache hit verifies output hashes and creates a fresh sealed candidate with its
  own provenance. Missing, incompatible or damaged entries fall back to compilation.
- File hash memoization requires unchanged size, mtime, ctime and mode; content
  hashing repeats if these change. This optimizes trusted local build inputs and
  is not a plugin security boundary. Native validation remains authoritative.
- A reused composition already active and healthy does not request another shell
  refresh or overwrite rollback history. Matching the build key alone is not
  sufficient: verify active artifact bytes and native status.
- Snapshots omit known generated native runner `flutter/ephemeral` directories;
  similarly named plugin asset directories remain inputs.
- GUI polling uses compact status, refreshes the catalog on demand/job completion,
  and slows to five seconds when idle. Active direct CLI jobs remain visible as
  busy even without a detached GUI job record.

Measured on `.18`, in isolated manager state with native activation disabled:

| Case | Plan | Build/verification | Total |
| --- | ---: | ---: | ---: |
| First taskbar composition | 11.31 s | 35.23 s | 46.54 s |
| Repeat identical composition | 1.49 s | 1.64 s | 3.13 s |
| First top-bar composition | 10.89 s | 27.51 s | 38.40 s |
| Return from top bar to cached taskbar | 2.06 s | 1.67 s | 3.72 s |

Earlier cached runs with the source-based tool launcher took approximately
38–40 seconds; its version query alone took 12.60 seconds versus 0.19 seconds
with the snapshot. These are single-run measurements, not latency guarantees.
They exclude native refresh and one-time kit preparation. Newly encountered
compositions still require Dart AOT compilation; no Rust/engine build is involved.
The user performs rendered-app validation. Backend regression coverage now has
27 passing tests, including input/cache invalidation, unchanged activation,
asset preservation, typed composition, provisioning and recovery; static analysis
and the standalone release app build pass.

Deployment: `.18` now selects app/backend artifact
`/home/logix/.cache/denial/lab/artifacts/plugins-e0f03dc8e0b25be8` and prepared kit
`b6dc6599a71fa1165dcd7725a5a194090bf0a673f5a9e3e9367c35ce540451a2`.
App/backend checksums and every kit manifest file/link were verified before
switching installed symlinks. The kit retains the prior runtime source identity.
Native PID 2339, generation 2 and healthy taskbar composition remain unchanged;
no shell bundle was activated and no app was launched for visual inspection.
Existing Plugins windows must be closed/reopened by the user to load the new app.

Local glass follow-up: Plugins now reads the saved transparency mode, glass
configuration and panel/card opacity, and paints its main/sidebar/card surfaces
through the shared theme helpers. The GTK host exposes per-pixel alpha and clears
its opaque region on realization/style updates, matching Settings' native setup.
Desktop backdrop glass belongs to the compositor; the client does not add a
second desktop blur. This app-only change does not require a shell restart.
The appearance watcher must recognize `FileSystemMoveEvent.destination`: Settings
publishes `.settings.json.*.tmp` by rename, so filtering only `event.path` misses
live slider updates. A real temporary-directory rename reproduced the failure and
confirmed the corrected predicate. Transparency is `1 - glass.opacity` (70% means
0.30 opacity). Client pixels still obey the compositor's separate alpha cutoff;
reading this setting does not bypass that cutoff or guarantee frost at every value.

The subsequent transparency split adds `appearance.glass.windowOpacity`. Legacy
documents initialize it from the shared `opacity`; saving writes both values.
Shell panels retain `opacity`, while Plugins and Settings use
`ShellThemeData.forWindowSurfaces()` for their window backgrounds. Changing shell
panel transparency no longer changes those app backgrounds after migration.
The two sliders leave foreground controls and whole-window focus opacity alone.

### Floating application layout

Plugins follows `docs/GLASS_UI_DESIGN_SKILL.md`. The upper area reveals Denial's
desktop through a faint 3/255-alpha backing rather than a decorative photograph.
This preserves shadows without isolated frosted patches at a zero pixel-alpha
cutoff. Sidebar and command glass use neutral black tint in dark appearance.
Actual app content sits on a lower
opaque #22211F surface extending behind the inset rounded glass navigation card.
Search and command groups float over the revealed upper area. There is no
full-width toolbar sheet or inset central content-card frame. The whole content sheet, including its charcoal backing, scrolls upward and
remains opaque. No scroll-edge fade is applied. Tab changes use the SDK content-only switcher:
page contents fade, while the charcoal sheet remains opaque. Short pages also allow the reveal gap to scroll away. Compact windows use
horizontal navigation and allow search on a separate row, conserving content height.
Installed plugins use separated rows; Discover uses adaptive tiles.

Shared materials and the frame come from the SDK's `materials.dart`, specified in
[APPLICATION_MATERIALS.md](APPLICATION_MATERIALS.md). Plugins is the first consumer
for Denial theming. Client filters sample available app pixels; the compositor
supplies desktop glass where upper-region client pixels are translucent. The lower
content stays opaque. Palette, floating edges, shadows and curvature are SDK
choices. Window opacity and live settings updates govern functional glass.
Transparency off or fully opaque settings also fill the upper region. Existing
shell helpers and unmigrated apps retain their behavior.

Installed and Discover search names/descriptions. Ctrl+F focuses search;
Ctrl+1/2/3 selects Installed/Discover/Activity. Apply remains available in the
explicit toolbar overflow menu. Actionable errors are shown at the bottom outside
the scrolling sheet, retaining View details and Dismiss. The entire bottom region
has opaque content backing, including padding. Nested surface corners derive from
Denial's window radius with `max(4, outerRadius - inset)` through the SDK geometry
scope, rather than independent roundness tokens. Sidebar and top command groups
use a shared 8-pixel outer inset; the minimum nested radius is 4 logical pixels. An inset glass
status group appears
only while work is running or the configured selection needs applying. A build
alone is not activation: `selectionNeedsApply` checks revision, native bundle,
health, active mode and cached reuse. The brief backend status retains only
`status`, `bundle`, and `reusedFrom` from the build record for this purpose.
The standalone `tool/check_selection_status.dart` checks activation/recovery
cases without a Flutter development engine.

Repository installation, dependency details, setup, updates, compatibility,
recovery, configuration and background job handling remain available. User
selection is described as selected until Apply activates the composition.

The user authorized app-only screenshots for this redesign. Use foreign-toplevel
capture (`grim -T IDENTIFIER`) for Plugins; do not capture the desktop. A stale
Flutter asset-target stamp previously retained the old icon subset after Dart
changes; invalidate the app's `release_bundle_linux-x64_assets.stamp` before its
next build if required to regenerate that subset. No engine rebuild is needed.

## 11. Distribution validation follow-up

Alpine adaptation now covers the Plugins GTK executable, backend and dynamically
linked compiler executables in the shipped kit. It adds the same process-local
gcompat/resolver/stack bridges as the existing Alpine runtime. The adapter verifies
the original kit manifest first, changes compiler executables only, and records
their new hashes. Runtime sources, raw engine and source identity remain intact.
The prepared-stage/tag-promotion branch continues to copy the retained payload
without compiling or adapting it again.

Do not run `patchelf` directly on the compiled backend: Dart's executable contains
an appended AOT snapshot with a footer at EOF. Direct patching displaced that
footer in validation, turning CLI arguments into runtime arguments. The adapter
patches the runtime portion, preserves the AOT payload, then emits the pinned
SDK's 64K-aligned snapshot offset/footer. Unsupported formats fail explicitly.

Verified in an isolated Alpine 3.24 container using actual staged artifacts:
backend help, relocated Flutter tooling, full kit verification/provisioning,
built-in selection, Pub resolution, typed discovery and a real release build.
Candidate `1790515047320964-128` sealed successfully with raw engine SHA-256
`924c80b40b1edb14481698fa10158078888f8051f0e2de7f9bd9d92af634f216`.
No native activation or graphical app launch was performed. This proves the
compiler path on Alpine; it is not a complete signed APK installation/release test.

RPM `%check` now checks executable existence instead of accidentally invoking the
new app. Debian/RPM metadata verification requires the app, backend, compiler-kit
manifest, source marker and desktop entry. Subsequent package build/install
validation is recorded in sections 12–13.

Nix compiler-kit wiring is now implemented but not build-verified:
`nix/plugin-build-kit.nix` packages the existing Nix engine/compiler and runtime
sources through the shared kit builder. The installed CLI sets
`DENIAL_PLUGIN_BUILD_KIT`, and the installed shell receives that kit's exact source
marker. Nix records its own engine output hash; it must not claim the checksum of
the independently packaged native build. The immutable Flutter SDK's metadata now
records the locked framework revision instead of Nixpkgs' synthetic revision.
The shared builder accepts an explicit source root/revision for builds without a
Git checkout and obtains generated SDK packages from the engine when absent from
the SDK cache. Nix syntax parsing and the shared packager-input build path pass;
these checks do not prove an actual Nix build.

The authoritative Nix lock-refresh procedure was attempted in an isolated source
copy. GitHub returns HTTP 404 for the locked Flutter source archive at
`2a731ef8427d07683160dd35a5bd02e767a11467`. A networked `git ls-remote` reports
published branch `denial/3.47.5-r1` at
`ebd51fef0d31ba0bfe04a0129795fb9b6115b3e0`; the locked revision is present in the
canonical local fork. No fork commit was published and neither authoritative
source lock nor checked-in Nix engine lock was changed. Nix build verification
requires making the already-selected source available and refreshing its verified
Nix hashes, not bypassing the lock assertions.

That failed fetch exposed a maintenance transaction bug: its EXIT trap referred
to a function-local backup after the scope unwound. The backup now survives until
commit/rollback. Both the actual fetch failure and the offline regression command
`tools/test-denial-nix-lock-rollback` confirm byte-identical restoration of the
original lock.

## 12. Native package and recovery audit

Native staging completed at
`/home/logix/.cache/denial/plugin-package-validation/input/native`, version
`0.2.1.r139.gcbed587a.dirty-1`. The staging check now includes shipped compiler
executables in the GLIBC 2.39 baseline, in addition to the compositor and apps.
The engine build was a verified no-op; routine staging rebuilt the native
compositor for its development build identity. No device/session was restarted.

Using that staged payload, the repository package scripts built Debian, Fedora
RPM and openSUSE RPM artifacts successfully. Their control/metadata checks and
byte-for-byte payload comparisons pass, including the new manager files.
Artifacts are retained under
`/home/logix/.cache/denial/plugin-package-validation/packages`.

The Debian packages installed with their declared dependencies in an isolated
Ubuntu 24.04 container. Service startup was disabled. App loader dependency checks
pass; the installed CLI prepared its kit and a detached worker produced plan
`1790516473745250-6649` (job `1790516473714996-6637`) with the desktop/top-bar
composition. This is an actual package installation check. Subsequent RPM,
Arch and APK checks are recorded below; Nix remains a separate verification
boundary. No graphical app was launched.
The same installed manager subsequently compiled and sealed that plan using only
the packaged/prepared tools, retaining engine SHA-256
`924c80b40b1edb14481698fa10158078888f8051f0e2de7f9bd9d92af634f216`.
Native activation was disabled throughout the container test.

Recovery audit fixes after that packaging snapshot:

- Mirror clones and completed checkouts are published by same-filesystem rename.
  Failed work never leaves a partial directory under the reusable cache key.
- Successful activation/rollback remembers each installed root's confirmed
  revision. Disable/apply/re-enable no longer loses a previously applied update.
  Failed activation does not replace retained installed pins.
- Tests exercise a detached worker after its submitting process exits, from both
  Dart source and a compiled executable. The complete backend suite now passes
  30 tests, and static analysis passes.

The latest compiled backend is deployed on `.18` at
`/home/logix/.cache/denial/lab/artifacts/plugin-backend-1e75cb32bd00da98`, SHA-256
`1e75cb32bd00da98d0730866a59c3de8f20a02e83711291c93f0bec893e88c53`.
Native PID 2339/generation 2 remain healthy with desktop/taskbar selected. The
standalone app and shell were not restarted. The package artifacts above predate
these final backend-only recovery fixes; do not treat them as final release
payloads or claim they prove a future exact-commit promotion.

## 13. Distribution installation checks

The actual local package pairs install with their declared dependencies in
isolated Ubuntu 24.04, Fedora 44, openSUSE Tumbleweed, Arch Linux and Alpine 3.24
containers. CLI startup and installed compiler-kit preparation pass on all five.
App loader dependencies pass on the glibc distributions. No graphical app,
notification, or interactive desktop test was launched. These are unsigned local
development artifacts, not release/promotion evidence.

Arch and Alpine package builds, metadata checks and byte-identical payload
verification pass. Alpine development versions containing `.dirty` use the legal
APK `_p0` suffix; clean version translation is unchanged, and runtime metadata
retains the full development identity.

APK extraction previously used `--exclude '.*'`, unintentionally omitting nested
compiler inputs such as `.dart_tool/package_config.json` and the installed shell's
`.denial-ui-source.json`. The old payload verifier repeated the exclusion and
therefore missed the damage. Both paths now use `tools/extract-denial-apk-payload`,
which preserves hidden payload entries and removes only known root APK metadata.
Unknown root dotfiles fail verification. `tools/test-denial-apk-payload` exercises
the extraction and real verifier; the corrected verifier rejects the previous
incomplete retained payload, and the rebuilt retained payload passes. This also
preserves the source identity required for custom bundle activation.

The installed Alpine manager also planned, compiled and sealed the reference
desktop/top-bar composition, candidate `1790517341067598-71`, using only its
packaged compiler kit. Its raw engine hash remains
`924c80b40b1edb14481698fa10158078888f8051f0e2de7f9bd9d92af634f216`.
Native activation was disabled for this container check.

Evidence logs are retained in `/tmp/denial-plugin-{fedora,suse,arch}-check.log`,
`/tmp/denial-plugin-apk-build.log` and
`/tmp/denial-plugin-apk-installed-{check,plan,build}.log`. The Debian release build
evidence is recorded in section 12. The Nix source-publication dependency described
in section 11 remains unresolved; neither source lock has been changed to bypass it.


## 14. Automatic installation and local activation preparation

Accepted requirement: users MUST NOT configure source, compiler, engine, backend,
or control-tool paths, set flags, or enable a development mode to use Plugins.
The sole optional plugin-infrastructure override is `DENIAL_SDK_PATH`, pointing
to the directory containing `denial_sdk/` and `denial_flutter_sdk/`. Ordinary
HOME/XDG conventions and plugin source/ref/package choices are not tool setup.
This section supersedes earlier manual setup examples and kit-location variables.

Implementation:

- Build/packaging-owned `denial-plugin-manager.installation.json` beside the app
  locates the compiled backend. `denial-plugins.installation.json` beside that
  backend locates native control and the matching release compiler kit. Paths
  are relative for native/development installations and store-owned for Nix.
  Discovery does not depend on the launcher's working directory or PATH.
- On app startup, `bootstrap` reuses or submits a detached `initialize` job.
  Initialization verifies and copies the kit once, then seeds the built-in preset
  only for a previously untouched selection. Disabled defaults remain disabled.
  Kit identity and expected paths determine whether preparation is needed after
  an installation upgrade. Routine polling does not hash/copy the compiler tree.
- Mutations also initialize automatically. Settings hold generated cache locations;
  they are not user infrastructure preferences. The GUI has no compiler paths,
  setup button, or development-SDK checkbox. It presents preparation progress,
  retry after failure, and ordinary plugin selection/Apply actions.
- Both SDK packages always resolve from one installed SDK snapshot. Local plugin
  path dependencies are redirected before snapshotting so another checkout (or
  an absent old checkout) cannot create duplicate SDK identities. Hosted version
  constraints remain validated. `DENIAL_SDK_PATH` substitutes only those SDK
  inputs, never the installed compiler, engine, or native compatibility checks.
- Applying checks native activation support before expensive planning/building.
  A running pre-activation compositor reports that a logout/login is needed.
  The app does not terminate the session. Subsequent plugin changes use the
  existing bundle replacement and startup-health path, without an engine build.
- `tools/denial-pc plugin-manager` writes development discovery metadata and
  retains the previous app bundle to avoid overwriting mapped libraries. The
  development session installs the Plugins desktop entry automatically when the
  built app exists. Native staging rewrites metadata for its installed prefix;
  RPM inventories and payload checks include it. Nix uses derivation-owned paths.
- The public collection catalog now defaults to `denialwm/denial-plugins`, as
  described in section 5. Built-ins and direct Git/local installation also work.

Validation for this change is recorded below. Historical package-installation
results above predate these discovery changes; they are not exact-payload proof
of the updated installer. Nix still has the source-publication blocker recorded
in section 11.

Validation completed on the local development machine (2026-09-27):

- Backend analysis and the full backend suite pass; additional regressions cover
  initialization/default persistence, SDK path substitution, installation
  relocation, and old/unavailable/current native preflight. App analysis and all
  eight pure-Dart selection-status checks pass. No Flutter debug engine was built.
- `tools/denial-pc compositor` and `compositor-test` pass, including sealed bundle
  source/engine validation and startup recovery. Prepared `deniald` SHA-256:
  `30eda3049c4a8925990d15520960abea8f677d1191f527cec58107db06d6f6f1`.
- `tools/denial-pc plugin-manager` built the updated app, backend and release kit.
  Two consecutive bootstrap calls reused initialization job
  `1790539047257923-308418`; it completed with no user configuration.
- A relocated native staging tree resolves its app/backend/kit paths correctly
  without PATH or environment overrides. This is a staging/discovery check, not
  a fresh five-distribution package-installation matrix or a Nix build.
- Built-in top bar candidate `1790539126553682-309158` and external taskbar
  candidate `1790539252511593-310598` both compiled and sealed. Both retain raw
  engine SHA-256 `924c80b40b1edb14481698fa10158078888f8051f0e2de7f9bd9d92af634f216`.
- Planning again with `DENIAL_SDK_PATH=/home/logix/denial/packages` produced
  `1790539404708170-315063`. Identical SDK bytes reused typed discovery and the
  verified taskbar binary: planning 2.35 seconds, reuse/sealing 2.80 seconds.
  These timings exclude native activation and are not a cold-build promise.
- Local installed roots include desktop, top bar and the sibling taskbar package;
  selected roots remain desktop/taskbar. The development Plugins launcher entry
  points to the updated app. No environment override was persisted.
- Native PID 1175 remains the old mapped executable. No bundle was activated,
  graphical app launched, screenshot taken, or session restarted. User logout
  and login to `Denial (development)` are still required before real activation
  can be checked. No experimental engine is armed. Do not claim live switching
  is verified until that native session transition and user test occur.

## 15. Operation feedback (2026-09-28)

Detached worker status now carries `progress: {completed, total, label}` for
known operation stages. Apply/update have five stages: preparing dependencies,
checking compatibility, compiling/reusing the shell, verifying/sealing, and
native activation/health confirmation. Other operations use their own counts.
The count describes completed stages, not elapsed-time or compiler percentage.
Unknown diagnostics retain the previous stage; success completes the count.

The bottom indicator includes a linear progress bar and stage label. Section 19
refines this into an animated activity line with stage counts in text. Worker failures and interruptions are
observed independently of whether a poll saw the job running, and replace the
ready-to-apply message with a persistent explanation, technical details and a
Dismiss action. Dismissal or starting another operation clears the notice without
polling resurrecting the same failure. Reopening shows the latest failed request,
not older errors preceding a successful operation. Nested planning jobs cannot
produce duplicate operation notices. The opaque footer backing is unchanged.

The reported local failure was a panel conflict: both `denial_top_bar` and
`denial_taskbar` were selected. Native work-area reservation now uses the exclusive `ShellWorkArea`; UI surfaces are a collection.
The GUI explains that one panel must be disabled, and new compiler diagnostics
list the conflicting provider types. No automatic selection change is made.

Validation: backend analysis and all 36 backend tests pass; app analysis, twelve
pure-Dart feedback/progress checks and eight selection-status checks pass. The
release Plugins app and backend were rebuilt locally, preserving the running
app's mapped libraries and existing installation metadata. The compiler kit,
engine and compositor were reused. No app or session was restarted, plugin
selection changed, bundle activated, or visual test triggered. Reopen Plugins
to load the updated footer; no session restart is required for this change.

## 16. Selection preflight and error presentation (2026-09-28)

Accepted extension: plugin authors may publish lightweight compatibility claims
for immediate selection checks. These claims are advisory; typed discovery and
composition validation remain mandatory and authoritative. This is not a second
package dependency resolver, runtime plugin registry, or replacement for Pub.

Schema in the plugin's existing `pubspec.yaml`:

```yaml
denial_plugin:
  schema: 1
  name: Reference Desktop
  provides:
    - contract: package:denial_flutter_sdk/application.dart#ShellApplication
      # count: 1 is the default; positive counts may represent multiple providers.
  requires:
    - contract: package:denial_flutter_sdk/surfaces.dart#ShellWorkArea
      label: Desktop panel
      min: 0
      max: 1
```

Each `provides` item names a fully library-qualified contract, with optional
positive `count` (maximum 1024). Each `requires` item names the contract and its
human-readable label, with `min`/`max` defaulting to 1; explicit `max: null`
allows an unbounded collection. `name` is the plugin's display name. Contract IDs
are serialized identities of the actual Dart contracts, never bare class names.
No taskbar/top-bar exclusion list or component-name registry is introduced.

`SelectionPreflight` reads selected packages and reachable local path dependency
manifests only. It does not fetch, analyze Dart, run Pub, or execute plugins.
Shared local dependencies count once. The manager's existing required
`ShellApplication` entry contract requires one desktop provider. Explicit typed
provider selections are deferred to the full composition check.

Known excess providers block Apply even when other dependency sources remain
unknown. Missing providers block only when the available source declarations are
complete; hosted/Git dependencies, unavailable paths and legacy packages without
claims make that check partial. They do not trigger downloads on switch changes
or incorrectly block a feature that Pub may bring in transitively. The platform
SDK/runtime packages and Flutter SDK dependencies are not activatable plugins.
All actual plugin dependencies remain declared in ordinary Pub `dependencies`.

Backend status includes revision-stamped preflight results and readable issues.
The app evaluates its local draft using cached declarations and disables every
Apply entry point while known conflicts exist. Switches do not submit jobs or
wait for backend status (see section 17). Known conflicts name the plugins and required capacity in
the bottom indicator. Backend plan/apply/update repeat the check under the
mutation lock before running the expensive pipeline. A source/metadata change
or incorrect declaration may still fail full typed composition checks.

Errors no longer concatenate progress output into `Operation failed (1) ...`.
Detached workers preserve the actual multiline diagnostic; progress remains in
its log. `job-details ID` returns that log on demand with validated job IDs.
The dialog leads with an actionable explanation, then separate collapsed
Technical details and Build log sections with selectable, monospaced output.
Legacy errors are split at their recorded `denial-plugins:` diagnostic marker,
so old failure records also receive the new presentation without rewriting them.

Validation: backend analysis and all 43 backend tests pass; app analysis, eighteen
pure-Dart feedback/preflight checks and eight selection-status checks pass. The
local release app/backend and updated built-in kit were built and prepared.
Read-only checks against the actual installed selection identify Taskbar/Top Bar
as the conflicting providers. Removing either root in an in-memory selection
clears the issue; the user's saved root choices were preserved. Warm preflight
averaged 2.63 ms across 25 checks (excluding process startup/native status IPC).
The existing native custom composition remains healthy. No application/session
restart, activation, screenshot, or interactive test event was performed.


## 17. Window-local selection drafts

Switches MUST change only an in-memory draft. They MUST NOT invoke a subprocess,
resolve sources, write selection/installed state, create jobs, set busy/loading,
or restart polling. Enable from Discover, Add after repository inspection, and
Use Denial defaults also stage a draft. Repository inspection remains explicit
I/O to discover packages; it does not select them. Closing the app discards an
unapplied draft. Discard restores the latest saved selection.

`SelectionDraft` owns the saved base revision and proposed roots. Normal status
polls update the baseline only when clean or when the saved roots acknowledge
the draft. Otherwise polling preserves edits. Another client's changed revision
marks the draft stale and blocks Apply until Discard. Toggling back to the base
selection clears dirty state without a write or revision increment.

Apply wording distinguishes local edits from saved work waiting for activation.
Use **Apply changes** while the window has selection edits, and **Apply pending
actions** when the draft is clean but the saved composition still needs applying.
The supporting text explains whether the user's selection changed or pending
updates remain. Local edits take precedence when both exist. Hide Apply when
neither exists, including in the toolbar menu; compatibility errors and progress
remain visible independently. Activity history uses neutral operation names
because a completed job does not retain the window's draft state.

A saved, previously applied composition that fails native startup is a recovery
error, not a new pending action. Show the native failure and retain the saved
selection. Do not offer Apply solely because startup fell back to the packaged
shell. A subsequent selection change or newly built candidate can still require
Apply. Engine compatibility failures must remain enforced; a session using an
experimental engine cannot load a bundle built for a different engine hash.
A composition rejected because Denial itself was updated is not a recovery
error; section 21 rebuilds it instead.

`SelectionPreflight.describe` collects normalized declaration facts and dependency
edges for disabled as well as enabled installed/catalog packages. Status and
catalog transport these caches to the app. Both clients use the pure Dart
`denial_sdk/plugin_selection.dart` evaluator; switch-time checking traverses only
memory. Unknown declarations retain section 16's partial-check semantics.
Actual files and actual Dart types remain authoritative at Apply time.

Apply submits one detached `apply --draft JSON` operation, carrying the expected
selection revision and desired root sources. Under the existing manager lock,
`commitSelectionDraft` rejects stale requests, retains known source identities
and pins, resolves new sources, rechecks declarations, and saves all roots in one
atomic selection-file replacement with one revision increment. Invalid drafts
leave selection unchanged. Build/activation continue in the same job. If the
later build fails, saved intent remains pending and the working desktop stays
active. Errors remain visible. An unchanged draft preserves the revision.

The app suppresses stale dependency-chain presentation and disables the optional
full compatibility plan action while a local draft exists. Apply performs the
full check for that draft. No local compositor/session restart is needed for this
manager-only behavior change.

Validation: 48 backend tests, 11 pure-Dart draft/cache checks, 18 feedback checks,
and eight selection-status checks pass; backend/app analysis is clean. The local
release app, backend and build kit are rebuilt. Compiled-backend status exposes
all three installed plugin declarations. No user selection was applied, app
launched, session restarted, or visual test triggered during this change.

Development installation metadata must survive Flutter's destructive CMake
bundle install. `denial-pc plugin-manager` now writes the app sidecar in the
release build directory, outside `bundle/`, before building the app. CMake copies
it into each rebuilt bundle. Do not postpone app metadata publication until the
larger compiler-kit packaging step completes. Clean distribution builds omit the
development sidecar; package staging continues to install distribution paths.
A regression check exercised first install, repeated destructive install, and
clean packaging without development metadata. The plugin backend is invoked on
demand, not a service users must start after reboot. Missing app-side metadata
means an incomplete installation, not a stopped service.

## 18. Compatibility-check performance

The switch-time declaration check remains synchronous and in memory. Apply's
resolved Dart check additionally validates actual SDK annotation identity,
constructor injection and implementation types; never replace it with claims
from `pubspec.yaml` or execute plugins to discover their declarations.

Typed discovery limits candidates to packages whose declared dependency closure
reaches `denial_sdk`, including transitive SDK imports through re-exporting
packages. Unrelated Flutter/platform/web libraries with library annotations
(e.g. `@JS`) are not Denial plugin candidates. Preserve prefixed/re-exported
annotations and actual element identity checks. Resolve SDK marker classes once
per discovery, not once per library.

The analyzer previously discarded all parsed/resolved information when each
worker exited. Planning and the `discover` command now share its file byte store
at `cache/analyzer`. Analyzer keys incorporate input signatures and serialization
salts; its byte store checks stored checksums and treats corrupt/missing records
as cache misses. A source change must still invalidate affected type information.
The internal analyzer API required to select a byte store is isolated in
`analysis_cache.dart`; the public factory hardcodes an in-memory store. Test this
adapter when updating the locked analyzer dependency. An unavailable cache falls
back to ordinary analysis. The existing complete-discovery cache remains the
first fast path; its format is bumped to 3 for the candidate-filter behavior.

On the actual desktop/taskbar candidate, fresh-process profiling measured
approximately 20.3 s before the change, 16.3 s with filtering and an empty analyzer
cache, and 1.9 s with persisted type information. A different retained composition
(Reference Desktop without either panel) took 1.6 s with that same type cache.
Contract matching took 3–6 ms; compiler fingerprinting was about 0.5 s. A cold SDK
or substantial new dependency graph still requires initial analysis; do not claim
all first-time setup or downloads are instantaneous. Compiler input preparation
now reports its own phase instead of leaving the compatibility label visible.

Validation: all 49 backend tests pass, including persisted-cache equivalence,
prefixed annotations through re-exports, and rejecting a provider changed after
its first cached analysis. No plugin selection or runtime activation is needed
to deploy this backend-only change.

Installed AOT-backend verification: `discover` against the current retained
candidate took 9.314 s to populate an empty analyzer cache, then 0.975 s in a fresh
process; checking the other retained composition took 0.784 s. Each result matched
its original saved discovery record exactly. Selection bytes were unchanged and
no build/activation was requested. These AOT timings are more representative of
the app than the source-run profiling numbers above. The local manager cache is
now populated for the user's current toolchain.


## 19. Live compilation feedback

The Apply footer and running Activity entries use an indeterminate animated line
while work is in progress. Keep the true operation-stage count in text; do not
present it as a percentage of compilation or advance it with an invented timer.
`ProgressText` updates elapsed time for the current substep once per second,
independently of backend status polling. Dispose its timer when it leaves the
widget tree. Screen-reader semantics announce the stable phase description,
without announcing the clock on every tick.

The release assembler runs with verbose output. `runCommand` optionally streams
lines from both stdout and stderr concurrently while retaining output and exit
status for failures. `CompilerProgress` accepts anchored target-start messages
from the pinned Flutter tool, tolerating its elapsed-time prefixes and ANSI
formatting; it ignores command echoes, target completion/skip records and
unrelated parallel targets. Map actual starts as follows:

- `kernel_snapshot_program`: Compiling Dart sources.
- `aot_elf_release`: Optimizing and generating native code.
- `release_bundle_linux-{x64,arm64}_assets`: Preparing assets.

These are all substeps of compilation (operation step 3 of 5). A verified bundle
cache hit retains the existing reuse path and emits no fictional compile phases.
The detached worker records a UTC `progress.started` timestamp when a recognized
phase changes; repeated or unknown diagnostics do not reset that timestamp.
Older jobs without timestamps retain ordinary progress text. The UI clamps
negative elapsed values if the system clock moves backward.

Validation: 52 backend tests pass, including a child-process handshake proving
output reaches the callback before exit, draining a large stderr pipe, preserving
nonzero-exit diagnostics, and verbose target parsing. The app's 22 feedback checks
cover clock advancement/reset and stable accessibility text. Backend/app analysis
is clean. No screenshots, visual tests, plugin activation or session restart are
needed to validate this change.

## 20. Recoverable backend discovery during app replacement

The earlier sidecar reinstall fix did not cover open-app publication windows or
latched connection errors. A running app can outlive the path of its original
bundle. A restored sidecar alone cannot clear the previous controller's `_error`,
which was also used for persistent operation failures.

`BackendInstallation` now remembers a successfully resolved backend while that
executable exists. On Linux, fresh discovery reads `/proc/self/exe` to follow a
renamed retained application rather than relying exclusively on Dart's cached
startup path. It first reads the executable-adjacent sidecar. A development
installation may also provide an independent parent descriptor explicitly marked
`application: denial-plugin-manager` with an absolute backend path. `denial-pc`
publishes that descriptor and backend metadata by rename before replacing the
bundle; CMake also copies the descriptor beside the new application. Ordinary
packaged/Nix sidecars and their relative/absolute paths remain supported. Never
search PATH, guess another checkout, or ask users to configure a backend path.

Missing/incomplete discovery information is retryable with a readable diagnostic,
not an exposed FormatException. Backend status lazily bootstraps the idempotent
setup and retries setup after a launch/discovery failure. Connection health and
its transient message are independent from submitted-operation/job failures.
Successful polling clears connection feedback; dismissing its text alone cannot
enable Apply while disconnected. A recovered connection never erases a failed
Apply or automatically resubmits one. Polling preserves existing selection drafts.

Validation covers relative paths with reserved URI characters, missing/corrupt
sidecars, retained bundle paths, stable-descriptor fallback, missing cached
executables, repair in the same client, bootstrap retry/reuse, and no automatic
Apply submission. Feedback checks also cover clearing a stale connection error,
keeping Apply disabled after dismissal, and preserving real operation failures.

## New built-ins remain disabled on upgrade

Build-kit preparation registers newly shipped built-in packages in the Installed
list, alongside refreshed source records for existing built-ins. Registration
never adds selected roots. Defaults are still selected only on first setup or
through the user's explicit defaults action; a new default plugin therefore
appears with its switch off for existing users. Existing external packages with
the same package name retain their source record. Regression coverage checks a
kit upgrade that introduces a default launcher while preserving the selected bar.

## Public collection validation (2026-09-30)

The first public collection is
[`denialwm/denial-plugins`](https://github.com/denialwm/denial-plugins), with
`denial_taskbar` at `plugins/denial_taskbar`. Commit
`4b7adf998852b09b9a91c1cfab48be58debf2e80` is pinned by the shell Pub lock and
the Nix flake input. The catalog points at the repository and package path without
selecting or activating it.

Headless validation covered first-use catalog discovery from the public URL,
multi-package inspection, exact-commit installation, offline error caching and
explicit retry, preservation of custom or disabled catalog settings, and kit
upgrade without selection changes. The full backend suite passed 60 tests. An
isolated composition replaced the built-in top bar with the published taskbar,
resolved and discovered its typed providers, compiled a release AOT bundle, and
sealed the candidate without activating the local desktop. The taskbar package
also passed analysis and its three pure-Dart suites.

Nix evaluation pins the same collection commit as Pub, vendors only the selected
package into the generated source, rewrites that generated source to an offline
path dependency, and passes lock consistency plus full flake evaluation. The UI
development workspace performs the equivalent vendoring from Pub's exact resolved
Git package, so local, packaged, and Nix builds no longer depend on an adjacent
standalone taskbar checkout.

## 21. Restoring plugins after a Denial update

Every Denial release changes the installed source identity. At the next login
deniald therefore rejects the composition it last confirmed and starts the
packaged shell. Previously nothing explained the change: the selection stayed
saved but inactive until the user opened Plugins and applied it again. A
package hook cannot rebuild for the user: it runs as root, outside the session,
possibly without Dart. The rebuild happens in the user's session after login,
while the packaged shell keeps the desktop usable.

Accepted behavior (2026-10-03):

- deniald treats a rejection as an update only for the selected composition it
  had confirmed before, and only when validation rejects it for a different
  Flutter generation or installed source identity. The engine is never a
  reason to reject (section 22). Seal, checksum, manifest and repeated-start
  rejections keep the section 17 recovery error.
- For an update, deniald keeps the selection, reports no error, and publishes
  `plugin_rebuild: {reason, bundle, version, installed_source}` in its UI
  state. `reason` is `source`, `flutter_generation` or `engine` (section 22);
  `version` is the installed release from `share/denial/version`, the build
  identity of a development build, or empty for `engine`; `installed_source`
  is the shell's `.denial-ui-source.json`, absent for a bundle without one.
  The field clears when a composition is confirmed or the packaged shell is
  explicitly restored.
- deniald starts `denial-plugins resume` once per compositor start when it
  reports `plugin_rebuild` and the Plugin Manager is installed. The packaged
  session exports `DENIAL_PLUGINS_BINARY`; otherwise deniald searches `PATH`.
- `resume` posts a notification at once, submits one detached `rebuild` job,
  and mirrors only its outcome. The job is visible in Plugins with its stages:
  preparing, checking compatibility, compiling, verifying, switching when you
  pause, and applying. A single `resume.lock` keeps one notifier per session.
- `rebuild` restores the composition deniald was running: that candidate's
  roots, provider selections, ordering, Pub lock and Git revisions, with
  built-in sources from the installed release. It never fetches newer plugin
  revisions; **Check for updates** remains the explicit update operation. When
  the saved selection is the same composition, the candidate carries the saved
  revision and nothing remains pending. Otherwise the saved selection stays
  pending for Apply after the restored composition returns. Built-in roots are
  the same intent across releases by name; Git and local roots must keep their
  source. Local plugins are read from their folders as they are now, like
  Apply.
- Before compiling, `rebuild` requires the identity its build tools stamp to
  equal the installed one that deniald reports. A mismatch means this plugin
  manager belongs to another Denial than the session runs; nothing is
  compiled.
- An automatic rebuild switches the shell only at a quiet moment: the session is
  unlocked, no input arrived for 2.5 seconds, the shell does not capture the
  keyboard, no visible application inhibits idling (a playing video, for
  example), and no runtime transition is running. deniald reports these facts
  as `session_activity: {locked, input_idle_ms, shell_captures_keyboard,
  idle_inhibited}` in every `ui status` reply; the policy lives in the backend,
  which asks again just after the idle threshold would pass. The manager lock
  is released while waiting, so Plugins stays usable. Someone watching the
  rebuild in Plugins is rarely idle, so Plugins offers **Switch now** while it
  waits (`denial-plugins rebuild-now`). `rebuild --now`, used by Plugins'
  **Rebuild plugins** and the **Try again** action, switches as soon as it is
  built, like Apply.
- Activating a rebuild candidate requires that deniald still waits for the same
  composition. If the user restored the packaged shell or applied another
  composition meanwhile, the rebuild finishes without switching.
- Automatic rebuilding runs once per installed build kit and composition,
  recorded in `resume.json`. A failed attempt is not repeated at later logins;
  each later login posts a reminder instead. **Try again** and Plugins'
  **Rebuild plugins** remain available. A download failure is not a failed
  attempt: the rebuild continues when NetworkManager reports the connection
  back, or after 30 seconds, 2 and 5 minutes when nobody can tell, and the
  next login tries again.

The user sees one notification that changes at most twice. Replacing a
notification raises its banner again, so stage changes are not published; the
stage-by-stage progress stays in Plugins.

| State | Title | Actions | Expires |
| --- | --- | --- | --- |
| Rebuilding | Bringing back your plugins | Open Plugins | when replaced |
| Restored | Your plugins are back | What's new (release versions only) | normally |
| Failed | Your plugins couldn't be rebuilt | Try again, Check for updates, Open Plugins | never |
| Offline | Your plugins are waiting for a connection | Try again, Open Plugins | never |
| Later login | Your plugins are still paused | Try again, Check for updates, Open Plugins | normally |

**Check for updates** appears only when the composition has Git plugins.
The texts say that the plugins and their settings are kept, that no logout is
needed, and which release the desktop was rebuilt for. They do not mention
bundles, compositions or source identities.

`resume` stays until the rebuild finishes, even when its progress notification
was dismissed, because the outcome still matters. Afterwards it keeps running
only while its notification can still be acted on: it exits when that closes,
and closes a failure notification itself once deniald no longer reports
`plugin_rebuild`, because the user fixed it in Plugins or chose the packaged
shell. A session that stays unavailable for a minute ends it. When the user
restores the packaged shell during a rebuild, the notification closes quietly.
Plugins is opened through its desktop entry, with the activation token that
came with the action; the action is offered only when that entry is
installed. deniald launches `resume` before its event loop serves
notifications and control requests, so `resume` waits for both. It never
D-Bus-activates the notification service: that could start another daemon in
place of Denial's. Without a notification server the rebuild still runs.

Example copy for Denial 0.3.0:

- Rebuilding: "Denial 0.3.0 is installed. Your plugins and their settings are
  safe: they're being rebuilt in the background and will come back on their
  own. No need to log out."
- Restored: "Everything is as you left it, now on Denial 0.3.0. Thanks for
  waiting."
- Failed: "One of them may need an update for Denial 0.3.0. Meanwhile, Denial
  uses its standard desktop. Your plugins and their settings are safe."

A development build is described as "Denial was updated" or "this Denial
build", never as a release, and gets no **What's new** action.

Follow-up, not implemented: building the new composition before the next login.
The old session keeps running after a package upgrade, so the manager could
notice the new build kit, rebuild in the background, and stage the result for
deniald to try first at the next login with the usual startup confirmation.
This needs a staged-candidate field that the old compositor never rewrites, and
must not activate a candidate in the old session: that compositor still maps the
old engine while validating against the new files on disk.

## 22. Which plugins load, development checkouts and the command line (2026-11-18)

This section supersedes, where they differ: the engine comparison and the
plan-versus-build checks of sections 9, 12 and 14, the manager's own record of
the active composition, and the `plan`, `build ID`, `activate ID` commands.

### Which plugins load

Two rules decide whether deniald loads a composition:

1. **It was built for this Denial.** The bundle's `source_identity` equals the
   shell's `.denial-ui-source.json`, and its Flutter generation is deniald's.
   A release is named by the marker of its build kit, which changes with every
   release. A development checkout is named by its path alone:
   `{"schema": 1, "development": "/path/to/checkout"}`. Commits, edits and
   engine rebuilds keep that name, so they never turn plugins away.
2. **The engine accepts it, proven by starting it.** The shell must show its
   first frame. When it does not, deniald goes back to the desktop it was
   running and reports the error.

A confirmed composition that fails rule 1 is rebuilt (section 21); it is never
an error. The engine is not compared before starting. The manifest's
`engine_sha256` only says which engine the composition was compiled against:

- `ui status` reports `plugin_engine_differs` while such a composition runs or
  starts. It is loaded all the same.
- When the confirmed composition does not start at login on another engine
  than it was compiled against, or the previous login died starting it,
  deniald publishes `plugin_rebuild` with reason `engine` and the manager
  rebuilds it against the session's engine.
- A composition that was just requested and does not start is a plain failure:
  the command returns deniald's error and the desktop that ran stays.

deniald still requires a sealed (read-only) bundle, a readable manifest and
matching checksums of `lib/libapp.so` and `data/flutter_assets`: they catch a
damaged build. The manager still checks plugin conflicts and the SDK boundary
before compiling.

A bundle holds `lib/libapp.so`, `data/flutter_assets` and
`denial-plugin-bundle.json`. It carries no engine and no ICU data: deniald runs
every composition on the session's own. deniald announces this as capability
`pluginBundleV2`; the manager applies nothing to a deniald without it and asks
for one logout and login.

### One record of what runs

deniald's `plugin-composition.json` is the only record. `ui status` reports
`plugin_bundle` (what runs), `plugin_previous` (what `undo` goes back to) and
`plugin_engine_differs`. The manager keeps no copy: its `status` derives
`active` from deniald's answer, and a composition deniald runs that this
manager did not build is reported as such.

Apply plans, builds and activates under one lock, from the saved selection as
it is. Nothing is hashed again between the steps, and an unchanged selection
whose build deniald already runs does not restart the shell.

### Development checkouts

`tools/denial-pc plugin-manager` builds the backend and the app and writes
`denial-plugins.installation.json` with
`development: {checkout, flutter, engineRoot, engineTarget, platform}`. Such a
manager has no build kit:

- It compiles with the checkout's Flutter tool and the engine output the
  checkout's shell is built with, in place.
- It reads the SDK packages and the built-in plugins from the checkout as they
  are on disk. Nothing is copied and no tool path is stored.
- It needs the shell built once (`tools/denial-pc bundle`), which produces the
  engine's compilers. `status` names the missing file otherwise.
- `tools/denial-pc` writes the checkout's name into the shell bundle when it
  builds the bundle or the plugin manager, when it starts the session, and
  when it stages an engine test.

The edit loop for a plugin, the SDK or the shell is one command:

```sh
tools/denial-plugins apply
```

`tools/denial-pc plugin-manager` is needed again only after changing the
plugin manager itself. The built-in plugin records follow the installation
that runs, so a machine with both a package and a checkout uses either.

A release build (`tools/denial-pc` with its managed Flutter SDK) keeps the
kit, and `tools/stage-denial-runtime` asks a checkout for one while staging a
package (`DENIAL_PC_PLUGIN_BUILD_KIT_REQUIRED=1`).

### Commands

| Command | Does |
| --- | --- |
| `denial-plugins status` | What runs now, why, and what to do next |
| `denial-plugins list` | Plugins you can use, and which are on |
| `denial-plugins add PLUGIN` | Turn a plugin on: a name from `list`, a folder, or a Git URL (`--path`, `--ref`) |
| `denial-plugins remove PLUGIN` | Turn a plugin off |
| `denial-plugins apply` | Build the selection and switch the desktop to it (`--update` also moves Git plugins to their newest revision) |
| `denial-plugins undo` | Go back to the plugins that ran before |
| `denial-plugins off` | Use the standard desktop; the selection is kept |

`add` and `remove` change only the selection. Commands print text for a
person; `--json` prints the full JSON. `status` is three kinds of lines: what
runs, the reasons, and the one command to run next.

```text
Your plugins are running: denial_desktop, denial_top_bar
Selected: denial_desktop, denial_taskbar
  Your selection changed since then: denial_desktop, denial_taskbar
Next: denial-plugins apply
```

Plugins and deniald keep using the verbs they had: `bootstrap`, `initialize`
(`prepare`), `catalog`, `refresh-catalog`, `inspect`, `enable`, `plan` (the
app's compatibility check), `update`, `revert` (`undo`), `restore` (`off`),
`rebuild`, `rebuild-now`, `resume`, `discover`, `submit`, `worker` and
`job-details`. `status --brief` is the app's poll.

## 23. What another program displays (2026-11-18)

A program that shows plugins, such as a Settings page, runs `denial-plugins`
and displays what it answers. It works nothing out itself: what runs, whether
Apply is needed, what failed and which buttons to offer are decided here, in
`lib/src/report.dart`. The command is `$DENIAL_PLUGINS_BINARY` in a Denial
session, else `denial-plugins` in `PATH`; without it there is no plugin
support to show.

Every sentence comes with a `code`. A program that knows the code uses its own
wording, in the user's language; for a code it does not know it shows `text`,
which is English. `contract` is 1. A new field or code keeps the number, so a
program ignores fields it does not know.

### `denial-plugins status --json`

The program reads the `summary` object and nothing else of the answer. It
takes about 40 ms; poll it every 5 s, and every 0.6 s while `work` is set.

| Field | Holds |
| --- | --- |
| `desktop` | What runs: `code` `standard`, `plugins` (with `plugins`: names), `other_plugins` (built elsewhere, with `bundle`) or `unreachable` (Denial does not answer), and `text` |
| `selected` | The saved selection: plugin names |
| `why` | Lines that explain `desktop`. Codes: `selection_changed`, `engine_differs`, `starting`, `rebuild_update` (with `version` for a release), `rebuild_engine`, `denial_said` (with `message`), `session_old`, `session_error` |
| `issues` | What stops the saved selection from being built: `code` `too_many_providers`, `missing_provider` or `invalid_declaration`, `text`, `plugins`, `feature` |
| `included` | What the last build took in besides the selected plugins, while that build is of the saved selection: `name`, `title`, and `through`, the names from a selected plugin down to the one that needs it |
| `setup` | Whether plugins can be built here: `ready`, `needed`, `preparing`, `missing_dart` (with `expected`), `incompatible_dart` (with `installed`, `required`) or `tools`. For the last three `text` says what to install |
| `work` | The request that runs now, or null: `job`, `operation`, `label`, `step` and `steps` (null while unknown), `started` (when this step began, for a clock). `label` is one of the labels of `lib/src/progress.dart` |
| `failure` | The last request, when it failed and nothing succeeded since, or null: `job`, `operation`, `code`, `text`, `detail` (the message it ended with). Codes: `did_not_start`, `conflict`, `two_panels`, `missing`, `declaration`, `download`, `log_in_again`, `other_denial`, `stopped`, `failed` |
| `next` | The one thing to do, or null: `apply`, `fix_selection`, `log_in_again`, `wait` or `open_in_session`. `text` is worded for the command line |
| `can` | What to offer now: `change` (switches), `apply`, `undo`, `off`, `switch_now` |

`can.apply` stays true while the selection already runs: in a development
checkout Apply is also how edits are tried. Show Apply as the main action when
`next.code` is `apply`. A failure stays until a request succeeds; a program
that lets the user dismiss it remembers `failure.job`.

### `denial-plugins list --json`

`plugins` is every plugin this installation knows, sorted by name: `name`,
`title`, `description`, `kind` (`builtin`, `local` or `git`), `from` (a
folder or a link, `built in` otherwise), `selected`, `installed` (false for a
community entry that was never added) and `default`. `errors` is non-empty
when the community list could not be loaded. `default_selection` is true
while the selection is exactly the plugins Denial comes with. `community`
holds `configured` (whether this Denial has a community list) and `updated`
(when it was last read, in UTC).

### `denial-plugins history --json`

`entries` is the requests the manager remembers, the newest first: `job`,
`operation`, `state` (`waiting`, `working`, `done`, `failed` or `stopped`)
and `when` (the time it ended or last said something, in UTC). One that
failed or was stopped also has `code`, `text` and `detail`, as `failure`
does. What a request ran inside itself, and looking into a folder or a link,
are left out.

### Requests

| The user | Run |
| --- | --- |
| flips a switch | `denial-plugins --json add NAME` or `remove NAME`. It returns at once and changes only the saved selection |
| adds a folder or a link | `denial-plugins --json inspect LOCATION` (`--local` for a folder, `--ref`) lists the plugin packages found there; then `submit add LOCATION --path PATH` |
| presses Apply | `denial-plugins submit apply` (`--update` also moves Git plugins to their newest revision) |
| presses Undo, or Standard desktop | `denial-plugins submit undo`, `submit off` |
| asks for Denial's defaults | `denial-plugins --json defaults`, while `default_selection` is false. It returns at once: the saved selection becomes the plugins Denial comes with, and only them. What was turned off stays in the list |
| refreshes the community list | `denial-plugins submit refresh-catalog`, while `community.configured`. `work` reports it, and `list` then has the new entries |
| opens the recent activity | `denial-plugins --json history` |
| presses Switch now | `denial-plugins rebuild-now`, while `can.switch_now` |
| opens the details of a failure | `denial-plugins job-details JOB`: the `log` of that request |
| opens the page | `denial-plugins bootstrap` once. It returns at once and prepares plugin support in the background when `setup` is `needed` |

`submit` starts the request in its own process and prints `{"job": ID}`; the
request goes on when the program closes, and `status` reports it as `work`. An
apply typed into a terminal shows up the same way. A request made while
another runs fails at once: offer one only while `can` allows it.
