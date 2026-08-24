//! `zwlr-screencopy-unstable-v1` output capture.
//!
//! Each physical output scans out its own native Flutter raster target.
//! Requests are journaled by the Wayland dispatcher and fulfilled only after
//! the target output presents. This both makes that output buffer safe to read
//! and naturally paces screen recorders at the output refresh rate.

#[cfg(feature = "flutter")]
use std::collections::HashMap;
use std::error::Error;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "flutter")]
use std::sync::mpsc::{self, SyncSender, TrySendError};
#[cfg(feature = "flutter")]
use std::thread::{self, JoinHandle};
use std::time::Duration;
#[cfg(feature = "flutter")]
use std::time::Instant;

use denial_core::topology::OutputId;
use smithay::backend::allocator::format::FormatSet;
use smithay::backend::allocator::{Buffer as AllocatorBuffer, Fourcc, dmabuf::Dmabuf};
#[cfg(feature = "flutter")]
use smithay::backend::egl::EGLContext;
use smithay::backend::renderer::gles::{GlesRenderer, GlesTexture};
use smithay::backend::renderer::{
    Bind, Blit, Color32F, ExportMem, Frame, ImportDma, Offscreen, Renderer, TextureFilter,
};
use smithay::output::Output;
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::channel::{Event as ChannelEvent, Sender, channel};
use smithay::reexports::wayland_protocols_wlr::screencopy::v1::server::{
    zwlr_screencopy_frame_v1::{self, ZwlrScreencopyFrameV1},
    zwlr_screencopy_manager_v1::{self, ZwlrScreencopyManagerV1},
};
use smithay::reexports::wayland_server::backend::{GlobalId, ObjectId};
use smithay::reexports::wayland_server::protocol::{
    wl_buffer::WlBuffer, wl_output::WlOutput, wl_shm,
};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};
use smithay::utils::{Buffer as BufferCoords, Logical, Physical, Rectangle, Size, Transform};
use smithay::wayland::dmabuf::get_dmabuf;
use smithay::wayland::shm::{with_buffer_contents, with_buffer_contents_mut};
use tracing::{debug, warn};

#[cfg(feature = "flutter")]
use super::super::{egl_context, flutter_runtime::OutputBufferLease};
use super::{RuntimeState, WaylandFrontend};

const PROTOCOL_VERSION: u32 = 3;
const BYTES_PER_PIXEL: i32 = 4;
const MAX_PENDING_SCREENCOPIES: usize = 64;
const MAX_COPIES_PER_PRESENTATION: usize = 4;
#[cfg(feature = "flutter")]
const MAX_IN_FLIGHT_SCREENCOPIES: usize = 4;

pub(crate) struct OutputCompositeSource {
    pub(crate) dmabuf: Dmabuf,
    pub(crate) destination: Rectangle<i32, Physical>,
    pub(crate) transform: Transform,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CaptureTarget {
    output: OutputId,
    /// Region within the output-local Flutter target, in top-left pixels.
    source: Rectangle<i32, Physical>,
    /// Client buffer size in the output's transformed physical pixels.
    size: Size<i32, Physical>,
    /// Complete output extent in transformed physical pixels.
    output_size: Size<i32, Physical>,
    /// Mapping Flutter applied from this logical pixel space into scanout.
    transform: Transform,
    overlay_cursor: bool,
}

#[derive(Debug)]
pub(super) struct ScreencopyFrameData {
    target: Option<CaptureTarget>,
    used: AtomicBool,
}

impl ScreencopyFrameData {
    fn new(target: Option<CaptureTarget>) -> Self {
        Self {
            used: AtomicBool::new(target.is_none()),
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
struct PendingScreencopy {
    frame: ZwlrScreencopyFrameV1,
    target: CaptureTarget,
    buffer: PendingBuffer,
    with_damage: bool,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
enum CaptureDestination {
    Shm,
    Dmabuf(Dmabuf),
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct CaptureJob {
    token: u64,
    source: Dmabuf,
    source_size: Size<i32, Physical>,
    target: CaptureTarget,
    destination: CaptureDestination,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
enum CapturePayload {
    Shm(Vec<u8>),
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
    _source_lease: OutputBufferLease,
    cancelled: bool,
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct CaptureWorker {
    jobs: Option<SyncSender<CaptureJob>>,
    worker: Option<JoinHandle<()>>,
}

#[cfg(feature = "flutter")]
impl CaptureWorker {
    fn start(context: EGLContext, completions: Sender<CaptureCompletion>) -> io::Result<Self> {
        let (jobs, receiver) = mpsc::sync_channel::<CaptureJob>(MAX_IN_FLIGHT_SCREENCOPIES);
        let (ready, initialized) = mpsc::sync_channel::<Result<(), String>>(1);
        let worker = thread::Builder::new()
            .name("denial-screencopy".into())
            .spawn(move || {
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
                while let Ok(mut job) = receiver.recv() {
                    let started = Instant::now();
                    let result = match &mut job.destination {
                        CaptureDestination::Shm => capture_to_memory(
                            &mut renderer,
                            &mut job.source,
                            job.source_size,
                            job.target,
                        )
                        .map(CapturePayload::Shm),
                        CaptureDestination::Dmabuf(destination) => copy_to_dmabuf(
                            &mut renderer,
                            &mut job.source,
                            job.source_size,
                            job.target,
                            &mut *destination,
                        )
                        .map(|()| CapturePayload::Dmabuf),
                    }
                    .map_err(|error| error.to_string());
                    if completions
                        .send(CaptureCompletion {
                            token: job.token,
                            elapsed: started.elapsed(),
                            result,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            })?;
        match initialized.recv() {
            Ok(Ok(())) => Ok(Self {
                jobs: Some(jobs),
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
            .try_send(job)
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

pub(super) struct ScreencopyManager {
    _global: GlobalId,
    pending: Vec<PendingScreencopy>,
    dmabuf_formats: FormatSet,
    #[cfg(feature = "flutter")]
    worker: Option<CaptureWorker>,
    #[cfg(feature = "flutter")]
    in_flight: HashMap<u64, InFlightScreencopy>,
    #[cfg(feature = "flutter")]
    next_token: u64,
}

impl ScreencopyManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display
                .create_global::<RuntimeState, ZwlrScreencopyManagerV1, _>(PROTOCOL_VERSION, ()),
            pending: Vec::new(),
            dmabuf_formats: FormatSet::default(),
            #[cfg(feature = "flutter")]
            worker: None,
            #[cfg(feature = "flutter")]
            in_flight: HashMap::new(),
            #[cfg(feature = "flutter")]
            next_token: 1,
        }
    }
}

#[cfg(feature = "flutter")]
impl Drop for ScreencopyManager {
    fn drop(&mut self) {
        // Source DMA-BUF leases must outlive every worker access. Join the
        // renderer before Rust drops the in-flight request table and its RAII
        // leases.
        if let Some(mut worker) = self.worker.take() {
            worker.shutdown();
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
    scanout_size: Size<i32, Physical>,
    logical_size: Size<i32, Logical>,
    requested: Option<Rectangle<i32, Logical>>,
    transform: Transform,
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
    let buffer_left = scaled_edge(left, logical_size.w, scanout_size.w)?;
    let buffer_top = scaled_edge(top, logical_size.h, scanout_size.h)?;
    let buffer_right = scaled_edge(right, logical_size.w, scanout_size.w)?;
    let buffer_bottom = scaled_edge(bottom, logical_size.h, scanout_size.h)?;

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
        output,
        source,
        size,
        output_size: scanout_size,
        transform,
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

fn capture_to_memory(
    renderer: &mut GlesRenderer,
    atlas: &mut Dmabuf,
    atlas_size: Size<i32, Physical>,
    target: CaptureTarget,
) -> Result<Vec<u8>, Box<dyn Error>> {
    let source = capture_source_rect(target, atlas_size)
        .ok_or_else(|| io::Error::other("capture source is outside the atlas"))?;

    if target.transform == Transform::Normal && source.size == target.size {
        let source_framebuffer = renderer.bind(atlas)?;
        let mapping = renderer.copy_framebuffer(
            &source_framebuffer,
            as_buffer_rect(source),
            Fourcc::Xrgb8888,
        )?;
        let pixels = renderer.map_texture(&mapping)?;
        return capture_pixels_to_vec(pixels, target.size);
    }

    let texture_size: Size<i32, BufferCoords> = (target.size.w, target.size.h).into();
    let mut scaled = <GlesRenderer as Offscreen<GlesTexture>>::create_buffer(
        renderer,
        Fourcc::Xrgb8888,
        texture_size,
    )?;
    let mut scaled_framebuffer = renderer.bind(&mut scaled)?;
    let destination = Rectangle::new((0, 0).into(), target.size);
    if target.transform == Transform::Normal {
        let source_framebuffer = renderer.bind(atlas)?;
        renderer
            .blit(
                &source_framebuffer,
                &mut scaled_framebuffer,
                source,
                destination,
                TextureFilter::Linear,
            )?
            .wait()?;
    } else {
        let texture = renderer.import_dmabuf(atlas, None)?;
        let mut frame = renderer.render(&mut scaled_framebuffer, target.size, Transform::Normal)?;
        frame.render_texture_from_to(
            &texture,
            as_buffer_rect(source).to_f64(),
            destination,
            &[destination],
            &[destination],
            target.transform,
            1.0,
            None,
            &[],
        )?;
        frame.finish()?.wait()?;
    }
    let mapping = renderer.copy_framebuffer(
        &scaled_framebuffer,
        as_buffer_rect(destination),
        Fourcc::Xrgb8888,
    )?;
    let pixels = renderer.map_texture(&mapping)?;
    capture_pixels_to_vec(pixels, target.size)
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
        frame.render_texture_from_to(
            &texture,
            source_rect,
            source.destination,
            &[source.destination],
            &[source.destination],
            source.transform,
            1.0,
            None,
            &[],
        )?;
        frame.finish()?.wait()?;
    }
    Ok(())
}

fn copy_to_dmabuf(
    renderer: &mut GlesRenderer,
    atlas: &mut Dmabuf,
    atlas_size: Size<i32, Physical>,
    target: CaptureTarget,
    destination: &mut Dmabuf,
) -> Result<(), Box<dyn Error>> {
    let source = capture_source_rect(target, atlas_size)
        .ok_or_else(|| io::Error::other("capture source is outside the atlas"))?;
    if target.transform != Transform::Normal {
        let texture = renderer.import_dmabuf(atlas, None)?;
        let mut destination_framebuffer = renderer.bind(destination)?;
        let destination_rect = Rectangle::new((0, 0).into(), target.size);
        let mut frame =
            renderer.render(&mut destination_framebuffer, target.size, Transform::Normal)?;
        frame.render_texture_from_to(
            &texture,
            as_buffer_rect(source).to_f64(),
            destination_rect,
            &[destination_rect],
            &[destination_rect],
            target.transform,
            1.0,
            None,
            &[],
        )?;
        frame.finish()?.wait()?;
        return Ok(());
    }
    let source_framebuffer = renderer.bind(atlas)?;
    let mut destination_framebuffer = renderer.bind(destination)?;
    renderer
        .blit(
            &source_framebuffer,
            &mut destination_framebuffer,
            source,
            Rectangle::new((0, 0).into(), target.size),
            if source.size == target.size {
                TextureFilter::Nearest
            } else {
                TextureFilter::Linear
            },
        )?
        .wait()?;
    Ok(())
}

impl WaylandFrontend {
    fn capture_target(
        &self,
        output: &WlOutput,
        requested: Option<Rectangle<i32, Logical>>,
        overlay_cursor: bool,
    ) -> Option<CaptureTarget> {
        let output = Output::from_resource(output)?;
        let entry = self
            .outputs
            .iter()
            .find(|entry| entry.output == output && entry.powered)?;
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
            frame: frame.clone(),
            target,
            buffer,
            with_damage,
        });
    }

    fn cancel_screencopy(&mut self, frame: ObjectId) {
        self.screencopy.pending.retain(|request| {
            let keep = request.frame.id() != frame;
            if !keep {
                request.buffer.release();
            }
            keep
        });
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

    pub(super) fn set_screencopy_dmabuf_formats(&mut self, formats: FormatSet) {
        self.screencopy.dmabuf_formats = formats;
    }

    pub(crate) fn has_pending_screencopy_for_output(&self, output: OutputId) -> bool {
        self.screencopy
            .pending
            .iter()
            .any(|request| request.target.output == output)
    }

    pub(crate) fn screencopy_clock_now(&self) -> Duration {
        self.presentation.monotonic_now()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn process_screencopies(
        &mut self,
        output_buffer: &Dmabuf,
        output: OutputId,
        presented: Duration,
        mut retain_source: impl FnMut() -> Result<OutputBufferLease, Box<dyn Error>>,
    ) -> Result<(), Box<dyn Error>> {
        let output_size: Size<i32, Physical> = (
            i32::try_from(output_buffer.width())?,
            i32::try_from(output_buffer.height())?,
        )
            .into();
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        let mut queued = 0usize;
        for request in std::mem::take(&mut self.screencopy.pending) {
            if request.target.output != output
                || queued >= MAX_COPIES_PER_PRESENTATION
                || self.screencopy.in_flight.len() >= MAX_IN_FLIGHT_SCREENCOPIES
            {
                retained.push(request);
                continue;
            }
            if !request.frame.is_alive() {
                request.buffer.release();
                continue;
            }
            if !request.buffer.resource().is_alive() {
                request.frame.failed();
                continue;
            }

            // Flutter owns the visible software cursor, so it is already in
            // the output target. Keep the request bit for diagnostics until a
            // cursor-free Flutter layer can be captured independently.
            let _overlay_cursor = request.target.overlay_cursor;
            let dmabuf = matches!(request.buffer, PendingBuffer::Dmabuf { .. });
            let destination = match &request.buffer {
                PendingBuffer::Shm(_) => CaptureDestination::Shm,
                PendingBuffer::Dmabuf { dmabuf, .. } => CaptureDestination::Dmabuf(dmabuf.clone()),
            };
            let source_lease = match retain_source() {
                Ok(lease) => lease,
                Err(error) => {
                    request.buffer.release();
                    request.frame.failed();
                    warn!(%error, ?output, "could not retain screencopy source buffer");
                    continue;
                }
            };
            let token = self.screencopy.next_token.max(1);
            self.screencopy.next_token = token.checked_add(1).unwrap_or(1);
            let job = CaptureJob {
                token,
                source: output_buffer.clone(),
                source_size: output_size,
                target: request.target,
                destination,
            };
            let Some(worker) = self.screencopy.worker.as_ref() else {
                request.buffer.release();
                request.frame.failed();
                return Err("screencopy transfer worker is unavailable".into());
            };
            match worker.try_submit(job) {
                Ok(()) => {
                    self.screencopy.in_flight.insert(
                        token,
                        InFlightScreencopy {
                            request,
                            presented,
                            dmabuf,
                            _source_lease: source_lease,
                            cancelled: false,
                        },
                    );
                    queued += 1;
                }
                Err(TrySendError::Full(_)) => retained.push(request),
                Err(TrySendError::Disconnected(_)) => {
                    request.buffer.release();
                    request.frame.failed();
                    warn!(?output, "screencopy transfer worker stopped unexpectedly");
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
        let result = if capture.cancelled {
            Err("screencopy target was cancelled".to_owned())
        } else if !frame_alive || !buffer_alive {
            Err("screencopy client buffer disappeared".to_owned())
        } else {
            match (completion.result, &request.buffer) {
                (Ok(CapturePayload::Shm(pixels)), PendingBuffer::Shm(buffer)) => {
                    copy_pixels_to_shm(buffer, &pixels, request.target.size)
                        .map_err(|error| error.to_string())
                }
                (Ok(CapturePayload::Dmabuf), PendingBuffer::Dmabuf { .. }) => Ok(()),
                (Ok(_), _) => Err("screencopy worker returned the wrong buffer kind".to_owned()),
                (Err(error), _) => Err(error),
            }
        };
        request.buffer.release();

        if frame_alive {
            match result {
                Ok(()) => {
                    request
                        .frame
                        .flags(zwlr_screencopy_frame_v1::Flags::empty());
                    if request.with_damage {
                        request.frame.damage(
                            0,
                            0,
                            u32::try_from(request.target.size.w).unwrap_or_default(),
                            u32::try_from(request.target.size.h).unwrap_or_default(),
                        );
                    }
                    let seconds = capture.presented.as_secs();
                    request.frame.ready(
                        (seconds >> 32) as u32,
                        seconds as u32,
                        capture.presented.subsec_nanos(),
                    );
                    debug!(
                        output = ?request.target.output,
                        width = request.target.size.w,
                        height = request.target.size.h,
                        dmabuf = capture.dmabuf,
                        transfer_ms = completion.elapsed.as_secs_f64() * 1_000.0,
                        "completed asynchronous screencopy"
                    );
                }
                Err(error) => {
                    request.frame.failed();
                    if !capture.cancelled {
                        warn!(
                            %error,
                            output = ?request.target.output,
                            width = request.target.size.w,
                            height = request.target.size.h,
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
        let mut failed = false;
        self.screencopy.pending.retain(|request| {
            let keep = request.target.output != output;
            if !keep {
                failed = true;
                request.buffer.release();
                if request.frame.is_alive() {
                    request.frame.failed();
                }
            }
            keep
        });
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            if capture.request.target.output == output {
                capture.cancelled = true;
                failed = true;
            }
        }
        if failed && let Err(error) = self.display_handle.flush_clients() {
            warn!(%error, ?output, "failed to flush cancelled screencopy");
        }
    }

    pub(super) fn fail_all_screencopies(&mut self) {
        let failed = !self.screencopy.pending.is_empty();
        for request in self.screencopy.pending.drain(..) {
            request.buffer.release();
            if request.frame.is_alive() {
                request.frame.failed();
            }
        }
        #[cfg(feature = "flutter")]
        for capture in self.screencopy.in_flight.values_mut() {
            capture.cancelled = true;
        }
        if failed && let Err(error) = self.display_handle.flush_clients() {
            warn!(%error, "failed to flush cancelled screencopies");
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
        data_init.init(resource, ());
    }
}

impl Dispatch<ZwlrScreencopyManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &ZwlrScreencopyManagerV1,
        request: zwlr_screencopy_manager_v1::Request,
        _data: &(),
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
                let resource = data_init.init(frame, ScreencopyFrameData::new(target));
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
                let resource = data_init.init(frame, ScreencopyFrameData::new(target));
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

#[cfg(test)]
#[path = "screencopy/tests.rs"]
mod tests;
