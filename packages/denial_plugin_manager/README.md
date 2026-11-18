# Plugin Manager backend

Build-time tooling only. Do not import this package into a shell bundle.

Build the development app/backend with `tools/denial-pc plugin-manager`. The app
resolves its backend from packaging-owned metadata beside its executable. The
backend similarly locates native control and its build tools: the compiler kit
of a package, or the Denial checkout it was built from, which it compiles in
place. There is no user setup, no tool-path preferences, and no required flags.
`bootstrap` submits one detached initialization job when needed; mutation
commands also ensure initialization. Defaults are seeded once, never restored
over deliberate removals. The app can close during initialization or
compilation.

`tools/denial-plugins` invokes that built backend. Seven commands are for
people; they print text, and JSON with `--json`. Progress and failures go to
stderr. Another program, such as a Settings page, displays the `summary` of
`status --json` and `list --json` and decides nothing itself: the contract is
section 23 of `docs/PLUGIN_MANAGER.md`. `--state DIRECTORY` is an internal test-isolation option (default:
`$XDG_STATE_HOME/denial/plugins`). Source selectors such as package path and
Git ref describe the plugin being added; they do not configure Denial tools.

```sh
tools/denial-plugins status         # what runs, why, and what to run next
tools/denial-plugins list           # plugins you can use, and which are on
tools/denial-plugins add /path/to/package
tools/denial-plugins --path panels/taskbar add https://example.org/plugins.git
tools/denial-plugins remove denial_top_bar
tools/denial-plugins apply          # build the selection and switch to it
tools/denial-plugins undo           # the plugins that ran before
tools/denial-plugins off            # the standard desktop; selection kept
```

`docs/PLUGIN_MANAGER.md` section 22 has the rules that decide which plugins
load, the development checkout and the verbs the app and deniald use.

Ordinary planning retains prior Git commits and the last resolved Pub lock.
`update` explicitly advances them. Plans snapshot local packages into new
workspaces; selection does not edit the source checkout.

The application runtime graph excludes dev dependencies. Library annotations and
contract identities resolve against the application's single Pub configuration.
Discovery does not execute Flutter or plugin code. Constructor injection accepts
public, concrete, non-generic classes with unnamed constructors, typed contract
parameters, nullable optional contracts, and ordered `List<Contract>` parameters.
Unrelated optional named defaults are left to Dart. Constructor cycles, missing
providers, and exclusive ambiguities fail before compilation. Generated code uses
ordinary constructor calls and typed immutable collections. It contains no runtime
registry. Instances belong to the composition; widgets and explicit owners remain
responsible for their normal lifecycle/disposal.

The installation supplies both SDK packages by default. Optional `DENIAL_SDK_PATH`
points to a directory containing `denial_sdk/` and `denial_flutter_sdk/` (for this
checkout, `/mnt/development/denial-os/denial/packages`). It changes only the snapshotted SDK inputs,
not the locked compiler or engine. It is the only plugin infrastructure environment
override. All packages resolve against that one SDK pair, including local plugins
whose pubspecs point to another checkout. SDK version constraints remain checked;
substitution never authorizes incompatible API versions. Git-distributed plugins
should declare SDK version constraints. For manual authoring, an ignored
`pubspec_overrides.yaml` points at the prepared SDK pair; see the exact SDK and
editor setup in [plugin development](../../docs/PLUGIN_DEVELOPMENT.md). SDK hosting
on pub.dev is optional; installation supplies those inputs automatically. Local
source installation also supports SDK path dependencies for development.

The builder uses existing engine compilers and never rebuilds Rust or Flutter.
It creates a fresh, read-only bundle of the compiled shell and its assets with
their checksums; a bundle carries no engine. Builds and repository operations
can run in detached workers that survive the submitting process; status and
progress are durable JSON/log files.

`plugin_manager_app` is the separate GUI. Build it and the compiled CLI with
`tools/denial-pc plugin-manager`. A release build also prepares the compiler
kit packages install; a development checkout prepares one only while staging a
package. Native package staging installs `denial-plugin-manager`,
`denial-plugins`, the desktop entry, and `/usr/lib/denial/plugin-build-kit`.

The app works through background jobs, so its window can close meanwhile:

```sh
denial-plugins bootstrap            # automatic; the app calls this itself
denial-plugins submit plan          # preview/validate only
denial-plugins submit apply         # retain pins, build and request activation
denial-plugins submit update        # deliberately advance Git/Pub, build and activate
denial-plugins submit revert        # same as undo
denial-plugins submit restore       # same as off
```

Wait for each background job to complete before submitting a dependent operation.
The GUI disables mutations while a job is active. A package's initial
preparation verifies the entire kit manifest before copying and publishing
configuration; it does not write into the installed kit. After an upgrade,
Denial prepares the matching kit automatically and custom bundles are rebuilt.

`ui activate BUNDLE` is the native transition. It verifies the sealed bundle's
checksums, architecture, Flutter generation and source identity before
replacement; the engine is proven by starting the shell. Promotion requires a
produced frame and three seconds of startup; no frame within 20 seconds
requests the standard desktop. Pending startup is never retried after a
process exit, and rapid repeated custom startups fall back to the standard
desktop. These checks detect startup failure; they are not a proof of plugin
correctness. Repeated requests cannot replace a pending native activation. GUI
close does not cancel builds; source/build failures do not request activation.

The default catalog is `plugins.yaml` in
[`denialwm/denial-plugins`](https://github.com/denialwm/denial-plugins).
Each plugin is an independently selectable package under `plugins/`; the
collection root is not a Dart package. First use fetches the catalog, then uses
cached results until Refresh. Offline errors leave built-ins available and can
be retried with Refresh. Existing custom catalog settings remain authoritative.
The catalog YAML schema is in `docs/PLUGIN_MANAGER.md`.
Catalog metadata never overrides Pub dependency information. SDK API versioning and
unrestricted build scripts remain separate work. No package, SDK, or catalog is
published by these commands.

Validation:

```sh
cd packages/denial_plugin_manager
/path/to/pinned/dart test
/path/to/pinned/dart analyze --fatal-infos
```

Tests exercise real temporary Git repositories, package closure filtering,
resolved annotation identity, generated Dart execution, source snapshots,
native-confirmed activation, rollback intent, in-place development tools,
isolated kit provisioning and the status report. They do not launch a graphical application.

Plugin authors can add advisory `denial_plugin` schema 1 `provides`/`requires`
claims to `pubspec.yaml` for fast switch-time compatibility checks. See
`docs/PLUGIN_MANAGER.md` section 16 (relative to the repository root) for the
schema and partial dependency-closure rules. Pub and actual Dart type discovery
remain authoritative; metadata is never executed. Status returns
`preflight.selectionRevision`, `canApply`, `complete`, and readable `issues`.
`job-details ID` returns a saved diagnostic and a separate build log on demand.


The GUI keeps switches in a window-local draft. Status/catalog include normalized
`declarations` for the shared SDK's in-memory evaluator. Apply sends one
`apply --draft JSON` job containing `{revision, roots}`. The revision is an
optimistic concurrency guard; sources are resolved and declarations rechecked
under the manager lock before atomically saving the complete selection. No
switch-time command, write, or background job is required. See section 17 of
`docs/PLUGIN_MANAGER.md` for draft acknowledgement and failure semantics.
