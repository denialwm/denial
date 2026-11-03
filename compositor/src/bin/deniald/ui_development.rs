use std::error::Error;
use std::ffi::CStr;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use super::plugin_bundle::{self, PluginSelection};

use serde::{Deserialize, Serialize};

pub(super) const CONTROL_CHANNEL: &CStr = c"denial/ui_development/control";
pub(super) const STATE_CHANNEL: &CStr = c"denial/ui_development/state";

const PROTOCOL_VERSION: u8 = 1;
const CONTROL_HEADER_BYTES: usize = 12;
const STATE_HEADER_BYTES: usize = 40;
const MAX_PACKET_BYTES: usize = 64 * 1024;
const MAX_WORKSPACE_BYTES: usize = 4096;
const MAX_DIAGNOSTICS: usize = 64;
const MAX_CONFIG_BYTES: usize = 64 * 1024;
const CONFIG_SCHEMA_VERSION: u32 = 1;
/// A compiled plugin that draws a frame and keeps running this long is kept.
const PLUGIN_CONFIRM_DELAY: Duration = Duration::from_secs(3);
/// A compiled plugin without a first frame by then is replaced.
const PLUGIN_START_TIMEOUT: Duration = Duration::from_secs(20);
static CONFIG_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
// These modes are part of the versioned state contract before every
// corresponding activation backend is available.
#[allow(dead_code)]
pub(super) enum UiRuntimeMode {
    OfficialOptimized = 0,
    CustomOptimized = 1,
    LiveDevelopment = 2,
    Unavailable = 3,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
// The protocol reserves operation states which later vertical slices will
// begin emitting without changing the wire format.
#[allow(dead_code)]
enum UiDevelopmentOperation {
    Idle = 0,
    ValidatingWorkspace = 1,
    SwitchingRuntime = 2,
    HotReloading = 3,
    HotRestarting = 4,
    BuildingOptimized = 5,
    Reverting = 6,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
// Informational diagnostics are reserved alongside the currently emitted
// warning and error severities.
#[allow(dead_code)]
enum DiagnosticSeverity {
    Information = 0,
    Warning = 1,
    Error = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CommandKind {
    Query,
    EnableLiveDevelopment,
    DisableLiveDevelopment,
    SetWorkspace,
    HotReload,
    HotRestart,
    BuildAndActivateOptimized,
    RestoreOfficial,
    RevertLastWorking,
    SetAutoReload,
    ActivatePluginBundle,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct UiDevelopmentCommand {
    kind: CommandKind,
    request_id: u32,
    workspace: Option<PathBuf>,
    auto_reload: bool,
}

impl UiDevelopmentCommand {
    pub(super) fn from_control(
        kind: CommandKind,
        request_id: u32,
        workspace: Option<PathBuf>,
        auto_reload: bool,
    ) -> Result<Self, UiDevelopmentProtocolError> {
        if request_id == 0 {
            return Err(protocol_error("request id must be non-zero"));
        }
        if matches!(
            kind,
            CommandKind::SetWorkspace | CommandKind::ActivatePluginBundle
        ) != workspace.is_some()
        {
            return Err(protocol_error(
                "workspace is only valid for the set-workspace command",
            ));
        }
        if !matches!(kind, CommandKind::SetAutoReload) && auto_reload {
            return Err(protocol_error(
                "auto reload is only valid for the set-auto-reload command",
            ));
        }
        if let Some(path) = workspace.as_deref() {
            workspace_protocol_string(path).ok_or_else(|| {
                protocol_error(
                    "workspace must be valid UTF-8, contain no NUL, and fit the size limit",
                )
            })?;
        }
        Ok(Self {
            kind,
            request_id,
            workspace,
            auto_reload,
        })
    }

    pub(super) fn kind(&self) -> CommandKind {
        self.kind
    }
}

#[derive(Debug)]
pub(super) struct UiDevelopmentProtocolError(String);

impl fmt::Display for UiDevelopmentProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

impl Error for UiDevelopmentProtocolError {}

pub(super) fn decode_control_packet(
    packet: &[u8],
) -> Result<UiDevelopmentCommand, UiDevelopmentProtocolError> {
    if packet.len() < CONTROL_HEADER_BYTES {
        return Err(protocol_error("control packet is truncated"));
    }
    if packet.len() > MAX_PACKET_BYTES {
        return Err(protocol_error("control packet exceeds the size limit"));
    }
    if packet[0] != PROTOCOL_VERSION {
        return Err(protocol_error("unsupported control protocol version"));
    }
    let kind = match packet[1] {
        0 => CommandKind::Query,
        1 => CommandKind::EnableLiveDevelopment,
        2 => CommandKind::DisableLiveDevelopment,
        3 => CommandKind::SetWorkspace,
        4 => CommandKind::HotReload,
        5 => CommandKind::HotRestart,
        6 => CommandKind::BuildAndActivateOptimized,
        7 => CommandKind::RestoreOfficial,
        8 => CommandKind::RevertLastWorking,
        9 => CommandKind::SetAutoReload,
        _ => return Err(protocol_error("unknown UI development command")),
    };
    if packet[3] != 0 || u16::from_le_bytes([packet[10], packet[11]]) != 0 {
        return Err(protocol_error("reserved control fields are non-zero"));
    }
    let request_id = u32::from_le_bytes(packet[4..8].try_into().expect("bounded header"));
    if request_id == 0 {
        return Err(protocol_error("request id must be non-zero"));
    }
    let workspace_length = usize::from(u16::from_le_bytes([packet[8], packet[9]]));
    if workspace_length > MAX_WORKSPACE_BYTES
        || CONTROL_HEADER_BYTES
            .checked_add(workspace_length)
            .is_none_or(|length| length != packet.len())
    {
        return Err(protocol_error("invalid workspace payload length"));
    }
    let workspace = if workspace_length == 0 {
        None
    } else {
        let bytes = &packet[CONTROL_HEADER_BYTES..];
        if bytes.contains(&0) {
            return Err(protocol_error("workspace contains a NUL byte"));
        }
        let value = std::str::from_utf8(bytes)
            .map_err(|_| protocol_error("workspace is not valid UTF-8"))?;
        Some(PathBuf::from(value))
    };
    if matches!(kind, CommandKind::SetWorkspace) != workspace.is_some() {
        return Err(protocol_error(
            "workspace is only valid for the set-workspace command",
        ));
    }
    if !matches!(kind, CommandKind::SetAutoReload) && packet[2] != 0 {
        return Err(protocol_error(
            "flags are only valid for the auto-reload command",
        ));
    }
    if matches!(kind, CommandKind::SetAutoReload) && packet[2] > 1 {
        return Err(protocol_error("invalid auto-reload flag"));
    }
    UiDevelopmentCommand::from_control(kind, request_id, workspace, packet[2] != 0)
}

fn protocol_error(message: impl Into<String>) -> UiDevelopmentProtocolError {
    UiDevelopmentProtocolError(message.into())
}

#[derive(Clone, Debug, Serialize)]
struct UiDevelopmentDiagnostic {
    severity: DiagnosticSeverity,
    message: String,
    path: String,
    line: u32,
    column: u32,
}

/// The last confirmed plugin composition was built for another installed
/// Denial. It is intact intent, not a failure: the manager rebuilds it.
#[derive(Clone, Debug, Serialize)]
pub(super) struct PluginRebuild {
    reason: plugin_bundle::UpdateReason,
    bundle: PathBuf,
    version: String,
    /// The identity a rebuilt composition must carry; absent for a
    /// development bundle without a source marker.
    installed_source: Option<serde_json::Value>,
}

/// Facts that decide whether replacing the shell would interrupt the user.
/// Only control replies carry them; the shell's own state packet does not.
#[derive(Clone, Copy, Debug, Serialize)]
pub(super) struct SessionActivity {
    pub(super) locked: bool,
    pub(super) input_idle_ms: u64,
    pub(super) shell_captures_keyboard: bool,
    /// A visible application, such as a video player, asked not to idle.
    pub(super) idle_inhibited: bool,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct UiDevelopmentState {
    active_mode: UiRuntimeMode,
    desired_mode: UiRuntimeMode,
    operation: UiDevelopmentOperation,
    developer_components_available: bool,
    workspace_valid: bool,
    auto_reload: bool,
    auto_reload_supported: bool,
    can_hot_reload: bool,
    can_hot_restart: bool,
    can_build_optimized: bool,
    can_revert: bool,
    vm_service_uri: String,
    generation: u64,
    revision: u64,
    acknowledged_request_id: u32,
    workspace: String,
    status: String,
    error: String,
    diagnostics: Vec<UiDevelopmentDiagnostic>,
    progress_basis_points: Option<u16>,
    plugin_bundle: Option<PathBuf>,
    plugin_healthy: bool,
    plugin_rebuild: Option<PluginRebuild>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_activity: Option<SessionActivity>,
    capabilities: Vec<&'static str>,
    // Query-only JSON telemetry; not part of the Dart UI state packet.
    #[serde(skip_serializing_if = "Option::is_none")]
    native_client_composition: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    output_frame_delivery: Option<serde_json::Value>,
}

impl UiDevelopmentState {
    pub(super) fn error_message(&self) -> Option<&str> {
        (!self.error.is_empty()).then_some(&self.error)
    }

    pub(super) fn with_output_frame_delivery(mut self, trace: serde_json::Value) -> Self {
        self.output_frame_delivery = Some(trace);
        self
    }

    pub(super) fn with_native_client_composition(mut self, stats: serde_json::Value) -> Self {
        self.native_client_composition = Some(stats);
        self
    }

    pub(super) fn with_session_activity(mut self, activity: SessionActivity) -> Self {
        self.session_activity = Some(activity);
        self
    }
}

impl UiDevelopmentState {
    fn packet(&self) -> Result<Vec<u8>, UiDevelopmentProtocolError> {
        let workspace = bounded_string("workspace", &self.workspace, MAX_WORKSPACE_BYTES)?;
        let vm_service = bounded_string("VM service URI", &self.vm_service_uri, u16::MAX as usize)?;
        let status = bounded_string("status", &self.status, u16::MAX as usize)?;
        let error = bounded_string("error", &self.error, u16::MAX as usize)?;
        if self.diagnostics.len() > MAX_DIAGNOSTICS {
            return Err(protocol_error("too many UI development diagnostics"));
        }

        let mut packet = Vec::with_capacity(STATE_HEADER_BYTES + 1024);
        packet.resize(STATE_HEADER_BYTES, 0);
        packet[0] = PROTOCOL_VERSION;
        packet[1] = self.active_mode as u8;
        packet[2] = self.desired_mode as u8;
        packet[3] = self.operation as u8;
        let flags = self.developer_components_available as u16
            | ((self.workspace_valid as u16) << 1)
            | ((self.auto_reload as u16) << 2)
            | ((self.can_hot_reload as u16) << 3)
            | ((self.can_hot_restart as u16) << 4)
            | ((self.can_build_optimized as u16) << 5)
            | ((self.can_revert as u16) << 6)
            | (((!self.vm_service_uri.is_empty()) as u16) << 7)
            | ((self.auto_reload_supported as u16) << 8);
        packet[4..6].copy_from_slice(&flags.to_le_bytes());
        let progress = match self.progress_basis_points {
            Some(progress) if progress <= 10_000 => progress,
            Some(_) => return Err(protocol_error("operation progress exceeds 100 percent")),
            None => u16::MAX,
        };
        packet[6..8].copy_from_slice(&progress.to_le_bytes());
        packet[8..16].copy_from_slice(&self.generation.to_le_bytes());
        packet[16..24].copy_from_slice(&self.revision.to_le_bytes());
        packet[24..28].copy_from_slice(&self.acknowledged_request_id.to_le_bytes());
        packet[28..30].copy_from_slice(
            &u16::try_from(workspace.len())
                .expect("workspace was bounded")
                .to_le_bytes(),
        );
        packet[30..32].copy_from_slice(
            &u16::try_from(vm_service.len())
                .expect("VM service URI was bounded")
                .to_le_bytes(),
        );
        packet[32..34].copy_from_slice(
            &u16::try_from(status.len())
                .expect("status was bounded")
                .to_le_bytes(),
        );
        packet[34..36].copy_from_slice(
            &u16::try_from(error.len())
                .expect("error was bounded")
                .to_le_bytes(),
        );
        packet[36..38].copy_from_slice(
            &u16::try_from(self.diagnostics.len())
                .expect("diagnostics were bounded")
                .to_le_bytes(),
        );
        packet.extend_from_slice(workspace);
        packet.extend_from_slice(vm_service);
        packet.extend_from_slice(status);
        packet.extend_from_slice(error);

        for diagnostic in &self.diagnostics {
            let path = bounded_string("diagnostic path", &diagnostic.path, u16::MAX as usize)?;
            let message =
                bounded_string("diagnostic message", &diagnostic.message, u16::MAX as usize)?;
            packet.push(diagnostic.severity as u8);
            packet.push(0);
            packet.extend_from_slice(&diagnostic.line.to_le_bytes());
            packet.extend_from_slice(&diagnostic.column.to_le_bytes());
            packet.extend_from_slice(
                &u16::try_from(path.len())
                    .expect("diagnostic path was bounded")
                    .to_le_bytes(),
            );
            packet.extend_from_slice(
                &u16::try_from(message.len())
                    .expect("diagnostic message was bounded")
                    .to_le_bytes(),
            );
            packet.extend_from_slice(path);
            packet.extend_from_slice(message);
        }
        if packet.len() > MAX_PACKET_BYTES {
            return Err(protocol_error("state packet exceeds the size limit"));
        }
        Ok(packet)
    }
}

fn bounded_string<'a>(
    label: &str,
    value: &'a str,
    maximum: usize,
) -> Result<&'a [u8], UiDevelopmentProtocolError> {
    let bytes = value.as_bytes();
    if bytes.len() > maximum {
        return Err(protocol_error(format!("{label} exceeds the size limit")));
    }
    Ok(bytes)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum UiDevelopmentEffect {
    None,
    Reload(UiRuntimeMode),
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedUiDevelopment {
    schema_version: u32,
    workspace: Option<PathBuf>,
    auto_reload: bool,
}

#[derive(Serialize)]
struct VmServiceInfo<'a> {
    uri: &'a str,
}

pub(super) struct UiDevelopmentController {
    official_bundle: PathBuf,
    debug_bundle: Option<PathBuf>,
    custom_bundle: Option<PathBuf>,
    config_path: Option<PathBuf>,
    vm_service_path: Option<PathBuf>,
    state: UiDevelopmentState,
    plugins: PluginSelection,
    release_bundle: Option<PathBuf>,
    plugin_start: Option<Instant>,
}

impl UiDevelopmentController {
    pub(super) fn new(
        official_bundle: &Path,
        debug_bundle: Option<PathBuf>,
        workspace_override: Option<PathBuf>,
    ) -> Self {
        Self::with_paths(
            official_bundle,
            debug_bundle.or_else(default_debug_bundle_path),
            default_profile_bundle_path(),
            workspace_override,
            default_config_path(),
            default_vm_service_path(),
        )
    }

    fn with_paths(
        official_bundle: &Path,
        debug_bundle: Option<PathBuf>,
        custom_bundle: Option<PathBuf>,
        workspace_override: Option<PathBuf>,
        config_path: Option<PathBuf>,
        vm_service_path: Option<PathBuf>,
    ) -> Self {
        let persisted = config_path.as_deref().and_then(load_config);
        let workspace = workspace_override.or_else(|| {
            persisted
                .as_ref()
                .and_then(|configuration| configuration.workspace.clone())
        });
        let auto_reload = persisted
            .as_ref()
            .is_none_or(|configuration| configuration.auto_reload);
        let workspace_string = workspace
            .as_deref()
            .and_then(workspace_protocol_string)
            .unwrap_or_default();
        let workspace_valid = !workspace_string.is_empty()
            && workspace
                .as_deref()
                .is_some_and(|path| validate_workspace(path).is_ok());
        let developer_components_available = debug_bundle.as_deref().is_some_and(|bundle| {
            validate_debug_bundle(bundle, workspace.as_deref().filter(|_| workspace_valid)).is_ok()
        });
        let profile_components_available = custom_bundle.as_deref().is_some_and(|bundle| {
            validate_profile_bundle(bundle, workspace.as_deref().filter(|_| workspace_valid))
                .is_ok()
        });
        let status = if developer_components_available {
            "The packaged optimized Flutter shell is active.".to_owned()
        } else {
            "Live development needs a configured JIT Flutter bundle.".to_owned()
        };
        let plugin_path = config_path
            .as_ref()
            .and_then(|p| p.parent())
            .map(|p| p.join("plugin-composition.json"));
        let mut plugin_error = String::new();
        let mut plugin_rebuild = None;
        let mut plugins = PluginSelection::open(plugin_path).unwrap_or_else(|error| {
            plugin_error = error;
            PluginSelection::empty()
        });
        // Only a confirmed selection reaches this point: an interrupted start
        // was already demoted by `open` and is never classified as an update.
        let release_bundle = plugins
            .selected()
            .map(Path::to_owned)
            .and_then(|candidate| {
                let validated = plugin_bundle::validate_bundle(&candidate, official_bundle)
                    .and_then(|bundle| {
                        plugins.begin(&bundle, true)?;
                        Ok(bundle)
                    });
                match validated {
                    Ok(bundle) => Some(bundle),
                    Err(plugin_bundle::Rejection {
                        update: Some(reason),
                        ..
                    }) => {
                        plugin_rebuild = Some(PluginRebuild {
                            reason,
                            bundle: candidate,
                            version: denial_core::version().to_owned(),
                            installed_source: plugin_bundle::installed_source_identity(
                                official_bundle,
                            )
                            .ok()
                            .flatten(),
                        });
                        None
                    }
                    Err(rejection) => {
                        plugin_error = rejection.message;
                        None
                    }
                }
            });
        let desired_mode = if release_bundle.is_some() {
            UiRuntimeMode::CustomOptimized
        } else {
            UiRuntimeMode::OfficialOptimized
        };
        Self {
            official_bundle: official_bundle.to_owned(),
            debug_bundle,
            custom_bundle,
            config_path,
            vm_service_path,
            plugins,
            release_bundle,
            plugin_start: None,
            state: UiDevelopmentState {
                active_mode: UiRuntimeMode::OfficialOptimized,
                desired_mode,
                operation: UiDevelopmentOperation::Idle,
                developer_components_available,
                workspace_valid,
                auto_reload,
                auto_reload_supported: false,
                can_hot_reload: false,
                can_hot_restart: false,
                can_build_optimized: profile_components_available,
                can_revert: false,
                vm_service_uri: String::new(),
                generation: 0,
                revision: 1,
                acknowledged_request_id: 0,
                workspace: workspace_string,
                status,
                error: plugin_error,
                diagnostics: Vec::new(),
                progress_basis_points: None,
                plugin_bundle: None,
                plugin_healthy: false,
                plugin_rebuild,
                session_activity: None,
                native_client_composition: None,
                output_frame_delivery: None,
                capabilities: vec!["pluginActionsV1"],
            },
        }
    }

    pub(super) fn plugin_rebuild_needed(&self) -> bool {
        self.state.plugin_rebuild.is_some()
    }

    pub(super) fn handle_external_command(
        &mut self,
        command: UiDevelopmentCommand,
    ) -> (UiDevelopmentEffect, UiDevelopmentState) {
        if self.state.operation == UiDevelopmentOperation::SwitchingRuntime
            && matches!(
                command.kind,
                CommandKind::ActivatePluginBundle
                    | CommandKind::RevertLastWorking
                    | CommandKind::BuildAndActivateOptimized
                    | CommandKind::EnableLiveDevelopment
            )
        {
            // Reject just this caller. A competing request must not poison the
            // first caller's health status or replace its pending selection.
            let mut reply = self.state_snapshot();
            reply.acknowledged_request_id = command.request_id;
            reply.error =
                "A UI runtime transition is already in progress; wait for it to finish.".into();
            return (UiDevelopmentEffect::None, reply);
        }
        let effect = self.handle_command(command);
        (effect, self.state_snapshot())
    }

    pub(super) fn handle_command(&mut self, command: UiDevelopmentCommand) -> UiDevelopmentEffect {
        self.state.acknowledged_request_id = command.request_id;
        if command.kind != CommandKind::Query {
            self.state.error.clear();
        }
        if command.kind != CommandKind::Query || self.state.error.is_empty() {
            self.state.diagnostics.clear();
        }
        self.state.progress_basis_points = None;
        let effect = match command.kind {
            CommandKind::Query => {
                self.refresh_availability();
                UiDevelopmentEffect::None
            }
            CommandKind::SetWorkspace => {
                if matches!(
                    self.state.active_mode,
                    UiRuntimeMode::LiveDevelopment | UiRuntimeMode::CustomOptimized
                ) || matches!(
                    self.state.desired_mode,
                    UiRuntimeMode::LiveDevelopment | UiRuntimeMode::CustomOptimized
                ) {
                    self.reject(
                        "Return to the packaged optimized UI before changing the live workspace.",
                    );
                } else {
                    self.set_workspace(command.workspace.expect("validated command workspace"));
                }
                UiDevelopmentEffect::None
            }
            CommandKind::SetAutoReload => {
                if self.state.auto_reload_supported {
                    self.state.auto_reload = command.auto_reload;
                    self.persist();
                    self.state.status = if command.auto_reload {
                        "Successful source changes will reload automatically.".to_owned()
                    } else {
                        "Automatic reload is paused.".to_owned()
                    };
                } else {
                    self.reject(
                        "Automatic source watching is not connected yet; use VSCodium or Flutter attach for hot reload.",
                    );
                }
                UiDevelopmentEffect::None
            }
            CommandKind::ActivatePluginBundle => {
                self.activate_plugin(command.workspace.expect("validated bundle path"))
            }
            CommandKind::EnableLiveDevelopment => self.request_mode(UiRuntimeMode::LiveDevelopment),
            CommandKind::DisableLiveDevelopment | CommandKind::RestoreOfficial => {
                if let Err(error) = self.plugins.restore() {
                    self.reject(error);
                    UiDevelopmentEffect::None
                } else {
                    self.release_bundle = None;
                    self.plugin_start = None;
                    // Choosing the packaged shell supersedes the composition
                    // that was waiting for a rebuild.
                    self.state.plugin_rebuild = None;
                    self.request_mode(UiRuntimeMode::OfficialOptimized)
                }
            }
            CommandKind::HotRestart => {
                self.reject(
                    "Hot restart will become available after Denial owns a Flutter tooling connection.",
                );
                UiDevelopmentEffect::None
            }
            CommandKind::HotReload => {
                self.reject(
                    "Hot reload will become available after Flutter tooling attaches to the Dart VM service.",
                );
                UiDevelopmentEffect::None
            }
            CommandKind::BuildAndActivateOptimized => {
                let expected_workspace = self
                    .state
                    .workspace_valid
                    .then(|| Path::new(&self.state.workspace));
                let validation = self
                    .custom_bundle
                    .as_deref()
                    .ok_or_else(|| "No AOT profile Flutter bundle is configured.".to_owned())
                    .and_then(|bundle| validate_profile_bundle(bundle, expected_workspace));
                match validation {
                    Ok(()) => {
                        self.release_bundle = None;
                        self.state.operation = UiDevelopmentOperation::SwitchingRuntime;
                        self.request_mode(UiRuntimeMode::CustomOptimized)
                    }
                    Err(error) => {
                        self.state.can_build_optimized = false;
                        self.reject(error);
                        UiDevelopmentEffect::None
                    }
                }
            }
            CommandKind::RevertLastWorking => {
                if let Some(previous) = self.plugins.previous().map(Path::to_owned) {
                    self.activate_plugin(previous)
                } else {
                    self.reject("There is no previous custom optimized UI to restore.");
                    UiDevelopmentEffect::None
                }
            }
        };
        self.bump_revision();
        effect
    }

    fn activate_plugin(&mut self, candidate: PathBuf) -> UiDevelopmentEffect {
        match plugin_bundle::validate(&candidate, &self.official_bundle).and_then(|bundle| {
            self.plugins.begin(&bundle, false)?;
            Ok(bundle)
        }) {
            Ok(bundle) => {
                self.release_bundle = Some(bundle);
                self.plugin_start = None;
                self.state.operation = UiDevelopmentOperation::SwitchingRuntime;
                self.state.status = "Starting the compiled plugin composition…".into();
                self.state.desired_mode = UiRuntimeMode::CustomOptimized;
                UiDevelopmentEffect::Reload(UiRuntimeMode::CustomOptimized)
            }
            Err(error) => {
                self.reject(error);
                UiDevelopmentEffect::None
            }
        }
    }

    pub(super) fn uses_release_plugins(&self) -> bool {
        self.release_bundle.is_some()
    }

    /// When `poll_plugin_health` next has something to decide: the plugin
    /// confirms after 3 s with a frame, and fails after 20 s without one.
    pub(super) fn plugin_health_deadline(&self, now: Instant) -> Option<Instant> {
        let started = self.plugin_start?;
        [PLUGIN_CONFIRM_DELAY, PLUGIN_START_TIMEOUT]
            .into_iter()
            .map(|delay| started + delay)
            .find(|deadline| *deadline > now)
    }

    pub(super) fn poll_plugin_health(
        &mut self,
        produced_frame: bool,
    ) -> Option<UiDevelopmentEffect> {
        let started = self.plugin_start?;
        if produced_frame && started.elapsed() >= PLUGIN_CONFIRM_DELAY {
            match self.plugins.confirm() {
                Ok(()) => {
                    self.plugin_start = None;
                    self.state.plugin_healthy = true;
                    self.state.plugin_rebuild = None;
                    self.state.operation = UiDevelopmentOperation::Idle;
                    self.state.can_revert = self.plugins.previous().is_some();
                    self.state.status = "Compiled plugin composition is active.".into();
                    self.bump_revision();
                    return Some(UiDevelopmentEffect::None);
                }
                Err(error) => {
                    self.runtime_failed(UiRuntimeMode::CustomOptimized, &error);
                    return Some(UiDevelopmentEffect::Reload(
                        UiRuntimeMode::OfficialOptimized,
                    ));
                }
            }
        }
        if started.elapsed() >= PLUGIN_START_TIMEOUT {
            self.runtime_failed(
                UiRuntimeMode::CustomOptimized,
                &"No initial frame arrived within 20 seconds",
            );
            return Some(UiDevelopmentEffect::Reload(
                UiRuntimeMode::OfficialOptimized,
            ));
        }
        None
    }

    fn set_workspace(&mut self, workspace: PathBuf) {
        self.state.operation = UiDevelopmentOperation::ValidatingWorkspace;
        self.state.workspace = workspace.to_string_lossy().into_owned();
        match validate_workspace(&workspace) {
            Ok(()) => {
                self.state.workspace_valid = true;
                let debug_validation = self
                    .debug_bundle
                    .as_deref()
                    .ok_or_else(|| "No JIT Flutter bundle is configured.".to_owned())
                    .and_then(|bundle| validate_debug_bundle(bundle, Some(&workspace)));
                match debug_validation {
                    Ok(()) => {
                        self.state.developer_components_available = true;
                        self.state.status =
                            "Flutter source workspace and JIT bundle are ready.".to_owned();
                    }
                    Err(error) => {
                        self.state.developer_components_available = false;
                        self.state.status =
                            "The workspace is valid, but its JIT bundle needs preparation."
                                .to_owned();
                        self.state.diagnostics.push(UiDevelopmentDiagnostic {
                            severity: DiagnosticSeverity::Warning,
                            message: error,
                            path: workspace.to_string_lossy().into_owned(),
                            line: 0,
                            column: 0,
                        });
                    }
                }
            }
            Err(error) => {
                self.state.workspace_valid = false;
                self.reject(error);
            }
        }
        self.state.operation = UiDevelopmentOperation::Idle;
        self.state.can_build_optimized = self.custom_bundle.as_deref().is_some_and(|bundle| {
            validate_profile_bundle(bundle, Some(Path::new(&self.state.workspace))).is_ok()
        });
        self.persist();
    }

    fn request_mode(&mut self, mode: UiRuntimeMode) -> UiDevelopmentEffect {
        if mode == self.state.active_mode && self.state.operation == UiDevelopmentOperation::Idle {
            self.state.desired_mode = mode;
            self.state.status = match mode {
                UiRuntimeMode::OfficialOptimized => {
                    "The packaged optimized Flutter shell is already active.".to_owned()
                }
                UiRuntimeMode::LiveDevelopment => {
                    "Live UI development is already active.".to_owned()
                }
                UiRuntimeMode::CustomOptimized => {
                    "Optimized AOT profile mode is already active.".to_owned()
                }
                UiRuntimeMode::Unavailable => "No Flutter runtime is active.".to_owned(),
            };
            return UiDevelopmentEffect::None;
        }
        if mode == UiRuntimeMode::LiveDevelopment {
            if !self.state.workspace_valid {
                self.reject("Choose a valid Flutter source workspace first.");
                return UiDevelopmentEffect::None;
            }
            let validation = self
                .debug_bundle
                .as_deref()
                .ok_or_else(|| {
                    "No JIT Flutter bundle is configured for this Denial session.".to_owned()
                })
                .and_then(|bundle| {
                    validate_debug_bundle(bundle, Some(Path::new(&self.state.workspace)))
                });
            if let Err(error) = validation {
                self.state.developer_components_available = false;
                self.reject(error);
                return UiDevelopmentEffect::None;
            }
        } else if mode == UiRuntimeMode::CustomOptimized && self.release_bundle.is_none() {
            let expected_workspace = self
                .state
                .workspace_valid
                .then(|| Path::new(&self.state.workspace));
            let validation = self
                .custom_bundle
                .as_deref()
                .ok_or_else(|| "No AOT profile Flutter bundle is configured.".to_owned())
                .and_then(|bundle| validate_profile_bundle(bundle, expected_workspace));
            if let Err(error) = validation {
                self.state.can_build_optimized = false;
                self.reject(error);
                return UiDevelopmentEffect::None;
            }
        }
        self.state.desired_mode = mode;
        self.state.operation = UiDevelopmentOperation::SwitchingRuntime;
        self.state.status = match mode {
            UiRuntimeMode::OfficialOptimized => {
                "Switching to the packaged optimized Flutter shell…".to_owned()
            }
            UiRuntimeMode::CustomOptimized => {
                "Starting the optimized AOT profile Flutter shell and Dart VM service…".to_owned()
            }
            UiRuntimeMode::LiveDevelopment => {
                "Starting the JIT Flutter shell and Dart VM service…".to_owned()
            }
            UiRuntimeMode::Unavailable => "Stopping the Flutter shell…".to_owned(),
        };
        UiDevelopmentEffect::Reload(mode)
    }

    fn reject(&mut self, message: impl Into<String>) {
        let message = message.into();
        self.state.operation = UiDevelopmentOperation::Idle;
        self.state.error.clone_from(&message);
        self.state.diagnostics.push(UiDevelopmentDiagnostic {
            severity: DiagnosticSeverity::Error,
            message,
            path: String::new(),
            line: 0,
            column: 0,
        });
    }

    fn refresh_availability(&mut self) {
        self.state.workspace_valid = (!self.state.workspace.is_empty())
            && validate_workspace(Path::new(&self.state.workspace)).is_ok();
        let expected_workspace = self
            .state
            .workspace_valid
            .then(|| Path::new(&self.state.workspace));
        let debug_validation = self
            .debug_bundle
            .as_deref()
            .ok_or_else(|| "No JIT Flutter bundle is configured.".to_owned())
            .and_then(|bundle| validate_debug_bundle(bundle, expected_workspace));
        self.state.developer_components_available = debug_validation.is_ok();
        self.state.can_revert = self.plugins.previous().is_some();
        self.state.can_build_optimized = self
            .custom_bundle
            .as_deref()
            .is_some_and(|bundle| validate_profile_bundle(bundle, expected_workspace).is_ok());
        if self.state.active_mode == UiRuntimeMode::OfficialOptimized && self.state.error.is_empty()
        {
            self.state.status = if !self.state.workspace_valid {
                "Choose a Flutter source workspace to begin live UI development.".to_owned()
            } else if self.state.developer_components_available {
                "Live development components are ready when you are.".to_owned()
            } else {
                "The workspace is valid, but its JIT bundle needs preparation.".to_owned()
            };
        }
        if self.state.error.is_empty()
            && self.state.workspace_valid
            && let Err(error) = debug_validation
        {
            self.state.diagnostics.push(UiDevelopmentDiagnostic {
                severity: DiagnosticSeverity::Warning,
                message: error,
                path: self.state.workspace.clone(),
                line: 0,
                column: 0,
            });
        }
    }

    pub(super) fn desired_mode(&self) -> UiRuntimeMode {
        self.state.desired_mode
    }

    pub(super) fn bundle_for(&self, mode: UiRuntimeMode) -> Option<&Path> {
        match mode {
            UiRuntimeMode::OfficialOptimized => Some(&self.official_bundle),
            UiRuntimeMode::CustomOptimized => self
                .release_bundle
                .as_deref()
                .or(self.custom_bundle.as_deref()),
            UiRuntimeMode::LiveDevelopment => self.debug_bundle.as_deref(),
            UiRuntimeMode::Unavailable => None,
        }
    }

    pub(super) fn runtime_started(&mut self, mode: UiRuntimeMode, generation: u64) {
        let recovered_to_official =
            mode == UiRuntimeMode::OfficialOptimized && !self.state.error.is_empty();
        self.clear_vm_service_endpoint();
        self.state.active_mode = mode;
        self.state.desired_mode = mode;
        self.state.operation = UiDevelopmentOperation::Idle;
        self.state.plugin_bundle = if mode == UiRuntimeMode::CustomOptimized {
            self.release_bundle.clone()
        } else {
            None
        };
        self.state.plugin_healthy = false;
        self.plugin_start = self.state.plugin_bundle.as_ref().map(|_| Instant::now());
        if self.plugin_start.is_some() {
            self.state.operation = UiDevelopmentOperation::SwitchingRuntime;
        }
        self.state.generation = generation;
        self.state.can_hot_restart = false;
        self.state.can_hot_reload = false;
        self.state.status = match (mode, recovered_to_official) {
            (UiRuntimeMode::OfficialOptimized, true) => {
                "The packaged optimized Flutter shell was restored after a development runtime failure."
                    .to_owned()
            }
            (UiRuntimeMode::OfficialOptimized, false) => {
                self.state.error.clear();
                if self.state.plugin_rebuild.is_some() {
                    "The packaged shell is active until your plugins are rebuilt for this Denial version.".to_owned()
                } else {
                    "The packaged optimized Flutter shell is active.".to_owned()
                }
            }
            (UiRuntimeMode::CustomOptimized, _) => {
                self.state.error.clear();
                if self.release_bundle.is_some() { "Waiting for the plugin composition's first frame…".into() }
                else { "Optimized AOT profile mode is active.".to_owned() }
            }
            (UiRuntimeMode::LiveDevelopment, _) => {
                self.state.error.clear();
                "Live Flutter UI development is active.".to_owned()
            }
            (UiRuntimeMode::Unavailable, _) => {
                self.state.error.clear();
                "The Flutter shell is unavailable.".to_owned()
            }
        };
        self.bump_revision();
    }

    pub(super) fn runtime_failed(&mut self, mode: UiRuntimeMode, error: &dyn fmt::Display) {
        if self.release_bundle.is_some() {
            let _ = self.plugins.reject();
            self.release_bundle = None;
            self.plugin_start = None;
        }
        self.state.desired_mode = UiRuntimeMode::OfficialOptimized;
        self.state.operation = UiDevelopmentOperation::SwitchingRuntime;
        self.state.error = format!(
            "Could not start {}: {error}. Restoring the packaged UI.",
            mode.description()
        );
        self.state.diagnostics.clear();
        self.state.diagnostics.push(UiDevelopmentDiagnostic {
            severity: DiagnosticSeverity::Error,
            message: self.state.error.clone(),
            path: String::new(),
            line: 0,
            column: 0,
        });
        self.bump_revision();
    }

    pub(super) fn runtime_switch_failed_preserving_active(
        &mut self,
        mode: UiRuntimeMode,
        error: &dyn fmt::Display,
    ) {
        let _ = self.plugins.reject();
        self.release_bundle = self.state.plugin_bundle.clone();
        self.plugin_start = None;
        let active_mode = self.state.active_mode;
        self.state.desired_mode = active_mode;
        self.state.operation = UiDevelopmentOperation::Idle;
        self.state.error = format!(
            "Could not start {}: {error}. Continuing with {}.",
            mode.description(),
            active_mode.description()
        );
        self.state.status = format!(
            "The requested runtime was not started; {} remains active.",
            active_mode.description()
        );
        self.state.diagnostics.clear();
        self.state.diagnostics.push(UiDevelopmentDiagnostic {
            severity: DiagnosticSeverity::Error,
            message: self.state.error.clone(),
            path: String::new(),
            line: 0,
            column: 0,
        });
        self.bump_revision();
    }

    pub(super) fn set_vm_service_uri(&mut self, uri: String) {
        if !matches!(
            self.state.active_mode,
            UiRuntimeMode::LiveDevelopment | UiRuntimeMode::CustomOptimized
        ) {
            return;
        }
        if let Some(path) = self.vm_service_path.as_deref()
            && let Err(error) = save_vm_service_info(path, &uri)
        {
            self.state.diagnostics.push(UiDevelopmentDiagnostic {
                severity: DiagnosticSeverity::Warning,
                message: format!("Could not publish the local VM service endpoint: {error}"),
                path: path.to_string_lossy().into_owned(),
                line: 0,
                column: 0,
            });
        }
        self.state.vm_service_uri = uri;
        // The URI is intentionally exposed with its authentication token so
        // Flutter tooling and IDEs can attach. Denial does not claim its own
        // hot-reload button is ready until it owns a VM-service client.
        self.state.can_hot_reload = false;
        self.state.can_hot_restart = false;
        self.state.status = if self.state.active_mode == UiRuntimeMode::CustomOptimized {
            "Optimized AOT profile mode is ready for Flutter DevTools.".to_owned()
        } else {
            "Live Flutter UI development is ready for VSCodium and Flutter tooling.".to_owned()
        };
        self.bump_revision();
    }

    pub(super) fn state_packet(&self) -> Result<Vec<u8>, UiDevelopmentProtocolError> {
        self.state.packet()
    }

    pub(super) fn state_snapshot(&self) -> UiDevelopmentState {
        self.state.clone()
    }

    fn persist(&mut self) {
        let Some(path) = self.config_path.as_deref() else {
            self.state.diagnostics.push(UiDevelopmentDiagnostic {
                severity: DiagnosticSeverity::Warning,
                message: "Could not determine the Denial configuration directory.".to_owned(),
                path: String::new(),
                line: 0,
                column: 0,
            });
            return;
        };
        let workspace =
            (!self.state.workspace.is_empty()).then(|| PathBuf::from(&self.state.workspace));
        let configuration = PersistedUiDevelopment {
            schema_version: CONFIG_SCHEMA_VERSION,
            workspace,
            auto_reload: self.state.auto_reload,
        };
        if let Err(error) = save_config(path, &configuration) {
            self.state.diagnostics.push(UiDevelopmentDiagnostic {
                severity: DiagnosticSeverity::Warning,
                message: format!("Could not save UI development settings: {error}"),
                path: path.to_string_lossy().into_owned(),
                line: 0,
                column: 0,
            });
        }
    }

    fn bump_revision(&mut self) {
        self.state.revision = self.state.revision.wrapping_add(1).max(1);
    }

    fn clear_vm_service_endpoint(&mut self) {
        self.state.vm_service_uri.clear();
        self.state.can_hot_reload = false;
        let Some(path) = self.vm_service_path.as_deref() else {
            return;
        };
        let Some(metadata) = fs::symlink_metadata(path).ok() else {
            return;
        };
        if metadata.file_type().is_file() {
            let _ = fs::remove_file(path);
        }
    }
}

impl Drop for UiDevelopmentController {
    fn drop(&mut self) {
        self.clear_vm_service_endpoint();
    }
}

impl UiRuntimeMode {
    fn description(self) -> &'static str {
        match self {
            Self::OfficialOptimized => "the packaged optimized Flutter shell",
            Self::CustomOptimized => "the custom optimized Flutter shell",
            Self::LiveDevelopment => "the live Flutter development shell",
            Self::Unavailable => "an unavailable Flutter shell",
        }
    }
}

fn validate_workspace(path: &Path) -> Result<(), String> {
    workspace_protocol_string(path).ok_or_else(|| {
        "The Flutter source workspace path must be valid UTF-8 and at most 4,096 bytes.".to_owned()
    })?;
    if !path.is_absolute() {
        return Err("The Flutter source workspace must be an absolute path.".to_owned());
    }
    let metadata = fs::metadata(path)
        .map_err(|error| format!("Could not open workspace {}: {error}", path.display()))?;
    if !metadata.is_dir() {
        return Err(format!("Workspace {} is not a directory.", path.display()));
    }
    for relative in ["pubspec.yaml", "lib/main.dart"] {
        let required = path.join(relative);
        if !required.is_file() {
            return Err(format!(
                "Workspace is missing {}.",
                required.to_string_lossy()
            ));
        }
    }
    Ok(())
}

fn workspace_protocol_string(path: &Path) -> Option<String> {
    let value = path.to_str()?;
    (value.len() <= MAX_WORKSPACE_BYTES && !value.as_bytes().contains(&0)).then(|| value.to_owned())
}

fn validate_debug_bundle(path: &Path, expected_workspace: Option<&Path>) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("The JIT Flutter bundle path must be absolute.".to_owned());
    }
    for candidates in [
        vec![
            path.join("lib/libflutter_engine.so"),
            path.join("libflutter_engine.so"),
        ],
        vec![path.join("data/icudtl.dat")],
        vec![path.join("data/flutter_assets/kernel_blob.bin")],
    ] {
        if !candidates.iter().any(|candidate| regular_file(candidate)) {
            return Err(format!(
                "JIT Flutter bundle is missing {}.",
                candidates[0].display()
            ));
        }
    }
    validate_bundle_workspace(
        path,
        expected_workspace,
        "JIT Flutter bundle",
        "denial-ui prepare",
    )
}

fn validate_profile_bundle(path: &Path, expected_workspace: Option<&Path>) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("The AOT profile Flutter bundle path must be absolute.".to_owned());
    }
    for candidates in [
        vec![
            path.join("lib/libflutter_engine.so"),
            path.join("libflutter_engine.so"),
        ],
        vec![path.join("data/icudtl.dat")],
        vec![path.join("lib/libapp.so"), path.join("libapp.so")],
        vec![path.join("data/flutter_assets/AssetManifest.bin")],
    ] {
        if !candidates.iter().any(|candidate| regular_file(candidate)) {
            return Err(format!(
                "AOT profile Flutter bundle is missing {}.",
                candidates[0].display()
            ));
        }
    }
    validate_bundle_workspace(
        path,
        expected_workspace,
        "AOT profile Flutter bundle",
        "denial-ui prepare-profile",
    )
}

fn validate_bundle_workspace(
    path: &Path,
    expected_workspace: Option<&Path>,
    label: &str,
    prepare_command: &str,
) -> Result<(), String> {
    let workspace_marker = path.join("workspace.path");
    let prepared_workspace = read_workspace_marker(&workspace_marker, label)?;
    if let Some(expected_workspace) = expected_workspace {
        let prepared = fs::canonicalize(&prepared_workspace).map_err(|error| {
            format!(
                "Could not resolve the {label} workspace {}: {error}",
                prepared_workspace.display()
            )
        })?;
        let expected = fs::canonicalize(expected_workspace).map_err(|error| {
            format!(
                "Could not resolve the selected workspace {}: {error}",
                expected_workspace.display()
            )
        })?;
        if prepared != expected {
            return Err(format!(
                "The {label} was prepared for {}, not {}. Run {prepare_command} for the selected workspace.",
                prepared.display(),
                expected.display()
            ));
        }
    }
    Ok(())
}

fn regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file())
}

fn read_workspace_marker(path: &Path, label: &str) -> Result<PathBuf, String> {
    if !regular_file(path) {
        return Err(format!(
            "{label} is missing its workspace marker at {}.",
            path.display()
        ));
    }
    let mut bytes = Vec::with_capacity(256);
    fs::File::open(path)
        .map_err(|error| format!("Could not open {}: {error}", path.display()))?
        .take((MAX_WORKSPACE_BYTES + 2) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    if bytes.len() > MAX_WORKSPACE_BYTES + 1 {
        return Err(format!("{label} workspace marker exceeds the size limit."));
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.is_empty()
        || bytes.len() > MAX_WORKSPACE_BYTES
        || bytes.contains(&0)
        || bytes.contains(&b'\n')
        || bytes.contains(&b'\r')
    {
        return Err(format!("{label} workspace marker is malformed."));
    }
    let value = std::str::from_utf8(&bytes)
        .map_err(|_| format!("{label} workspace marker is not valid UTF-8."))?;
    let workspace = PathBuf::from(value);
    if !workspace.is_absolute() {
        return Err(format!("{label} workspace marker is not absolute."));
    }
    Ok(workspace)
}

fn default_config_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".config"))
        })?;
    Some(root.join("denial/ui-development.json"))
}

fn default_debug_bundle_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".cache"))
        })?;
    Some(root.join("denial/ui-development/debug/bundle"))
}

fn default_profile_bundle_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".cache"))
        })?;
    Some(root.join("denial/ui-development/profile/bundle"))
}

fn default_vm_service_path() -> Option<PathBuf> {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .map(|path| path.join("denial/flutter-vm-service.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn startup_with_selected(
        fixture: &plugin_bundle::fixtures::Fixture,
        official: &Path,
        selected: &Path,
    ) -> UiDevelopmentController {
        let config = fixture.0.join("config");
        fs::create_dir_all(&config).unwrap();
        fs::write(
            config.join("plugin-composition.json"),
            serde_json::to_vec(&serde_json::json!({"schema": 1, "selected": selected})).unwrap(),
        )
        .unwrap();
        UiDevelopmentController::with_paths(
            official,
            None,
            None,
            None,
            Some(config.join("ui-development.json")),
            None,
        )
    }

    #[test]
    fn an_updated_installation_rebuilds_the_confirmed_composition_without_an_error() {
        use plugin_bundle::fixtures::{Fixture, set_manifest_field};
        let fixture = Fixture::new();
        let (bundle, official) = fixture.bundle();
        set_manifest_field(
            &bundle,
            "source_identity",
            serde_json::json!({"source_revision": "0.2.1"}),
        );
        fs::write(
            official.join(".denial-ui-source.json"),
            b"{\"source_revision\":\"0.3.0\"}",
        )
        .unwrap();
        let mut controller = startup_with_selected(&fixture, &official, &bundle);
        assert!(controller.state.error.is_empty());
        assert!(controller.release_bundle.is_none());
        assert_eq!(controller.desired_mode(), UiRuntimeMode::OfficialOptimized);
        assert!(controller.plugin_rebuild_needed());
        // The composition remains the user's intent until a rebuild confirms
        // its replacement.
        assert_eq!(controller.plugins.selected(), Some(bundle.as_path()));
        let value = serde_json::to_value(&controller.state).unwrap();
        assert_eq!(value["plugin_rebuild"]["reason"], "source");
        assert_eq!(value["plugin_rebuild"]["bundle"], bundle.to_str().unwrap());
        assert_eq!(value["plugin_rebuild"]["version"], denial_core::version());
        assert_eq!(
            value["plugin_rebuild"]["installed_source"],
            serde_json::json!({"source_revision": "0.3.0"})
        );
        assert!(value.get("session_activity").is_none());
        controller.runtime_started(UiRuntimeMode::OfficialOptimized, 1);
        assert!(controller.state.status.contains("rebuilt"));

        let activity = SessionActivity {
            locked: false,
            input_idle_ms: 4_200,
            shell_captures_keyboard: true,
            idle_inhibited: false,
        };
        let value =
            serde_json::to_value(controller.state_snapshot().with_session_activity(activity))
                .unwrap();
        assert_eq!(value["session_activity"]["input_idle_ms"], 4_200);
        assert_eq!(value["session_activity"]["shell_captures_keyboard"], true);

        let restore =
            UiDevelopmentCommand::from_control(CommandKind::RestoreOfficial, 1, None, false)
                .unwrap();
        controller.handle_command(restore);
        assert!(!controller.plugin_rebuild_needed());
        assert_eq!(controller.plugins.selected(), None);
    }

    #[test]
    fn a_confirmed_replacement_ends_the_rebuild_and_damage_stays_an_error() {
        use plugin_bundle::fixtures::{Fixture, seal, set_manifest_field, unseal};
        let fixture = Fixture::new();
        let (bundle, official) = fixture.bundle();
        set_manifest_field(
            &bundle,
            "source_identity",
            serde_json::json!({"source_revision": "0.2.1"}),
        );
        fs::write(
            official.join(".denial-ui-source.json"),
            b"{\"source_revision\":\"0.3.0\"}",
        )
        .unwrap();
        let mut controller = startup_with_selected(&fixture, &official, &bundle);
        controller
            .plugins
            .begin(Path::new("/rebuilt"), false)
            .unwrap();
        controller.release_bundle = Some(PathBuf::from("/rebuilt"));
        controller.runtime_started(UiRuntimeMode::CustomOptimized, 2);
        controller.plugin_start = Some(Instant::now() - Duration::from_secs(4));
        assert_eq!(
            controller.poll_plugin_health(true),
            Some(UiDevelopmentEffect::None)
        );
        assert!(!controller.plugin_rebuild_needed());
        assert_eq!(controller.plugins.selected(), Some(Path::new("/rebuilt")));

        // A damaged bundle for the installed release is a recovery error.
        set_manifest_field(
            &bundle,
            "source_identity",
            serde_json::json!({"source_revision": "0.3.0"}),
        );
        unseal(&bundle);
        fs::write(bundle.join("lib/libapp.so"), b"damaged").unwrap();
        seal(&bundle);
        let controller = startup_with_selected(&fixture, &official, &bundle);
        assert!(!controller.plugin_rebuild_needed());
        assert!(controller.state.error.contains("checksum mismatch"));
    }

    #[test]
    fn plugin_health_requires_a_frame_and_failed_startup_requests_packaged_recovery() {
        let directory =
            std::env::temp_dir().join(format!("denial-plugin-health-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let mut controller = UiDevelopmentController::with_paths(
            Path::new("/official"),
            None,
            None,
            None,
            Some(directory.join("ui-development.json")),
            None,
        );
        controller
            .plugins
            .begin(Path::new("/candidate"), false)
            .unwrap();
        controller.release_bundle = Some(PathBuf::from("/candidate"));
        controller.runtime_started(UiRuntimeMode::CustomOptimized, 7);
        controller.plugin_start = Some(Instant::now() - Duration::from_secs(4));
        let concurrent = UiDevelopmentCommand::from_control(
            CommandKind::ActivatePluginBundle,
            42,
            Some(PathBuf::from("/second")),
            false,
        )
        .unwrap();
        let (effect, reply) = controller.handle_external_command(concurrent);
        assert_eq!(effect, UiDevelopmentEffect::None);
        assert!(reply.error.contains("already in progress"));
        assert!(controller.state.error.is_empty());
        assert_eq!(
            controller.release_bundle.as_deref(),
            Some(Path::new("/candidate"))
        );
        assert_eq!(controller.poll_plugin_health(false), None);
        assert!(!controller.state.plugin_healthy);
        assert_eq!(
            controller.poll_plugin_health(true),
            Some(UiDevelopmentEffect::None)
        );
        assert!(controller.state.plugin_healthy);
        assert_eq!(controller.plugins.selected(), Some(Path::new("/candidate")));
        controller
            .plugins
            .begin(Path::new("/broken"), false)
            .unwrap();
        controller.release_bundle = Some(PathBuf::from("/broken"));
        controller.runtime_started(UiRuntimeMode::CustomOptimized, 8);
        controller.plugin_start = Some(Instant::now() - Duration::from_secs(21));
        assert_eq!(
            controller.poll_plugin_health(false),
            Some(UiDevelopmentEffect::Reload(
                UiRuntimeMode::OfficialOptimized
            ))
        );
        assert_eq!(controller.desired_mode(), UiRuntimeMode::OfficialOptimized);
        assert_eq!(controller.plugins.selected(), Some(Path::new("/candidate")));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn renderer_preparation_failure_preserves_the_active_runtime() {
        let mut controller = UiDevelopmentController::with_paths(
            Path::new("/official"),
            None,
            None,
            None,
            None,
            None,
        );
        controller.state.desired_mode = UiRuntimeMode::LiveDevelopment;
        controller.state.operation = UiDevelopmentOperation::SwitchingRuntime;
        let generation = controller.state.generation;
        let revision = controller.state.revision;

        controller.runtime_switch_failed_preserving_active(
            UiRuntimeMode::LiveDevelopment,
            &"renderer preflight failed",
        );

        assert_eq!(
            controller.state.active_mode,
            UiRuntimeMode::OfficialOptimized
        );
        assert_eq!(
            controller.state.desired_mode,
            UiRuntimeMode::OfficialOptimized
        );
        assert_eq!(controller.state.operation, UiDevelopmentOperation::Idle);
        assert_eq!(controller.state.generation, generation);
        assert!(controller.state.error.contains("renderer preflight failed"));
        assert!(
            controller
                .state
                .error
                .contains("Continuing with the packaged")
        );
        assert_eq!(controller.state.diagnostics.len(), 1);
        assert_ne!(controller.state.revision, revision);
    }

    #[test]
    fn retained_live_runtime_keeps_its_vm_service_capabilities() {
        let mut controller = UiDevelopmentController::with_paths(
            Path::new("/official"),
            None,
            None,
            None,
            None,
            None,
        );
        controller.state.active_mode = UiRuntimeMode::LiveDevelopment;
        controller.state.desired_mode = UiRuntimeMode::OfficialOptimized;
        controller.state.operation = UiDevelopmentOperation::SwitchingRuntime;
        controller.state.vm_service_uri = "http://127.0.0.1:1234/token/".to_owned();
        controller.state.can_hot_reload = true;
        controller.state.can_hot_restart = true;

        controller.runtime_switch_failed_preserving_active(
            UiRuntimeMode::OfficialOptimized,
            &"renderer preflight failed",
        );

        assert_eq!(controller.state.active_mode, UiRuntimeMode::LiveDevelopment);
        assert_eq!(
            controller.state.desired_mode,
            UiRuntimeMode::LiveDevelopment
        );
        assert_eq!(controller.state.operation, UiDevelopmentOperation::Idle);
        assert_eq!(
            controller.state.vm_service_uri,
            "http://127.0.0.1:1234/token/"
        );
        assert!(controller.state.can_hot_reload);
        assert!(controller.state.can_hot_restart);
    }
}

fn load_config(path: &Path) -> Option<PersistedUiDevelopment> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.file_type().is_file() {
        return None;
    }
    let mut bytes = Vec::with_capacity(4096);
    fs::File::open(path)
        .ok()?
        .take((MAX_CONFIG_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_CONFIG_BYTES {
        return None;
    }
    let configuration: PersistedUiDevelopment = serde_json::from_slice(&bytes).ok()?;
    (configuration.schema_version == CONFIG_SCHEMA_VERSION).then_some(configuration)
}

fn save_config(path: &Path, configuration: &PersistedUiDevelopment) -> Result<(), Box<dyn Error>> {
    let parent = path
        .parent()
        .ok_or("UI development config has no parent directory")?;
    fs::create_dir_all(parent)?;
    if fs::symlink_metadata(parent)?.file_type().is_symlink() {
        return Err("UI development config directory is a symlink".into());
    }
    if fs::symlink_metadata(path)
        .ok()
        .is_some_and(|metadata| !metadata.file_type().is_file())
    {
        return Err("UI development config target is not a regular file".into());
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("UI development config file name is not valid UTF-8")?;
    let sequence = CONFIG_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".{file_name}.{}.{}.tmp",
        std::process::id(),
        sequence
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let write_result = (|| -> Result<(), Box<dyn Error>> {
        serde_json::to_writer_pretty(&mut file, configuration)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

fn save_vm_service_info(path: &Path, uri: &str) -> Result<(), Box<dyn Error>> {
    if uri.len() > 2048 || uri.contains('\0') || uri.contains('\n') {
        return Err("VM service URI is malformed".into());
    }
    let parent = path
        .parent()
        .ok_or("VM service endpoint has no parent directory")?;
    fs::create_dir_all(parent)?;
    if fs::symlink_metadata(parent)?.file_type().is_symlink() {
        return Err("VM service endpoint directory is a symlink".into());
    }
    let sequence = CONFIG_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".flutter-vm-service.{}.{}.tmp",
        std::process::id(),
        sequence
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let write_result = (|| -> Result<(), Box<dyn Error>> {
        serde_json::to_writer(&mut file, &VmServiceInfo { uri })?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}
