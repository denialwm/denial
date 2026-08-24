use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use denial_core::topology::{LogicalPoint, OutputTransform, SCALE_BASE};
#[cfg(feature = "flutter")]
use denial_flutter_engine::RendererBackend;

const DEFAULT_DEVICE: &str = "/dev/dri/by-path/pci-0000:0a:00.0-card";
const MAX_OUTPUT_CONFIG_BYTES: usize = 64 * 1024;
const MAX_CONFIGURED_OUTPUTS: usize = 128;
const REFRESH_MILLIHERTZ_LITERAL_THRESHOLD: u32 = 10_000;
const MIN_OUTPUT_SCALE: f64 = 0.25;
const MAX_OUTPUT_SCALE: f64 = 8.0;
const MANAGED_OUTPUT_CONFIG_HEADER: &str = "# Output settings managed by Denial output control.";
static OUTPUT_CONFIG_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
pub(super) const SIMULATED_HOTPLUG_GAP_FRAMES: u64 = 30;
const DEFAULT_SYSTEM_BAR_THICKNESS: f64 = 32.0;
const MAX_SYSTEM_BAR_THICKNESS: f64 = 512.0;
const DEFAULT_MAXIMIZE_PADDING: f64 = 10.0;
const MAX_MAXIMIZE_PADDING: f64 = 256.0;
const SYSTEM_BAR_SPEC_HELP: &str =
    "system bar must use SIDE,THICKNESS[,OUTPUT[+OUTPUT...]] or hidden";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SystemBarSide {
    Left,
    Right,
    Top,
    Bottom,
    Hidden,
}

/// Shell system bar placement. The bar itself is Flutter UI; deniald owns the
/// configuration because monitor identity and hotplug are native concerns, and
/// forwards the resolved placement through the display-layout snapshot.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct SystemBarOptions {
    /// Connector names which receive independent copies of the bar. An empty
    /// list follows the render ticker output.
    pub(super) outputs: Vec<String>,
    pub(super) side: SystemBarSide,
    /// Logical pixels reserved across the configured side.
    pub(super) thickness: f64,
}

impl Default for SystemBarOptions {
    fn default() -> Self {
        Self {
            outputs: Vec::new(),
            side: SystemBarSide::Top,
            thickness: DEFAULT_SYSTEM_BAR_THICKNESS,
        }
    }
}

impl SystemBarOptions {
    pub(super) fn hidden() -> Self {
        Self {
            outputs: Vec::new(),
            side: SystemBarSide::Hidden,
            thickness: 0.0,
        }
    }
}

/// Work-area shaping around client windows. The system bar strip is always
/// reserved; `maximize_padding` additionally keeps maximized windows away
/// from every output edge the bar does not occupy. True fullscreen ignores
/// both and covers the complete output.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct WorkAreaOptions {
    pub(super) system_bar: SystemBarOptions,
    /// Logical pixels between a maximized window and bar-free output edges.
    pub(super) maximize_padding: f64,
}

impl Default for WorkAreaOptions {
    fn default() -> Self {
        Self {
            system_bar: SystemBarOptions::default(),
            maximize_padding: DEFAULT_MAXIMIZE_PADDING,
        }
    }
}

fn parse_maximize_padding(value: &str) -> Result<f64, Box<dyn Error>> {
    let padding: f64 = value.trim().parse()?;
    if !(0.0..=MAX_MAXIMIZE_PADDING).contains(&padding) {
        return Err(format!(
            "maximize padding must be within [0, {MAX_MAXIMIZE_PADDING}] logical pixels"
        )
        .into());
    }
    Ok(padding)
}

#[derive(Debug)]
pub(super) struct Options {
    pub(super) device: PathBuf,
    pub(super) render_device: Option<PathBuf>,
    commit_seconds: u64,
    pub(super) max_outputs: usize,
    pub(super) output_config: Option<PathBuf>,
    pub(super) primary_output: Option<String>,
    pub(super) positions: BTreeMap<String, LogicalPoint>,
    pub(super) mode_sizes: BTreeMap<String, (u32, u32)>,
    pub(super) refresh_millihz: BTreeMap<String, u32>,
    pub(super) scales_120: BTreeMap<String, u32>,
    pub(super) transforms: BTreeMap<String, OutputTransform>,
    pub(super) vrr_outputs: BTreeSet<String>,
    pub(super) disabled_outputs: BTreeSet<String>,
    pub(super) next_positions: BTreeMap<String, LogicalPoint>,
    pub(super) reconfigure_at_frame: Option<u64>,
    pub(super) rescan_at_frame: Option<u64>,
    pub(super) simulate_hotplug_at_frame: Option<u64>,
    pub(super) wayland: bool,
    pub(super) flutter_bundle: Option<PathBuf>,
    #[cfg(feature = "flutter")]
    pub(super) flutter_renderer: RendererBackend,
    pub(super) flutter_offscreen_blit: bool,
    pub(super) flutter_debug_bundle: Option<PathBuf>,
    pub(super) flutter_ui_workspace: Option<PathBuf>,
    pub(super) start_locked: bool,
    pub(super) work_area: WorkAreaOptions,
    frames: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RuntimeLimit {
    TestOnly,
    Frames(u64),
    Duration(Duration),
    UntilLogout,
}

impl Options {
    fn terminal() -> Self {
        Self {
            device: PathBuf::from(DEFAULT_DEVICE),
            render_device: None,
            commit_seconds: 0,
            max_outputs: 0,
            output_config: None,
            primary_output: None,
            positions: BTreeMap::new(),
            mode_sizes: BTreeMap::new(),
            refresh_millihz: BTreeMap::new(),
            scales_120: BTreeMap::new(),
            transforms: BTreeMap::new(),
            vrr_outputs: BTreeSet::new(),
            disabled_outputs: BTreeSet::new(),
            next_positions: BTreeMap::new(),
            reconfigure_at_frame: None,
            rescan_at_frame: None,
            simulate_hotplug_at_frame: None,
            wayland: false,
            flutter_bundle: None,
            #[cfg(feature = "flutter")]
            flutter_renderer: RendererBackend::default(),
            flutter_offscreen_blit: false,
            flutter_debug_bundle: None,
            flutter_ui_workspace: None,
            start_locked: false,
            work_area: WorkAreaOptions::default(),
            frames: 0,
        }
    }

    pub(super) fn parse() -> Result<Self, Box<dyn Error>> {
        Self::parse_from(std::env::args().skip(1))
    }

    fn parse_from(args: impl IntoIterator<Item = String>) -> Result<Self, Box<dyn Error>> {
        let mut device = PathBuf::from(DEFAULT_DEVICE);
        let mut render_device = None;
        let mut commit_seconds = 0;
        let mut max_outputs = usize::MAX;
        let mut output_config = None;
        let mut primary_output = None;
        let mut positions = BTreeMap::new();
        let mut mode_sizes = BTreeMap::new();
        let mut refresh_millihz = BTreeMap::new();
        let mut scales_120 = BTreeMap::new();
        let mut transforms = BTreeMap::new();
        let mut vrr_outputs = BTreeSet::new();
        let mut disabled_outputs = BTreeSet::new();
        let mut next_positions = BTreeMap::new();
        let mut reconfigure_at_frame = None;
        let mut rescan_at_frame = None;
        let mut simulate_hotplug_at_frame = None;
        let mut wayland = false;
        let mut flutter_bundle = None;
        #[cfg(feature = "flutter")]
        let mut flutter_renderer = None;
        let mut flutter_offscreen_blit = false;
        let mut flutter_debug_bundle = None;
        let mut flutter_ui_workspace = None;
        let mut start_locked = false;
        let mut system_bar_argument = None;
        let mut maximize_padding_argument = None;
        let mut frames = 0;
        let mut args = args.into_iter();

        while let Some(argument) = args.next() {
            match argument.as_str() {
                "--device" => device = PathBuf::from(args.next().ok_or("--device needs a path")?),
                "--render-device" => {
                    render_device = Some(PathBuf::from(
                        args.next().ok_or("--render-device needs a path")?,
                    ));
                }
                "--commit-seconds" => {
                    commit_seconds = args
                        .next()
                        .ok_or("--commit-seconds needs a value")?
                        .parse()?;
                }
                "--max-outputs" => {
                    max_outputs = args.next().ok_or("--max-outputs needs a value")?.parse()?;
                    if max_outputs == 0 {
                        return Err("--max-outputs must be greater than zero".into());
                    }
                }
                "--output-config" => {
                    output_config = Some(PathBuf::from(
                        args.next().ok_or("--output-config needs a path")?,
                    ));
                }
                "--output-position" => {
                    let value = args.next().ok_or("--output-position needs NAME=X,Y")?;
                    let (name, position) = parse_output_position(&value)?;
                    insert_output_position(&mut positions, name, position, "--output-position")?;
                }
                "--next-output-position" => {
                    let value = args.next().ok_or("--next-output-position needs NAME=X,Y")?;
                    let (name, position) = parse_output_position(&value)?;
                    insert_output_position(
                        &mut next_positions,
                        name,
                        position,
                        "--next-output-position",
                    )?;
                }
                "--reconfigure-at-frame" => {
                    let frame = args
                        .next()
                        .ok_or("--reconfigure-at-frame needs a value")?
                        .parse()?;
                    if frame == 0 {
                        return Err("--reconfigure-at-frame must be greater than zero".into());
                    }
                    reconfigure_at_frame = Some(frame);
                }
                "--rescan-at-frame" => {
                    let frame = args
                        .next()
                        .ok_or("--rescan-at-frame needs a value")?
                        .parse()?;
                    if frame == 0 {
                        return Err("--rescan-at-frame must be greater than zero".into());
                    }
                    rescan_at_frame = Some(frame);
                }
                "--simulate-hotplug-at-frame" => {
                    let frame: u64 = args
                        .next()
                        .ok_or("--simulate-hotplug-at-frame needs a value")?
                        .parse()?;
                    if frame == 0 {
                        return Err("--simulate-hotplug-at-frame must be greater than zero".into());
                    }
                    simulate_hotplug_at_frame = Some(frame);
                }
                "--wayland" => wayland = true,
                "--start-locked" => start_locked = true,
                "--flutter-bundle" => {
                    flutter_bundle = Some(PathBuf::from(
                        args.next().ok_or("--flutter-bundle needs a path")?,
                    ));
                }
                #[cfg(feature = "flutter")]
                "--flutter-renderer" => {
                    if flutter_renderer.is_some() {
                        return Err("--flutter-renderer may only be specified once".into());
                    }
                    flutter_renderer = Some(
                        args.next()
                            .ok_or("--flutter-renderer needs skia or impeller")?
                            .parse()?,
                    );
                }
                "--flutter-offscreen-blit" => flutter_offscreen_blit = true,
                "--flutter-debug-bundle" => {
                    flutter_debug_bundle = Some(PathBuf::from(
                        args.next().ok_or("--flutter-debug-bundle needs a path")?,
                    ));
                }
                "--flutter-ui-workspace" => {
                    flutter_ui_workspace = Some(PathBuf::from(
                        args.next().ok_or("--flutter-ui-workspace needs a path")?,
                    ));
                }
                "--system-bar" => {
                    let value = args.next().ok_or(
                        "--system-bar needs SIDE,THICKNESS[,OUTPUT[+OUTPUT...]] or hidden",
                    )?;
                    system_bar_argument = Some(parse_system_bar_spec(&value)?);
                }
                "--maximize-padding" => {
                    let value = args
                        .next()
                        .ok_or("--maximize-padding needs logical pixels")?;
                    maximize_padding_argument = Some(parse_maximize_padding(&value)?);
                }
                "--frames" => {
                    frames = args.next().ok_or("--frames needs a value")?.parse()?;
                    if frames == 0 {
                        return Err("--frames must be greater than zero".into());
                    }
                }
                "--help" | "-h" => {
                    println!(
                        "Usage: deniald [--device PATH] [--render-device PATH] [--max-outputs N] \
                         [--output-config PATH] \
                         [--output-position NAME=X,Y] \
                         [--next-output-position NAME=X,Y --reconfigure-at-frame N] \
                         [--rescan-at-frame N] \
                         [--simulate-hotplug-at-frame N] \
                         [--wayland] \
                         [--flutter-bundle PATH] \
                         [--flutter-renderer skia|impeller] \
                         [--flutter-offscreen-blit] \
                         [--flutter-debug-bundle PATH] \
                         [--flutter-ui-workspace PATH] \
                         [--start-locked] \
                         [-V | --version] \
                         [--system-bar SIDE,THICKNESS[,OUTPUT[+OUTPUT...]] | --system-bar hidden] \
                         [--maximize-padding PIXELS] \
                         [--commit-seconds N | --frames N]\n\
                         With --flutter-bundle, omitting both limits runs until logout.\n\
                         Without Flutter, N=0 performs atomic TEST_ONLY without changing scanout.\n\
                         Control: SIGUSR1 safely refreshes the embedded Flutter bundle in process."
                    );
                    return Ok(Self::terminal());
                }
                "--version" | "-V" => {
                    println!(
                        "deniald {} (build {}; Flutter Engine ABI {})",
                        denial_core::version(),
                        denial_core::BUILD_IDENTITY,
                        denial_core::FLUTTER_ENGINE_ABI,
                    );
                    return Ok(Self::terminal());
                }
                _ => return Err(format!("unknown argument: {argument}").into()),
            }
        }

        let mut system_bar = None;
        let mut maximize_padding = None;
        if let Some(path) = output_config.as_deref() {
            let mut configured = load_output_config(path)?;
            // Command-line positions are useful for one-shot experiments and
            // deliberately take precedence over the persistent machine file.
            for (name, position) in positions {
                insert_output_position(
                    &mut configured.positions,
                    name,
                    position,
                    "combined output config",
                )?;
            }
            positions = configured.positions;
            primary_output = configured.primary_output;
            mode_sizes = configured.mode_sizes;
            refresh_millihz = configured.refresh_millihz;
            scales_120 = configured.scales_120;
            transforms = configured.transforms;
            vrr_outputs = configured.vrr_outputs;
            disabled_outputs = configured.disabled_outputs;
            system_bar = configured.system_bar;
            maximize_padding = configured.maximize_padding;
        }
        let work_area = WorkAreaOptions {
            system_bar: system_bar_argument.or(system_bar).unwrap_or_default(),
            maximize_padding: maximize_padding_argument
                .or(maximize_padding)
                .unwrap_or(DEFAULT_MAXIMIZE_PADDING),
        };

        if frames != 0 && commit_seconds != 0 {
            return Err("--frames and --commit-seconds are mutually exclusive".into());
        }
        match (reconfigure_at_frame, next_positions.is_empty()) {
            (Some(_), true) => {
                return Err(
                    "--reconfigure-at-frame needs at least one --next-output-position".into(),
                );
            }
            (Some(frame), false) if frames == 0 || frame > frames => {
                return Err("reconfiguration frame must be within --frames".into());
            }
            (None, false) => {
                return Err(
                    "--next-output-position needs --reconfigure-at-frame and --frames".into(),
                );
            }
            _ => {}
        }
        if rescan_at_frame.is_some_and(|frame| frames == 0 || frame > frames) {
            return Err("rescan frame must be within --frames".into());
        }
        if simulate_hotplug_at_frame.is_some_and(|frame| {
            frames == 0
                || frame
                    .checked_add(SIMULATED_HOTPLUG_GAP_FRAMES)
                    .is_none_or(|reconnect| reconnect > frames)
        }) {
            return Err(
                "simulated hotplug and reconnect frames must both be within --frames".into(),
            );
        }
        if simulate_hotplug_at_frame.is_some()
            && (reconfigure_at_frame.is_some() || rescan_at_frame.is_some())
        {
            return Err(
                "--simulate-hotplug-at-frame cannot be combined with another frame transition"
                    .into(),
            );
        }
        if flutter_bundle.is_some() && !wayland {
            return Err("--flutter-bundle requires --wayland".into());
        }
        #[cfg(feature = "flutter")]
        if flutter_renderer.is_some() && flutter_bundle.is_none() {
            return Err("--flutter-renderer requires --flutter-bundle".into());
        }
        if flutter_offscreen_blit && flutter_bundle.is_none() {
            return Err("--flutter-offscreen-blit requires --flutter-bundle".into());
        }
        if (flutter_debug_bundle.is_some() || flutter_ui_workspace.is_some())
            && flutter_bundle.is_none()
        {
            return Err(
                "--flutter-debug-bundle and --flutter-ui-workspace require --flutter-bundle".into(),
            );
        }
        if start_locked && flutter_bundle.is_none() {
            return Err("--start-locked requires --flutter-bundle".into());
        }
        if wayland && frames == 0 && flutter_bundle.is_none() {
            return Err("--wayland without Flutter currently requires --frames".into());
        }
        Ok(Self {
            device,
            render_device,
            commit_seconds,
            max_outputs,
            output_config,
            primary_output,
            positions,
            mode_sizes,
            refresh_millihz,
            scales_120,
            transforms,
            vrr_outputs,
            disabled_outputs,
            next_positions,
            reconfigure_at_frame,
            rescan_at_frame,
            simulate_hotplug_at_frame,
            wayland,
            flutter_bundle,
            #[cfg(feature = "flutter")]
            flutter_renderer: flutter_renderer.unwrap_or_default(),
            flutter_offscreen_blit,
            flutter_debug_bundle,
            flutter_ui_workspace,
            start_locked,
            work_area,
            frames,
        })
    }

    pub(super) fn runtime_limit(&self) -> RuntimeLimit {
        if self.frames > 0 {
            RuntimeLimit::Frames(self.frames)
        } else if self.commit_seconds > 0 {
            RuntimeLimit::Duration(Duration::from_secs(self.commit_seconds))
        } else if self.flutter_bundle.is_some() {
            RuntimeLimit::UntilLogout
        } else {
            RuntimeLimit::TestOnly
        }
    }
}

fn parse_output_position(value: &str) -> Result<(String, LogicalPoint), Box<dyn Error>> {
    let (name, coordinates) = value
        .split_once('=')
        .ok_or("output position must use NAME=X,Y")?;
    let name = name.trim();
    if name.is_empty() {
        return Err("output position has an empty name".into());
    }
    let (x, y) = coordinates
        .split_once(',')
        .ok_or("output position must use NAME=X,Y")?;
    Ok((
        name.to_owned(),
        LogicalPoint::new(x.trim().parse()?, y.trim().parse()?),
    ))
}

fn insert_output_position(
    positions: &mut BTreeMap<String, LogicalPoint>,
    name: String,
    position: LogicalPoint,
    source: &str,
) -> Result<(), Box<dyn Error>> {
    if !positions.contains_key(&name) && positions.len() == MAX_CONFIGURED_OUTPUTS {
        return Err(format!("{source} exceeds the {MAX_CONFIGURED_OUTPUTS}-output limit").into());
    }
    positions.insert(name, position);
    Ok(())
}

fn parse_system_bar_spec(value: &str) -> Result<SystemBarOptions, Box<dyn Error>> {
    let mut fields = value.split(',').map(str::trim);
    let side = match fields.next().filter(|side| !side.is_empty()) {
        Some(side) => side,
        None => return Err(SYSTEM_BAR_SPEC_HELP.into()),
    };
    let side = match side {
        "top" => SystemBarSide::Top,
        "bottom" => SystemBarSide::Bottom,
        "left" => SystemBarSide::Left,
        "right" => SystemBarSide::Right,
        "hidden" => {
            if fields.next().is_some() {
                return Err("hidden system bar takes no other fields".into());
            }
            return Ok(SystemBarOptions::hidden());
        }
        other => return Err(format!("unknown system bar side: {other}").into()),
    };
    let thickness: f64 = fields.next().ok_or(SYSTEM_BAR_SPEC_HELP)?.parse()?;
    if !thickness.is_finite() || thickness <= 0.0 || thickness > MAX_SYSTEM_BAR_THICKNESS {
        return Err(format!(
            "system bar thickness must be within (0, {MAX_SYSTEM_BAR_THICKNESS}] logical pixels"
        )
        .into());
    }
    let outputs = match fields.next() {
        None | Some("auto") => Vec::new(),
        Some("") => return Err("system bar output name is empty".into()),
        Some(names) => {
            let mut outputs = Vec::new();
            for name in names.split('+').map(str::trim) {
                if name.is_empty() {
                    return Err("system bar output name is empty".into());
                }
                if name == "auto" {
                    return Err("auto cannot be combined with named system bar outputs".into());
                }
                if outputs.len() == MAX_CONFIGURED_OUTPUTS {
                    return Err(format!(
                        "system bar exceeds the {MAX_CONFIGURED_OUTPUTS}-output limit"
                    )
                    .into());
                }
                if outputs.iter().any(|configured| configured == name) {
                    return Err(format!("duplicate system bar output {name}").into());
                }
                outputs.push(name.to_owned());
            }
            outputs
        }
    };
    if fields.next().is_some() {
        return Err(SYSTEM_BAR_SPEC_HELP.into());
    }
    Ok(SystemBarOptions {
        outputs,
        side,
        thickness,
    })
}

#[derive(Debug, Default, PartialEq)]
struct OutputConfig {
    primary_output: Option<String>,
    positions: BTreeMap<String, LogicalPoint>,
    mode_sizes: BTreeMap<String, (u32, u32)>,
    refresh_millihz: BTreeMap<String, u32>,
    scales_120: BTreeMap<String, u32>,
    transforms: BTreeMap<String, OutputTransform>,
    vrr_outputs: BTreeSet<String>,
    disabled_outputs: BTreeSet<String>,
    system_bar: Option<SystemBarOptions>,
    maximize_padding: Option<f64>,
}

fn load_output_config(path: &Path) -> Result<OutputConfig, Box<dyn Error>> {
    let file = std::fs::File::open(path)
        .map_err(|error| format!("could not open output config {}: {error}", path.display()))?;
    let contents = read_output_config(file)
        .map_err(|error| format!("could not read output config {}: {error}", path.display()))?;
    parse_output_config(&contents)
        .map_err(|error| format!("invalid output config {}: {error}", path.display()).into())
}

fn read_output_config(reader: impl Read) -> Result<String, String> {
    let mut bytes = Vec::with_capacity(MAX_OUTPUT_CONFIG_BYTES.min(4096));
    reader
        .take((MAX_OUTPUT_CONFIG_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > MAX_OUTPUT_CONFIG_BYTES {
        return Err(format!(
            "file exceeds the {MAX_OUTPUT_CONFIG_BYTES}-byte limit"
        ));
    }
    String::from_utf8(bytes).map_err(|error| format!("file is not valid UTF-8: {error}"))
}

fn parse_output_config_entry(
    value: &str,
) -> Result<(String, LogicalPoint, Option<u32>), Box<dyn Error>> {
    let (name, fields) = value
        .split_once('=')
        .ok_or("output config must use NAME=X,Y[,REFRESH_HZ]")?;
    let name = name.trim();
    if name.is_empty() {
        return Err("output config has an empty name".into());
    }
    let mut fields = fields.split(',').map(str::trim);
    let x = fields
        .next()
        .ok_or("output config must use NAME=X,Y[,REFRESH_HZ]")?;
    let y = fields
        .next()
        .ok_or("output config must use NAME=X,Y[,REFRESH_HZ]")?;
    let refresh = fields.next();
    if fields.next().is_some() {
        return Err("output config must use NAME=X,Y[,REFRESH_HZ]".into());
    }
    let refresh_millihz = refresh
        .map(|refresh| -> Result<u32, Box<dyn Error>> {
            let refresh_hz: u32 = refresh.parse()?;
            if refresh_hz == 0 {
                return Err("output refresh must be greater than zero".into());
            }
            refresh_hz
                .checked_mul(1_000)
                .ok_or_else(|| "output refresh is too large".into())
        })
        .transpose()?;
    Ok((
        name.to_owned(),
        LogicalPoint::new(x.parse()?, y.parse()?),
        refresh_millihz,
    ))
}

fn parse_output_mode_entry(value: &str) -> Result<(String, u32, u32, u32), Box<dyn Error>> {
    let mut fields = value.split(',').map(str::trim);
    let name = fields
        .next()
        .filter(|name| !name.is_empty())
        .ok_or("output mode must use mode=NAME,WIDTH,HEIGHT,REFRESH_MILLIHZ")?;
    let width: u32 = fields
        .next()
        .ok_or("output mode must use mode=NAME,WIDTH,HEIGHT,REFRESH_MILLIHZ")?
        .parse()?;
    let height: u32 = fields
        .next()
        .ok_or("output mode must use mode=NAME,WIDTH,HEIGHT,REFRESH_MILLIHZ")?
        .parse()?;
    let refresh: u32 = fields
        .next()
        .ok_or("output mode must use mode=NAME,WIDTH,HEIGHT,REFRESH_MILLIHZ")?
        .parse()?;
    if fields.next().is_some() {
        return Err("output mode must use mode=NAME,WIDTH,HEIGHT,REFRESH_MILLIHZ".into());
    }
    if width == 0 || height == 0 || refresh == 0 {
        return Err("output mode dimensions and refresh must be greater than zero".into());
    }
    // Persisted mode directives use millihertz. Small hand-written values are
    // unambiguously human-scale hertz and accepting them avoids turning a
    // harmless unit mistake into a failed graphical session.
    let refresh_millihz = if refresh < REFRESH_MILLIHERTZ_LITERAL_THRESHOLD {
        refresh
            .checked_mul(1_000)
            .ok_or("output refresh is too large")?
    } else {
        refresh
    };
    Ok((name.to_owned(), width, height, refresh_millihz))
}

fn parse_output_scale_entry(value: &str) -> Result<(String, u32), Box<dyn Error>> {
    let mut fields = value.split(',').map(str::trim);
    let name = fields
        .next()
        .filter(|name| !name.is_empty())
        .ok_or("output scale must use scale=NAME,SCALE")?;
    let scale: f64 = fields
        .next()
        .ok_or("output scale must use scale=NAME,SCALE")?
        .parse()?;
    if fields.next().is_some() {
        return Err("output scale must use scale=NAME,SCALE".into());
    }
    if !scale.is_finite() || !(MIN_OUTPUT_SCALE..=MAX_OUTPUT_SCALE).contains(&scale) {
        return Err(format!(
            "output scale must be finite and within [{MIN_OUTPUT_SCALE}, {MAX_OUTPUT_SCALE}]"
        )
        .into());
    }
    Ok((
        name.to_owned(),
        (scale * f64::from(SCALE_BASE)).round() as u32,
    ))
}

fn parse_output_transform_entry(value: &str) -> Result<(String, OutputTransform), Box<dyn Error>> {
    let mut fields = value.split(',').map(str::trim);
    let name = fields
        .next()
        .filter(|name| !name.is_empty())
        .ok_or(
            "output transform must use transform=NAME,normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270",
        )?;
    let transform = match fields.next() {
        Some("normal") => OutputTransform::Normal,
        Some("90") => OutputTransform::Rotate90,
        Some("180") => OutputTransform::Rotate180,
        Some("270") => OutputTransform::Rotate270,
        Some("flipped") => OutputTransform::Flipped,
        Some("flipped-90") => OutputTransform::Flipped90,
        Some("flipped-180") => OutputTransform::Flipped180,
        Some("flipped-270") => OutputTransform::Flipped270,
        _ => {
            return Err(
                "output transform must use transform=NAME,normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270"
                    .into(),
            );
        }
    };
    if fields.next().is_some() {
        return Err(
            "output transform must use transform=NAME,normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270"
                .into(),
        );
    }
    Ok((name.to_owned(), transform))
}

fn format_output_transform(transform: OutputTransform) -> &'static str {
    match transform {
        OutputTransform::Normal => "normal",
        OutputTransform::Rotate90 => "90",
        OutputTransform::Rotate180 => "180",
        OutputTransform::Rotate270 => "270",
        OutputTransform::Flipped => "flipped",
        OutputTransform::Flipped90 => "flipped-90",
        OutputTransform::Flipped180 => "flipped-180",
        OutputTransform::Flipped270 => "flipped-270",
    }
}

fn parse_output_config(contents: &str) -> Result<OutputConfig, String> {
    let mut config = OutputConfig::default();
    for (index, raw_line) in contents.lines().enumerate() {
        let line = raw_line
            .split_once('#')
            .map_or(raw_line, |(value, _)| value)
            .trim();
        if line.is_empty() {
            continue;
        }
        if let Some((key, output)) = line.split_once('=')
            && key.trim() == "primary"
        {
            if config.primary_output.is_some() {
                return Err(format!("line {}: duplicate primary entry", index + 1));
            }
            let output = output.trim();
            validate_output_config_name(output)
                .map_err(|error| format!("line {}: {error}", index + 1))?;
            config.primary_output = Some(output.to_owned());
            continue;
        }
        if let Some((key, spec)) = line.split_once('=')
            && key.trim() == "system_bar"
        {
            if config.system_bar.is_some() {
                return Err(format!("line {}: duplicate system_bar entry", index + 1));
            }
            config.system_bar = Some(
                parse_system_bar_spec(spec)
                    .map_err(|error| format!("line {}: {error}", index + 1))?,
            );
            continue;
        }
        if let Some((key, spec)) = line.split_once('=')
            && key.trim() == "maximize_padding"
        {
            if config.maximize_padding.is_some() {
                return Err(format!(
                    "line {}: duplicate maximize_padding entry",
                    index + 1
                ));
            }
            config.maximize_padding = Some(
                parse_maximize_padding(spec)
                    .map_err(|error| format!("line {}: {error}", index + 1))?,
            );
            continue;
        }
        if let Some((key, spec)) = line.split_once('=')
            && key.trim() == "mode"
        {
            let (name, width, height, refresh_millihz) = parse_output_mode_entry(spec)
                .map_err(|error| format!("line {}: {error}", index + 1))?;
            if config.mode_sizes.contains_key(&name) || config.refresh_millihz.contains_key(&name) {
                return Err(format!(
                    "line {}: duplicate mode or refresh for output {name}",
                    index + 1
                ));
            }
            if config.mode_sizes.len() == MAX_CONFIGURED_OUTPUTS {
                return Err(format!(
                    "line {}: output config exceeds the {MAX_CONFIGURED_OUTPUTS}-output mode limit",
                    index + 1
                ));
            }
            config.mode_sizes.insert(name.clone(), (width, height));
            config.refresh_millihz.insert(name, refresh_millihz);
            continue;
        }
        if let Some((key, spec)) = line.split_once('=')
            && key.trim() == "scale"
        {
            let (name, scale_120) = parse_output_scale_entry(spec)
                .map_err(|error| format!("line {}: {error}", index + 1))?;
            if config.scales_120.contains_key(&name) {
                return Err(format!(
                    "line {}: duplicate scale for output {name}",
                    index + 1
                ));
            }
            if config.scales_120.len() == MAX_CONFIGURED_OUTPUTS {
                return Err(format!(
                    "line {}: output config exceeds the {MAX_CONFIGURED_OUTPUTS}-output scale limit",
                    index + 1
                ));
            }
            config.scales_120.insert(name, scale_120);
            continue;
        }
        if let Some((key, spec)) = line.split_once('=')
            && key.trim() == "transform"
        {
            let (name, transform) = parse_output_transform_entry(spec)
                .map_err(|error| format!("line {}: {error}", index + 1))?;
            if config.transforms.contains_key(&name) {
                return Err(format!(
                    "line {}: duplicate transform for output {name}",
                    index + 1
                ));
            }
            if config.transforms.len() == MAX_CONFIGURED_OUTPUTS {
                return Err(format!(
                    "line {}: output config exceeds the {MAX_CONFIGURED_OUTPUTS}-output transform limit",
                    index + 1
                ));
            }
            config.transforms.insert(name, transform);
            continue;
        }
        if let Some((key, output)) = line.split_once('=')
            && key.trim() == "disabled"
        {
            let output = output.trim();
            if output.is_empty() {
                return Err(format!("line {}: disabled output name is empty", index + 1));
            }
            if config.disabled_outputs.len() == MAX_CONFIGURED_OUTPUTS {
                return Err(format!(
                    "line {}: output config exceeds the {MAX_CONFIGURED_OUTPUTS}-output disabled limit",
                    index + 1
                ));
            }
            if !config.disabled_outputs.insert(output.to_owned()) {
                return Err(format!(
                    "line {}: duplicate disabled output {output}",
                    index + 1
                ));
            }
            continue;
        }
        if let Some((key, output)) = line.split_once('=')
            && key.trim() == "vrr"
        {
            let output = output.trim();
            if output.is_empty() {
                return Err(format!("line {}: VRR output name is empty", index + 1));
            }
            if config.vrr_outputs.len() == MAX_CONFIGURED_OUTPUTS {
                return Err(format!(
                    "line {}: output config exceeds the {MAX_CONFIGURED_OUTPUTS}-output VRR limit",
                    index + 1
                ));
            }
            if !config.vrr_outputs.insert(output.to_owned()) {
                return Err(format!("line {}: duplicate VRR output {output}", index + 1));
            }
            continue;
        }
        let (name, position, refresh_millihz) = parse_output_config_entry(line)
            .map_err(|error| format!("line {}: {error}", index + 1))?;
        if config.positions.contains_key(&name) {
            return Err(format!("line {}: duplicate output {name}", index + 1));
        }
        if config.positions.len() == MAX_CONFIGURED_OUTPUTS {
            return Err(format!(
                "line {}: output config exceeds the {MAX_CONFIGURED_OUTPUTS}-output limit",
                index + 1
            ));
        }
        if let Some(refresh_millihz) = refresh_millihz {
            if config.refresh_millihz.contains_key(&name) {
                return Err(format!(
                    "line {}: duplicate mode or refresh for output {name}",
                    index + 1
                ));
            }
            config.refresh_millihz.insert(name.clone(), refresh_millihz);
        }
        config.positions.insert(name, position);
    }
    Ok(config)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct PersistedOutput {
    pub(super) name: String,
    pub(super) enabled: bool,
    pub(super) x: i32,
    pub(super) y: i32,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) refresh_millihz: u32,
    pub(super) scale_120: u32,
    pub(super) transform: OutputTransform,
    pub(super) adaptive_sync: bool,
}

#[derive(Debug)]
pub(super) struct PreparedOutputConfig {
    target: PathBuf,
    temporary: PathBuf,
    original: String,
    target_device: u64,
    target_inode: u64,
    renamed: bool,
}

impl PreparedOutputConfig {
    pub(super) fn commit(mut self) -> Result<(), String> {
        let target_metadata = fs::symlink_metadata(&self.target).map_err(|error| {
            format!(
                "could not recheck output config {}: {error}",
                self.target.display()
            )
        })?;
        if !target_metadata.file_type().is_file()
            || target_metadata.dev() != self.target_device
            || target_metadata.ino() != self.target_inode
        {
            return Err(format!(
                "output config {} changed while the display transaction was being applied",
                self.target.display()
            ));
        }

        let mut target = fs::File::open(&self.target).map_err(|error| {
            format!(
                "could not reopen output config {}: {error}",
                self.target.display()
            )
        })?;
        let opened_metadata = target.metadata().map_err(|error| {
            format!(
                "could not inspect output config {}: {error}",
                self.target.display()
            )
        })?;
        if opened_metadata.dev() != self.target_device || opened_metadata.ino() != self.target_inode
        {
            return Err(format!(
                "output config {} changed while the display transaction was being applied",
                self.target.display()
            ));
        }
        let current = read_output_config(&mut target).map_err(|error| {
            format!(
                "could not re-read output config {}: {error}",
                self.target.display()
            )
        })?;
        if current != self.original {
            return Err(format!(
                "output config {} was edited while the display transaction was being applied",
                self.target.display()
            ));
        }

        fs::rename(&self.temporary, &self.target).map_err(|error| {
            format!(
                "could not atomically replace output config {}: {error}",
                self.target.display()
            )
        })?;
        self.renamed = true;

        let parent = output_config_parent(&self.target);
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                format!(
                    "could not sync output config directory {}: {error}",
                    parent.display()
                )
            })
    }
}

impl Drop for PreparedOutputConfig {
    fn drop(&mut self) {
        if !self.renamed {
            let _ = fs::remove_file(&self.temporary);
        }
    }
}

pub(super) fn prepare_output_config_persistence(
    path: &Path,
    outputs: &[PersistedOutput],
    primary_output: Option<&str>,
) -> Result<PreparedOutputConfig, String> {
    let path_metadata = fs::symlink_metadata(path).map_err(|error| {
        format!(
            "could not inspect output config {}: {error}",
            path.display()
        )
    })?;
    if path_metadata.file_type().is_symlink() {
        return Err(format!(
            "refusing to replace symlinked output config {}",
            path.display()
        ));
    }
    if !path_metadata.file_type().is_file() {
        return Err(format!(
            "output config {} is not a regular file",
            path.display()
        ));
    }

    let mut target = fs::File::open(path)
        .map_err(|error| format!("could not open output config {}: {error}", path.display()))?;
    let target_metadata = target.metadata().map_err(|error| {
        format!(
            "could not inspect output config {}: {error}",
            path.display()
        )
    })?;
    if target_metadata.dev() != path_metadata.dev() || target_metadata.ino() != path_metadata.ino()
    {
        return Err(format!(
            "output config {} changed while it was being opened",
            path.display()
        ));
    }
    let original = read_output_config(&mut target)
        .map_err(|error| format!("could not read output config {}: {error}", path.display()))?;
    parse_output_config(&original)
        .map_err(|error| format!("invalid output config {}: {error}", path.display()))?;

    let rendered = render_persisted_output_config(&original, outputs, primary_output)?;
    if rendered.len() > MAX_OUTPUT_CONFIG_BYTES {
        return Err(format!(
            "updated output config exceeds the {MAX_OUTPUT_CONFIG_BYTES}-byte limit"
        ));
    }
    parse_output_config(&rendered)
        .map_err(|error| format!("generated output config is invalid: {error}"))?;

    let parent = output_config_parent(path);
    let file_name = path
        .file_name()
        .ok_or_else(|| format!("output config {} has no file name", path.display()))?;
    let mode = target_metadata.permissions().mode() & 0o777;
    let (temporary, mut file) = create_output_config_temp(parent, file_name)?;
    if let Err(error) = (|| -> Result<(), String> {
        file.set_permissions(fs::Permissions::from_mode(mode))
            .map_err(|error| {
                format!(
                    "could not preserve permissions on {}: {error}",
                    temporary.display()
                )
            })?;
        file.write_all(rendered.as_bytes()).map_err(|error| {
            format!(
                "could not write temporary output config {}: {error}",
                temporary.display()
            )
        })?;
        file.sync_all().map_err(|error| {
            format!(
                "could not sync temporary output config {}: {error}",
                temporary.display()
            )
        })
    })() {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }

    Ok(PreparedOutputConfig {
        target: path.to_path_buf(),
        temporary,
        original,
        target_device: target_metadata.dev(),
        target_inode: target_metadata.ino(),
        renamed: false,
    })
}

fn create_output_config_temp(
    parent: &Path,
    file_name: &std::ffi::OsStr,
) -> Result<(PathBuf, fs::File), String> {
    for _ in 0..32 {
        let sequence = OUTPUT_CONFIG_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let mut temporary_name = OsString::from(".");
        temporary_name.push(file_name);
        temporary_name.push(format!(".denial-{}-{sequence}.tmp", std::process::id()));
        let temporary = parent.join(temporary_name);
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
        {
            Ok(file) => return Ok((temporary, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "could not create temporary output config in {}: {error}",
                    parent.display()
                ));
            }
        }
    }
    Err(format!(
        "could not allocate a temporary output config name in {}",
        parent.display()
    ))
}

fn output_config_parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn render_persisted_output_config(
    original: &str,
    outputs: &[PersistedOutput],
    primary_output: Option<&str>,
) -> Result<String, String> {
    if outputs.is_empty() {
        return Err("persistent output configuration contains no connectors".to_owned());
    }
    if outputs.len() > MAX_CONFIGURED_OUTPUTS {
        return Err(format!(
            "persistent output configuration exceeds the {MAX_CONFIGURED_OUTPUTS}-output limit"
        ));
    }

    let mut sorted = BTreeMap::new();
    for output in outputs {
        validate_persisted_output(output)?;
        if sorted.insert(output.name.as_str(), output).is_some() {
            return Err(format!(
                "persistent output configuration contains duplicate output {}",
                output.name
            ));
        }
    }
    if !outputs.iter().any(|output| output.enabled) {
        return Err("at least one persistent output must remain enabled".to_owned());
    }
    if let Some(primary_output) = primary_output {
        validate_output_config_name(primary_output)?;
    }
    let connected = sorted.keys().copied().collect::<BTreeSet<_>>();

    let mut lines = original
        .lines()
        .filter(|raw_line| raw_line.trim() != MANAGED_OUTPUT_CONFIG_HEADER)
        .filter(|raw_line| !is_primary_output_directive(raw_line))
        .filter(|raw_line| {
            output_directive_name(raw_line).is_none_or(|name| !connected.contains(name))
        })
        .map(str::to_owned)
        .collect::<Vec<_>>();
    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
    if !lines.is_empty() {
        lines.push(String::new());
    }
    lines.push(MANAGED_OUTPUT_CONFIG_HEADER.to_owned());
    if let Some(primary_output) = primary_output {
        lines.push(format!("primary={primary_output}"));
    }
    for output in sorted.into_values() {
        lines.push(format!("{}={},{}", output.name, output.x, output.y));
        lines.push(format!(
            "mode={},{},{},{}",
            output.name, output.width, output.height, output.refresh_millihz
        ));
        lines.push(format!(
            "scale={},{}",
            output.name,
            format_output_scale(output.scale_120)
        ));
        if output.transform != OutputTransform::Normal {
            lines.push(format!(
                "transform={},{}",
                output.name,
                format_output_transform(output.transform)
            ));
        }
        if output.adaptive_sync {
            lines.push(format!("vrr={}", output.name));
        }
        if !output.enabled {
            lines.push(format!("disabled={}", output.name));
        }
    }

    let mut rendered = lines.join("\n");
    rendered.push('\n');
    Ok(rendered)
}

fn validate_persisted_output(output: &PersistedOutput) -> Result<(), String> {
    validate_output_config_name(&output.name)?;
    if output.width == 0 || output.height == 0 || output.refresh_millihz == 0 {
        return Err(format!(
            "{} has an invalid persistent display mode",
            output.name
        ));
    }
    let min_scale_120 = (MIN_OUTPUT_SCALE * f64::from(SCALE_BASE)).round() as u32;
    let max_scale_120 = (MAX_OUTPUT_SCALE * f64::from(SCALE_BASE)).round() as u32;
    if !(min_scale_120..=max_scale_120).contains(&output.scale_120) {
        return Err(format!(
            "{} has an invalid persistent output scale",
            output.name
        ));
    }
    Ok(())
}

fn validate_output_config_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || name.trim() != name
        || name
            .chars()
            .any(|character| character.is_control() || matches!(character, '#' | ',' | '='))
    {
        return Err(format!(
            "output name {name:?} cannot be represented in the output config"
        ));
    }
    Ok(())
}

fn is_primary_output_directive(raw_line: &str) -> bool {
    let line = raw_line
        .split_once('#')
        .map_or(raw_line, |(value, _)| value)
        .trim();
    line.split_once('=')
        .is_some_and(|(key, _)| key.trim() == "primary")
}

fn output_directive_name(raw_line: &str) -> Option<&str> {
    let line = raw_line
        .split_once('#')
        .map_or(raw_line, |(value, _)| value)
        .trim();
    let (key, value) = line.split_once('=')?;
    let key = key.trim();
    match key {
        "primary" | "system_bar" | "maximize_padding" => None,
        "disabled" | "vrr" => Some(value.trim()),
        "mode" | "scale" | "transform" => value.split(',').next().map(str::trim),
        _ => Some(key),
    }
}

fn format_output_scale(scale_120: u32) -> String {
    let mut value = format!("{:.6}", f64::from(scale_120) / f64::from(SCALE_BASE));
    while value.ends_with('0') {
        value.pop();
    }
    if value.ends_with('.') {
        value.pop();
    }
    value
}

#[cfg(test)]
#[path = "options/tests.rs"]
mod tests;
