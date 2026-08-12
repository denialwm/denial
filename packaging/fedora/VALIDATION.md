# Fedora validation

## Fedora 44 Workstation

Denial was validated on a Fedora 44 Workstation installation using GDM and a
direct `/usr/bin/denial-session` Wayland session. The host used systemd 259,
glibc 2.43, kernel 7.1.8, and the RPM Fusion NVIDIA 610.57.04 driver on an
RTX 4060 Mobile GPU.

The session reached a real atomic commit on the internal 1920×1200 panel,
started the hardware Impeller Flutter shell, published its discovered Wayland,
X11, and control sockets to systemd and D-Bus activation, and started Xwayland.
Stock Fedora GTK applications launched through the user manager without
environment overrides, and native Wayland screen capture succeeded. No UWSM
package or launcher environment override was installed.

Fedora's `xdg-desktop-portal.service` has
`Requisite=graphical-session.target`. A direct display-manager session must
therefore activate Denial's packaged `denial-session.target` only after the
compositor has published its endpoints and completed its first real KMS
commit. The target binds to the standard `graphical-session.target`; the
launcher stops it after Denial exits. This is a session lifecycle requirement,
not a Fedora runtime branch. A fresh `org.freedesktop.portal.Screenshot`
request then completed successfully through `xdg-desktop-portal-wlr`. Stopping
GDM made Denial, both session targets, and all portal backends inactive;
starting GDM recreated the session and another fresh portal request succeeded.

Fedora also splits the libddcutil ABI library into the `libddcutil` package,
separately from the `ddcutil` command. Fedora 44 provides libddcutil 2.2.1 with
ABI 5 and the legacy `ddca_set_non_table_vcp_value` symbol. Denial selects that
symbol by capability when the verification-free 2.2.6 entry point is absent.

On this particular hybrid-graphics laptop, the internal panel is connected to
the NVIDIA device. Fedora's Nouveau driver exposed only legacy KMS on that
device, while the atomic AMD device had no connected outputs. Installing the
RPM Fusion NVIDIA driver supplied atomic KMS for the panel. That is a
host-driver requirement discovered through capabilities, not a Fedora or GPU
vendor branch in Denial.

## Native package validation

The Fedora spec built `denial-flutter-engine` and `denial` from the same
version-neutral payload used by the Debian adapter. It disabled stripping,
debug splitting, build-id links, and other package-time ELF rewriting.
Format-native extraction proved every packaged file and mode identical to the
common, glibc 2.39-gated staging tree. Neither compilation nor RPM assembly ran
inside Fedora.

DNF resolved the local RPM pair without an undeclared dependency. The host had
no prior Denial packages but retained its manual runtime-port files; RPM took
ownership of the payload, preserved the existing machine configuration, and
placed the packaged default beside it as `session.conf.rpmnew`. Reinstalling
both packages remained noninteractive and preserved the configuration hash.

After a fresh GDM launch, `/usr/bin/denial-session --check` resolved only
package-owned binaries and the `/usr/lib/denial/flutter` bundle. Both
graphical-session targets were active. GNOME Text Editor launched as a native
client, and `grim` captured a 1920x1200 PNG through the packaged compositor.
This validates the native RPM transaction and graphical session independently
of the earlier manual runtime port.
