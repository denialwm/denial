//! `zwlr-screencopy-unstable-v1` output capture.
//!
//! Each physical output scans out its own native Flutter raster target.
//! Requests are journaled by the Wayland dispatcher and fulfilled only after
//! the target output presents. This both makes that output buffer safe to read
//! and naturally paces screen recorders at the output refresh rate.

use std::error::Error;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use denial_core::topology::OutputId;
use smithay::backend::allocator::format::FormatSet;
use smithay::backend::allocator::{Buffer as AllocatorBuffer, Fourcc, dmabuf::Dmabuf};
use smithay::backend::renderer::gles::{GlesRenderer, GlesTexture};
use smithay::backend::renderer::{
    Bind, Blit, Color32F, ExportMem, Frame, Offscreen, Renderer, TextureFilter,
};
use smithay::output::Output;
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

use super::{RuntimeState, WaylandFrontend};

const PROTOCOL_VERSION: u32 = 3;
const BYTES_PER_PIXEL: i32 = 4;
const MAX_PENDING_SCREENCOPIES: usize = 64;
const MAX_COPIES_PER_PRESENTATION: usize = 4;

pub(crate) struct OutputCompositeSource {
    pub(crate) dmabuf: Dmabuf,
    pub(crate) destination: Rectangle<i32, Physical>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CaptureTarget {
    output: OutputId,
    /// Region within the output-local Flutter target, in top-left pixels.
    source: Rectangle<i32, Physical>,
    /// Client buffer size in the output's transformed physical pixels.
    size: Size<i32, Physical>,
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

#[derive(Debug)]
pub(super) struct ScreencopyManager {
    _global: GlobalId,
    pending: Vec<PendingScreencopy>,
    dmabuf_formats: FormatSet,
}

impl ScreencopyManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display
                .create_global::<RuntimeState, ZwlrScreencopyManagerV1, _>(PROTOCOL_VERSION, ()),
            pending: Vec::new(),
            dmabuf_formats: FormatSet::default(),
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

fn copy_to_shm(
    renderer: &mut GlesRenderer,
    atlas: &mut Dmabuf,
    atlas_size: Size<i32, Physical>,
    target: CaptureTarget,
    buffer: &WlBuffer,
) -> Result<(), Box<dyn Error>> {
    let source = framebuffer_source_rect(target.source, atlas_size)
        .ok_or_else(|| io::Error::other("capture source is outside the atlas"))?;
    let source_framebuffer = renderer.bind(atlas)?;

    if source.size == target.size {
        let mapping = renderer.copy_framebuffer(
            &source_framebuffer,
            as_buffer_rect(source),
            Fourcc::Xrgb8888,
        )?;
        let pixels = renderer.map_texture(&mapping)?;
        return copy_pixels_to_shm(buffer, pixels, target.size);
    }

    let texture_size: Size<i32, BufferCoords> = (target.size.w, target.size.h).into();
    let mut scaled = <GlesRenderer as Offscreen<GlesTexture>>::create_buffer(
        renderer,
        Fourcc::Xrgb8888,
        texture_size,
    )?;
    let mut scaled_framebuffer = renderer.bind(&mut scaled)?;
    let destination = Rectangle::new((0, 0).into(), target.size);
    renderer
        .blit(
            &source_framebuffer,
            &mut scaled_framebuffer,
            source,
            destination,
            TextureFilter::Linear,
        )?
        .wait()?;
    let mapping = renderer.copy_framebuffer(
        &scaled_framebuffer,
        as_buffer_rect(destination),
        Fourcc::Xrgb8888,
    )?;
    let pixels = renderer.map_texture(&mapping)?;
    copy_pixels_to_shm(buffer, pixels, target.size)
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
    let expected = usize::try_from(source.size.w)?
        .checked_mul(usize::try_from(source.size.h)?)
        .and_then(|pixels| pixels.checked_mul(BYTES_PER_PIXEL as usize))
        .ok_or_else(|| io::Error::other("capture payload size overflow"))?;
    if pixels.len() < expected {
        return Err(io::Error::other("renderer returned a short capture mapping").into());
    }
    Ok(pixels[..expected].to_vec())
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
    let source = framebuffer_source_rect(target.source, atlas_size)
        .ok_or_else(|| io::Error::other("capture source is outside the atlas"))?;
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

    pub(crate) fn process_screencopies(
        &mut self,
        renderer: &mut GlesRenderer,
        output_buffer: &mut Dmabuf,
        output: OutputId,
        presented: Duration,
    ) -> Result<(), Box<dyn Error>> {
        let output_size: Size<i32, Physical> = (
            i32::try_from(output_buffer.width())?,
            i32::try_from(output_buffer.height())?,
        )
            .into();
        let mut retained = Vec::with_capacity(self.screencopy.pending.len());
        let mut copied = 0usize;
        for mut request in std::mem::take(&mut self.screencopy.pending) {
            if request.target.output != output || copied >= MAX_COPIES_PER_PRESENTATION {
                retained.push(request);
                continue;
            }
            copied += 1;
            if !request.frame.is_alive() {
                request.buffer.release();
                continue;
            }
            if !request.buffer.resource().is_alive() {
                request.frame.failed();
                continue;
            }

            // Flutter owns the visible software cursor, so it is already in
            // the atlas. Keep the request bit for diagnostics until a
            // cursor-free Flutter layer can be captured independently.
            let _overlay_cursor = request.target.overlay_cursor;
            let dmabuf = matches!(request.buffer, PendingBuffer::Dmabuf { .. });
            let result = match &mut request.buffer {
                PendingBuffer::Shm(buffer) => {
                    copy_to_shm(renderer, output_buffer, output_size, request.target, buffer)
                }
                PendingBuffer::Dmabuf { dmabuf, .. } => {
                    copy_to_dmabuf(renderer, output_buffer, output_size, request.target, dmabuf)
                }
            };
            request.buffer.release();
            if let Err(error) = result {
                warn!(
                    %error,
                    ?output,
                    width = request.target.size.w,
                    height = request.target.size.h,
                    "screencopy transfer failed"
                );
                request.frame.failed();
                continue;
            }

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
            let seconds = presented.as_secs();
            request.frame.ready(
                (seconds >> 32) as u32,
                seconds as u32,
                presented.subsec_nanos(),
            );
            debug!(
                ?output,
                width = request.target.size.w,
                height = request.target.size.h,
                dmabuf,
                "completed screencopy"
            );
        }
        retained.append(&mut self.screencopy.pending);
        self.screencopy.pending = retained;
        self.display_handle.flush_clients()?;
        Ok(())
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
mod tests {
    use super::*;

    #[test]
    fn clips_logical_regions_and_projects_both_atlas_and_scanout_edges() {
        let target = project_capture_region(
            OutputId(7),
            Rectangle::new((100, 200).into(), (3840, 2160).into()),
            (1920, 1080).into(),
            (1920, 1080).into(),
            Some(Rectangle::new((-100, 100).into(), (1060, 540).into())),
            false,
        )
        .unwrap();

        assert_eq!(
            target.source,
            Rectangle::new((100, 400).into(), (1920, 1080).into())
        );
        assert_eq!(target.size, (960, 540).into());
    }

    #[test]
    fn rejects_empty_or_fully_clipped_capture_regions() {
        let source = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let scanout = Size::from((1920, 1080));
        let logical = Size::from((1920, 1080));
        assert!(
            project_capture_region(
                OutputId(1),
                source,
                scanout,
                logical,
                Some(Rectangle::new((50, 50).into(), (0, 100).into())),
                false,
            )
            .is_none()
        );
        assert!(
            project_capture_region(
                OutputId(1),
                source,
                scanout,
                logical,
                Some(Rectangle::new((2000, 0).into(), (100, 100).into())),
                false,
            )
            .is_none()
        );
    }

    #[test]
    fn validates_the_last_shm_row_without_overflow() {
        assert!(pool_range_is_valid(400, 0, 40, 10, 10));
        assert!(pool_range_is_valid(416, 16, 40, 10, 10));
        assert!(!pool_range_is_valid(415, 16, 40, 10, 10));
        assert!(!pool_range_is_valid(usize::MAX, -1, 40, 10, 10));
        assert!(!pool_range_is_valid(400, 0, -1, 10, 10));
    }

    #[test]
    fn framebuffer_sources_keep_atlas_top_left_coordinates() {
        let source = Rectangle::new((100, 200).into(), (640, 480).into());
        assert_eq!(
            framebuffer_source_rect(source, (1920, 1080).into()),
            Some(source)
        );
        assert_eq!(
            framebuffer_source_rect(
                Rectangle::new((1500, 700).into(), (640, 480).into()),
                (1920, 1080).into(),
            ),
            None
        );
    }
}
