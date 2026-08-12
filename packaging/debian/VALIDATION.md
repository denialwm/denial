# Debian validation

## Debian 13 Workstation

Denial was validated on Debian 13 (trixie) with the GNOME Workstation package
set, GDM 48.0, systemd 257, kernel 6.12.101+deb13-amd64, and the proprietary
NVIDIA 550.163.01 driver on an RTX 4060 Laptop GPU. GDM launched the same direct
`/usr/bin/denial-session` Wayland entry used by the Fedora port; no UWSM
package, distribution flag, or launcher environment override was installed.

The session completed a real atomic commit on the internal 1920x1200 panel at
144.004 Hz, started the hardware Impeller Flutter shell and Xwayland, published
its discovered Wayland, X11, and control sockets to systemd and D-Bus
activation, and activated both `denial-session.target` and
`graphical-session.target`. `/usr/bin/denial-session --check` passed using the
installed payload and the DRM device selected from the connected output.

Stock GNOME Text Editor and GNOME Terminal launched through the user manager as
native Wayland clients. PipeWire 1.4.2 and WirePlumber 0.5.8 exposed the
laptop's audio devices. A fresh `org.freedesktop.portal.Screenshot` request
completed through xdg-desktop-portal 1.20.3 and xdg-desktop-portal-wlr 0.7.1,
producing a 1920x1200 PNG. These checks passed again after a cold boot into the
Debian logical volume and GDM autologin.

## Compatibility behavior exercised

The NVIDIA 550 driver advertised the primary plane's `IN_FENCE_FD` atomic
property but rejected the first commit carrying a real Flutter sync file with
`EPERM`. Denial initially uses the advertised kernel capability. Only after
that real fenced commit is rejected with an unsupported-operation class error
does the output scheduler retain the same framebuffer, wait for its sync file
through the event loop, and retry it without the fence property. Subsequent
frames use that userspace fence wait. Other atomic errors remain fatal, so the
fallback cannot hide DRM master loss, resource exhaustion, or a broken KMS
transaction. NVIDIA 610 on the Fedora host continued to use kernel fence
submission.

Debian supplies libddcutil 2.2.0 with ABI 5. It has the stable
`ddca_get_display_info` metadata API and legacy VCP setter, but not the newer
connector-aware metadata pair or verification-free setter. Denial selects the
available symbol pairs, correlates an I2C display to its DRM connector through
`/sys/class/drm/*/ddc`, and uses a complete base EDID only when it identifies a
single connector. The validation laptop has only an internal eDP panel, so the
worker correctly reported that no controllable DDC/CI display was present.

The Debian Bash 5.2 launcher also exposed a shutdown race. Restoring a trapped
termination signal to its default action from inside the active trap allowed
Bash to re-signal itself before `wait` returned. The launcher now ignores
re-entrant HUP, INT, and TERM while forwarding TERM to Denial and waiting for
the compositor's bounded KMS handoff. A GDM restart with the corrected launcher
recorded Denial releasing DRM master, completing the Flutter KMS session, and
finishing its KMS hold without the prior Bash trap warning or NVIDIA EGL
destructor crash. The next direct GDM session started normally.

## Host prerequisites

The internal panel is wired to the NVIDIA GPU. The host therefore needed the
Debian NVIDIA driver, matching kernel headers, DRM KMS enabled, preserved video
memory, and the vendor suspend, resume, and hibernate services. These are host
driver requirements. Denial still selects devices, atomic properties, library
entry points, and session services through capabilities rather than
distribution, GPU-vendor, or version checks.

## Native package validation

The Debian adapter built `denial-flutter-engine` and `denial` from the same
version-neutral payload used by the Fedora adapter. Staging rejected ELF inputs
newer than the glibc 2.39 baseline, and extraction proved every packaged file
and mode identical to that staging tree. No compilation or package assembly
ran inside Debian.

The Debian host had no prior Denial packages, but retained the files from its
runtime-port installation. APT resolved the two local packages and their
repository dependencies after the adapter mapped the XKB capability to
Debian's `xkb-data` package. Dpkg took ownership of the installed payload; the
one pre-existing machine configuration was deliberately retained during that
transition. A subsequent noninteractive reinstall preserved its SHA-256 and
completed without a conffile prompt.

After a GDM restart, the running process was `/usr/bin/deniald` with its bundle
below `/usr/lib/denial/flutter`. `denial-session --check` passed using only
package-owned paths, both graphical-session targets were active, and the four
compiled-file hashes matched the common staging payload. This validates the
native `.deb` transaction and graphical session independently of the earlier
manual runtime port.
