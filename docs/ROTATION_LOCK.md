# Automatic orientation lock

The native compositor owns rotation lock. Enabling it **locks the current
orientation**, not natural orientation. It freezes the applied cardinal device
rotation, independent of the latest sensor reading waiting for renderer readiness.
An in-progress rotation animation may finish at that already-applied orientation.

`settings.json` stores `rotationLock.enabled` and a native-captured
`rotationLock.orientation` (0, 90, 180, or 270 degrees). Existing documents without
the section default to unlocked; no schema migration is needed. Shell document
writes request only `enabled`: the native owner captures the current applied
rotation on the false-to-true transition and ignores shell-provided orientation.
Unrelated legacy shell writes that omit the section preserve it. Live external
settings edits also capture the current orientation when enabling; startup restores
the saved orientation before constructing outputs. Invalid external edits retain
the last valid live settings; an invalid startup file remains untouched and uses
safe defaults, following the existing settings transaction policy.

Sensor observations continue while locked. Unlocking uses the latest **valid**
reading, even when there is no subsequent sensor event. Unknown readings, missing
hardware and service disconnects do not rotate to natural orientation or erase a
queued valid reading. With no valid reading since startup, unlocking keeps the
startup orientation until a valid reading arrives. Renderer and scanout readiness
still gate actual geometry changes through the existing native transaction path.

The frozen offset applies to the existing internal-panel sensor targets (DSI,
eDP, LVDS), including panels reconnected while locked. External displays are not
sensor-rotated. Explicit per-output rotation remains an intentional user override:
it changes the persistent panel baseline without changing the frozen sensor offset.
Unlocking composes the latest sensor rotation with that baseline. Display-layout
confirmation rollback carries the current sensor offset, so it cannot revert lock
policy or newly observed unlocked rotation.

The public Flutter SDK exports `rotationLockProvider` and its controller/state
from `package:denial_flutter_sdk/settings.dart`. The provider uses the existing
revision-checked native settings-document bridge, merges only this policy,
observes native document updates, retries one concurrent revision conflict, and
never optimistically reports a lock. Pending requests disable repeated taps;
failed requests retain the last authoritative state and expose an error.

`rotationLockSupported` is native-owned, non-persisted snapshot metadata advertising
**policy support**, not accelerometer presence. It is true for the native Flutter
runtime implementing this policy. Old native versions omit it, and unsupported
runtimes report false. The reference desktop plugin only shows the rotation tile
when this capability is present. There is no decorative local toggle and no
parallel native channel owned by the plugin. On machines without a sensor, the
policy is harmless and keeps the current device offset.

## Validation boundaries

Native unit tests cover capture, restart persistence, untrusted orientation,
legacy writes, malformed settings/revision conflicts, live editor transitions,
latest valid readings, coalesced sensor loss, and manual/internal/external/reconnect
composition. These are non-engine tests. SDK asynchronous tests require the
authorized Flutter development-engine path; do not run them or prepare that engine
without explicit permission. Hardware rotation, animation, connector hotplug,
confirmation timing and rendered tile/shade validation remain user-owned checks.
