use std::error::Error;
use std::ffi::CStr;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

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
        if matches!(kind, CommandKind::SetWorkspace) != workspace.is_some() {
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
}

impl UiDevelopmentState {
    pub(super) fn error_message(&self) -> Option<&str> {
        (!self.error.is_empty()).then_some(&self.error)
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
        Self {
            official_bundle: official_bundle.to_owned(),
            debug_bundle,
            custom_bundle,
            config_path,
            vm_service_path,
            state: UiDevelopmentState {
                active_mode: UiRuntimeMode::OfficialOptimized,
                desired_mode: UiRuntimeMode::OfficialOptimized,
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
                error: String::new(),
                diagnostics: Vec::new(),
                progress_basis_points: None,
            },
        }
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
            CommandKind::EnableLiveDevelopment => self.request_mode(UiRuntimeMode::LiveDevelopment),
            CommandKind::DisableLiveDevelopment | CommandKind::RestoreOfficial => {
                self.request_mode(UiRuntimeMode::OfficialOptimized)
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
                    Ok(()) => self.request_mode(UiRuntimeMode::CustomOptimized),
                    Err(error) => {
                        self.state.can_build_optimized = false;
                        self.reject(error);
                        UiDevelopmentEffect::None
                    }
                }
            }
            CommandKind::RevertLastWorking => {
                self.reject("There is no previous custom optimized UI to restore.");
                UiDevelopmentEffect::None
            }
        };
        self.bump_revision();
        effect
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
        } else if mode == UiRuntimeMode::CustomOptimized {
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
            UiRuntimeMode::CustomOptimized => self.custom_bundle.as_deref(),
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
                "The packaged optimized Flutter shell is active.".to_owned()
            }
            (UiRuntimeMode::CustomOptimized, _) => {
                self.state.error.clear();
                "Optimized AOT profile mode is active.".to_owned()
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
            Self::CustomOptimized => "the optimized AOT profile Flutter shell",
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
