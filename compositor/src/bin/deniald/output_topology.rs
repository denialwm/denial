//! Connector discovery, output-control validation, and topology projection.

use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct OutputModePreference {
    pub(super) width: Option<u32>,
    pub(super) height: Option<u32>,
    pub(super) refresh_millihz: Option<u32>,
}

#[derive(Clone, Debug)]
pub(super) struct RuntimeOutputConfiguration {
    pub(super) primary_output: Option<String>,
    pub(super) positions: BTreeMap<String, LogicalPoint>,
    pub(super) modes: BTreeMap<String, OutputModePreference>,
    pub(super) scales_120: BTreeMap<String, u32>,
    pub(super) transforms: BTreeMap<String, OutputTransform>,
    /// Transient device rotation from iio-sensor-proxy. `transforms` remains
    /// the persistent panel-mount baseline.
    pub(super) sensor_rotation: OutputTransform,
    pub(super) vrr_outputs: BTreeSet<String>,
    pub(super) disabled_outputs: BTreeSet<String>,
}

#[derive(Clone, Debug)]
pub(super) struct ConnectedConnector {
    pub(super) info: connector::Info,
    pub(super) crtc: crtc::Handle,
}

impl RuntimeOutputConfiguration {
    pub(super) fn from_options(options: &Options) -> Self {
        let mut modes = options
            .refresh_millihz
            .iter()
            .map(|(name, refresh_millihz)| {
                (
                    name.clone(),
                    OutputModePreference {
                        width: None,
                        height: None,
                        refresh_millihz: Some(*refresh_millihz),
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();
        for (name, (width, height)) in &options.mode_sizes {
            let preference = modes.entry(name.clone()).or_insert(OutputModePreference {
                width: None,
                height: None,
                refresh_millihz: None,
            });
            preference.width = Some(*width);
            preference.height = Some(*height);
        }
        Self {
            primary_output: options.primary_output.clone(),
            positions: options.positions.clone(),
            modes,
            scales_120: options.scales_120.clone(),
            transforms: options.transforms.clone(),
            sensor_rotation: OutputTransform::Normal,
            vrr_outputs: options.vrr_outputs.clone(),
            disabled_outputs: options.disabled_outputs.clone(),
        }
    }

    pub(super) fn effective_transform(&self, name: &str) -> OutputTransform {
        let baseline = self
            .transforms
            .get(name)
            .copied()
            .unwrap_or(OutputTransform::Normal);
        if orientation_sensor_output(name) {
            baseline.rotated_by(self.sensor_rotation)
        } else {
            baseline
        }
    }

    pub(super) fn baseline_transform(
        &self,
        name: &str,
        effective: OutputTransform,
    ) -> OutputTransform {
        if orientation_sensor_output(name) {
            effective.rotated_by(self.sensor_rotation.inverse_rotation())
        } else {
            effective
        }
    }
}

fn orientation_sensor_output(name: &str) -> bool {
    name.starts_with("DSI-") || name.starts_with("eDP-") || name.starts_with("LVDS-")
}

pub(super) fn connected_outputs(
    scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &DrmDevice,
    max_outputs: usize,
    configuration: &RuntimeOutputConfiguration,
) -> Result<Vec<ConnectedOutput>, Box<dyn Error>> {
    let connected = scan_connected_connectors(scanner, drm)?;
    configured_outputs(connected, max_outputs, configuration)
}

pub(super) fn scan_connected_connectors(
    scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &DrmDevice,
) -> Result<Vec<ConnectedConnector>, Box<dyn Error>> {
    let scan = scanner.scan_connectors(drm)?;
    for event in scan.iter() {
        match event {
            DrmScanEvent::Connected { connector, crtc } => info!(
                connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
                ?crtc,
                "DRM connector added"
            ),
            DrmScanEvent::Disconnected { connector, crtc } => info!(
                connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
                ?crtc,
                "DRM connector removed"
            ),
            DrmScanEvent::Changed { connector, crtc } => info!(
                connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
                ?crtc,
                "DRM connector modes changed"
            ),
        }
    }
    Ok(current_connected_connectors(scanner))
}

fn current_connected_connectors(scanner: &DrmScanner<SimpleCrtcMapper>) -> Vec<ConnectedConnector> {
    let mut connected = scanner
        .crtcs()
        .filter(|(connector, _)| connector.state() == connector::State::Connected)
        .map(|(connector, crtc)| ConnectedConnector {
            info: connector.clone(),
            crtc,
        })
        .collect::<Vec<_>>();

    connected.sort_by_key(|connector| {
        (
            connector.info.interface().as_str().to_owned(),
            connector.info.interface_id(),
        )
    });
    connected
}

pub(super) fn configured_outputs(
    mut connected: Vec<ConnectedConnector>,
    max_outputs: usize,
    configuration: &RuntimeOutputConfiguration,
) -> Result<Vec<ConnectedOutput>, Box<dyn Error>> {
    connected.retain(|connector| {
        let name = format!(
            "{}-{}",
            connector.info.interface().as_str(),
            connector.info.interface_id()
        );
        if configuration.disabled_outputs.contains(&name) {
            info!(output = name, "ignoring disabled KMS output");
            false
        } else {
            true
        }
    });
    connected.truncate(max_outputs);

    connected
        .into_iter()
        .map(|connector| {
            let name = format!(
                "{}-{}",
                connector.info.interface().as_str(),
                connector.info.interface_id()
            );
            let vrr_enabled = configuration.vrr_outputs.contains(&name);
            let mode_preference = configuration.modes.get(&name).copied();
            let mode = select_output_mode(&connector.info, mode_preference).ok_or_else(|| {
                mode_preference.map_or_else(
                    || format!("{name} has no usable native mode"),
                    |preference| {
                        let size = preference.width.zip(preference.height).map_or_else(
                            || "native resolution".to_owned(),
                            |(width, height)| format!("{width}x{height}"),
                        );
                        let refresh = preference.refresh_millihz.map_or_else(
                            || "the highest available refresh".to_owned(),
                            |refresh| format!("{} mHz", refresh),
                        );
                        format!("{name} has no mode compatible with {size} at {refresh}")
                    },
                )
            })?;
            let output_mode: OutputMode = mode.into();
            let configured_refresh_millihz =
                mode_preference.and_then(|preference| preference.refresh_millihz);
            if let (Some(configured), Ok(selected)) = (
                configured_refresh_millihz,
                u32::try_from(output_mode.refresh),
            ) && selected.abs_diff(configured) > REFRESH_FALLBACK_WARNING_MILLIHERTZ
            {
                warn!(
                    output = name,
                    requested_refresh_millihz = configured,
                    selected_refresh_millihz = selected,
                    "requested refresh is unavailable; using the closest mode"
                );
            }
            info!(
                output = name,
                crtc = ?connector.crtc,
                width = output_mode.size.w,
                height = output_mode.size.h,
                refresh_millihz = output_mode.refresh,
                configured_refresh_millihz,
                vrr_enabled,
                "connected KMS output"
            );
            let transform = configuration.effective_transform(&name);
            Ok(ConnectedOutput {
                id: OutputId(u64::from(u32::from(connector.info.handle()))),
                name,
                connector: connector.info.handle(),
                crtc: connector.crtc,
                mode,
                transform,
                vrr_enabled,
            })
        })
        .collect()
}

#[cfg(feature = "flutter")]
pub(super) fn output_control_state(
    scanner: &DrmScanner<SimpleCrtcMapper>,
    scanouts: &[Scanout],
    topology: &TopologyManager,
    configuration: &RuntimeOutputConfiguration,
    persistence_available: bool,
    pending_confirmation: Option<output_control::OutputControlConfirmation>,
) -> Result<output_control::OutputControlState, Box<dyn Error>> {
    let snapshot = topology.snapshot();
    let mut outputs = Vec::new();
    let mut placement = HorizontalOutputPlacement::default();
    for output in &snapshot.outputs {
        placement.include(
            output.position,
            i32::try_from(output.logical_rect().width.ceil() as i64)?,
        )?;
    }
    for connector in current_connected_connectors(scanner) {
        let name = format!(
            "{}-{}",
            connector.info.interface().as_str(),
            connector.info.interface_id()
        );
        let id = OutputId(u64::from(u32::from(connector.info.handle())));
        let scanout = scanouts.iter().find(|scanout| scanout.output.id == id);
        let spec = snapshot.outputs.iter().find(|output| output.id == id);
        let enabled = scanout.is_some();
        let scale_120 = spec
            .map(|output| output.scale_120)
            .or_else(|| configuration.scales_120.get(&name).copied())
            .unwrap_or(SCALE_BASE);
        let transform = spec
            .map(|output| output.transform)
            .unwrap_or_else(|| configuration.effective_transform(&name));
        let modes = output_control_modes(&connector.info);
        let current_mode =
            scanout.and_then(|scanout| output_control_mode(&connector.info, scanout.output.mode));
        let fallback_mode = current_mode.or_else(|| {
            select_output_mode(&connector.info, configuration.modes.get(&name).copied())
                .and_then(|mode| output_control_mode(&connector.info, mode))
                .or_else(|| modes.first().copied())
        });
        let (logical_width, logical_height) = fallback_mode.map_or((0, 0), |mode| {
            logical_size_for_control(mode, scale_120, transform)
        });
        let position = placement.resolve(
            spec.map(|output| output.position)
                .or_else(|| configuration.positions.get(&name).copied()),
        );
        placement.include(position, i32::try_from(logical_width)?)?;
        let (physical_width_mm, physical_height_mm) = connector
            .info
            .size()
            .map_or((None, None), |(width, height)| (Some(width), Some(height)));
        let adaptive_sync = scanout
            .map(|scanout| scanout.output.vrr_enabled)
            .unwrap_or_else(|| configuration.vrr_outputs.contains(&name));
        let adaptive_sync_supported = scanout.is_some_and(|scanout| {
            match scanout.surface.vrr_supported(connector.info.handle()) {
                Ok(support) => support != VrrSupport::NotSupported,
                Err(error) => {
                    warn!(
                        output = name,
                        %error,
                        "could not query variable refresh rate support"
                    );
                    false
                }
            }
        });

        outputs.push(output_control::OutputControlOutput {
            monitor_id: i64::try_from(id.0)?,
            name: name.clone(),
            description: name.clone(),
            connected: true,
            enabled,
            powered: scanout.is_some_and(|scanout| scanout.powered),
            x: position.x,
            y: position.y,
            logical_width,
            logical_height,
            physical_width_mm,
            physical_height_mm,
            scale: f64::from(scale_120) / f64::from(SCALE_BASE),
            transform: output_transform_name(transform),
            adaptive_sync_supported,
            adaptive_sync,
            current_mode,
            modes,
        });
    }
    let capabilities = output_control::OutputControlCapabilities {
        persistent: persistence_available,
        ..Default::default()
    };
    Ok(output_control::OutputControlState {
        capabilities,
        primary_output: configuration.primary_output.clone(),
        outputs,
        pending_confirmation,
    })
}

#[cfg(feature = "flutter")]
fn output_control_modes(connector: &connector::Info) -> Vec<output_control::OutputControlMode> {
    let mut modes = BTreeMap::new();
    for mode in connector.modes() {
        let output_mode: OutputMode = (*mode).into();
        let Ok(width) = u32::try_from(output_mode.size.w) else {
            continue;
        };
        let Ok(height) = u32::try_from(output_mode.size.h) else {
            continue;
        };
        let Ok(refresh_millihz) = u32::try_from(output_mode.refresh) else {
            continue;
        };
        let preferred = mode.mode_type().contains(ModeTypeFlags::PREFERRED);
        modes
            .entry((width, height, refresh_millihz))
            .and_modify(|existing| *existing |= preferred)
            .or_insert(preferred);
    }
    let mut modes = modes
        .into_iter()
        .map(
            |((width, height, refresh_millihz), preferred)| output_control::OutputControlMode {
                width,
                height,
                refresh_millihz,
                preferred,
            },
        )
        .collect::<Vec<_>>();
    modes.sort_by_key(|mode| {
        (
            std::cmp::Reverse(mode.preferred),
            std::cmp::Reverse(u64::from(mode.width) * u64::from(mode.height)),
            std::cmp::Reverse(mode.refresh_millihz),
        )
    });
    modes
}

#[cfg(feature = "flutter")]
fn output_control_mode(
    connector: &connector::Info,
    mode: Mode,
) -> Option<output_control::OutputControlMode> {
    let output_mode: OutputMode = mode.into();
    Some(output_control::OutputControlMode {
        width: u32::try_from(output_mode.size.w).ok()?,
        height: u32::try_from(output_mode.size.h).ok()?,
        refresh_millihz: u32::try_from(output_mode.refresh).ok()?,
        preferred: connector.modes().iter().any(|candidate| {
            candidate.size() == mode.size()
                && OutputMode::from(*candidate).refresh == output_mode.refresh
                && candidate.mode_type().contains(ModeTypeFlags::PREFERRED)
        }),
    })
}

#[cfg(feature = "flutter")]
fn logical_size_for_control(
    mode: output_control::OutputControlMode,
    scale_120: u32,
    transform: OutputTransform,
) -> (u32, u32) {
    if scale_120 == 0 {
        return (0, 0);
    }
    let (width, height) = if transform.swaps_axes() {
        (mode.height, mode.width)
    } else {
        (mode.width, mode.height)
    };
    let scaled = |value: u32| {
        let numerator = u64::from(value) * u64::from(SCALE_BASE);
        u32::try_from((numerator + u64::from(scale_120) / 2) / u64::from(scale_120))
            .unwrap_or(u32::MAX)
    };
    (scaled(width), scaled(height))
}

#[cfg(feature = "flutter")]
fn output_transform_name(transform: OutputTransform) -> output_control::OutputTransformName {
    match transform {
        OutputTransform::Normal => output_control::OutputTransformName::Normal,
        OutputTransform::Rotate90 => output_control::OutputTransformName::Rotate90,
        OutputTransform::Rotate180 => output_control::OutputTransformName::Rotate180,
        OutputTransform::Rotate270 => output_control::OutputTransformName::Rotate270,
        OutputTransform::Flipped => output_control::OutputTransformName::Flipped,
        OutputTransform::Flipped90 => output_control::OutputTransformName::Flipped90,
        OutputTransform::Flipped180 => output_control::OutputTransformName::Flipped180,
        OutputTransform::Flipped270 => output_control::OutputTransformName::Flipped270,
    }
}

#[cfg(feature = "flutter")]
fn output_transform_from_name(transform: output_control::OutputTransformName) -> OutputTransform {
    match transform {
        output_control::OutputTransformName::Normal => OutputTransform::Normal,
        output_control::OutputTransformName::Rotate90 => OutputTransform::Rotate90,
        output_control::OutputTransformName::Rotate180 => OutputTransform::Rotate180,
        output_control::OutputTransformName::Rotate270 => OutputTransform::Rotate270,
        output_control::OutputTransformName::Flipped => OutputTransform::Flipped,
        output_control::OutputTransformName::Flipped90 => OutputTransform::Flipped90,
        output_control::OutputTransformName::Flipped180 => OutputTransform::Flipped180,
        output_control::OutputTransformName::Flipped270 => OutputTransform::Flipped270,
    }
}

#[cfg(feature = "flutter")]
pub(super) fn output_request_changes_only_transforms(
    current: &[output_control::OutputControlOutput],
    requested: &[output_control::RequestedOutput],
) -> bool {
    if current.len() != requested.len() {
        return false;
    }

    let mut transform_changed = false;
    for requested in requested {
        let Some(current) = current
            .iter()
            .find(|current| current.name == requested.name)
        else {
            return false;
        };
        let Some(mode) = current.current_mode else {
            return false;
        };
        if current.enabled != requested.enabled
            || current.powered != requested.powered
            || current.x != requested.x
            || current.y != requested.y
            || mode.width != requested.mode.width
            || mode.height != requested.mode.height
            || mode.refresh_millihz != requested.mode.refresh_millihz
            || current.scale != requested.scale
            || current.adaptive_sync != requested.adaptive_sync
        {
            return false;
        }
        transform_changed |= current.transform != requested.transform;
    }
    transform_changed
}

#[cfg(feature = "flutter")]
pub(super) fn configuration_from_output_request(
    request: &output_control::ApplyOutputConfiguration,
    connectors: &[ConnectedConnector],
    max_outputs: usize,
    current: &RuntimeOutputConfiguration,
    persistence_available: bool,
) -> Result<
    (RuntimeOutputConfiguration, BTreeMap<OutputId, bool>),
    output_control::OutputControlFailure,
> {
    const MIN_SCALE: f64 = 0.25;
    const MAX_SCALE: f64 = 8.0;
    const MIN_CONFIRMATION_TIMEOUT_MILLISECONDS: u64 = 1_000;
    const MAX_CONFIRMATION_TIMEOUT_MILLISECONDS: u64 = 60_000;

    if request.persistent && !persistence_available {
        return Err(output_control::OutputControlFailure::new(
            "unsupported",
            "persistent output configuration requires deniald --output-config",
        ));
    }
    if request
        .confirmation_timeout_milliseconds
        .is_some_and(|timeout| {
            !(MIN_CONFIRMATION_TIMEOUT_MILLISECONDS..=MAX_CONFIRMATION_TIMEOUT_MILLISECONDS)
                .contains(&timeout)
        })
    {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "output confirmation timeout must be within [{MIN_CONFIRMATION_TIMEOUT_MILLISECONDS}, {MAX_CONFIRMATION_TIMEOUT_MILLISECONDS}] milliseconds"
            ),
        ));
    }
    if let Some(primary_output) = request.primary_output.as_deref()
        && (primary_output.is_empty()
            || primary_output.trim() != primary_output
            || primary_output
                .chars()
                .any(|character| character.is_control() || matches!(character, '#' | ',' | '=')))
    {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!("invalid primary output name {primary_output:?}"),
        ));
    }
    if request.outputs.len() != connectors.len() {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "a complete configuration for {} connected outputs is required, received {}",
                connectors.len(),
                request.outputs.len()
            ),
        ));
    }

    let mut requested_by_name = BTreeMap::new();
    for output in &request.outputs {
        if requested_by_name
            .insert(output.name.as_str(), output)
            .is_some()
        {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!("output {} appears more than once", output.name),
            ));
        }
    }
    let connected_names = connectors
        .iter()
        .map(|connector| {
            format!(
                "{}-{}",
                connector.info.interface().as_str(),
                connector.info.interface_id()
            )
        })
        .collect::<BTreeSet<_>>();
    let requested_names = requested_by_name
        .keys()
        .map(|name| (*name).to_owned())
        .collect::<BTreeSet<_>>();
    if connected_names != requested_names {
        let missing = connected_names
            .difference(&requested_names)
            .cloned()
            .collect::<Vec<_>>();
        let unknown = requested_names
            .difference(&connected_names)
            .cloned()
            .collect::<Vec<_>>();
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "output set does not match connected hardware; missing={missing:?}, unknown={unknown:?}"
            ),
        ));
    }

    let enabled_count = request
        .outputs
        .iter()
        .filter(|output| output.enabled)
        .count();
    if enabled_count == 0 {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            "at least one connected output must remain enabled",
        ));
    }
    if enabled_count > max_outputs {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "{enabled_count} enabled outputs exceed Denial's configured limit of {max_outputs}"
            ),
        ));
    }

    let mut staged = current.clone();
    staged.primary_output = request.primary_output.clone();
    let mut power = BTreeMap::new();
    for connector in connectors {
        let name = format!(
            "{}-{}",
            connector.info.interface().as_str(),
            connector.info.interface_id()
        );
        let output = requested_by_name[&name.as_str()];
        if !output.enabled && output.powered {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!("disabled output {name} cannot be powered on"),
            ));
        }
        if !output.scale.is_finite() || !(MIN_SCALE..=MAX_SCALE).contains(&output.scale) {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!("{name} scale must be finite and within [{MIN_SCALE}, {MAX_SCALE}]"),
            ));
        }
        let mode = OutputModePreference {
            width: Some(output.mode.width),
            height: Some(output.mode.height),
            refresh_millihz: Some(output.mode.refresh_millihz),
        };
        if select_output_mode(&connector.info, Some(mode)).is_none() {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!(
                    "{} does not advertise {}x{} at {} mHz",
                    name, output.mode.width, output.mode.height, output.mode.refresh_millihz
                ),
            ));
        }

        let scale_120 = (output.scale * f64::from(SCALE_BASE)).round() as u32;
        staged
            .positions
            .insert(name.clone(), LogicalPoint::new(output.x, output.y));
        staged.modes.insert(name.clone(), mode);
        staged.scales_120.insert(name.clone(), scale_120);
        let effective_transform = output_transform_from_name(output.transform);
        staged.transforms.insert(
            name.clone(),
            current.baseline_transform(&name, effective_transform),
        );
        if output.enabled {
            staged.disabled_outputs.remove(&name);
            power.insert(
                OutputId(u64::from(u32::from(connector.info.handle()))),
                output.powered,
            );
        } else {
            staged.disabled_outputs.insert(name.clone());
            power.remove(&OutputId(u64::from(u32::from(connector.info.handle()))));
        }
        if output.adaptive_sync {
            staged.vrr_outputs.insert(name);
        } else {
            staged.vrr_outputs.remove(&name);
        }
    }
    Ok((staged, power))
}

pub(super) fn stage_output_vrr(
    surface: &DrmSurface,
    output: &ConnectedOutput,
) -> Result<(), Box<dyn Error>> {
    if output.vrr_enabled {
        let support = surface.vrr_supported(output.connector)?;
        if support == VrrSupport::NotSupported {
            return Err(format!("{} does not advertise VRR support", output.name).into());
        }
        if surface.vrr_enabled() {
            return Ok(());
        }
        info!(
            output = output.name,
            ?support,
            "enabling variable refresh rate"
        );
    } else {
        if !surface.vrr_enabled() {
            return Ok(());
        }
        info!(output = output.name, "disabling variable refresh rate");
    }
    surface
        .use_vrr(output.vrr_enabled)
        .map_err(|error| format!("{} VRR staging failed: {error}", output.name).into())
}

const REFRESH_FALLBACK_WARNING_MILLIHERTZ: u32 = 1_000;

fn select_output_mode(
    connector: &connector::Info,
    preference: Option<OutputModePreference>,
) -> Option<Mode> {
    let preferred = connector
        .modes()
        .iter()
        .find(|mode| mode.mode_type().contains(ModeTypeFlags::PREFERRED))
        .or_else(|| connector.modes().first())?;
    let selected_size = match preference {
        Some(OutputModePreference {
            width: Some(width),
            height: Some(height),
            ..
        }) => (u16::try_from(width).ok()?, u16::try_from(height).ok()?),
        Some(OutputModePreference {
            width: None,
            height: None,
            ..
        })
        | None => preferred.size(),
        Some(_) => return None,
    };
    let configured_refresh_millihz = preference.and_then(|preference| preference.refresh_millihz);

    let matching_modes = connector
        .modes()
        .iter()
        .filter(|mode| mode.size() == selected_size)
        .filter_map(|mode| {
            let refresh = u32::try_from(OutputMode::from(*mode).refresh).ok()?;
            Some((*mode, refresh))
        })
        .collect::<Vec<_>>();
    let selected_refresh = select_refresh_millihz(
        matching_modes.iter().map(|(_, refresh)| *refresh),
        configured_refresh_millihz,
    )?;
    matching_modes
        .into_iter()
        .find_map(|(mode, refresh)| (refresh == selected_refresh).then_some(mode))
}

fn select_refresh_millihz(
    refreshes: impl IntoIterator<Item = u32>,
    configured_refresh_millihz: Option<u32>,
) -> Option<u32> {
    let refreshes = refreshes.into_iter();
    match configured_refresh_millihz {
        Some(configured) => refreshes
            .min_by_key(|refresh| (refresh.abs_diff(configured), std::cmp::Reverse(*refresh))),
        None => refreshes.max(),
    }
}

pub(super) fn topology_for_outputs(
    outputs: &[ConnectedOutput],
    configuration: &RuntimeOutputConfiguration,
) -> Result<TopologyManager, Box<dyn Error>> {
    Ok(TopologyManager::new_with_primary_output(
        output_specs(outputs, configuration)?,
        configuration.primary_output.clone(),
    )?)
}

pub(super) fn update_topology_for_outputs(
    topology: &mut TopologyManager,
    outputs: &[ConnectedOutput],
    configuration: &RuntimeOutputConfiguration,
) -> Result<TopologySnapshot, Box<dyn Error>> {
    let specs = output_specs(outputs, configuration)?;
    let desired = specs.iter().map(|output| output.id).collect::<HashSet<_>>();
    let mut changes = topology
        .snapshot()
        .outputs
        .into_iter()
        .filter(|output| !desired.contains(&output.id))
        .map(|output| TopologyChange::Remove(output.id))
        .collect::<Vec<_>>();
    changes.extend(specs.into_iter().map(TopologyChange::Upsert));
    topology.apply_with_primary_output(changes, configuration.primary_output.clone())?;
    Ok(topology.snapshot())
}

fn output_specs(
    outputs: &[ConnectedOutput],
    configuration: &RuntimeOutputConfiguration,
) -> Result<Vec<OutputSpec>, Box<dyn Error>> {
    let mut pending = Vec::with_capacity(outputs.len());

    for output in outputs {
        let mode: OutputMode = output.mode.into();
        let width = u32::try_from(mode.size.w)?;
        let height = u32::try_from(mode.size.h)?;
        let configured_position = configuration.positions.get(&output.name).copied();
        let scale_120 = configuration
            .scales_120
            .get(&output.name)
            .copied()
            .unwrap_or(SCALE_BASE);
        pending.push((
            OutputSpec {
                id: output.id,
                name: output.name.clone(),
                position: configured_position.unwrap_or(LogicalPoint::new(0, 0)),
                mode: PixelSize::new(width, height),
                scale_120,
                refresh_millihz: u32::try_from(mode.refresh)?,
                transform: output.transform,
            },
            configured_position.is_some(),
        ));
    }

    let mut placement = HorizontalOutputPlacement::default();
    for (spec, configured) in &pending {
        if *configured {
            placement.include(
                spec.position,
                i32::try_from(spec.logical_rect().width.ceil() as i64)?,
            )?;
        }
    }

    let mut specs = Vec::with_capacity(pending.len());
    for (mut spec, configured) in pending {
        if !configured {
            spec.position = placement.resolve(None);
        }
        placement.include(
            spec.position,
            i32::try_from(spec.logical_rect().width.ceil() as i64)?,
        )?;
        specs.push(spec);
    }

    Ok(specs)
}

#[derive(Default)]
struct HorizontalOutputPlacement {
    default_x: i32,
}

impl HorizontalOutputPlacement {
    fn resolve(&self, configured: Option<LogicalPoint>) -> LogicalPoint {
        configured.unwrap_or(LogicalPoint::new(self.default_x, 0))
    }

    fn include(
        &mut self,
        position: LogicalPoint,
        logical_width: i32,
    ) -> Result<(), Box<dyn Error>> {
        self.default_x = self.default_x.max(
            position
                .x
                .checked_add(logical_width)
                .ok_or("output layout overflow")?,
        );
        Ok(())
    }
}

#[cfg(test)]
#[path = "output_topology/tests.rs"]
mod tests;
