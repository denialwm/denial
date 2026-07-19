#![forbid(unsafe_code)]

use std::error::Error;
use std::time::{Duration, Instant};

use ::winit::event_loop::pump_events::PumpStatus;
use denial_core::topology::{
    AtlasPlan, LogicalPoint, LogicalRect, OutputId, OutputSpec, OutputTransform, PixelRect,
    PixelSize, TopologyManager,
};
use smithay::backend::input::InputEvent;
use smithay::backend::renderer::{Color32F, Frame, Renderer, gles::GlesRenderer};
use smithay::backend::winit::{self, WinitEvent};
use smithay::utils::{Physical, Rectangle, Size, Transform};
use tracing::info;

const PRESET_NAMES: [&str; 4] = ["horizontal", "vertical", "l-shape", "mixed"];
const COLORS: [Color32F; 5] = [
    Color32F::new(0.24, 0.58, 0.98, 1.0),
    Color32F::new(0.94, 0.36, 0.36, 1.0),
    Color32F::new(0.31, 0.78, 0.52, 1.0),
    Color32F::new(0.72, 0.43, 0.95, 1.0),
    Color32F::new(0.96, 0.68, 0.25, 1.0),
];

#[derive(Debug)]
struct Options {
    preset_index: usize,
    cycle_interval: Option<Duration>,
    exit_after: Option<Duration>,
}

impl Options {
    fn parse() -> Result<Self, Box<dyn Error>> {
        let mut preset_index = 0;
        let mut cycle_interval = Some(Duration::from_millis(2500));
        let mut exit_after = None;
        let mut args = std::env::args().skip(1);

        while let Some(argument) = args.next() {
            match argument.as_str() {
                "--preset" => {
                    let name = args.next().ok_or("--preset needs a value")?;
                    preset_index = PRESET_NAMES
                        .iter()
                        .position(|candidate| *candidate == name)
                        .ok_or_else(|| format!("unknown preset: {name}"))?;
                }
                "--cycle-ms" => {
                    let milliseconds = args
                        .next()
                        .ok_or("--cycle-ms needs a value")?
                        .parse::<u64>()?;
                    cycle_interval =
                        (milliseconds > 0).then(|| Duration::from_millis(milliseconds));
                }
                "--exit-after-ms" => {
                    let milliseconds = args
                        .next()
                        .ok_or("--exit-after-ms needs a value")?
                        .parse::<u64>()?;
                    exit_after = (milliseconds > 0).then(|| Duration::from_millis(milliseconds));
                }
                "--help" | "-h" => {
                    println!(
                        "Usage: denial-nested [--preset {}] [--cycle-ms N] [--exit-after-ms N]",
                        PRESET_NAMES.join("|")
                    );
                    std::process::exit(0);
                }
                _ => return Err(format!("unknown argument: {argument}").into()),
            }
        }

        Ok(Self {
            preset_index,
            cycle_interval,
            exit_after,
        })
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "denial_rs=info".into()),
        )
        .init();

    let options = Options::parse()?;
    let (mut backend, mut event_source) = winit::init::<GlesRenderer>()?;
    let mut preset_index = options.preset_index;
    let mut topology = TopologyManager::new(preset(PRESET_NAMES[preset_index]))?;
    let started = Instant::now();
    let mut last_transition = Instant::now();
    log_topology(PRESET_NAMES[preset_index], &topology);

    loop {
        let mut close_requested = false;
        let status = event_source.dispatch_new_events(|event| match event {
            WinitEvent::Input(InputEvent::Keyboard { .. }) => {}
            WinitEvent::CloseRequested => close_requested = true,
            _ => {}
        });
        if close_requested || !matches!(status, PumpStatus::Continue) {
            return Ok(());
        }
        if options
            .exit_after
            .is_some_and(|duration| started.elapsed() >= duration)
        {
            return Ok(());
        }

        if options
            .cycle_interval
            .is_some_and(|interval| last_transition.elapsed() >= interval)
        {
            preset_index = (preset_index + 1) % PRESET_NAMES.len();
            let next = TopologyManager::new(preset(PRESET_NAMES[preset_index]))?;
            let next_snapshot = next.snapshot();
            let next_ids = next_snapshot
                .outputs
                .iter()
                .map(|output| output.id)
                .collect::<std::collections::BTreeSet<_>>();
            let changes = next_snapshot
                .outputs
                .into_iter()
                .map(denial_core::topology::TopologyChange::Upsert)
                .chain(
                    topology
                        .snapshot()
                        .outputs
                        .into_iter()
                        .filter(|old| !next_ids.contains(&old.id))
                        .map(|old| denial_core::topology::TopologyChange::Remove(old.id)),
                )
                .collect::<Vec<_>>();
            topology.apply(changes)?;
            last_transition = Instant::now();
            log_topology(PRESET_NAMES[preset_index], &topology);
        }

        let size = backend.window_size();
        let damage = Rectangle::from_size(size);
        {
            let (renderer, mut framebuffer) = backend.bind()?;
            let mut frame = renderer.render(&mut framebuffer, size, Transform::Flipped180)?;
            draw_topology(&mut frame, size, &topology)?;
            let _sync_point = frame.finish()?;
        }
        backend.submit(Some(&[damage]))?;
        backend.window().request_redraw();
    }
}

fn log_topology(name: &str, topology: &TopologyManager) {
    let snapshot = topology.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot);
    info!(
        preset = name,
        epoch = snapshot.epoch,
        outputs = snapshot.outputs.len(),
        ticker = ?snapshot.ticker,
        logical_bounds = ?snapshot.logical_bounds,
        atlas_size = ?atlas.as_ref().map(|plan| plan.pixel_size),
        engine_scale_120 = ?atlas.as_ref().map(|plan| plan.engine_scale_120),
        "nested topology committed"
    );
}

fn draw_topology<F>(
    frame: &mut F,
    window_size: Size<i32, Physical>,
    topology: &TopologyManager,
) -> Result<(), F::Error>
where
    F: Frame,
{
    let full = Rectangle::from_size(window_size);
    frame.clear(Color32F::new(0.025, 0.03, 0.045, 1.0), &[full])?;

    let snapshot = topology.snapshot();
    let Some(bounds) = snapshot.logical_bounds else {
        return Ok(());
    };
    let Some(atlas) = AtlasPlan::for_snapshot(&snapshot) else {
        return Ok(());
    };

    let margin = 24;
    let gap = 22;
    let available_width = (window_size.w - margin * 2).max(1);
    let available_height = (window_size.h - margin * 2 - gap).max(1);
    let logical_height = (available_height * 2 / 3).max(1);
    let atlas_height = (available_height - logical_height).max(1);
    let logical_view = Rectangle::new(
        (margin, margin).into(),
        (available_width, logical_height).into(),
    );
    let atlas_view = Rectangle::new(
        (margin, margin + logical_height + gap).into(),
        (available_width, atlas_height).into(),
    );

    frame.clear(
        Color32F::new(0.055, 0.065, 0.09, 1.0),
        &[logical_view, atlas_view],
    )?;

    for (index, output) in snapshot.outputs.iter().enumerate() {
        let rect = project_logical(output.logical_rect(), bounds, logical_view);
        draw_output(frame, rect, COLORS[index % COLORS.len()])?;
    }

    let atlas_bounds = LogicalRect {
        x: 0.0,
        y: 0.0,
        width: atlas.pixel_size.width as f64,
        height: atlas.pixel_size.height as f64,
    };
    for (index, output) in atlas.outputs.iter().enumerate() {
        let rect = project_pixels(output.source_rect, atlas_bounds, atlas_view);
        draw_output(frame, rect, COLORS[index % COLORS.len()])?;
    }

    Ok(())
}

fn draw_output<F>(
    frame: &mut F,
    rect: Rectangle<i32, Physical>,
    color: Color32F,
) -> Result<(), F::Error>
where
    F: Frame,
{
    if rect.size.w <= 0 || rect.size.h <= 0 {
        return Ok(());
    }
    frame.clear(Color32F::new(0.72, 0.76, 0.84, 1.0), &[rect])?;
    if rect.size.w > 6 && rect.size.h > 6 {
        let inner = Rectangle::new(
            (rect.loc.x + 3, rect.loc.y + 3).into(),
            (rect.size.w - 6, rect.size.h - 6).into(),
        );
        frame.clear(color, &[inner])?;
        let marker = Rectangle::new(
            (inner.loc.x + 5, inner.loc.y + 5).into(),
            ((inner.size.w / 8).max(4), (inner.size.h / 12).max(4)).into(),
        );
        frame.clear(Color32F::new(0.96, 0.97, 1.0, 1.0), &[marker])?;
    }
    Ok(())
}

fn project_logical(
    rect: LogicalRect,
    bounds: LogicalRect,
    viewport: Rectangle<i32, Physical>,
) -> Rectangle<i32, Physical> {
    project_rect(rect, bounds, viewport)
}

fn project_pixels(
    rect: PixelRect,
    bounds: LogicalRect,
    viewport: Rectangle<i32, Physical>,
) -> Rectangle<i32, Physical> {
    project_rect(
        LogicalRect {
            x: rect.x as f64,
            y: rect.y as f64,
            width: rect.width as f64,
            height: rect.height as f64,
        },
        bounds,
        viewport,
    )
}

fn project_rect(
    rect: LogicalRect,
    bounds: LogicalRect,
    viewport: Rectangle<i32, Physical>,
) -> Rectangle<i32, Physical> {
    let padding = 12.0;
    let width = (viewport.size.w as f64 - padding * 2.0).max(1.0);
    let height = (viewport.size.h as f64 - padding * 2.0).max(1.0);
    let scale = (width / bounds.width.max(1.0)).min(height / bounds.height.max(1.0));
    let content_width = bounds.width * scale;
    let content_height = bounds.height * scale;
    let origin_x = viewport.loc.x as f64 + (viewport.size.w as f64 - content_width) / 2.0;
    let origin_y = viewport.loc.y as f64 + (viewport.size.h as f64 - content_height) / 2.0;

    Rectangle::new(
        (
            (origin_x + (rect.x - bounds.x) * scale).round() as i32,
            (origin_y + (rect.y - bounds.y) * scale).round() as i32,
        )
            .into(),
        (
            (rect.width * scale).round().max(1.0) as i32,
            (rect.height * scale).round().max(1.0) as i32,
        )
            .into(),
    )
}

fn preset(name: &str) -> Vec<OutputSpec> {
    match name {
        "horizontal" => vec![
            output(1, "left", (-1920, 0), (1920, 1080), 120, 60_000),
            output(2, "main", (0, -360), (2560, 1440), 120, 200_000),
        ],
        "vertical" => vec![
            output(1, "top", (320, -1080), (1920, 1080), 120, 75_000),
            output(2, "main", (0, 0), (2560, 1440), 120, 200_000),
        ],
        "l-shape" => vec![
            output(1, "left", (-1920, 0), (1920, 1080), 120, 75_000),
            output(2, "main", (0, 0), (2560, 1440), 120, 200_000),
            output(3, "lower", (640, 1440), (1920, 1080), 120, 60_000),
        ],
        "mixed" => {
            let mut portrait = output(3, "portrait", (3968, 0), (1080, 1920), 120, 60_000);
            portrait.transform = OutputTransform::Rotate90;
            vec![
                output(1, "hidpi", (-1920, 0), (3840, 2160), 240, 120_000),
                output(2, "main", (0, -360), (2560, 1440), 150, 200_000),
                portrait,
            ]
        }
        _ => unreachable!("validated preset"),
    }
}

fn output(
    id: u64,
    name: &str,
    position: (i32, i32),
    mode: (u32, u32),
    scale_120: u32,
    refresh_millihz: u32,
) -> OutputSpec {
    OutputSpec {
        id: OutputId(id),
        name: name.into(),
        position: LogicalPoint::new(position.0, position.1),
        mode: PixelSize::new(mode.0, mode.1),
        scale_120,
        refresh_millihz,
        transform: OutputTransform::Normal,
    }
}
