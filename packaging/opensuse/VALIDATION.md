# openSUSE validation

## openSUSE Tumbleweed

Denial was validated on a clean openSUSE Tumbleweed 20260919 installation on
the shared `.18` lab host. The installation used kernel 7.2.6, systemd 261.2,
glibc 2.44, Mesa 26.2.2, GDM 50.3, Xwayland 24.1.13, and libseat 0.9.3.

The official appliance archive and its detached checksum signature were
verified before its root filesystem was provisioned into a new thin volume.
The existing lab volumes were not modified. The kernel and initramfs were
staged into the shared Limine boot partition with independently checked
BLAKE2b-512 URI hashes, and the resulting system booted from its LVM thin
volume with no failed system units.

## Native package validation

The openSUSE spec built `denial-flutter-engine` and `denial` from the common,
glibc 2.39-gated native staging tree. RPM extraction proved every packaged
file and mode byte-identical to that tree. Building under openSUSE also exposed
and fixed a locale-dependent package-inventory ordering bug: staging and
verification now force the C locale.

Zypper resolved the local package pair without an undeclared dependency or a
package removal. The only dependency-name changes from Fedora were `dbus-1`,
`xwayland`, and `google-noto-sans-cjk-fonts`; the compiled payload did not need
an openSUSE runtime branch. RPM verification passed after installation, and
`/usr/bin/denial-session --check` resolved only package-owned binaries and the
packaged Flutter bundle.

GDM started `/usr/bin/denial-session` as the real `seat0` session. The new
`deniald` process acquired the AMD DRM device, accepted its atomic KMS test for
the connected 1920x1200 panel, created hardware GLES 3.2 compositor,
screencopy, Flutter raster, and Flutter resource contexts, and started the
Impeller OpenGLES backend with native physical-output pools. Denial published
its Wayland, X11, control, and portal endpoints; Xwayland became ready; and
`denial-session.target`, `graphical-session.target`, the Denial portal, and
both desktop portal services were active. The engine mapped by the live
process matched the package's recorded SHA-256, and neither the system nor
user manager reported a failed unit.

A temporary RPM-MD repository generated from the exact pair with
`createrepo_c` refreshed successfully in Zypper and exposed both package names
and their exact versions. This proves the existing repository format is
reusable; signing, hosted-path isolation, release-asset names, and independent
published-client verification remain publication work.

Rendered appearance remains user-owned validation; no screenshots, test
applications, notifications, or synthetic UI events were used for this port.
