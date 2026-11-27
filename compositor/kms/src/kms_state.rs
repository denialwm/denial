//! Ownership and rollback state for DRM scanouts and render-target buffers.

use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
#[cfg(feature = "flutter")]
use std::os::fd::AsRawFd;
#[cfg(feature = "flutter")]
use std::sync::Arc;

use denial_core::topology::{LogicalPoint, OutputId, OutputTransform, PixelRect, PixelSize};
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::format::FormatSet;
#[cfg(feature = "flutter")]
use smithay::backend::allocator::gbm::GbmDevice;
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBuffer, GbmBufferFlags};
use smithay::backend::allocator::{Allocator, Buffer as AllocatorBuffer, Format, Fourcc, Modifier};
use smithay::backend::drm::{DrmDevice, DrmDeviceFd, DrmSurface, PlaneConfig, PlaneState};
#[cfg(feature = "flutter")]
use smithay::backend::renderer::Bind;
#[cfg(feature = "flutter")]
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::output::Mode as OutputMode;
use smithay::reexports::drm::buffer::{DrmFourcc, DrmModifier, Handle as BufferHandle, PlanarBuffer};
use smithay::reexports::drm::control::{
    AtomicCommitFlags, Device as ControlDevice, FbCmd2Flags, Mode, PlaneType, RawResourceHandle,
    ResourceHandle, atomic::AtomicModeReq, connector, crtc, framebuffer, from_u32, plane,
    property,
};
use smithay::utils::{Buffer, Physical, Rectangle, Transform};
use tracing::{error, info, warn};

use crate::hotplug_transaction::{append_quarantined, install_candidate};

#[cfg(feature = "flutter")]
use super::kms_render::output_plane_state;
use super::kms_render::{plane_state, plane_state_for_mode};
#[cfg(feature = "flutter")]
use denial_core::topology::{RenderOutputPlan, RenderViewId};
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};

use smithay::reexports::rustix::{io, ioctl};

/// An output renders its next frame while the previous one is still on the
/// GPU, once frames take longer than a refresh allows. Frames that fit a
/// refresh and VRR outputs are unaffected. DENIAL_RENDER_AHEAD=0 turns it
/// off: a frame then starts only after the previous one has left for KMS.
pub fn render_ahead() -> bool {
    static RENDER_AHEAD: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *RENDER_AHEAD
        .get_or_init(|| render_ahead_enabled(std::env::var("DENIAL_RENDER_AHEAD").as_deref()))
}

fn render_ahead_enabled(value: Result<&str, &std::env::VarError>) -> bool {
    match value {
        Err(std::env::VarError::NotPresent) => true,
        Ok("0") => false,
        Ok("1") => true,
        _ => {
            warn!("DENIAL_RENDER_AHEAD must be 0 or 1; rendering ahead disabled");
            false
        }
    }
}

/// Atlas formats in preference order. XR30 keeps 10 bits per channel from
/// composition to scanout, the headroom color transforms need; XR24 serves
/// planes or renderers without it. Both store 32 bits per pixel.
const SCANOUT_FOURCCS: [Fourcc; 2] = [Fourcc::Xrgb2101010, Fourcc::Xrgb8888];
const SCANOUT_BYTES_PER_PIXEL: u64 = 4;
const MAX_SCANOUT_DIMENSION: u32 = 16_384;
const MAX_SCANOUT_POOL_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_SCANOUT_BUFFERS: usize = 49;
/// Scanout, a commit in KMS, a frame awaiting its GPU work, and the frame
/// Flutter renders: an output that renders ahead needs a fourth buffer, or
/// the frame it starts early leaves no free buffer for the next tick.
#[cfg(feature = "flutter")]
fn output_pool_length() -> usize {
    if render_ahead() {
        4
    } else {
        3
    }
}

/// Request local scanout constraints only when the render device also owns
/// KMS. A render-only GPU exports the atlas to another DRM device, so asking
/// its GBM allocator for local scanout can reject otherwise shareable LINEAR
/// render targets on output-less PRIME render sources.
pub fn scanout_gbm_flags(cross_device: bool) -> GbmBufferFlags {
    let flags = GbmBufferFlags::RENDERING;
    if cross_device {
        flags
    } else {
        flags | GbmBufferFlags::SCANOUT
    }
}

#[derive(Clone, Debug)]
pub struct ConnectedOutput {
    pub id: OutputId,
    pub name: String,
    pub connector: connector::Handle,
    pub crtc: crtc::Handle,
    pub mode: Mode,
    pub transform: OutputTransform,
    pub vrr_enabled: bool,
    /// The scale used when the configuration names none for this output.
    pub default_scale_120: u32,
}

pub struct Scanout {
    pub output: ConnectedOutput,
    pub surface: DrmSurface,
    pub plane_properties: AtlasPlaneProperties,
    pub source_rect: PixelRect,
    pub original_mode: Mode,
    /// Whether this logical output currently owns an active KMS pipeline.
    /// DPMS-off outputs deliberately remain in the topology and scanout list.
    pub powered: bool,
}

pub struct PreviousScanoutState {
    pub index: usize,
    pub output: ConnectedOutput,
    pub source_rect: PixelRect,
    pub pending_mode: Mode,
    pub pending_vrr: bool,
}

pub enum ScanoutRollbackFramebuffers {
    Atlas(framebuffer::Handle),
    #[cfg(feature = "flutter")]
    Outputs(BTreeMap<OutputId, (framebuffer::Handle, PixelSize)>),
}

impl ScanoutRollbackFramebuffers {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>> {
        match self {
            Self::Atlas(framebuffer) => Ok(plane_state(scanout, *framebuffer)),
            #[cfg(feature = "flutter")]
            Self::Outputs(outputs) => {
                let (framebuffer, size) = outputs
                    .get(&scanout.output.id)
                    .ok_or("rollback scanout has no retained physical framebuffer")?;
                Ok(output_plane_state(scanout, *framebuffer, *size))
            }
        }
    }
}

pub enum ReconciledScanoutOrigin {
    Reused(Box<PreviousScanoutState>),
    Created,
}

/// Owns both sides of a staged scanout replacement. Reused `DrmSurface`s live
/// in `candidate`, while removed surfaces remain pinned in their original
/// slots until the new scanout generation has reached vblank. Consequently no old surface
/// is dropped merely because preparation or TEST_ONLY failed.
pub struct ScanoutReconciliation<'a> {
    pub destination: &'a mut Vec<Scanout>,
    pub candidate: Vec<Scanout>,
    pub retired: Vec<Option<Scanout>>,
    pub origins: Vec<ReconciledScanoutOrigin>,
    pub resolved: bool,
}

impl ScanoutReconciliation<'_> {
    pub fn scanouts(&self) -> &[Scanout] {
        &self.candidate
    }

    pub fn clear_retired(&self) -> Vec<String> {
        let mut failures = Vec::new();
        for scanout in self.retired.iter().flatten() {
            if let Err(error) = scanout.surface.clear() {
                failures.push(format!(
                    "{} retired CRTC clear failed: {error}",
                    scanout.output.name
                ));
            }
        }
        failures
    }

    pub fn commit(mut self) -> Vec<Option<Scanout>> {
        // From this instruction onward Drop must never try to rebuild the old
        // vector: destination already owns every current scanout. The helper
        // resolves the journal before returning any displaced ownership.
        let displaced =
            install_candidate(self.destination, &mut self.candidate, &mut self.resolved);
        self.origins.clear();
        let mut retired = std::mem::take(&mut self.retired);
        // The destination is empty in a valid reconciliation. If an ownership
        // invariant regresses, retain any displaced resources until the same
        // post-finalization teardown point instead of dropping them here.
        retired.extend(displaced.into_iter().map(Some));
        retired
    }

    fn restore_ownership(&mut self) -> (Vec<String>, usize) {
        if self.resolved {
            return (Vec::new(), self.destination.len());
        }

        let mut failures = Vec::new();
        let mut quarantined = Vec::new();
        if self.candidate.len() != self.origins.len() {
            failures.push(format!(
                "ownership journal length mismatch: {} candidates for {} origins",
                self.candidate.len(),
                self.origins.len()
            ));
        }
        while !self.candidate.is_empty() && !self.origins.is_empty() {
            let Some(mut scanout) = self.candidate.pop() else {
                break;
            };
            let Some(origin) = self.origins.pop() else {
                quarantined.push(scanout);
                break;
            };
            match origin {
                ReconciledScanoutOrigin::Reused(previous) => {
                    let previous = *previous;
                    if let Err(error) = scanout.surface.use_mode(previous.pending_mode) {
                        failures.push(format!(
                            "{} pending-mode rollback failed: {error}",
                            previous.output.name
                        ));
                    }
                    if let Err(error) = scanout.surface.use_vrr(previous.pending_vrr) {
                        failures.push(format!(
                            "{} pending-VRR rollback failed: {error}",
                            previous.output.name
                        ));
                    }
                    scanout.output = previous.output;
                    scanout.source_rect = previous.source_rect;
                    match self.retired.get_mut(previous.index) {
                        Some(slot @ None) => *slot = Some(scanout),
                        Some(Some(_)) | None => {
                            failures.push(format!(
                                "{} ownership journal has an invalid destination slot",
                                scanout.output.name
                            ));
                            if let Err(error) = scanout.surface.clear() {
                                failures.push(format!(
                                    "{} orphaned CRTC clear failed: {error}",
                                    scanout.output.name
                                ));
                                quarantined.push(scanout);
                            }
                        }
                    }
                }
                ReconciledScanoutOrigin::Created => {
                    if let Err(error) = scanout.surface.clear() {
                        failures.push(format!(
                            "{} created CRTC clear failed: {error}",
                            scanout.output.name
                        ));
                        // Never destroy a surface that may still own an active
                        // CRTC. It was registered in RestoreState when staged,
                        // so the outer teardown can retry the clear while this
                        // object keeps the kernel state reachable.
                        quarantined.push(scanout);
                    }
                }
            }
        }
        if !self.candidate.is_empty() {
            failures.push(format!(
                "{} unjournaled scanout candidates quarantined",
                self.candidate.len()
            ));
            quarantined.append(&mut self.candidate);
        }
        if !self.origins.is_empty() {
            failures.push(format!(
                "{} ownership origins have no scanout candidate",
                self.origins.len()
            ));
            self.origins.clear();
        }
        let mut restored = self.retired.drain(..).flatten().collect::<Vec<_>>();
        let rollback_count = append_quarantined(&mut restored, &mut quarantined);
        *self.destination = restored;
        self.resolved = true;
        (failures, rollback_count)
    }

    pub fn rollback(
        mut self,
        old_framebuffers: &ScanoutRollbackFramebuffers,
        hardware: bool,
    ) -> Vec<String> {
        let (mut failures, rollback_count) = self.restore_ownership();
        if hardware {
            // Retry every old output even after one fails. This is compensation,
            // not an all-or-nothing setup path: preserving the remaining displays
            // is more valuable than returning at the first damaged connector.
            for scanout in self
                .destination
                .iter()
                .take(rollback_count)
                .filter(|scanout| scanout.powered)
            {
                let rollback = old_framebuffers
                    .plane_state(scanout)
                    .and_then(|state| scanout.surface.commit([state], false).map_err(Into::into));
                if let Err(error) = rollback {
                    failures.push(format!(
                        "{} hardware rollback failed: {error}",
                        scanout.output.name
                    ));
                }
            }
        }
        failures
    }
}

impl Drop for ScanoutReconciliation<'_> {
    fn drop(&mut self) {
        let (failures, _) = self.restore_ownership();
        for failure in failures {
            error!(
                failure,
                "restored scanout ownership during transaction unwind"
            );
        }
    }
}

#[derive(Clone, Copy)]
pub struct AtlasPlaneProperties {
    pub framebuffer: property::Handle,
    pub source_x: property::Handle,
    pub source_y: property::Handle,
    pub source_width: property::Handle,
    pub source_height: property::Handle,
    pub rotation: Option<property::Handle>,
    pub in_fence_fd: Option<property::Handle>,
    pub smithay_opaque_alpha: f32,
}

impl AtlasPlaneProperties {
    pub fn load(drm: &DrmDevice, plane: plane::Handle) -> Result<Self, Box<dyn Error>> {
        let smithay_opaque_alpha = match optional_named_property(drm, plane, "alpha")? {
            Some(alpha) => match drm.get_property(alpha)?.value_type() {
                property::ValueType::UnsignedRange(0, maximum) => {
                    let value = smithay_opaque_alpha_for_maximum(maximum);
                    if value != 1.0 {
                        info!(
                            ?plane,
                            maximum, "adapting to non-standard DRM plane alpha range"
                        );
                    }
                    value
                }
                _ => 1.0,
            },
            None => 1.0,
        };
        Ok(Self {
            framebuffer: named_property(drm, plane, "FB_ID")?,
            source_x: named_property(drm, plane, "SRC_X")?,
            source_y: named_property(drm, plane, "SRC_Y")?,
            source_width: named_property(drm, plane, "SRC_W")?,
            source_height: named_property(drm, plane, "SRC_H")?,
            rotation: optional_named_property(drm, plane, "rotation")?,
            in_fence_fd: optional_named_property(drm, plane, "IN_FENCE_FD")?,
            smithay_opaque_alpha,
        })
    }
}

impl Scanout {
    pub fn rotation_property(
        &self,
        transform: OutputTransform,
    ) -> Result<Option<(property::Handle, u64)>, Box<dyn Error>> {
        match self.plane_properties.rotation {
            Some(property) => Ok(Some((property, drm_rotation(transform)))),
            None if transform == OutputTransform::Normal => Ok(None),
            None => Err(format!(
                "{} primary plane does not expose the DRM rotation property required for {:?}",
                self.output.name, transform
            )
            .into()),
        }
    }
}

const fn drm_rotation(transform: OutputTransform) -> u64 {
    const ROTATE_0: u64 = 1 << 0;
    const ROTATE_90: u64 = 1 << 1;
    const ROTATE_180: u64 = 1 << 2;
    const ROTATE_270: u64 = 1 << 3;
    const REFLECT_Y: u64 = 1 << 5;

    match transform {
        OutputTransform::Normal => ROTATE_0,
        OutputTransform::Rotate90 => ROTATE_90,
        OutputTransform::Rotate180 => ROTATE_180,
        OutputTransform::Rotate270 => ROTATE_270,
        OutputTransform::Flipped => REFLECT_Y,
        OutputTransform::Flipped90 => REFLECT_Y | ROTATE_90,
        OutputTransform::Flipped180 => REFLECT_Y | ROTATE_180,
        OutputTransform::Flipped270 => REFLECT_Y | ROTATE_270,
    }
}

fn smithay_opaque_alpha_for_maximum(maximum: u64) -> f32 {
    const DRM_STANDARD_ALPHA_MAXIMUM: u64 = u16::MAX as u64;

    if (1..DRM_STANDARD_ALPHA_MAXIMUM).contains(&maximum) {
        maximum as f32 / DRM_STANDARD_ALPHA_MAXIMUM as f32
    } else {
        1.0
    }
}

pub struct KmsContext {
    pub drm: DrmDevice,
    pub scanouts: Vec<Scanout>,
    teardown: TeardownGate,
}

pub struct RestoreAttempt {
    pub restored: bool,
    pub failures: Vec<String>,
}

/// Owns the KMS framebuffer independently of the allocation. GBM owns its own
/// GEM handles; only the split-device PRIME path gives us handles to close.
struct ScanoutFramebuffer {
    handle: framebuffer::Handle,
    drm: DrmDeviceFd,
    imported_handles: Vec<BufferHandle>,
}

impl Drop for ScanoutFramebuffer {
    fn drop(&mut self) {
        if let Err(error) = close_scanout_framebuffer(&self.drm, self.handle) {
            warn!(framebuffer = ?self.handle, %error, "failed to close scanout framebuffer");
        }
        for handle in self.imported_handles.drain(..) {
            if let Err(error) = self.drm.close_buffer(handle) {
                warn!(buffer = ?handle, %error, "failed to close imported PRIME scanout handle");
            }
        }
    }
}

#[repr(C)]
struct DrmModeCloseFb {
    fb_id: u32,
    pad: u32,
}

const _: () = assert!(std::mem::size_of::<DrmModeCloseFb>() == 8);

pub fn close_scanout_framebuffer(
    drm: &DrmDeviceFd,
    handle: framebuffer::Handle,
) -> std::io::Result<()> {
    static LEGACY_RMFB_REQUIRED: AtomicBool = AtomicBool::new(false);

    if !LEGACY_RMFB_REQUIRED.load(Ordering::Relaxed) {
        // RMFB may disable an active plane and synchronously flush the kernel's
        // removal work, even after DRM master was released. CLOSEFB drops our
        // ownership without that modeset: an active scanout retains its own
        // reference until the next compositor replaces or disables it. Inactive
        // framebuffer storage is still released immediately. Use the same rule
        // for pool retirement, where a previous scanout can still hold a ref.
        // drm-rs 0.14 does not yet expose DRM_IOCTL_MODE_CLOSEFB.
        const REQUEST: ioctl::Opcode = ioctl::opcode::read_write::<DrmModeCloseFb>(b'd', 0xd0);
        let mut request = DrmModeCloseFb {
            fb_id: handle.into(),
            pad: 0,
        };
        loop {
            // SAFETY: the exact C-layout DRM UAPI payload is fully initialized,
            // and both it and the descriptor outlive this synchronous call.
            let result =
                unsafe { ioctl::ioctl(drm, ioctl::Updater::<REQUEST, _>::new(&mut request)) };
            match result {
                Ok(()) => return Ok(()),
                Err(io::Errno::INTR) => continue,
                // Older DRM dispatch tables return EINVAL for an unknown core
                // ioctl. The only CLOSEFB-specific EINVAL is nonzero padding,
                // which this request never supplies. Keep old-kernel support,
                // but report that it cannot provide the non-disabling handoff.
                Err(io::Errno::INVAL | io::Errno::NOTTY) => {
                    if !LEGACY_RMFB_REQUIRED.swap(true, Ordering::Relaxed) {
                        warn!("kernel lacks DRM CLOSEFB; using legacy framebuffer removal");
                    }
                    break;
                }
                Err(error) => return Err(error.into()),
            }
        }
    }
    drm.destroy_framebuffer(handle)
}

pub struct ScanoutAllocator {
    allocator: GbmAllocator<DrmDeviceFd>,
    drm_fd: DrmDeviceFd,
    cross_device: bool,
    #[cfg(feature = "flutter")]
    transfer: Option<SceneTransferAllocator>,
}

#[cfg(feature = "flutter")]
struct SceneTransferAllocator {
    source_gbm: GbmDevice<DrmDeviceFd>,
    scene_formats: FormatSet,
    source_probe: GlesRenderer,
    device: Arc<crate::gpu_transfer::TransferDevice>,
}

impl ScanoutAllocator {
    pub fn gbm(
        allocator: GbmAllocator<DrmDeviceFd>,
        drm_fd: DrmDeviceFd,
        cross_device: bool,
    ) -> Self {
        Self {
            allocator,
            drm_fd,
            cross_device,
            #[cfg(feature = "flutter")]
            transfer: None,
        }
    }

    #[cfg(feature = "flutter")]
    pub fn enable_scene_transfer(
        &mut self,
        source_gbm: GbmDevice<DrmDeviceFd>,
        source_fd: DrmDeviceFd,
        scene_display: &smithay::backend::egl::EGLDisplay,
    ) -> Result<(), Box<dyn Error>> {
        let context = crate::egl_context::create_render_context(scene_display)?;
        // SAFETY: this context belongs exclusively to this allocation probe.
        let source_probe = unsafe { GlesRenderer::new(context)? };
        let scene_formats = scene_display.dmabuf_render_formats().clone();
        let device = crate::gpu_transfer::TransferDevice::new(source_fd, self.drm_fd.clone())?;
        self.transfer = Some(SceneTransferAllocator {
            source_gbm,
            scene_formats,
            source_probe,
            device,
        });
        Ok(())
    }

    fn allocate(
        &mut self,
        size: PixelSize,
        code: Fourcc,
        modifiers: &[Modifier],
        mut scene_target: SceneTarget,
        scene_code: Option<Fourcc>,
    ) -> Result<ScanoutBuffer, Box<dyn Error>> {
        let mut buffer = ScanoutBuffer::allocate_gbm(
            &mut self.allocator,
            &self.drm_fd,
            self.cross_device,
            size,
            code,
            modifiers,
        )?;
        #[cfg(feature = "flutter")]
        if let Some(transfer) = &mut self.transfer {
            // Probe actual output-local storage, not physical-device identity.
            // A successful scene FBO import retains the existing direct pool.
            let mut direct = buffer.dmabuf.clone();
            if let Err(error) = transfer.source_probe.bind(&mut direct) {
                match scene_target {
                    SceneTarget::Required => {
                        return Err(format!(
                            "--flutter-offscreen-blit requires direct scene FBO import: {error}"
                        )
                        .into());
                    }
                    SceneTarget::IfDirect => scene_target = SceneTarget::None,
                    SceneTarget::None => {}
                }
                if code != Fourcc::Xrgb8888 {
                    return Err(format!(
                        "scene cannot render output-local {code:?} scanout ({error}); the transfer copies XR24 only"
                    )
                    .into());
                }
                info!(%error, "scene cannot render output-local scanout; negotiating destination import");
                buffer.scene_transfer =
                    Some(transfer.allocate(self.allocator.as_ref(), &buffer.dmabuf, size)?);
            } else {
                info!(format=?buffer.format, "scene imported output-local scanout directly; retaining direct Flutter pool");
            }
        }
        // Only the GPU draws and samples a display-color scene, so it takes
        // the scanout's layout, LINEAR where the scene format has none.
        // `--flutter-offscreen-blit` keeps its LINEAR scene.
        let layouts = match scene_target {
            SceneTarget::None => &[][..],
            SceneTarget::Required => &[Modifier::Linear][..],
            SceneTarget::IfDirect => &[buffer.format.modifier, Modifier::Linear][..],
        };
        if !layouts.is_empty() {
            buffer.render_target = Some(SceneRenderBuffer::allocate(
                &mut self.allocator,
                size,
                scene_code.unwrap_or(code),
                layouts,
            )?);
        }
        Ok(buffer)
    }
}

#[cfg(feature = "flutter")]
impl SceneTransferAllocator {
    fn allocate(
        &mut self,
        destination_gbm: &GbmDevice<DrmDeviceFd>,
        destination: &Dmabuf,
        size: PixelSize,
    ) -> Result<SceneTransferBuffers, Box<dyn Error>> {
        let mut failures = Vec::new();
        // Try every direct layout before requesting any Vulkan capabilities.
        for use_bridge in [false, true] {
            for fourcc in [
                Fourcc::Abgr8888,
                Fourcc::Argb8888,
                Fourcc::Xbgr8888,
                Fourcc::Xrgb8888,
            ] {
                let candidates = if use_bridge {
                    self.device
                        .source_modifiers(fourcc, size.width, size.height)
                } else {
                    self.device.direct_source_modifiers(fourcc)
                };
                let modifiers = candidates
                    .into_iter()
                    .filter(|modifier| {
                        self.scene_formats.contains(&Format {
                            code: fourcc,
                            modifier: *modifier,
                        })
                    })
                    .take(16)
                    .collect::<Vec<_>>();
                if modifiers.is_empty() {
                    continue;
                }
                let bridge = if use_bridge {
                    let bo = match destination_gbm.create_buffer_object_with_modifiers2::<()>(
                        size.width,
                        size.height,
                        fourcc,
                        [Modifier::Linear].into_iter(),
                        GbmBufferFlags::empty(),
                    ) {
                        Ok(bo) => bo,
                        Err(error) => {
                            failures
                                .push(format!("{fourcc:?} destination LINEAR allocation: {error}"));
                            continue;
                        }
                    };
                    let bridge = GbmBuffer::from_bo(bo, false);
                    if AllocatorBuffer::format(&bridge)
                        != (Format {
                            code: fourcc,
                            modifier: Modifier::Linear,
                        })
                        || bridge.plane_count() != 1
                    {
                        failures.push("bridge allocator returned unsupported layout".into());
                        continue;
                    }
                    Some(bridge)
                } else {
                    None
                };
                let bridge_dmabuf = bridge.as_ref().map(|buffer| buffer.export()).transpose()?;
                for flags in [
                    GbmBufferFlags::RENDERING,
                    GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT,
                ] {
                    // Some GBM backends expose their real EGL/Vulkan-compatible
                    // layout only through ordinary allocation. Its *returned*
                    // modifier is checked identically, never labelled LINEAR.
                    for requested_modifier in
                        crate::gpu_transfer::source_allocation_candidates(&modifiers, use_bridge)
                    {
                        let explicit = requested_modifier.is_some();
                        let allocation = if let Some(modifier) = requested_modifier {
                            self.source_gbm.create_buffer_object_with_modifiers2::<()>(
                                size.width,
                                size.height,
                                fourcc,
                                std::iter::once(modifier),
                                flags,
                            )
                        } else {
                            self.source_gbm.create_buffer_object::<()>(
                                size.width,
                                size.height,
                                fourcc,
                                flags,
                            )
                        };
                        let source_buffer = match allocation {
                            Ok(bo) => GbmBuffer::from_bo(bo, false),
                            Err(error) => {
                                failures.push(format!(
                                    "{fourcc:?} source flags={flags:?} explicit={explicit}: {error}"
                                ));
                                continue;
                            }
                        };
                        let actual = AllocatorBuffer::format(&source_buffer);
                        if actual.code != fourcc
                            || !modifiers.contains(&actual.modifier)
                            || source_buffer.plane_count() != 1
                        {
                            failures.push(format!(
                                "source allocator returned unnegotiated layout {actual:?}"
                            ));
                            continue;
                        }
                        let mut source = source_buffer.export()?;
                        if let Err(error) = self.source_probe.bind(&mut source) {
                            failures.push(format!("{actual:?} source EGL FBO import: {error}"));
                            continue;
                        }
                        match self.device.prepare(
                            source.clone(),
                            bridge_dmabuf.clone(),
                            destination.clone(),
                        ) {
                            Ok(target) => {
                                info!(
                                    ?actual,
                                    ?flags,
                                    explicit,
                                    width = size.width,
                                    height = size.height,
                                    bridge_allocated = bridge_dmabuf.is_some(),
                                    "negotiated destination-owned scene transfer"
                                );
                                return Ok(SceneTransferBuffers {
                                    source,
                                    bridge: bridge_dmabuf.clone(),
                                    target,
                                    _source_buffer: source_buffer,
                                    _bridge_buffer: bridge,
                                });
                            }
                            Err(error) => failures.push(format!(
                                "{actual:?} use_bridge={use_bridge} destination import: {error}"
                            )),
                        }
                    }
                }
            }
        }
        Err(format!(
            "no usable direct destination import or Vulkan transfer for {}x{}: {}",
            size.width,
            size.height,
            failures.join("; ")
        )
        .into())
    }
}

/// Whether an output buffer gets an off-screen scene for Flutter to render.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SceneTarget {
    None,
    /// `--flutter-offscreen-blit`: an output that cannot have one fails.
    Required,
    /// Display color: only where the scene renders this output directly;
    /// a transfer-fed output goes without.
    IfDirect,
}

struct SceneRenderBuffer {
    dmabuf: Dmabuf,
    _buffer: GbmBuffer,
}

impl SceneRenderBuffer {
    fn allocate(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        size: PixelSize,
        code: Fourcc,
        layouts: &[Modifier],
    ) -> Result<Self, Box<dyn Error>> {
        let buffer = allocator.create_buffer(size.width, size.height, code, layouts)?;
        let format = smithay::backend::allocator::Buffer::format(&buffer);
        if format.code != code || !layouts.contains(&format.modifier) {
            return Err(format!(
                "offscreen Flutter render target {format:?} is not {code:?} in {layouts:?}"
            )
            .into());
        }
        let dmabuf = buffer.export()?;
        Ok(Self {
            dmabuf,
            _buffer: buffer,
        })
    }
}

pub struct ScanoutBuffer {
    // Release framebuffer ownership before its backing allocation. An active
    // KMS plane independently pins the storage during a compositor handoff.
    framebuffer: ScanoutFramebuffer,
    pub dmabuf: Dmabuf,
    format: Format,
    render_target: Option<SceneRenderBuffer>,
    _buffer: GbmBuffer,
    #[cfg(feature = "flutter")]
    scene_transfer: Option<SceneTransferBuffers>,
}

#[cfg(feature = "flutter")]
struct SceneTransferBuffers {
    source: Dmabuf,
    bridge: Option<Dmabuf>,
    target: Arc<crate::gpu_transfer::TransferTarget>,
    _source_buffer: GbmBuffer,
    _bridge_buffer: Option<GbmBuffer>,
}

impl ScanoutBuffer {
    fn allocate_gbm(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        drm_fd: &DrmDeviceFd,
        cross_device: bool,
        size: PixelSize,
        code: Fourcc,
        modifiers: &[Modifier],
    ) -> Result<Self, Box<dyn Error>> {
        let buffer = allocator.create_buffer(size.width, size.height, code, modifiers)?;
        let format = smithay::backend::allocator::Buffer::format(&buffer);
        let dmabuf = buffer.export()?;
        let framebuffer = if cross_device {
            framebuffer_from_prime_dmabuf(drm_fd, &dmabuf)?
        } else {
            framebuffer_from_scanout_bo(drm_fd, &buffer, code)?
        };
        Ok(Self {
            framebuffer,
            dmabuf,
            format,
            render_target: None,
            _buffer: buffer,
            #[cfg(feature = "flutter")]
            scene_transfer: None,
        })
    }

    pub fn framebuffer(&self) -> framebuffer::Handle {
        self.framebuffer.handle
    }

    pub fn format(&self) -> Format {
        self.format
    }

    /// The composed scene before any output correction: what captures read.
    #[cfg(feature = "flutter")]
    pub fn scene_dmabuf(&self) -> &Dmabuf {
        self.render_target
            .as_ref()
            .map_or(&self.dmabuf, |target| &target.dmabuf)
    }

    #[cfg(feature = "flutter")]
    pub fn flutter_target_dmabufs(&self) -> (&Dmabuf, Option<&Dmabuf>) {
        (
            self.scene_transfer
                .as_ref()
                .map_or(&self.dmabuf, |transfer| &transfer.source),
            self.render_target.as_ref().map(|target| &target.dmabuf),
        )
    }
    #[cfg(feature = "flutter")]
    fn allocation_bytes(&self) -> Result<u64, Box<dyn Error>> {
        let mut buffers = vec![&self.dmabuf];
        if let Some(render) = &self.render_target {
            buffers.push(&render.dmabuf);
        }
        if let Some(transfer) = &self.scene_transfer {
            buffers.push(&transfer.source);
            if let Some(bridge) = &transfer.bridge {
                buffers.push(bridge);
            }
        }
        let mut bytes = 0u64;
        for buffer in buffers {
            for fd in buffer.handles() {
                // SAFETY: DMA-BUF descriptors support seeking to their backing
                // extent. No CPU mapping or pixel access is performed here.
                let extent = unsafe { libc::lseek(fd.as_raw_fd(), 0, libc::SEEK_END) };
                if extent <= 0 {
                    return Err("cannot determine DMA-BUF backing extent".into());
                }
                bytes = bytes
                    .checked_add(extent as u64)
                    .ok_or("DMA-BUF backing byte count overflow")?;
            }
        }
        // Shared aux-plane FDs may be counted twice, a conservative reservation.
        Ok(bytes)
    }

    #[cfg(feature = "flutter")]
    pub fn transfer_target(&self) -> Option<Arc<crate::gpu_transfer::TransferTarget>> {
        self.scene_transfer
            .as_ref()
            .map(|transfer| Arc::clone(&transfer.target))
    }
}

fn framebuffer_from_scanout_bo(
    drm: &DrmDeviceFd,
    buffer: &GbmBuffer,
    code: Fourcc,
) -> Result<ScanoutFramebuffer, Box<dyn Error>> {
    // This allocator requests opaque XR30 or XR24 only. Register the existing
    // GBM handles directly: PRIME-importing them back onto the same DRM fd
    // could return GBM's handles and incorrectly make us responsible for
    // closing them.
    if PlanarBuffer::format(buffer) != code {
        return Err(format!(
            "GBM scanout allocation did not preserve the requested {code:?} format"
        )
        .into());
    }
    let depth = if code == Fourcc::Xrgb2101010 { 30 } else { 24 };
    let flags = if PlanarBuffer::modifier(buffer).is_some() {
        FbCmd2Flags::MODIFIERS
    } else {
        FbCmd2Flags::empty()
    };
    let handle = match drm.add_planar_framebuffer(buffer, flags) {
        Ok(handle) => handle,
        Err(error) => {
            // Preserve Smithay's legacy ADDFB fallback for single-plane GBM
            // allocations. XR30 and XR24 have depth 30 and 24 and 32 storage
            // bits per pixel.
            if buffer.plane_count() > 1 {
                return Err(error.into());
            }
            warn!(%error, "ADDFB2 failed for GBM scanout; trying legacy ADDFB");
            drm.add_framebuffer(buffer, depth, 32)?
        }
    };
    Ok(ScanoutFramebuffer {
        handle,
        drm: drm.clone(),
        imported_handles: Vec::new(),
    })
}

/// Display-only DRM nodes may lack GBM import support for a scanout modifier.
/// Import GEM handles directly through PRIME and register them with ADDFB2.
fn framebuffer_from_prime_dmabuf(
    drm: &DrmDeviceFd,
    dmabuf: &Dmabuf,
) -> Result<ScanoutFramebuffer, Box<dyn Error>> {
    let plane_count = dmabuf.num_planes();
    if plane_count == 0 || plane_count > 4 {
        return Err(format!("cannot import a dma-buf with {plane_count} planes to KMS").into());
    }

    let mut handles = [None; 4];
    let mut imported_handles = Vec::with_capacity(plane_count);
    for (index, fd) in dmabuf.handles().enumerate() {
        let handle = match drm.prime_fd_to_buffer(fd) {
            Ok(handle) => handle,
            Err(error) => {
                close_prime_handles(drm, &mut imported_handles);
                return Err(error.into());
            }
        };
        handles[index] = Some(handle);
        if !imported_handles
            .iter()
            .any(|existing| u32::from(*existing) == u32::from(handle))
        {
            imported_handles.push(handle);
        }
    }

    let mut pitches = [0; 4];
    for (index, stride) in dmabuf.strides().enumerate() {
        pitches[index] = stride;
    }
    let mut offsets = [0; 4];
    for (index, offset) in dmabuf.offsets().enumerate() {
        offsets[index] = offset;
    }

    let format = AllocatorBuffer::format(dmabuf);
    let modifier = (format.modifier != Modifier::Invalid).then_some(format.modifier);
    let planar = AliasedPlanarBuffer {
        size: (dmabuf.width(), dmabuf.height()),
        format: format.code,
        modifier,
        pitches,
        handles,
        offsets,
    };
    let flags = if modifier.is_some() {
        FbCmd2Flags::MODIFIERS
    } else {
        FbCmd2Flags::empty()
    };
    let handle = match drm.add_planar_framebuffer(&planar, flags) {
        Ok(handle) => handle,
        Err(error) => {
            close_prime_handles(drm, &mut imported_handles);
            return Err(error.into());
        }
    };

    Ok(ScanoutFramebuffer {
        handle,
        drm: drm.clone(),
        imported_handles,
    })
}

fn close_prime_handles(drm: &DrmDeviceFd, handles: &mut Vec<BufferHandle>) {
    for handle in handles.drain(..) {
        if let Err(error) = drm.close_buffer(handle) {
            warn!(buffer = ?handle, %error, "failed to close PRIME handle after framebuffer import failure");
        }
    }
}

pub struct AtlasSwapchain {
    pub size: PixelSize,
    pub buffers: Vec<ScanoutBuffer>,
    pub current: usize,
}

/// Native scanout storage for one physical Flutter raster target. Buffer
/// indices are local to the output; Volition's stream ID disambiguates them.
#[cfg(feature = "flutter")]
pub struct OutputSwapchain {
    pub output_id: OutputId,
    pub render_view_id: RenderViewId,
    pub configuration_generation: u64,
    pub size: PixelSize,
    pub buffers: Vec<ScanoutBuffer>,
    pub current: usize,
    /// Gamut correction applied when copying Flutter's scene to scanout.
    pub color: Option<denial_color::output_color::OutputColor>,
    /// The primary plane's color pipeline. When it shows the desktop look and
    /// correction, nothing copies the scene and `color` is None.
    pub plane_color: Option<denial_color::plane_color::PlaneColor>,
    /// Whether a desktop look was loaded when the pool was made, when only
    /// the look decided whether it has a scene target to copy.
    pub copies_for_look: Option<bool>,
}

#[cfg(feature = "flutter")]
pub struct OutputSwapchains {
    pub outputs: Vec<OutputSwapchain>,
}

#[cfg(feature = "flutter")]
impl OutputSwapchains {
    pub fn allocate(
        allocator: &mut ScanoutAllocator,
        plans: &[RenderOutputPlan],
        scanouts: &[Scanout],
        render_formats: &FormatSet,
        offscreen_blit: bool,
    ) -> Result<Self, Box<dyn Error>> {
        if plans.len() != scanouts.len() || plans.is_empty() {
            return Err("physical output pools do not match the active scanouts".into());
        }

        let mut outputs = Vec::with_capacity(plans.len());
        let mut allocated_bytes = 0u64;
        let mut hdr_displays = Vec::new();
        for plan in plans {
            let scanout = scanouts
                .iter()
                .find(|scanout| scanout.output.id == plan.output_id)
                .ok_or("physical output pool has no matching scanout")?;
            #[cfg(feature = "flutter")]
            let render_formats = allocator
                .transfer
                .as_ref()
                .map_or(render_formats, |transfer| transfer.device.render_formats());
            // A corrected, graded or HDR output renders off-screen; the copy
            // to scanout converts it, and captures read the untouched scene.
            let display_color = denial_color::output_color::read(&allocator.drm_fd, scanout.output.id);
            let desktop_look = denial_color::output_color::desktop_lut().is_some();
            let mut hdr = display_color
                .hdr
                .zip(denial_color::output_color::hdr_request(&scanout.output.name))
                .map(|(display, mode)| denial_color::output_color::HdrOutput::new(display, mode));
            let formats = compatible_scanout_formats(
                &SCANOUT_FOURCCS,
                &[&scanout.surface.plane_info().formats],
                render_formats,
            );
            if formats.is_empty() {
                return Err(format!(
                    "no XR30 or XR24 modifier is common to EGL rendering and {}'s primary plane",
                    scanout.output.name
                )
                .into());
            }
            let pool_bytes = u64::from(plan.target_size.width)
                .checked_mul(u64::from(plan.target_size.height))
                .and_then(|pixels| pixels.checked_mul(SCANOUT_BYTES_PER_PIXEL))
                .and_then(|bytes| bytes.checked_mul(output_pool_length() as u64))
                .ok_or("physical output pool byte count overflow")?;
            let previous_bytes = allocated_bytes;
            allocated_bytes = allocated_bytes
                .checked_add(pool_bytes)
                .ok_or("physical output pool aggregate byte count overflow")?;
            if allocated_bytes > MAX_SCANOUT_POOL_BYTES {
                return Err(format!(
                    "physical output pools need {allocated_bytes} bytes, above the {MAX_SCANOUT_POOL_BYTES}-byte safety limit"
                )
                .into());
            }

            // An SDR output whose primary plane has a color pipeline shows the
            // look and correction there and renders straight into scanout.
            // Any other output keeps the pipeline off: the copy does the
            // work. The frame loop commits it once these pools are installed.
            let mut plane_color = denial_color::plane_color::PlaneColor::probe(
                &allocator.drm_fd,
                scanout.surface.plane(),
                display_color.correction.map(|correction| correction.matrix),
            )
            .unwrap_or_else(|error| {
                warn!(output = %scanout.output.name, %error, "could not read the plane's color pipelines");
                None
            });
            if let Some(pipeline) = &mut plane_color {
                pipeline.set_shows(hdr.is_none() && !offscreen_blit);
            }
            let plane_colored = plane_color
                .as_ref()
                .is_some_and(denial_color::plane_color::PlaneColor::shows);

            // Take the first format whose whole pool allocates, imports and
            // registers: a driver may advertise XR30 and still refuse it. HDR
            // scenes are half float; a display that cannot have one shows SDR.
            let mut allocate_pool = |hdr: Option<denial_color::output_color::HdrOutput>| {
                let color = hdr
                    .map(|hdr| hdr.output_color())
                    .or(display_color.correction.filter(|_| !plane_colored));
                let scene_target = if offscreen_blit {
                    SceneTarget::Required
                } else if color.is_some() || (desktop_look && !plane_colored) {
                    SceneTarget::IfDirect
                } else {
                    SceneTarget::None
                };
                let scene_code = hdr.map(|_| Fourcc::Abgr16161616f);
                for (index, format) in formats.iter().enumerate() {
                    match allocate_scanout_pool(
                        allocator,
                        plan.target_size,
                        output_pool_length(),
                        format,
                        scene_target,
                        scene_code,
                        MAX_SCANOUT_POOL_BYTES - previous_bytes,
                    ) {
                        Ok(pool) => {
                            info!(
                                output = %scanout.output.name,
                                format = ?format.code,
                                scanout = ?pool.first().map(ScanoutBuffer::format),
                                scene = ?pool.first().and_then(|buffer| buffer.render_target.as_ref()).map(|target| smithay::backend::allocator::Buffer::format(&target.dmabuf)),
                                gamut_correction = display_color.correction.is_some(),
                                hdr = hdr.is_some(),
                                desktop_look,
                                plane_colored,
                                "allocated output pool"
                            );
                            return Ok((pool, color, scene_target));
                        }
                        Err(error) if index + 1 < formats.len() => {
                            warn!(output = %scanout.output.name, format = ?format.code, %error, "output pool format failed; trying the next");
                        }
                        Err(error) => return Err(error),
                    }
                }
                Err::<_, Box<dyn Error>>("no output pool format allocated".into())
            };
            let (buffers, mut color, scene_target) = match allocate_pool(hdr) {
                Err(error) if hdr.is_some() => {
                    warn!(output = %scanout.output.name, %error, "could not allocate a half-float scene; showing SDR");
                    hdr = None;
                    allocate_pool(None)?
                }
                result => result?,
            };
            // Only the look decided this pool's scene target: gaining or
            // losing one rebuilds it (`synchronize_plane_color`).
            let copies_for_look =
                (!offscreen_blit && !plane_colored && color.is_none()).then_some(desktop_look);
            if scene_target == SceneTarget::IfDirect
                && !buffers.iter().all(|buffer| buffer.render_target.is_some())
            {
                warn!(
                    output = %scanout.output.name,
                    "the scene reaches this output through the GPU transfer; showing it without display color"
                );
                color = None;
                hdr = None;
            }
            if let Err(error) =
                apply_connector_hdr(&allocator.drm_fd, scanout.output.connector, hdr)
            {
                warn!(output = %scanout.output.name, %error, "the display did not take the HDR signal; showing SDR");
                if hdr.take().is_some() {
                    color = display_color.correction.filter(|_| !plane_colored);
                }
            }
            if let Some(capability) = display_color.hdr {
                hdr_displays.push(denial_color::output_color::HdrDisplay {
                    id: scanout.output.id,
                    name: scanout.output.name.clone(),
                    display: capability,
                    active: hdr.map(denial_color::output_color::HdrOutput::mode),
                });
            }
            let actual_bytes = buffers.iter().try_fold(0u64, |bytes, buffer| {
                bytes
                    .checked_add(buffer.allocation_bytes()?)
                    .ok_or_else(|| -> Box<dyn Error> {
                        "physical output backing byte count overflow".into()
                    })
            })?;
            allocated_bytes = previous_bytes
                .checked_add(actual_bytes)
                .ok_or("physical output backing aggregate overflow")?;
            if allocated_bytes > MAX_SCANOUT_POOL_BYTES {
                return Err(format!("physical source/bridge/scanout backings reserve {allocated_bytes} bytes, above {MAX_SCANOUT_POOL_BYTES}").into());
            }
            outputs.push(OutputSwapchain {
                output_id: plan.output_id,
                render_view_id: plan.render_view_id,
                configuration_generation: plan.configuration_generation,
                size: plan.target_size,
                buffers,
                current: 0,
                copies_for_look,
                color,
                plane_color,
            });
        }
        denial_color::output_color::set_hdr_displays(hdr_displays);
        Ok(Self { outputs })
    }

    pub fn for_output(&self, output: OutputId) -> Option<&OutputSwapchain> {
        self.outputs.iter().find(|pool| pool.output_id == output)
    }

    pub fn for_output_mut(&mut self, output: OutputId) -> Option<&mut OutputSwapchain> {
        self.outputs
            .iter_mut()
            .find(|pool| pool.output_id == output)
    }

    pub fn framebuffer(
        &self,
        output: OutputId,
        index: usize,
    ) -> Option<framebuffer::Handle> {
        self.for_output(output)?
            .buffers
            .get(index)
            .map(ScanoutBuffer::framebuffer)
    }

    pub fn present(&mut self, output: OutputId, index: usize) -> Result<(), &'static str> {
        let pool = self
            .for_output_mut(output)
            .ok_or("presented output has no native buffer pool")?;
        if index >= pool.buffers.len() {
            return Err("presented output buffer exceeds its native pool");
        }
        pool.current = index;
        Ok(())
    }
}

/// The active presentation storage has exactly one representation. Diagnostic
/// rendering uses a virtual desktop atlas; Flutter renders directly into one
/// native pool per physical output. Keeping the alternatives disjoint makes
/// it impossible for the Flutter path to silently fall back to atlas scanout.
pub enum RenderSwapchains {
    Atlas(AtlasSwapchain),
    #[cfg(feature = "flutter")]
    Outputs {
        desktop_size: PixelSize,
        swapchains: OutputSwapchains,
    },
}

impl RenderSwapchains {
    pub fn desktop_size(&self) -> PixelSize {
        match self {
            Self::Atlas(atlas) => atlas.size,
            #[cfg(feature = "flutter")]
            Self::Outputs { desktop_size, .. } => *desktop_size,
        }
    }

    #[cfg(feature = "flutter")]
    pub fn set_desktop_size(&mut self, size: PixelSize) -> Result<(), &'static str> {
        match self {
            Self::Outputs { desktop_size, .. } => {
                *desktop_size = size;
                Ok(())
            }
            Self::Atlas(_) => Err("diagnostic atlas has no Flutter desktop size"),
        }
    }

    pub fn atlas(&self) -> Option<&AtlasSwapchain> {
        match self {
            Self::Atlas(atlas) => Some(atlas),
            #[cfg(feature = "flutter")]
            Self::Outputs { .. } => None,
        }
    }

    pub fn atlas_mut(&mut self) -> Option<&mut AtlasSwapchain> {
        match self {
            Self::Atlas(atlas) => Some(atlas),
            #[cfg(feature = "flutter")]
            Self::Outputs { .. } => None,
        }
    }

    #[cfg(feature = "flutter")]
    pub fn outputs(&self) -> Option<&OutputSwapchains> {
        match self {
            Self::Atlas(_) => None,
            Self::Outputs { swapchains, .. } => Some(swapchains),
        }
    }

    #[cfg(feature = "flutter")]
    pub fn outputs_mut(&mut self) -> Option<&mut OutputSwapchains> {
        match self {
            Self::Atlas(_) => None,
            Self::Outputs { swapchains, .. } => Some(swapchains),
        }
    }

    pub fn representative_framebuffer(&self) -> framebuffer::Handle {
        match self {
            Self::Atlas(atlas) => atlas.current_framebuffer(),
            #[cfg(feature = "flutter")]
            Self::Outputs { swapchains, .. } => swapchains
                .outputs
                .first()
                .and_then(|pool| pool.buffers.get(pool.current))
                .expect("validated physical output storage is non-empty")
                .framebuffer(),
        }
    }
}

pub struct ScreenshotBuffer {
    pub dmabuf: Dmabuf,
    _buffer: GbmBuffer,
}

impl ScreenshotBuffer {
    pub fn allocate(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        size: PixelSize,
        modifier: Modifier,
    ) -> Result<Self, Box<dyn Error>> {
        let buffer =
            allocator.create_buffer(size.width, size.height, Fourcc::Xrgb8888, &[modifier])?;
        let dmabuf = buffer.export()?;
        Ok(Self {
            dmabuf,
            _buffer: buffer,
        })
    }
}

pub struct LayoutTransition {
    pub at_frame: u64,
    pub positions: BTreeMap<String, LogicalPoint>,
}

/// An atlas pixel format and the modifiers every consumer can use with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AtlasFormat {
    pub code: Fourcc,
    pub modifiers: Vec<Modifier>,
}

/// Return, in the order of `fourccs`, each format that every plane can scan
/// out and EGL can render into, with its usable modifiers.
fn compatible_scanout_formats(
    fourccs: &[Fourcc],
    plane_formats: &[&FormatSet],
    render_formats: &FormatSet,
) -> Vec<AtlasFormat> {
    fourccs
        .iter()
        .filter_map(|&code| {
            let modifiers = compatible_modifiers(code, plane_formats, render_formats);
            (!modifiers.is_empty()).then_some(AtlasFormat { code, modifiers })
        })
        .collect()
}

fn common_modifiers(code: Fourcc, format_sets: &[&FormatSet]) -> Vec<Modifier> {
    let Some((first, remaining)) = format_sets.split_first() else {
        return Vec::new();
    };
    first
        .iter()
        .filter(|format| format.code == code && format.modifier != Modifier::Invalid)
        .filter(|format| remaining.iter().all(|formats| formats.contains(format)))
        .map(|format| format.modifier)
        .collect()
}

fn compatible_modifiers(
    code: Fourcc,
    plane_formats: &[&FormatSet],
    render_formats: &FormatSet,
) -> Vec<Modifier> {
    let mut modifiers = common_modifiers(code, plane_formats);
    let renderer_has_explicit_modifiers = render_formats
        .iter()
        .any(|format| format.code == code && format.modifier != Modifier::Invalid);
    if renderer_has_explicit_modifiers {
        modifiers.retain(|modifier| {
            render_formats.contains(&Format {
                code,
                modifier: *modifier,
            })
        });
    } else {
        modifiers.retain(|modifier| *modifier == Modifier::Linear);
    }

    let implicit = Format {
        code,
        modifier: Modifier::Invalid,
    };
    if modifiers.is_empty()
        && !plane_formats.is_empty()
        && plane_formats
            .iter()
            .all(|formats| formats.contains(&implicit))
        && render_formats.contains(&implicit)
    {
        // GBM may satisfy this through an explicit LINEAR allocation or its
        // legacy implicit allocation path. Both are safe when every consumer
        // advertises the implicit format, unlike guessing a vendor modifier.
        modifiers.push(Modifier::Linear);
    }

    modifiers
}

/// Return the atlas format every primary plane can scan out and EGL can
/// render into: XR30 when all of them support it, otherwise XR24. Plane order
/// is retained: DRM exposes the driver's preferred tiled/compressed layouts
/// first and LINEAR last on hardware that supports both. If there is no
/// explicit intersection but every consumer advertises the legacy implicit
/// format, fall back to a LINEAR allocation request rather than guessing that
/// a vendor modifier is renderable.
pub fn shared_atlas_format(
    scanouts: &[Scanout],
    render_formats: &FormatSet,
) -> Result<AtlasFormat, Box<dyn Error>> {
    if scanouts.is_empty() {
        return Err("shared atlas format selection needs at least one primary plane".into());
    }

    let plane_formats = scanouts
        .iter()
        .map(|scanout| &scanout.surface.plane_info().formats)
        .collect::<Vec<_>>();
    compatible_scanout_formats(&SCANOUT_FOURCCS, &plane_formats, render_formats)
        .into_iter()
        .next()
        .ok_or_else(|| {
        let outputs = scanouts
            .iter()
            .map(|scanout| scanout.output.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "no XR30 or XR24 modifier is common to EGL rendering and the primary planes for {outputs}"
        )
        .into()
    })
}

impl AtlasSwapchain {
    pub fn allocate(
        allocator: &mut ScanoutAllocator,
        size: PixelSize,
        format: &AtlasFormat,
    ) -> Result<Self, Box<dyn Error>> {
        Self::allocate_pool(allocator, size, 2, format, false)
    }

    pub fn allocate_pool(
        allocator: &mut ScanoutAllocator,
        size: PixelSize,
        length: usize,
        format: &AtlasFormat,
        linear_render_targets: bool,
    ) -> Result<Self, Box<dyn Error>> {
        let scene_target = if linear_render_targets {
            SceneTarget::Required
        } else {
            SceneTarget::None
        };
        let buffers = allocate_scanout_pool(
            allocator,
            size,
            length,
            format,
            scene_target,
            None,
            MAX_SCANOUT_POOL_BYTES,
        )?;
        Ok(Self {
            size,
            buffers,
            current: 0,
        })
    }

    pub fn current_framebuffer(&self) -> framebuffer::Handle {
        self.buffers[self.current].framebuffer()
    }

    pub fn next_index(&self) -> usize {
        (self.current + 1) % self.buffers.len()
    }

    pub fn present(&mut self, index: usize) {
        debug_assert!(index < self.buffers.len());
        self.current = index;
    }
}

fn allocate_scanout_pool(
    allocator: &mut ScanoutAllocator,
    size: PixelSize,
    length: usize,
    format: &AtlasFormat,
    scene_target: SceneTarget,
    scene_code: Option<Fourcc>,
    _byte_budget: u64,
) -> Result<Vec<ScanoutBuffer>, Box<dyn Error>> {
    validate_scanout_pool_allocation(size, length)?;
    let modifiers = &format.modifiers;
    let optimized = modifiers
        .iter()
        .copied()
        .filter(|modifier| *modifier != Modifier::Linear && *modifier != Modifier::Invalid)
        .collect::<Vec<_>>();
    let linear_supported = modifiers.contains(&Modifier::Linear);
    if optimized.is_empty() && !linear_supported {
        return Err("scanout allocation received no usable DRM modifier".into());
    }

    let allocate = |allocator: &mut ScanoutAllocator, modifiers: &[Modifier]| {
        let mut buffers = Vec::with_capacity(length);
        #[cfg(feature = "flutter")]
        let mut bytes = 0u64;
        for _ in 0..length {
            let buffer =
                allocator.allocate(size, format.code, modifiers, scene_target, scene_code)?;
            #[cfg(feature = "flutter")]
            {
                bytes = bytes
                    .checked_add(buffer.allocation_bytes()?)
                    .ok_or("physical output backing byte count overflow")?;
                if bytes > _byte_budget {
                    return Err(format!(
                        "negotiated output pool exceeds its {_byte_budget}-byte budget"
                    )
                    .into());
                }
            }
            buffers.push(buffer);
        }
        Ok::<_, Box<dyn Error>>(buffers)
    };
    let buffers = if optimized.is_empty() {
        allocate(allocator, &[Modifier::Linear])?
    } else {
        match allocate(allocator, &optimized) {
            Ok(buffers) => buffers,
            Err(optimized_error) if linear_supported => {
                warn!(
                    %optimized_error,
                    "could not allocate a tiled/compressed scanout pool; falling back to LINEAR"
                );
                allocate(allocator, &[Modifier::Linear]).map_err(|linear_error| {
                        format!(
                            "optimized scanout allocation failed ({optimized_error}); LINEAR fallback failed ({linear_error})"
                        )
                    })?
            }
            Err(error) => {
                return Err(format!(
                        "could not allocate the scanout pool with any compatible optimized modifier: {error}"
                    )
                    .into());
            }
        }
    };
    Ok(buffers)
}

fn validate_scanout_pool_allocation(size: PixelSize, length: usize) -> Result<(), Box<dyn Error>> {
    if !(2..=MAX_SCANOUT_BUFFERS).contains(&length) {
        return Err(format!(
            "scanout pool length {length} is outside the supported 2..={MAX_SCANOUT_BUFFERS} range"
        )
        .into());
    }
    if size.width == 0 || size.height == 0 {
        return Err("scanout buffers need a non-empty extent".into());
    }
    if size.width > MAX_SCANOUT_DIMENSION || size.height > MAX_SCANOUT_DIMENSION {
        return Err(format!(
            "scanout target {}x{} exceeds the supported {}-pixel texture dimension",
            size.width, size.height, MAX_SCANOUT_DIMENSION
        )
        .into());
    }
    let pool_bytes = u64::from(size.width)
        .checked_mul(u64::from(size.height))
        .and_then(|pixels| pixels.checked_mul(SCANOUT_BYTES_PER_PIXEL))
        .and_then(|bytes| bytes.checked_mul(u64::try_from(length).ok()?))
        .ok_or("scanout pool byte count overflow")?;
    if pool_bytes > MAX_SCANOUT_POOL_BYTES {
        return Err(format!(
            "scanout pool needs {pool_bytes} bytes, above the {}-byte safety limit",
            MAX_SCANOUT_POOL_BYTES
        )
        .into());
    }
    Ok(())
}

impl KmsContext {
    pub fn new(drm: DrmDevice) -> Self {
        Self {
            drm,
            scanouts: Vec::new(),
            teardown: TeardownGate::default(),
        }
    }

    pub fn pause(&mut self) {
        if self.drm.is_active() {
            self.drm.pause();
        }
    }

    pub fn restore_once(
        &mut self,
        restore_state: &RestoreState,
        framebuffer: framebuffer::Handle,
    ) -> RestoreAttempt {
        if !self.teardown.begin() {
            return RestoreAttempt {
                restored: false,
                failures: Vec::new(),
            };
        }

        // A disabled libseat session no longer owns DRM master. Touching KMS
        // here could race the compositor on the active VT, so leave that
        // session's scanout intact and only make our destructors inert.
        if !self.drm.is_active() {
            warn!("KMS teardown happened while libseat was inactive; skipping atomic restore");
            return RestoreAttempt {
                restored: false,
                failures: Vec::new(),
            };
        }

        let mode_restore =
            restore_original_modes_with_atlas(&self.scanouts, restore_state, framebuffer);
        let plane_restore = restore_state.restore_planes(&self.scanouts);
        self.pause();

        let mut failures = Vec::new();
        if let Err(error) = mode_restore {
            failures.push(format!("mode restore failed: {error}"));
        }
        if let Err(error) = plane_restore {
            failures.push(format!("plane restore failed: {error}"));
        }
        RestoreAttempt {
            restored: failures.is_empty(),
            failures,
        }
    }
}

impl Drop for KmsContext {
    fn drop(&mut self) {
        // DrmSurface::drop actively disables its CRTC. Pausing first makes all
        // surface destructors inert and also suppresses Smithay's broad
        // best-effort restore, which is not valid for framebuffers owned by a
        // different DRM client (for example an inactive display manager).
        self.pause();
    }
}

#[derive(Clone, Copy, Debug)]
struct SavedAtomicProperty {
    object: RawResourceHandle,
    property: property::Handle,
    value: property::RawValue,
}

#[derive(Debug)]
pub struct RestoreState {
    outputs: Vec<SavedOutputState>,
}

#[derive(Debug)]
struct SavedOutputState {
    id: OutputId,
    name: String,
    original_mode: Mode,
    /// `None` means this output was inactive when Denial first discovered it.
    framebuffer: Option<framebuffer::Handle>,
    properties: Vec<SavedAtomicProperty>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ScanoutIdentity {
    output: u64,
    connector: u32,
    crtc: u32,
    plane: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ScanoutIdentityError {
    Zero(&'static str),
    OutputConnectorMismatch { output: u64, connector: u32 },
    DuplicateOutput(u64),
    DuplicateConnector(u32),
    DuplicateCrtc(u32),
    DuplicatePlane(u32),
}

impl fmt::Display for ScanoutIdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Zero(kind) => write!(formatter, "scanout has zero {kind} identity"),
            Self::OutputConnectorMismatch { output, connector } => write!(
                formatter,
                "output {output} does not match connector {connector}"
            ),
            Self::DuplicateOutput(output) => {
                write!(formatter, "output {output} owns multiple scanouts")
            }
            Self::DuplicateConnector(connector) => {
                write!(formatter, "connector {connector} owns multiple scanouts")
            }
            Self::DuplicateCrtc(crtc) => write!(formatter, "CRTC {crtc} has multiple owners"),
            Self::DuplicatePlane(plane) => {
                write!(formatter, "primary plane {plane} has multiple owners")
            }
        }
    }
}

impl Error for ScanoutIdentityError {}

fn validate_scanout_identities(
    identities: impl IntoIterator<Item = ScanoutIdentity>,
) -> Result<(), ScanoutIdentityError> {
    let mut outputs = BTreeSet::new();
    let mut connectors = BTreeSet::new();
    let mut crtcs = BTreeSet::new();
    let mut planes = BTreeSet::new();
    for identity in identities {
        if identity.output == 0 {
            return Err(ScanoutIdentityError::Zero("output"));
        }
        if identity.connector == 0 {
            return Err(ScanoutIdentityError::Zero("connector"));
        }
        if identity.crtc == 0 {
            return Err(ScanoutIdentityError::Zero("CRTC"));
        }
        if identity.plane == 0 {
            return Err(ScanoutIdentityError::Zero("plane"));
        }
        if !outputs.insert(identity.output) {
            return Err(ScanoutIdentityError::DuplicateOutput(identity.output));
        }
        if !connectors.insert(identity.connector) {
            return Err(ScanoutIdentityError::DuplicateConnector(identity.connector));
        }
        if !crtcs.insert(identity.crtc) {
            return Err(ScanoutIdentityError::DuplicateCrtc(identity.crtc));
        }
        if !planes.insert(identity.plane) {
            return Err(ScanoutIdentityError::DuplicatePlane(identity.plane));
        }
        if identity.output != u64::from(identity.connector) {
            return Err(ScanoutIdentityError::OutputConnectorMismatch {
                output: identity.output,
                connector: identity.connector,
            });
        }
    }
    Ok(())
}

struct AliasedPlanarBuffer {
    size: (u32, u32),
    format: DrmFourcc,
    modifier: Option<DrmModifier>,
    pitches: [u32; 4],
    handles: [Option<BufferHandle>; 4],
    offsets: [u32; 4],
}

pub fn cursor_framebuffer(
    drm: &DrmDeviceFd,
    size: (u32, u32),
    pitch: u32,
    handle: BufferHandle,
) -> std::io::Result<framebuffer::Handle> {
    let buffer = AliasedPlanarBuffer {
        size,
        format: Fourcc::Argb8888,
        modifier: None,
        handles: [Some(handle), None, None, None],
        pitches: [pitch, 0, 0, 0],
        offsets: [0; 4],
    };
    drm.add_planar_framebuffer(&buffer, FbCmd2Flags::empty())
}

impl PlanarBuffer for AliasedPlanarBuffer {
    fn size(&self) -> (u32, u32) {
        self.size
    }

    fn format(&self) -> DrmFourcc {
        self.format
    }

    fn modifier(&self) -> Option<DrmModifier> {
        self.modifier
    }

    fn pitches(&self) -> [u32; 4] {
        self.pitches
    }

    fn handles(&self) -> [Option<BufferHandle>; 4] {
        self.handles
    }

    fn offsets(&self) -> [u32; 4] {
        self.offsets
    }
}

impl RestoreState {
    /// Build teardown metadata for a display-manager session handoff.
    ///
    /// A long-running login session never restores the greeter framebuffer:
    /// it releases DRM master and lets the display manager perform its own
    /// modeset. Recording the scanouts still gives hotplug transactions stable
    /// output identities and original modes without depending on a racy
    /// foreign framebuffer.
    pub fn for_session_handoff(scanouts: &[Scanout]) -> Result<Self, Box<dyn Error>> {
        validate_scanout_identities(scanouts.iter().map(|scanout| ScanoutIdentity {
            output: scanout.output.id.0,
            connector: u32::from(scanout.output.connector),
            crtc: u32::from(scanout.output.crtc),
            plane: u32::from(scanout.surface.plane()),
        }))?;

        Ok(Self {
            outputs: scanouts
                .iter()
                .map(|scanout| SavedOutputState {
                    id: scanout.output.id,
                    name: scanout.output.name.clone(),
                    original_mode: scanout.original_mode,
                    framebuffer: None,
                    properties: Vec::new(),
                })
                .collect(),
        })
    }

    pub fn capture(drm: &DrmDevice, scanouts: &[Scanout]) -> Result<Self, Box<dyn Error>> {
        const CONNECTOR_PROPERTIES: &[&str] = &["CRTC_ID", "Colorspace"];
        const CRTC_PROPERTIES: &[&str] = &["ACTIVE", "VRR_ENABLED"];
        const PLANE_PROPERTIES: &[&str] = &[
            "CRTC_ID",
            "SRC_X",
            "SRC_Y",
            "SRC_W",
            "SRC_H",
            "CRTC_X",
            "CRTC_Y",
            "CRTC_W",
            "CRTC_H",
            "rotation",
            "alpha",
            "FB_DAMAGE_CLIPS",
        ];

        validate_scanout_identities(scanouts.iter().map(|scanout| ScanoutIdentity {
            output: scanout.output.id.0,
            connector: u32::from(scanout.output.connector),
            crtc: u32::from(scanout.output.crtc),
            plane: u32::from(scanout.surface.plane()),
        }))?;

        let mut outputs = Vec::with_capacity(scanouts.len());
        for scanout in scanouts {
            let Some(source_framebuffer) = primary_framebuffer(drm, scanout.surface.plane())?
            else {
                outputs.push(SavedOutputState {
                    id: scanout.output.id,
                    name: scanout.output.name.clone(),
                    original_mode: scanout.original_mode,
                    framebuffer: None,
                    properties: Vec::new(),
                });
                info!(
                    output = scanout.output.name,
                    crtc = ?scanout.output.crtc,
                    plane = ?scanout.surface.plane(),
                    "primary plane had no predecessor framebuffer"
                );
                continue;
            };
            let mut properties = Vec::new();
            capture_named_properties(
                drm,
                scanout.output.connector,
                CONNECTOR_PROPERTIES,
                &mut properties,
            )?;
            capture_owned_hdr_metadata(drm, scanout.output.connector, &mut properties)?;
            capture_named_properties(drm, scanout.output.crtc, CRTC_PROPERTIES, &mut properties)?;
            capture_owned_mode_blob(drm, scanout.output.crtc, &mut properties)?;
            let mut plane_properties = Vec::new();
            capture_named_properties(
                drm,
                scanout.surface.plane(),
                PLANE_PROPERTIES,
                &mut plane_properties,
            )?;
            let framebuffer = capture_owned_framebuffer(
                drm,
                scanout.surface.plane(),
                source_framebuffer,
                &mut plane_properties,
            )?;
            properties.extend_from_slice(&plane_properties);
            outputs.push(SavedOutputState {
                id: scanout.output.id,
                name: scanout.output.name.clone(),
                original_mode: scanout.original_mode,
                framebuffer: Some(framebuffer),
                properties,
            });
        }

        Ok(Self { outputs })
    }

    fn request(properties: &[SavedAtomicProperty]) -> AtomicModeReq {
        let mut request = AtomicModeReq::new();
        for saved in properties {
            request.add_raw_property(saved.object, saved.property, saved.value);
        }
        request
    }

    pub fn property_count(&self) -> usize {
        self.outputs.iter().fold(0_usize, |count, output| {
            count.saturating_add(output.properties.len())
        })
    }

    pub fn owned_framebuffer_count(&self) -> usize {
        self.outputs
            .iter()
            .filter(|output| output.framebuffer.is_some())
            .count()
    }

    pub fn original_mode(&self, id: OutputId) -> Option<Mode> {
        self.outputs
            .iter()
            .find(|output| output.id == id)
            .map(|output| output.original_mode)
    }

    pub fn was_active(&self, id: OutputId) -> bool {
        self.outputs
            .iter()
            .find(|output| output.id == id)
            .is_some_and(|output| output.framebuffer.is_some())
    }

    pub fn register_inactive_scanout(&mut self, scanout: &Scanout) {
        if self
            .outputs
            .iter()
            .any(|saved| saved.id == scanout.output.id)
        {
            return;
        }
        self.outputs.push(SavedOutputState {
            id: scanout.output.id,
            name: scanout.output.name.clone(),
            original_mode: scanout.original_mode,
            framebuffer: None,
            properties: Vec::new(),
        });
        info!(
            output = scanout.output.name,
            "registered originally-inactive hotplug output for teardown"
        );
    }

    pub fn test(&self, drm: &DrmDevice) -> Result<(), Box<dyn Error>> {
        for output in self
            .outputs
            .iter()
            .filter(|output| output.framebuffer.is_some())
        {
            drm.atomic_commit(
                AtomicCommitFlags::ALLOW_MODESET | AtomicCommitFlags::TEST_ONLY,
                Self::request(&output.properties),
            )
            .map_err(|error| format!("{} restore TEST_ONLY failed: {error}", output.name))?;
        }
        Ok(())
    }

    fn restore_planes(&self, scanouts: &[Scanout]) -> Result<(), Box<dyn Error>> {
        // Modes have already been restored while the Denial atlas was still
        // pinned. Finish the handoff using the same normalized PlaneState path
        // as the takeover rather than replaying driver-specific raw values.
        let mut failures = Vec::new();
        for output in self.outputs.iter().rev() {
            let Some(scanout) = scanouts
                .iter()
                .find(|scanout| scanout.output.id == output.id)
            else {
                info!(
                    output = output.name,
                    "original output is disconnected; skipping framebuffer restore"
                );
                continue;
            };
            let Some(framebuffer) = output.framebuffer else {
                if let Err(error) = scanout.surface.clear() {
                    failures.push(format!(
                        "{} originally-inactive output disable failed: {error}",
                        scanout.output.name
                    ));
                } else {
                    info!(
                        output = scanout.output.name,
                        "disabled originally-inactive hotplug output"
                    );
                }
                continue;
            };
            if let Err(error) = scanout
                .surface
                .commit([original_plane_state(scanout, framebuffer)], false)
            {
                failures.push(format!(
                    "{} restore plane commit failed: {error}",
                    scanout.output.name
                ));
            } else {
                info!(
                    output = scanout.output.name,
                    framebuffer = ?framebuffer,
                    "restored original scanout buffer"
                );
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join("; ").into())
        }
    }
}

fn capture_named_properties<H>(
    drm: &DrmDevice,
    object: H,
    names: &[&str],
    destination: &mut Vec<SavedAtomicProperty>,
) -> Result<(), Box<dyn Error>>
where
    H: ResourceHandle + Copy,
{
    for (handle, value) in drm.get_properties(object)? {
        let info = drm.get_property(handle)?;
        let Ok(name) = info.name().to_str() else {
            continue;
        };
        if names.contains(&name) {
            destination.push(SavedAtomicProperty {
                object: object.into(),
                property: handle,
                value,
            });
        }
    }
    Ok(())
}

fn capture_owned_mode_blob(
    drm: &DrmDevice,
    crtc: crtc::Handle,
    destination: &mut Vec<SavedAtomicProperty>,
) -> Result<(), Box<dyn Error>> {
    let mode = drm
        .get_crtc(crtc)?
        .mode()
        .ok_or_else(|| format!("{crtc:?} has no active mode to restore"))?;
    let mode_blob = drm.create_property_blob(&mode)?;
    let mode_blob_id = mode_blob.as_blob().ok_or("mode blob has the wrong type")?;
    destination.push(SavedAtomicProperty {
        object: crtc.into(),
        property: named_property(drm, crtc, "MODE_ID")?,
        value: mode_blob_id,
    });
    Ok(())
}

/// The predecessor's HDR metadata, copied into a blob this process owns so
/// the restore does not depend on the predecessor keeping its own alive.
fn capture_owned_hdr_metadata(
    drm: &DrmDevice,
    connector: connector::Handle,
    destination: &mut Vec<SavedAtomicProperty>,
) -> Result<(), Box<dyn Error>> {
    let Some(property) = optional_named_property(drm, connector, "HDR_OUTPUT_METADATA")? else {
        return Ok(());
    };
    let blob = drm
        .get_properties(connector)?
        .into_iter()
        .find_map(|(handle, value)| (handle == property).then_some(value))
        .unwrap_or(0);
    let value = if blob == 0 {
        0
    } else {
        let metadata =
            <[u8; HDR_OUTPUT_METADATA_BYTES]>::try_from(drm.get_property_blob(blob)?.as_slice())
                .map_err(|_| "the predecessor's HDR metadata has an unknown size")?;
        drm.create_property_blob(&metadata)?
            .as_blob()
            .ok_or("HDR metadata blob has the wrong type")?
    };
    destination.push(SavedAtomicProperty {
        object: connector.into(),
        property,
        value,
    });
    Ok(())
}

/// `struct hdr_output_metadata` in the DRM UAPI.
const HDR_OUTPUT_METADATA_BYTES: usize = 32;

/// Static metadata type 1 for a display showing PQ: its own primaries and
/// luminance, since Denial already fits the content to them.
fn hdr_output_metadata(hdr: denial_color::output_color::HdrOutput) -> [u8; HDR_OUTPUT_METADATA_BYTES] {
    const SMPTE_ST2084: u8 = 2;
    let display = hdr.display;
    let mut bytes = [0; HDR_OUTPUT_METADATA_BYTES];
    // metadata_type (u32) stays HDMI_STATIC_METADATA_TYPE1 = 0.
    bytes[4] = SMPTE_ST2084;
    let mut put = |at: usize, value: f64| {
        let value = value.round().clamp(0.0, f64::from(u16::MAX)) as u16;
        bytes[at..at + 2].copy_from_slice(&value.to_ne_bytes());
    };
    // Chromaticities in units of 0.00002: red, green, blue, then white.
    for (index, (x, y)) in display.primaries.into_iter().enumerate() {
        put(6 + index * 4, x * 50_000.0);
        put(8 + index * 4, y * 50_000.0);
    }
    put(22, display.max_luminance);
    put(24, display.min_luminance * 10_000.0);
    put(26, display.max_luminance);
    put(28, display.max_frame_average);
    bytes
}

/// Puts the connector's signal in BT.2100 PQ for `hdr`, or back in SDR. A
/// change of transfer function is a modeset on amdgpu, so it is committed on
/// its own, before the pools reach the planes.
fn apply_connector_hdr(
    drm: &DrmDeviceFd,
    connector: connector::Handle,
    hdr: Option<denial_color::output_color::HdrOutput>,
) -> Result<(), Box<dyn Error>> {
    let metadata_property = optional_named_property(drm, connector, "HDR_OUTPUT_METADATA")?;
    let colorspace_property = optional_named_property(drm, connector, "Colorspace")?;
    let (Some(metadata_property), Some(colorspace_property)) =
        (metadata_property, colorspace_property)
    else {
        return match hdr {
            Some(_) => Err("the connector has no HDR_OUTPUT_METADATA or Colorspace".into()),
            None => Ok(()),
        };
    };
    let colorspace_name = if hdr.is_some() {
        "BT2020_RGB"
    } else {
        "Default"
    };
    let colorspace = match drm.get_property(colorspace_property)?.value_type() {
        property::ValueType::Enum(values) => values
            .values()
            .1
            .iter()
            .find(|value| value.name().to_str() == Ok(colorspace_name))
            .map(|value| value.value()),
        _ => None,
    }
    .ok_or_else(|| format!("the connector has no {colorspace_name} colorspace"))?;
    let metadata = hdr.map(hdr_output_metadata);
    let (mut current_blob, mut current_colorspace) = (0, None);
    for (handle, value) in drm.get_properties(connector)? {
        if handle == metadata_property {
            current_blob = value;
        } else if handle == colorspace_property {
            current_colorspace = Some(value);
        }
    }
    let current_metadata = match current_blob {
        0 => None,
        blob => Some(drm.get_property_blob(blob)?),
    };
    if current_colorspace == Some(colorspace)
        && current_metadata.as_deref() == metadata.as_ref().map(<[u8; 32]>::as_slice)
    {
        return Ok(());
    }
    let blob = match &metadata {
        Some(metadata) => drm
            .create_property_blob(metadata)?
            .as_blob()
            .ok_or("HDR metadata blob has the wrong type")?,
        None => 0,
    };
    let mut request = AtomicModeReq::new();
    request.add_raw_property(connector.into(), metadata_property, blob);
    request.add_raw_property(connector.into(), colorspace_property, colorspace);
    let committed = drm.atomic_commit(AtomicCommitFlags::ALLOW_MODESET, request);
    // The committed connector state holds its own reference to the blob.
    if blob != 0 {
        let _ = drm.destroy_property_blob(blob);
    }
    committed?;
    info!(
        ?connector,
        signal = if hdr.is_some() { "BT.2100 PQ" } else { "SDR" },
        white = hdr.map(|hdr| hdr.white),
        primaries = hdr.map(|hdr| hdr.primaries.name()),
        "switched the display signal"
    );
    Ok(())
}

fn primary_framebuffer(
    drm: &DrmDevice,
    plane: plane::Handle,
) -> Result<Option<framebuffer::Handle>, Box<dyn Error>> {
    let fb_property = named_property(drm, plane, "FB_ID")?;
    let source_raw = drm
        .get_properties(plane)?
        .into_iter()
        .find_map(|(handle, value)| (handle == fb_property).then_some(value))
        .ok_or("primary plane has no FB_ID value")?;
    framebuffer_from_property_value(source_raw)
}

fn framebuffer_from_property_value(
    value: u64,
) -> Result<Option<framebuffer::Handle>, Box<dyn Error>> {
    Ok(from_u32::<framebuffer::Handle>(u32::try_from(value)?))
}

fn capture_owned_framebuffer(
    drm: &DrmDevice,
    plane: plane::Handle,
    source: framebuffer::Handle,
    destination: &mut Vec<SavedAtomicProperty>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    let fb_property = named_property(drm, plane, "FB_ID")?;
    let source_info = drm.get_planar_framebuffer(source)?;
    let alias_buffer = AliasedPlanarBuffer {
        size: source_info.size(),
        format: source_info.pixel_format(),
        modifier: source_info.modifier(),
        pitches: source_info.pitches(),
        handles: source_info.buffers(),
        offsets: source_info.offsets(),
    };
    if alias_buffer.handles.iter().all(Option::is_none) {
        return Err(format!(
            "kernel did not expose GEM handles for pre-existing framebuffer {source:?}"
        )
        .into());
    }

    let alias = drm.add_planar_framebuffer(&alias_buffer, source_info.flags())?;
    destination.push(SavedAtomicProperty {
        object: plane.into(),
        property: fb_property,
        value: u64::from(u32::from(alias)),
    });
    info!(source = ?source, alias = ?alias, "pinned pre-Denial framebuffer");
    Ok(alias)
}

pub fn named_property<H>(
    drm: &impl ControlDevice,
    object: H,
    expected_name: &str,
) -> Result<property::Handle, Box<dyn Error>>
where
    H: ResourceHandle + Copy,
{
    optional_named_property(drm, object, expected_name)?
        .ok_or_else(|| format!("missing atomic property {expected_name}").into())
}

fn optional_named_property<H>(
    drm: &impl ControlDevice,
    object: H,
    expected_name: &str,
) -> Result<Option<property::Handle>, Box<dyn Error>>
where
    H: ResourceHandle + Copy,
{
    for (handle, _) in drm.get_properties(object)? {
        let info = drm.get_property(handle)?;
        if info.name().to_str() == Ok(expected_name) {
            return Ok(Some(handle));
        }
    }
    Ok(None)
}

/// Release non-primary planes left latched by the previous DRM master.
///
/// A display manager can
/// leave a cursor or overlay plane bound when it releases DRM master, causing
/// the kernel to scan that stale image out above every Denial frame. Refusing
/// this best-effort cleanup must not prevent the session from starting.
pub fn release_inherited_planes(drm: &DrmDevice) {
    let inherited = match inherited_plane_request(drm) {
        Ok(Some(inherited)) => inherited,
        Ok(None) => return,
        Err(error) => {
            warn!("could not inspect planes inherited from the previous DRM master: {error}");
            return;
        }
    };

    if let Err(error) = drm.atomic_commit(
        AtomicCommitFlags::ALLOW_MODESET | AtomicCommitFlags::TEST_ONLY,
        inherited.request.clone(),
    ) {
        warn!(
            planes = ?inherited.planes,
            "inherited plane release rejected by TEST_ONLY: {error}"
        );
        return;
    }
    if let Err(error) = drm.atomic_commit(AtomicCommitFlags::ALLOW_MODESET, inherited.request) {
        warn!(
            planes = ?inherited.planes,
            "inherited plane release failed: {error}"
        );
        return;
    }
    info!(
        planes = ?inherited.planes,
        "released planes inherited from the previous DRM master"
    );
}

/// Turns off displays the configuration leaves off but a previous DRM master
/// left lit. Kept lit, a display shows that session's last picture, and
/// turning it on later fails: a hotplug never takes over an active CRTC that
/// Denial does not own (#243). A CRTC a lit output will use is left to that
/// output's own modeset.
pub fn release_unlit_outputs(
    drm: &DrmDevice,
    unlit: &[connector::Handle],
    lit: &[ConnectedOutput],
) {
    let released = match unlit_output_request(drm, unlit, lit) {
        Ok(Some(released)) => released,
        Ok(None) => return,
        Err(error) => {
            warn!("could not inspect displays left lit by the previous DRM master: {error}");
            return;
        }
    };
    if let Err(error) = drm.atomic_commit(
        AtomicCommitFlags::ALLOW_MODESET | AtomicCommitFlags::TEST_ONLY,
        released.request.clone(),
    ) {
        warn!(
            connectors = ?released.connectors,
            "turning off displays left lit was rejected by TEST_ONLY: {error}"
        );
        return;
    }
    if let Err(error) = drm.atomic_commit(AtomicCommitFlags::ALLOW_MODESET, released.request) {
        warn!(
            connectors = ?released.connectors,
            "could not turn off displays left lit: {error}"
        );
        return;
    }
    info!(
        connectors = ?released.connectors,
        crtcs = ?released.crtcs,
        "turned off displays the previous DRM master left lit"
    );
}

struct UnlitOutputRequest {
    request: AtomicModeReq,
    connectors: Vec<u32>,
    crtcs: Vec<u32>,
}

fn unlit_output_request(
    drm: &DrmDevice,
    unlit: &[connector::Handle],
    lit: &[ConnectedOutput],
) -> Result<Option<UnlitOutputRequest>, Box<dyn Error>> {
    let mut request = AtomicModeReq::new();
    let mut connectors = Vec::new();
    let mut crtcs = BTreeSet::new();
    for &connector in unlit {
        let Some(encoder) = drm.get_connector(connector, false)?.current_encoder() else {
            continue;
        };
        let Some(crtc) = drm.get_encoder(encoder)?.crtc() else {
            continue;
        };
        if lit.iter().any(|output| output.crtc == crtc) || drm.get_crtc(crtc)?.mode().is_none() {
            continue;
        }
        let Some(connector_crtc) = optional_named_property(drm, connector, "CRTC_ID")? else {
            continue;
        };
        let (Some(active), Some(mode)) = (
            optional_named_property(drm, crtc, "ACTIVE")?,
            optional_named_property(drm, crtc, "MODE_ID")?,
        ) else {
            continue;
        };
        request.add_raw_property(connector.into(), connector_crtc, 0);
        connectors.push(u32::from(connector));
        if !crtcs.insert(u32::from(crtc)) {
            continue;
        }
        request.add_raw_property(crtc.into(), active, 0);
        request.add_raw_property(crtc.into(), mode, 0);
        for plane in drm.plane_handles()? {
            if drm.get_plane(plane)?.crtc() != Some(crtc) {
                continue;
            }
            let (Some(framebuffer), Some(plane_crtc)) = (
                optional_named_property(drm, plane, "FB_ID")?,
                optional_named_property(drm, plane, "CRTC_ID")?,
            ) else {
                continue;
            };
            request.add_raw_property(plane.into(), framebuffer, 0);
            request.add_raw_property(plane.into(), plane_crtc, 0);
        }
    }
    Ok((!connectors.is_empty()).then(|| UnlitOutputRequest {
        request,
        connectors,
        crtcs: crtcs.into_iter().collect(),
    }))
}

struct InheritedPlaneRequest {
    request: AtomicModeReq,
    planes: Vec<u32>,
}

fn inherited_plane_request(
    drm: &DrmDevice,
) -> Result<Option<InheritedPlaneRequest>, Box<dyn Error>> {
    let mut request = AtomicModeReq::new();
    let mut planes = Vec::new();
    for plane in drm.plane_handles()? {
        let properties = drm.get_properties(plane)?.into_iter().collect::<Vec<_>>();

        // If a driver does not expose the standardized plane type, leave the
        // plane alone rather than risking Denial's future primary scanout.
        let Some(type_property) = optional_named_property(drm, plane, "type")? else {
            continue;
        };
        let Some(plane_type) = property_value(&properties, type_property) else {
            continue;
        };
        let Some(framebuffer_property) = optional_named_property(drm, plane, "FB_ID")? else {
            continue;
        };
        let framebuffer = property_value(&properties, framebuffer_property).unwrap_or(0);
        if !inherited_plane_needs_release(plane_type, framebuffer) {
            continue;
        }
        let Some(crtc_property) = optional_named_property(drm, plane, "CRTC_ID")? else {
            continue;
        };

        request.add_raw_property(plane.into(), framebuffer_property, 0);
        request.add_raw_property(plane.into(), crtc_property, 0);
        planes.push(u32::from(plane));
    }

    Ok((!planes.is_empty()).then_some(InheritedPlaneRequest { request, planes }))
}

fn property_value(
    properties: &[(property::Handle, property::RawValue)],
    wanted: property::Handle,
) -> Option<property::RawValue> {
    properties
        .iter()
        .find_map(|(handle, value)| (*handle == wanted).then_some(*value))
}

fn inherited_plane_needs_release(
    plane_type: property::RawValue,
    framebuffer: property::RawValue,
) -> bool {
    plane_type != PlaneType::Primary as property::RawValue && framebuffer != 0
}

fn original_plane_state(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
) -> PlaneState<'static> {
    let (width, height) = scanout.original_mode.size();
    PlaneState {
        handle: scanout.surface.plane(),
        config: Some(PlaneConfig {
            src: Rectangle::<f64, Buffer>::new(
                (0.0, 0.0).into(),
                (f64::from(width), f64::from(height)).into(),
            ),
            dst: Rectangle::<i32, Physical>::from_size(
                (i32::from(width), i32::from(height)).into(),
            ),
            transform: Transform::Normal,
            alpha: scanout.plane_properties.smithay_opaque_alpha,
            damage_clips: None,
            fb: framebuffer,
            fence: None,
        }),
    }
}

fn restore_original_modes_with_atlas(
    scanouts: &[Scanout],
    restore_state: &RestoreState,
    framebuffer: framebuffer::Handle,
) -> Result<(), Box<dyn Error>> {
    let mut failures = Vec::new();
    for scanout in scanouts.iter().rev() {
        if !restore_state.was_active(scanout.output.id) {
            continue;
        }
        if scanout.surface.current_mode() == scanout.original_mode {
            continue;
        }
        if let Err(error) = scanout.surface.use_mode(scanout.original_mode) {
            failures.push(format!(
                "{} original mode staging failed: {error}",
                scanout.output.name
            ));
            continue;
        }
        if let Err(error) = scanout.surface.commit(
            [plane_state_for_mode(
                scanout,
                framebuffer,
                scanout.original_mode,
            )],
            false,
        ) {
            failures.push(format!(
                "{} original mode commit failed: {error}",
                scanout.output.name
            ));
            continue;
        }
        let mode: OutputMode = scanout.original_mode.into();
        info!(
            output = scanout.output.name,
            refresh_millihz = mode.refresh,
            "restored original mode while retaining the Denial atlas"
        );
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; ").into())
    }
}

#[cfg(test)]
#[path = "kms_state/tests.rs"]
mod tests;

/// Guards a teardown that more than one path may start.
#[derive(Debug, Default)]
pub struct TeardownGate {
    started: bool,
}

impl TeardownGate {
    /// Returns true exactly once, for the caller responsible for teardown.
    pub fn begin(&mut self) -> bool {
        !std::mem::replace(&mut self.started, true)
    }
}
