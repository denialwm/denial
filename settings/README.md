# Settings

Settings and Welcome are one program: the GPUI application in
[denial-apps](https://github.com/denialwm/denial-apps) (`apps/settings`),
built against [gpui-touch](https://github.com/denialwm/gpui-touch). Denial
builds it and installs it with the `denial` package, on the desktop and the
phones alike. Its source and its own README are in denial-apps; this folder
holds what Denial adds.

Denial's Polkit agent (`apps/polkit` in denial-apps) is the second member of
Settings' Cargo workspace: it comes from the same locked commits, in the same
Cargo run, into the same package. It also draws denial-portal's Access
requests.

The plugin manager (`libraries/denial-plugins` in denial-apps) is the third:
Settings links it, and the same Cargo run builds its `denial-plugins`
command, which the `denial-plugin-manager` package carries
(docs/PLUGIN_MANAGER.md, section 25).

| File | What it is |
|---|---|
| `SOURCE_LOCK.json` | The denial-apps and gpui-touch commits every format builds |
| `org.denialwm.Settings.desktop` | The launcher entry; the application names its windows `org.denialwm.Settings` |
| `org.denialwm.Welcome.desktop` | Welcome's entry: the same program with `--welcome`, windows named `org.denialwm.Welcome` |

## What a package installs

| Path | What |
|---|---|
| `/usr/lib/denial-apps/settings` | The program |
| `/usr/bin/denial-settings` | A link to it; the shell and the compositor start this name. The entries name the program itself: a phone image that predates this keeps pacman from unpacking the link |
| `/usr/lib/denial-apps/polkit` | The Polkit agent and its dialogs |
| `/usr/bin/denial-polkit-agent` | A link to it, which the unit and the compositor start |
| `/usr/lib/systemd/user/denial-polkit-agent.service` | The agent's unit, part of `denial-session.target` |
| `/usr/share/applications/org.denialwm.{Settings,Welcome}.desktop` | The two entries |
| `/usr/share/icons/hicolor/512x512/apps/org.denialwm.Settings.png` | The icon |
| `/usr/share/licenses/denial/settings/` | denial-apps' license notice and texts |
| `/usr/share/denial/settings/SOURCE_LOCK.json` | The commits it was built from |

Settings draws with Vulkan and needs a Vulkan driver; the packages depend on
the loader. `iw` and `wireless-regdb` are optional: without them the Wi-Fi
country cannot be set.

## Building

`tools/denial-pc build` builds it with everything else, and
`tools/denial-pc settings` builds it alone. Both run `tools/denial-settings`:

```sh
tools/denial-settings build     # fetch the locked commits and build
tools/denial-settings path      # where the program is
tools/denial-settings polkit-path  # where the Polkit agent is
tools/denial-settings plugins-path # where the denial-plugins command is
tools/denial-settings lock      # the locked commits
```

The commits are fetched once into the dependency cache
(`$DENIAL_PC_DEPENDENCY_ROOT/settings-source`) and kept there. Cargo builds
into a target of its own beside the compositor's
(`$DENIAL_PC_RUST_TARGET-settings`), with Denial's Rust toolchain.
`DENIAL_TARGET_ARCH=aarch64` cross-builds it as it does the rest.

Packages check every program against glibc 2.39. Settings defines the math
functions newer glibc versions renamed (`src/glibc.rs` in denial-apps); when
the check names another function, it goes there.

## Trying a change before it is locked

Build the denial-apps and gpui-touch checkouts as they are on disk:

```sh
DENIAL_SETTINGS_SOURCE_ROOT=/path/holding/both tools/denial-settings build
```

`tools/denial-pc install-settings-entry` and `install-welcome-entry` point
this user's launcher entries at that build.

## Moving the lock

1. Push the denial-apps (and gpui-touch) commit.
2. Put its hash in `SOURCE_LOCK.json` and in the `denialApps` (or
   `gpuiTouch`) input URL in `flake.nix`, then run `nix flake lock`. The Nix
   lock check fails when the two differ.
3. `tools/denial-settings build`, then commit the three files together.

Nix builds the same commits with denial-apps' own `apps/settings/Cargo.lock`
(`nix/settings.nix`), both programs.

## Welcome

The compositor starts `denial-settings --welcome --autostart` at each full
startup; the program leaves at once when `$XDG_CONFIG_HOME/denial/welcome`
exists, which finishing or leaving Welcome writes. The launcher entry opens
it again at any time. In stacking mode the compositor centers its window on
the monitor it opens on.
