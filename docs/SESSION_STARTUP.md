# Session startup and locking

`denial-session` is the supported entry point for an installed Denial
session. It resolves the DRM device, initializes and validates the user's
output configuration, selects the packaged Flutter bundle, and then starts
`deniald`. Normal sessions should not invoke `deniald` directly.

## Display-manager sessions

The installed Wayland session entry starts Denial directly:

```sh
/usr/bin/denial-session
```

Once the compositor has selected its sockets, it publishes the complete
session environment to D-Bus activation. After the Flutter shell is alive and
every initial output has accepted a real atomic commit, Denial also publishes
the environment to an available systemd user manager and starts its packaged
`denial-session.target`. That target binds to the standard
`graphical-session.target`, allowing portals and other desktop services to
start against the discovered sockets. Denial stops the target on shutdown,
and the launcher provides a cleanup fallback after the compositor process
exits.

The D-Bus-activated `denial-portal.service` is part of that target. It connects
to deniald's private appearance-state socket before owning the Settings portal
bus name, then stops when the compositor disconnects. XDG desktop portal
routing selects it for `org.freedesktop.impl.portal.Settings` with GTK as the
fallback for keys Denial does not implement. No portal process is placed on
the compositor render or input path.

On a system without a systemd user manager, such as a runit system using
elogind, the launcher remains the session process parent and therefore owns
the compositor lifecycle directly. D-Bus-activated desktop services still
receive the same discovered Wayland, X11, desktop, and control endpoints.
The Denial portal D-Bus file also carries a direct `Exec` fallback, so its
lifetime remains bounded by the private compositor connection without
requiring a user service manager.

The same publication is the readiness contract UWSM discovers when a user
elects to run Denial inside UWSM; no launcher flag or separate finalization
command is needed.

## Qt application theming

Qt does not necessarily consult the desktop Settings portal merely because the
portal is available. Denial therefore selects Qt's standard portal-backed
platform theme provider by default:

```sh
QT_QPA_PLATFORMTHEME=xdgdesktopportal
```

The launcher exports that value before starting the compositor. Denial also
publishes it with the discovered Wayland/X11 endpoints to D-Bus and systemd
activation, and applies it to applications launched directly by the shell.
The provider reads `org.freedesktop.appearance/color-scheme`; Denial does not
write KDE's `kdeglobals`, force a Qt widget style, or duplicate dark/light
palette state in an environment variable.

An inherited value or an assignment in `/etc/denial/session.conf` takes
precedence. For example, `QT_QPA_PLATFORMTHEME=kde` selects an installed KDE
provider, while `QT_QPA_PLATFORMTHEME=` deliberately restores Qt's toolkit
default. A session restart is required because the provider is selected when
each Qt process starts. Colour-scheme changes inside Denial Settings remain
live for portal-aware providers and do not require restarting the session.

This path starts unlocked. That is intentional: a display manager such as GDM
or SDDM has already authenticated the user before it launches the selected
session. Adding another startup lock to that entry would normally ask for the
same password twice without establishing a stronger login boundary.

## Autologin and direct startup

If a session manager starts Denial without authenticating the user first, it
must request Denial's own startup lock:

```sh
/usr/bin/denial-session --start-locked
```

`--start-locked` initializes the native authentication state and security gate
as locked before Flutter starts. The shell's first visual state is therefore
the lock screen, and the user must authenticate through Denial's PAM-backed
unlock flow before using the session.

For example, a greetd autologin can use:

```toml
[initial_session]
command = "/usr/bin/denial-session --start-locked"
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

## Xwayland scaling compatibility

Xwayland uses Denial's exact fractional output density by default. This lets
DPI-aware X11 applications render directly at scales such as 125% instead of
rendering at 200% and being reduced by the compositor.

An application that cannot handle fractional X11 DPI can use the former
integer-upscale compatibility behavior for the whole session:

```sh
DENIAL_XWAYLAND_SCALE_MODE=integer
```

The accepted values are `fractional` (the default) and `integer`. A session
restart is required because the mode is selected when Xwayland starts.

## Supported launcher modes

| Invocation | Result |
| --- | --- |
| `denial-session` | Start the packaged desktop after an authenticated display-manager login |
| `denial-session --check` | Validate the installation, discovered session lifecycle, bundle, output configuration, DRM selection, Qt platform theme, and Xwayland without starting a compositor |
| `denial-session --start-locked` | Start with Denial's native security gate and Flutter lock screen already locked |

`denial-session` forwards other arguments to `deniald`. Those lower-level
switches exist for controlled development and compositor diagnostics and are
not the stable end-user configuration interface. Run `deniald --help` to
inspect the options provided by the installed build; persistent user settings
belong in Denial Settings, while administrator overrides belong in
`/etc/denial/session.conf`.
