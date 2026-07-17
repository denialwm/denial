# Denial compositor core

This directory contains the native Wayland compositor used by `deniald`. It
started from Hyprland and is now built only as part of Denial: the standalone
Hyprland executable, package manager, command-line client, installer, example
configuration, packaging files, and upstream CI are intentionally excluded.

Build from the repository root with:

```sh
tools/denial-pc build
```

The build tool provides pinned Aquamarine, `hyprland-protocols`, and `udis86`
sources from the external Denial cache. CMake also keeps generated protocol,
shader, version, and copied runtime-asset files in the external build tree.

The retained compositor code remains under the BSD 3-Clause license in
[`LICENSE`](LICENSE). Import ancestry and the upstream update policy are
documented in [`../HYPRLAND_HISTORY.md`](../HYPRLAND_HISTORY.md).
