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
start against the discovered sockets. It pulls in and waits for
`graphical-session-pre.target` before the graphical session starts, then
starts systemd's
`xdg-desktop-autostart.target`, so the user manager launches the effective
desktop entries from `$XDG_CONFIG_HOME/autostart` and the `autostart` child of
every directory in `$XDG_CONFIG_DIRS` only after Denial is ready. Entries can
target Denial with `OnlyShowIn=Denial;`. Denial stops the graphical-session
target on shutdown, and the launcher provides a cleanup fallback after the
compositor process exits.

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

Denial does not implement a second XDG autostart runner. On systems without a
systemd user manager, desktop entries in the XDG autostart directories are not
started by Denial; use that system's session-service mechanism or an explicit
launcher instead. This does not affect D-Bus activation or applications
launched from the Denial shell.

The same publication is the readiness contract UWSM discovers when a user
elects to run Denial inside UWSM; no launcher flag or separate finalization
command is needed.

## Application environment

Denial can override the environment of processes launched by its application
launcher and native shortcuts. Configure the default rules and optional
per-application rules on the **App environment** page in Settings. A value
sets the variable, including to an empty string; **Hide variable** removes an
inherited variable from the child process.

Flutter does not open or write a configuration file. It submits the desired
rules through the settings bridge, and deniald validates and atomically commits
the `applicationEnvironment` object inside its Rust-owned
`$XDG_CONFIG_HOME/denial/settings.json` document. Its stored shape is:

```json
{
  "default": {
    "QT_QPA_PLATFORM": "wayland;xcb",
    "DISPLAY": null
  },
  "applications": {
    "org.mozilla.firefox.desktop": {
      "MOZ_ENABLE_WAYLAND": "1",
      "QT_QPA_PLATFORM": "wayland"
    }
  }
}
```

The document may also be edited directly while Denial is running. Denial
watches the containing directory, validates the complete saved document, and
applies valid changes live. `version` and `revision` are Denial-owned metadata;
an editor does not need to increment `revision`. Invalid edits are left intact
for correction and do not replace the running last known-good settings.
Deleting the file restores and recreates the defaults.

The `default` map applies to every process launched by Denial. Each entry in
`applications` is a delta keyed by the standard freedesktop desktop-file ID;
it applies after the default map when that desktop entry is launched from the
shell. Deleting a per-application rule restores inheritance from `default`.
Shortcuts configured with the **Application** target carry the same desktop-file
identity and therefore receive that application's map. Raw **Program** and
**Shell command** shortcuts are generic commands and receive only the default
map. Denial does not edit desktop files or guess application identity from
executable names.

Settings lists the effective launchable desktop entries from the XDG data
directories and retains configured IDs whose desktop files have disappeared,
so stale rules can still be removed. Values are literal: Denial does not
perform shell expansion. The authoritative settings document is read for
every new launch, so changes affect subsequent launches without restarting the
compositor. Invalid environment data is rejected before Rust writes it. An
invalid settings file encountered at launch is reported in the Denial log and
ignored rather than making the application launcher unusable.

These overrides intentionally do not change deniald's own environment and are
not published to systemd or D-Bus activation. Consequently, they do not affect
applications launched through `xdg-desktop-autostart.target`. Put variables in
the login environment instead when every process in the graphical session must
inherit them.

## Clipboard display boundary

Denial authorizes clipboard reads according to the display backend that owns
keyboard focus. When a native Wayland surface is focused, every X11 request for
the Wayland-owned clipboard is rejected, including requests from a hidden Xlib
client in the same process tree. Native Wayland applications must read through
the Wayland data-device protocol instead of using Xwayland as a side channel.

Hybrid applications must therefore select their native Wayland window and
clipboard backend. For example, launch Linux QQ with
`--ozone-platform=wayland`; merely running inside a Wayland session does not
prevent QQ from selecting Xwayland for its windows. Any hidden Xlib clipboard
reader still receives an ordinary failed X11 selection response and is not
treated as part of the focused Wayland client.

Session clipboard tools may publish and observe the clipboard through both
`ext-data-control-v1` and `zwlr-data-control-v1`. This lets tools such as
`wl-copy` own data without mapping a temporary surface and taking keyboard
focus merely to obtain a data-device serial.

When an Xwayland window owns keyboard focus, Denial instead permits clipboard
reads from that shared Xwayland server. X11 clients within the server form one
legacy trust domain because upstream Smithay does not identify the requesting
client in its selection policy callback. X11 clients that own a selection
remain able to export it to Wayland; the focus policy controls reads from a
clipboard that Denial has published into Xwayland.

Before launching an application, Denial checks Xwayland's `XIM_SERVERS`
registrations when neither the inherited environment nor the applicable
application-environment rules select `XMODIFIERS`. If exactly one registered
XIM server still owns its advertised selection, Denial derives the standard
`@im=...` modifier for that launch. Stale, missing, or ambiguous registrations
are ignored. This makes an already-running Fcitx, IBus, or other conforming XIM
server available to Denial-launched Xwayland applications without requiring a
manual environment override.

GTK input-method selection is scoped to the display backend instead of being
forced into every child process through `GTK_IM_MODULE`. Native Wayland GTK
applications leave that variable unset and automatically select GTK's Wayland
text-input path. Denial publishes `Gtk/IMModule=xim` through the XSettings
manager owned by Xwayland, so GTK applications using X11 select the standard
XIM bridge without a per-application override. An inherited or configured
`GTK_IM_MODULE` still takes precedence over XSettings. Discovery of the active
XIM server and launch-time `XMODIFIERS` selection remain conditional as
described above.

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
the lock screen, and the user must authenticate through Denial's password or
fingerprint unlock flow before using the session.

For example, a greetd autologin can use:

```toml
[initial_session]
command = "/usr/bin/denial-session --start-locked"
user = "alice"
```

The regular, authenticated greeter path should continue to launch
`denial-session` without `--start-locked`.

For simultaneous lock and display-off deadlines, the native input gate closes
immediately and the output scheduler stops new submissions before powering off.
On locked wake, Flutter resumes rendering while KMS remains physically off.
The `denial/lock_frame` handshake asks the secure stage to settle its lock
entrance, then acknowledge the current wake token after layout. Only subsequent
render authorizations carry that token. Earlier frames are discarded with their
GPU fence ownership preserved; a matching frame must finish rendering before it
can perform the KMS wake modeset. Re-lock and a new wake invalidate old tokens.
This avoids showing the desktop on wake or flashing the lock UI before power-off.
Native and Flutter bundles must both support this handshake; a missing or stale
acknowledgement keeps a locked display off rather than presenting old content.

Denial also holds a logind-compatible `sleep` delay inhibitor and observes
`PrepareForSleep` for system suspend and hibernation. Before releasing that
inhibitor, the native authentication gate closes and every output which was on
is cleared through DRM DPMS. After resume, only those outputs are restored, and
the same lock-frame handshake keeps KMS off until Flutter has produced a fresh
lock frame. This covers sleep requested by Denial, logind idle policy, lid
switches, and external logind clients without flashing the lock screen before
the display goes black.

## Fingerprint unlock

When fprintd is installed and the session user already has a fingerprint
registered, Denial automatically verifies fingerprints while locked, including
with `--start-locked`. A completed match unlocks the existing Flutter lock
screen after PAM account validation succeeds. Successful unlock also wakes
outputs blanked by Denial and resets the idle deadlines, including when no
keyboard or pointer input occurred. Password authentication remains available
in parallel.

When a fingerprint is validated with the display off, Denial keeps the session
locked while waking the output, then waits 150 ms after the wake frame before
publishing success. This lets the unlock animation run on the lit display.
An already-lit display unlocks immediately. A new lock request cancels any
validated fingerprint waiting for display wake.

Denial talks directly to fprintd on the system bus, using the session user's
identity and the distribution's existing PolicyKit rules. No PAM fingerprint
module or additional PolicyKit grant is needed for this integration. On Arch,
install the optional `fprintd` package, which pulls in the libfprint drivers.
Missing hardware, absent enrollment, denied authorization, and service failures
leave password unlock available. While locked, unavailable-reader retries start
after one second and back off to at most 30 seconds. This avoids a long initial
delay when session authorization is still being established during startup.
Rejected fingerprints use an increasing cooldown, up to 30 seconds. A rejected
scan shows a localized “Fingerprint not recognized” banner for four seconds,
including before the password panel is opened. This advisory event preserves
the active password prompt and input focus; unlock clears the banner.

The native authentication worker owns each verification and binds it to the
current lock epoch and fprintd's unique bus owner. Unlock, re-lock, and shutdown
invalidate the scan; cleanup stops verification and releases the sensor.
Fingerprint success also cancels a pending password conversation. Flutter has
no command that can assert a fingerprint match or bypass the security gate.

Settings shows a Fingerprint section only while fprintd reports a device. It
initially shows only a sudo password prompt. After password verification it
offers first-time enrollment or lists enrolled fingers with an Add fingerprint
button. Enrollment reports scan progress and supports cancellation. Leaving
the section closes the privileged session and releases any device claim;
authorization also expires after five minutes.

The Settings process launches `sudo -S -k -- deniald --fingerprint-settings`
over private stdin/stdout pipes. The helper independently verifies the invoking
user's password through the `sudo` PAM service, including on hosts configured
with passwordless sudo, before reading any enrolled-finger metadata. It accepts
only listing, enrollment of a named finger, and cancellation for that user.
Passwords are never passed in command arguments or logged. Settings requires
`sudo` in addition to the optional `fprintd` package.

The isolated fprintd mock tests run as part of `tools/denial-pc test`. They never
access the system bus or real fingerprint hardware. For the focused Rust suite:

```sh
cd compositor
DENIAL_FPRINT_TEST_BUS=1 dbus-run-session -- \
  cargo test --locked --features flutter --bin deniald authentication::
```

## Renderer selection

Impeller GLES is the default renderer. A machine that needs the retained
Skia/Ganesh compatibility path can select it persistently in
`/etc/denial/session.conf`:

```sh
DENIAL_FLUTTER_RENDERER=skia
```

For a controlled one-shot session, pass `--flutter-renderer skia` through the
launcher instead. Renderer changes take effect when the Flutter engine starts,
so restart the Denial session after changing the machine override.

Denial environment variables use the `DENIAL_*` prefix. The former `DENIA_*`
spellings remain compatibility aliases during the transition; when both forms
are present, the `DENIAL_*` value takes precedence.

Machines whose display controller and GPU are exposed as different DRM nodes
can select the render node independently in `/etc/denial/session.conf`:

```sh
DENIAL_DRM_DEVICE=/dev/dri/card0
DENIAL_RENDER_DEVICE=/dev/dri/renderD128
```

Denial keeps KMS and scanout on `DENIAL_DRM_DEVICE`; GBM allocation, EGL, and
Flutter rendering use `DENIAL_RENDER_DEVICE`. When the render override is
unset, both paths continue to use the KMS device.

When the effective render device uses the VMware `vmwgfx` kernel driver, the
installed launcher automatically passes `--software-rendering`. Mesa then uses
its KMS software rasterizer for GBM/EGL while `vmwgfx` continues to own KMS
scanout. This compatibility path avoids depending on VMware's accelerated EGL
display, which can be unavailable even when the virtual display has working
modesetting. `denial-session --check` reports the detected kernel driver and
the selected Mesa policy.

An explicitly inherited `LIBGL_ALWAYS_SOFTWARE` value or an assignment in
`/etc/denial/session.conf` takes precedence over that automatic choice. Set it
to `0` to retry VMware acceleration for diagnostics, or to `1` to force Mesa
software rendering on another driver. Direct `deniald` diagnostics can request
the same software path with `--software-rendering`.

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
| `denial-session --check` | Validate the installation, discovered session lifecycle, bundle, output configuration, DRM and Mesa renderer selection, Qt platform theme, and Xwayland without starting a compositor |
| `denial-session --start-locked` | Start with Denial's native security gate and Flutter lock screen already locked |

`denial-session` forwards other arguments to `deniald`. Those lower-level
switches exist for controlled development and compositor diagnostics and are
not the stable end-user configuration interface. Run `deniald --help` to
inspect the options provided by the installed build; persistent user settings
belong in Denial Settings, while administrator overrides belong in
`/etc/denial/session.conf`.
