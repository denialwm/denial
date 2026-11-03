//! Private offscreen harness for the real destination-owned worker path.
//! Timings establish buffer readiness, not KMS presentation or Flutter raster cost.
use super::*;
use smithay::backend::allocator::{
    Format,
    dmabuf::AsDmabuf,
    gbm::{GbmBuffer, GbmBufferFlags},
};
use smithay::utils::DeviceFd;
use std::{fs::OpenOptions, mem::ManuallyDrop, os::unix::fs::FileTypeExt, path::Path};

const HZ: u32 = 144;
const WARMUP: u32 = 8;
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(4);

fn open_render_node(path: &str) -> Result<DrmDeviceFd> {
    let path = std::fs::canonicalize(path).map_err(|e| format!("{path}: {e}"))?;
    let node = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    if !node
        .strip_prefix("renderD")
        .and_then(|s| s.parse::<u32>().ok())
        .is_some_and(|n| n >= 128)
        || !std::fs::metadata(&path)
            .map_err(|e| e.to_string())?
            .file_type()
            .is_char_device()
        || path.parent() != Some(Path::new("/dev/dri"))
    {
        return Err(format!("{} is not a DRM render node", path.display()));
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&path)
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    let fd: OwnedFd = file.into();
    Ok(DrmDeviceFd::new(DeviceFd::from(fd)))
}

struct Framebuffer {
    image: ImageTexture,
    framebuffer: u32,
}

impl Framebuffer {
    fn new(context: Rc<Destination>, buffer: &Dmabuf) -> Result<Self> {
        // SAFETY: this thread owns the context and switches only at completed-frame boundaries.
        unsafe { context.context.make_current() }.map_err(|e| e.to_string())?;
        let image = ImageTexture::new(context, buffer, false)?;
        let mut frame = Self {
            image,
            framebuffer: 0,
        };
        let gl = &frame.image.destination.gl;
        // SAFETY: current context owns the imported 2D image and the new FBO.
        unsafe {
            gl.GenFramebuffers(1, &mut frame.framebuffer);
            gl.BindFramebuffer(gl::FRAMEBUFFER, frame.framebuffer);
            gl.FramebufferTexture2D(
                gl::FRAMEBUFFER,
                gl::COLOR_ATTACHMENT0,
                gl::TEXTURE_2D,
                frame.image.texture,
                0,
            );
            let status = gl.CheckFramebufferStatus(gl::FRAMEBUFFER);
            gl.BindFramebuffer(gl::FRAMEBUFFER, 0);
            if status != gl::FRAMEBUFFER_COMPLETE {
                return Err(format!("probe framebuffer incomplete: {status:#x}"));
            }
        }
        check_gl(gl, "probe framebuffer")?;
        Ok(frame)
    }
}

impl Drop for Framebuffer {
    fn drop(&mut self) {
        // SAFETY: the owning context is on this thread, with all frame work completed.
        if unsafe { self.image.destination.context.make_current() }.is_ok() {
            unsafe {
                self.image
                    .destination
                    .gl
                    .DeleteFramebuffers(1, &self.framebuffer);
            }
        }
        // ImageTexture immediately follows and drops in this same current context.
    }
}

struct Plan {
    source: Framebuffer,
    readback: Framebuffer,
    target: Arc<TransferTarget>,
    _buffers: Vec<GbmBuffer>,
    width: u32,
    height: u32,
}

fn allocate(
    source: Rc<Destination>,
    destination: Rc<Destination>,
    device: &Arc<TransferDevice>,
    width: u32,
    height: u32,
) -> Result<Plan> {
    let mut failures = Vec::new();
    for use_bridge in [false, true] {
        for fourcc in [
            Fourcc::Abgr8888,
            Fourcc::Argb8888,
            Fourcc::Xbgr8888,
            Fourcc::Xrgb8888,
        ] {
            let candidates = if use_bridge {
                device.source_modifiers(fourcc, width, height)
            } else {
                device.direct_source_modifiers(fourcc)
            };
            let modifiers: Vec<_> = candidates
                .into_iter()
                .filter(|modifier| {
                    source.display.dmabuf_render_formats().contains(&Format {
                        code: fourcc,
                        modifier: *modifier,
                    })
                })
                .take(16)
                .collect();
            if modifiers.is_empty() {
                continue;
            }
            let bridge = if use_bridge {
                let bo = match destination._gbm.create_buffer_object_with_modifiers2::<()>(
                    width,
                    height,
                    fourcc,
                    [Modifier::Linear].into_iter(),
                    GbmBufferFlags::empty(),
                ) {
                    Ok(bo) => bo,
                    Err(e) => {
                        failures.push(format!("{fourcc:?} LINEAR bridge: {e}"));
                        continue;
                    }
                };
                let bridge = GbmBuffer::from_bo(bo, false);
                if bridge.format()
                    != (Format {
                        code: fourcc,
                        modifier: Modifier::Linear,
                    })
                    || bridge.plane_count() != 1
                {
                    continue;
                }
                Some(bridge)
            } else {
                None
            };
            let bridge_dmabuf = bridge
                .as_ref()
                .map(|buffer| buffer.export())
                .transpose()
                .map_err(|e| e.to_string())?;
            // There is no physical plane in this probe. Use the worker's destination
            // render formats and real scanout allocation usages, never a hard-coded modifier.
            let scanout_modifiers: Vec<_> = device
                .render_formats()
                .iter()
                .filter(|format| format.code == fourcc)
                .map(|format| format.modifier)
                .collect();
            if scanout_modifiers.is_empty() {
                continue;
            }
            let scanout = match destination._gbm.create_buffer_object_with_modifiers2::<()>(
                width,
                height,
                fourcc,
                scanout_modifiers.into_iter(),
                GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT,
            ) {
                Ok(bo) => GbmBuffer::from_bo(bo, false),
                Err(e) => {
                    failures.push(format!("{fourcc:?} destination allocation: {e}"));
                    continue;
                }
            };
            if !device.render_formats().contains(&scanout.format()) {
                continue;
            }
            let scanout_dmabuf = scanout.export().map_err(|e| e.to_string())?;
            let readback = Framebuffer::new(destination.clone(), &scanout_dmabuf)?;
            for flags in [
                GbmBufferFlags::RENDERING,
                GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT,
            ] {
                for modifier in source_allocation_candidates(&modifiers, use_bridge) {
                    let allocation = match modifier {
                        Some(m) => source._gbm.create_buffer_object_with_modifiers2::<()>(
                            width,
                            height,
                            fourcc,
                            std::iter::once(m),
                            flags,
                        ),
                        None => source
                            ._gbm
                            .create_buffer_object::<()>(width, height, fourcc, flags),
                    };
                    let buffer = match allocation {
                        Ok(bo) => GbmBuffer::from_bo(bo, false),
                        Err(e) => {
                            failures.push(format!("source {fourcc:?} {flags:?} {modifier:?}: {e}"));
                            continue;
                        }
                    };
                    let actual = buffer.format();
                    if actual.code != fourcc
                        || !modifiers.contains(&actual.modifier)
                        || buffer.plane_count() != 1
                    {
                        continue;
                    }
                    let dmabuf = buffer.export().map_err(|e| e.to_string())?;
                    let source_fbo = match Framebuffer::new(source.clone(), &dmabuf) {
                        Ok(fbo) => fbo,
                        Err(e) => {
                            failures.push(e);
                            continue;
                        }
                    };
                    let target =
                        match device.prepare(dmabuf, bridge_dmabuf.clone(), scanout_dmabuf.clone())
                        {
                            Ok(target) => target,
                            Err(error) => {
                                failures.push(error);
                                continue;
                            }
                        };
                    eprintln!(
                        "allocated source={actual:?} flags={flags:?} bridge={:?} destination={:?}",
                        bridge.as_ref().map(|buffer| buffer.format()),
                        scanout.format()
                    );
                    return Ok(Plan {
                        source: source_fbo,
                        readback,
                        target,
                        _buffers: [Some(buffer), bridge, Some(scanout)]
                            .into_iter()
                            .flatten()
                            .collect(),
                        width,
                        height,
                    });
                }
            }
        }
    }
    Err(format!(
        "no negotiated transfer plan: {}",
        failures.join("; ")
    ))
}

fn color(frame: u32, quadrant: u32) -> [u8; 4] {
    [
        ((frame as u64 * 37 + quadrant as u64 * 53) % 256) as u8,
        ((frame as u64 * 71 + quadrant as u64 * 97) % 256) as u8,
        ((frame as u64 * 113 + quadrant as u64 * 29) % 256) as u8,
        255,
    ]
}

fn produce(plan: &Plan, frame: u32) -> Result<OwnedFd> {
    let context = &plan.source.image.destination;
    // SAFETY: source GL objects are exclusively owned by this thread.
    unsafe { context.context.make_current() }.map_err(|e| e.to_string())?;
    let gl = &context.gl;
    let half_w = plan.width / 2;
    let half_h = plan.height / 2;
    // SAFETY: each scissor rectangle is inside the allocated, complete native-size FBO.
    unsafe {
        gl.BindFramebuffer(gl::FRAMEBUFFER, plan.source.framebuffer);
        gl.Viewport(0, 0, plan.width as i32, plan.height as i32);
        gl.Disable(gl::DITHER);
        gl.ColorMask(gl::TRUE, gl::TRUE, gl::TRUE, gl::TRUE);
        gl.Enable(gl::SCISSOR_TEST);
        for quadrant in 0..4 {
            let x = if quadrant & 1 == 0 { 0 } else { half_w };
            let y = if quadrant & 2 == 0 { 0 } else { half_h };
            let w = if x == 0 { half_w } else { plan.width - half_w };
            let h = if y == 0 { half_h } else { plan.height - half_h };
            let c = color(frame, quadrant);
            gl.Scissor(x as i32, y as i32, w as i32, h as i32);
            gl.ClearColor(
                c[0] as f32 / 255.0,
                c[1] as f32 / 255.0,
                c[2] as f32 / 255.0,
                1.0,
            );
            gl.Clear(gl::COLOR_BUFFER_BIT);
        }
        gl.Disable(gl::SCISSOR_TEST);
        gl.BindFramebuffer(gl::FRAMEBUFFER, 0);
    }
    check_gl(gl, "probe pattern")?;
    let fence = EGLFence::create(&context.display).map_err(|e| e.to_string())?;
    if !fence.is_native() {
        return Err("source fence is not native".into());
    }
    // SAFETY: publishes the pattern and native fence on the current source context.
    unsafe {
        gl.Flush();
    }
    fence
        .export()
        .map_err(|e| format!("source fence export: {e}"))
}

fn transfer(plan: &Plan, frame: u32) -> Result<(Duration, Duration)> {
    let start = Instant::now();
    let fence = produce(plan, frame)?;
    let submitted = Instant::now();
    let (send, receive) = mpsc::sync_channel(1);
    plan.target.submit(
        fence,
        Box::new(move |result| {
            let _ = send.send((Instant::now(), result));
        }),
    )?;
    let (finished, fence) = receive
        .recv_timeout(CALLBACK_TIMEOUT)
        .map_err(|e| format!("bounded worker completion: {e}"))?;
    let fence = fence?;
    // Real worker completion already signifies a signaled final writer fence.
    wait_source(&fence, COMPLETION_TIMEOUT)?;
    Ok((
        finished.duration_since(start),
        finished.duration_since(submitted),
    ))
}

fn verify(plan: &Plan, frame: u32) -> Result<()> {
    let context = &plan.readback.image.destination;
    // SAFETY: completed worker result precedes all untimed readback work.
    unsafe { context.context.make_current() }.map_err(|e| e.to_string())?;
    let gl = &context.gl;
    unsafe {
        gl.BindFramebuffer(gl::FRAMEBUFFER, plan.readback.framebuffer);
    }
    for quadrant in 0..4 {
        let x = if quadrant & 1 == 0 {
            plan.width / 4
        } else {
            plan.width * 3 / 4
        };
        let y = if quadrant & 2 == 0 {
            plan.height / 4
        } else {
            plan.height * 3 / 4
        };
        let mut pixel = [0u8; 4];
        // SAFETY: RGBA/UNSIGNED_BYTE writes one four-byte pixel into this array.
        unsafe {
            gl.ReadPixels(
                x as i32,
                y as i32,
                1,
                1,
                gl::RGBA,
                gl::UNSIGNED_BYTE,
                pixel.as_mut_ptr().cast(),
            );
        }
        check_gl(gl, "untimed pixel verification")?;
        let expected = color(frame, quadrant);
        if pixel.iter().zip(expected).any(|(&a, b)| a.abs_diff(b) > 1) {
            return Err(format!(
                "frame {frame} quadrant {quadrant}: got {pixel:?}, expected {expected:?}"
            ));
        }
    }
    unsafe {
        gl.BindFramebuffer(gl::FRAMEBUFFER, 0);
    }
    eprintln!("untimed verification frame={frame}: four RGBA samples match");
    Ok(())
}

fn cpu_seconds() -> f64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    // SAFETY: getrusage initializes the full writable output on success.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return f64::NAN;
    }
    let usage = unsafe { usage.assume_init() };
    let seconds = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

fn summary(label: &str, samples: &[Duration]) {
    let mut values: Vec<_> = samples.iter().map(Duration::as_secs_f64).collect();
    values.sort_by(f64::total_cmp);
    let percentile = |p: usize| values[((values.len() - 1) * p).div_ceil(100)] * 1000.0;
    eprintln!(
        "{label}_ms mean={:.3} p50={:.3} p95={:.3} p99={:.3} max={:.3}",
        values.iter().sum::<f64>() / values.len() as f64 * 1000.0,
        percentile(50),
        percentile(95),
        percentile(99),
        values[values.len() - 1] * 1000.0
    );
}

fn measure(plan: &Plan, frames: u32) -> Result<()> {
    for frame in 0..WARMUP {
        transfer(plan, frame)?;
    }
    verify(plan, WARMUP - 1)?;
    let period = Duration::from_secs_f64(1.0 / HZ as f64);
    let mut ready = Vec::with_capacity(frames as usize);
    let mut worker = Vec::with_capacity(frames as usize);
    let mut rows = Vec::with_capacity(frames as usize);
    let mut misses = 0;
    let cpu = cpu_seconds();
    let epoch = Instant::now() + period;
    for frame in 0..frames {
        let scheduled = epoch + period * frame;
        if let Some(delay) = scheduled.checked_duration_since(Instant::now()) {
            thread::sleep(delay);
        }
        let wake = Instant::now();
        let (elapsed, transfer_time) = transfer(plan, frame + WARMUP)?;
        let finish = Instant::now();
        let missed = finish > scheduled + period;
        misses += u32::from(missed);
        ready.push(elapsed);
        worker.push(transfer_time);
        rows.push((
            frame,
            wake.saturating_duration_since(scheduled),
            elapsed,
            transfer_time,
            finish.saturating_duration_since(scheduled),
            missed,
        ));
    }
    let wall = Instant::now().duration_since(epoch).as_secs_f64();
    let cpu = cpu_seconds() - cpu;
    // Readback and printing cannot perturb the timed/paced frame stream.
    verify(plan, frames - 1 + WARMUP)?;
    println!(
        "frame,wake_late_ms,draw_to_ready_ms,submit_to_ready_ms,scheduled_to_observed_ready_ms,deadline_miss"
    );
    for (frame, wake, draw, submit, finish, missed) in rows {
        println!(
            "{frame},{:.3},{:.3},{:.3},{:.3},{}",
            wake.as_secs_f64() * 1000.0,
            draw.as_secs_f64() * 1000.0,
            submit.as_secs_f64() * 1000.0,
            finish.as_secs_f64() * 1000.0,
            u32::from(missed)
        );
    }
    summary("draw_to_ready", &ready);
    summary("submit_to_ready", &worker);
    eprintln!(
        "offscreen={}x{} frames={frames} hz={HZ} deadline_misses={misses} wall_s={wall:.3} process_cpu_s={cpu:.3} cpu_one_core_pct={:.1}",
        plan.width,
        plan.height,
        cpu / wall * 100.0
    );
    Ok(())
}

pub fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if !(2..=5).contains(&args.len()) {
        return Err("usage: denial-transfer-benchmark SOURCE_RENDER_NODE DESTINATION_RENDER_NODE [WIDTH HEIGHT FRAMES] (defaults: 2944 1840 400; fixed 144Hz)".into());
    }
    let number = |index: usize, default: u32| -> Result<u32> {
        args.get(index).map_or(Ok(default), |s| {
            s.parse().map_err(|e| format!("invalid number {s}: {e}"))
        })
    };
    let (width, height, frames) = (number(2, 2944)?, number(3, 1840)?, number(4, 400)?);
    if !(4..=16384).contains(&width)
        || !(4..=16384).contains(&height)
        || frames == 0
        || frames > 100_000
        || width as u64 * height as u64 * 12 > 1024 * 1024 * 1024
    {
        return Err("invalid dimensions/frame count or three-buffer budget exceeds 1GiB".into());
    }
    crate::cpu_scheduling::normalize_current_worker("transfer-benchmark");
    let source_fd = open_render_node(&args[0])?;
    let destination_fd = open_render_node(&args[1])?;
    // This one-shot executable measures readiness, not device teardown. Keep
    // every probe owner until process exit, even on setup/measurement errors:
    // same-node EGL displays may alias, and the real worker drains asynchronously
    // when its last sender drops. Retaining that sender avoids racing worker
    // destruction against the harness contexts; retaining the plan also protects
    // imports/storage when completion is ambiguous. The OS reclaims the graph
    // at executable exit, without changing production Destination/worker lifetime.
    let source = ManuallyDrop::new(Destination::new(source_fd.clone())?);
    let destination = ManuallyDrop::new(Destination::new(destination_fd.clone())?);
    let device = ManuallyDrop::new(TransferDevice::new_with_direct_rejection(
        source_fd,
        destination_fd,
        denial_core::environment::flag("DENIAL_GPU_TRANSFER_REJECT_DIRECT_IMPORT"),
    )?);
    eprintln!(
        "render-node-only readiness probe: negotiated output layout; no KMS/Flutter presentation, no MTK display-only UFBC allocation"
    );
    let plan = ManuallyDrop::new(allocate(
        Rc::clone(&source),
        Rc::clone(&destination),
        &device,
        width,
        height,
    )?);
    measure(&plan, frames)
}
