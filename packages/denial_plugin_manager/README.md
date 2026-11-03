# Plugin Manager backend

Build-time tooling only. Do not import this package into a shell bundle.

Build the development app/backend with `tools/denial-pc plugin-manager`. The app
resolves its backend from packaging-owned metadata beside its executable. The
backend similarly locates the matching compiler kit and native control tool.
There is no user setup, no tool-path preferences, and no required flags. `bootstrap`
submits one detached initialization job when needed; mutation commands also ensure
initialization. Defaults are seeded once, never restored over deliberate removals.
The app can close during initialization or compilation.

`tools/denial-plugins` invokes that built backend. Commands emit JSON; progress
and failures go to stderr. `--state DIRECTORY` is an internal test-isolation option
(default: `$XDG_STATE_HOME/denial/plugins`). Source selectors such as package path
and Git ref describe the plugin being added; they do not configure Denial tools.

```sh
tools/denial-plugins bootstrap
tools/denial-plugins inspect https://example.org/plugins.git
tools/denial-plugins --path panels/taskbar add https://example.org/plugins.git
tools/denial-plugins --local add /path/to/package
tools/denial-plugins remove denial_top_bar
tools/denial-plugins submit plan
tools/denial-plugins status
tools/denial-plugins submit apply
```

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

The release builder uses existing locked engine artifacts and never rebuilds
Rust or Flutter. It creates a fresh, read-only bundle with checksums and retained
provenance. Builds and repository operations can run in detached workers that
survive the submitting process; status and progress are durable JSON/log files.

`plugin_manager_app` is the separate GUI. Build it and the compiled CLI with
`tools/denial-pc plugin-manager`. The same command prepares a release-only compiler
kit from the locked artifacts; it does not build a development engine. Native
package staging installs `denial-plugin-manager`, `denial-plugins`, the desktop
entry, and `/usr/lib/denial/plugin-build-kit`. These packaging changes still need
the distribution-level validation recorded in `docs/PLUGIN_MANAGER.md`.

Installed use:

```sh
denial-plugins bootstrap            # automatic; the app calls this itself
denial-plugins submit plan          # preview/validate only
denial-plugins submit apply         # retain pins, build and request activation
denial-plugins submit update        # deliberately advance Git/Pub, build and activate
denial-plugins submit revert        # previous bundle and its complete selection/pins
denial-plugins submit restore       # packaged recovery shell
```

Wait for each background job to complete before submitting a dependent operation.
The GUI disables mutations while a job is active. Initial preparation verifies the entire
packaged input manifest before copying and publishing configuration; it does not
write into the installed kit. The compiler cache is keyed by manifest hash. After an
upgrade, Denial prepares the matching kit automatically; custom bundles are rebuilt.
A native packaged source marker prevents loading a composition for another source
snapshot even when engine hashes match. Explicit development checkouts without
that marker still require the exact engine hash and Flutter compatibility generation.

`ui activate BUNDLE` is the native release transition. It verifies sealed bundle
hashes, architecture, engine, and installed source identity before replacement.
Promotion requires a produced frame and three seconds of startup; no frame within
20 seconds requests packaged recovery. Pending startup is never retried after a
process exit, and rapid repeated custom startups fall back to the packaged shell.
These checks detect startup failure; they are not a proof of plugin correctness.
Repeated requests cannot replace a pending native activation. GUI close does not
cancel builds; source/build failures do not request activation.

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
resolved annotation identity, generated Dart execution, source snapshots, and
stale-plan rejection, native-confirmed activation bookkeeping, rollback intent,
and isolated compiler provisioning. They do not launch a graphical application.

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
