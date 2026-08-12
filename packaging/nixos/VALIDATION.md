# NixOS 26.05 runtime validation

This records a development runtime validation, not an official Nix package.
Distribution packaging is intentionally deferred to the packaging pass.

## Test system

- Host: dedicated unattended validation machine `192.168.1.18`
- Distribution: NixOS 26.05.7443.70cc4559b10a
- Kernel: Linux 7.1.8
- Session: direct GDM Wayland session with systemd/logind
- Display: AMD-driven internal eDP panel at 1920x1200 and 144 Hz
- Secondary GPU: NVIDIA PRIME/offload device

The validation used a temporary Nix derivation containing Denial's normal
installed layout. Its session launcher found the compositor, control client,
and Flutter bundle relative to its resolved package prefix and started the
distribution-neutral `denial-session.target`. No NixOS name or filesystem
layout check was added to Denial.

The runtime closure declared the native interfaces used directly by the
payload, including EGL/libglvnd, PAM, PulseAudio, and Fontconfig. The tested
release engine had SHA-256
`8735bdabb624e5b12c9cfe3d7473c834c224fc707c88ed954bb13c255e82f8b1`.

## Portability fixes

NixOS does not normally expose system fonts below `/usr/share/fonts`. The
Flutter engine is now built with its Fontconfig backend, allowing it to use
the host's configured fonts through `libfontconfig.so.1` rather than a fixed
directory.

Nix profiles expose many application desktop entries as symbolic links.
Launcher discovery now follows only candidates named `*.desktop`, accepts a
candidate when its resolved target is a regular file, and ignores broken or
non-file links. This preserves desktop-file identity and precedence without
recursively traversing arbitrary links.

## Results

- The shell rendered its fonts correctly from the Nix store.
- The launcher discovered 33 visible applications from 97 installed desktop
  entries after applying desktop-entry visibility rules.
- Native Wayland Kitty and Xwayland XTerm launched successfully.
- PipeWire, WirePlumber, and the PulseAudio compatibility service were active;
  Denial's volume-down and volume-up controls changed the live sink volume.
- Desktop portals activated through the user D-Bus session, and direct Wayland
  screencopy succeeded.
- Native authentication connected through PAM on a fresh session startup.
- Wayland, X11, and Denial control endpoints were published to the systemd and
  D-Bus activation environments.
- A complete NixOS boot and a later display-manager session restart both
  reached a working direct Denial session.

The built-in panel was not exposed as a DDC-controllable display; its firmware
backlight behavior was outside this runtime portability pass.
