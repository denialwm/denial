# Native application plugin ABI v1

Denial can load optional native-application providers without compiling them
into the compositor. The interface is product-neutral: a provider publishes
independent application windows, rendering into Denial-owned DMA-BUF targets,
explicit acquire fences, lifecycle state, and input. Denial supplies window
policy, target allocation, Flutter/KMS composition, visibility, configuration,
and release completion. It does not know or compose a provider's internal
application layers.

The canonical C declaration is
[`compositor/include/denial_native_app_plugin_v1.h`](../compositor/include/denial_native_app_plugin_v1.h).
Plugins may be implemented in any language that can export this C ABI. They
must not rely on Denial's Rust ABI.

## Loading and isolation

`DENIAL_NATIVE_APP_PLUGINS` is an `env::split_paths` list of absolute shared
object paths. If it is unset, Denial does not initialize a plugin manager and
normal compositor behavior is unchanged. Every configured path is
canonicalized and must identify a regular file owned by root or Denial's
effective user with no group/world write permission.

The plugin exports `denial_native_app_plugin_v1`. Denial passes a borrowed DRM
descriptor only for initialization; a plugin must duplicate it before the
entry point returns. The plugin returns a stable poll descriptor and callbacks.
Denial registers a duplicate of the poll descriptor in its compositor event
loop and invokes callbacks only on that thread. A plugin must never call back
into Denial from a worker or raster thread.

Entry and command callbacks return zero on success. `next_event` returns zero
for one event, one when drained, and a negative value on failure. A callback
must contain panics or language exceptions before they cross the C boundary.

## Identities and windows

Plugin object, buffer, frame, and external identity values are opaque nonzero
64-bit integers scoped to one loaded plugin. Denial assigns every accepted
window a host ID from a separate positive namespace. One plugin object maps to
one Denial toplevel; a provider may publish many objects simultaneously.

A window receives a render-target pool and configure immediately after
`CREATE_WINDOW`, but it is not published to the shell until its first target's
acquire fence becomes ready.
Providers may set `DENIAL_NATIVE_APP_CREATE_HEADLESS_V1` on `CREATE_WINDOW` for
an internal producer surface that must receive render targets and configure
events but must never become a shell window. Denial discards acquired frames
from such a surface without sampling them and completes their normal release
path. The flag is product-neutral and does not imply a particular guest or
application runtime.
Denial sends later configure, visibility/focus, close, and input commands to
the owning plugin. The provider remains responsible for mapping those neutral
operations into its application runtime.

Input follows the shell's authoritative front-to-back `InputLayout`. Shell
and software-keyboard regions win hit testing. A touch down over the first
visible, hit-testable plugin root captures that slot until up or cancel, even
if later motion leaves the window. Coordinates are mapped through the
published source rectangle and encoded as signed 16.16 values. Touch pressure
uses the full unsigned 16-bit range; physical keyboard commands carry Linux
evdev keycodes and a zero-based repeat count. `timestamp_nanos` is the kernel
monotonic input timestamp. Active plugin input is balanced or cancelled when
devices disappear, the session locks, shell capture becomes exclusive, or the
window is destroyed.

## Descriptor ownership

On a successful `next_event`, every nonnegative plane or acquire-fence
descriptor transfers to Denial. Unused descriptor slots must be `-1`. Denial
closes every transferred descriptor on success and on event-validation failure.
Strings, damage arrays, and other pointed-to event data remain plugin-owned and
need only stay valid until the next `next_event` call; Denial copies them
synchronously.

Descriptors in Denial-to-plugin commands are borrowed for that callback only.
This includes every plane in `REGISTER_RENDER_TARGET`. The plugin must
duplicate any descriptor it retains. Format arrays have the same synchronous
borrowed lifetime.

## DMA-BUF and synchronization

Denial sends renderer-supported explicit format/modifier pairs, allocates a
three-target GBM pool compatible with its renderer and scanout path, and lends
each allocation to the plugin with `REGISTER_RENDER_TARGET` before the matching
configure. The plugin imports the one through four dense DMA-BUF planes and
refers to that Denial identity in presents. It must not present a target from a
different configure generation or render into a target before the prior frame
reaches a terminal release command. Dimensions, strides, modifiers, damage,
configure serials, identities, and resource counts fail closed.

On resize Denial registers a new pool before sending the new configure. Old
targets are marked retired and are revoked with `UNREGISTER_RENDER_TARGET` as
soon as their last frame is released. Denial retains every GBM allocation for
the complete loan, so the plugin never owns or guesses host buffer lifetime.

The host independently limits configured plugins to 16, live plugin windows
to 4096, and pending acquire-fence frames to 4096. These bounds do not depend
on a provider's own protocol limits.

Each present transfers one acquire `sync_file`. Denial waits asynchronously by
polling it in the compositor event loop; it never blocks the compositor thread.
Release commands are ordered on the compositor thread. A completion fence is
borrowed with `MATERIALIZE_RELEASE`, followed by `COMPLETE_RELEASE` only after
GPU use ends. `DISCARD_RELEASE` is terminal for a frame that will not be used.

The ABI deliberately says nothing about Android, Wayland, a container format,
or a particular application framework. Those belong to independently shipped
plugins.
