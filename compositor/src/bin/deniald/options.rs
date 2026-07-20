use std::collections::BTreeMap;
use std::error::Error;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use denial_core::topology::LogicalPoint;

const DEFAULT_DEVICE: &str = "/dev/dri/by-path/pci-0000:0a:00.0-card";
const MAX_OUTPUT_CONFIG_BYTES: usize = 64 * 1024;
const MAX_CONFIGURED_OUTPUTS: usize = 128;
pub(super) const SIMULATED_HOTPLUG_GAP_FRAMES: u64 = 30;
const DEFAULT_SYSTEM_BAR_THICKNESS: f64 = 32.0;
const MAX_SYSTEM_BAR_THICKNESS: f64 = 512.0;
const DEFAULT_MAXIMIZE_PADDING: f64 = 10.0;
const MAX_MAXIMIZE_PADDING: f64 = 256.0;
const SYSTEM_BAR_SPEC_HELP: &str = "system bar must use SIDE,THICKNESS[,OUTPUT] or hidden";

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
    /// Connector name; `None` follows the render ticker output.
    pub(super) output: Option<String>,
    pub(super) side: SystemBarSide,
    /// Logical pixels reserved across the configured side.
    pub(super) thickness: f64,
}

impl Default for SystemBarOptions {
    fn default() -> Self {
        Self {
            output: None,
            side: SystemBarSide::Top,
            thickness: DEFAULT_SYSTEM_BAR_THICKNESS,
        }
    }
}

impl SystemBarOptions {
    pub(super) fn hidden() -> Self {
        Self {
            output: None,
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
    if !padding.is_finite() || padding < 0.0 || padding > MAX_MAXIMIZE_PADDING {
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
    commit_seconds: u64,
    pub(super) max_outputs: usize,
    pub(super) positions: BTreeMap<String, LogicalPoint>,
    pub(super) refresh_millihz: BTreeMap<String, u32>,
    pub(super) next_positions: BTreeMap<String, LogicalPoint>,
    pub(super) reconfigure_at_frame: Option<u64>,
    pub(super) rescan_at_frame: Option<u64>,
    pub(super) simulate_hotplug_at_frame: Option<u64>,
    pub(super) wayland: bool,
    pub(super) flutter_bundle: Option<PathBuf>,
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
    pub(super) fn parse() -> Result<Self, Box<dyn Error>> {
        Self::parse_from(std::env::args().skip(1))
    }

    fn parse_from(args: impl IntoIterator<Item = String>) -> Result<Self, Box<dyn Error>> {
        let mut device = PathBuf::from(DEFAULT_DEVICE);
        let mut commit_seconds = 0;
        let mut max_outputs = usize::MAX;
        let mut output_config = None;
        let mut positions = BTreeMap::new();
        let mut refresh_millihz = BTreeMap::new();
        let mut next_positions = BTreeMap::new();
        let mut reconfigure_at_frame = None;
        let mut rescan_at_frame = None;
        let mut simulate_hotplug_at_frame = None;
        let mut wayland = false;
        let mut flutter_bundle = None;
        let mut system_bar_argument = None;
        let mut maximize_padding_argument = None;
        let mut frames = 0;
        let mut args = args.into_iter();

        while let Some(argument) = args.next() {
            match argument.as_str() {
                "--device" => device = PathBuf::from(args.next().ok_or("--device needs a path")?),
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
                    let frame = args
                        .next()
                        .ok_or("--simulate-hotplug-at-frame needs a value")?
                        .parse()?;
                    if frame == 0 {
                        return Err("--simulate-hotplug-at-frame must be greater than zero".into());
                    }
                    simulate_hotplug_at_frame = Some(frame);
                }
                "--wayland" => wayland = true,
                "--flutter-bundle" => {
                    flutter_bundle = Some(PathBuf::from(
                        args.next().ok_or("--flutter-bundle needs a path")?,
                    ));
                }
                "--system-bar" => {
                    let value = args
                        .next()
                        .ok_or("--system-bar needs SIDE,THICKNESS[,OUTPUT] or hidden")?;
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
                        "Usage: deniald [--device PATH] [--max-outputs N] \
                         [--output-config PATH] \
                         [--output-position NAME=X,Y] \
                         [--next-output-position NAME=X,Y --reconfigure-at-frame N] \
                         [--rescan-at-frame N] \
                         [--simulate-hotplug-at-frame N] \
                         [--wayland] \
                         [--flutter-bundle PATH] \
                         [--system-bar SIDE,THICKNESS[,OUTPUT] | --system-bar hidden] \
                         [--maximize-padding PIXELS] \
                         [--commit-seconds N | --frames N]\n\
                         With --flutter-bundle, omitting both limits runs until logout.\n\
                         Without Flutter, N=0 performs atomic TEST_ONLY without changing scanout."
                    );
                    return Ok(Self {
                        device,
                        commit_seconds,
                        max_outputs: 0,
                        positions,
                        refresh_millihz,
                        next_positions,
                        reconfigure_at_frame,
                        rescan_at_frame,
                        simulate_hotplug_at_frame,
                        wayland,
                        flutter_bundle,
                        work_area: WorkAreaOptions {
                            system_bar: system_bar_argument.unwrap_or_default(),
                            maximize_padding: maximize_padding_argument
                                .unwrap_or(DEFAULT_MAXIMIZE_PADDING),
                        },
                        frames,
                    });
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
            refresh_millihz = configured.refresh_millihz;
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
        if wayland && frames == 0 && flutter_bundle.is_none() {
            return Err("--wayland without Flutter currently requires --frames".into());
        }
        Ok(Self {
            device,
            commit_seconds,
            max_outputs,
            positions,
            refresh_millihz,
            next_positions,
            reconfigure_at_frame,
            rescan_at_frame,
            simulate_hotplug_at_frame,
            wayland,
            flutter_bundle,
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
    let output = match fields.next() {
        None | Some("auto") => None,
        Some("") => return Err("system bar output name is empty".into()),
        Some(name) => Some(name.to_owned()),
    };
    if fields.next().is_some() {
        return Err(SYSTEM_BAR_SPEC_HELP.into());
    }
    Ok(SystemBarOptions {
        output,
        side,
        thickness,
    })
}

#[derive(Debug, Default, PartialEq)]
struct OutputConfig {
    positions: BTreeMap<String, LogicalPoint>,
    refresh_millihz: BTreeMap<String, u32>,
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
            config.refresh_millihz.insert(name.clone(), refresh_millihz);
        }
        config.positions.insert(name, position);
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(arguments: &[&str]) -> Options {
        Options::parse_from(arguments.iter().map(|argument| (*argument).to_owned()))
            .expect("valid deniald options")
    }

    #[test]
    fn flutter_without_a_finite_limit_runs_until_logout() {
        let options = options(&["--wayland", "--flutter-bundle", "/tmp/denial-bundle"]);
        assert_eq!(options.runtime_limit(), RuntimeLimit::UntilLogout);
    }

    #[test]
    fn finite_flutter_harnesses_keep_their_limits() {
        let frames = options(&[
            "--wayland",
            "--flutter-bundle",
            "/tmp/denial-bundle",
            "--frames",
            "42",
        ]);
        let duration = options(&[
            "--wayland",
            "--flutter-bundle",
            "/tmp/denial-bundle",
            "--commit-seconds",
            "7",
        ]);

        assert_eq!(frames.runtime_limit(), RuntimeLimit::Frames(42));
        assert_eq!(
            duration.runtime_limit(),
            RuntimeLimit::Duration(Duration::from_secs(7))
        );
    }

    #[test]
    fn flutter_requires_the_wayland_frontend() {
        let error = Options::parse_from(
            ["--flutter-bundle", "/tmp/denial-bundle"]
                .into_iter()
                .map(str::to_owned),
        )
        .expect_err("Flutter without a Wayland frontend must be rejected");

        assert_eq!(error.to_string(), "--flutter-bundle requires --wayland");
    }

    #[test]
    fn no_flutter_and_no_limit_remains_test_only() {
        assert_eq!(options(&[]).runtime_limit(), RuntimeLimit::TestOnly);
    }

    #[test]
    fn output_config_accepts_positions_and_optional_refresh_rates() {
        let config = parse_output_config(
            "# physical desk profile\nDP-5 = 0, 0, 200\nDP-4=2560,-120 # raised display\n",
        )
        .expect("valid output config");

        assert_eq!(config.positions.len(), 2);
        assert_eq!(config.positions["DP-5"], LogicalPoint::new(0, 0));
        assert_eq!(config.positions["DP-4"], LogicalPoint::new(2560, -120));
        assert_eq!(config.refresh_millihz["DP-5"], 200_000);
        assert!(!config.refresh_millihz.contains_key("DP-4"));
    }

    #[test]
    fn system_bar_defaults_to_a_top_bar_on_the_ticker_output() {
        assert_eq!(options(&[]).work_area, WorkAreaOptions::default());
        assert_eq!(SystemBarOptions::default().side, SystemBarSide::Top);
        assert!(SystemBarOptions::default().thickness > 0.0);
        assert_eq!(SystemBarOptions::default().output, None);
    }

    #[test]
    fn system_bar_accepts_side_thickness_and_optional_output() {
        let bar = options(&["--system-bar", "bottom,48,DP-3"])
            .work_area
            .system_bar;
        assert_eq!(
            bar,
            SystemBarOptions {
                output: Some("DP-3".to_owned()),
                side: SystemBarSide::Bottom,
                thickness: 48.0,
            }
        );

        let auto = options(&["--system-bar", "top,24,auto"])
            .work_area
            .system_bar;
        assert_eq!(auto.output, None);

        let hidden = options(&["--system-bar", "hidden"]).work_area.system_bar;
        assert_eq!(hidden, SystemBarOptions::hidden());
    }

    #[test]
    fn system_bar_rejects_invalid_specs() {
        for spec in [
            "",
            "top",
            "top,0",
            "top,nan",
            "top,513",
            "middle,32",
            "top,32,DP-1,extra",
        ] {
            assert!(
                parse_system_bar_spec(spec).is_err(),
                "spec {spec:?} must be rejected"
            );
        }
    }

    #[test]
    fn output_config_carries_the_system_bar_and_command_line_wins() {
        let config =
            parse_output_config("DP-5=0,0\nsystem_bar = top, 36, DP-5 # reserve the strip\n")
                .expect("valid output config");
        assert_eq!(
            config.system_bar,
            Some(SystemBarOptions {
                output: Some("DP-5".to_owned()),
                side: SystemBarSide::Top,
                thickness: 36.0,
            })
        );

        let duplicate = parse_output_config("system_bar=top,36\nsystem_bar=hidden\n")
            .expect_err("duplicate system_bar must fail");
        assert!(duplicate.contains("line 2: duplicate system_bar entry"));
    }

    #[test]
    fn maximize_padding_defaults_and_parses_from_config_and_command_line() {
        assert_eq!(options(&[]).work_area.maximize_padding, 10.0);
        assert_eq!(
            options(&["--maximize-padding", "24"])
                .work_area
                .maximize_padding,
            24.0
        );

        let config = parse_output_config("maximize_padding = 16 # breathing room\n")
            .expect("valid output config");
        assert_eq!(config.maximize_padding, Some(16.0));

        let duplicate = parse_output_config("maximize_padding=8\nmaximize_padding=8\n")
            .expect_err("duplicate maximize_padding must fail");
        assert!(duplicate.contains("line 2: duplicate maximize_padding entry"));

        for value in ["", "-1", "257", "nan"] {
            assert!(
                parse_maximize_padding(value).is_err(),
                "padding {value:?} must be rejected"
            );
        }
    }

    #[test]
    fn output_config_rejects_duplicate_connector_names() {
        let error = parse_output_config("DP-5=0,0,200\nDP-5=2560,0,180\n")
            .expect_err("duplicate output must fail");

        assert!(error.contains("line 2: duplicate output DP-5"));
    }

    #[test]
    fn output_config_rejects_invalid_refresh_rates() {
        let zero = parse_output_config("DP-5=0,0,0\n").expect_err("zero refresh must fail");
        assert!(zero.contains("output refresh must be greater than zero"));

        let extra =
            parse_output_config("DP-5=0,0,200,unexpected\n").expect_err("extra fields must fail");
        assert!(extra.contains("NAME=X,Y[,REFRESH_HZ]"));
    }

    #[test]
    fn output_config_reader_rejects_oversized_files() {
        let error = read_output_config(std::io::Cursor::new(vec![
            b'x';
            MAX_OUTPUT_CONFIG_BYTES + 1
        ]))
        .expect_err("oversized output config must fail");

        assert!(error.contains("65536-byte limit"));
    }

    #[test]
    fn output_config_rejects_too_many_connectors() {
        let contents = (0..=MAX_CONFIGURED_OUTPUTS)
            .map(|index| format!("DP-{index}={index},0"))
            .collect::<Vec<_>>()
            .join("\n");
        let error =
            parse_output_config(&contents).expect_err("too many configured outputs must fail");

        assert!(error.contains("128-output limit"));
    }

    #[test]
    fn command_line_positions_share_the_output_limit() {
        let arguments = (0..=MAX_CONFIGURED_OUTPUTS).flat_map(|index| {
            [
                "--output-position".to_owned(),
                format!("DP-{index}={index},0"),
            ]
        });
        let error =
            Options::parse_from(arguments).expect_err("too many command-line positions must fail");

        assert!(error.to_string().contains("128-output limit"));
    }
}
