# Void Linux runtime validation

Void Linux is the first Denial validation system without a systemd user
manager. It exercises runit for system services, elogind for the standard
logind seat/session API, and a standalone user D-Bus started by the login
session.

Native Void packaging remains deferred with the other distribution adapters.
The lab installation uses the distribution-neutral installed layout under
`/usr/local` so runtime behavior is proven independently of a package recipe.

## Installation provenance

- official `void-x86_64-ROOTFS-20250202.tar.xz` glibc rootfs;
- SHA-256
  `3f48e6673ac5907a897d913c97eb96edbfb230162731b4016562c51b3b8f1876`;
- checksum manifest verified with the official Void 2025 release Minisign key;
- packages updated from Void's current signed repository on 2026-08-12;
- Void kernel `6.18.44_1`;
- isolated 32 GiB thin LV `denial_lab/void`, with no additional bootloader.

The initramfs includes LVM plus `dm_thin_pool`, `dm_persistent_data`,
`dm_bio_prison`, and `dm_bufio`. Limine loads hash-verified copies of that
initramfs and kernel from the shared Denial lab boot partition.

## Session model

The representative installation includes Void's Xfce desktop applications,
NetworkManager, greetd, elogind, PipeWire/WirePlumber, Xwayland, GTK and wlr
portals, Mesa, fonts, and the normal polkit agent.

Greetd starts a user-owned `dbus-run-session`, whose process tree owns
PipeWire, the polkit agent, and `denial-session --start-locked`. Runit starts
elogind before greetd so PAM establishes the seat session without racing
D-Bus activation. RTKit remains D-Bus activated, as a second runit instance
would duplicate the same service owner.

Denial does not identify Void or runit. Its launcher probes whether an active
systemd user manager is available. When one is absent, the launcher remains
the compositor's process parent. Once the first real KMS commit succeeds,
`deniald` always publishes its discovered Wayland, X11, desktop, and control
endpoints to D-Bus activation; it additionally manages the packaged systemd
target only when `org.freedesktop.systemd1` owns its standard bus name.

## Validated behavior

Validation on the physical `.18` hybrid-graphics host completed with:

- the internal `1920x1200` panel running at `144.004 Hz` on AMD Radeon 890M;
- Impeller OpenGL ES, the four-buffer native-fence atlas, and real atomic KMS;
- native PAM startup lock and successful unlock;
- installed application discovery and direct launch of Thunar, Kitty, and the
  Xfce task manager;
- Xwayland direct rendering on AMD through Mesa 26.1.6;
- a `1920x1200` compositor screenshot and active GTK/wlr portal processes;
- PipeWire Pulse compatibility, a real analog sink/source, and RTKit-backed
  compositor/display/raster priority elevation;
- persistent Wi-Fi with the physical adapter MAC, SSH, and one-shot EFI
  reboot selection;
- `denial-session --check` selecting `launcher process` as the session
  lifecycle without an override or distribution-specific branch.

The repository test pass covering this change completed with 405 Rust tests
passing and two explicitly ignored host-scheduling probes. The same built
payload was then used for the physical Void session above.
