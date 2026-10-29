# denialctl

`denialctl` is Denial's native command-line client. It talks directly to the
compositor's per-user control socket and never depends on the Flutter shell
being able to render, process input, or receive a platform message.

That makes it both an inspection tool and the recovery path for live UI
development.

## Discovery and security

The client resolves the socket in this order:

1. `--socket PATH`;
2. `DENIAL_SOCKET`; then
3. `$XDG_RUNTIME_DIR/denial/control.sock`.

The path must be absolute, refer directly to a Unix socket, and have no
group/other permission bits. A normal Denial session creates its directory as
`0700`, its socket as `0600`, and exports `DENIAL_SOCKET` to launched
applications and the systemd/D-Bus activation environments.

## Runtime and recovery

Inspect the complete UI-development state:

```sh
denialctl ui status
```

Install the optional development package, then create, prepare, select, and
start a version-matched editable UI:

```sh
sudo pacman -S denial-ui-development
denialctl ui setup
```

Installations whose executables are outside `/usr/bin` can set
`DENIAL_CONTROL_TOOL` to the `denialctl` path and
`DENIAL_DEVELOPMENT_TOOL` to the `denial-ui` path. The shell uses both
overrides for its setup action, and `denialctl` uses the development-tool
override when it prepares the workspace.

The default source root is `~/DenialUI`; pass an explicit destination to
`ui setup` when preferred. Initial setup clones the branch or release recorded
by the package from GitHub and rejects it unless its commit matches the
installed source metadata. Compilation then uses the packaged source overlay
and locked dependencies offline. The resulting checkout starts on `main` with
the official Denial repository as `origin`. Existing checkouts are reused only
when they contain a valid Flutter workspace, and are never overwritten.

Advanced users can still select and start a manually managed source tree:

```sh
denial-ui prepare /absolute/path/to/denial/dart_shell
denialctl ui workspace /absolute/path/to/denial/dart_shell
denialctl ui live on
```

Return to the packaged optimized UI:

```sh
denialctl ui restore
```

`ui restore` does not ask the running Flutter code to cooperate. The native
controller accepts the command and replaces the Flutter runtime while
Wayland clients, KMS ownership, and the compositor session remain alive.

Runtime-mode commands wait for the requested mode by default. Use
`--no-wait` when a script only needs confirmation that the transition was
accepted.

The complete UI command set is:

```text
denialctl ui status
denialctl ui setup [PATH]
denialctl ui workspace PATH
denialctl ui live on|off
denialctl ui reload
denialctl ui restart
denialctl ui build
denialctl ui restore
denialctl ui revert
denialctl ui auto-reload on|off
denialctl ui vm-service
```

Commands whose backing capability is not implemented return an explicit
`rejected` error. Their names are already reserved so the CLI does not need a
second incompatible design when native file watching, VM-service control,
optimized builds, and rollback are completed.

## General status and outputs

Show a concise compositor summary:

```sh
denialctl status
```

List connected outputs, their active modes, positions, scales, power state,
and the current output-configuration serial:

```sh
denialctl outputs
```

Display changes continue to use the complete transactional output API. The
first `denialctl` version intentionally inspects that state but does not
provide a partial per-field mutation syntax which could bypass the existing
all-output validation and rollback model.

## Color correction

Show whether displays get their gamut correction, or switch it off and on to
compare. Screenshots never include it:

```sh
denialctl color correction
denialctl color correction off
denialctl color correction on
```

Grade the whole desktop with a `.cube` 3D LUT, as exported by Resolve and most
grading tools. Like the correction, it never reaches screenshots:

```sh
denialctl color lut load ~/luts/warm.cube
denialctl color lut clear
denialctl color
```

Grade one app instead, by its app ID. Unlike the desktop LUT this is part of the
picture, so screenshots and recordings include it:

```sh
denialctl color app org.mozilla.firefox lut load ~/luts/warm.cube
denialctl color apps
denialctl color app org.mozilla.firefox lut clear
```

Show HDR on a display whose EDID offers PQ, with SDR content at a chosen white
in cd/m² (203 by default). `srgb` is for displays that show a PQ signal stated
as BT.2020 with sRGB primaries:

```sh
denialctl color hdr
denialctl color hdr DP-4 on 150 srgb
denialctl color hdr DP-4 off
```

Open the color tuning editor, a shell panel that grades the desktop or a
picked app live:

```sh
denialctl color tune
```

Super+Alt+P opens and closes it too.

Every color change is saved in the `color` section of the settings document
and applies again at the next start. A LUT is saved by the absolute path it
was read from; one that no longer reads is skipped and stays saved.

## Machine-readable output

Every read and action command supports `--json`:

```sh
denialctl --json status
denialctl --json ui status
denialctl --json outputs
```

Standard output then contains only formatted JSON. Diagnostics and transport
errors go to standard error, and rejected or failed commands return a nonzero
exit status.

The underlying versioned protocol is documented in
[Control protocol v1](protocol/control-v1.md).
