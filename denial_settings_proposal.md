# Denial Settings architecture proposal

## Status

Recommended architecture for implementation.

## Objective

Denial Settings will be a normal, independently launched Flutter Wayland
application. It will be managed by Denial like any other user application:
it can be resized, moved, minimized, closed, displayed in Overview, and selected
through normal window switching.

The application will aggregate several settings domains without taking
ownership away from the services that actually implement them:

- `deniald` owns compositor and embedded-shell settings;
- NetworkManager owns Wi-Fi state and connections;
- BlueZ owns Bluetooth adapters, devices, and connections;
- existing persistent native controllers continue to own audio and brightness;
- standard system services continue to own power profiles and similar features.

The settings UI is therefore a client of authoritative services, not the
source of truth itself.

## Architectural principles

1. Denial Settings is a real Wayland client, not an embedded shell overlay.
2. Widgets do not write compositor configuration files or issue raw commands.
3. `deniald` exposes a typed, versioned, bounded settings API.
4. The public API uses stable Denial product setting identifiers rather than
   Hyprland parser keys.
5. Every setting has one authoritative owner.
6. The settings application and quick settings may share domain code, but they
   do not share presentation widgets.
7. Live state is observed through persistent connections and change signals.
   There is no polling through CLI utilities.
8. The user's main compositor configuration is never rewritten.
9. All values received from an application are validated by the owning service.
10. Accessibility, keyboard navigation, adaptive layout, and reduced motion are
    part of the architecture rather than later visual refinements.

## Runtime topology

~~~text
org.denial.Settings
Flutter Wayland application
  |
  | session D-Bus
  v
deniald
  SettingsService
    SettingsRegistry
      descriptors and validation
      effective-value calculation
      revision and transaction handling
    SettingsStore
      versioned Denial-owned persistence
      atomic writes and migrations
    RuntimeAdapters
      native compositor settings
      output and input settings
      embedded-shell settings
  |
  | existing binary platform bridge
  v
embedded Flutter shell
  MotionPolicy and other live shell preferences

org.denial.Settings
  |
  +-- system D-Bus --> NetworkManager
  +-- system D-Bus --> BlueZ
  +-- system D-Bus --> power-profiles-daemon and similar services
~~~

The external application must not use the embedded Flutter platform channels.
Those channels belong to the Flutter engine hosted inside `deniald`. The
application uses a session D-Bus API for Denial-specific state and the standard
system D-Bus APIs for services that already have an authoritative interface.

## Application identity and lifecycle

The application should use:

- application ID: `org.denial.Settings`;
- desktop entry: `org.denial.Settings.desktop`;
- display name: `Denial Settings`;
- a dedicated Flutter eLinux Wayland runner and application bundle.

The application ID must not use the `denia-systemui` prefix. That prefix is
reserved for special shell surfaces; Denial Settings must be classified as a
normal user application.

The desktop entry makes the application discoverable by the existing launcher.
Normal compositor policy handles launch animation, focus, window placement,
minimize, close, and task switching. The application must not reproduce these
behaviors internally.

A later packaging step may add single-instance activation. Reopening the
desktop entry should then focus the existing window and optionally navigate it
to a requested route.

## Repository layout

The intended source boundaries are:

~~~text
apps/
  denial_settings/
    pubspec.yaml
    lib/
      main.dart
      app/
        settings_app.dart
        settings_router.dart
        settings_scaffold.dart
      features/
        home/
        motion/
        wifi/
        bluetooth/
        displays/
        input/
        power/
        about/
    test/

packages/
  denial_design/
    shared theme tokens, icons, and motion primitives

  denial_settings_api/
    compositor settings models
    repository interfaces
    session D-Bus client
    protocol errors and capability models

  denial_system_services/
    NetworkManager models and client
    BlueZ models and client
    power-profile and related standard-service clients

dart_shell/
  embedded shell
  quick-settings presentation
  sole shell-owned Bluetooth pairing-agent host

Hyprland/deniald/
  SettingsService
  SettingsRegistry
  SettingsStore
  typed runtime adapters
~~~

Path dependencies are sufficient initially. A repository-wide Dart workspace
can be introduced separately if it improves tooling without disturbing the
embedded bundle build.

## Flutter application architecture

### Root application

Denial Settings uses `MaterialApp.router` with a Denial-specific Material 3
theme. It owns a normal navigation stack, route history, focus hierarchy, and
overlay.

The embedded shell remains independent and does not gain a Navigator merely to
host the settings experience.

### Navigation

Initial routes:

~~~text
/
/motion
/wifi
/wifi/network/:networkId
/bluetooth
/bluetooth/device/:deviceId
/displays
/displays/:outputId
/input
/power
/about
~~~

Routes carry stable identifiers only. A destination loads its current model
from its repository; complete mutable objects are not passed through route
arguments.

### Adaptive application frame

The application layout adapts to its current window size:

- compact: category list and detail pages use normal forward/back navigation;
- medium: navigation rail or compact sidebar plus one content pane;
- expanded: persistent sidebar plus content, with an optional detail pane.

Resizing must not discard the selected route, in-progress safe edits, or scroll
position. All pages remain scrollable at small supported sizes.

Keyboard and pointer behavior are first-class:

- deterministic Tab focus order;
- arrow-key movement where lists or segmented controls support it;
- Enter and Space activation;
- Escape closes a transient prompt before navigating back;
- visible focus indicators;
- tooltips and semantic labels for icon-only controls.

### Feature modules

Each feature owns:

- route-facing page widgets;
- small reusable presentation components for that feature;
- a Riverpod controller or `AsyncNotifier`;
- repository dependencies;
- mapping from domain failures to user-facing state.

There is no single mutable `SettingsState` containing the entire application.
Feature controllers observe only the authoritative streams they need.

Widgets render immutable state and send intent to controllers. They do not call
D-Bus clients directly and do not edit files.

### UI behavior

The settings application is not generated as a generic property grid.
Descriptors supplied by the compositor API provide validation, capabilities,
constraints, and defaults, while each page is deliberately designed for its
domain.

Dialogs and sheets are limited to genuinely transient actions:

- Wi-Fi credentials;
- Bluetooth confirmation when appropriate;
- destructive reset or forget actions;
- display-preview confirmation;
- privileged operations requiring system authorization.

Normal navigation and configuration happen inside persistent application
pages.

## Compositor settings service

### D-Bus identity

The proposed session-bus service is:

~~~text
Bus name:   org.denial.Compositor
Object:     /org/denial/Compositor/Settings
Interface:  org.denial.Compositor.Settings1
~~~

The interface is versioned. Incompatible revisions receive a new interface
version rather than silently changing existing method semantics.

### Responsibilities

The service:

- publishes the supported settings and capabilities;
- publishes the current effective snapshot;
- validates requested values;
- applies supported changes on the correct compositor thread;
- coordinates settings that affect both native and Flutter state;
- persists committed Denial overrides;
- observes compositor configuration reloads;
- emits authoritative changed signals;
- owns preview and rollback transactions;
- returns structured failures.

The service does not accept:

- arbitrary compositor configuration keys;
- raw Hyprland commands;
- shell command lines or executable arguments;
- unbounded strings or collections;
- network or Bluetooth credentials.

### Stable setting identifiers

Public identifiers describe Denial behavior rather than implementation details.
Examples include:

~~~text
motion.enabled
motion.preset
motion.durationScale
motion.windowOpenStyle
motion.windowCloseStyle

shell.systemBarSide
shell.systemBarOutput

input.naturalScroll
input.tapToClick
input.pointerSpeed

display.vrr
display.scale
display.transform
~~~

An internal runtime adapter may map a setting to a Hyprland value, a Denial
native controller, an embedded Flutter preference, or several of them. That
mapping is private and may change without breaking the application API.

### Descriptor model

Each supported setting has an immutable descriptor:

~~~text
SettingDescriptor
  id
  value type
  default value
  optional minimum and maximum
  optional discrete choices
  capability requirements
  apply mode
  preview requirement
  persistence support
~~~

Supported value types are intentionally small and bounded:

- Boolean;
- signed integer;
- finite double;
- bounded string or enum identifier;
- small typed tuple where a scalar cannot represent the domain.

Descriptors are used for validation and capability-aware UI. They are not a
replacement for feature-specific page design.

### Snapshot model

The authoritative snapshot contains:

~~~text
SettingsSnapshot
  protocolVersion
  revision
  entries

SettingEntry
  id
  effectiveValue
  configuredValue, if present
  defaultValue
  origin
  availability
  restartRequirement
~~~

The origin is one of:

- Denial default;
- user compositor configuration;
- Denial Settings override;
- temporary preview.

This allows the UI to explain why a value is active and makes Reset behavior
unambiguous.

### Operations

The first interface should support operations equivalent to:

~~~text
GetCapabilities()
GetSnapshot()
Apply(expectedRevision, changes, persist)
Reset(expectedRevision, settingIds)
BeginPreview(expectedRevision, changes, timeout)
CommitPreview(previewId)
CancelPreview(previewId)
~~~

The exact D-Bus signatures may use bounded arrays of typed ID/value pairs.
No method uses JSON.

The service emits:

~~~text
SettingsChanged(revision, changedEntries)
CapabilitiesChanged(revision)
PreviewStateChanged(previewId, state, remainingTime)
~~~

Every successful mutation returns the resulting authoritative revision and
changed entries.

### Revision and concurrency rules

The registry maintains a monotonic 64-bit revision.

Clients include the revision on which an edit was based. If another client or a
configuration reload changed relevant state, the service rejects the stale
mutation and returns the latest snapshot. The application then reconciles its
controls rather than overwriting newer state.

All items in a batch are validated before any are applied. A committed batch is
observable as one revision so that native behavior and embedded-shell behavior
cannot appear as unrelated changes.

### Threading

D-Bus message decoding and value validation must not mutate compositor state
from an arbitrary callback thread.

Validated transactions are scheduled on the compositor event loop. Runtime
adapters may enqueue bounded work on an existing persistent controller where
the underlying operation requires a worker. Completion is returned
asynchronously.

## Persistence model

### Owned settings file

Committed GUI overrides are stored in a Denial-owned, versioned file:

~~~text
$XDG_CONFIG_HOME/denial/settings.toml
~~~

The settings application never writes this file directly. `deniald` owns
parsing, migration, validation, and writing.

The file stores only stable Denial setting identifiers and values. It does not
contain Wi-Fi passwords, Bluetooth secrets, session tokens, or arbitrary
commands.

### Precedence

Effective values use this order:

~~~text
Denial defaults
  < user compositor configuration
  < committed Denial Settings overrides
  < temporary preview values
~~~

Reset removes the committed override. The effective value then falls back to
the user's compositor configuration or the Denial default.

On a normal compositor configuration reload, the registry:

1. reads the new base values;
2. reapplies valid Denial Settings overrides;
3. recalculates every affected effective value;
4. increments the revision once;
5. publishes the authoritative changes to all clients and the embedded shell.

### Atomic writes

Persistent commits use an atomic same-directory replacement:

1. serialize the complete next version;
2. write a temporary file with owner-only permissions;
3. flush and validate it;
4. replace the previous file atomically;
5. flush the containing directory where supported.

An interrupted write must leave either the previous valid file or the complete
new file. Startup ignores no errors silently: invalid data is reported,
quarantined or preserved for diagnosis, and safe defaults remain available.

Format migrations are explicit and tested. Unknown future setting identifiers
are preserved when safe or reported without being interpreted as commands.

## Motion architecture

### Current ownership

Denial's visible shell motion is implemented in embedded Flutter, while some
native compositor behavior may also depend on animation-related configuration.
A single user-facing animation control must therefore coordinate both sides.

### Shared motion model

The existing compile-time motion constants are split into:

~~~text
MotionTokens
  default durations
  curves
  spring descriptions

MotionPolicy
  enabled
  preset
  duration scale
  selected window styles
  effective reduced-motion state
~~~

`MotionTokens` lives in `packages/denial_design`. `MotionPolicy` is immutable
runtime state provided through Riverpod in the embedded shell and in the
settings application's preview components.

The settings application's preview uses the same tokens and policy calculation
as the shell, but it remains a separate presentation implementation.

### Initial motion settings

The first supported motion settings should be:

- global motion enabled;
- a small set of named motion presets;
- bounded duration scale;
- window-open style;
- window-close style.

The first release should not expose every raw duration and spring coefficient.
Stable presets keep the UI understandable and allow internal tuning without
turning implementation constants into permanent public API.

### Accessibility precedence

Platform accessibility reduction always wins over an ordinary motion preset.
Effective policy is calculated from:

~~~text
platform disable-animations request
user motion-enabled preference
selected preset
duration scale
~~~

When effective motion is disabled, scripted transitions complete immediately
or use an accessible reduced transition. Gesture-driven interactions continue
to track the user's gesture, but their settle phase avoids decorative motion.

### Live update behavior

A motion change is one settings transaction:

1. `SettingsRegistry` validates the product-level values;
2. native animation adapters receive the new revision;
3. a complete policy snapshot is sent to embedded Flutter;
4. the service publishes the same revision to Denial Settings;
5. persistence is committed if requested.

New transitions use the new policy. Disabling motion may safely finish active
non-gesture transitions at their logical end state; it must never leave a layer
half-open or a window non-interactive.

## Wi-Fi architecture

NetworkManager remains authoritative.

The current NetworkManager models and persistent D-Bus backend move into
`packages/denial_system_services`. The full settings application and embedded
quick settings may each own a bounded client connection and immutable cache.
They remain consistent because both observe NetworkManager's authoritative
signals.

The Wi-Fi feature includes:

- service and hardware availability;
- radio enabled state;
- connection status;
- access-point scan results;
- saved connection state;
- connect, disconnect, forget, and rescan operations;
- explicit loading, permission, unavailable, captive-portal, and error states.

Wi-Fi credentials are passed only to NetworkManager for the requested
connection operation. They are not placed in Riverpod's long-lived global
state, logs, the compositor settings API, or `settings.toml`.

The settings page may present a local credential prompt. Quick settings keeps
its condensed interaction model while calling the same domain client.

## Bluetooth architecture

BlueZ remains authoritative.

The existing Bluetooth backend is separated into two responsibilities:

~~~text
BluezClient
  adapter and device snapshots
  discovery
  pair, trust, connect, disconnect, and remove operations

BluezPairingAgentHost
  Agent1 registration
  one pending bounded pairing conversation
  timeout and cancellation
  global system prompt routing
~~~

`BluezClient` moves into `packages/denial_system_services` and is safe for the
settings application and quick settings to instantiate.

The embedded shell remains the single `BluezPairingAgentHost` and the default
BlueZ agent. Denial Settings must never register or request another default
agent. A pairing operation initiated from the application is shown as progress
inside the device page, while any required system confirmation is presented by
the shell's secure global pairing surface.

If the session is locked, the shell rejects or defers interactive pairing
requests according to lock policy. Pairing secrets and passkeys are never
persisted by Denial Settings.

## Other service domains

Additional pages follow the same ownership rule:

- audio and brightness use the existing persistent native controllers exposed
  through a typed `deniald` D-Bus interface;
- power profiles use the standard system D-Bus service;
- battery information remains observational;
- display topology and input configuration go through compositor runtime
  adapters;
- notifications and privacy controls use the service that already owns their
  lifecycle.

No frequent or latency-sensitive control launches a CLI utility.

## Display previews and rollback

Display settings can make the application invisible or unusable. Changes to
mode, scale, transform, layout, or output enablement require a preview
transaction.

Preview behavior:

1. validate the complete proposed output topology;
2. retain the previous known-good topology;
3. apply the preview with a bounded timeout;
4. show a compositor-owned confirmation surface on a visible output;
5. commit only after explicit confirmation;
6. roll back on timeout, client disconnect, invalid presentation, or explicit
   cancellation.

The confirmation surface is compositor-owned so it remains reachable even if
the settings window moves off-screen. Only a committed preview is persisted.

## Error and offline behavior

The application remains a usable application when one backend is unavailable.

- If `deniald` settings D-Bus is unavailable, compositor pages show an offline
  state and retry; NetworkManager and BlueZ pages may remain functional.
- If NetworkManager is unavailable, Wi-Fi shows a service-unavailable state
  rather than a false disabled toggle.
- If BlueZ disappears, device state is cleared authoritatively and pending
  operations fail with a bounded error.
- D-Bus clients reconnect with bounded exponential backoff and refresh their
  entire snapshot after reconnection.
- An embedded Flutter engine restart receives a complete settings snapshot;
  correctness never depends on replaying missed incremental signals.
- Runtime apply and persistence failures are returned explicitly. The UI does
  not display a successful state until it receives the authoritative revision.

Errors crossing process boundaries use stable codes plus bounded diagnostic
text. Widgets map stable codes to user-facing messages.

## Security boundary

The settings application is treated as an untrusted IPC client even though it
runs in the same user session.

The service:

- validates interface version, IDs, types, ranges, lengths, and enum values;
- rejects unknown or unsupported settings;
- limits batch size and preview lifetime;
- never interprets a value as a command line;
- authorizes only explicitly supported mutations;
- relies on system D-Bus and polkit for system-service authorization;
- avoids logging credentials or secret-bearing payloads;
- rejects sensitive interaction while the secure session lock owns input.

Session-bus ownership alone does not replace input validation.

## Testing strategy

### Pure unit tests

- descriptor validation and capability filtering;
- effective-value precedence;
- revision and stale-update handling;
- atomic batch validation;
- Reset behavior;
- persistence serialization and migration;
- preview commit, timeout, disconnect, and rollback;
- motion policy calculation and accessibility precedence.

### D-Bus contract tests

- valid and invalid method payloads;
- bounded collection enforcement;
- changed-signal ordering;
- reconnect and full-snapshot behavior;
- incompatible interface-version behavior;
- structured error mapping.

### Flutter tests

- route restoration and back navigation;
- compact, medium, and expanded layouts;
- keyboard traversal and activation;
- feature loading, offline, empty, error, and success states;
- stale edit reconciliation;
- motion preview under normal and reduced-motion policies;
- Wi-Fi credential disposal;
- Bluetooth pairing progress and cancellation.

### Integration tests

- settings change reaches `deniald` and the embedded shell under one revision;
- engine reload restores the full effective motion policy;
- manual compositor reload recomputes origins and overrides;
- NetworkManager and BlueZ changes appear in quick settings and the application;
- display preview rolls back without application cooperation;
- no supported control path launches a CLI process from embedded Dart.

## Implementation sequence

### 1. Application and protocol foundation

- add the separate Flutter Wayland application target;
- add the desktop entry and application identity;
- create the routed adaptive application frame;
- create `denial_settings_api` models and repository interfaces;
- add the versioned `deniald` D-Bus Settings1 service;
- implement snapshot, revision, change signal, and bounded validation.

### 2. Motion vertical slice

- introduce `MotionTokens` and runtime `MotionPolicy`;
- add settings-registry motion descriptors and adapters;
- publish motion policy to embedded Flutter through the existing binary bridge;
- build the Motion page and live preview;
- implement persistence, Reset, and accessibility precedence.

This slice validates the complete application-to-compositor-to-shell path
before broader settings are added.

### 3. Connectivity extraction

- move NetworkManager models and client to `denial_system_services`;
- move BlueZ models and read/control client;
- separate and retain one shell-owned pairing-agent host;
- migrate quick settings to the shared domain clients;
- build full Wi-Fi and Bluetooth pages.

### 4. Compositor domains

- add input settings;
- add system bar and shell behavior settings;
- add display descriptors and safe preview transactions;
- add power and other standard-service pages.

### 5. Packaging and resilience

- extend PC and target-device build/install workflows;
- install the desktop entry and icon;
- add D-Bus activation or single-instance activation if desired;
- finish reconnect, migration, recovery, and end-to-end tests.

## Acceptance criteria

The architecture is complete when:

- Denial Settings launches as a normal Wayland application window;
- it participates in normal focus, resize, Overview, minimize, close, and
  window-switching behavior;
- it has real route navigation and adaptive page layout;
- compositor settings are changed only through the typed `deniald` API;
- the main user compositor configuration is never rewritten;
- a motion change updates native behavior and embedded Flutter from one
  authoritative revision;
- reduced-motion accessibility always overrides decorative motion;
- Wi-Fi and Bluetooth use persistent D-Bus clients with no CLI polling;
- only one BlueZ pairing agent exists;
- quick settings and the full application share domain behavior but not their
  UI surfaces;
- display changes have compositor-owned confirmation and automatic rollback;
- service loss produces honest offline states and recovers through full
  snapshots;
- all IPC inputs are bounded and validated;
- credentials are never written to Denial's compositor settings store.

## Architectural invariants

1. Denial Settings is never rendered as an embedded shell dialog.
2. `deniald` remains authoritative for compositor and embedded-shell settings.
3. Standard system daemons remain authoritative for their own domains.
4. Public setting IDs are stable Denial concepts, not raw upstream parser keys.
5. The UI never writes configuration files or launches control utilities.
6. Persistence is separate, versioned, atomic, and removable through Reset.
7. Every mutation is reconciled against an authoritative revision.
8. The embedded shell can reconstruct complete settings state after reload.
9. Presentation can evolve independently from shared service and protocol code.
10. Security-sensitive confirmation remains available even if the settings
    application is closed, disconnected, or positioned off-screen.
