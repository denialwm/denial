use super::*;

struct TemporaryOutputConfig {
    path: PathBuf,
}

impl TemporaryOutputConfig {
    fn new(contents: &str) -> Self {
        for _ in 0..32 {
            let sequence = OUTPUT_CONFIG_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "denial-output-config-test-{}-{sequence}.conf",
                std::process::id()
            ));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut file) => {
                    file.write_all(contents.as_bytes())
                        .expect("write temporary output config");
                    file.sync_all().expect("sync temporary output config");
                    return Self { path };
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create temporary output config: {error}"),
            }
        }
        panic!("allocate temporary output config name");
    }
}

impl Drop for TemporaryOutputConfig {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn persisted_output(name: &str) -> PersistedOutput {
    PersistedOutput {
        name: name.to_owned(),
        enabled: true,
        x: 32,
        y: -16,
        width: 2560,
        height: 1440,
        refresh_millihz: 199_998,
        scale_120: 150,
        transform: OutputTransform::Rotate90,
        adaptive_sync: true,
    }
}

fn options(arguments: &[&str]) -> Options {
    Options::parse_from(arguments.iter().map(|argument| (*argument).to_owned()))
        .expect("valid deniald options")
}

#[test]
fn flutter_without_a_finite_limit_runs_until_logout() {
    let options = options(&["--wayland", "--flutter-bundle", "/tmp/denial-bundle"]);
    assert_eq!(options.runtime_limit(), RuntimeLimit::UntilLogout);
    assert_eq!(options.render_device, None);
    #[cfg(feature = "flutter")]
    assert_eq!(options.flutter_renderer, RendererBackend::ImpellerGles);
}

#[test]
fn render_device_can_differ_from_the_kms_device() {
    let options = options(&[
        "--device",
        "/dev/dri/card0",
        "--render-device",
        "/dev/dri/renderD128",
    ]);
    assert_eq!(options.device, PathBuf::from("/dev/dri/card0"));
    assert_eq!(
        options.render_device,
        Some(PathBuf::from("/dev/dri/renderD128"))
    );
}

#[test]
#[cfg(feature = "flutter")]
fn flutter_renderers_are_explicit_and_impeller_remains_the_default() {
    for (name, expected) in [
        ("skia", RendererBackend::SkiaGles),
        ("impeller", RendererBackend::ImpellerGles),
    ] {
        let configured = options(&[
            "--wayland",
            "--flutter-bundle",
            "/tmp/denial-bundle",
            "--flutter-renderer",
            name,
        ]);
        assert_eq!(configured.flutter_renderer, expected);
    }

    let missing_bundle = Options::parse_from(
        ["--flutter-renderer", "impeller"]
            .into_iter()
            .map(str::to_owned),
    )
    .expect_err("renderer selection without Flutter must be rejected");
    assert_eq!(
        missing_bundle.to_string(),
        "--flutter-renderer requires --flutter-bundle"
    );

    let unknown = Options::parse_from(
        [
            "--wayland",
            "--flutter-bundle",
            "/tmp/denial-bundle",
            "--flutter-renderer",
            "ganesh-but-spelled-wrong",
        ]
        .into_iter()
        .map(str::to_owned),
    )
    .expect_err("unknown renderer must be rejected");
    assert_eq!(
        unknown.to_string(),
        "unknown Flutter renderer \"ganesh-but-spelled-wrong\"; expected skia or impeller"
    );
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
fn live_ui_paths_are_explicit_and_require_the_packaged_bundle() {
    let configured = options(&[
        "--wayland",
        "--flutter-bundle",
        "/tmp/denial-release",
        "--flutter-debug-bundle",
        "/tmp/denial-debug",
        "--flutter-ui-workspace",
        "/home/example/denial-ui",
    ]);
    assert_eq!(
        configured.flutter_debug_bundle.as_deref(),
        Some(Path::new("/tmp/denial-debug"))
    );
    assert_eq!(
        configured.flutter_ui_workspace.as_deref(),
        Some(Path::new("/home/example/denial-ui"))
    );

    let error = Options::parse_from(
        ["--flutter-debug-bundle", "/tmp/denial-debug"]
            .into_iter()
            .map(str::to_owned),
    )
    .expect_err("a debug bundle without the recovery bundle must be rejected");
    assert_eq!(
        error.to_string(),
        "--flutter-debug-bundle and --flutter-ui-workspace require --flutter-bundle"
    );
}

#[test]
fn flutter_offscreen_blit_is_explicit_and_requires_flutter() {
    let direct = options(&["--wayland", "--flutter-bundle", "/tmp/denial-bundle"]);
    let blit = options(&[
        "--wayland",
        "--flutter-bundle",
        "/tmp/denial-bundle",
        "--flutter-offscreen-blit",
    ]);
    let error = Options::parse_from(["--flutter-offscreen-blit"].into_iter().map(str::to_owned))
        .expect_err("offscreen blit without Flutter must be rejected");

    assert!(!direct.flutter_offscreen_blit);
    assert!(blit.flutter_offscreen_blit);
    assert_eq!(
        error.to_string(),
        "--flutter-offscreen-blit requires --flutter-bundle"
    );
}

#[test]
fn startup_lock_is_explicit_and_requires_flutter() {
    let unlocked = options(&["--wayland", "--flutter-bundle", "/tmp/denial-bundle"]);
    let locked = options(&[
        "--wayland",
        "--flutter-bundle",
        "/tmp/denial-bundle",
        "--start-locked",
    ]);
    let error = Options::parse_from(["--start-locked"].into_iter().map(str::to_owned))
        .expect_err("a startup lock without an unlock UI must be rejected");

    assert!(!unlocked.start_locked);
    assert!(locked.start_locked);
    assert_eq!(
        error.to_string(),
        "--start-locked requires --flutter-bundle"
    );
}

#[test]
fn no_flutter_and_no_limit_remains_test_only() {
    assert_eq!(options(&[]).runtime_limit(), RuntimeLimit::TestOnly);
}

#[test]
fn version_is_a_terminal_command() {
    assert_eq!(options(&["--version"]).max_outputs, 0);
    assert_eq!(options(&["-V"]).max_outputs, 0);
}

#[test]
fn output_config_accepts_positions_and_optional_refresh_rates() {
    let config = parse_output_config(
        "# physical desk profile\nDP-5 = 0, 0, 200\nDP-4=2560,-120 # raised display\nvrr=DP-4\ndisabled=HDMI-A-1\n",
    )
    .expect("valid output config");

    assert_eq!(config.positions.len(), 2);
    assert_eq!(config.positions["DP-5"], LogicalPoint::new(0, 0));
    assert_eq!(config.positions["DP-4"], LogicalPoint::new(2560, -120));
    assert_eq!(config.refresh_millihz["DP-5"], 200_000);
    assert!(!config.refresh_millihz.contains_key("DP-4"));
    assert_eq!(config.vrr_outputs, BTreeSet::from(["DP-4".to_owned()]));
    assert_eq!(
        config.disabled_outputs,
        BTreeSet::from(["HDMI-A-1".to_owned()])
    );
}

#[test]
fn output_config_accepts_exact_modes_and_fractional_scales() {
    let config = parse_output_config(
        "DP-5=0,0\nmode=DP-5,2560,1440,199998\nscale=DP-5,1.25\ntransform=DP-5,90\nmode=DP-4,1920,1080,60\n",
    )
    .expect("valid exact output config");

    assert_eq!(config.mode_sizes["DP-5"], (2560, 1440));
    assert_eq!(config.refresh_millihz["DP-5"], 199_998);
    assert_eq!(config.scales_120["DP-5"], 150);
    assert_eq!(config.transforms["DP-5"], OutputTransform::Rotate90);
    assert_eq!(config.refresh_millihz["DP-4"], 60_000);
}

#[test]
fn output_config_accepts_every_wayland_transform_and_rejects_duplicates() {
    let config = parse_output_config(
        "transform=A,normal\ntransform=B,90\ntransform=C,180\ntransform=D,270\ntransform=E,flipped\ntransform=F,flipped-90\ntransform=G,flipped-180\ntransform=H,flipped-270\n",
    )
    .expect("valid output transforms");

    assert_eq!(config.transforms["A"], OutputTransform::Normal);
    assert_eq!(config.transforms["B"], OutputTransform::Rotate90);
    assert_eq!(config.transforms["C"], OutputTransform::Rotate180);
    assert_eq!(config.transforms["D"], OutputTransform::Rotate270);
    assert_eq!(config.transforms["E"], OutputTransform::Flipped);
    assert_eq!(config.transforms["F"], OutputTransform::Flipped90);
    assert_eq!(config.transforms["G"], OutputTransform::Flipped180);
    assert_eq!(config.transforms["H"], OutputTransform::Flipped270);

    let duplicate = parse_output_config("transform=DP-1,90\ntransform=DP-1,180\n")
        .expect_err("duplicate transform must fail");
    assert!(duplicate.contains("duplicate transform for output DP-1"));
    let invalid =
        parse_output_config("transform=DP-1,left\n").expect_err("unknown transform must fail");
    assert!(invalid.contains("output transform must use"));
}

#[test]
fn persistent_render_replaces_connected_outputs_and_preserves_other_settings() {
    let original = "\
# hand tuned
DP-5=0,0,200
mode=DP-5,1920,1080,200000
scale=DP-5,1
disabled=DP-5
HDMI-A-1=3840,0
mode=HDMI-A-1,1920,1080,60000
scale=HDMI-A-1,1.5
system_bar=top,36,DP-5
maximize_padding=14
";
    let rendered = render_persisted_output_config(original, &[persisted_output("DP-5")])
        .expect("render persistent output config");
    let parsed = parse_output_config(&rendered).expect("generated config parses");

    assert!(rendered.contains("# hand tuned"));
    assert!(rendered.contains("HDMI-A-1=3840,0"));
    assert!(rendered.contains("mode=HDMI-A-1,1920,1080,60000"));
    assert!(rendered.contains("system_bar=top,36,DP-5"));
    assert!(rendered.contains("maximize_padding=14"));
    assert!(rendered.contains(MANAGED_OUTPUT_CONFIG_HEADER));
    assert_eq!(parsed.positions["DP-5"], LogicalPoint::new(32, -16));
    assert_eq!(parsed.mode_sizes["DP-5"], (2560, 1440));
    assert_eq!(parsed.refresh_millihz["DP-5"], 199_998);
    assert_eq!(parsed.scales_120["DP-5"], 150);
    assert_eq!(parsed.transforms["DP-5"], OutputTransform::Rotate90);
    assert!(parsed.vrr_outputs.contains("DP-5"));
    assert!(!parsed.disabled_outputs.contains("DP-5"));
    assert_eq!(
        rendered
            .lines()
            .filter(|line| output_directive_name(line) == Some("DP-5"))
            .count(),
        5
    );
}

#[test]
fn persistent_output_config_is_prepared_then_atomically_committed() {
    let config =
        TemporaryOutputConfig::new("# keep this comment\nDP-5=0,0,200\nsystem_bar=hidden\n");
    fs::set_permissions(&config.path, fs::Permissions::from_mode(0o640))
        .expect("set original permissions");
    let before = fs::read_to_string(&config.path).expect("read original config");

    let prepared = prepare_output_config_persistence(&config.path, &[persisted_output("DP-5")])
        .expect("prepare persistent config");
    assert_eq!(
        fs::read_to_string(&config.path).expect("target remains readable"),
        before,
        "preparation must not expose the new config"
    );

    prepared.commit().expect("commit persistent config");
    let updated = fs::read_to_string(&config.path).expect("read committed config");
    let parsed = parse_output_config(&updated).expect("committed config parses");
    assert_eq!(parsed.mode_sizes["DP-5"], (2560, 1440));
    assert_eq!(
        fs::metadata(&config.path)
            .expect("read committed metadata")
            .permissions()
            .mode()
            & 0o777,
        0o640
    );
}

#[test]
fn persistent_commit_refuses_a_concurrent_edit() {
    let config = TemporaryOutputConfig::new("DP-5=0,0,200\n");
    let prepared = prepare_output_config_persistence(&config.path, &[persisted_output("DP-5")])
        .expect("prepare persistent config");
    fs::write(&config.path, "DP-5=99,77,60\n").expect("simulate concurrent edit");

    let error = prepared
        .commit()
        .expect_err("concurrent edit must block replacement");
    assert!(error.contains("was edited"));
    assert_eq!(
        fs::read_to_string(&config.path).expect("read concurrent edit"),
        "DP-5=99,77,60\n"
    );
}

#[test]
fn persistent_prepare_refuses_a_symlink_target() {
    use std::os::unix::fs::symlink;

    let target = TemporaryOutputConfig::new("DP-5=0,0,200\n");
    let link = TemporaryOutputConfig::new("");
    fs::remove_file(&link.path).expect("replace temporary file with a symlink");
    symlink(&target.path, &link.path).expect("create output config symlink");

    let error = prepare_output_config_persistence(&link.path, &[persisted_output("DP-5")])
        .expect_err("symlinked config must be rejected");
    assert!(error.contains("refusing to replace symlinked"));
}

#[test]
fn output_config_rejects_invalid_vrr_outputs() {
    let empty = parse_output_config("vrr=\n").expect_err("empty VRR output must fail");
    assert!(empty.contains("VRR output name is empty"));

    let duplicate =
        parse_output_config("vrr=DP-4\nvrr=DP-4\n").expect_err("duplicate VRR output must fail");
    assert!(duplicate.contains("duplicate VRR output DP-4"));
}

#[test]
fn output_config_rejects_invalid_disabled_outputs() {
    let empty = parse_output_config("disabled=\n").expect_err("empty disabled output must fail");
    assert!(empty.contains("disabled output name is empty"));

    let duplicate = parse_output_config("disabled=DP-4\ndisabled=DP-4\n")
        .expect_err("duplicate disabled output must fail");
    assert!(duplicate.contains("duplicate disabled output DP-4"));
}

#[test]
fn system_bar_defaults_to_a_top_bar_on_the_ticker_output() {
    assert_eq!(options(&[]).work_area, WorkAreaOptions::default());
    assert_eq!(SystemBarOptions::default().side, SystemBarSide::Top);
    assert!(SystemBarOptions::default().thickness > 0.0);
    assert!(SystemBarOptions::default().outputs.is_empty());
}

#[test]
fn system_bar_accepts_side_thickness_and_optional_output() {
    let bar = options(&["--system-bar", "bottom,48,DP-3"])
        .work_area
        .system_bar;
    assert_eq!(
        bar,
        SystemBarOptions {
            outputs: vec!["DP-3".to_owned()],
            side: SystemBarSide::Bottom,
            thickness: 48.0,
        }
    );

    let auto = options(&["--system-bar", "top,24,auto"])
        .work_area
        .system_bar;
    assert!(auto.outputs.is_empty());

    let cloned = options(&["--system-bar", "left,40,DP-3+HDMI-A-1"])
        .work_area
        .system_bar;
    assert_eq!(
        cloned.outputs,
        vec!["DP-3".to_owned(), "HDMI-A-1".to_owned()]
    );

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
        "top,32,DP-1+DP-1",
        "top,32,auto+DP-1",
    ] {
        assert!(
            parse_system_bar_spec(spec).is_err(),
            "spec {spec:?} must be rejected"
        );
    }
}

#[test]
fn output_config_carries_the_system_bar_and_command_line_wins() {
    let config = parse_output_config("DP-5=0,0\nsystem_bar = top, 36, DP-5 # reserve the strip\n")
        .expect("valid output config");
    assert_eq!(
        config.system_bar,
        Some(SystemBarOptions {
            outputs: vec!["DP-5".to_owned()],
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
    let error = parse_output_config(&contents).expect_err("too many configured outputs must fail");

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
