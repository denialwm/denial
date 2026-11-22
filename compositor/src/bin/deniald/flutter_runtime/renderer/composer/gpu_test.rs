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
    Batch, Frame, Gpu, Image, MaterialStep, Merge, Step, Upload, Usage, WindowDraw, wait_fd,
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
    let gpu = Gpu::new(fd.as_fd()).expect("Vulkan composer device");
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
        )
        .expect("submit");
    if let Some(done) = done {
        assert!(wait_fd(done.as_fd(), 5000), "submission did not complete");
    }
    let (count, first) = mismatches(&rig.target_buffer);
    assert_eq!(count, 0, "first mismatch {first:?}");
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
            window: Some(WindowDraw {
                draw: index,
                image: Arc::clone(&client),
                look: Arc::clone(&rig.no_look),
                nearest: true,
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
    };
    let merges = [Merge {
        image: Arc::clone(&merged),
        batches: vec![batch(&below, false, 0), {
            let mut both = batch(&above, false, 1);
            both.count = 2;
            both
        }],
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
    assert_eq!(wrong, None, "first pixel off by more than one");
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
