//! Ownership and rollback state for DRM scanouts and atlas buffers.

use super::*;
use std::collections::BTreeSet;
use std::fmt;

const ATLAS_BYTES_PER_PIXEL: u64 = 4;
const MAX_ATLAS_DIMENSION: u32 = 16_384;
const MAX_ATLAS_POOL_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_ATLAS_BUFFERS: usize = 33;

#[derive(Clone, Debug)]
pub(super) struct ConnectedOutput {
    pub(super) id: OutputId,
    pub(super) name: String,
    pub(super) connector: connector::Handle,
    pub(super) crtc: crtc::Handle,
    pub(super) mode: Mode,
}

pub(super) struct Scanout {
    pub(super) output: ConnectedOutput,
    pub(super) surface: DrmSurface,
    pub(super) plane_properties: AtlasPlaneProperties,
    pub(super) source_rect: PixelRect,
    pub(super) original_mode: Mode,
}

pub(super) struct PreviousScanoutState {
    pub(super) index: usize,
    pub(super) output: ConnectedOutput,
    pub(super) source_rect: PixelRect,
    pub(super) pending_mode: Mode,
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
            for scanout in self.destination.iter().take(rollback_count) {
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
}

impl AtlasPlaneProperties {
    pub(super) fn load(drm: &DrmDevice, plane: plane::Handle) -> Result<Self, Box<dyn Error>> {
        Ok(Self {
            framebuffer: named_property(drm, plane, "FB_ID")?,
            source_x: named_property(drm, plane, "SRC_X")?,
            source_y: named_property(drm, plane, "SRC_Y")?,
            source_width: named_property(drm, plane, "SRC_W")?,
            source_height: named_property(drm, plane, "SRC_H")?,
            in_fence_fd: optional_named_property(drm, plane, "IN_FENCE_FD")?,
        })
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

pub(super) struct AtlasBuffer {
    // The framebuffer must be destroyed before its backing GBM object.
    framebuffer: GbmFramebuffer,
    pub(super) dmabuf: Dmabuf,
    format: Format,
    _buffer: GbmBuffer,
}

impl AtlasBuffer {
    fn allocate(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        drm_fd: &DrmDeviceFd,
        size: PixelSize,
        modifiers: &[Modifier],
    ) -> Result<Self, Box<dyn Error>> {
        let buffer =
            allocator.create_buffer(size.width, size.height, Fourcc::Xrgb8888, modifiers)?;
        let format = smithay::backend::allocator::Buffer::format(&buffer);
        let dmabuf = buffer.export()?;
        let framebuffer = framebuffer_from_bo(drm_fd, &buffer, true)?;
        Ok(Self {
            framebuffer,
            dmabuf,
            format,
            _buffer: buffer,
        })
    }

    pub(super) fn framebuffer(&self) -> framebuffer::Handle {
        *self.framebuffer.as_ref()
    }

    pub(super) fn format(&self) -> Format {
        self.format
    }
}

pub(super) struct AtlasSwapchain {
    pub(super) size: PixelSize,
    pub(super) buffers: Vec<AtlasBuffer>,
    pub(super) current: usize,
}

pub(super) struct LayoutTransition {
    pub(super) at_frame: u64,
    pub(super) positions: BTreeMap<String, LogicalPoint>,
}

#[cfg(feature = "flutter")]
pub(super) struct FlutterLauncher {
    factory: flutter_runtime::FlutterRuntimeFactory,
    events: Sender<flutter_runtime::RuntimeEvent>,
    authentication: Arc<authentication::AuthenticationController>,
    wayland_display: Option<OsString>,
    x11_display: Option<OsString>,
    work_area: options::WorkAreaOptions,
    pub(super) generation: u64,
}

#[cfg(feature = "flutter")]
impl FlutterLauncher {
    pub(super) fn new(
        bundle: &Path,
        events: Sender<flutter_runtime::RuntimeEvent>,
        wayland_display: Option<OsString>,
        x11_display: Option<OsString>,
        work_area: options::WorkAreaOptions,
    ) -> Result<Self, Box<dyn Error>> {
        Ok(Self {
            factory: flutter_runtime::FlutterRuntimeFactory::new(bundle)?,
            events,
            authentication: Arc::new(authentication::AuthenticationController::new()?),
            wayland_display,
            x11_display,
            work_area,
            generation: 0,
        })
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
        let refresh_millihz = scanouts
            .iter()
            .map(|scanout| OutputMode::from(scanout.output.mode).refresh)
            .max()
            .ok_or("Flutter runtime has no output refresh")?;
        flutter_runtime::FlutterRuntime::start(
            renderer.egl_context(),
            swapchain.buffers.iter().map(|buffer| &buffer.dmabuf),
            swapchain.current,
            swapchain.size,
            snapshot,
            atlas,
            u32::try_from(refresh_millihz)?,
            &self.factory,
            self.events.clone(),
            Arc::clone(&self.authentication),
            self.work_area.clone(),
            self.generation,
            scanouts
                .iter()
                .all(|scanout| scanout.plane_properties.in_fence_fd.is_some()),
            self.wayland_display.clone(),
            self.x11_display.clone(),
        )
    }
}

#[cfg(feature = "flutter")]
pub(super) fn flutter_pool_length(output_count: usize) -> Result<usize, Box<dyn Error>> {
    if output_count == 0 {
        return Err("Flutter atlas pool needs at least one output".into());
    }

    // Independently clocked outputs may each retain one scanning and one
    // submitted atlas generation while Flutter needs one unowned render
    // target. This is the same bound used by deniald's established scheduler;
    // a global triple buffer would periodically couple a fast CRTC to the
    // slowest one.
    let length = output_count
        .checked_mul(2)
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
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        drm_fd: &DrmDeviceFd,
        size: PixelSize,
        modifiers: &[Modifier],
    ) -> Result<Self, Box<dyn Error>> {
        Self::allocate_pool(allocator, drm_fd, size, 2, modifiers)
    }

    pub(super) fn allocate_pool(
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        drm_fd: &DrmDeviceFd,
        size: PixelSize,
        length: usize,
        modifiers: &[Modifier],
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

        let allocate = |allocator: &mut GbmAllocator<DrmDeviceFd>, modifiers: &[Modifier]| {
            (0..length)
                .map(|_| AtlasBuffer::allocate(allocator, drm_fd, size, modifiers))
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
    /// it releases DRM master and lets SDDM perform its own modeset. Recording
    /// the scanouts still gives hotplug transactions stable output identities
    /// and original modes without depending on a racy foreign framebuffer.
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
            alpha: 1.0,
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
    #[cfg(feature = "flutter")]
    use super::flutter_pool_length;
    use super::{
        Format, FormatSet, Fourcc, Modifier, PixelSize, ScanoutIdentity, ScanoutIdentityError,
        common_xrgb8888_modifiers, validate_atlas_allocation, validate_scanout_identities,
    };

    #[cfg(feature = "flutter")]
    #[test]
    fn flutter_atlas_reserves_two_generations_per_independent_output() {
        assert!(flutter_pool_length(0).is_err());
        assert_eq!(flutter_pool_length(1).expect("one output"), 3);
        assert_eq!(flutter_pool_length(2).expect("two outputs"), 5);
        assert_eq!(flutter_pool_length(16).expect("sixteen outputs"), 33);
        assert!(flutter_pool_length(17).is_err());
        assert!(flutter_pool_length(usize::MAX).is_err());
    }

    #[test]
    fn atlas_allocation_rejects_pathological_dimensions_before_gbm() {
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 0).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 1).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 5).is_ok());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), 34).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(0, 1080), 3).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(16_385, 1080), 3).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(15_360, 4_320), 3).is_ok());
        assert!(validate_atlas_allocation(PixelSize::new(16_384, 8_192), 3).is_err());
        assert!(validate_atlas_allocation(PixelSize::new(1, 1), usize::MAX).is_err());
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
