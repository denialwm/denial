use super::*;

fn control_packet(command: u8, request_id: u32, flags: u8, path: &[u8]) -> Vec<u8> {
    let mut packet = vec![0; CONTROL_HEADER_BYTES];
    packet[0] = PROTOCOL_VERSION;
    packet[1] = command;
    packet[2] = flags;
    packet[4..8].copy_from_slice(&request_id.to_le_bytes());
    packet[8..10].copy_from_slice(
        &u16::try_from(path.len())
            .expect("test path fits")
            .to_le_bytes(),
    );
    packet.extend_from_slice(path);
    packet
}

#[test]
fn control_protocol_accepts_a_bounded_absolute_workspace() {
    let decoded =
        decode_control_packet(&control_packet(3, 42, 0, b"/home/example/denial-ui")).unwrap();
    assert_eq!(decoded.kind, CommandKind::SetWorkspace);
    assert_eq!(decoded.request_id, 42);
    assert_eq!(
        decoded.workspace.as_deref(),
        Some(Path::new("/home/example/denial-ui"))
    );
}

#[test]
fn control_protocol_rejects_trailing_and_reserved_data() {
    let mut packet = control_packet(0, 1, 0, b"");
    packet.push(0);
    assert!(decode_control_packet(&packet).is_err());

    let mut packet = control_packet(0, 1, 0, b"");
    packet[10] = 1;
    assert!(decode_control_packet(&packet).is_err());
}

#[test]
fn control_protocol_scopes_the_auto_reload_flag() {
    assert!(decode_control_packet(&control_packet(0, 1, 1, b"")).is_err());
    let decoded = decode_control_packet(&control_packet(9, 2, 1, b"")).unwrap();
    assert_eq!(decoded.kind, CommandKind::SetAutoReload);
    assert!(decoded.auto_reload);
}

#[test]
fn vm_service_info_uses_flutters_attach_file_shape() {
    let encoded = serde_json::to_string(&VmServiceInfo {
        uri: "http://127.0.0.1:43125/AUTH=/",
    })
    .unwrap();
    assert_eq!(encoded, r#"{"uri":"http://127.0.0.1:43125/AUTH=/"}"#);
}

#[test]
fn live_runtime_rejects_workspace_replacement() {
    let mut controller = UiDevelopmentController::isolated(Path::new("/packaged/ui"));
    controller.state.active_mode = UiRuntimeMode::LiveDevelopment;
    let effect = controller.handle_command(UiDevelopmentCommand {
        kind: CommandKind::SetWorkspace,
        request_id: 7,
        workspace: Some(PathBuf::from("/home/example/other-ui")),
        auto_reload: false,
    });

    assert_eq!(effect, UiDevelopmentEffect::None);
    assert!(controller.state.workspace.is_empty());
    assert!(controller.state.error.contains("before changing"));
    assert_eq!(controller.state.acknowledged_request_id, 7);
}

#[test]
fn status_query_preserves_a_runtime_recovery_failure() {
    let mut controller = UiDevelopmentController::isolated(Path::new("/packaged/ui"));
    controller.runtime_failed(UiRuntimeMode::LiveDevelopment, &"debug engine failed");
    controller.runtime_started(UiRuntimeMode::OfficialOptimized, 2);
    let error = controller.state.error.clone();
    let status = controller.state.status.clone();

    let query = UiDevelopmentCommand::from_control(CommandKind::Query, 9, None, false).unwrap();
    assert_eq!(controller.handle_command(query), UiDevelopmentEffect::None);
    assert_eq!(controller.state.error, error);
    assert_eq!(controller.state.status, status);
    assert_eq!(controller.state.acknowledged_request_id, 9);
}

#[test]
fn state_protocol_stays_within_the_declared_header() {
    let mut state = UiDevelopmentState {
        active_mode: UiRuntimeMode::OfficialOptimized,
        desired_mode: UiRuntimeMode::LiveDevelopment,
        operation: UiDevelopmentOperation::SwitchingRuntime,
        developer_components_available: true,
        workspace_valid: true,
        auto_reload: true,
        auto_reload_supported: false,
        can_hot_reload: false,
        can_hot_restart: false,
        can_build_optimized: false,
        can_revert: false,
        vm_service_uri: String::new(),
        generation: 7,
        revision: 9,
        acknowledged_request_id: 11,
        workspace: "/tmp/denial-ui".to_owned(),
        status: "Switching".to_owned(),
        error: String::new(),
        diagnostics: Vec::new(),
        progress_basis_points: None,
    };
    let packet = state.packet().unwrap();
    assert_eq!(packet[0], PROTOCOL_VERSION);
    assert_eq!(u64::from_le_bytes(packet[8..16].try_into().unwrap()), 7);
    assert_eq!(u32::from_le_bytes(packet[24..28].try_into().unwrap()), 11);
    assert_eq!(
        usize::from(u16::from_le_bytes([packet[28], packet[29]])),
        "/tmp/denial-ui".len()
    );

    state.workspace = "a".repeat(MAX_WORKSPACE_BYTES + 1);
    assert!(state.packet().is_err());
    state.workspace.clear();
    state.progress_basis_points = Some(10_001);
    assert!(state.packet().is_err());
}
