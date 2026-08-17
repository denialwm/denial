//! Ownership and rollback state for DRM scanouts and atlas buffers.

use super::*;
use std::collections::BTreeSet;
use std::fmt;

#[cfg(feature = "flutter")]
use smithay::backend::egl::EGLContext;

const ATLAS_BYTES_PER_PIXEL: u64 = 4;
const MAX_ATLAS_DIMENSION: u32 = 16_384;
const MAX_ATLAS_POOL_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_ATLAS_BUFFERS: usize = 49;

/// Request local scanout constraints only when the render device also owns
/// KMS. A render-only GPU exports the atlas to another DRM device, so asking
/// its GBM allocator for local scanout can reject otherwise shareable LINEAR
/// buffers on output-less PRIME render sources.
pub(super) fn atlas_gbm_flags(cross_device: bool) -> GbmBufferFlags {
    let flags = GbmBufferFlags::RENDERING;
    if cross_device {
        flags
    } else {
        flags | GbmBufferFlags::SCANOUT
    }
}

#[derive(Clone, Debug)]
pub(super) struct ConnectedOutput {
    pub(super) id: OutputId,
    pub(super) name: String,
    pub(super) connector: connector::Handle,
    pub(super) crtc: crtc::Handle,
    pub(super) mode: Mode,
    pub(super) vrr_enabled: bool,
}

pub(super) struct Scanout {
    pub(super) output: ConnectedOutput,
    pub(super) surface: DrmSurface,
    pub(super) plane_properties: AtlasPlaneProperties,
    pub(super) source_rect: PixelRect,
    pub(super) original_mode: Mode,
    /// Whether this logical output currently owns an active KMS pipeline.
    /// DPMS-off outputs deliberately remain in the topology and scanout list.
    pub(super) powered: bool,
}

pub(super) struct PreviousScanoutState {
    pub(super) index: usize,
    pub(super) output: ConnectedOutput,
    pub(super) source_rect: PixelRect,
    pub(super) pending_mode: Mode,
    pub(super) pending_vrr: bool,
}

pub(super) enum ReconciledScanoutOrigin {
    Reused(Box<PreviousScanoutState>),
    Created,
}

/// Owns both sides of a staged scanout replacement. Reused `DrmSurface`s live
/// in `candidate`, while removed surfaces remain pinned in their original
/// slots until the new atlas has reached vblank. Consequently no old surface
/// is dropped merely because preparation or TEST_ONLY failed.
pub(super) struct ScanoutReconciliation<'a> {
    pub(super) destination: &'a mut Vec<Scanout>,
    pub(super) candidate: Vec<Scanout>,
    pub(super) retired: Vec<Option<Scanout>>,
    pub(super) origins: Vec<ReconciledScanoutOrigin>,
    pub(super) resolved: bool,
}

impl ScanoutReconciliation<'_> {
    pub(super) fn scanouts(&self) -> &[Scanout] {
        &self.candidate
    }

    pub(super) fn clear_retired(&self) -> Vec<String> {
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

    pub(super) fn commit(mut self) -> Vec<Option<Scanout>> {
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

    pub(super) fn rollback(
        mut self,
        old_framebuffer: framebuffer::Handle,
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
                if let Err(error) = scanout
                    .surface
                    .commit([plane_state(scanout, old_framebuffer)], false)
                {
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
pub(super) struct AtlasPlaneProperties {
    pub(super) framebuffer: property::Handle,
    pub(super) source_x: property::Handle,
    pub(super) source_y: property::Handle,
    pub(super) source_width: property::Handle,
    pub(super) source_height: property::Handle,
    pub(super) in_fence_fd: Option<property::Handle>,
    pub(super) smithay_opaque_alpha: f32,
}

impl AtlasPlaneProperties {
    pub(super) fn load(drm: &DrmDevice, plane: plane::Handle) -> Result<Self, Box<dyn Error>> {
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
            in_fence_fd: optional_named_property(drm, plane, "IN_FENCE_FD")?,
            smithay_opaque_alpha,
        })
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

pub(super) struct KmsContext {
    pub(super) drm: DrmDevice,
    pub(super) scanouts: Vec<Scanout>,
    teardown: TeardownGate,
}

pub(super) struct RestoreAttempt {
    pub(super) restored: bool,
    pub(super) failures: Vec<String>,
}

enum AtlasFramebuffer {
    Gbm(GbmFramebuffer),
    Prime(PrimeFramebuffer),
}

impl AtlasFramebuffer {
    fn handle(&self) -> framebuffer::Handle {
        match self {
            Self::Gbm(framebuffer) => *framebuffer.as_ref(),
            Self::Prime(framebuffer) => framebuffer.handle,
        }
    }
}

/// A KMS framebuffer whose GEM handles were imported directly from dma-buf
/// file descriptors. Display-only DRM nodes do not necessarily have a GBM
/// backend capable of re-importing every modifier their planes can scan out;
/// PRIME plus ADDFB2 is the kernel ABI for that split-device case.
struct PrimeFramebuffer {
    handle: framebuffer::Handle,
    drm: DrmDeviceFd,
    imported_handles: Vec<BufferHandle>,
}

impl Drop for PrimeFramebuffer {
    fn drop(&mut self) {
        if let Err(error) = self.drm.destroy_framebuffer(self.handle) {
            warn!(framebuffer = ?self.handle, %error, "failed to destroy PRIME scanout framebuffer");
        }
        for handle in self.imported_handles.drain(..) {
            if let Err(error) = self.drm.close_buffer(handle) {
                warn!(buffer = ?handle, %error, "failed to close imported PRIME scanout handle");
            }
        }
    }
}

pub(super) struct AtlasAllocator {
    allocator: GbmAllocator<DrmDeviceFd>,
    drm_fd: DrmDeviceFd,
    cross_device: bool,
}

impl AtlasAllocator {
    pub(super) fn gbm(
        allocator: GbmAllocator<DrmDeviceFd>,
        drm_fd: DrmDeviceFd,
        cross_device: bool,
    ) -> Self {
        Self {
            allocator,
            drm_fd,
            cross_device,
        }
    }

    fn allocate(
        &mut self,
        size: PixelSize,
        modifiers: &[Modifier],
        linear_render_target: bool,
    ) -> Result<AtlasBuffer, Box<dyn Error>> {
        let mut buffer = AtlasBuffer::allocate_gbm(
            &mut self.allocator,
            &self.drm_fd,
            self.cross_device,
            size,
            modifiers,
        )?;
        if linear_render_target {
            buffer.render_target = Some(LinearRenderBuffer::allocate(&mut self.allocator, size)?);
        }
        Ok(buffer)
    }
}

struct LinearRenderBuffer {
    dmabuf: Dmabuf,
    _buffer: GbmBuffer,
}

impl LinearRenderBuffer {
    fn allocate(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        size: PixelSize,
    ) -> Result<Self, Box<dyn Error>> {
        let buffer = allocator.create_buffer(
            size.width,
            size.height,
            Fourcc::Xrgb8888,
            &[Modifier::Linear],
        )?;
        let format = smithay::backend::allocator::Buffer::format(&buffer);
        if format.code != Fourcc::Xrgb8888 || format.modifier != Modifier::Linear {
            return Err(
                format!("offscreen Flutter render target is not linear XR24: {format:?}").into(),
            );
        }
        let dmabuf = buffer.export()?;
        Ok(Self {
            dmabuf,
            _buffer: buffer,
        })
    }
}

pub(super) struct AtlasBuffer {
    // The framebuffer must be destroyed before its backing allocation.
    framebuffer: AtlasFramebuffer,
    pub(super) dmabuf: Dmabuf,
    format: Format,
    render_target: Option<LinearRenderBuffer>,
    _buffer: GbmBuffer,
}

impl AtlasBuffer {
    fn allocate_gbm(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        drm_fd: &DrmDeviceFd,
        cross_device: bool,
        size: PixelSize,
        modifiers: &[Modifier],
    ) -> Result<Self, Box<dyn Error>> {
        let buffer =
            allocator.create_buffer(size.width, size.height, Fourcc::Xrgb8888, modifiers)?;
        let format = smithay::backend::allocator::Buffer::format(&buffer);
        let dmabuf = buffer.export()?;
        let framebuffer = if cross_device {
            AtlasFramebuffer::Prime(framebuffer_from_prime_dmabuf(drm_fd, &dmabuf)?)
        } else {
            AtlasFramebuffer::Gbm(framebuffer_from_bo(drm_fd, &buffer, true)?)
        };
        Ok(Self {
            framebuffer,
            dmabuf,
            format,
            render_target: None,
            _buffer: buffer,
        })
    }

    pub(super) fn framebuffer(&self) -> framebuffer::Handle {
        self.framebuffer.handle()
    }

    pub(super) fn format(&self) -> Format {
        self.format
    }

    #[cfg(feature = "flutter")]
    pub(super) fn flutter_target_dmabufs(&self) -> (&Dmabuf, Option<&Dmabuf>) {
        (
            &self.dmabuf,
            self.render_target.as_ref().map(|target| &target.dmabuf),
        )
    }
}

fn framebuffer_from_prime_dmabuf(
    drm: &DrmDeviceFd,
    dmabuf: &Dmabuf,
) -> Result<PrimeFramebuffer, Box<dyn Error>> {
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

    Ok(PrimeFramebuffer {
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

pub(super) struct AtlasSwapchain {
    pub(super) size: PixelSize,
    pub(super) buffers: Vec<AtlasBuffer>,
    pub(super) current: usize,
}

pub(super) struct ScreenshotBuffer {
    pub(super) dmabuf: Dmabuf,
    _buffer: GbmBuffer,
}

impl ScreenshotBuffer {
    pub(super) fn allocate(
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

pub(super) struct LayoutTransition {
    pub(super) at_frame: u64,
    pub(super) positions: BTreeMap<String, LogicalPoint>,
}

#[cfg(feature = "flutter")]
pub(super) struct FlutterLauncher {
    factory: Option<flutter_runtime::FlutterRuntimeFactory>,
    renderer_backend: denial_flutter_engine::RendererBackend,
    offscreen_blit: bool,
    active_mode: ui_development::UiRuntimeMode,
    resident_jit_engine_fingerprint: Option<[u8; 32]>,
    ui_development: ui_development::UiDevelopmentController,
    events: Sender<flutter_runtime::RuntimeEvent>,
    authentication: Arc<authentication::AuthenticationController>,
    clipboard: clipboard::ClipboardManager,
    wayland_display: Option<OsString>,
    x11_display: Option<OsString>,
    output_control_socket: Option<OsString>,
    work_area: options::WorkAreaOptions,
    pub(super) generation: u64,
}

#[cfg(feature = "flutter")]
pub(super) struct FlutterLaunchConfiguration<'a> {
    pub(super) bundle: &'a Path,
    pub(super) renderer_backend: denial_flutter_engine::RendererBackend,
    pub(super) offscreen_blit: bool,
    pub(super) debug_bundle: Option<PathBuf>,
    pub(super) ui_workspace: Option<PathBuf>,
}

#[cfg(feature = "flutter")]
impl FlutterLauncher {
    pub(super) fn new(
        configuration: FlutterLaunchConfiguration<'_>,
        events: Sender<flutter_runtime::RuntimeEvent>,
        wayland_display: Option<OsString>,
        x11_display: Option<OsString>,
        output_control_socket: Option<OsString>,
        work_area: options::WorkAreaOptions,
        start_locked: bool,
    ) -> Result<Self, Box<dyn Error>> {
        let ui_development = ui_development::UiDevelopmentController::new(
            configuration.bundle,
            configuration.debug_bundle,
            configuration.ui_workspace,
        );
        Ok(Self {
            factory: Some(flutter_runtime::FlutterRuntimeFactory::new(
                configuration.bundle,
                denial_flutter_engine::DartRuntimeMode::Aot,
                configuration.renderer_backend,
            )?),
            renderer_backend: configuration.renderer_backend,
            offscreen_blit: configuration.offscreen_blit,
            active_mode: ui_development::UiRuntimeMode::OfficialOptimized,
            resident_jit_engine_fingerprint: None,
            ui_development,
            events,
            authentication: Arc::new(authentication::AuthenticationController::new(start_locked)?),
            clipboard: clipboard::ClipboardManager::default(),
            wayland_display,
            x11_display,
            output_control_socket,
            work_area,
            generation: 0,
        })
    }

    pub(super) fn uses_offscreen_blit(&self) -> bool {
        self.offscreen_blit
    }

    pub(super) fn start(
        &mut self,
        renderer: &GlesRenderer,
        swapchain: &AtlasSwapchain,
        scanouts: &[Scanout],
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
    ) -> Result<flutter_runtime::FlutterRuntime, Box<dyn Error>> {
        self.generation = self.generation.wrapping_add(1).max(1);
        if let Err(error) = self.activate_requested_factory() {
            let failed_mode = self.ui_development.desired_mode();
            if failed_mode == ui_development::UiRuntimeMode::OfficialOptimized {
                return Err(error);
            }
            self.ui_development
                .runtime_failed(failed_mode, error.as_ref());
            warn!(
                %error,
                ?failed_mode,
                "could not prepare custom Flutter runtime; restoring the packaged shell"
            );
            self.replace_factory(ui_development::UiRuntimeMode::OfficialOptimized)?;
        }
        let refresh_millihz = scanouts
            .iter()
            .map(|scanout| OutputMode::from(scanout.output.mode).refresh)
            .max()
            .ok_or("Flutter runtime has no output refresh")?;
        let runtime = self.start_with_current_factory(
            renderer.egl_context(),
            swapchain
                .buffers
                .iter()
                .map(AtlasBuffer::flutter_target_dmabufs),
            swapchain.current,
            swapchain.size,
            snapshot,
            atlas,
            scanouts,
            u32::try_from(refresh_millihz)?,
        );
        let mut runtime = match runtime {
            Ok(runtime) => runtime,
            Err(error) if self.active_mode != ui_development::UiRuntimeMode::OfficialOptimized => {
                let failed_mode = self.active_mode;
                self.ui_development
                    .runtime_failed(failed_mode, error.as_ref());
                warn!(
                    %error,
                    ?failed_mode,
                    "custom Flutter runtime failed; restoring the packaged shell"
                );
                self.replace_factory(ui_development::UiRuntimeMode::OfficialOptimized)?;
                self.start_with_current_factory(
                    renderer.egl_context(),
                    swapchain
                        .buffers
                        .iter()
                        .map(AtlasBuffer::flutter_target_dmabufs),
                    swapchain.current,
                    swapchain.size,
                    snapshot,
                    atlas,
                    scanouts,
                    u32::try_from(refresh_millihz)?,
                )?
            }
            Err(error) => return Err(error),
        };
        self.ui_development
            .runtime_started(self.active_mode, self.generation);
        self.publish_ui_development_state(&mut runtime)?;
        Ok(runtime)
    }

    #[allow(clippy::too_many_arguments)]
    fn start_with_current_factory<'a>(
        &self,
        shared_context: &EGLContext,
        dmabufs: impl IntoIterator<Item = (&'a Dmabuf, Option<&'a Dmabuf>)>,
        initial_scanout: usize,
        size: PixelSize,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        scanouts: &[Scanout],
        refresh_millihz: u32,
    ) -> Result<flutter_runtime::FlutterRuntime, Box<dyn Error>> {
        if let Some(scanout) = scanouts
            .iter()
            .find(|scanout| scanout.plane_properties.in_fence_fd.is_none())
        {
            return Err(format!(
                "{} primary KMS plane does not advertise IN_FENCE_FD; Denial requires explicit scanout fencing",
                scanout.output.name
            )
            .into());
        }
        flutter_runtime::FlutterRuntime::start(
            shared_context,
            dmabufs,
            initial_scanout,
            size,
            snapshot,
            atlas,
            refresh_millihz,
            self.offscreen_blit,
            self.factory
                .as_ref()
                .ok_or("Flutter launcher has no active runtime factory")?,
            self.events.clone(),
            Arc::clone(&self.authentication),
            self.clipboard.clone(),
            self.work_area.clone(),
            self.generation,
            self.wayland_display.clone(),
            self.x11_display.clone(),
            self.output_control_socket.clone(),
        )
    }

    fn activate_requested_factory(&mut self) -> Result<(), Box<dyn Error>> {
        let requested = self.ui_development.desired_mode();
        if requested == self.active_mode && self.factory.is_some() {
            if requested == ui_development::UiRuntimeMode::LiveDevelopment {
                let bundle = self
                    .ui_development
                    .bundle_for(requested)
                    .ok_or("live development has no configured Flutter bundle")?;
                let prepared = flutter_runtime::bundle_engine_fingerprint(bundle)?;
                ensure_resident_jit_engine_matches(
                    self.resident_jit_engine_fingerprint.as_ref(),
                    &prepared,
                )?;
            }
            return Ok(());
        }
        self.replace_factory(requested)
    }

    fn replace_factory(
        &mut self,
        requested: ui_development::UiRuntimeMode,
    ) -> Result<(), Box<dyn Error>> {
        let bundle = self
            .ui_development
            .bundle_for(requested)
            .ok_or_else(|| format!("{requested:?} has no configured Flutter bundle"))?
            .to_owned();
        let runtime = match requested {
            ui_development::UiRuntimeMode::OfficialOptimized => {
                denial_flutter_engine::DartRuntimeMode::Aot
            }
            ui_development::UiRuntimeMode::CustomOptimized => {
                denial_flutter_engine::DartRuntimeMode::AotProfile
            }
            ui_development::UiRuntimeMode::LiveDevelopment => {
                denial_flutter_engine::DartRuntimeMode::Jit
            }
            ui_development::UiRuntimeMode::Unavailable => {
                return Err("cannot launch an unavailable Flutter runtime".into());
            }
        };
        let jit_engine_fingerprint = (requested == ui_development::UiRuntimeMode::LiveDevelopment)
            .then(|| flutter_runtime::bundle_engine_fingerprint(&bundle))
            .transpose()?;
        if let Some(prepared) = jit_engine_fingerprint.as_ref() {
            ensure_resident_jit_engine_matches(
                self.resident_jit_engine_fingerprint.as_ref(),
                prepared,
            )?;
        }

        // AOT and JIT Flutter libraries each own process-global Dart state.
        // The old runtime is shut down before this method is reached; release
        // its library before loading the other runtime mode.
        self.factory = None;
        self.factory = Some(flutter_runtime::FlutterRuntimeFactory::new(
            &bundle,
            runtime,
            self.renderer_backend,
        )?);
        if let Some(fingerprint) = jit_engine_fingerprint {
            self.resident_jit_engine_fingerprint = Some(fingerprint);
        }
        self.active_mode = requested;
        Ok(())
    }

    pub(super) fn synchronize_ui_development(
        &mut self,
        runtime: &mut flutter_runtime::FlutterRuntime,
    ) -> Result<bool, Box<dyn Error>> {
        let vm_service_uri = runtime.take_vm_service_uri();
        let vm_service_changed = vm_service_uri.is_some();
        let commands = runtime.drain_ui_development_commands().collect::<Vec<_>>();
        if let Some(uri) = vm_service_uri {
            self.ui_development.set_vm_service_uri(uri);
        }
        if commands.is_empty() && !vm_service_changed {
            return Ok(false);
        }
        let mut reload_requested = false;
        for command in commands {
            if let ui_development::UiDevelopmentEffect::Reload(requested_mode) =
                self.ui_development.handle_command(command)
            {
                debug_assert_eq!(self.ui_development.desired_mode(), requested_mode);
                reload_requested = true;
            }
        }
        self.publish_ui_development_state(runtime)?;
        Ok(reload_requested)
    }

    pub(super) fn handle_external_ui_development(
        &mut self,
        runtime: &mut flutter_runtime::FlutterRuntime,
        command: ui_development::UiDevelopmentCommand,
    ) -> (bool, ui_development::UiDevelopmentState) {
        let reload_requested = matches!(
            self.ui_development.handle_command(command),
            ui_development::UiDevelopmentEffect::Reload(_)
        );
        // denialctl is the recovery path when Flutter itself is unavailable
        // or unhealthy. Updating the shell is useful, but it must never be a
        // prerequisite for accepting an external restore command.
        if let Err(error) = self.publish_ui_development_state(runtime) {
            warn!(%error, "could not publish denialctl UI state to Flutter");
        }
        (reload_requested, self.ui_development.state_snapshot())
    }

    fn publish_ui_development_state(
        &self,
        runtime: &mut flutter_runtime::FlutterRuntime,
    ) -> Result<(), Box<dyn Error>> {
        let packet = self.ui_development.state_packet()?;
        runtime.publish_ui_development_state(&packet)
    }

    pub(super) fn set_work_area(&mut self, work_area: options::WorkAreaOptions) {
        self.work_area = work_area;
    }
}

#[cfg(feature = "flutter")]
fn ensure_resident_jit_engine_matches(
    resident: Option<&[u8; 32]>,
    prepared: &[u8; 32],
) -> Result<(), Box<dyn Error>> {
    if resident.is_some_and(|resident| resident != prepared) {
        return Err(
            "The prepared JIT Flutter engine changed after this Denial session loaded its native development runtime. Restart the Denial session before enabling live UI development."
                .into(),
        );
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn flutter_pool_length(output_count: usize) -> Result<usize, Box<dyn Error>> {
    if output_count == 0 {
        return Err("Flutter atlas pool needs at least one output".into());
    }

    // Independently clocked outputs may each retain a scanning generation, an
    // atomic submission awaiting its page-flip event, and a newer ready
    // generation awaiting fence completion or submission. Flutter still needs
    // one unowned render target. At high refresh rates the ready generation can
    // legitimately overlap the following render; reserving only two output
    // generations turns that overlap into an avoidable skipped Flutter frame.
    let length = output_count
        .checked_mul(3)
        .and_then(|count| count.checked_add(1))
        .ok_or("Flutter atlas pool length overflow")?;
    if length > MAX_ATLAS_BUFFERS {
        return Err(format!(
            "Flutter atlas pool needs {length} buffers, above the supported {MAX_ATLAS_BUFFERS}"
        )
        .into());
    }
    Ok(length)
}

fn common_xrgb8888_modifiers<'a>(
    format_sets: impl IntoIterator<Item = &'a FormatSet>,
) -> Vec<Modifier> {
    let mut format_sets = format_sets.into_iter();
    let Some(first) = format_sets.next() else {
        return Vec::new();
    };
    let remaining = format_sets.collect::<Vec<_>>();
    first
        .iter()
        .filter(|format| format.code == Fourcc::Xrgb8888 && format.modifier != Modifier::Invalid)
        .filter(|format| remaining.iter().all(|formats| formats.contains(format)))
        .map(|format| format.modifier)
        .collect()
}

/// Return XR24 modifiers that every primary plane can scan out and EGL can
/// render into. Plane order is retained: DRM exposes the driver's preferred
/// tiled/compressed layouts first and LINEAR last on hardware that supports
/// both. If EGL only advertises the legacy implicit modifier, restrict the
/// result to LINEAR rather than guessing that a vendor modifier is renderable.
pub(super) fn shared_atlas_modifiers(
    scanouts: &[Scanout],
    render_formats: &FormatSet,
) -> Result<Vec<Modifier>, Box<dyn Error>> {
    if scanouts.is_empty() {
        return Err("shared atlas modifier selection needs at least one primary plane".into());
    }

    let mut modifiers = common_xrgb8888_modifiers(
        scanouts
            .iter()
            .map(|scanout| &scanout.surface.plane_info().formats),
    );
    let renderer_has_explicit_modifiers = render_formats
        .iter()
        .any(|format| format.code == Fourcc::Xrgb8888 && format.modifier != Modifier::Invalid);
    if renderer_has_explicit_modifiers {
        modifiers.retain(|modifier| {
            render_formats.contains(&Format {
                code: Fourcc::Xrgb8888,
                modifier: *modifier,
            })
        });
    } else {
        modifiers.retain(|modifier| *modifier == Modifier::Linear);
    }

    if modifiers.is_empty() {
        let outputs = scanouts
            .iter()
            .map(|scanout| scanout.output.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(format!(
            "no XR24 modifier is common to EGL rendering and the primary planes for {outputs}"
        )
        .into());
    }
    Ok(modifiers)
}

impl AtlasSwapchain {
    pub(super) fn allocate(
        allocator: &mut AtlasAllocator,
        size: PixelSize,
        modifiers: &[Modifier],
    ) -> Result<Self, Box<dyn Error>> {
        Self::allocate_pool(allocator, size, 2, modifiers, false)
    }

    pub(super) fn allocate_pool(
        allocator: &mut AtlasAllocator,
        size: PixelSize,
        length: usize,
        modifiers: &[Modifier],
        linear_render_targets: bool,
    ) -> Result<Self, Box<dyn Error>> {
        if length < 2 {
            return Err("an atlas swapchain needs at least two buffers".into());
        }
        validate_atlas_allocation(size, length)?;
        let optimized = modifiers
            .iter()
            .copied()
            .filter(|modifier| *modifier != Modifier::Linear && *modifier != Modifier::Invalid)
            .collect::<Vec<_>>();
        let linear_supported = modifiers.contains(&Modifier::Linear);
        if optimized.is_empty() && !linear_supported {
            return Err("atlas allocation received no usable DRM modifier".into());
        }

        let allocate = |allocator: &mut AtlasAllocator, modifiers: &[Modifier]| {
            (0..length)
                .map(|_| allocator.allocate(size, modifiers, linear_render_targets))
                .collect::<Result<Vec<_>, _>>()
        };
        let buffers = if optimized.is_empty() {
            allocate(allocator, &[Modifier::Linear])?
        } else {
            match allocate(allocator, &optimized) {
                Ok(buffers) => buffers,
                Err(optimized_error) if linear_supported => {
                    warn!(
                        %optimized_error,
                        "could not allocate a tiled/compressed atlas; falling back to LINEAR"
                    );
                    allocate(allocator, &[Modifier::Linear]).map_err(|linear_error| {
                        format!(
                            "optimized atlas allocation failed ({optimized_error}); LINEAR fallback failed ({linear_error})"
                        )
                    })?
                }
                Err(error) => {
                    return Err(format!(
                        "could not allocate the shared atlas with any common optimized modifier: {error}"
                    )
                    .into());
                }
            }
        };
        Ok(Self {
            size,
            buffers,
            current: 0,
        })
    }

    pub(super) fn current_framebuffer(&self) -> framebuffer::Handle {
        self.buffers[self.current].framebuffer()
    }

    pub(super) fn next_index(&self) -> usize {
        (self.current + 1) % self.buffers.len()
    }

    pub(super) fn present(&mut self, index: usize) {
        debug_assert!(index < self.buffers.len());
        self.current = index;
    }
}

fn validate_atlas_allocation(size: PixelSize, length: usize) -> Result<(), Box<dyn Error>> {
    if !(2..=MAX_ATLAS_BUFFERS).contains(&length) {
        return Err(format!(
            "atlas pool length {length} is outside the supported 2..={MAX_ATLAS_BUFFERS} range"
        )
        .into());
    }
    if size.width == 0 || size.height == 0 {
        return Err("atlas buffers need a non-empty extent".into());
    }
    if size.width > MAX_ATLAS_DIMENSION || size.height > MAX_ATLAS_DIMENSION {
        return Err(format!(
            "atlas {}x{} exceeds the supported {}-pixel texture dimension",
            size.width, size.height, MAX_ATLAS_DIMENSION
        )
        .into());
    }
    let pool_bytes = u64::from(size.width)
        .checked_mul(u64::from(size.height))
        .and_then(|pixels| pixels.checked_mul(ATLAS_BYTES_PER_PIXEL))
        .and_then(|bytes| bytes.checked_mul(u64::try_from(length).ok()?))
        .ok_or("atlas pool byte count overflow")?;
    if pool_bytes > MAX_ATLAS_POOL_BYTES {
        return Err(format!(
            "atlas pool needs {pool_bytes} bytes, above the {}-byte safety limit",
            MAX_ATLAS_POOL_BYTES
        )
        .into());
    }
    Ok(())
}

impl KmsContext {
    pub(super) fn new(drm: DrmDevice) -> Self {
        Self {
            drm,
            scanouts: Vec::new(),
            teardown: TeardownGate::default(),
        }
    }

    pub(super) fn pause(&mut self) {
        if self.drm.is_active() {
            self.drm.pause();
        }
    }

    pub(super) fn restore_once(
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
pub(super) struct RestoreState {
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
    pub(super) fn for_session_handoff(scanouts: &[Scanout]) -> Result<Self, Box<dyn Error>> {
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

    pub(super) fn capture(drm: &DrmDevice, scanouts: &[Scanout]) -> Result<Self, Box<dyn Error>> {
        const CONNECTOR_PROPERTIES: &[&str] = &["CRTC_ID"];
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
            let mut properties = Vec::new();
            capture_named_properties(
                drm,
                scanout.output.connector,
                CONNECTOR_PROPERTIES,
                &mut properties,
            )?;
            capture_named_properties(drm, scanout.output.crtc, CRTC_PROPERTIES, &mut properties)?;
            capture_owned_mode_blob(drm, scanout.output.crtc, &mut properties)?;
            let mut plane_properties = Vec::new();
            capture_named_properties(
                drm,
                scanout.surface.plane(),
                PLANE_PROPERTIES,
                &mut plane_properties,
            )?;
            let framebuffer =
                capture_owned_framebuffer(drm, scanout.surface.plane(), &mut plane_properties)?;
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

    pub(super) fn property_count(&self) -> usize {
        self.outputs.iter().fold(0_usize, |count, output| {
            count.saturating_add(output.properties.len())
        })
    }

    pub(super) fn owned_framebuffer_count(&self) -> usize {
        self.outputs
            .iter()
            .filter(|output| output.framebuffer.is_some())
            .count()
    }

    pub(super) fn original_mode(&self, id: OutputId) -> Option<Mode> {
        self.outputs
            .iter()
            .find(|output| output.id == id)
            .map(|output| output.original_mode)
    }

    pub(super) fn was_active(&self, id: OutputId) -> bool {
        self.outputs
            .iter()
            .find(|output| output.id == id)
            .is_some_and(|output| output.framebuffer.is_some())
    }

    pub(super) fn register_inactive_scanout(&mut self, scanout: &Scanout) {
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

    pub(super) fn test(&self, drm: &DrmDevice) -> Result<(), Box<dyn Error>> {
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

fn capture_owned_framebuffer(
    drm: &DrmDevice,
    plane: plane::Handle,
    destination: &mut Vec<SavedAtomicProperty>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    let fb_property = named_property(drm, plane, "FB_ID")?;
    let source_raw = drm
        .get_properties(plane)?
        .into_iter()
        .find_map(|(handle, value)| (handle == fb_property).then_some(value))
        .ok_or("primary plane has no FB_ID value")?;
    let source = from_u32::<framebuffer::Handle>(u32::try_from(source_raw)?)
        .ok_or("primary plane is not scanning out a framebuffer")?;
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

fn named_property<H>(
    drm: &DrmDevice,
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
    drm: &DrmDevice,
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
/// Denial composites its pointer into the Flutter scene and never programs a
/// hardware cursor plane. A display manager can nevertheless
/// leave a cursor or overlay plane bound when it releases DRM master, causing
/// the kernel to scan that stale image out above every Denial frame. Refusing
/// this best-effort cleanup must not prevent the session from starting.
pub(super) fn release_inherited_planes(drm: &DrmDevice) {
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
mod tests {
    use super::{
        Format, FormatSet, Fourcc, GbmBufferFlags, Modifier, PixelSize, ScanoutIdentity,
        ScanoutIdentityError, atlas_gbm_flags, common_xrgb8888_modifiers,
        inherited_plane_needs_release, smithay_opaque_alpha_for_maximum, validate_atlas_allocation,
        validate_scanout_identities,
    };
    #[cfg(feature = "flutter")]
    use super::{ensure_resident_jit_engine_matches, flutter_pool_length};

    #[cfg(feature = "flutter")]
    #[test]
    fn flutter_atlas_reserves_three_output_generations_plus_a_render_target() {
        assert!(flutter_pool_length(0).is_err());
        assert_eq!(flutter_pool_length(1).expect("one output"), 4);
        assert_eq!(flutter_pool_length(2).expect("two outputs"), 7);
        assert_eq!(flutter_pool_length(16).expect("sixteen outputs"), 49);
        assert!(flutter_pool_length(17).is_err());
        assert!(flutter_pool_length(usize::MAX).is_err());
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn a_changed_resident_jit_engine_requires_a_session_restart() {
        let first = [0x11; 32];
        let same = [0x11; 32];
        let changed = [0x22; 32];

        assert!(ensure_resident_jit_engine_matches(None, &first).is_ok());
        assert!(ensure_resident_jit_engine_matches(Some(&first), &same).is_ok());
        let error = ensure_resident_jit_engine_matches(Some(&first), &changed)
            .expect_err("changed native JIT engine must be rejected");
        assert!(error.to_string().contains("Restart the Denial session"));
    }

    #[test]
    fn atlas_allocation_rejects_pathological_dimensions_before_gbm() {
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 0).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 1).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 5).is_ok());
        assert!(
            validate_atlas_allocation(PixelSize::new(1, 1), super::MAX_ATLAS_BUFFERS + 1).is_err()
        );
        assert!(validate_atlas_allocation(PixelSize::new(0, 1080), 3).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(16_385, 1080), 3).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(15_360, 4_320), 3).is_ok());
        assert!(validate_atlas_allocation(PixelSize::new(16_384, 8_192), 3).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), usize::MAX).is_err());
    }

    #[test]
    fn cross_device_atlas_does_not_require_local_scanout() {
        let local = atlas_gbm_flags(false);
        assert!(local.contains(GbmBufferFlags::RENDERING));
        assert!(local.contains(GbmBufferFlags::SCANOUT));

        let offloaded = atlas_gbm_flags(true);
        assert!(offloaded.contains(GbmBufferFlags::RENDERING));
        assert!(!offloaded.contains(GbmBufferFlags::SCANOUT));
    }

    #[test]
    fn atlas_modifier_intersection_preserves_driver_preference_over_linear() {
        let preferred = Modifier::from(0x0200_0000_0082_0405_u64);
        let unavailable = Modifier::from(0x0200_0000_0042_0405_u64);
        let first = [
            Format {
                code: Fourcc::Xrgb8888,
                modifier: preferred,
            },
            Format {
                code: Fourcc::Xrgb8888,
                modifier: unavailable,
            },
            Format {
                code: Fourcc::Xrgb8888,
                modifier: Modifier::Linear,
            },
            Format {
                code: Fourcc::Xrgb8888,
                modifier: Modifier::Invalid,
            },
        ]
        .into_iter()
        .collect::<FormatSet>();
        let second = [
            Format {
                code: Fourcc::Xrgb8888,
                modifier: Modifier::Linear,
            },
            Format {
                code: Fourcc::Xrgb8888,
                modifier: preferred,
            },
        ]
        .into_iter()
        .collect::<FormatSet>();

        assert_eq!(
            common_xrgb8888_modifiers([&first, &second]),
            vec![preferred, Modifier::Linear]
        );
    }

    #[test]
    fn plane_alpha_uses_an_advertised_narrow_range_only_when_needed() {
        let standard = smithay_opaque_alpha_for_maximum(u16::MAX as u64);
        let eight_bit = smithay_opaque_alpha_for_maximum(u8::MAX as u64);

        assert_eq!(standard, 1.0);
        assert_eq!((standard * u16::MAX as f32).round() as u64, 0xffff);
        assert_eq!((eight_bit * u16::MAX as f32).round() as u64, 0xff);
        assert_eq!(smithay_opaque_alpha_for_maximum(0), 1.0);
        assert_eq!(smithay_opaque_alpha_for_maximum(0x1_0000), 1.0);
    }

    #[test]
    fn inherited_plane_release_selects_only_bound_non_primary_planes() {
        const OVERLAY: u64 = 0;
        const PRIMARY: u64 = 1;
        const CURSOR: u64 = 2;

        assert!(!inherited_plane_needs_release(PRIMARY, 41));
        assert!(!inherited_plane_needs_release(CURSOR, 0));
        assert!(inherited_plane_needs_release(CURSOR, 41));
        assert!(inherited_plane_needs_release(OVERLAY, 42));
    }

    #[test]
    fn scanout_identity_validation_rejects_every_alias_class() {
        let identity = |output, connector, crtc, plane| ScanoutIdentity {
            output,
            connector,
            crtc,
            plane,
        };
        let baseline = identity(1, 1, 10, 20);
        assert!(validate_scanout_identities([baseline]).is_ok());
        assert_eq!(
            validate_scanout_identities([baseline, identity(1, 2, 11, 21)]),
            Err(ScanoutIdentityError::DuplicateOutput(1))
        );
        assert_eq!(
            validate_scanout_identities([baseline, identity(2, 1, 11, 21)]),
            Err(ScanoutIdentityError::DuplicateConnector(1))
        );
        assert_eq!(
            validate_scanout_identities([baseline, identity(2, 2, 10, 21)]),
            Err(ScanoutIdentityError::DuplicateCrtc(10))
        );
        assert_eq!(
            validate_scanout_identities([baseline, identity(2, 2, 11, 20)]),
            Err(ScanoutIdentityError::DuplicatePlane(20))
        );
        assert_eq!(
            validate_scanout_identities([identity(9, 1, 10, 20)]),
            Err(ScanoutIdentityError::OutputConnectorMismatch {
                output: 9,
                connector: 1,
            })
        );
        for zeroed in [
            identity(0, 1, 10, 20),
            identity(1, 0, 10, 20),
            identity(1, 1, 0, 20),
            identity(1, 1, 10, 0),
        ] {
            assert!(matches!(
                validate_scanout_identities([zeroed]),
                Err(ScanoutIdentityError::Zero(_))
            ));
        }
    }
}
