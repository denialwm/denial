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
