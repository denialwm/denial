use std::error::Error;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};

use denial_core::topology::{AtlasPlan, OutputId};
use smithay::backend::allocator::Modifier;
use smithay::backend::allocator::gbm::GbmAllocator;
use smithay::backend::drm::DrmDeviceFd;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::utils::{Physical, Rectangle, Size};
use tracing::{info, warn};

use super::clipboard::ClipboardManager;
use super::flutter_runtime::FlutterRuntime;
use super::flutter_runtime::system_command::ScreenshotRequest;
use super::kms_state::ScreenshotBuffer;
use super::wayland_frontend::OutputCompositeSource;

const MAX_PENDING_SCREENSHOT_WRITES: usize = 2;
const BYTES_PER_PIXEL: usize = 4;

struct ScreenshotJob {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
}

struct ScreenshotSelection {
    request_id: u64,
    target_output: OutputId,
    atlas: AtlasPlan,
    buffer: ScreenshotBuffer,
    prepared: bool,
    texture_id: Option<i64>,
}

pub(super) struct ScreenshotManager {
    sender: Option<SyncSender<ScreenshotJob>>,
    worker: Option<JoinHandle<()>>,
    selection: Option<ScreenshotSelection>,
    next_request_id: u64,
}

impl ScreenshotManager {
    pub(super) fn new(clipboard: ClipboardManager) -> io::Result<Self> {
        let (sender, receiver) = mpsc::sync_channel(MAX_PENDING_SCREENSHOT_WRITES);
        let worker = thread::Builder::new()
            .name("denial-screenshot-writer".into())
            .spawn(move || {
                while let Ok(job) = receiver.recv() {
                    match write_png(job) {
                        Ok(output) => {
                            info!(path = %output.path.display(), "saved screenshot");
                            match clipboard.set_image_png(output.png) {
                                Ok(item_id) => {
                                    info!(item_id, "published screenshot to the clipboard")
                                }
                                Err(error) => {
                                    warn!(?error, "could not publish screenshot to the clipboard")
                                }
                            }
                        }
                        Err(error) => warn!(%error, "could not save screenshot"),
                    }
                }
            })?;
        Ok(Self {
            sender: Some(sender),
            worker: Some(worker),
            selection: None,
            next_request_id: 1,
        })
    }

    pub(super) fn begin_selection(
        &mut self,
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        target_output: OutputId,
        atlas: AtlasPlan,
        modifier: Modifier,
    ) -> Result<Option<u64>, Box<dyn Error>> {
        if self.selection.is_some() {
            return Ok(None);
        }
        let buffer = ScreenshotBuffer::allocate(allocator, atlas.pixel_size, modifier)?;
        let request_id = self.next_request_id.max(1);
        self.next_request_id = request_id.checked_add(1).unwrap_or(1);
        self.selection = Some(ScreenshotSelection {
            request_id,
            target_output,
            atlas,
            buffer,
            prepared: false,
            texture_id: None,
        });
        Ok(Some(request_id))
    }

    pub(super) fn prepared(&mut self, request_id: u64) -> bool {
        let Some(selection) = self.selection.as_mut() else {
            return false;
        };
        if selection.request_id != request_id
            || selection.prepared
            || selection.texture_id.is_some()
        {
            return false;
        }
        selection.prepared = true;
        true
    }

    pub(super) fn capture_prepared_frame(
        &mut self,
        renderer: &mut GlesRenderer,
        runtime: &mut FlutterRuntime,
        output: OutputId,
        sources: &mut [OutputCompositeSource],
    ) -> Result<Option<(u64, i64)>, Box<dyn Error>> {
        let Some(selection) = self.selection.as_mut() else {
            return Ok(None);
        };
        if selection.target_output != output
            || selection.texture_id.is_some()
            || !selection.prepared
        {
            return Ok(None);
        }
        let atlas_size = atlas_physical_size(&selection.atlas)?;
        super::wayland_frontend::compose_output_targets_to_atlas(
            renderer,
            sources,
            atlas_size,
            &mut selection.buffer.dmabuf,
        )?;
        let texture_id = runtime
            .register_screenshot_texture(selection.buffer.dmabuf.clone(), selection.request_id)?;
        selection.texture_id = Some(texture_id);
        info!(
            request_id = selection.request_id,
            texture_id,
            width = selection.atlas.pixel_size.width,
            height = selection.atlas.pixel_size.height,
            "froze the screenshot selection canvas"
        );
        Ok(Some((selection.request_id, texture_id)))
    }

    pub(super) fn capture_live(
        &self,
        renderer: &mut GlesRenderer,
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        atlas: &AtlasPlan,
        modifier: Modifier,
        sources: &mut [OutputCompositeSource],
        request: ScreenshotRequest,
    ) -> Result<(), Box<dyn Error>> {
        if request.request_id.is_some() {
            return Err(io::Error::other("region capture requires a frozen screenshot").into());
        }
        let source = project_request(request, atlas)
            .ok_or_else(|| io::Error::other("screenshot region is outside the canvas"))?;
        let atlas_size = atlas_physical_size(atlas)?;
        let mut buffer = ScreenshotBuffer::allocate(allocator, atlas.pixel_size, modifier)?;
        super::wayland_frontend::compose_output_targets_to_atlas(
            renderer,
            sources,
            atlas_size,
            &mut buffer.dmabuf,
        )?;
        let pixels = super::wayland_frontend::copy_atlas_region_to_memory(
            renderer,
            &mut buffer.dmabuf,
            atlas_size,
            source,
        )?;
        self.queue_job(ScreenshotJob {
            pixels,
            width: u32::try_from(source.size.w)?,
            height: u32::try_from(source.size.h)?,
        })
    }

    pub(super) fn finish_selection(
        &mut self,
        renderer: &mut GlesRenderer,
        runtime: &mut FlutterRuntime,
        request: ScreenshotRequest,
    ) -> Result<bool, Box<dyn Error>> {
        let Some(request_id) = request.request_id.map(|request_id| request_id.get()) else {
            return Ok(false);
        };
        let Some(selection) = self.selection.as_ref() else {
            return Ok(false);
        };
        if selection.request_id != request_id || selection.texture_id.is_none() {
            return Ok(false);
        }

        let mut selection = self
            .selection
            .take()
            .expect("matching screenshot selection disappeared");
        let capture_result = (|| {
            let source = project_request(request, &selection.atlas).ok_or_else(|| {
                io::Error::other("screenshot region is outside the frozen canvas")
            })?;
            let pixels = super::wayland_frontend::copy_atlas_region_to_memory(
                renderer,
                &mut selection.buffer.dmabuf,
                atlas_physical_size(&selection.atlas)?,
                source,
            )?;
            self.queue_job(ScreenshotJob {
                pixels,
                width: u32::try_from(source.size.w)?,
                height: u32::try_from(source.size.h)?,
            })
        })();
        let teardown_result = teardown_selection(runtime, &selection);
        capture_result?;
        teardown_result?;
        Ok(true)
    }

    pub(super) fn cancel_selection(
        &mut self,
        runtime: &mut FlutterRuntime,
        request_id: Option<u64>,
    ) -> Result<Option<u64>, Box<dyn Error>> {
        let Some(selection) = self.selection.as_ref() else {
            return Ok(None);
        };
        if request_id.is_some_and(|request_id| request_id != selection.request_id) {
            return Ok(None);
        }
        let selection = self
            .selection
            .take()
            .expect("matching screenshot selection disappeared");
        teardown_selection(runtime, &selection)?;
        Ok(Some(selection.request_id))
    }

    pub(super) fn target_output(&self) -> Option<OutputId> {
        self.selection
            .as_ref()
            .map(|selection| selection.target_output)
    }

    pub(super) fn request_id(&self) -> Option<u64> {
        self.selection
            .as_ref()
            .map(|selection| selection.request_id)
    }

    pub(super) fn topology_epoch(&self) -> Option<u64> {
        self.selection
            .as_ref()
            .map(|selection| selection.atlas.topology_epoch)
    }

    fn queue_job(&self, job: ScreenshotJob) -> Result<(), Box<dyn Error>> {
        let Some(sender) = self.sender.as_ref() else {
            return Err(io::Error::other("screenshot writer has stopped").into());
        };
        match sender.try_send(job) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                warn!(
                    limit = MAX_PENDING_SCREENSHOT_WRITES,
                    "dropped screenshot because the writer queue is full"
                );
                Ok(())
            }
            Err(TrySendError::Disconnected(_)) => {
                Err(io::Error::other("screenshot writer disconnected").into())
            }
        }
    }
}

fn teardown_selection(
    runtime: &mut FlutterRuntime,
    selection: &ScreenshotSelection,
) -> Result<(), Box<dyn Error>> {
    runtime.cancel_screenshot_frame(selection.request_id);
    if let Some(texture_id) = selection.texture_id {
        runtime.unregister_screenshot_texture(texture_id)?;
    }
    Ok(())
}

fn atlas_physical_size(atlas: &AtlasPlan) -> Result<Size<i32, Physical>, Box<dyn Error>> {
    Ok((
        i32::try_from(atlas.pixel_size.width)?,
        i32::try_from(atlas.pixel_size.height)?,
    )
        .into())
}

impl Drop for ScreenshotManager {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            warn!("screenshot writer panicked during shutdown");
        }
    }
}

fn project_request(
    request: ScreenshotRequest,
    atlas: &AtlasPlan,
) -> Option<Rectangle<i32, Physical>> {
    let (logical_width, logical_height) = atlas.logical_size;
    if logical_width <= 0.0 || logical_height <= 0.0 {
        return None;
    }
    let (x, y, width, height) = request
        .region
        .map_or((0.0, 0.0, logical_width, logical_height), |region| {
            (region.x, region.y, region.width, region.height)
        });
    let left = x.clamp(0.0, logical_width);
    let top = y.clamp(0.0, logical_height);
    let right = (x + width).clamp(0.0, logical_width);
    let bottom = (y + height).clamp(0.0, logical_height);
    if right <= left || bottom <= top {
        return None;
    }

    let pixel_width = f64::from(atlas.pixel_size.width);
    let pixel_height = f64::from(atlas.pixel_size.height);
    let project_x = |edge: f64| (edge * pixel_width / logical_width).round() as i64;
    let project_y = |edge: f64| (edge * pixel_height / logical_height).round() as i64;
    let pixel_left = project_x(left).clamp(0, i64::from(atlas.pixel_size.width));
    let pixel_top = project_y(top).clamp(0, i64::from(atlas.pixel_size.height));
    let pixel_right = project_x(right).clamp(0, i64::from(atlas.pixel_size.width));
    let pixel_bottom = project_y(bottom).clamp(0, i64::from(atlas.pixel_size.height));
    let width = pixel_right.checked_sub(pixel_left)?.max(1);
    let height = pixel_bottom.checked_sub(pixel_top)?.max(1);
    Some(Rectangle::new(
        (
            i32::try_from(pixel_left).ok()?,
            i32::try_from(pixel_top).ok()?,
        )
            .into(),
        (i32::try_from(width).ok()?, i32::try_from(height).ok()?).into(),
    ))
}

struct WrittenScreenshot {
    path: PathBuf,
    png: Vec<u8>,
}

struct ScreenshotPngSink {
    file: BufWriter<File>,
    clipboard: Vec<u8>,
}

impl Write for ScreenshotPngSink {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let written = self.file.write(data)?;
        self.clipboard.extend_from_slice(&data[..written]);
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

fn write_png(mut job: ScreenshotJob) -> Result<WrittenScreenshot, Box<dyn Error + Send + Sync>> {
    let expected = usize::try_from(job.width)?
        .checked_mul(usize::try_from(job.height)?)
        .and_then(|pixels| pixels.checked_mul(BYTES_PER_PIXEL))
        .ok_or_else(|| io::Error::other("screenshot payload size overflow"))?;
    if job.pixels.len() != expected {
        return Err(io::Error::other("screenshot payload has the wrong size").into());
    }

    // DRM XRGB8888 is B, G, R, X in little-endian memory. PNG expects RGBA.
    for pixel in job.pixels.as_chunks_mut::<BYTES_PER_PIXEL>().0 {
        pixel.swap(0, 2);
        pixel[3] = u8::MAX;
    }

    let directory = screenshot_directory()?;
    fs::create_dir_all(&directory)?;
    let (file, path) = create_screenshot_file(&directory)?;
    let mut sink = ScreenshotPngSink {
        file: BufWriter::new(file),
        clipboard: Vec::new(),
    };
    {
        let mut encoder = png::Encoder::new(&mut sink, job.width, job.height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header()?;
        writer.write_image_data(&job.pixels)?;
        writer.finish()?;
    }
    sink.flush()?;
    Ok(WrittenScreenshot {
        path,
        png: sink.clipboard,
    })
}

fn screenshot_directory() -> io::Result<PathBuf> {
    if let Some(directory) = std::env::var_os("DENIAL_SCREENSHOT_DIR")
        && !directory.is_empty()
    {
        return Ok(PathBuf::from(directory));
    }
    let home = std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"))?;
    Ok(PathBuf::from(home).join("Pictures").join("Screenshots"))
}

fn create_screenshot_file(directory: &Path) -> io::Result<(File, PathBuf)> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?;
    let stem = format!("Screenshot-{}-{:03}", now.as_secs(), now.subsec_millis());
    for suffix in 0..100u8 {
        let suffix = (suffix != 0).then(|| format!("-{suffix}"));
        let name = OsString::from(format!(
            "{}{suffix}.png",
            stem,
            suffix = suffix.as_deref().unwrap_or_default()
        ));
        let path = directory.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((file, path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a unique screenshot filename",
    ))
}
