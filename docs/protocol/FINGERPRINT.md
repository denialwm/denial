# Optical fingerprint presentation

`compositor/protocol/denial-fingerprint-v1.xml` coordinates a trusted fingerprint
worker with Denial's Flutter scene and native display policy. The image is an illumination
presentation target, never a captured biometric sample.

1. A session resolves a sensor identifier to a protected hardware profile.
2. A real fingerprint-region DOWN sends `present(serial, wl_buffer, x, y, width,
   height)`. The buffer comes from `linux-dmabuf`; geometry uses native,
   unrotated panel pixels and must match the profile.
3. Native copies the supplied image into one compositor-owned Flutter external
   texture and sends the logical geometry and scene epoch on `denial/fingerprint_scene`. Flutter
   builds opaque black plus the texture for a screen-off wake, or overlays the
   texture on its existing UI when awake. Flutter acknowledges layout; only
   subsequently authorized frames carry that epoch through physical scanout.
   Native does not paint into, clear, or rewrite completed Flutter buffers.
4. After that frame's actual page-flip completion (even when the kernel's
   timestamp is zero), Denial enables local panel illumination and
   waits for the configured settling interval before sending `ready(serial)`.
5. UP, withdrawal, timeout, disconnect, or policy revocation ends acquisition.
   Denial restores illumination and releases the client buffer. Flutter can
   keep the owned image at ordinary brightness through the short authentication
   handoff, without delaying fprintd's result. A screen-off wake retains black
   for up to three idle seconds for quick retries and authentication completion. It then powers
   off unless independent user activity or trusted authentication supersedes it.
6. Successful authentication reveals home while the black scene and fingerprint
   image fade together over 220 ms in Flutter. A reveal arriving before Flutter's authentication event remains
   black until the trusted unlocked state arrives. Awake unlock retains the
   normal lock transition. The desktop widget subtree is never reparented.

Authentication stays in fprintd and Denial's existing native authentication
controller, including PAM account checks and lock-epoch validation. The
Wayland protocol cannot assert a match or unlock the session.

The initial service policy accepts root peers only. Credentials are captured
from the accepted socket before Wayland insertion; global visibility callbacks
must use cached identity because they execute under a backend lock. Unknown
identity fails closed. Application IDs confer no authority.

Enable presentation with a root-owned, non-writable-by-others regular file at
`/etc/denial/fingerprint.json`. The Roadstr example is
`docs/hardware/roadstr-fingerprint.json`: DSI-1, 1220×2712, rectangle
(508,2338,204,204), connector HBM value 2 for fingerprint illumination and 0
for normal mode. Global maximum backlight is not a fallback. This board path
checks the panel identity through `/sys/class/drm/card0-DSI-1/panelName`.

The hardware profile and illumination backend are the device-specific parts.
Additional panels need validated profiles/backends; the protocol and fprintd
authentication path should remain shared. Current native worker integration
covers verification; enrollment retains the separately enabled screen-on
diagnostic worker. Hardware double-tap wake is described in `../hardware/WAKE_GESTURES.md`.

Status: the user accepted the Flutter-owned presentation after reboot, with
physical capture and trusted unlock working. Overlapping sensor preparation and
display wake subsequently reduced six observed screen-off unlocks to 0.76–0.82 s.
The user accepted the shared target/home fade; the final build measured about
0.51 s awake and 0.61–0.67 s for fresh screen-off contacts. The current geometry adapter supports unrotated outputs;
rotation needs a validated texture transform before enabling it.

The presentation image and black guard share one Flutter opacity animation on
trusted unlock (220 ms, immediate with reduced motion). Local HBM is disabled
first. Denial copies only the supplied small icon into one owned external texture;
it never samples a released client buffer or paints a completed output frame.
This permits immediate hardware cleanup and client release without waiting for
a UI animation before fprintd can deliver its result. An unsuccessful contact
retains the ordinary-brightness icon for at most 400 ms; trusted unlock extends
the scene lifetime to one second so Flutter can complete the fade. Independent
wake cancels that retention. One bounded presentation texture is cached and
replaced on the next contact; it contains no biometric data.
