//! GPU smoke test and submission timing for the composer's Vulkan path.
//! Needs a render node: `DENIAL_COMPOSER_TEST_NODE` (default
//! /dev/dri/renderD128). Run with
//! `cargo test --features flutter --bin deniald composer::gpu_test -- --ignored --nocapture`.

use std::os::fd::{AsFd, OwnedFd};
use std::sync::Arc;
use std::time::{Duration, Instant};

use denial_flutter_engine::scene::{EntryLocal, Material, Matrix3, Rect, Sampling, SliceBlit};
use smithay::backend::allocator::dmabuf::AsDmabuf;
use smithay::backend::allocator::gbm::{GbmBuffer, GbmDevice};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::drm::DrmDeviceFd;

use super::device::{
    self, Batch, Frame, Gpu, Image, MaterialStep, Merge, Step, Upload, Usage, WindowDraw, wait_fd,
};
use super::material::Frost;
use super::record::{self, ClipSpan};

const W: u32 = 256;
const H: u32 = 128;

/// Redraws the whole target.
const WHOLE: [i32; 4] = [0, 0, i32::MAX, i32::MAX];

fn node() -> OwnedFd {
    let path =
        std::env::var("DENIAL_COMPOSER_TEST_NODE").unwrap_or_else(|_| "/dev/dri/renderD128".into());
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&path)
        .unwrap_or_else(|error| panic!("{path}: {error}"))
        .into()
}

fn allocate(gbm: &GbmDevice<DrmDeviceFd>) -> GbmBuffer {
    let bo = gbm
        .create_buffer_object_with_modifiers::<()>(
            W,
            H,
            Fourcc::Abgr8888,
            [Modifier::Linear].into_iter(),
        )
        .expect("linear ABGR8888 buffer");
    GbmBuffer::from_bo(bo, false)
}

/// Opaque, distinct per pixel; RGBA bytes.
fn pattern(x: u32, y: u32) -> [u8; 4] {
    [
        (x & 0xff) as u8,
        (y & 0xff) as u8,
        ((x + y) & 0xff) as u8,
        0xff,
    ]
}

fn fill(buffer: &mut GbmBuffer, row_of: impl Fn(u32) -> u32) {
    fill_with(buffer, |x, y| pattern(x, row_of(y)));
}

fn fill_with(buffer: &mut GbmBuffer, color: impl Fn(u32, u32) -> [u8; 4]) {
    buffer
        .map_mut(0, 0, W, H, |mapping| {
            let stride = mapping.stride() as usize;
            let bytes = mapping.buffer_mut();
            for y in 0..H {
                for x in 0..W {
                    let at = y as usize * stride + x as usize * 4;
                    bytes[at..at + 4].copy_from_slice(&color(x, y));
                }
            }
        })
        .expect("map slice");
}

fn mismatches(buffer: &GbmBuffer) -> (usize, Option<(u32, u32, [u8; 4])>) {
    buffer
        .map(0, 0, W, H, |mapping| {
            let stride = mapping.stride() as usize;
            let bytes = mapping.buffer();
            let mut count = 0;
            let mut first = None;
            for y in 0..H {
                for x in 0..W {
                    let at = y as usize * stride + x as usize * 4;
                    let got: [u8; 4] = bytes[at..at + 4].try_into().unwrap();
                    // The output is bottom-up, as the GL FBO Impeller wraps:
                    // target row y is memory row H - 1 - y.
                    if got != pattern(x, H - 1 - y) {
                        count += 1;
                        first.get_or_insert((x, y, got));
                    }
                }
            }
            (count, first)
        })
        .expect("map target")
}

struct Rig {
    gpu: Gpu,
    target_buffer: GbmBuffer,
    target: Arc<Image>,
    slices: Vec<(GbmBuffer, Arc<Image>)>,
    no_look: Arc<Image>,
}

fn rig(slices: usize, bottom_up: bool) -> Rig {
    let fd = node();
    let gpu = Gpu::new(fd.as_fd()).expect("Stagecraft device");
    let gbm = GbmDevice::new(DrmDeviceFd::new(smithay::utils::DeviceFd::from(fd))).expect("GBM");
    let target_buffer = allocate(&gbm);
    let target = gpu
        .import(&target_buffer.export().unwrap(), Usage::Target)
        .expect("target import");
    let slices = (0..slices)
        .map(|_| {
            let mut buffer = allocate(&gbm);
            fill(&mut buffer, |y| if bottom_up { H - 1 - y } else { y });
            let image = gpu
                .import(&buffer.export().unwrap(), Usage::Sampled)
                .expect("slice import");
            (buffer, image)
        })
        .collect();
    let no_look = gpu
        .look_image(1, &[0.0, 0.0, 0.0, 1.0])
        .expect("look stand-in");
    Rig {
        gpu,
        target_buffer,
        target,
        slices,
        no_look,
    }
}

/// `bands` horizontal bands, each from the next slice in turn.
fn scene(rig: &Rig, bands: u32, bottom_up: bool) -> (Vec<record::Draw>, Vec<Step>) {
    let ndc = record::ndc_from_target(W, H);
    let mut draws = Vec::new();
    let mut batches: Vec<Step> = Vec::new();
    for band in 0..bands {
        let top = f64::from(H * band / bands);
        let bottom = f64::from(H * (band + 1) / bands);
        let rect = [0.0, top, f64::from(W), bottom];
        let blit = SliceBlit {
            source: rect,
            destination: rect,
        };
        let image = &rig.slices[band as usize % rig.slices.len()].1;
        draws.push(record::slice_blit(&blit, image.size, bottom_up, &ndc));
        let index = draws.len() as u32 - 1;
        match batches.last_mut() {
            Some(Step::Draws(last)) if Arc::ptr_eq(&last.image, image) => last.count += 1,
            _ => batches.push(Step::Draws(Batch {
                image: Arc::clone(image),
                look: Arc::clone(&rig.no_look),
                nearest: true,
                first: index,
                count: 1,
                content: 0,
                layers: None,
            })),
        }
    }
    (draws, batches)
}

fn check(bottom_up: bool) {
    let rig = rig(1, bottom_up);
    let (draws, batches) = scene(&rig, 1, bottom_up);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let done = frame
        .submit(
            1,
            &rig.target,
            &draws,
            &[],
            &[],
            &[],
            &[],
            &batches,
            &[],
            WHOLE,
            None,
            None,
        )
        .expect("submit");
    if let Some(done) = done {
        assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
    }
    let (count, first) = mismatches(&rig.target_buffer);
    assert_eq!(count, 0, "first mismatch {first:?}");
}

/// A composer on the test node with one imported output buffer, 1.
fn composer_with_target() -> (super::SceneComposer, GbmBuffer) {
    let device = DrmDeviceFd::new(smithay::utils::DeviceFd::from(node()));
    let composer = super::SceneComposer::new(device, &[Modifier::Linear], &[]).expect("composer");
    let gbm = GbmDevice::new(DrmDeviceFd::new(smithay::utils::DeviceFd::from(node()))).unwrap();
    let target = allocate(&gbm);
    composer.add_target(1, &target.export().unwrap());
    (composer, target)
}

/// A frame of `view_id` that draws nothing.
fn empty_staged(view_id: i64) -> super::Staged {
    super::Staged {
        view_id,
        output_from_scene: Matrix3::IDENTITY,
        scene_revision: 1,
        draws: Vec::new(),
        glasses: Vec::new(),
        clips: Vec::new(),
        edges: Vec::new(),
        steps: Vec::new(),
        backdrop_tokens: Vec::new(),
        engine_tokens: Vec::new(),
        outputs: Vec::new(),
        remade_why: [0; 6],
        frosts_allocated: 0,
        slices: Vec::new(),
        slices_rewritten: 0,
        clients: Vec::new(),
        credits: Vec::new(),
        omitted: Vec::new(),
        uploads: Vec::new(),
        merges: Vec::new(),
        merged_windows: Vec::new(),
        merges_reused: 0,
        layered: 0,
        converted: 0,
        covers: Vec::new(),
        culled_draws: 0,
        culled_materials: 0,
        split_draws: 0,
        client_draws: Vec::new(),
        shown_textures: Vec::new(),
        hidden_textures: Vec::new(),
        full_cover: None,
    }
}

const NO_DAMAGE: super::FrameDamage<'static> = super::FrameDamage {
    frame: &[],
    buffer: &[],
};

#[test]
#[ignore = "needs a GPU"]
fn a_failed_submission_leaves_the_composer_usable() {
    let (composer, _target) = composer_with_target();
    // An output buffer the composer never imported.
    let failed = composer.submit(&mut empty_staged(-1), 2, NO_DAMAGE, None);
    assert!(failed.is_err());
    assert!(!composer.broken());
    // The view's next frame draws, redrawing and reporting all of it.
    let submitted = composer
        .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
        .expect("the next frame draws");
    let added = submitted.added.expect("the whole target is reported");
    assert_eq!(
        (added.left, added.top, added.right, added.bottom),
        (0.0, 0.0, f64::from(W), f64::from(H))
    );
    if let Some(completion) = submitted.completion {
        assert!(wait_fd(completion.as_fd(), 5000));
    }
}

#[test]
#[ignore = "needs a GPU"]
fn a_frame_lost_after_submission_is_redrawn_whole() {
    let (composer, _target) = composer_with_target();
    let whole = (0.0, 0.0, f64::from(W), f64::from(H));
    let rect = |submitted: &super::Submitted| {
        submitted
            .added
            .map(|added| (added.left, added.top, added.right, added.bottom))
    };
    let finish = |submitted: super::Submitted| {
        if let Some(completion) = submitted.completion {
            assert!(wait_fd(completion.as_fd(), 5000));
        }
    };
    // Drawn frames add nothing to the engine's damage.
    for _ in 0..2 {
        let drawn = composer
            .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
            .expect("frame");
        assert_eq!(rect(&drawn), None);
        finish(drawn);
    }
    // Drawn, but its copy or handoff failed: the retry, with no new damage,
    // reports the whole target so every buffer slot is repaired.
    composer.frame_lost(-1);
    let retry = composer
        .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
        .expect("retry");
    assert_eq!(rect(&retry), Some(whole));
    finish(retry);
}

#[test]
#[ignore = "needs a GPU"]
fn frames_without_a_completion_file_are_tracked_by_their_fence() {
    let (composer, _target) = composer_with_target();
    // Fill every frame, each known complete only by its fence.
    for _ in 0..super::MAX_FRAMES * 2 {
        let submitted = composer
            .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
            .expect("frame");
        drop(submitted);
        let mut state = super::lock(&composer.state);
        for frame in &mut state.frames {
            frame.forget_completion();
        }
    }
    // Still usable, and the frames retire.
    let start = Instant::now();
    let submitted = composer
        .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
        .expect("a frame completed by its fence");
    assert!(start.elapsed() < super::FRAME_WAIT);
    if let Some(completion) = submitted.completion {
        assert!(wait_fd(completion.as_fd(), 5000));
    }
    assert!(!composer.broken());
}

#[test]
#[ignore = "needs a GPU"]
fn a_stuck_gpu_returns_control_instead_of_hanging() {
    let (composer, _target) = composer_with_target();
    // Every frame in flight on a completion that never signals.
    let mut writers = Vec::new();
    {
        let mut state = super::lock(&composer.state);
        while state.frames.len() < super::MAX_FRAMES {
            let mut frame = Frame::new(&composer.gpu).expect("frame");
            let (read, write) = std::io::pipe().expect("pipe");
            frame.set_stuck(OwnedFd::from(read));
            writers.push(write);
            state.frames.push(frame);
        }
    }
    let start = Instant::now();
    let result = composer.submit(&mut empty_staged(-1), 1, NO_DAMAGE, None);
    let waited = start.elapsed();
    assert!(result.is_err(), "no frame was free");
    assert!(
        waited >= super::FRAME_WAIT && waited < super::FRAME_WAIT * 2,
        "{waited:?}"
    );
    assert!(!composer.broken());
    // The frames complete: the next submits.
    for frame in &mut super::lock(&composer.state).frames {
        frame.unstick();
    }
    drop(writers);
    let submitted = composer
        .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
        .expect("a frame completed");
    if let Some(completion) = submitted.completion {
        assert!(wait_fd(completion.as_fd(), 5000));
    }
}

/// Run in its own test process with a second, differently driven GPU.
#[test]
#[ignore = "set DENIAL_COMPOSER_TEST_NODE and DENIAL_COMPOSER_TEST_UNUSED_NODE"]
fn compositor_leaves_the_other_render_node_closed() {
    use smithay::backend::allocator::format::FormatSet;
    use std::os::unix::fs::MetadataExt;

    let selected = std::fs::File::from(node());
    let selected_dev = selected.metadata().unwrap().rdev();
    let unused = std::env::var_os("DENIAL_COMPOSER_TEST_UNUSED_NODE").unwrap();
    let unused_dev = std::fs::metadata(&unused).unwrap().rdev();
    assert_ne!(selected_dev, unused_dev);
    device::sampled_client_formats(selected_dev, &FormatSet::default()).unwrap();
    let gpu = Gpu::new(selected.as_fd()).expect("compositor device");
    let unused_open = std::fs::read_dir("/proc/self/fd").unwrap().any(|fd| {
        fd.ok()
            .and_then(|fd| std::fs::metadata(fd.path()).ok())
            .is_some_and(|stat| stat.rdev() == unused_dev)
    });
    assert!(!unused_open, "compositor holds {unused:?}");

    // A client inheriting this process's environment can use the other GPU
    // while the compositor still owns its device.
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "clients_are_offered_only_layouts_the_composer_samples",
            "--ignored",
        ])
        .env("DENIAL_COMPOSER_TEST_NODE", unused)
        .output()
        .unwrap();
    assert!(
        child.status.success(),
        "{}",
        String::from_utf8_lossy(&child.stdout)
    );
    drop(gpu);
}

#[test]
#[ignore = "needs a GPU"]
fn clients_are_offered_only_layouts_the_composer_samples() {
    use smithay::backend::allocator::Format;
    use smithay::backend::allocator::format::FormatSet;
    use std::os::unix::fs::MetadataExt;

    let device_number = std::fs::File::from(node())
        .metadata()
        .expect("render node metadata")
        .rdev();
    // No driver has this modifier: the vendor byte is unassigned.
    let unknown = Modifier::from(0x7f00_0000_0000_0001);
    let format = |code, modifier| Format { code, modifier };
    let offered: FormatSet = [
        format(Fourcc::Abgr8888, Modifier::Linear),
        format(Fourcc::Abgr8888, unknown),
        format(Fourcc::Abgr8888, Modifier::Invalid),
        format(Fourcc::Nv12, unknown),
    ]
    .into_iter()
    .collect();
    let sampled = super::device::sampled_client_formats(device_number, &offered)
        .expect("a Vulkan device behind the render node");
    let kept: Vec<Format> = sampled.iter().copied().collect();
    assert_eq!(
        kept,
        [
            format(Fourcc::Abgr8888, Modifier::Linear),
            format(Fourcc::Abgr8888, Modifier::Invalid),
            format(Fourcc::Nv12, unknown),
        ]
    );
}

#[test]
#[ignore = "needs a GPU"]
fn top_down_slice_copies_exactly() {
    check(false);
}

/// SHM pixels as the snapshot packs them: RGBA rows, top-down.
fn shm_frame(revision: u64, color: impl Fn(u32, u32) -> [u8; 4]) -> super::super::ShmTextureFrame {
    let mut rgba = Vec::with_capacity((W * H * 4) as usize);
    for y in 0..H {
        for x in 0..W {
            rgba.extend_from_slice(&color(x, y));
        }
    }
    super::super::ShmTextureFrame::new_owned(W, H, revision, rgba).expect("SHM frame")
}

#[test]
#[ignore = "needs a GPU"]
fn shm_upload_draws_exactly_and_is_overwritten() {
    let rig = rig(0, false);
    let image = rig.gpu.upload_image((W, H)).expect("upload image");
    let ndc = record::ndc_from_target(W, H);
    let rect = [0.0, 0.0, f64::from(W), f64::from(H)];
    let draws = [record::slice_blit(
        &SliceBlit {
            source: rect,
            destination: rect,
        },
        image.size,
        false,
        &ndc,
    )];
    let steps = [Step::Draws(Batch {
        image: Arc::clone(&image),
        look: Arc::clone(&rig.no_look),
        nearest: true,
        first: 0,
        count: 1,
        content: 0,
        layers: None,
    })];
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    // The first upload goes into undefined contents, the second over what
    // the first left, as a cursor's next image does.
    let uploads = [
        (shm_frame(1, |_, _| [0x40, 0, 0, 0xff]), true),
        (shm_frame(2, pattern), false),
    ];
    for (serial, (pixels, fresh)) in uploads.into_iter().enumerate() {
        while !frame.idle() {
            std::thread::yield_now();
        }
        let upload = Upload {
            image: Arc::clone(&image),
            frame: pixels,
            fresh,
        };
        let done = frame
            .submit(
                serial as u64 + 1,
                &rig.target,
                &draws,
                &[],
                &[],
                &[],
                &[],
                &steps,
                &[upload],
                WHOLE,
                None,
                None,
            )
            .expect("submit");
        if let Some(done) = done {
            assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
        }
    }
    let (count, first) = mismatches(&rig.target_buffer);
    assert_eq!(count, 0, "first mismatch {first:?}");
}

#[test]
#[ignore = "needs a GPU"]
fn bottom_up_slice_copies_exactly() {
    check(true);
}

fn time(label: &str, slices: usize, bands: u32) {
    let rig = rig(slices, false);
    let (draws, batches) = scene(&rig, bands, false);
    let mut frames = vec![Frame::new(&rig.gpu).unwrap(), Frame::new(&rig.gpu).unwrap()];
    let mut cpu = Vec::with_capacity(2000);
    let mut serial = 0;
    for iteration in 0..2100 {
        let frame = &mut frames[iteration % 2];
        while !frame.idle() {
            std::thread::yield_now();
        }
        serial += 1;
        let started = Instant::now();
        let done = frame
            .submit(
                serial,
                &rig.target,
                &draws,
                &[],
                &[],
                &[],
                &[],
                &batches,
                &[],
                WHOLE,
                None,
                None,
            )
            .expect("submit");
        let spent = started.elapsed();
        drop(done);
        if iteration >= 100 {
            cpu.push(spent);
        }
    }
    for frame in &mut frames {
        while !frame.idle() {
            std::thread::yield_now();
        }
    }
    cpu.sort();
    let mean = cpu.iter().sum::<Duration>() / cpu.len() as u32;
    println!(
        "{label}: {} draws in {} batches, submit CPU mean {:.1} µs, p50 {:.1} µs, p99 {:.1} µs",
        draws.len(),
        batches.len(),
        mean.as_secs_f64() * 1e6,
        cpu[cpu.len() / 2].as_secs_f64() * 1e6,
        cpu[cpu.len() * 99 / 100].as_secs_f64() * 1e6,
    );
    let (count, first) = mismatches(&rig.target_buffer);
    assert_eq!(count, 0, "first mismatch {first:?}");
}

#[test]
#[ignore = "needs a GPU"]
fn submit_timing() {
    time("one slice", 1, 1);
    time("eight bands, one slice", 1, 8);
    time("eight bands, four slices", 4, 8);
}

/// A blur material over target pixels `rect`.
fn blur_material(rig: &Rig, rect: [f32; 4], sigma: f32) -> record::MaterialDraw {
    let material = Material {
        glass: None,
        sigma: [sigma; 2],
        blend_mode: denial_flutter_engine::scene::BLEND_SRC_OVER,
        bounds: Rect {
            left: rect[0],
            top: rect[1],
            right: rect[2],
            bottom: rect[3],
        },
        content_clip: None,
        backdrop_token: Some(1),
        alpha_threshold: 0.0,
        frozen: None,
    };
    let local = EntryLocal {
        scene_from_local: Matrix3::IDENTITY,
        opacity: 1.0,
        clips: 0..0,
        sampling: Sampling::Linear,
        freeze: false,
    };
    record::material(
        &material,
        &local,
        ClipSpan::default(),
        &Matrix3::IDENTITY,
        rig.target.size,
    )
    .expect("supported material")
    .expect("visible material")
}

/// One slice drawn whole, then a material over `rect`.
fn material_scene(
    rig: &Rig,
    rect: [f32; 4],
    sigma: f32,
    frost: &mut Option<Arc<Frost>>,
    fresh: bool,
) -> (Vec<record::Draw>, Vec<record::Glass>, Vec<Step>) {
    let (draws, mut steps) = scene(rig, 1, false);
    let record::MaterialDraw { glass, plan, .. } = blur_material(rig, rect, sigma);
    let frost = frost.get_or_insert_with(|| Arc::new(Frost::new(&rig.gpu, plan).expect("frost")));
    steps.push(Step::Material(MaterialStep {
        record: 0,
        plan,
        frost: Some(Arc::clone(frost)),
        fresh,
        below: 0,
        made: 0,
        frozen: None,
        window: None,
    }));
    (draws, vec![glass], steps)
}

fn submit_and_wait(
    rig: &Rig,
    frame: &mut Frame,
    draws: &[record::Draw],
    glasses: &[record::Glass],
    steps: &[Step],
) {
    submit_area_and_wait(rig, frame, draws, glasses, steps, WHOLE);
}

/// Submits a frame that redraws `area` (left, top, right, bottom target
/// pixels, rows counting up from the bottom) and waits for it.
fn submit_area_and_wait(
    rig: &Rig,
    frame: &mut Frame,
    draws: &[record::Draw],
    glasses: &[record::Glass],
    steps: &[Step],
    area: [i32; 4],
) {
    let done = frame
        .submit(
            1,
            &rig.target,
            draws,
            glasses,
            &[],
            &[],
            &[],
            steps,
            &[],
            area,
            None,
            None,
        )
        .expect("submit");
    if let Some(done) = done {
        assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
    }
    assert!(frame.idle());
}

/// A material without blur shows exactly the pixels under it: the copy
/// out of the bottom-up target, its flip and the frost mapping line up.
#[test]
#[ignore = "needs a GPU"]
fn unblurred_material_reproduces_its_backdrop() {
    let rig = rig(1, false);
    assert!(rig.target.copyable, "the test target cannot be copied");
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut frost = None;
    for fresh in [true, false] {
        let (draws, glasses, steps) =
            material_scene(&rig, [37.0, 21.0, 201.0, 99.0], 0.0, &mut frost, fresh);
        submit_and_wait(&rig, &mut frame, &draws, &glasses, &steps);
        let (count, first) = mismatches(&rig.target_buffer);
        assert_eq!(count, 0, "fresh {fresh}: first mismatch {first:?}");
    }
}

/// A blurred uniform color stays that color: the weights are normalized and
/// the edges clamp.
#[test]
#[ignore = "needs a GPU"]
fn blurred_uniform_color_is_unchanged() {
    let mut rig = rig(1, false);
    let color = [40, 120, 200, 255];
    fill_with(&mut rig.slices[0].0, |_, _| color);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    for sigma in [6.0, 10.0, 18.0] {
        let mut frost = None;
        let (draws, glasses, steps) =
            material_scene(&rig, [30.0, 20.0, 220.0, 110.0], sigma, &mut frost, true);
        submit_and_wait(&rig, &mut frame, &draws, &glasses, &steps);
        let worst = rig
            .target_buffer
            .map(0, 0, W, H, |mapping| {
                let stride = mapping.stride() as usize;
                let bytes = mapping.buffer();
                let mut worst = 0u8;
                for y in 0..H as usize {
                    for x in 0..W as usize {
                        let at = y * stride + x * 4;
                        for channel in 0..4 {
                            worst = worst.max(bytes[at + channel].abs_diff(color[channel]));
                        }
                    }
                }
                worst
            })
            .expect("map target");
        assert!(worst <= 2, "sigma {sigma}: off by {worst}");
    }
}

#[test]
#[ignore = "needs a GPU"]
fn material_timing() {
    let rig = rig(1, false);
    let mut frames = vec![Frame::new(&rig.gpu).unwrap(), Frame::new(&rig.gpu).unwrap()];
    for (label, fresh) in [
        ("material, frost made", true),
        ("material, frost reused", false),
    ] {
        let mut frost = None;
        let (draws, glasses, steps) =
            material_scene(&rig, [30.0, 20.0, 220.0, 110.0], 10.0, &mut frost, fresh);
        // A reused frost must exist first.
        let (_, _, first) =
            material_scene(&rig, [30.0, 20.0, 220.0, 110.0], 10.0, &mut frost, true);
        submit_and_wait(&rig, &mut frames[0], &draws, &glasses, &first);
        let mut cpu = Vec::with_capacity(2000);
        for iteration in 0..2100 {
            let frame = &mut frames[iteration % 2];
            while !frame.idle() {
                std::thread::yield_now();
            }
            let started = Instant::now();
            let done = frame
                .submit(
                    iteration as u64 + 2,
                    &rig.target,
                    &draws,
                    &glasses,
                    &[],
                    &[],
                    &[],
                    &steps,
                    &[],
                    WHOLE,
                    None,
                    None,
                )
                .expect("submit");
            let spent = started.elapsed();
            drop(done);
            if iteration >= 100 {
                cpu.push(spent);
            }
        }
        for frame in &mut frames {
            while !frame.idle() {
                std::thread::yield_now();
            }
        }
        cpu.sort();
        let mean = cpu.iter().sum::<Duration>() / cpu.len() as u32;
        println!(
            "{label}: submit CPU mean {:.1} µs, p50 {:.1} µs, p99 {:.1} µs",
            mean.as_secs_f64() * 1e6,
            cpu[cpu.len() / 2].as_secs_f64() * 1e6,
            cpu[cpu.len() * 99 / 100].as_secs_f64() * 1e6,
        );
    }
}

/// The scene drawn whole, then `draw` from `frost`.
fn steps_with(
    rig: &Rig,
    draw: &record::MaterialDraw,
    frost: &Arc<Frost>,
    fresh: bool,
) -> (Vec<record::Draw>, Vec<Step>) {
    let (draws, mut steps) = scene(rig, 1, false);
    steps.push(Step::Material(MaterialStep {
        record: 0,
        plan: draw.plan,
        frost: Some(Arc::clone(frost)),
        fresh,
        below: 0,
        made: 0,
        frozen: None,
        window: None,
    }));
    (draws, steps)
}

/// The target pixel at memory row `row`.
fn pixel(buffer: &GbmBuffer, x: u32, row: u32) -> [u8; 4] {
    buffer
        .map(0, 0, W, H, |mapping| {
            let at = row as usize * mapping.stride() as usize + x as usize * 4;
            mapping.buffer()[at..at + 4].try_into().unwrap()
        })
        .expect("map target")
}

/// Black-tinted glass with one rounded corner, on a gray output buffer
/// whose root flips y as the engine's does: the glass draws, upright (its
/// rounded corner at the scene's top left, which is memory row 0's end of
/// the buffer).
#[test]
#[ignore = "needs a GPU"]
fn glass_on_a_flipped_output_is_upright() {
    let mut rig = rig(1, false);
    let gray = [128, 128, 128, 255];
    fill_with(&mut rig.slices[0].0, |_, _| gray);
    let material = record::tests::glass_material(
        [40.0, 20.0, 216.0, 108.0],
        [[40.0; 2], [0.0; 2], [0.0; 2], [0.0; 2]],
    );
    let draw = record::material(
        &material,
        &record::tests::plain_local(),
        ClipSpan::default(),
        &record::tests::flip(H),
        rig.target.size,
    )
    .expect("supported material")
    .expect("visible material");
    let frost = Arc::new(Frost::new(&rig.gpu, draw.plan).expect("frost"));
    let (draws, steps) = steps_with(&rig, &draw, &frost, true);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    submit_and_wait(&rig, &mut frame, &draws, &[draw.glass], &steps);
    // Memory rows are scene rows on a flipped output.
    let dark = |color: [u8; 4]| color[..3].iter().all(|&c| c < 8);
    assert_eq!(
        pixel(&rig.target_buffer, 42, 22),
        gray,
        "scene top left is rounded"
    );
    assert!(
        dark(pixel(&rig.target_buffer, 42, 105)),
        "scene bottom left is square"
    );
    assert!(
        dark(pixel(&rig.target_buffer, 213, 22)),
        "scene top right is square"
    );
    assert!(dark(pixel(&rig.target_buffer, 128, 64)), "the glass draws");
    assert_eq!(pixel(&rig.target_buffer, 20, 64), gray, "outside the glass");
}

/// Scene coordinates of local point (x, y) turned by `angle` about the
/// target's centre, as the close animation turns a window.
fn turned(angle: f32, x: f32, y: f32) -> (u32, u32) {
    let (c, s) = (angle.cos(), angle.sin());
    let (cx, cy) = (W as f32 * 0.5, H as f32 * 0.5);
    let (dx, dy) = (x - cx, y - cy);
    (
        (c * dx - s * dy + cx).round() as u32,
        (s * dx + c * dy + cy).round() as u32,
    )
}

fn turned_local(angle: f32) -> EntryLocal {
    let (c, s) = (angle.cos(), angle.sin());
    let (cx, cy) = (W as f32 * 0.5, H as f32 * 0.5);
    EntryLocal {
        scene_from_local: Matrix3([
            c,
            -s,
            cx - c * cx + s * cy,
            s,
            c,
            cy - s * cx - c * cy,
            0.0,
            0.0,
            1.0,
        ]),
        ..record::tests::plain_local()
    }
}

/// Black glass with one rounded corner, turned: it draws in its own frame,
/// so its rounded corner turns with it and the corners of its target bounds
/// keep the scene.
#[test]
#[ignore = "needs a GPU"]
fn turned_glass_draws_in_its_own_frame() {
    let mut rig = rig(1, false);
    let gray = [128, 128, 128, 255];
    fill_with(&mut rig.slices[0].0, |_, _| gray);
    let material = record::tests::glass_material(
        [40.0, 20.0, 216.0, 108.0],
        [[40.0; 2], [0.0; 2], [0.0; 2], [0.0; 2]],
    );
    let angle = 0.3;
    let draw = record::material(
        &material,
        &turned_local(angle),
        ClipSpan::default(),
        &record::tests::flip(H),
        rig.target.size,
    )
    .expect("supported material")
    .expect("visible material");
    let frost = Arc::new(Frost::new(&rig.gpu, draw.plan).expect("frost"));
    let (draws, steps) = steps_with(&rig, &draw, &frost, true);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    submit_and_wait(&rig, &mut frame, &draws, &[draw.glass], &steps);
    let dark = |color: [u8; 4]| color[..3].iter().all(|&c| c < 8);
    // Memory rows are scene rows on a flipped output.
    let at = |(x, y): (u32, u32)| pixel(&rig.target_buffer, x, y);
    assert!(dark(at(turned(angle, 128.0, 64.0))), "the glass draws");
    assert!(
        dark(at(turned(angle, 208.0, 28.0))),
        "the square corner turned with the glass"
    );
    assert_eq!(
        at(turned(angle, 45.0, 25.0)),
        gray,
        "the rounded corner turned with the glass"
    );
    assert_eq!(
        at(turned(angle, 128.0, 10.0)),
        gray,
        "above the turned top edge, within the target bounds"
    );
}

/// A turned blur covers its own rectangle: the corners of its target
/// bounds keep the scene unblurred.
#[test]
#[ignore = "needs a GPU"]
fn turned_blur_covers_its_own_rectangle() {
    let mut rig = rig(1, false);
    let checker = |x: u32, y: u32| {
        if ((x / 8) + (y / 8)) % 2 == 0 {
            [0, 0, 0, 255]
        } else {
            [255, 255, 255, 255]
        }
    };
    fill_with(&mut rig.slices[0].0, checker);
    let mut material = record::tests::glass_material([40.0, 20.0, 216.0, 108.0], [[0.0; 2]; 4]);
    material.glass = None;
    material.sigma = [8.0; 2];
    let angle = 0.3;
    let draw = record::material(
        &material,
        &turned_local(angle),
        ClipSpan::default(),
        &record::tests::flip(H),
        rig.target.size,
    )
    .expect("supported material")
    .expect("visible material");
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let at = |(x, y): (u32, u32)| pixel(&rig.target_buffer, x, y);
    // The scene alone, for what the blur must leave untouched.
    let (draws, steps) = scene(&rig, 1, false);
    submit_and_wait(&rig, &mut frame, &draws, &[], &steps);
    let outside = turned(angle, 128.0, 10.0);
    let unblurred = at(outside);
    let frost = Arc::new(Frost::new(&rig.gpu, draw.plan).expect("frost"));
    let (draws, steps) = steps_with(&rig, &draw, &frost, true);
    submit_and_wait(&rig, &mut frame, &draws, &[draw.glass], &steps);
    let centre = at(turned(angle, 128.0, 64.0));
    assert!(
        (60..=200).contains(&centre[0]),
        "the blur averages the checker: {centre:?}"
    );
    assert_eq!(at(outside), unblurred, "outside the turned rectangle");
}

/// A blur over a stripe that moves: a reused frost keeps the old stripe,
/// a fresh one shows the new one.
#[test]
#[ignore = "needs a GPU"]
fn frost_is_kept_or_remade_as_asked() {
    let mut rig = rig(1, false);
    let stripe = |at: u32| {
        move |x: u32, _| {
            if (at..at + 12).contains(&x) {
                [255, 255, 255, 255]
            } else {
                [0, 0, 0, 255]
            }
        }
    };
    let draw = blur_material(&rig, [37.0, 21.0, 211.0, 99.0], 6.0);
    let frost = Arc::new(Frost::new(&rig.gpu, draw.plan).expect("frost"));
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut brightness = |at: u32, fresh: bool| {
        fill_with(&mut rig.slices[0].0, stripe(at));
        let (draws, steps) = steps_with(&rig, &draw, &frost, fresh);
        submit_and_wait(&rig, &mut frame, &draws, &[draw.glass], &steps);
        (
            pixel(&rig.target_buffer, 86, 60)[0],
            pixel(&rig.target_buffer, 156, 60)[0],
        )
    };
    let (old, new) = brightness(80, true);
    assert!(old > 60 && new < 4, "first frame: {old}, {new}");
    let (old, new) = brightness(150, false);
    assert!(old > 60 && new < 4, "reused frost: {old}, {new}");
    let (old, new) = brightness(150, true);
    assert!(old < 4 && new > 60, "fresh frost: {old}, {new}");
}

/// A frost made in images with room, after a larger white frost filled
/// them, draws as one made in images of its own size: its passes and glass
/// read its texels only. The regions are the materials themselves, as a
/// window's exact frost, so taps at the edges reach past the texels.
#[test]
#[ignore = "needs a GPU"]
fn a_frost_in_roomy_images_matches_an_exact_one() {
    let mut rig = rig(1, false);
    let rect = [37.0, 21.0, 211.0, 99.0];
    // A white stripe across the material's right edge.
    let stripe = |x: u32, _| {
        if (196..204).contains(&x) {
            [255, 255, 255, 255]
        } else {
            [0, 0, 0, 255]
        }
    };
    let exact_region = |rig: &Rig, rect: [f32; 4]| {
        let mut draw = blur_material(rig, rect, 6.0);
        draw.plan.region = rect.map(|value| value as i32);
        draw
    };
    let draw = exact_region(&rig, rect);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut image = |rig: &mut Rig, frost: &Arc<Frost>, draw: &record::MaterialDraw| {
        let mut glass = draw.glass;
        glass.place_frost(&draw.plan, frost.last_storage());
        let (draws, steps) = steps_with(rig, draw, frost, true);
        submit_and_wait(rig, &mut frame, &draws, &[glass], &steps);
        let mut pixels = Vec::new();
        for row in 0..H {
            for x in 0..W {
                pixels.push(pixel(&rig.target_buffer, x, row));
            }
        }
        pixels
    };
    fill_with(&mut rig.slices[0].0, stripe);
    let exact = Arc::new(Frost::new(&rig.gpu, draw.plan).expect("frost"));
    let expected = image(&mut rig, &exact, &draw);
    // Fill the roomy images white past the smaller plan's texels.
    let larger = exact_region(&rig, [30.0, 15.0, 225.0, 110.0]);
    let roomy = Arc::new(Frost::with_room(&rig.gpu, larger.plan).expect("frost"));
    assert!(
        roomy.fits(&draw.plan),
        "the smaller plan fits the larger room"
    );
    assert!(roomy.last_storage() != exact.last_storage());
    fill_with(&mut rig.slices[0].0, |_, _| [255, 255, 255, 255]);
    image(&mut rig, &roomy, &larger);
    fill_with(&mut rig.slices[0].0, stripe);
    let got = image(&mut rig, &roomy, &draw);
    let worst = expected
        .iter()
        .zip(&got)
        .map(|(a, b)| (0..4).map(|c| a[c].abs_diff(b[c])).max().unwrap())
        .max()
        .unwrap();
    assert!(worst <= 1, "largest channel difference {worst}");
}

/// A half-transparent black client over a white scene, with black glass
/// behind it: above the threshold the glass shows through the client
/// (dark); below it the client composites plainly (mid gray).
#[test]
#[ignore = "needs a GPU"]
fn window_shows_its_material_above_the_threshold() {
    use denial_flutter_engine::scene::WindowStyle;
    let mut rig = rig(2, false);
    fill_with(&mut rig.slices[0].0, |_, _| [255, 255, 255, 255]);
    // Premultiplied black at half alpha.
    fill_with(&mut rig.slices[1].0, |_, _| [0, 0, 0, 128]);
    let rect = Rect {
        left: 40.0,
        top: 20.0,
        right: 216.0,
        bottom: 108.0,
    };
    let style = WindowStyle {
        bounds: rect,
        content_bounds: rect,
        material_bounds: None,
        radius: 0.0,
        frame_color: 0,
        direct_texture: true,
    };
    let local = record::tests::plain_local();
    let client = Arc::clone(&rig.slices[1].1);
    let placement = record::Placement::new(rect, client.size, None).expect("placement");
    let draw = record::window(
        &local,
        ClipSpan::default(),
        &record::ndc_from_target(W, H),
        &style,
        &Matrix3::IDENTITY,
        1.0,
        Some((&placement, client.size)),
    )
    .expect("window draw");
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut center = |threshold: f32| {
        let mut material = record::tests::glass_material(
            [rect.left, rect.top, rect.right, rect.bottom],
            [[0.0; 2]; 4],
        );
        material.alpha_threshold = threshold;
        let behind = record::window_material(
            &material,
            None,
            &local,
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            rig.target.size,
        )
        .expect("supported material")
        .expect("visible material");
        let frost = Arc::new(Frost::new(&rig.gpu, behind.plan).expect("frost"));
        let (mut draws, mut steps) = scene(&rig, 1, false);
        let index = draws.len() as u32;
        draws.push(draw.with_glass(0));
        steps.push(Step::Material(MaterialStep {
            record: 0,
            plan: behind.plan,
            frost: Some(frost),
            fresh: true,
            below: 0,
            made: 0,
            frozen: None,
            window: Some(WindowDraw {
                draw: index,
                image: Arc::clone(&client),
                look: Arc::clone(&rig.no_look),
                nearest: true,
                content: 0,
                layers: None,
            }),
        }));
        submit_and_wait(&rig, &mut frame, &draws, &[behind.glass], &steps);
        // Target row 64 is memory row H - 1 - 64.
        (
            pixel(&rig.target_buffer, 128, H - 1 - 64),
            pixel(&rig.target_buffer, 20, H - 1 - 64),
        )
    };
    let (inside, outside) = center(0.2);
    assert!(
        inside[..3].iter().all(|&c| c < 8),
        "glass behind the client: {inside:?}"
    );
    assert_eq!(outside, [255, 255, 255, 255]);
    let (inside, _) = center(0.6);
    assert!(
        inside[..3].iter().all(|&c| c.abs_diff(127) <= 2),
        "below the threshold the client composites plainly: {inside:?}"
    );
}

/// A half-transparent dark red client over black, through an inverting
/// look: graded in straight color and premultiplied again, as GLES grades
/// its copy.
#[test]
#[ignore = "needs a GPU"]
fn window_client_is_graded_through_its_look() {
    use denial_flutter_engine::scene::WindowStyle;
    let mut rig = rig(2, false);
    fill_with(&mut rig.slices[0].0, |_, _| [0, 0, 0, 255]);
    // Premultiplied: straight (0.5, 0, 0) at half alpha.
    fill_with(&mut rig.slices[1].0, |_, _| [64, 0, 0, 128]);
    // Two entries per axis, red fastest: each entry is its own inverse.
    let mut texels = Vec::new();
    for b in 0..2 {
        for g in 0..2 {
            for r in 0..2 {
                texels.extend([1.0 - r as f32, 1.0 - g as f32, 1.0 - b as f32, 1.0]);
            }
        }
    }
    let invert = rig.gpu.look_image(2, &texels).expect("look");
    let rect = Rect {
        left: 40.0,
        top: 20.0,
        right: 216.0,
        bottom: 108.0,
    };
    let style = WindowStyle {
        bounds: rect,
        content_bounds: rect,
        material_bounds: None,
        radius: 0.0,
        frame_color: 0,
        direct_texture: true,
    };
    let client = Arc::clone(&rig.slices[1].1);
    let placement = record::Placement::new(rect, client.size, None).expect("placement");
    let draw = record::window(
        &record::tests::plain_local(),
        ClipSpan::default(),
        &record::ndc_from_target(W, H),
        &style,
        &Matrix3::IDENTITY,
        1.0,
        Some((&placement, client.size)),
    )
    .expect("window draw");
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut center = |look: Option<&Arc<Image>>| {
        let (mut draws, mut steps) = scene(&rig, 1, false);
        let index = draws.len() as u32;
        draws.push(draw.with_look(look.is_some()));
        steps.push(Step::Draws(Batch {
            image: Arc::clone(&client),
            look: Arc::clone(look.unwrap_or(&rig.no_look)),
            nearest: true,
            first: index,
            count: 1,
            content: 0,
            layers: None,
        }));
        submit_and_wait(&rig, &mut frame, &draws, &[], &steps);
        pixel(&rig.target_buffer, 128, H - 1 - 64)
    };
    let plain = center(None);
    assert!(
        plain[0].abs_diff(64) <= 1 && plain[1] < 2 && plain[2] < 2,
        "no look: {plain:?}"
    );
    let graded = center(Some(&invert));
    assert!(
        graded[0].abs_diff(64) <= 2 && graded[1].abs_diff(128) <= 2 && graded[2].abs_diff(128) <= 2,
        "inverted at half alpha: {graded:?}"
    );
}

/// A slice drawn through twelve nested clips, which no longer fit in a draw
/// record: the clip buffer holds them after three unrelated clips that
/// would hide everything, so the draw must read its own run.
#[test]
#[ignore = "needs a GPU"]
fn a_draw_reads_any_number_of_clips_from_its_own_run() {
    use denial_flutter_engine::scene::Clip;
    let rig = rig(1, false);
    let (mut draws, batches) = scene(&rig, 1, false);
    let rect = |inset: f32| Clip {
        scene_to_clip: Matrix3::IDENTITY,
        rect: Rect {
            left: inset,
            top: inset,
            right: W as f32 - inset,
            bottom: H as f32 - inset,
        },
        radii: [[0.0; 2]; 4],
        path: None,
    };
    let hidden = [Clip {
        rect: Rect {
            left: 0.0,
            top: 0.0,
            right: 0.0,
            bottom: 0.0,
        },
        ..rect(0.0)
    }; 3];
    let nested: Vec<Clip> = (0..12).map(|inset| rect(inset as f32)).collect();
    let mut clips = Vec::new();
    let first = record::intern_clips(&hidden, ClipSpan::default(), &mut clips);
    let span = record::intern_clips(&nested, first, &mut clips);
    assert_eq!((span.first, span.count, clips.len()), (3, 12, 15));
    record::inside_material(&mut draws[0], span, 1.0, &Matrix3::IDENTITY);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let done = frame
        .submit(
            1,
            &rig.target,
            &draws,
            &[],
            &clips,
            &[],
            &[],
            &batches,
            &[],
            WHOLE,
            None,
            None,
        )
        .expect("submit");
    if let Some(done) = done {
        assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
    }
    let inside = |x: u32, row: u32| (11..W - 11).contains(&x) && (11..H - 11).contains(&row);
    let mut wrong = None;
    rig.target_buffer
        .map(0, 0, W, H, |mapping| {
            for row in 0..H {
                for x in 0..W {
                    let at = row as usize * mapping.stride() as usize + x as usize * 4;
                    let got: [u8; 4] = mapping.buffer()[at..at + 4].try_into().unwrap();
                    let shown = got[3] != 0;
                    if shown != inside(x, row) && wrong.is_none() {
                        wrong = Some((x, row, got));
                    }
                }
            }
        })
        .expect("map target");
    assert_eq!(wrong, None, "first pixel on the wrong side of the clips");
}

/// A native window's layers merged into its image before the frame draws,
/// as the GLES pass merges them: an opaque full layer; over it a
/// half-transparent one at half opacity, turned half a turn; and one whose
/// right half reaches past its buffer, which leaves the layer below as it
/// is there. The frame then copies the merged image into the target.
#[test]
#[ignore = "needs a GPU"]
fn native_window_layers_merge_as_the_gles_pass() {
    let rig = rig(0, false);
    let layer = |size: (u32, u32), color: &dyn Fn(u32, u32) -> [u8; 4]| {
        let mut rgba = Vec::with_capacity((size.0 * size.1 * 4) as usize);
        for y in 0..size.1 {
            for x in 0..size.0 {
                rgba.extend_from_slice(&color(x, y));
            }
        }
        let frame =
            super::super::ShmTextureFrame::new_owned(size.0, size.1, 1, rgba).expect("SHM frame");
        let image = rig.gpu.upload_image(size).expect("layer image");
        (image, frame)
    };
    // Premultiplied: color at most alpha.
    let top = |x: u32, y: u32| [(x * 2) as u8, (y * 4) as u8, 0, 128];
    let (below, below_pixels) = layer((W, H), &pattern);
    let (above, above_pixels) = layer((64, 32), &top);
    let limits = |(w, h): (u32, u32)| {
        let (w, h) = (w as f32, h as f32);
        [0.5 / w, 0.5 / h, 1.0 - 0.5 / w, 1.0 - 0.5 / h]
    };
    let merged = rig.gpu.merge_image((W, H)).expect("merge image");
    let ndc = record::ndc_from_target(W, H);
    let rect = [0.0, 0.0, f64::from(W), f64::from(H)];
    let draws = [
        record::merged_layer(
            (W, H),
            [0.0, 0.0, W as f32, H as f32],
            [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]],
            limits((W, H)),
            1.0,
        )
        .expect("lower layer"),
        record::merged_layer(
            (W, H),
            [32.0, 16.0, 96.0, 48.0],
            [[1.0, 1.0], [0.0, 1.0], [1.0, 0.0]],
            limits((64, 32)),
            0.5,
        )
        .expect("upper layer"),
        record::merged_layer(
            (W, H),
            [128.0, 80.0, 256.0, 112.0],
            [[0.0, 0.0], [2.0, 0.0], [0.0, 1.0]],
            limits((64, 32)),
            1.0,
        )
        .expect("layer past its buffer"),
        record::slice_blit(
            &SliceBlit {
                source: rect,
                destination: rect,
            },
            merged.size,
            false,
            &ndc,
        ),
    ];
    let batch = |image: &Arc<Image>, nearest: bool, first: u32| Batch {
        image: Arc::clone(image),
        look: Arc::clone(&rig.no_look),
        nearest,
        first,
        count: 1,
        content: 0,
        layers: None,
    };
    let merges = [Merge {
        image: Arc::clone(&merged),
        batches: vec![batch(&below, false, 0), {
            let mut both = batch(&above, false, 1);
            both.count = 2;
            both
        }],
        area: None,
    }];
    let steps = [Step::Draws(batch(&merged, true, 3))];
    let uploads = [
        Upload {
            image: Arc::clone(&below),
            frame: below_pixels,
            fresh: true,
        },
        Upload {
            image: Arc::clone(&above),
            frame: above_pixels,
            fresh: true,
        },
    ];
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let done = frame
        .submit(
            1,
            &rig.target,
            &draws,
            &[],
            &[],
            &[],
            &merges,
            &steps,
            &uploads,
            WHOLE,
            None,
            None,
        )
        .expect("submit");
    if let Some(done) = done {
        assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
    }
    let expected = |x: u32, y: u32| -> [f32; 4] {
        let below = pattern(x, y).map(|c| f32::from(c) / 255.0);
        if (128..192).contains(&x) && (80..112).contains(&y) {
            let above = top(x - 128, y - 80).map(|c| f32::from(c) / 255.0);
            return std::array::from_fn(|c| above[c] + below[c] * (1.0 - above[3]));
        }
        if !((32..96).contains(&x) && (16..48).contains(&y)) {
            return below;
        }
        // Half a turn: the layer's last texel at the quad's first pixel.
        let above = top(63 - (x - 32), 31 - (y - 16)).map(|c| f32::from(c) / 255.0 * 0.5);
        std::array::from_fn(|c| above[c] + below[c] * (1.0 - above[3]))
    };
    let first_wrong = |expected: &dyn Fn(u32, u32) -> [f32; 4]| {
        let mut wrong = None;
        rig.target_buffer
            .map(0, 0, W, H, |mapping| {
                for row in 0..H {
                    for x in 0..W {
                        let at = row as usize * mapping.stride() as usize + x as usize * 4;
                        let got: [u8; 4] = mapping.buffer()[at..at + 4].try_into().unwrap();
                        // A top-down image lands bottom-up in the target.
                        let want = expected(x, H - 1 - row).map(|c| (c * 255.0).round() as i32);
                        let off = (0..4).any(|c| (i32::from(got[c]) - want[c]).abs() > 1);
                        if off && wrong.is_none() {
                            wrong = Some((x, row, got, want));
                        }
                    }
                }
            })
            .expect("map target");
        wrong
    };
    assert_eq!(
        first_wrong(&expected),
        None,
        "first pixel off by more than one"
    );

    // Drawn again within an area, without the upper layer: the area shows
    // the layer below, and the rest of the image stays as it was.
    let area = [40, 20, 30, 20];
    let merges = [Merge {
        image: Arc::clone(&merged),
        batches: vec![batch(&below, false, 0)],
        area: Some(area),
    }];
    assert!(frame.idle());
    let done = frame
        .submit(
            2,
            &rig.target,
            &draws,
            &[],
            &[],
            &[],
            &merges,
            &steps,
            &[],
            WHOLE,
            None,
            None,
        )
        .expect("submit");
    if let Some(done) = done {
        assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
    }
    let in_area = |x: u32, y: u32| {
        (area[0]..area[0] + area[2]).contains(&x) && (area[1]..area[1] + area[3]).contains(&y)
    };
    let expected_after = |x: u32, y: u32| match in_area(x, y) {
        true => pattern(x, y).map(|c| f32::from(c) / 255.0),
        false => expected(x, y),
    };
    assert_eq!(
        first_wrong(&expected_after),
        None,
        "first pixel off by more than one after a partial merge"
    );
}

/// The layers of `native_window_layers_merge_as_the_gles_pass`, drawn from
/// their own images by one draw each time: as a texture, as a window and
/// as a window over its material. The target shows what the merged image
/// would, and nothing is merged.
#[test]
#[ignore = "needs a GPU"]
fn native_window_layers_draw_without_a_merge() {
    use denial_flutter_engine::scene::WindowStyle;
    let rig = rig(1, false);
    assert!(rig.gpu.layered(), "the GPU passes the layered varyings");
    let layer = |size: (u32, u32), color: &dyn Fn(u32, u32) -> [u8; 4]| {
        let mut rgba = Vec::with_capacity((size.0 * size.1 * 4) as usize);
        for y in 0..size.1 {
            for x in 0..size.0 {
                rgba.extend_from_slice(&color(x, y));
            }
        }
        let frame =
            super::super::ShmTextureFrame::new_owned(size.0, size.1, 1, rgba).expect("SHM frame");
        let image = rig.gpu.upload_image(size).expect("layer image");
        (image, frame)
    };
    // Premultiplied: color at most alpha.
    let top = |x: u32, y: u32| [(x * 2) as u8, (y * 4) as u8, 0, 128];
    let (below, below_pixels) = layer((W, H), &pattern);
    let (above, above_pixels) = layer((64, 32), &top);
    let limits = |(w, h): (u32, u32)| {
        let (w, h) = (w as f32, h as f32);
        [0.5 / w, 0.5 / h, 1.0 - 0.5 / w, 1.0 - 0.5 / h]
    };
    let layers = [
        record::Layer {
            quad: [0.0, 0.0, W as f32, H as f32],
            uv: [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]],
            limits: limits((W, H)),
            opacity: 1.0,
        },
        // Half a turn, at half opacity.
        record::Layer {
            quad: [32.0, 16.0, 96.0, 48.0],
            uv: [[1.0, 1.0], [0.0, 1.0], [1.0, 0.0]],
            limits: limits((64, 32)),
            opacity: 0.5,
        },
        // Its right half reaches past its buffer.
        record::Layer {
            quad: [128.0, 80.0, 256.0, 112.0],
            uv: [[0.0, 0.0], [2.0, 0.0], [0.0, 1.0]],
            limits: limits((64, 32)),
            opacity: 1.0,
        },
    ];
    let further: device::Layers =
        Arc::new([Arc::clone(&above), Arc::clone(&above), Arc::clone(&below)]);
    let whole = Rect {
        left: 0.0,
        top: 0.0,
        right: W as f32,
        bottom: H as f32,
    };
    let ndc = record::ndc_from_target(W, H);
    let local = record::tests::plain_local();
    let placement = record::Placement::new(whole, (W, H), None).expect("placement");
    // The records of the further layers first, then the draw that names
    // them.
    let records = |mut draw: record::Draw| {
        let (further, kept) = record::layered(&mut draw, (W, H), &layers).expect("layered draw");
        assert_eq!(kept, [true, true, true, false]);
        draw.set_layers(0);
        let mut draws = further.to_vec();
        draws.push(draw);
        draws
    };
    let style = WindowStyle {
        bounds: whole,
        content_bounds: whole,
        material_bounds: None,
        radius: 0.0,
        frame_color: 0,
        direct_texture: true,
    };
    let window = record::window(
        &local,
        ClipSpan::default(),
        &ndc,
        &style,
        &Matrix3::IDENTITY,
        1.0,
        Some((&placement, (W, H))),
    )
    .expect("window draw");
    let expected = |x: u32, y: u32| -> [f32; 4] {
        let below = pattern(x, y).map(|c| f32::from(c) / 255.0);
        if (128..192).contains(&x) && (80..112).contains(&y) {
            let above = top(x - 128, y - 80).map(|c| f32::from(c) / 255.0);
            return std::array::from_fn(|c| above[c] + below[c] * (1.0 - above[3]));
        }
        if !((32..96).contains(&x) && (16..48).contains(&y)) {
            return below;
        }
        // Half a turn: the layer's last texel at the quad's first pixel.
        let above = top(63 - (x - 32), 31 - (y - 16)).map(|c| f32::from(c) / 255.0 * 0.5);
        std::array::from_fn(|c| above[c] + below[c] * (1.0 - above[3]))
    };
    let first_wrong = || {
        let mut wrong = None;
        rig.target_buffer
            .map(0, 0, W, H, |mapping| {
                for row in 0..H {
                    for x in 0..W {
                        let at = row as usize * mapping.stride() as usize + x as usize * 4;
                        let got: [u8; 4] = mapping.buffer()[at..at + 4].try_into().unwrap();
                        // Target row y is memory row H - 1 - y.
                        let want = expected(x, H - 1 - row).map(|c| (c * 255.0).round() as i32);
                        let off = (0..4).any(|c| (i32::from(got[c]) - want[c]).abs() > 1);
                        if off && wrong.is_none() {
                            wrong = Some((x, row, got, want));
                        }
                    }
                }
            })
            .expect("map target");
        wrong
    };
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut serial = 0;
    let mut submit =
        |draws: &[record::Draw], glasses: &[record::Glass], steps: &[Step], uploads: &[Upload]| {
            serial += 1;
            assert!(frame.idle());
            let done = frame
                .submit(
                    serial,
                    &rig.target,
                    draws,
                    glasses,
                    &[],
                    &[],
                    &[],
                    steps,
                    uploads,
                    WHOLE,
                    None,
                    None,
                )
                .expect("submit");
            if let Some(done) = done {
                assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
            }
        };
    let batch = |first: u32| Batch {
        image: Arc::clone(&below),
        look: Arc::clone(&rig.no_look),
        nearest: false,
        first,
        count: 1,
        content: 0,
        layers: Some(Arc::clone(&further)),
    };

    // A texture.
    let texture = record::texture(&local, ClipSpan::default(), &ndc, &placement, (W, H))
        .expect("texture draw");
    let uploads = [
        Upload {
            image: Arc::clone(&below),
            frame: below_pixels,
            fresh: true,
        },
        Upload {
            image: Arc::clone(&above),
            frame: above_pixels,
            fresh: true,
        },
    ];
    submit(&records(texture), &[], &[Step::Draws(batch(3))], &uploads);
    assert_eq!(
        first_wrong(),
        None,
        "texture: first pixel off by more than one"
    );

    // A window. Every frame clears the target first.
    submit(&records(window), &[], &[Step::Draws(batch(3))], &[]);
    assert_eq!(
        first_wrong(),
        None,
        "window: first pixel off by more than one"
    );

    // A window over its material: opaque, so the material stays behind it.
    let material = record::tests::glass_material([0.0, 0.0, W as f32, H as f32], [[0.0; 2]; 4]);
    let behind = record::window_material(
        &material,
        None,
        &local,
        ClipSpan::default(),
        &Matrix3::IDENTITY,
        rig.target.size,
    )
    .expect("supported material")
    .expect("visible material");
    let frost = Arc::new(Frost::new(&rig.gpu, behind.plan).expect("frost"));
    let (mut draws, mut steps) = scene(&rig, 1, false);
    let first = draws.len() as u32;
    draws.extend(records(window.with_glass(0)));
    draws[first as usize + 3].set_layers(first);
    steps.push(Step::Material(MaterialStep {
        record: 0,
        plan: behind.plan,
        frost: Some(frost),
        fresh: true,
        below: 0,
        made: 0,
        frozen: None,
        window: Some(WindowDraw {
            draw: first + 3,
            image: Arc::clone(&below),
            look: Arc::clone(&rig.no_look),
            nearest: false,
            content: 0,
            layers: Some(Arc::clone(&further)),
        }),
    }));
    submit(&draws, &[behind.glass], &steps, &[]);
    assert_eq!(
        first_wrong(),
        None,
        "window over its material: first pixel off by more than one"
    );
}

/// A slice drawn through a path clip, a five-pointed star drawn in one
/// stroke whose edges cross, in a space shifted from the scene: under the
/// nonzero rule its centre is in, under even-odd out, and a path without
/// edges hides everything. Each pixel is in when its centre is, as the
/// engine's single-sample stencil fill decides.
#[test]
#[ignore = "needs a GPU"]
fn a_path_clip_fills_by_its_rule_at_pixel_centres() {
    use denial_flutter_engine::scene::{Clip, ClipPath};
    let rig = rig(1, false);
    let shift = [10.0f32, 5.0];
    let star: Vec<[f64; 2]> = (0..5)
        .map(|k| {
            let angle = f64::from(k) * 144f64.to_radians() + 0.05;
            [
                128.37 + f64::from(shift[0]) + 60.0 * angle.sin(),
                64.21 + f64::from(shift[1]) - 60.0 * angle.cos(),
            ]
        })
        .collect();
    let edges: Vec<[f32; 4]> = (0..5)
        .map(|k| {
            let (a, b) = (star[k], star[(k + 1) % 5]);
            [a[0] as f32, a[1] as f32, b[0] as f32, b[1] as f32]
        })
        .collect();
    // The rule at a scene point, in f64.
    let inside = |x: f64, y: f64, even_odd: bool| {
        let (x, y) = (x + f64::from(shift[0]), y + f64::from(shift[1]));
        let mut winding = 0i32;
        for k in 0..5 {
            let (a, b) = (star[k], star[(k + 1) % 5]);
            if (a[1] <= y) != (b[1] <= y) && a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]) > x {
                winding += if b[1] > a[1] { 1 } else { -1 };
            }
        }
        if even_odd {
            winding & 1 != 0
        } else {
            winding != 0
        }
    };
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    for (path, expect) in [
        (
            ClipPath {
                first: 0,
                count: 5,
                even_odd: false,
            },
            Some(false),
        ),
        (
            ClipPath {
                first: 0,
                count: 5,
                even_odd: true,
            },
            Some(true),
        ),
        (
            ClipPath {
                first: 0,
                count: 0,
                even_odd: false,
            },
            None,
        ),
    ] {
        let (mut draws, batches) = scene(&rig, 1, false);
        let clip = Clip {
            scene_to_clip: Matrix3([1.0, 0.0, shift[0], 0.0, 1.0, shift[1], 0.0, 0.0, 1.0]),
            rect: Rect {
                left: 0.0,
                top: 0.0,
                right: 400.0,
                bottom: 200.0,
            },
            radii: [[0.0; 2]; 4],
            path: Some(path),
        };
        let mut clips = Vec::new();
        let span = record::intern_clips(&[clip], ClipSpan::default(), &mut clips);
        record::inside_material(&mut draws[0], span, 1.0, &Matrix3::IDENTITY);
        let done = frame
            .submit(
                1,
                &rig.target,
                &draws,
                &[],
                &clips,
                &edges,
                &[],
                &batches,
                &[],
                WHOLE,
                None,
                None,
            )
            .expect("submit");
        if let Some(done) = done {
            assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
        }
        assert!(frame.idle());
        let mut wrong = None;
        let mut shown_count = 0;
        rig.target_buffer
            .map(0, 0, W, H, |mapping| {
                for row in 0..H {
                    // Targets are bottom-up in memory.
                    let y = H - 1 - row;
                    for x in 0..W {
                        let at = row as usize * mapping.stride() as usize + x as usize * 4;
                        let got: [u8; 4] = mapping.buffer()[at..at + 4].try_into().unwrap();
                        let shown = got[3] != 0;
                        shown_count += usize::from(shown);
                        let wanted = expect.is_some_and(|even_odd| {
                            inside(f64::from(x) + 0.5, f64::from(y) + 0.5, even_odd)
                        });
                        if shown != wanted && wrong.is_none() {
                            wrong = Some((x, y, got));
                        }
                    }
                }
            })
            .expect("map target");
        assert_eq!(wrong, None, "{path:?}: first pixel on the wrong side");
        assert_eq!(
            shown_count == 0,
            expect.is_none(),
            "{path:?}: {shown_count} pixels shown"
        );
    }
}

/// The target's bytes, memory row by memory row.
fn snapshot(buffer: &GbmBuffer) -> Vec<[u8; 4]> {
    buffer
        .map(0, 0, W, H, |mapping| {
            let stride = mapping.stride() as usize;
            let bytes = mapping.buffer();
            (0..H as usize)
                .flat_map(|y| (0..W as usize).map(move |x| (y, x)))
                .map(|(y, x)| bytes[y * stride + x * 4..][..4].try_into().unwrap())
                .collect()
        })
        .expect("map target")
}

/// A frame that redraws part of the target draws the new scene there and
/// leaves every other pixel as the last frame left it; one that redraws
/// nothing leaves the target alone.
#[test]
#[ignore = "needs a GPU"]
fn a_partial_redraw_keeps_the_pixels_outside_it() {
    let mut rig = rig(1, false);
    let (draws, steps) = scene(&rig, 1, false);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    submit_and_wait(&rig, &mut frame, &draws, &[], &steps);
    assert_eq!(mismatches(&rig.target_buffer).0, 0, "first frame");
    let red = [200, 0, 0, 255];
    fill_with(&mut rig.slices[0].0, |_, _| red);
    let area = [40, 30, 121, 91];
    submit_area_and_wait(&rig, &mut frame, &draws, &[], &steps, area);
    let pixels = snapshot(&rig.target_buffer);
    let mut wrong = 0;
    for (index, &got) in pixels.iter().enumerate() {
        let (x, row) = ((index % W as usize) as i32, (index / W as usize) as i32);
        // Target row y is memory row H - 1 - y.
        let y = H as i32 - 1 - row;
        let inside = (area[0]..area[2]).contains(&x) && (area[1]..area[3]).contains(&y);
        let expected = if inside {
            red
        } else {
            pattern(x as u32, H - 1 - row as u32)
        };
        wrong += usize::from(got != expected);
    }
    assert_eq!(wrong, 0, "pixels wrong after a partial redraw");
    fill_with(&mut rig.slices[0].0, |_, _| [0, 200, 0, 255]);
    submit_area_and_wait(&rig, &mut frame, &draws, &[], &steps, [0; 4]);
    assert_eq!(
        snapshot(&rig.target_buffer),
        pixels,
        "a frame without damage changed the target"
    );
}

/// A frost made again in a partial frame reads the scene below it as a
/// full redraw does, once the frame redraws the frost's whole region (as
/// the composer grows the damage); redrawing less, the copy reads the last
/// frame's material over itself.
#[test]
#[ignore = "needs a GPU"]
fn a_frost_remade_in_a_partial_frame_matches_a_full_redraw() {
    let rig = rig(1, false);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut frost = None;
    // Low in the target, so its region is far from symmetric in rows.
    let (draws, glasses, steps) =
        material_scene(&rig, [37.0, 10.0, 211.0, 40.0], 6.0, &mut frost, true);
    let Some(Step::Material(material)) = steps.last() else {
        unreachable!("material_scene ends with its material");
    };
    let region = material.plan.region;
    assert!(
        region[3] < H as i32 - 20,
        "region {region:?} spans the target"
    );
    submit_and_wait(&rig, &mut frame, &draws, &glasses, &steps);
    let full = snapshot(&rig.target_buffer);
    let damage = [100, 20, 110, 30];
    submit_area_and_wait(&rig, &mut frame, &draws, &glasses, &steps, damage);
    let differing = snapshot(&rig.target_buffer)
        .iter()
        .zip(&full)
        .filter(|(got, full)| got != full)
        .count();
    assert!(differing > 0, "the copy should have read the last frame");
    submit_and_wait(&rig, &mut frame, &draws, &glasses, &steps);
    assert_eq!(snapshot(&rig.target_buffer), full, "full redraw");
    let grown = record::pixels_union(damage, region);
    submit_area_and_wait(&rig, &mut frame, &draws, &glasses, &steps, grown);
    let differing = snapshot(&rig.target_buffer)
        .iter()
        .zip(&full)
        .filter(|(got, full)| got != full)
        .count();
    assert_eq!(
        differing, 0,
        "a grown partial frame differs from a full one"
    );
}

/// Copies every client as `image` (None: GLES cannot read it either).
struct CopyAs {
    image: Option<Arc<Image>>,
    calls: u32,
}

impl super::Resolve for CopyAs {
    fn client(&mut self, _: i64, _: Rect) -> Result<super::Client, super::Decline> {
        unreachable!("the test resolves no scene")
    }

    fn copy(&mut self, _: &super::SampledClient) -> Result<Option<Arc<Image>>, super::Decline> {
        self.calls += 1;
        Ok(self.image.clone())
    }
}

#[test]
#[ignore = "needs a GPU"]
fn a_client_the_composer_cannot_import_is_copied_by_gles() {
    let (composer, _target) = composer_with_target();
    let gbm = GbmDevice::new(DrmDeviceFd::new(smithay::utils::DeviceFd::from(node()))).unwrap();
    // A format the composer does not sample.
    let bo = gbm
        .create_buffer_object_with_modifiers::<()>(W, H, Fourcc::R8, [Modifier::Linear].into_iter())
        .expect("linear R8 buffer");
    let sampled = super::SampledClient {
        texture_id: 7,
        generation: 1,
        source: super::super::ExternalTextureSource::Dmabuf {
            dmabuf: GbmBuffer::from_bo(bo, false).export().unwrap(),
            buffer_guard: None,
            revision: 1,
            feedback: None,
            color: None,
            opaque: false,
        },
    };
    let mut state = super::lock(&composer.state);
    let mut uploads = Vec::new();
    let mut copy = CopyAs {
        image: Some(Arc::clone(&composer.placeholder)),
        calls: 0,
    };
    let resolved = composer
        .client_image(&mut state, &mut uploads, &sampled, &mut copy)
        .expect("not declined");
    assert!(
        matches!(&resolved, super::Resolved::Copied(image) if Arc::ptr_eq(image, &composer.placeholder))
    );
    assert_eq!(copy.calls, 1);
    // Unreadable by GLES too: left out, as the GLES pass does.
    let mut unreadable = CopyAs {
        image: None,
        calls: 0,
    };
    let resolved = composer
        .client_image(&mut state, &mut uploads, &sampled, &mut unreadable)
        .expect("not declined");
    assert!(matches!(resolved, super::Resolved::Unreadable));
}

/// A native window of up to four layers is staged as one draw over its
/// layers' own images, with nothing merged; a window of more is merged
/// into an image first.
#[test]
#[ignore = "needs a GPU"]
fn a_native_window_is_staged_from_its_layers() {
    let (composer, _target) = composer_with_target();
    assert!(
        composer.gpu.layered(),
        "the GPU passes the layered varyings"
    );
    let layer = |texture_id: i64| {
        let pixels = vec![128; (W * H * 4) as usize];
        let frame = super::super::ShmTextureFrame::new_owned(W, H, 1, pixels).expect("SHM frame");
        super::MergedLayer {
            sampled: super::SampledClient {
                texture_id,
                generation: 1,
                source: super::super::ExternalTextureSource::Shm(frame),
            },
            quad: [0.0, 0.0, W as f32, H as f32],
            uv: [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]],
            limits: [0.0, 0.0, 1.0, 1.0],
            opacity: 0.5,
            history: Default::default(),
        }
    };
    let whole = Rect {
        left: 0.0,
        top: 0.0,
        right: W as f32,
        bottom: H as f32,
    };
    let window = |layers: i64| super::Client::Merged {
        placement: record::Placement::new(whole, (W, H), None).expect("placement"),
        merged: super::MergedClient {
            texture_id: 100,
            app: None,
            size: (W, H),
            layers: (1..=layers).map(layer).collect(),
            unseen: Vec::new(),
        },
        look: None,
    };
    let mut state = super::lock(&composer.state);
    let mut copy = CopyAs {
        image: None,
        calls: 0,
    };
    let mut staged = empty_staged(1);
    let mut client = composer
        .resolved_image(&mut state, &mut staged, window(4), &mut copy)
        .expect("not declined")
        .expect("a client");
    assert!(staged.merges.is_empty(), "nothing is merged");
    assert_eq!(staged.layered, 1);
    assert_eq!(staged.clients.len(), 4, "every layer's buffer is shown");
    assert!(!client.opaque, "half-transparent layers hide nothing");
    let mut draw = record::texture(
        &record::tests::plain_local(),
        ClipSpan::default(),
        &record::ndc_from_target(W, H),
        &client.placement,
        client.size,
    )
    .expect("texture draw");
    let layers = client
        .layer(&mut draw, &mut staged.draws)
        .expect("not declined")
        .expect("a layered draw");
    assert_eq!(staged.draws.len(), 3, "the records of the further layers");
    // The draw samples the lowest layer's image, and the others in order.
    let image = |texture_id: i64| &state.uploads[&texture_id].image;
    assert!(Arc::ptr_eq(&client.image, image(1)));
    for (index, layer) in layers.iter().enumerate() {
        assert!(Arc::ptr_eq(layer, image(index as i64 + 2)));
    }

    let mut staged = empty_staged(1);
    let client = composer
        .resolved_image(&mut state, &mut staged, window(5), &mut copy)
        .expect("not declined")
        .expect("a client");
    assert!(client.layers.is_none());
    assert_eq!(staged.merges.len(), 1, "five layers are merged");
    assert_eq!(staged.layered, 0);
    assert_eq!(copy.calls, 0);
}

#[test]
#[ignore = "needs a GPU"]
fn conversions_are_waited_for_until_a_submission_succeeds() {
    let (composer, _target) = composer_with_target();
    assert!(matches!(
        composer.producer_wait(),
        super::ProducerWait::None
    ));
    // GLES converted a client.
    super::lock(&composer.converts).unwaited = true;
    assert!(matches!(
        composer.producer_wait(),
        super::ProducerWait::Fresh
    ));
    // A failed submission did not wait for it.
    assert!(
        composer
            .submit(&mut empty_staged(-1), 2, NO_DAMAGE, None)
            .is_err()
    );
    assert!(super::lock(&composer.converts).unwaited);
    let submitted = composer
        .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
        .expect("frame");
    if let Some(completion) = submitted.completion {
        assert!(wait_fd(completion.as_fd(), 5000));
    }
    assert!(!super::lock(&composer.converts).unwaited);
    assert!(matches!(
        composer.producer_wait(),
        super::ProducerWait::None
    ));
}

#[test]
#[ignore = "needs a GPU"]
fn lent_images_come_back_after_the_engine_read_them() {
    let (composer, _target) = composer_with_target();
    // A frame's completion stands in for the GLES fence after the copies.
    let submitted = composer
        .submit(&mut empty_staged(-1), 1, NO_DAMAGE, None)
        .expect("frame");
    let images = vec![Arc::clone(&composer.placeholder)];
    let lent = composer
        .gpu
        .transfer(images.clone(), true, submitted.completion)
        .expect("lend");
    let returned = composer.gpu.transfer(images, false, None).expect("return");
    let start = std::time::Instant::now();
    while !(lent.done() && returned.done()) {
        assert!(start.elapsed() < std::time::Duration::from_secs(5));
        std::thread::yield_now();
    }
    // Neither transfer holds the image once dropped.
    drop((lent, returned));
    assert_eq!(Arc::strong_count(&composer.placeholder), 1);
}

/// A draw or material an opaque draw above holds whole is left out; one
/// that reaches past every cover is drawn. A client is hidden on the target
/// only under a cover: off the target, another output may show it.
#[test]
#[ignore = "needs a GPU"]
fn what_an_opaque_draw_hides_is_left_out() {
    let rig = rig(1, false);
    let (w, h) = (f64::from(W), f64::from(H));
    let staged = |cover: [i32; 4], destination: Option<[f64; 4]>| {
        let (mut draws, mut steps) = scene(&rig, 1, false);
        if let Some(destination) = destination {
            let blit = SliceBlit {
                source: [0.0, 0.0, w, h],
                destination,
            };
            draws[0] = record::slice_blit(
                &blit,
                rig.slices[0].1.size,
                false,
                &record::ndc_from_target(W, H),
            );
        }
        let material = blur_material(&rig, [10.0, 10.0, 50.0, 50.0], 4.0);
        let mut staged = empty_staged(1);
        staged.glasses.push(material.glass);
        staged.outputs.push(material.output);
        staged.backdrop_tokens.push(Some(1));
        staged.engine_tokens.push(Some(1));
        steps.push(Step::Material(MaterialStep {
            record: 0,
            plan: material.plan,
            frost: None,
            fresh: false,
            below: 0,
            made: 0,
            frozen: None,
            window: None,
        }));
        // The cover: the slice again, over everything.
        draws.push(draws[0]);
        steps.push(Step::Draws(Batch {
            image: Arc::clone(&rig.slices[0].1),
            look: Arc::clone(&rig.no_look),
            nearest: true,
            first: 1,
            count: 1,
            content: 0,
            layers: None,
        }));
        staged.draws = draws;
        staged.steps = steps;
        staged.covers.push((1, cover));
        // Draw 0 shows client texture 7.
        staged.client_draws.push((7, 0));
        super::cull(&mut staged, (W, H));
        staged
    };
    let whole = [0, 0, W as i32, H as i32];
    let hidden = staged(whole, None);
    assert_eq!((hidden.culled_draws, hidden.culled_materials), (1, 1));
    assert_eq!(hidden.hidden_textures, [7]);
    assert!(matches!(hidden.steps.as_slice(), [Step::Draws(batch)] if batch.first == 1));
    // One pixel short of the slice: the slice shows, the material does not.
    let short = staged([1, 0, W as i32, H as i32], None);
    assert_eq!((short.culled_draws, short.culled_materials), (0, 1));
    assert_eq!(short.shown_textures, [7]);
    assert_eq!(short.steps.len(), 2);
    // A cover never hides its own draw.
    assert!(matches!(short.steps.last(), Some(Step::Draws(batch)) if batch.first == 1));
    // What a draw puts past the target needs no cover.
    // The slice reaches past the target on every side.
    let spilled = staged(whole, Some([-20.0, -20.0, w + 20.0, h + 20.0]));
    assert_eq!((spilled.culled_draws, spilled.culled_materials), (1, 1));
    // A client wholly off the target (and its cover, a copy of it) is left
    // out and is not hidden.
    let off = staged(whole, Some([w + 10.0, 0.0, 2.0 * w + 10.0, h]));
    assert_eq!(off.culled_draws, 2);
    assert!(off.hidden_textures.is_empty() && off.shown_textures.is_empty());
}

/// A flat draw partly under an opaque cover is drawn only where it shows,
/// and the target gets exactly the pixels the whole draw gives it.
#[test]
#[ignore = "needs a GPU"]
fn a_draw_split_around_a_cover_draws_the_same_pixels() {
    let mut rig = rig(2, false);
    fill_with(&mut rig.slices[1].0, |_, _| [9, 99, 199, 255]);
    let ndc = record::ndc_from_target(W, H);
    let (w, h) = (f64::from(W), f64::from(H));
    let whole = [0.0, 0.0, w, h];
    // Large enough to be worth splitting (`visible_pieces`).
    let hole = [20.0, 9.0, w - 30.0, h - 10.0];
    let staged = || {
        let mut staged = empty_staged(1);
        for (index, rect) in [whole, hole].into_iter().enumerate() {
            staged.draws.push(record::slice_blit(
                &SliceBlit {
                    source: rect,
                    destination: rect,
                },
                rig.slices[index].1.size,
                false,
                &ndc,
            ));
            staged.steps.push(Step::Draws(Batch {
                image: Arc::clone(&rig.slices[index].1),
                look: Arc::clone(&rig.no_look),
                nearest: true,
                first: index as u32,
                count: 1,
                content: 0,
                layers: None,
            }));
        }
        staged.covers.push((1, hole.map(|value| value as i32)));
        staged
    };
    let read = |buffer: &GbmBuffer| {
        buffer
            .map(0, 0, W, H, |mapping| mapping.buffer().to_vec())
            .expect("map target")
    };
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let whole_draw = staged();
    submit_and_wait(&rig, &mut frame, &whole_draw.draws, &[], &whole_draw.steps);
    let expected = read(&rig.target_buffer);
    fill_with(&mut rig.target_buffer, |_, _| [0, 0, 0, 0]);
    let mut split = staged();
    super::cull(&mut split, (W, H));
    assert_eq!((split.split_draws, split.culled_draws), (1, 0));
    // The draw, its three other pieces and the cover.
    let drawn: u32 = split
        .steps
        .iter()
        .map(|step| match step {
            Step::Draws(batch) => batch.count,
            Step::Material(_) => 0,
        })
        .sum();
    assert_eq!(drawn, 5);
    submit_and_wait(&rig, &mut frame, &split.draws, &[], &split.steps);
    assert!(read(&rig.target_buffer) == expected, "split pixels differ");
}

/// Every pixel an opaque window claims to cover is the client's colour
/// alone, at its antialiased edges too: what the window hides below may go
/// undrawn.
#[test]
#[ignore = "needs a GPU"]
fn an_opaque_window_paints_every_pixel_it_covers() {
    use denial_flutter_engine::scene::WindowStyle;
    let mut rig = rig(2, false);
    fill_with(&mut rig.slices[0].0, |_, _| [0, 0, 255, 255]);
    fill_with(&mut rig.slices[1].0, |_, _| [255, 0, 0, 255]);
    let client = Arc::clone(&rig.slices[1].1);
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    // Whole pixels, then a scale and edges between pixels.
    for (scale, rect) in [
        (1.0, [40.0, 20.0, 216.0, 108.0]),
        (1.5, [27.3, 13.1, 144.2, 72.6]),
    ] {
        let rect = Rect {
            left: rect[0],
            top: rect[1],
            right: rect[2],
            bottom: rect[3],
        };
        let style = WindowStyle {
            bounds: rect,
            content_bounds: rect,
            material_bounds: None,
            radius: 0.0,
            frame_color: 0,
            direct_texture: true,
        };
        let local = EntryLocal {
            scene_from_local: Matrix3([scale, 0.0, 0.0, 0.0, scale, 0.0, 0.0, 0.0, 1.0]),
            ..record::tests::plain_local()
        };
        let placement = record::Placement::new(rect, client.size, None).expect("placement");
        let draw = record::window(
            &local,
            ClipSpan::default(),
            &record::ndc_from_target(W, H),
            &style,
            &Matrix3::IDENTITY,
            1.0,
            Some((&placement, client.size)),
        )
        .expect("window draw");
        let surface = record::window_surface(&Matrix3::IDENTITY, &placement);
        let [Some([left, top, right, bottom]), None] = draw.opaque(surface, (W, H)) else {
            panic!("no cover at scale {scale}");
        };
        let (mut draws, mut steps) = scene(&rig, 1, false);
        let index = draws.len() as u32;
        draws.push(draw);
        steps.push(Step::Draws(Batch {
            image: Arc::clone(&client),
            look: Arc::clone(&rig.no_look),
            nearest: true,
            first: index,
            count: 1,
            content: 0,
            layers: None,
        }));
        submit_and_wait(&rig, &mut frame, &draws, &[], &steps);
        let inside = pixel(&rig.target_buffer, 128, H - 1 - 50);
        for y in top..bottom {
            for x in left..right {
                let got = pixel(&rig.target_buffer, x as u32, H - 1 - y as u32);
                assert_eq!(got, inside, "pixel ({x}, {y}) at scale {scale}");
            }
        }
        // The cover reaches the window's edges.
        let edge = |v: f32| (v * scale).round() as i32;
        assert!(
            (left - edge(rect.left)).abs() <= 1 && (right - edge(rect.right)).abs() <= 1,
            "cover {left}..{right} at scale {scale}"
        );
        assert!(frame.idle());
    }
}

/// A frame that draws only its own damage and copies what earlier frames
/// changed from the buffer shown last ends up with the pixels a frame
/// drawing everything again would: the shown buffer's.
#[test]
#[ignore = "needs a GPU"]
fn a_frame_copies_earlier_changes_from_the_shown_buffer() {
    let mut rig = rig(2, false);
    fill_with(&mut rig.slices[1].0, |x, y| {
        [255 - (x & 0xff) as u8, 40, (y * 2) as u8, 255]
    });
    // The buffer shown last: a second target, of the same kind.
    let gbm =
        GbmDevice::new(DrmDeviceFd::new(smithay::utils::DeviceFd::from(node()))).expect("GBM");
    let shown_buffer = allocate(&gbm);
    let shown = rig
        .gpu
        .import(&shown_buffer.export().unwrap(), Usage::Target)
        .expect("second target import");
    assert!(
        rig.target.copyable && shown.copyable,
        "targets Stagecraft cannot copy"
    );
    let mut frame = Frame::new(&rig.gpu).expect("frame");
    let mut serial = 0;
    let mut submit =
        |target: &Arc<Image>, slice: usize, area: [i32; 4], repair: Option<device::Repair<'_>>| {
            let (mut draws, mut steps) = scene(&rig, 1, false);
            if let Some(Step::Draws(batch)) = steps.first_mut() {
                batch.image = Arc::clone(&rig.slices[slice].1);
            }
            draws.truncate(1);
            serial += 1;
            let done = frame
                .submit(
                    serial,
                    target,
                    &draws,
                    &[],
                    &[],
                    &[],
                    &[],
                    &steps,
                    &[],
                    area,
                    repair,
                    None,
                )
                .expect("submit");
            if let Some(done) = done {
                assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
            }
            assert!(frame.idle());
        };
    // The target holds an older frame (slice 1); the shown buffer the last
    // one (slice 0), which this frame repeats.
    submit(&rig.target, 1, WHOLE, None);
    submit(&shown, 0, WHOLE, None);
    let own = [40, 20, 100, 60];
    let mut rects = Vec::new();
    record::rect_subtract(
        [0.0, 0.0, W as f32, H as f32],
        own.map(|v| v as f32),
        &mut rects,
    );
    let rects: Vec<[i32; 4]> = rects.iter().map(|rect| rect.map(|v| v as i32)).collect();
    submit(
        &rig.target,
        0,
        own,
        Some(device::Repair {
            source: &shown,
            rects: &rects,
        }),
    );
    let read = |buffer: &GbmBuffer| {
        let mut pixels = Vec::new();
        buffer
            .map(0, 0, W, H, |mapping| {
                for row in 0..H {
                    let at = row as usize * mapping.stride() as usize;
                    pixels.extend_from_slice(&mapping.buffer()[at..at + W as usize * 4]);
                }
            })
            .expect("map target");
        pixels
    };
    let (got, want) = (read(&rig.target_buffer), read(&shown_buffer));
    let first = (0..got.len())
        .step_by(4)
        .find(|&i| got[i..i + 4] != want[i..i + 4]);
    assert_eq!(
        first.map(|i| (
            (i / 4) as u32 % W,
            (i / 4) as u32 / W,
            &got[i..i + 4],
            &want[i..i + 4]
        )),
        None,
        "first pixel that differs from the shown buffer"
    );
}

#[test]
fn memory_fill_lists_blocks_largest_first_in_mib() {
    let mib = 1 << 20;
    let (all, each) = super::memory_fill(&[
        (3 * mib / 2, 32 * mib),
        (0, 128 * mib),
        (40 * mib, 128 * mib),
    ]);
    assert_eq!(all, "41.5/288");
    assert_eq!(each, "40.0/128 0.0/128 1.5/32");
    assert_eq!(super::memory_fill(&[]), ("0.0/0".to_owned(), String::new()));
}

#[test]
#[ignore = "needs a GPU"]
fn memory_blocks_count_a_private_image_until_it_is_dropped() {
    let fd = node();
    let gpu = Gpu::new(fd.as_fd()).expect("Stagecraft device");
    let used = |gpu: &Gpu| {
        gpu.memory_blocks()
            .iter()
            .map(|(used, _)| used)
            .sum::<u64>()
    };
    let before = used(&gpu);
    let image = gpu
        .private_image((W, H), 1, ash::vk::ImageUsageFlags::SAMPLED)
        .expect("private image");
    let blocks = gpu.memory_blocks();
    assert!(used(&gpu) >= before + u64::from(W * H * 4));
    assert!(blocks.iter().all(|(used, size)| used <= size));
    drop(image);
    assert_eq!(used(&gpu), before);
}
