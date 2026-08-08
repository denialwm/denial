# Session startup and locking

`denial-session` is the supported entry point for an installed Denial
session. It resolves the DRM device, initializes and validates the user's
output configuration, selects the packaged Flutter bundle, and then starts
`deniald`. Normal sessions should not invoke `deniald` directly.

## Display-manager sessions

The installed Wayland session entry starts Denial through UWSM:

```sh
uwsm start -e -D Denial /usr/bin/denial-session
```

This path starts unlocked. That is intentional: a display manager such as
SDDM has already authenticated the user before it launches the selected
session. Adding another startup lock to that entry would normally ask for the
same password twice without establishing a stronger login boundary.

## Autologin and direct startup

If a session manager starts Denial without authenticating the user first, it
must request Denial's own startup lock:

```sh
uwsm start -e -D Denial -- /usr/bin/denial-session --start-locked
```

`--start-locked` initializes the native authentication state and security gate
as locked before Flutter starts. The shell's first visual state is therefore
the lock screen, and the user must authenticate through Denial's PAM-backed
unlock flow before using the session.

For example, a greetd autologin can use:

```toml
[initial_session]
command = "uwsm start -e -D Denial -- /usr/bin/denial-session --start-locked"
user = "alice"
```

The regular, authenticated greeter path should continue to launch
`denial-session` without `--start-locked`.

## Renderer selection

Impeller GLES is the default renderer. A machine that needs the retained
Skia/Ganesh compatibility path can select it persistently in
`/etc/denial/session.conf`:

```sh
DENIA_FLUTTER_RENDERER=skia
```

For a controlled one-shot session, pass `--flutter-renderer skia` through the
launcher instead. Renderer changes take effect when the Flutter engine starts,
so restart the Denial session after changing the machine override.

Machines whose display controller and GPU are exposed as different DRM nodes
can select the render node independently in `/etc/denial/session.conf`:

```sh
DENIAL_DRM_DEVICE=/dev/dri/card0
DENIAL_RENDER_DEVICE=/dev/dri/renderD128
```

Denial keeps KMS and scanout on `DENIAL_DRM_DEVICE`; GBM allocation, EGL, and
Flutter rendering use `DENIAL_RENDER_DEVICE`. When the render override is
unset, both paths continue to use the KMS device.

Some display engines cannot scan out physically fragmented render-node
allocations. They can allocate the shared atlas through the KMS device's dumb
allocator, export it to the render node, and describe its driver-supported
layout explicitly:

```sh
DENIAL_DUMB_SCANOUT_MODIFIER=0x0800000000000062
DENIAL_DUMB_SCANOUT_EXTRA_ROWS=128
```

The modifier must be common to the KMS primary planes and EGL render formats.
Extra rows reserve backing storage only; Denial continues to expose the
configured output's visible dimensions to KMS and Flutter.

## Supported launcher modes

| Invocation | Result |
| --- | --- |
| `denial-session` | Start the packaged desktop after an authenticated display-manager login |
| `denial-session --check` | Validate the installation, bundle, output configuration, DRM selection, Xwayland, and UWSM without starting a compositor |
| `denial-session --start-locked` | Start with Denial's native security gate and Flutter lock screen already locked |

`denial-session` forwards other arguments to `deniald`. Those lower-level
switches exist for controlled development and compositor diagnostics and are
not the stable end-user configuration interface. Run `deniald --help` to
inspect the options provided by the installed build; persistent user settings
belong in Denial Settings, while administrator overrides belong in
`/etc/denial/session.conf`.
