//! Output and foreign-toplevel capture through `ext-image-copy-capture-v1`,
//! plus the legacy `zwlr-screencopy-unstable-v1` output protocol.
//!
//! Each physical output scans out its own native Flutter raster target.
//! Presented output buffers are snapshotted into capture-owned textures. GPU
//! fences retire the short source read independently of client transfers, so
//! capture backpressure cannot retain Flutter's display pool. Damage-aware
//! streams wait for changed content; transfers and readback run on a worker.

use std::collections::HashMap;
use std::error::Error;
use std::io;
#[cfg(feature = "flutter")]
use std::io::{Read, Write};
#[cfg(feature = "flutter")]
use std::os::fd::{AsRawFd, OwnedFd};
#[cfg(feature = "flutter")]
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "flutter")]
use std::sync::mpsc::{self, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Mutex};
#[cfg(feature = "flutter")]
use std::thread::{self, JoinHandle};
use std::time::Duration;
#[cfg(feature = "flutter")]
use std::time::Instant;

use denial_core::topology::OutputId;
use smithay::backend::allocator::format::FormatSet;
use smithay::backend::allocator::{Buffer as AllocatorBuffer, Fourcc, dmabuf::Dmabuf};
use smithay::backend::drm::DrmNode;
#[cfg(feature = "flutter")]
use smithay::backend::egl::EGLContext;
use smithay::backend::renderer::element::{
    Id, Kind,
    surface::{WaylandSurfaceRenderElement, render_elements_from_surface_tree},
};
use smithay::backend::renderer::gles::{GlesRenderer, GlesTexture};
#[cfg(feature = "flutter")]
use smithay::backend::renderer::sync::SyncPoint;
use smithay::backend::renderer::utils::CommitCounter;
use smithay::backend::renderer::utils::draw_render_elements;
use smithay::backend::renderer::{
    Bind, Blit, Color32F, ExportMem, Frame, ImportDma, Offscreen, Renderer, TextureFilter,
};
#[cfg(feature = "flutter")]
use smithay::backend::renderer::{Texture, element::Element};
use smithay::desktop::Window;
use smithay::output::{Output, WeakOutput};
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::channel::{Event as ChannelEvent, Sender, channel};
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::{
    Interest, Mode, PostAction,
    generic::Generic,
    timer::{TimeoutAction, Timer},
};
use smithay::reexports::wayland_protocols_wlr::screencopy::v1::server::{
    zwlr_screencopy_frame_v1::{self, ZwlrScreencopyFrameV1},
    zwlr_screencopy_manager_v1::{self, ZwlrScreencopyManagerV1},
};
use smithay::reexports::wayland_server::backend::{GlobalId, ObjectId};
use smithay::reexports::wayland_server::protocol::{
    wl_buffer::WlBuffer, wl_output::WlOutput, wl_shm, wl_surface::WlSurface,
};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, Weak,
};
#[cfg(not(feature = "flutter"))]
use smithay::utils::Point;
use smithay::utils::{Buffer as BufferCoords, Logical, Physical, Rectangle, Size, Transform};
use smithay::wayland::dmabuf::get_dmabuf;
use smithay::wayland::foreign_toplevel_list::{
    ForeignToplevelHandle, ForeignToplevelListHandler, ForeignToplevelListState,
    ForeignToplevelWeakHandle,
};
use smithay::wayland::image_capture_source::{
    ImageCaptureSource, ImageCaptureSourceHandler, ImageCaptureSourceState,
    OutputCaptureSourceHandler, OutputCaptureSourceState, ToplevelCaptureSourceHandler,
    ToplevelCaptureSourceState,
};
use smithay::wayland::image_copy_capture::{
    BufferConstraints, CaptureFailureReason, DmabufConstraints, Frame as ImageCopyFrame,
    FrameRef as ImageCopyFrameRef, ImageCopyCaptureHandler, ImageCopyCaptureState,
    Session as ImageCopySession, SessionRef as ImageCopySessionRef,
};
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::shm::{with_buffer_contents, with_buffer_contents_mut};
use tracing::{debug, warn};

use super::managed_window::ManagedWindow;

#[cfg(feature = "flutter")]
use super::super::{egl_context, flutter_runtime::OutputBufferLease};
use super::{RuntimeState, WaylandFrontend};

const PROTOCOL_VERSION: u32 = 3;
const BYTES_PER_PIXEL: i32 = 4;
const MAX_PENDING_SCREENCOPIES: usize = 64;
const MAX_COPIES_PER_PRESENTATION: usize = 4;
const MAX_TOPLEVEL_COPIES_PER_DISPATCH: usize = 4;
#[cfg(feature = "flutter")]
const MAX_IN_FLIGHT_SCREENCOPIES: usize = 4;

pub(crate) struct OutputCompositeSource {
    pub(crate) dmabuf: Dmabuf,
    pub(crate) destination: Rectangle<i32, Physical>,
    pub(crate) transform: Transform,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum CaptureTargetKind {
    Output(OutputId),
    Toplevel(u64),
}

#[derive(Clone, Debug, PartialEq)]
struct SurfaceCaptureStamp {
    id: Id,
    commit: CommitCounter,
    geometry: Rectangle<i32, Physical>,
    source: Rectangle<f64, BufferCoords>,
    transform: Transform,
    alpha: f32,
}

#[derive(Clone, Debug, PartialEq)]
enum CaptureRevision {
    Output(u64),
    Toplevel(Vec<SurfaceCaptureStamp>),
}

#[derive(Clone, Debug, PartialEq)]
struct CaptureStamp {
    target: CaptureTarget,
    revision: CaptureRevision,
}

/// Legacy damage history belongs to the manager binding, while ext capture
/// history belongs to its session. Failed/aborted frames never advance it.
#[derive(Clone, Debug, Default)]
pub(super) struct CaptureHistory(Arc<Mutex<HashMap<CaptureTargetKind, CaptureStamp>>>);

impl CaptureHistory {
    fn needs_capture(&self, stamp: &CaptureStamp) -> bool {
        self.0.lock().unwrap().get(&stamp.target.kind) != Some(stamp)
    }

    fn completed(&self, stamp: CaptureStamp) {
        let mut history = self.0.lock().unwrap();
        if let Some(previous) = history.get(&stamp.target.kind)
            && let (CaptureRevision::Output(old), CaptureRevision::Output(new)) =
                (&previous.revision, &stamp.revision)
            && old > new
        {
            // Independent GPU transfers can complete out of order.
            return;
        }
        history.insert(stamp.target.kind, stamp);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CaptureTarget {
    kind: CaptureTargetKind,
    /// Region within the upright, output-local pixel space.
    source: Rectangle<i32, Physical>,
    /// Client buffer size in the output's transformed physical pixels.
    size: Size<i32, Physical>,
    /// Complete output extent in transformed physical pixels.
    output_size: Size<i32, Physical>,
    /// Orientation of the native Flutter output buffer.
    ///
    /// The snapshot preserves the native buffer orientation. The worker uses this transform
    /// both to locate the upright `source` inside the native buffer and to
    /// render normal-oriented pixels into the capture client's buffer.
    transform: Transform,
    overlay_cursor: bool,
}

impl CaptureTarget {
    fn output(self) -> Option<OutputId> {
        match self.kind {
            CaptureTargetKind::Output(output) => Some(output),
            CaptureTargetKind::Toplevel(_) => None,
        }
    }

    fn toplevel(self) -> Option<u64> {
        match self.kind {
            CaptureTargetKind::Output(_) => None,
            CaptureTargetKind::Toplevel(toplevel) => Some(toplevel),
        }
    }

    fn into_native_output_buffer(mut self) -> Self {
        let transform = self.transform;
        self.source = transform.transform_rect_in(self.source, &self.output_size);
        self.size = transform.transform_size(self.size);
        self.output_size = transform.transform_size(self.output_size);
        self.transform = Transform::Normal;
        self
    }
}

#[derive(Clone, Debug)]
struct ForeignToplevelCaptureData {
    surface: Weak<WlSurface>,
}

#[derive(Debug)]
pub(super) struct ScreencopyFrameData {
    target: Option<CaptureTarget>,
    used: AtomicBool,
    history: CaptureHistory,
}

impl ScreencopyFrameData {
    fn new(target: Option<CaptureTarget>, history: CaptureHistory) -> Self {
        Self {
            used: AtomicBool::new(target.is_none()),
            history,
            target,
        }
    }

    fn claim(&self) -> bool {
        self.used
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }
}

#[derive(Debug)]
enum PendingBuffer {
    Shm(WlBuffer),
    Dmabuf { resource: WlBuffer, dmabuf: Dmabuf },
}

impl PendingBuffer {
    fn resource(&self) -> &WlBuffer {
        match self {
            Self::Shm(resource) | Self::Dmabuf { resource, .. } => resource,
        }
    }

    fn release(&self) {
        if self.resource().is_alive() {
            self.resource().release();
        }
    }
}

#[derive(Debug)]
enum CaptureFrame {
    Legacy {
        frame: ZwlrScreencopyFrameV1,
        with_damage: bool,
    },
    ImageCopy(ImageCopyFrame),
}

impl CaptureFrame {
    fn is_alive(&self) -> bool {
        match self {
            Self::Legacy { frame, .. } => frame.is_alive(),
            // Smithay reports destruction through `frame_aborted`, which
            // removes or cancels the corresponding request.
            Self::ImageCopy(_) => true,
        }
    }

    fn matches_legacy(&self, id: &ObjectId) -> bool {
        matches!(self, Self::Legacy { frame, .. } if frame.id() == *id)
    }

    fn matches_image_copy(&self, frame_ref: &ImageCopyFrameRef) -> bool {
        matches!(self, Self::ImageCopy(frame) if frame == frame_ref)
    }

    fn release_buffer(&self, buffer: &PendingBuffer) {
        // ext-image-copy-capture explicitly leaves wl_buffer.release unused.
        if matches!(self, Self::Legacy { .. }) {
            buffer.release();
        }
    }

    fn fail(self, reason: CaptureFailureReason) {
        match self {
            Self::Legacy { frame, .. } => {
                if frame.is_alive() {
                    frame.failed();
                }
            }
            Self::ImageCopy(frame) => frame.fail(reason),
        }
    }

    fn success(self, target: CaptureTarget, presented: Duration) {
        match self {
            Self::Legacy { frame, with_damage } => {
                if !frame.is_alive() {
                    return;
                }
                frame.flags(zwlr_screencopy_frame_v1::Flags::empty());
                if with_damage {
                    frame.damage(
                        0,
                        0,
                        u32::try_from(target.size.w).unwrap_or_default(),
                        u32::try_from(target.size.h).unwrap_or_default(),
                    );
                }
                let seconds = presented.as_secs();
                frame.ready(
                    (seconds >> 32) as u32,
                    seconds as u32,
                    presented.subsec_nanos(),
                );
            }
            Self::ImageCopy(frame) => {
                let damage = Rectangle::new((0, 0).into(), (target.size.w, target.size.h).into());
                // The copy worker resolves the output transform while writing
                // an upright client buffer, so the advertised transform is
                // normal and every completed frame currently has full damage.
                frame.success(Transform::Normal, Some(vec![damage]), presented);
            }
        }
    }
}

#[derive(Debug)]
struct PendingScreencopy {
    frame: CaptureFrame,
    target: CaptureTarget,
    buffer: PendingBuffer,
    history: Option<CaptureHistory>,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
enum CaptureDestination {
    Shm(WlBuffer),
    Dmabuf(Dmabuf),
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct CaptureJob {
    token: u64,
    cancelled: Arc<AtomicBool>,
    source: GlesTexture,
    source_ready: SyncPoint,
    source_size: Size<i32, Physical>,
    target: CaptureTarget,
    destination: CaptureDestination,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
enum CapturePayload {
    Shm,
    Dmabuf,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct CaptureCompletion {
    token: u64,
    elapsed: Duration,
    result: Result<CapturePayload, String>,
}

#[cfg(feature = "flutter")]
struct InFlightScreencopy {
    request: PendingScreencopy,
    presented: Duration,
    dmabuf: bool,
    stamp: CaptureStamp,
    cancelled: Arc<AtomicBool>,
}

#[cfg(feature = "flutter")]
enum CaptureSourceOwner {
    Output {
        output: OutputId,
        _buffer: Dmabuf,
        _lease: OutputBufferLease,
    },
    Toplevel {
        _elements: Vec<WaylandSurfaceRenderElement<GlesRenderer>>,
    },
}

#[cfg(feature = "flutter")]
struct CaptureSourceRead {
    _texture: GlesTexture,
    owner: CaptureSourceOwner,
}

/// The owner is kept even if a protocol request disappears. Only the fence,
/// not client liveness or transfer completion, permits its release.
#[cfg(feature = "flutter")]
struct FenceOwned<T> {
    ready: SyncPoint,
    resource: T,
}

#[cfg(feature = "flutter")]
fn reap_fence_owned<T>(resources: &mut HashMap<u64, FenceOwned<T>>) {
    resources.retain(|_, resource| !resource.ready.is_reached());
}

#[cfg(feature = "flutter")]
struct CaptureTransfer {
    job: CaptureJob,
    started: Instant,
    copy: Option<FenceOwned<CaptureCopy>>,
    /// The exported fence the transfer waits on: the source until the copy
    /// is submitted, then the copy.
    fence: Option<OwnedFd>,
}

#[cfg(feature = "flutter")]
impl CaptureTransfer {
    fn pending(&self) -> &SyncPoint {
        match &self.copy {
            Some(copy) => &copy.ready,
            None => &self.job.source_ready,
        }
    }
}

#[cfg(feature = "flutter")]
struct CaptureCopy {
    readback: Option<GlesTexture>,
    failure: Option<String>,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct CaptureWorker {
    jobs: Option<SyncSender<CaptureJob>>,
    /// Wakes the worker while it waits on fences of earlier transfers.
    wake: UnixStream,
    worker: Option<JoinHandle<()>>,
}

#[cfg(feature = "flutter")]
impl CaptureWorker {
    fn start(context: EGLContext, completions: Sender<CaptureCompletion>) -> io::Result<Self> {
        let (jobs, receiver) = mpsc::sync_channel::<CaptureJob>(MAX_IN_FLIGHT_SCREENCOPIES);
        let (ready, initialized) = mpsc::sync_channel::<Result<(), String>>(1);
        let (wake, worker_wake) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        worker_wake.set_nonblocking(true)?;
        let worker = thread::Builder::new()
            .name("denial-screencopy".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("screencopy");
                // SAFETY: the new shared context has never been current and is
                // moved directly into this one owning renderer thread.
                let mut renderer = match unsafe { GlesRenderer::new(context) } {
                    Ok(renderer) => renderer,
                    Err(error) => {
                        let _ = ready.send(Err(format!(
                            "could not initialize screencopy GLES renderer: {error}"
                        )));
                        return;
                    }
                };
                if ready.send(Ok(())).is_err() {
                    return;
                }
                let mut transfers: Vec<CaptureTransfer> = Vec::new();
                let mut disconnected = false;
                loop {
                    // Sleep on the channel when idle. With GPU work in flight,
                    // wait for any fence or a new job, never for one transfer:
                    // a slow client must not serialize the other streams.
                    let mut next = if transfers.is_empty() && !disconnected {
                        receiver.recv().map_err(|_| TryRecvError::Disconnected)
                    } else {
                        receiver.try_recv()
                    };
                    loop {
                        match next {
                            Ok(job) => transfers.push(CaptureTransfer {
                                job,
                                started: Instant::now(),
                                copy: None,
                                fence: None,
                            }),
                            Err(TryRecvError::Disconnected) => {
                                disconnected = true;
                                break;
                            }
                            Err(TryRecvError::Empty) => break,
                        }
                        next = receiver.try_recv();
                    }
                    let mut index = 0;
                    while index < transfers.len() {
                        let transfer = &mut transfers[index];
                        let result = if let Some(copy) = &mut transfer.copy {
                            if !copy.ready.is_reached() {
                                index += 1;
                                continue;
                            }
                            if transfer.job.cancelled.load(Ordering::Acquire) {
                                Err(io::Error::other("capture was aborted").into())
                            } else if let Some(error) = copy.resource.failure.take() {
                                Err(io::Error::other(error).into())
                            } else {
                                match (&transfer.job.destination, &mut copy.resource.readback) {
                                    (CaptureDestination::Shm(buffer), Some(texture)) => {
                                        read_capture_to_shm(
                                            &mut renderer,
                                            texture,
                                            buffer,
                                            transfer.job.target.size,
                                        )
                                        .map(|()| CapturePayload::Shm)
                                    }
                                    (CaptureDestination::Dmabuf(_), None) => {
                                        Ok(CapturePayload::Dmabuf)
                                    }
                                    _ => {
                                        Err(io::Error::other("invalid capture transfer state")
                                            .into())
                                    }
                                }
                            }
                        } else if transfer.job.cancelled.load(Ordering::Acquire) {
                            // No client GPU commands have been submitted. The
                            // independent source read still owns the snapshot.
                            Err(io::Error::other("capture was aborted").into())
                        } else {
                            if !transfer.job.source_ready.is_reached() {
                                index += 1;
                                continue;
                            }
                            match submit_capture_transfer(&mut renderer, &mut transfer.job) {
                                Ok(copy) => {
                                    transfer.copy = Some(copy);
                                    transfer.fence = None;
                                    index += 1;
                                    continue;
                                }
                                Err(error) => Err(error),
                            }
                        };
                        let transfer = transfers.swap_remove(index);
                        let _ = completions.send(CaptureCompletion {
                            token: transfer.job.token,
                            elapsed: transfer.started.elapsed(),
                            result: result.map_err(|error| error.to_string()),
                        });
                        // job retains the source texture and destination until
                        // GPU completion, including when the frame was aborted.
                    }
                    if disconnected && transfers.is_empty() {
                        break;
                    }
                    let _ = renderer.cleanup_texture_cache();
                    if !transfers.is_empty() {
                        wait_for_transfers(&mut transfers, (!disconnected).then_some(&worker_wake));
                    }
                }
            })?;
        match initialized.recv() {
            Ok(Ok(())) => Ok(Self {
                jobs: Some(jobs),
                wake,
                worker: Some(worker),
            }),
            Ok(Err(error)) => {
                let _ = worker.join();
                Err(io::Error::other(error))
            }
            Err(_) => {
                let _ = worker.join();
                Err(io::Error::other(
                    "screencopy worker exited during initialization",
                ))
            }
        }
    }

    fn try_submit(&self, job: CaptureJob) -> Result<(), TrySendError<CaptureJob>> {
        self.jobs
            .as_ref()
            .expect("live screencopy worker lost its job sender")
            .try_send(job)?;
        // A full socket already holds a wake.
        let _ = (&self.wake).write(&[1]);
        Ok(())
    }

    fn shutdown(&mut self) {
        self.jobs.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(feature = "flutter")]
impl Drop for CaptureWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Sleeps until a transfer's fence signals or a job arrives on `wake`. A
/// fence the driver cannot export is checked again after a millisecond.
/// Cancellation sets no fence; a cancelled transfer ends with its GPU work.
#[cfg(feature = "flutter")]
fn wait_for_transfers(transfers: &mut [CaptureTransfer], wake: Option<&UnixStream>) {
    let mut descriptors = Vec::with_capacity(transfers.len() + 1);
    let mut timeout = -1;
    for transfer in transfers.iter_mut() {
        if transfer.fence.is_none() {
            transfer.fence = transfer.pending().export();
        }
        match &transfer.fence {
            Some(fence) => descriptors.push(libc::pollfd {
                fd: fence.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            }),
            None => timeout = 1,
        }
    }
    if let Some(wake) = wake {
        descriptors.push(libc::pollfd {
            fd: wake.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
    }
    // SAFETY: the descriptors stay open and the array valid during the call.
    // An interrupted or failed wait only returns to the caller's checks.
    unsafe {
        libc::poll(
            descriptors.as_mut_ptr(),
            descriptors.len() as libc::nfds_t,
            timeout,
        );
    }
    if let Some(wake) = wake {
        let mut drained = [0_u8; 64];
        while matches!((&*wake).read(&mut drained), Ok(read) if read > 0) {}
    }
}

pub(super) struct ScreencopyManager {
    _legacy_global: GlobalId,
    _image_capture_source: ImageCaptureSourceState,
    output_capture_source: OutputCaptureSourceState,
    foreign_toplevel_list: ForeignToplevelListState,
    toplevel_capture_source: ToplevelCaptureSourceState,
    foreign_toplevels: HashMap<ObjectId, ForeignToplevelHandle>,
    image_copy_capture: ImageCopyCaptureState,
    image_copy_sessions: Vec<ImageCopySession>,
    pending: Vec<PendingScreencopy>,
    dmabuf_formats: FormatSet,
    render_node: Option<DrmNode>,
    #[cfg(feature = "flutter")]
    worker: Option<CaptureWorker>,
    #[cfg(feature = "flutter")]
    in_flight: HashMap<u64, InFlightScreencopy>,
    #[cfg(feature = "flutter")]
    next_token: u64,
    #[cfg(feature = "flutter")]
    source_reads: HashMap<u64, FenceOwned<CaptureSourceRead>>,
    #[cfg(feature = "flutter")]
    snapshots: HashMap<CaptureTargetKind, Vec<GlesTexture>>,
    output_revisions: HashMap<OutputId, u64>,
}

impl ScreencopyManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _legacy_global: display
                .create_global::<RuntimeState, ZwlrScreencopyManagerV1, _>(PROTOCOL_VERSION, ()),
            _image_capture_source: ImageCaptureSourceState::new(),
            output_capture_source: OutputCaptureSourceState::new::<RuntimeState>(display),
            foreign_toplevel_list: ForeignToplevelListState::new::<RuntimeState>(display),
            toplevel_capture_source: ToplevelCaptureSourceState::new::<RuntimeState>(display),
            foreign_toplevels: HashMap::new(),
            image_copy_capture: ImageCopyCaptureState::new::<RuntimeState>(display),
            image_copy_sessions: Vec::new(),
            pending: Vec::new(),
            dmabuf_formats: FormatSet::default(),
            render_node: None,
            #[cfg(feature = "flutter")]
            worker: None,
            #[cfg(feature = "flutter")]
            in_flight: HashMap::new(),
            #[cfg(feature = "flutter")]
            next_token: 1,
            #[cfg(feature = "flutter")]
            source_reads: HashMap::new(),
            #[cfg(feature = "flutter")]
            snapshots: HashMap::new(),
            output_revisions: HashMap::new(),
        }
    }
}

#[cfg(feature = "flutter")]
impl Drop for ScreencopyManager {
    fn drop(&mut self) {
        // Drain worker GPU work before releasing client resources. A snapshot
        // rejected by the worker queue can still own an outstanding source
        // read, so retire that fence as well before dropping its owner.
        if let Some(mut worker) = self.worker.take() {
            worker.shutdown();
        }
        for read in self.source_reads.values() {
            while !read.ready.is_reached() {
                let _ = read.ready.wait();
            }
        }
    }
}

fn scaled_edge(edge: i32, logical_extent: i32, pixel_extent: i32) -> Option<i32> {
    if edge < 0 || logical_extent <= 0 || pixel_extent <= 0 {
        return None;
    }
    let numerator = i64::from(edge)
        .checked_mul(i64::from(pixel_extent))?
        .checked_add(i64::from(logical_extent) / 2)?;
    i32::try_from(numerator / i64::from(logical_extent)).ok()
}

fn project_capture_region(
    output: OutputId,
    source: Rectangle<i32, Physical>,
    capture_size: Size<i32, Physical>,
    logical_size: Size<i32, Logical>,
    requested: Option<Rectangle<i32, Logical>>,
    output_transform: Transform,
    overlay_cursor: bool,
) -> Option<CaptureTarget> {
    let requested = requested.unwrap_or_else(|| Rectangle::from_size(logical_size));
    if requested.size.w <= 0 || requested.size.h <= 0 {
        return None;
    }

    let left = requested.loc.x.clamp(0, logical_size.w);
    let top = requested.loc.y.clamp(0, logical_size.h);
    let right = requested
        .loc
        .x
        .saturating_add(requested.size.w)
        .clamp(0, logical_size.w);
    let bottom = requested
        .loc
        .y
        .saturating_add(requested.size.h)
        .clamp(0, logical_size.h);
    if right <= left || bottom <= top {
        return None;
    }

    let source_left = scaled_edge(left, logical_size.w, source.size.w)?;
    let source_top = scaled_edge(top, logical_size.h, source.size.h)?;
    let source_right = scaled_edge(right, logical_size.w, source.size.w)?;
    let source_bottom = scaled_edge(bottom, logical_size.h, source.size.h)?;
    let buffer_left = scaled_edge(left, logical_size.w, capture_size.w)?;
    let buffer_top = scaled_edge(top, logical_size.h, capture_size.h)?;
    let buffer_right = scaled_edge(right, logical_size.w, capture_size.w)?;
    let buffer_bottom = scaled_edge(bottom, logical_size.h, capture_size.h)?;

    let source = Rectangle::new(
        (
            source.loc.x.checked_add(source_left)?,
            source.loc.y.checked_add(source_top)?,
        )
            .into(),
        (
            source_right.checked_sub(source_left)?.max(1),
            source_bottom.checked_sub(source_top)?.max(1),
        )
            .into(),
    );
    let size = (
        buffer_right.checked_sub(buffer_left)?.max(1),
        buffer_bottom.checked_sub(buffer_top)?.max(1),
    )
        .into();
    Some(CaptureTarget {
        kind: CaptureTargetKind::Output(output),
        source,
        size,
        output_size: capture_size,
        transform: output_transform,
        overlay_cursor,
    })
}

fn pool_range_is_valid(pool_len: usize, offset: i32, stride: i32, width: i32, height: i32) -> bool {
    let (Ok(offset), Ok(stride), Ok(width), Ok(height)) = (
        usize::try_from(offset),
        usize::try_from(stride),
        usize::try_from(width),
        usize::try_from(height),
    ) else {
        return false;
    };
    let Some(row_bytes) = width.checked_mul(BYTES_PER_PIXEL as usize) else {
        return false;
    };
    let Some(last_row) = height
        .checked_sub(1)
        .and_then(|row| row.checked_mul(stride))
    else {
        return false;
    };
    offset
        .checked_add(last_row)
        .and_then(|start| start.checked_add(row_bytes))
        .is_some_and(|end| end <= pool_len)
}

fn validate_capture_buffer(
    buffer: WlBuffer,
    target: CaptureTarget,
    dmabuf_formats: &FormatSet,
) -> Result<PendingBuffer, &'static str> {
    if let Ok(dmabuf) = get_dmabuf(&buffer) {
        let dmabuf = dmabuf.clone();
        if !dmabuf_formats.contains(&dmabuf.format()) {
            return Err("DMA-BUF capture was not advertised");
        }
        if Some(dmabuf.width()) != u32::try_from(target.size.w).ok()
            || Some(dmabuf.height()) != u32::try_from(target.size.h).ok()
            || dmabuf.format().code != Fourcc::Xrgb8888
        {
            return Err("DMA-BUF dimensions or format do not match the capture frame");
        }
        return Ok(PendingBuffer::Dmabuf {
            resource: buffer,
            dmabuf,
        });
    }

    let valid = with_buffer_contents(&buffer, |_, pool_len, data| {
        data.width == target.size.w
            && data.height == target.size.h
            && data.stride == target.size.w.saturating_mul(BYTES_PER_PIXEL)
            && data.format == wl_shm::Format::Xrgb8888
            && pool_range_is_valid(pool_len, data.offset, data.stride, data.width, data.height)
    })
    .map_err(|_| "capture buffer is neither a supported wl_shm buffer nor a DMA-BUF")?;
    if !valid {
        return Err("wl_shm dimensions, stride, format, or pool size are invalid");
    }
    Ok(PendingBuffer::Shm(buffer))
}

fn framebuffer_source_rect(
    source: Rectangle<i32, Physical>,
    atlas_size: Size<i32, Physical>,
) -> Option<Rectangle<i32, Physical>> {
    let right = source.loc.x.checked_add(source.size.w)?;
    let bottom = source.loc.y.checked_add(source.size.h)?;
    (source.loc.x >= 0
        && source.loc.y >= 0
        && source.size.w > 0
        && source.size.h > 0
        && right <= atlas_size.w
        && bottom <= atlas_size.h)
        .then_some(source)
}

fn capture_source_rect(
    target: CaptureTarget,
    scanout_size: Size<i32, Physical>,
) -> Option<Rectangle<i32, Physical>> {
    let source = target
        .transform
        .transform_rect_in(target.source, &target.output_size);
    framebuffer_source_rect(source, scanout_size)
}

fn as_buffer_rect(rect: Rectangle<i32, Physical>) -> Rectangle<i32, BufferCoords> {
    Rectangle::new(
        (rect.loc.x, rect.loc.y).into(),
        (rect.size.w, rect.size.h).into(),
    )
}

fn copy_pixels_to_shm(
    buffer: &WlBuffer,
    pixels: &[u8],
    size: Size<i32, Physical>,
) -> Result<(), Box<dyn Error>> {
    let row_bytes = usize::try_from(size.w)?
        .checked_mul(BYTES_PER_PIXEL as usize)
        .ok_or_else(|| io::Error::other("capture row size overflow"))?;
    let expected = row_bytes
        .checked_mul(usize::try_from(size.h)?)
        .ok_or_else(|| io::Error::other("capture payload size overflow"))?;
    if pixels.len() < expected {
        return Err(io::Error::other("renderer returned a short capture mapping").into());
    }

    with_buffer_contents_mut(buffer, |destination, pool_len, data| {
        if !pool_range_is_valid(pool_len, data.offset, data.stride, data.width, data.height) {
            return Err(io::Error::other("capture buffer pool changed size"));
        }
        // SAFETY: `pool_range_is_valid` proves that `offset` starts within the
        // mapped pool and that every copied row remains inside it.
        let destination = unsafe { destination.add(data.offset as usize) };
        let stride = data.stride as usize;
        for row in 0..size.h as usize {
            // SAFETY: `pool_range_is_valid` proves every destination row is
            // within the mapped pool and `expected` proves every source row
            // is within `pixels`. Source and destination are distinct
            // allocations owned by the renderer and Wayland client.
            unsafe {
                std::ptr::copy_nonoverlapping(
                    pixels.as_ptr().add(row * row_bytes),
                    destination.add(row * stride),
                    row_bytes,
                );
            }
        }
        Ok::<(), io::Error>(())
    })
    .map_err(|error| io::Error::other(error.to_string()))??;
    Ok(())
}

fn capture_pixels_to_vec(
    pixels: &[u8],
    size: Size<i32, Physical>,
) -> Result<Vec<u8>, Box<dyn Error>> {
    let expected = usize::try_from(size.w)?
        .checked_mul(usize::try_from(size.h)?)
        .and_then(|pixels| pixels.checked_mul(BYTES_PER_PIXEL as usize))
        .ok_or_else(|| io::Error::other("capture payload size overflow"))?;
    if pixels.len() < expected {
        return Err(io::Error::other("renderer returned a short capture mapping").into());
    }
    Ok(pixels[..expected].to_vec())
}

pub(crate) fn copy_atlas_region_to_memory(
    renderer: &mut GlesRenderer,
    atlas: &mut Dmabuf,
    atlas_size: Size<i32, Physical>,
    source: Rectangle<i32, Physical>,
) -> Result<Vec<u8>, Box<dyn Error>> {
    let source = framebuffer_source_rect(source, atlas_size)
        .ok_or_else(|| io::Error::other("capture source is outside the atlas"))?;
    let source_framebuffer = renderer.bind(atlas)?;
    let mapping = renderer.copy_framebuffer(
        &source_framebuffer,
        as_buffer_rect(source),
        Fourcc::Xrgb8888,
    )?;
    let pixels = renderer.map_texture(&mapping)?;
    capture_pixels_to_vec(pixels, source.size)
}

pub(crate) fn compose_output_targets_to_atlas(
    renderer: &mut GlesRenderer,
    sources: &mut [OutputCompositeSource],
    atlas_size: Size<i32, Physical>,
    destination: &mut Dmabuf,
) -> Result<(), Box<dyn Error>> {
    if i32::try_from(destination.width()).ok() != Some(atlas_size.w)
        || i32::try_from(destination.height()).ok() != Some(atlas_size.h)
    {
        return Err(io::Error::other("screenshot DMA-BUF does not match the atlas size").into());
    }

    {
        let mut destination_framebuffer = renderer.bind(destination)?;
        let mut frame =
            renderer.render(&mut destination_framebuffer, atlas_size, Transform::Normal)?;
        frame.clear(
            Color32F::new(0.0, 0.0, 0.0, 1.0),
            &[Rectangle::from_size(atlas_size)],
        )?;
        frame.finish()?.wait()?;
    }

    for source in sources {
        let source_size: Size<i32, Physical> = (
            i32::try_from(source.dmabuf.width())?,
            i32::try_from(source.dmabuf.height())?,
        )
            .into();
        if framebuffer_source_rect(source.destination, atlas_size).is_none() {
            return Err(io::Error::other("output destination is outside screenshot atlas").into());
        }
        if source.transform == Transform::Normal {
            let source_framebuffer = renderer.bind(&mut source.dmabuf)?;
            let mut destination_framebuffer = renderer.bind(destination)?;
            renderer
                .blit(
                    &source_framebuffer,
                    &mut destination_framebuffer,
                    Rectangle::from_size(source_size),
                    source.destination,
                    if source_size == source.destination.size {
                        TextureFilter::Nearest
                    } else {
                        TextureFilter::Linear
                    },
                )?
                .wait()?;
            continue;
        }

        let texture = renderer.import_dmabuf(&source.dmabuf, None)?;
        let mut destination_framebuffer = renderer.bind(destination)?;
        let mut frame =
            renderer.render(&mut destination_framebuffer, atlas_size, Transform::Normal)?;
        let source_rect = Rectangle::<f64, BufferCoords>::from_size(
            (f64::from(source_size.w), f64::from(source_size.h)).into(),
        );
        // Frame damage and opaque regions are destination-local. Passing the
        // atlas-space destination here clips every transformed output whose
        // atlas origin is non-zero down to an empty draw, leaving that output
        // black in both the selection texture and the saved screenshot.
        let destination_local = output_composite_local_rect(source.destination);
        // Flutter's output projection maps the atlas scene into the native
        // connector buffer. `render_texture_from_to` applies the inverse of
        // the supplied source orientation, so passing that same orientation
        // reconstructs upright atlas pixels. Pre-inverting it here applies the
        // output rotation twice on 90/270-degree outputs.
        let source_transform = output_composite_source_transform(source.transform);
        frame.render_texture_from_to(
            &texture,
            source_rect,
            source.destination,
            &[destination_local],
            &[destination_local],
            source_transform,
            1.0,
            None,
            &[],
        )?;
        frame.finish()?.wait()?;
    }
    Ok(())
}

fn output_composite_local_rect(destination: Rectangle<i32, Physical>) -> Rectangle<i32, Physical> {
    Rectangle::from_size(destination.size)
}

fn output_composite_source_transform(transform: Transform) -> Transform {
    transform
}

#[cfg(all(test, feature = "flutter"))]
mod capture_lifetime_tests {
    use super::*;
    use smithay::backend::renderer::sync::{Fence, Interrupted};
    use std::os::fd::OwnedFd;

    #[derive(Debug)]
    struct TestFence(Arc<AtomicBool>);

    impl Fence for TestFence {
        fn is_signaled(&self) -> bool {
            self.0.load(Ordering::Acquire)
        }

        fn wait(&self) -> Result<(), Interrupted> {
            panic!("capture retirement must never block the compositor")
        }

        fn is_exportable(&self) -> bool {
            false
        }

        fn export(&self) -> Option<OwnedFd> {
            None
        }
    }

    #[test]
    fn source_owner_retires_at_snapshot_fence_independently_of_client_transfer() {
        let source_ready = Arc::new(AtomicBool::new(false));
        let client_ready = Arc::new(AtomicBool::new(false));
        let source_owner = Arc::new(());
        let source_lifetime = Arc::downgrade(&source_owner);
        let client_owner = Arc::new(());
        let client_lifetime = Arc::downgrade(&client_owner);
        let mut source_reads = HashMap::from([(
            1,
            FenceOwned {
                ready: TestFence(source_ready.clone()).into(),
                resource: source_owner,
            },
        )]);
        let mut transfers = HashMap::from([(
            2,
            FenceOwned {
                ready: TestFence(client_ready.clone()).into(),
                resource: client_owner,
            },
        )]);

        reap_fence_owned(&mut source_reads);
        assert!(source_lifetime.upgrade().is_some());
        source_ready.store(true, Ordering::Release);
        reap_fence_owned(&mut source_reads);
        reap_fence_owned(&mut transfers);
        assert!(source_lifetime.upgrade().is_none());
        assert!(client_lifetime.upgrade().is_some());

        client_ready.store(true, Ordering::Release);
        reap_fence_owned(&mut transfers);
        assert!(client_lifetime.upgrade().is_none());
    }

    #[test]
    fn capture_history_is_per_stream_and_successful_generation() {
        let target = project_capture_region(
            OutputId(7),
            Rectangle::from_size((2560, 1440).into()),
            (2560, 1440).into(),
            (2560, 1440).into(),
            None,
            Transform::Normal,
            false,
        )
        .unwrap();
        let stamp = |generation| CaptureStamp {
            target,
            revision: CaptureRevision::Output(generation),
        };
        let history = CaptureHistory::default();
        assert!(
            history.needs_capture(&stamp(0)),
            "first frame must capture even an idle output"
        );
        history.completed(stamp(0));
        assert!(!history.needs_capture(&stamp(0)));
        assert!(history.needs_capture(&stamp(1)));
        assert!(
            history.needs_capture(&stamp(1)),
            "failed frames leave damage pending"
        );

        history.completed(stamp(2));
        history.completed(stamp(1));
        assert!(
            !history.needs_capture(&stamp(2)),
            "late completion must not rewind history"
        );
        assert!(
            CaptureHistory::default().needs_capture(&stamp(2)),
            "a new stream needs its own first frame"
        );
        let mut resized = stamp(2);
        resized.target.size = (1280, 720).into();
        assert!(
            history.needs_capture(&resized),
            "geometry changes invalidate the captured frame"
        );
    }
}

#[cfg(test)]
mod capture_rotation_tests {
    use super::*;

    #[test]
    fn atlas_composition_passes_native_output_orientation_to_renderer() {
        // Smithay's renderer applies the inverse of src_transform. The native
        // buffer orientation must therefore be passed through, not inverted
        // before the renderer sees it.
        assert_eq!(
            output_composite_source_transform(Transform::_90),
            Transform::_90
        );
        assert_eq!(
            output_composite_source_transform(Transform::_270),
            Transform::_270
        );
        assert_eq!(
            output_composite_source_transform(Transform::Flipped90),
            Transform::Flipped90
        );
    }

    #[test]
    fn rotated_output_capture_maps_upright_region_into_native_buffer() {
        let target = project_capture_region(
            OutputId(7),
            Rectangle::from_size((1440, 2560).into()),
            (1440, 2560).into(),
            (1440, 2560).into(),
            None,
            Transform::_90,
            false,
        )
        .expect("valid capture target");

        assert_eq!(target.transform, Transform::_90);
        assert_eq!(target.size, Size::from((1440, 2560)));
        assert_eq!(
            capture_source_rect(target, (2560, 1440).into()),
            Some(Rectangle::from_size((2560, 1440).into()))
        );
    }

    #[test]
    fn legacy_capture_preserves_native_output_orientation() {
        let target = project_capture_region(
            OutputId(7),
            Rectangle::from_size((1440, 2560).into()),
            (1440, 2560).into(),
            (1440, 2560).into(),
            None,
            Transform::_90,
            false,
        )
        .expect("valid capture target")
        .into_native_output_buffer();

        assert_eq!(target.transform, Transform::Normal);
        assert_eq!(target.source, Rectangle::from_size((2560, 1440).into()));
        assert_eq!(target.size, Size::from((2560, 1440)));
        assert_eq!(target.output_size, Size::from((2560, 1440)));
        assert_eq!(
            capture_source_rect(target, (2560, 1440).into()),
            Some(Rectangle::from_size((2560, 1440).into()))
        );
    }
}

#[cfg(feature = "flutter")]
fn submit_capture_transfer(
    renderer: &mut GlesRenderer,
    job: &mut CaptureJob,
) -> Result<FenceOwned<CaptureCopy>, Box<dyn Error>> {
    let source = capture_source_rect(job.target, job.source_size)
        .ok_or_else(|| io::Error::other("capture source is outside the snapshot"))?;
    let mut readback = match &job.destination {
        CaptureDestination::Shm(_) => {
            Some(<GlesRenderer as Offscreen<GlesTexture>>::create_buffer(
                renderer,
                Fourcc::Xrgb8888,
                (job.target.size.w, job.target.size.h).into(),
            )?)
        }
        CaptureDestination::Dmabuf(_) => None,
    };
    let mut framebuffer = match (&mut job.destination, &mut readback) {
        (CaptureDestination::Shm(_), Some(texture)) => renderer.bind(texture)?,
        (CaptureDestination::Dmabuf(destination), None) => renderer.bind(destination)?,
        _ => unreachable!("capture destination and readback texture disagree"),
    };
    let destination = Rectangle::from_size(job.target.size);
    if job.target.transform == Transform::Normal {
        let source_framebuffer = renderer.bind(&mut job.source)?;
        let ready = renderer.blit(
            &source_framebuffer,
            &mut framebuffer,
            source,
            destination,
            if source.size == job.target.size {
                TextureFilter::Nearest
            } else {
                TextureFilter::Linear
            },
        )?;
        drop(source_framebuffer);
        drop(framebuffer);
        return Ok(FenceOwned {
            ready,
            resource: CaptureCopy {
                readback,
                failure: None,
            },
        });
    }
    let mut frame = renderer.render(&mut framebuffer, job.target.size, Transform::Normal)?;
    let failure = frame
        .render_texture_from_to(
            &job.source,
            as_buffer_rect(source).to_f64(),
            destination,
            &[destination],
            &[destination],
            job.target.transform,
            1.0,
            None,
            &[],
        )
        .err()
        .map(|error| error.to_string());
    let ready = frame.finish()?;
    drop(framebuffer);
    Ok(FenceOwned {
        ready,
        resource: CaptureCopy { readback, failure },
    })
}

#[cfg(feature = "flutter")]
fn read_capture_to_shm(
    renderer: &mut GlesRenderer,
    texture: &mut GlesTexture,
    buffer: &WlBuffer,
    size: Size<i32, Physical>,
) -> Result<(), Box<dyn Error>> {
    let framebuffer = renderer.bind(texture)?;
    let mapping = renderer.copy_framebuffer(
        &framebuffer,
        Rectangle::from_size((size.w, size.h).into()),
        Fourcc::Xrgb8888,
    )?;
    let pixels = renderer.map_texture(&mapping)?;
    // Smithay locks the shm pool mapping for this access. The potentially
    // expensive readback and row copies never run on the compositor thread.
    copy_pixels_to_shm(buffer, pixels, size)
}

#[cfg(not(feature = "flutter"))]
fn render_toplevel_capture(
    renderer: &mut GlesRenderer,
    window: &Window,
    scale: f64,
    target: CaptureTarget,
    buffer: &mut PendingBuffer,
) -> Result<(), Box<dyn Error>> {
    let physical_bbox: Rectangle<i32, Physical> = window.bbox().to_physical_precise_round(scale);
    if physical_bbox.size != target.size || target.transform != Transform::Normal {
        return Err(io::Error::other("toplevel capture geometry changed").into());
    }
    let location: Point<i32, Physical> = (-physical_bbox.loc.x, -physical_bbox.loc.y).into();
    let surface = window
        .wl_surface()
        .ok_or_else(|| io::Error::other("toplevel capture source has no Wayland surface"))?;
    let elements: Vec<WaylandSurfaceRenderElement<GlesRenderer>> =
        render_elements_from_surface_tree(
            renderer,
            &surface,
            location,
            scale,
            1.0,
            Kind::Unspecified,
        );
    let damage = Rectangle::from_size(target.size);

    match buffer {
        PendingBuffer::Dmabuf { dmabuf, .. } => {
            let mut framebuffer = renderer.bind(dmabuf)?;
            let mut frame = renderer.render(&mut framebuffer, target.size, Transform::Normal)?;
            frame.clear(Color32F::new(0.0, 0.0, 0.0, 1.0), &[damage])?;
            draw_render_elements(&mut frame, scale, &elements, &[damage])?;
            frame.finish()?.wait()?;
        }
        PendingBuffer::Shm(buffer) => {
            let texture_size: Size<i32, BufferCoords> = (target.size.w, target.size.h).into();
            let mut rendered = <GlesRenderer as Offscreen<GlesTexture>>::create_buffer(
                renderer,
                Fourcc::Xrgb8888,
                texture_size,
            )?;
            let mut framebuffer = renderer.bind(&mut rendered)?;
            let mut frame = renderer.render(&mut framebuffer, target.size, Transform::Normal)?;
            frame.clear(Color32F::new(0.0, 0.0, 0.0, 1.0), &[damage])?;
            draw_render_elements(&mut frame, scale, &elements, &[damage])?;
            frame.finish()?.wait()?;
            let mapping = renderer.copy_framebuffer(
                &framebuffer,
                as_buffer_rect(damage),
                Fourcc::Xrgb8888,
            )?;
            let pixels = renderer.map_texture(&mapping)?;
            let pixels = capture_pixels_to_vec(pixels, target.size)?;
            copy_pixels_to_shm(buffer, &pixels, target.size)?;
        }
    }
    Ok(())
}

fn foreign_toplevel_metadata(window: &Window) -> (String, String) {
    ManagedWindow::new(window)
        .map(|window| window.metadata())
        .unwrap_or_default()
}

impl WaylandFrontend {
    pub(super) fn announce_foreign_toplevel(&mut self, window: &Window) {
        let Some(surface) = self.window_root_surface(window) else {
            return;
        };
        if self
            .screencopy
            .foreign_toplevels
            .contains_key(&surface.id())
        {
            self.update_foreign_toplevel(window);
            return;
        }
        let (title, app_id) = foreign_toplevel_metadata(window);
        let handle = self
            .screencopy
            .foreign_toplevel_list
            .new_toplevel::<RuntimeState>(title, app_id);
        handle
            .user_data()
            .insert_if_missing(|| ForeignToplevelCaptureData {
                surface: surface.downgrade(),
            });
        self.screencopy
            .foreign_toplevels
            .insert(surface.id(), handle);
    }

    pub(super) fn update_foreign_toplevel(&mut self, window: &Window) {
        let Some(surface) = self.window_root_surface(window) else {
            return;
        };
        let Some(handle) = self.screencopy.foreign_toplevels.get(&surface.id()) else {
            return;
        };
        let (title, app_id) = foreign_toplevel_metadata(window);
        let changed = handle.title() != title || handle.app_id() != app_id;
        if !changed {
            return;
        }
        handle.send_title(&title);
        handle.send_app_id(&app_id);
        handle.send_done();
    }

    pub(super) fn remove_foreign_toplevel(&mut self, surface: &WlSurface) {
        let stable_id = self.surface_ids.get(&surface.id()).copied();
        let Some(handle) = self.screencopy.foreign_toplevels.remove(&surface.id()) else {
            return;
        };
        self.screencopy
            .foreign_toplevel_list
            .remove_toplevel(&handle);
        if let Some(stable_id) = stable_id {
            self.fail_screencopies_for_toplevel(stable_id);
        }
        self.refresh_image_copy_constraints_if_changed();
    }

    fn capture_target_for_output(
        &self,
        output: &Output,
        requested: Option<Rectangle<i32, Logical>>,
        overlay_cursor: bool,
    ) -> Option<CaptureTarget> {
        let entry = self
            .outputs
            .iter()
            .find(|entry| entry.output == *output && entry.powered)?;
        project_capture_region(
            entry.id,
            entry.capture_source,
            entry.capture_size,
            entry.logical_geometry.size,
            requested,
            entry.output.current_transform(),
            overlay_cursor,
        )
    }

    fn capture_target(
        &self,
        output: &WlOutput,
        requested: Option<Rectangle<i32, Logical>>,
        overlay_cursor: bool,
    ) -> Option<CaptureTarget> {
        let output = Output::from_resource(output)?;
        self.capture_target_for_output(&output, requested, overlay_cursor)
            .map(CaptureTarget::into_native_output_buffer)
    }

    fn image_copy_target(
        &self,
        source: &ImageCaptureSource,
        overlay_cursor: bool,
    ) -> Option<CaptureTarget> {
        if let Some(output) = source.user_data().get::<WeakOutput>() {
            return self.capture_target_for_output(&output.upgrade()?, None, overlay_cursor);
        }
        let toplevel = source
            .user_data()
            .get::<ForeignToplevelWeakHandle>()?
            .upgrade()?;
        if toplevel.is_closed() {
            return None;
        }
        let surface = toplevel
            .user_data()
            .get::<ForeignToplevelCaptureData>()?
            .surface
            .upgrade()
            .ok()?;
        let window = self.window_for_root_surface(&surface)?;
        let stable_id = *self.surface_ids.get(&surface.id())?;
        let output = self.output_for_geometry(self.window_geometry_target(&window))?;
        let scale = output.output.current_scale().fractional_scale();
        let physical_bbox: Rectangle<i32, Physical> =
            window.bbox().to_physical_precise_round(scale);
        if physical_bbox.size.w <= 0 || physical_bbox.size.h <= 0 {
            return None;
        }
        Some(CaptureTarget {
            kind: CaptureTargetKind::Toplevel(stable_id),
            source: Rectangle::from_size(physical_bbox.size),
            size: physical_bbox.size,
            output_size: physical_bbox.size,
            transform: Transform::Normal,
            overlay_cursor,
        })
    }

    fn image_copy_constraints(&self, source: &ImageCaptureSource) -> Option<BufferConstraints> {
        let target = self.image_copy_target(source, false)?;
        let modifiers = self
            .screencopy
            .dmabuf_formats
            .iter()
            .filter(|format| format.code == Fourcc::Xrgb8888)
            .map(|format| format.modifier)
            .collect::<Vec<_>>();
        let dma = self
            .screencopy
            .render_node
            .filter(|_| !modifiers.is_empty())
            .map(|node| DmabufConstraints {
                node,
                formats: vec![(Fourcc::Xrgb8888, modifiers)],
            });
        Some(BufferConstraints {
            size: (target.size.w, target.size.h).into(),
            shm: vec![wl_shm::Format::Xrgb8888],
            dma,
        })
    }

    fn announce_screencopy_frame(
        &self,
        frame: &ZwlrScreencopyFrameV1,
        target: Option<CaptureTarget>,
    ) {
        let Some(target) = target else {
            frame.failed();
            return;
        };
        let Ok(width) = u32::try_from(target.size.w) else {
            frame.failed();
            return;
        };
        let Ok(height) = u32::try_from(target.size.h) else {
            frame.failed();
            return;
        };
        let Some(stride) = target
            .size
            .w
            .checked_mul(BYTES_PER_PIXEL)
            .and_then(|stride| u32::try_from(stride).ok())
        else {
            frame.failed();
            return;
        };
        frame.buffer(wl_shm::Format::Xrgb8888, width, height, stride);
        if frame.version() >= 3 {
            if self
                .screencopy
                .dmabuf_formats
                .iter()
                .any(|format| format.code == Fourcc::Xrgb8888)
            {
                frame.linux_dmabuf(Fourcc::Xrgb8888 as u32, width, height);
            }
            frame.buffer_done();
        }
    }

    fn queue_screencopy(
        &mut self,
        frame: &ZwlrScreencopyFrameV1,
        data: &ScreencopyFrameData,
        buffer: WlBuffer,
        with_damage: bool,
    ) {
        if !data.claim() {
            frame.post_error(
                zwlr_screencopy_frame_v1::Error::AlreadyUsed,
                "screencopy frame has already been used",
            );
            return;
        }
        let Some(target) = data.target else {
            frame.failed();
            return;
        };
        let buffer = match validate_capture_buffer(buffer, target, &self.screencopy.dmabuf_formats)
        {
            Ok(buffer) => buffer,
            Err(message) => {
                frame.post_error(zwlr_screencopy_frame_v1::Error::InvalidBuffer, message);
                return;
            }
        };
        if self.screencopy.pending.len() >= MAX_PENDING_SCREENCOPIES {
            buffer.release();
            frame.failed();
            warn!(
                limit = MAX_PENDING_SCREENCOPIES,
                "rejected screencopy because the bounded request queue is full"
            );
            return;
        }
        self.screencopy.pending.push(PendingScreencopy {
            frame: CaptureFrame::Legacy {
                frame: frame.clone(),
                with_damage,
            },
            target,
            buffer,
            history: with_damage.then(|| data.history.clone()),
        });
    }

    fn queue_image_copy(&mut self, session: &ImageCopySessionRef, frame: ImageCopyFrame) {
        let Some(target) = self.image_copy_target(&session.source(), session.draw_cursor()) else {
            frame.fail(CaptureFailureReason::Unknown);
            return;
        };
        let buffer = match validate_capture_buffer(
            frame.buffer(),
            target,
            &self.screencopy.dmabuf_formats,
        ) {
            Ok(buffer) => buffer,
            Err(message) => {
                warn!(%message, "rejected image-copy-capture buffer");
                frame.fail(CaptureFailureReason::BufferConstraints);
                return;
            }
        };
        if self.screencopy.pending.len() >= MAX_PENDING_SCREENCOPIES {
            frame.fail(CaptureFailureReason::Unknown);
            warn!(
                limit = MAX_PENDING_SCREENCOPIES,
                "rejected image-copy capture because the bounded request queue is full"
            );
            return;
        }
        session
            .user_data()
            .insert_if_missing(CaptureHistory::default);
        let history = session.user_data().get::<CaptureHistory>().unwrap().clone();
        self.screencopy.pending.push(PendingScreencopy {
            frame: CaptureFrame::ImageCopy(frame),
            target,
            buffer,
            history: Some(history),
        });
    }

    fn cancel_screencopy(&mut self, frame: ObjectId) {
        self.screencopy.pending.retain(|request| {
            let keep = !request.frame.matches_legacy(&frame);
            if !keep {
                request.frame.release_buffer(&request.buffer);
            }
            keep
        });
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            if capture.request.frame.matches_legacy(&frame) {
                capture.cancelled.store(true, Ordering::Release);
            }
        }
    }

    fn cancel_image_copy(&mut self, frame: &ImageCopyFrameRef) {
        self.screencopy.pending.retain(|request| {
            let keep = !request.frame.matches_image_copy(frame);
            if !keep {
                request.frame.release_buffer(&request.buffer);
            }
            keep
        });
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            if capture.request.frame.matches_image_copy(frame) {
                capture.cancelled.store(true, Ordering::Release);
            }
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn init_screencopy_worker(
        &mut self,
        renderer: &GlesRenderer,
    ) -> Result<(), Box<dyn Error>> {
        if self.screencopy.worker.is_some() {
            return Ok(());
        }
        let context = egl_context::create_screencopy_context(renderer.egl_context())?;
        let (completion_sender, completion_source) = channel();
        let worker = CaptureWorker::start(context, completion_sender)?;
        self.loop_handle.insert_source(
            completion_source,
            |event, _, state: &mut RuntimeState| {
                if let ChannelEvent::Msg(completion) = event
                    && let Some(frontend) = state.wayland.as_mut()
                {
                    frontend.finish_screencopy(completion);
                }
            },
        )?;
        self.screencopy.worker = Some(worker);
        Ok(())
    }

    pub(super) fn set_screencopy_dmabuf_formats(
        &mut self,
        formats: FormatSet,
        render_node: Option<DrmNode>,
    ) {
        self.screencopy.dmabuf_formats = formats;
        self.screencopy.render_node = render_node;
        self.refresh_image_copy_constraints();
    }

    pub(super) fn refresh_image_copy_constraints(&mut self) {
        let sessions = std::mem::take(&mut self.screencopy.image_copy_sessions);
        let mut retained = Vec::with_capacity(sessions.len());
        for session in sessions {
            if let Some(constraints) = self.image_copy_constraints(&session.source()) {
                session.update_constraints(constraints);
                retained.push(session);
            } else {
                session.stop();
            }
        }
        self.screencopy.image_copy_sessions = retained;
        self.screencopy.image_copy_capture.cleanup();
    }

    pub(super) fn refresh_image_copy_constraints_if_changed(&mut self) {
        let sessions = std::mem::take(&mut self.screencopy.image_copy_sessions);
        let mut retained = Vec::with_capacity(sessions.len());
        for session in sessions {
            if let Some(constraints) = self.image_copy_constraints(&session.source()) {
                if session
                    .current_constraints()
                    .is_none_or(|current| current.size != constraints.size)
                {
                    session.update_constraints(constraints);
                }
                retained.push(session);
            } else {
                session.stop();
            }
        }
        self.screencopy.image_copy_sessions = retained;
        self.screencopy.image_copy_capture.cleanup();
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn has_pending_screencopies(&self) -> bool {
        !self.screencopy.pending.is_empty()
    }

    pub(crate) fn has_pending_screencopy_for_output(&self, output: OutputId) -> bool {
        self.screencopy
            .pending
            .iter()
            .any(|request| request.target.output() == Some(output))
    }

    pub(crate) fn screencopy_clock_now(&self) -> Duration {
        self.presentation.monotonic_now()
    }

    #[cfg(not(feature = "flutter"))]
    pub(crate) fn process_toplevel_screencopies(
        &mut self,
        renderer: &mut GlesRenderer,
    ) -> Result<(), Box<dyn Error>> {
        let presented = self.screencopy_clock_now();
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        let mut copied = 0usize;
        for mut request in std::mem::take(&mut self.screencopy.pending) {
            let Some(toplevel) = request.target.toplevel() else {
                retained.push(request);
                continue;
            };
            if copied >= MAX_TOPLEVEL_COPIES_PER_DISPATCH {
                retained.push(request);
                continue;
            }
            if !request.frame.is_alive() {
                request.frame.release_buffer(&request.buffer);
                continue;
            }
            if !request.buffer.resource().is_alive() {
                request.frame.fail(CaptureFailureReason::Unknown);
                continue;
            }

            let source = self
                .surfaces_by_id
                .get(&toplevel)
                .and_then(|surface| self.window_for_root_surface(surface))
                .and_then(|window| {
                    let output = self.output_for_geometry(self.window_geometry_target(&window))?;
                    Some((window, output.output.current_scale().fractional_scale()))
                });
            let result = source
                .ok_or_else(|| "toplevel capture source is no longer mapped".into())
                .and_then(|(window, scale): (Window, f64)| {
                    render_toplevel_capture(
                        renderer,
                        &window,
                        scale,
                        request.target,
                        &mut request.buffer,
                    )
                });
            request.frame.release_buffer(&request.buffer);
            match result {
                Ok(()) => {
                    request.frame.success(request.target, presented);
                    debug!(
                        toplevel,
                        width = request.target.size.w,
                        height = request.target.size.h,
                        "completed foreign-toplevel image capture"
                    );
                }
                Err(error) => {
                    request.frame.fail(CaptureFailureReason::Unknown);
                    warn!(
                        %error,
                        toplevel,
                        width = request.target.size.w,
                        height = request.target.size.h,
                        "foreign-toplevel image capture failed"
                    );
                }
            }
            copied += 1;
        }
        retained.append(&mut self.screencopy.pending);
        self.screencopy.pending = retained;
        if copied != 0 {
            renderer.cleanup_texture_cache()?;
            self.display_handle.flush_clients()?;
        }
        Ok(())
    }

    /// Publish the scene revision only after the matching page flip. A repair
    /// repaint retains its revision, including after an unpresented dirty
    /// generation was discarded by the output scheduler.
    pub(crate) fn screencopy_output_presented(&mut self, output: OutputId, revision: u64) {
        self.screencopy.output_revisions.insert(output, revision);
    }

    #[cfg(feature = "flutter")]
    fn capture_texture(
        &mut self,
        renderer: &mut GlesRenderer,
        source: CaptureTargetKind,
        size: Size<i32, Physical>,
    ) -> Result<Option<GlesTexture>, Box<dyn Error>> {
        let size: Size<i32, BufferCoords> = (size.w, size.h).into();
        let pool = self.screencopy.snapshots.entry(source).or_default();
        pool.retain_mut(|texture| texture.size() == size || !texture.is_unique_reference());
        for texture in pool.iter_mut() {
            if texture.is_unique_reference() {
                return Ok(Some(texture.clone()));
            }
        }
        if pool.len() >= MAX_IN_FLIGHT_SCREENCOPIES {
            return Ok(None);
        }
        let texture = <GlesRenderer as Offscreen<GlesTexture>>::create_buffer(
            renderer,
            Fourcc::Xrgb8888,
            size,
        )?;
        pool.push(texture.clone());
        Ok(Some(texture))
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn reap_capture_source_reads(&mut self) {
        reap_fence_owned(&mut self.screencopy.source_reads);
    }

    #[cfg(feature = "flutter")]
    fn track_capture_source_read(
        &mut self,
        texture: GlesTexture,
        ready: SyncPoint,
        owner: CaptureSourceOwner,
    ) {
        if ready.is_reached() {
            return;
        }
        let token = self.next_capture_token();
        let fence = ready.export();
        self.screencopy.source_reads.insert(
            token,
            FenceOwned {
                ready,
                resource: CaptureSourceRead {
                    _texture: texture,
                    owner,
                },
            },
        );
        if let Some(fence) = fence {
            match self.loop_handle.insert_source(
                Generic::new(fence, Interest::READ, Mode::Level),
                move |_, _, state: &mut RuntimeState| {
                    if let Some(frontend) = state.wayland.as_mut() {
                        frontend.reap_capture_source_reads();
                    }
                    Ok(PostAction::Remove)
                },
            ) {
                Ok(_) => return,
                Err(error) => {
                    warn!(%error, "could not watch capture source fence; polling instead")
                }
            }
        }
        if let Err(error) = self.loop_handle.insert_source(
            Timer::from_duration(Duration::from_millis(1)),
            move |_, _, state: &mut RuntimeState| {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.reap_capture_source_reads();
                    if frontend.screencopy.source_reads.contains_key(&token) {
                        return TimeoutAction::ToDuration(Duration::from_millis(1));
                    }
                }
                TimeoutAction::Drop
            },
        ) {
            // The main dispatch also polls. Never drop an unsignaled owner
            // just because registering a wakeup failed.
            warn!(%error, "could not register capture source fence timer");
        }
    }

    #[cfg(feature = "flutter")]
    fn next_capture_token(&mut self) -> u64 {
        let token = self.screencopy.next_token.max(1);
        self.screencopy.next_token = token.checked_add(1).unwrap_or(1);
        token
    }

    #[cfg(feature = "flutter")]
    fn submit_screencopy(
        &mut self,
        request: PendingScreencopy,
        stamp: CaptureStamp,
        source: GlesTexture,
        source_ready: SyncPoint,
        source_size: Size<i32, Physical>,
        presented: Duration,
    ) -> Option<PendingScreencopy> {
        let token = self.next_capture_token();
        let dmabuf = matches!(request.buffer, PendingBuffer::Dmabuf { .. });
        let destination = match &request.buffer {
            PendingBuffer::Shm(buffer) => CaptureDestination::Shm(buffer.clone()),
            PendingBuffer::Dmabuf { dmabuf, .. } => CaptureDestination::Dmabuf(dmabuf.clone()),
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        let job = CaptureJob {
            token,
            cancelled: cancelled.clone(),
            source,
            source_ready,
            source_size,
            target: request.target,
            destination,
        };
        let Some(worker) = self.screencopy.worker.as_ref() else {
            request.frame.release_buffer(&request.buffer);
            request.frame.fail(CaptureFailureReason::Unknown);
            return None;
        };
        match worker.try_submit(job) {
            Ok(()) => {
                self.screencopy.in_flight.insert(
                    token,
                    InFlightScreencopy {
                        request,
                        presented,
                        dmabuf,
                        stamp,
                        cancelled,
                    },
                );
                None
            }
            Err(TrySendError::Full(_)) => Some(request),
            Err(TrySendError::Disconnected(_)) => {
                request.frame.release_buffer(&request.buffer);
                request.frame.fail(CaptureFailureReason::Unknown);
                warn!("screencopy transfer worker stopped unexpectedly");
                None
            }
        }
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn process_toplevel_screencopies(
        &mut self,
        renderer: &mut GlesRenderer,
    ) -> Result<(), Box<dyn Error>> {
        self.reap_capture_source_reads();
        let presented = self.screencopy_clock_now();
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        let mut copied = 0;
        for request in std::mem::take(&mut self.screencopy.pending) {
            let Some(toplevel) = request.target.toplevel() else {
                retained.push(request);
                continue;
            };
            if copied >= MAX_TOPLEVEL_COPIES_PER_DISPATCH
                || self.screencopy.in_flight.len() >= MAX_IN_FLIGHT_SCREENCOPIES
                || self
                    .screencopy
                    .in_flight
                    .values()
                    .any(|capture| capture.request.target.toplevel() == Some(toplevel))
            {
                retained.push(request);
                continue;
            }
            if !request.frame.is_alive() {
                request.frame.release_buffer(&request.buffer);
                continue;
            }
            if !request.buffer.resource().is_alive() {
                request.frame.fail(CaptureFailureReason::Unknown);
                continue;
            }
            let result = (|| -> Result<_, Box<dyn Error>> {
                let (window, scale) = self
                    .surfaces_by_id
                    .get(&toplevel)
                    .and_then(|surface| self.window_for_root_surface(surface))
                    .and_then(|window| {
                        let output =
                            self.output_for_geometry(self.window_geometry_target(&window))?;
                        Some((window, output.output.current_scale().fractional_scale()))
                    })
                    .ok_or_else(|| {
                        io::Error::other("toplevel capture source is no longer mapped")
                    })?;
                let bbox: Rectangle<i32, Physical> = window.bbox().to_physical_precise_round(scale);
                if bbox.size != request.target.size {
                    return Err(io::Error::other("toplevel capture geometry changed").into());
                }
                let surface = window
                    .wl_surface()
                    .ok_or_else(|| io::Error::other("toplevel has no surface"))?;
                let elements: Vec<WaylandSurfaceRenderElement<GlesRenderer>> =
                    render_elements_from_surface_tree(
                        renderer,
                        &surface,
                        (-bbox.loc.x, -bbox.loc.y),
                        scale,
                        1.0,
                        Kind::Unspecified,
                    );
                let stamp = CaptureStamp {
                    target: request.target,
                    revision: CaptureRevision::Toplevel(
                        elements
                            .iter()
                            .map(|element| SurfaceCaptureStamp {
                                id: element.id().clone(),
                                commit: element.current_commit(),
                                geometry: element.geometry(scale.into()),
                                source: element.src(),
                                transform: element.transform(),
                                alpha: element.alpha(),
                            })
                            .collect(),
                    ),
                };
                if request
                    .history
                    .as_ref()
                    .is_some_and(|history| !history.needs_capture(&stamp))
                {
                    return Ok(None);
                }
                let Some(mut texture) =
                    self.capture_texture(renderer, request.target.kind, request.target.size)?
                else {
                    return Ok(None);
                };
                let mut framebuffer = renderer.bind(&mut texture)?;
                let damage = Rectangle::from_size(request.target.size);
                let mut frame =
                    renderer.render(&mut framebuffer, request.target.size, Transform::Normal)?;
                let drawn = frame
                    .clear(Color32F::new(0.0, 0.0, 0.0, 1.0), &[damage])
                    .and_then(|()| {
                        draw_render_elements(&mut frame, scale, &elements, &[damage]).map(|_| ())
                    });
                let ready = frame.finish()?;
                drop(framebuffer);
                self.track_capture_source_read(
                    texture.clone(),
                    ready.clone(),
                    CaptureSourceOwner::Toplevel {
                        _elements: elements,
                    },
                );
                drawn?;
                Ok(Some((texture, ready, stamp)))
            })();
            match result {
                Ok(Some((texture, ready, stamp))) => {
                    let size = request.target.size;
                    if let Some(request) =
                        self.submit_screencopy(request, stamp, texture, ready, size, presented)
                    {
                        retained.push(request);
                    }
                    copied += 1;
                }
                Ok(None) => retained.push(request),
                Err(error) => {
                    request.frame.release_buffer(&request.buffer);
                    request.frame.fail(CaptureFailureReason::Unknown);
                    warn!(%error, toplevel, "foreign-toplevel capture failed");
                }
            }
        }
        retained.append(&mut self.screencopy.pending);
        self.screencopy.pending = retained;
        if copied != 0 {
            renderer.cleanup_texture_cache()?;
            self.display_handle.flush_clients()?;
        }
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn process_screencopies(
        &mut self,
        renderer: &mut GlesRenderer,
        output_buffer: &Dmabuf,
        output: OutputId,
        presented: Duration,
        mut retain_source: impl FnMut() -> Result<OutputBufferLease, Box<dyn Error>>,
    ) -> Result<(), Box<dyn Error>> {
        self.reap_capture_source_reads();
        // At most one short read of the display pool per output. A slow GPU
        // defers capture instead of pinning a second display generation.
        if self.screencopy.source_reads.values().any(|read| matches!(read.resource.owner, CaptureSourceOwner::Output { output: source, .. } if source == output)) {
            return Ok(());
        }
        let output_size: Size<i32, Physical> = (
            i32::try_from(output_buffer.width())?,
            i32::try_from(output_buffer.height())?,
        )
            .into();
        let revision =
            CaptureRevision::Output(*self.screencopy.output_revisions.get(&output).unwrap_or(&0));
        let mut snapshot: Option<(GlesTexture, SyncPoint)> = None;
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        let mut queued = 0;
        for request in std::mem::take(&mut self.screencopy.pending) {
            let stamp = CaptureStamp {
                target: request.target,
                revision: revision.clone(),
            };
            if request.target.output() != Some(output)
                || queued >= MAX_COPIES_PER_PRESENTATION
                || self.screencopy.in_flight.len() >= MAX_IN_FLIGHT_SCREENCOPIES
                || request
                    .history
                    .as_ref()
                    .is_some_and(|history| !history.needs_capture(&stamp))
            {
                retained.push(request);
                continue;
            }
            if !request.frame.is_alive() {
                request.frame.release_buffer(&request.buffer);
                continue;
            }
            if !request.buffer.resource().is_alive() {
                request.frame.fail(CaptureFailureReason::Unknown);
                continue;
            }
            let result = (|| -> Result<_, Box<dyn Error>> {
                if snapshot.is_none() {
                    let Some(mut texture) = self.capture_texture(
                        renderer,
                        CaptureTargetKind::Output(output),
                        output_size,
                    )?
                    else {
                        return Ok(None);
                    };
                    let lease = retain_source()?;
                    let mut source = output_buffer.clone();
                    let source_framebuffer = renderer.bind(&mut source)?;
                    let mut framebuffer = renderer.bind(&mut texture)?;
                    let full = Rectangle::from_size(output_size);
                    let ready = renderer.blit(
                        &source_framebuffer,
                        &mut framebuffer,
                        full,
                        full,
                        TextureFilter::Nearest,
                    )?;
                    drop(framebuffer);
                    drop(source_framebuffer);
                    self.track_capture_source_read(
                        texture.clone(),
                        ready.clone(),
                        CaptureSourceOwner::Output {
                            output,
                            _buffer: output_buffer.clone(),
                            _lease: lease,
                        },
                    );
                    snapshot = Some((texture, ready));
                }
                Ok(snapshot.clone())
            })();
            match result {
                Ok(Some((texture, ready))) => {
                    if let Some(request) = self.submit_screencopy(
                        request,
                        stamp,
                        texture,
                        ready,
                        output_size,
                        presented,
                    ) {
                        retained.push(request);
                    }
                    queued += 1;
                }
                Ok(None) => retained.push(request),
                Err(error) => {
                    request.frame.release_buffer(&request.buffer);
                    request.frame.fail(CaptureFailureReason::Unknown);
                    warn!(%error, ?output, "could not snapshot screencopy source");
                }
            }
        }
        retained.append(&mut self.screencopy.pending);
        self.screencopy.pending = retained;
        self.display_handle.flush_clients()?;
        Ok(())
    }

    #[cfg(feature = "flutter")]
    fn finish_screencopy(&mut self, completion: CaptureCompletion) {
        let Some(capture) = self.screencopy.in_flight.remove(&completion.token) else {
            return;
        };
        let request = capture.request;
        let frame_alive = request.frame.is_alive();
        let buffer_alive = request.buffer.resource().is_alive();
        let target = request.target;
        let cancelled = capture.cancelled.load(Ordering::Acquire);
        let result = if cancelled {
            Err("screencopy target was cancelled".to_owned())
        } else if !frame_alive || !buffer_alive {
            Err("screencopy client buffer disappeared".to_owned())
        } else {
            match (completion.result, &request.buffer) {
                (Ok(CapturePayload::Shm), PendingBuffer::Shm(_)) => Ok(()),
                (Ok(CapturePayload::Dmabuf), PendingBuffer::Dmabuf { .. }) => Ok(()),
                (Ok(_), _) => Err("screencopy worker returned the wrong buffer kind".to_owned()),
                (Err(error), _) => Err(error),
            }
        };
        request.frame.release_buffer(&request.buffer);

        if frame_alive {
            match result {
                Ok(()) => {
                    if let Some(history) = &request.history {
                        history.completed(capture.stamp);
                    }
                    request.frame.success(target, capture.presented);
                    debug!(
                        output = ?target.output(),
                        width = target.size.w,
                        height = target.size.h,
                        dmabuf = capture.dmabuf,
                        transfer_ms = completion.elapsed.as_secs_f64() * 1_000.0,
                        "completed asynchronous screencopy"
                    );
                }
                Err(error) => {
                    request.frame.fail(CaptureFailureReason::Unknown);
                    if !cancelled {
                        warn!(
                            %error,
                            output = ?target.output(),
                            width = target.size.w,
                            height = target.size.h,
                            dmabuf = capture.dmabuf,
                            transfer_ms = completion.elapsed.as_secs_f64() * 1_000.0,
                            "asynchronous screencopy transfer failed"
                        );
                    }
                }
            }
        }
        if let Err(error) = self.display_handle.flush_clients() {
            warn!(%error, "failed to flush completed screencopy");
        }
    }

    pub(super) fn fail_screencopies_for_output(&mut self, output: OutputId) {
        self.screencopy.output_revisions.remove(&output);
        #[cfg(feature = "flutter")]
        self.screencopy
            .snapshots
            .remove(&CaptureTargetKind::Output(output));
        let mut failed = false;
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        for request in std::mem::take(&mut self.screencopy.pending) {
            if request.target.output() == Some(output) {
                failed = true;
                request.frame.release_buffer(&request.buffer);
                request.frame.fail(CaptureFailureReason::Unknown);
            } else {
                retained.push(request);
            }
        }
        self.screencopy.pending = retained;
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            if capture.request.target.output() == Some(output) {
                capture.cancelled.store(true, Ordering::Release);
                failed = true;
            }
        }
        if failed && let Err(error) = self.display_handle.flush_clients() {
            warn!(%error, ?output, "failed to flush cancelled screencopy");
        }
    }

    fn fail_screencopies_for_toplevel(&mut self, toplevel: u64) {
        #[cfg(feature = "flutter")]
        self.screencopy
            .snapshots
            .remove(&CaptureTargetKind::Toplevel(toplevel));
        let mut failed = false;
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        for request in std::mem::take(&mut self.screencopy.pending) {
            if request.target.toplevel() == Some(toplevel) {
                failed = true;
                request.frame.release_buffer(&request.buffer);
                request.frame.fail(CaptureFailureReason::Stopped);
            } else {
                retained.push(request);
            }
        }
        self.screencopy.pending = retained;
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            if capture.request.target.toplevel() == Some(toplevel) {
                capture.cancelled.store(true, Ordering::Release);
                failed = true;
            }
        }
        if failed && let Err(error) = self.display_handle.flush_clients() {
            warn!(%error, toplevel, "failed to flush cancelled toplevel captures");
        }
    }

    pub(super) fn fail_all_screencopies(&mut self) {
        let failed = !self.screencopy.pending.is_empty();
        for request in self.screencopy.pending.drain(..) {
            request.frame.release_buffer(&request.buffer);
            request.frame.fail(CaptureFailureReason::Unknown);
        }
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            capture.cancelled.store(true, Ordering::Release);
        }
        if failed && let Err(error) = self.display_handle.flush_clients() {
            warn!(%error, "failed to flush cancelled screencopies");
        }
    }
}

impl ImageCaptureSourceHandler for RuntimeState {}

impl OutputCaptureSourceHandler for RuntimeState {
    fn output_capture_source_state(&mut self) -> &mut OutputCaptureSourceState {
        &mut self
            .wayland
            .as_mut()
            .expect("output capture source dispatched without Wayland frontend")
            .screencopy
            .output_capture_source
    }

    fn output_source_created(&mut self, source: ImageCaptureSource, output: &Output) {
        source.user_data().insert_if_missing(|| output.downgrade());
    }
}

impl ForeignToplevelListHandler for RuntimeState {
    fn foreign_toplevel_list_state(&mut self) -> &mut ForeignToplevelListState {
        &mut self
            .wayland
            .as_mut()
            .expect("foreign toplevel list dispatched without Wayland frontend")
            .screencopy
            .foreign_toplevel_list
    }
}

impl ToplevelCaptureSourceHandler for RuntimeState {
    fn toplevel_capture_source_state(&mut self) -> &mut ToplevelCaptureSourceState {
        &mut self
            .wayland
            .as_mut()
            .expect("toplevel capture source dispatched without Wayland frontend")
            .screencopy
            .toplevel_capture_source
    }

    fn toplevel_source_created(
        &mut self,
        source: ImageCaptureSource,
        toplevel: ForeignToplevelHandle,
    ) {
        source
            .user_data()
            .insert_if_missing(|| toplevel.downgrade());
    }
}

impl ImageCopyCaptureHandler for RuntimeState {
    fn image_copy_capture_state(&mut self) -> &mut ImageCopyCaptureState {
        &mut self
            .wayland
            .as_mut()
            .expect("image copy capture dispatched without Wayland frontend")
            .screencopy
            .image_copy_capture
    }

    fn capture_constraints(&mut self, source: &ImageCaptureSource) -> Option<BufferConstraints> {
        self.wayland.as_ref()?.image_copy_constraints(source)
    }

    fn new_session(&mut self, session: ImageCopySession) {
        let Some(frontend) = self.wayland.as_mut() else {
            return;
        };
        frontend.screencopy.image_copy_capture.cleanup();
        frontend.screencopy.image_copy_sessions.push(session);
    }

    fn frame(&mut self, session: &ImageCopySessionRef, frame: ImageCopyFrame) {
        let Some(frontend) = self.wayland.as_mut() else {
            frame.fail(CaptureFailureReason::Unknown);
            return;
        };
        frontend.queue_image_copy(session, frame);
    }

    fn frame_aborted(&mut self, frame: ImageCopyFrameRef) {
        if let Some(frontend) = self.wayland.as_mut() {
            frontend.cancel_image_copy(&frame);
        }
    }

    fn session_destroyed(&mut self, session: ImageCopySessionRef) {
        if let Some(frontend) = self.wayland.as_mut() {
            #[cfg(feature = "flutter")]
            if let Some(target) =
                frontend.image_copy_target(&session.source(), session.draw_cursor())
            {
                frontend.screencopy.snapshots.remove(&target.kind);
            }
            frontend
                .screencopy
                .image_copy_sessions
                .retain(|owned| owned != &session);
            frontend.screencopy.image_copy_capture.cleanup();
        }
    }
}

impl GlobalDispatch<ZwlrScreencopyManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwlrScreencopyManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, CaptureHistory::default());
    }
}

impl Dispatch<ZwlrScreencopyManagerV1, CaptureHistory> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &ZwlrScreencopyManagerV1,
        request: zwlr_screencopy_manager_v1::Request,
        data: &CaptureHistory,
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        let Some(frontend) = state.wayland.as_mut() else {
            return;
        };
        match request {
            zwlr_screencopy_manager_v1::Request::CaptureOutput {
                frame,
                overlay_cursor,
                output,
            } => {
                let target = frontend.capture_target(&output, None, overlay_cursor != 0);
                let resource =
                    data_init.init(frame, ScreencopyFrameData::new(target, data.clone()));
                frontend.announce_screencopy_frame(&resource, target);
            }
            zwlr_screencopy_manager_v1::Request::CaptureOutputRegion {
                frame,
                overlay_cursor,
                output,
                x,
                y,
                width,
                height,
            } => {
                let region = Rectangle::new((x, y).into(), (width, height).into());
                let target = frontend.capture_target(&output, Some(region), overlay_cursor != 0);
                let resource =
                    data_init.init(frame, ScreencopyFrameData::new(target, data.clone()));
                frontend.announce_screencopy_frame(&resource, target);
            }
            zwlr_screencopy_manager_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<ZwlrScreencopyFrameV1, ScreencopyFrameData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwlrScreencopyFrameV1,
        request: zwlr_screencopy_frame_v1::Request,
        data: &ScreencopyFrameData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        let Some(frontend) = state.wayland.as_mut() else {
            return;
        };
        match request {
            zwlr_screencopy_frame_v1::Request::Copy { buffer } => {
                frontend.queue_screencopy(resource, data, buffer, false);
            }
            zwlr_screencopy_frame_v1::Request::CopyWithDamage { buffer } => {
                frontend.queue_screencopy(resource, data, buffer, true);
            }
            zwlr_screencopy_frame_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        resource: &ZwlrScreencopyFrameV1,
        _data: &ScreencopyFrameData,
    ) {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.cancel_screencopy(resource.id());
        }
    }
}
