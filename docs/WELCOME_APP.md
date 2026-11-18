# Welcome

Welcome is the desktop's first-start tour. It is Settings started with
`--welcome`: the GPUI application from denial-apps that Denial builds and
packages (see [`settings/README.md`](../settings/README.md)). Its windows are
named `org.denialwm.Welcome`, apart from Settings' `org.denialwm.Settings`,
and each is single-instance on its own: Settings can stay open beside it.

The five steps begin with a welcome screen and a Get started command, then
show the current shortcut bindings, pick the window layout, pick transparency
and appearance, and offer optional support links. Layout and appearance go
through Denial's settings and apply at once. The bindings come from the
compositor's shortcut service, unassigned actions included; moving and
resizing a window with Super and a drag are built in.

Finishing, and leaving after confirming, write
`$XDG_CONFIG_HOME/denial/welcome` (default `~/.config/denial/welcome`) and
close Welcome. Cancelling the confirmation changes nothing, and closing an
unfinished window through the compositor does not mark it complete. The
launcher entry always opens Welcome. Each full Denial startup starts it with
`--autostart` after initial scanout and session environment publication,
independent of systemd and XDG autostart; with `--autostart` the program
leaves before it registers or opens a window when the marker exists, so a
completed setup cannot take focus. Bounded diagnostics, test runs and Flutter
bundle refreshes do not start it. The older state-directory marker is taken
over on startup. Remove the marker to see Welcome at startup again.

In stacking mode, Welcome ignores saved placement and centers on the opening
monitor after the client supplies its actual size. This one-time placement
does not recenter later moves or resizes. Dwindle and scrolling own placement
normally.

`tools/denial-pc settings` builds the program; `tools/denial-pc welcome` also
installs Welcome's development launcher entry. To point that entry at another
build:

```sh
DENIAL_SETTINGS_BINARY=/path/to/settings tools/denial-pc install-welcome-entry
```

Welcome is in English and simplified Chinese. The Donate button opens the
sponsor page of the shown language; GitHub Sponsors and the repository have
their own buttons. A browser opens only on a button press. Visual validation
belongs to the user.
