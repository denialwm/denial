# Ubuntu runtime validation

## Ubuntu 24.04.4 LTS

Denial was validated on a representative `ubuntu-desktop-minimal`
installation with GDM 46.2, systemd 255, glibc 2.39, HWE kernel
7.0.0-28-generic, and Mesa 25.2.8. The release pipeline now produces the
shared Debian-family package pair against this glibc baseline. The runtime
validation below predates a clean Ubuntu transaction test, so Ubuntu package
installation remains a separate validation gate from package generation and
signature publication.

The installation was bootstrapped noninteractively from Canonical's official
`ubuntu-base-24.04.4-base-amd64.tar.gz`. Its SHA-256 was
`c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58`,
and the matching checksum manifest was verified with Canonical's CD Image
Automatic Signing Key. The resulting desktop root lives on the isolated
`denial_lab/ubuntu2404` thin logical volume and boots hash-verified kernel and
initramfs copies from the shared lab boot partition.

GDM started Denial through the same distribution-neutral Wayland session and
systemd user-session lifecycle used on Fedora, Debian, and NixOS. A cold boot
reached a local `seat0` Wayland session on `tty2`; `denial-session --check`
found the installed compositor, control client, Flutter bundle, output
configuration, DRM/render device, and Xwayland without an override. Both
`denial-session.target` and `graphical-session.target` were active, with no
failed system or user units and no boot-priority errors.

## Hybrid graphics

The laptop's internal 1920x1200, 144.004 Hz panel is connected to the AMD
Radeon 890M, while the NVIDIA RTX 4060 has no connected connector in this boot.
Denial therefore selected the AMD device for both KMS scanout and rendering.
The GPUs do not have one unified memory pool: live GLX inspection reported
8,188 MiB of private NVIDIA VRAM and marked both devices as non-unified. They
do have the optimized Linux PRIME path. A compositor can allocate on a
separate render GPU, export DMA-BUFs, import them into the KMS GPU, and
synchronize them with fences without a CPU round trip when both drivers share
a usable format and modifier. Applications may also use an internal copy or
blit path that does not require the foreign buffer to be scanned out directly.

Both paths were tested. A `DRI_PRIME=1` Xwayland probe rendered through Zink on
NVK while AMD continued to drive the panel. Ubuntu's recommended
`nvidia-driver-595-open` driver was then installed in on-demand mode and Denial
was started with the NVIDIA render node while retaining AMD KMS. With that
driver, the standard PRIME render-offload variables also produced direct GLX
rendering on `NVIDIA GeForce RTX 4060 Laptop GPU` using NVIDIA 595.84. Denial
opened the independent render node correctly, but NVIDIA's EGL-renderable XR24
modifiers and the AMD primary plane's scanout modifiers had no intersection.
Startup therefore failed explicitly with `no XR24 modifier is common to EGL
rendering and the primary planes for eDP-2`; no unsafe implicit-modifier guess
or CPU-copy fallback was made.

This pair cannot use Denial's current direct shared-atlas path, even though
application PRIME offload works. The automatic AMD choice is therefore the
correct compatible default on this machine, not a general claim that an
integrated GPU is faster. Under the controlled 144 Hz workload, 30 valid
one-second AMD samples delivered 4,315 presentations with no missed vblanks
and no skipped or blocked Flutter frames. Future automatic selection must
remain capability-driven and should compare frame deadlines and power only
after modifier negotiation succeeds; it must not branch on distribution or
GPU vendor names.

## Validated behavior

- The hardware Impeller GLES shell completed real atomic KMS commits using the
  four-buffer native-fence atlas.
- The freshly built Dart bundle rendered correctly with Ubuntu, Noto Sans, and
  Noto Color Emoji fonts discovered through Fontconfig.
- The launcher discovered the installed desktop applications. GNOME Text
  Editor, Files, and Kitty ran as Wayland clients; Xwayland GLX used hardware
  acceleration on the AMD GPU.
- Native PAM lock and unlock completed successfully twice. Ubuntu's optional
  `pam_lastlog.so` reference emits a warning because that module is absent, but
  it does not affect authentication.
- PipeWire/WirePlumber exposed the real audio sink, source, and camera devices.
  GTK and wlr portal backends were active, and native Wayland capture produced
  a 1920x1200 screenshot.
- Wayland, X11, desktop, and Denial control endpoints were published to both
  systemd and D-Bus activation environments.

The install-root bootstrap did not create Ubuntu's normal
`display-manager.service` alias, so the lab setup supplied the standard alias
to `gdm.service` before first graphical validation. This is an installation
integration detail, not a Denial compatibility branch.
