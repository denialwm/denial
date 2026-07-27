#![forbid(unsafe_code)]

use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

const FLUTTER_ENGINE_ABI: &str = "3.44.7.denial1";
const FLUTTER_SDK_VERSION: &str = "3.44.7";
const UI_PACKAGE_NAME: &str = "denial-ui-development";
const UI_DENIAL_MINIMUM_VERSION: &str = "0.2.0";
const UI_DENIAL_VERSION_BEFORE: &str = "0.3.0";
const CANONICAL_TOOLCHAIN_ROOT: &str = "/opt/denial-build/ui-development";
const DENIAL_GIT_REMOTE: &str = "https://github.com/denialwm/denial.git";
const UI_SOURCE_MARKER: &str = ".denial-ui-source.json";
const PUB_CACHE_GENERATION_MARKER: &str = ".denial-generation";
static TEMPORARY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("denial-xtask: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), ToolError> {
    let mut arguments = env::args_os().skip(1);
    match arguments.next().as_deref().and_then(OsStr::to_str) {
        Some("flutter-tool-snapshot") => {
            if arguments.next().is_some() {
                return Err(ToolError::usage(
                    "flutter-tool-snapshot accepts no arguments",
                ));
            }
            let paths = BuildPaths::discover()?;
            validate_host(&paths)?;
            build_flutter_tool_snapshot(&paths)
        }
        Some("ui-development-package") => {
            if arguments.next().is_some() {
                return Err(ToolError::usage(
                    "ui-development-package accepts no arguments",
                ));
            }
            build_ui_development_package()
        }
        Some("help") | Some("-h") | Some("--help") | None => {
            if arguments.next().is_some() {
                return Err(ToolError::usage("help accepts no arguments"));
            }
            print_help();
            Ok(())
        }
        Some(command) => Err(ToolError::usage(format!("unknown command {command:?}"))),
    }
}

fn print_help() {
    println!(
        "\
Usage: cargo xtask COMMAND

Commands:
  flutter-tool-snapshot  Build and verify the packaged Flutter tool snapshot
  ui-development-package  Build and validate denial-ui-development

Environment:
  DENIAL_PC_BUILD_ROOT
  DENIAL_PC_RUST_TARGET
  DENIAL_PC_DEPENDENCY_ROOT
  DENIAL_FLUTTER_SDK_ROOT
  DENIAL_PC_PACKAGE_ROOT
  DENIAL_PC_MAKEPKG_ROOT
  DENIAL_PACKAGE_RELEASE
  DENIAL_PACKAGE_PACKAGER
  DENIAL_RELEASE_TAG"
    );
}

fn build_ui_development_package() -> Result<(), ToolError> {
    let paths = BuildPaths::discover()?;
    validate_host(&paths)?;
    let identity = PackageIdentity::resolve(&paths.repository)?;

    fs::create_dir_all(&paths.rust_target).map_err(ToolError::io)?;
    fs::create_dir_all(&paths.package_root).map_err(ToolError::io)?;
    fs::create_dir_all(&paths.makepkg_root).map_err(ToolError::io)?;

    build_development_client(&paths)?;
    build_flutter_tool_snapshot(&paths)?;
    resolve_ui_dependencies(&paths)?;
    build_flutter_tool_runtime(&paths)?;
    build_flutter_sdk_runtime(&paths)?;
    build_ui_workspace_template(&paths, &identity)?;
    validate_package_inputs(&paths)?;

    let mut package_list = makepkg_command(&paths, &identity);
    package_list.arg("--packagelist");
    let package_output = checked_output(
        &mut package_list,
        "could not determine the UI development package path",
    )?;
    let package = one_output_path(&package_output, &paths.package_directory)?;

    let mut makepkg = makepkg_command(&paths, &identity);
    makepkg.args([
        "--force",
        "--cleanbuild",
        "--clean",
        "--nodeps",
        "--noconfirm",
    ]);
    checked_status(&mut makepkg, "UI development package build failed")?;

    validate_package(&paths, &identity, &package)?;
    let archive_sha256 = sha256(&package)?;
    let size = fs::metadata(&package).map_err(ToolError::io)?.len();
    const MAX_PACKAGE_BYTES: u64 = 160 * 1024 * 1024;
    if size > MAX_PACKAGE_BYTES {
        return Err(ToolError::new(format!(
            "development package is {}, above the {} archive size budget",
            human_size(size),
            human_size(MAX_PACKAGE_BYTES)
        )));
    }
    println!(
        "\nValidated Arch package:\n  {}\n  size: {}\n  sha256: {}",
        package.display(),
        human_size(size),
        archive_sha256
    );
    Ok(())
}

#[derive(Debug)]
struct BuildPaths {
    repository: PathBuf,
    compositor: PathBuf,
    package_directory: PathBuf,
    package_root: PathBuf,
    makepkg_root: PathBuf,
    build_root: PathBuf,
    rust_target: PathBuf,
    development_binary: PathBuf,
    flutter_sdk: PathBuf,
    pub_cache: PathBuf,
    flutter_tool_snapshot: PathBuf,
    flutter_tool_runtime: PathBuf,
    flutter_sdk_runtime: PathBuf,
    ui_workspace_template: PathBuf,
    flutter_tool_checksum: PathBuf,
    debug_engine: PathBuf,
    debug_engine_checksum: PathBuf,
}

impl BuildPaths {
    fn discover() -> Result<Self, ToolError> {
        let manifest_directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let repository = manifest_directory
            .parent()
            .and_then(Path::parent)
            .ok_or_else(|| ToolError::new("xtask is not below the repository root"))?
            .to_path_buf();
        let repository = fs::canonicalize(repository).map_err(ToolError::io)?;
        let xdg_cache_home = absolute_environment_path("XDG_CACHE_HOME")?;
        let home = absolute_environment_path("HOME")?;
        let cache_home = xdg_cache_home
            .or_else(|| home.as_ref().map(|path| path.join(".cache")))
            .ok_or_else(|| ToolError::new("HOME or an absolute XDG_CACHE_HOME is required"))?;
        let build_root = absolute_environment_path("DENIAL_PC_BUILD_ROOT")?
            .unwrap_or_else(|| cache_home.join("denial/pc-build"));
        let dependency_root = absolute_environment_path("DENIAL_PC_DEPENDENCY_ROOT")?
            .unwrap_or_else(|| cache_home.join("denial/pc-dependencies"));
        let rust_target = absolute_environment_path("DENIAL_PC_RUST_TARGET")?
            .unwrap_or_else(|| build_root.join("rust"));
        let package_root = absolute_environment_path("DENIAL_PC_PACKAGE_ROOT")?
            .unwrap_or_else(|| build_root.join("packages"));
        let makepkg_root = absolute_environment_path("DENIAL_PC_MAKEPKG_ROOT")?
            .unwrap_or_else(|| build_root.join("makepkg"));
        let flutter_sdk = absolute_environment_path("DENIAL_FLUTTER_SDK_ROOT")?
            .unwrap_or_else(|| dependency_root.join("flutter"));
        let pub_cache = absolute_environment_path("PUB_CACHE")?
            .or_else(|| home.map(|path| path.join(".pub-cache")))
            .ok_or_else(|| ToolError::new("HOME or an absolute PUB_CACHE is required"))?;
        let development_binary = absolute_environment_path("DENIAL_PACKAGE_UI_BINARY")?
            .unwrap_or_else(|| rust_target.join("release/denial-ui"));
        let flutter_tool_snapshot =
            build_root.join("ui-development/flutter-tools/flutter_tools.snapshot");
        let flutter_tool_runtime = build_root.join("ui-development/flutter-tools/runtime");
        let flutter_sdk_runtime = build_root.join("ui-development/flutter-sdk-runtime");
        let ui_workspace_template = build_root.join("ui-development/workspace-template");
        let debug_engine = absolute_environment_path("DENIAL_PACKAGE_DEBUG_ENGINE_SOURCE")?
            .unwrap_or_else(|| {
                repository.join("prebuilt/flutter-engine/linux-x64-debug/libflutter_engine.so")
            });

        Ok(Self {
            compositor: repository.join("compositor"),
            package_directory: repository.join("packaging/arch/ui-development"),
            package_root,
            makepkg_root,
            build_root,
            rust_target,
            development_binary,
            flutter_sdk,
            pub_cache,
            flutter_tool_snapshot,
            flutter_tool_runtime,
            flutter_sdk_runtime,
            ui_workspace_template,
            flutter_tool_checksum: repository
                .join("prebuilt/flutter-tools/3.44.7/flutter_tools.snapshot.sha256"),
            debug_engine,
            debug_engine_checksum: repository
                .join("prebuilt/flutter-engine/linux-x64-debug/libflutter_engine.so.sha256"),
            repository,
        })
    }
}

#[derive(Debug)]
struct PackageIdentity {
    version: String,
    release: String,
    source_date_epoch: String,
    source_ref: String,
}

impl PackageIdentity {
    fn resolve(repository: &Path) -> Result<Self, ToolError> {
        let base_version = cargo_package_version(&repository.join("compositor/Cargo.toml"))?;
        let release = env::var("DENIAL_PACKAGE_RELEASE").unwrap_or_else(|_| String::from("1"));
        if release.is_empty() || !release.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(ToolError::new(
                "DENIAL_PACKAGE_RELEASE must contain only decimal digits",
            ));
        }

        let source_date_epoch = git_output(repository, &["log", "-1", "--format=%ct"])?;
        if source_date_epoch.is_empty()
            || !source_date_epoch.bytes().all(|byte| byte.is_ascii_digit())
        {
            return Err(ToolError::new(
                "could not derive SOURCE_DATE_EPOCH from the current commit",
            ));
        }

        if let Ok(tag) = env::var("DENIAL_RELEASE_TAG")
            && !tag.is_empty()
        {
            validate_release_tag(&tag)?;
            let head = git_output(repository, &["rev-parse", "HEAD"])?;
            let tagged = git_output(repository, &["rev-parse", &format!("{tag}^{{commit}}")])?;
            if head != tagged {
                return Err(ToolError::new(format!(
                    "release tag {tag} does not identify HEAD"
                )));
            }
            if !git_output(
                repository,
                &["status", "--porcelain", "--untracked-files=normal"],
            )?
            .is_empty()
            {
                return Err(ToolError::new(
                    "a tagged release must be built from a clean checkout",
                ));
            }
            let version = tag
                .strip_prefix('v')
                .ok_or_else(|| ToolError::new("release tag must begin with v"))?;
            if version != base_version {
                return Err(ToolError::new(format!(
                    "release tag {tag} does not match Cargo version {base_version}"
                )));
            }
            if release != "1" {
                return Err(ToolError::new(
                    "a tagged release must use package release 1",
                ));
            }
            return Ok(Self {
                version: version.to_owned(),
                release,
                source_date_epoch,
                source_ref: tag,
            });
        }

        let source_ref = git_output(repository, &["branch", "--show-current"])?;
        validate_source_ref(&source_ref)?;
        let revision_count = git_output(repository, &["rev-list", "--count", "HEAD"])?;
        let revision = git_output(repository, &["rev-parse", "--short=8", "HEAD"])?;
        let dirty = !git_output(
            repository,
            &["status", "--porcelain", "--untracked-files=normal"],
        )?
        .is_empty();
        let mut version = format!("{base_version}.r{revision_count}.g{revision}");
        if dirty {
            version.push_str(".dirty");
        }
        Ok(Self {
            version,
            release,
            source_date_epoch,
            source_ref,
        })
    }
}

fn build_development_client(paths: &BuildPaths) -> Result<(), ToolError> {
    let jobs = std::thread::available_parallelism()
        .map(usize::from)
        .unwrap_or(1)
        .to_string();
    let rustflags = package_rustflags(&paths.repository)?;
    let mut cargo = Command::new("cargo");
    cargo
        .current_dir(&paths.compositor)
        .env("CARGO_TARGET_DIR", &paths.rust_target)
        .env("CARGO_INCREMENTAL", "0")
        .env("CARGO_PROFILE_RELEASE_STRIP", "symbols")
        .env_remove("RUSTFLAGS")
        .env("CARGO_ENCODED_RUSTFLAGS", rustflags)
        .args([
            "build",
            "--locked",
            "--release",
            "--jobs",
            &jobs,
            "--features",
            "ui-development",
            "--bin",
            "denial-ui",
        ]);
    checked_status(&mut cargo, "could not build denial-ui")?;
    require_executable(&paths.development_binary)
}

fn build_flutter_tool_snapshot(paths: &BuildPaths) -> Result<(), ToolError> {
    let source_config = paths
        .flutter_sdk
        .join("packages/flutter_tools/.dart_tool/package_config.json");
    let source_script = paths
        .flutter_sdk
        .join("packages/flutter_tools/bin/flutter_tools.dart");
    let dart_sdk = paths.flutter_sdk.join("bin/cache/dart-sdk");
    let dartaotruntime = dart_sdk.join("bin/dartaotruntime");
    let gen_kernel = dart_sdk.join("bin/snapshots/gen_kernel_aot.dart.snapshot");
    let platform = dart_sdk.join("lib/_internal/vm_platform_product.dill");
    let gen_snapshot = dart_sdk.join("bin/utils/gen_snapshot");
    for required in [&source_config, &source_script, &gen_kernel, &platform] {
        require_regular_file(required)?;
    }
    for executable in [&dartaotruntime, &gen_snapshot] {
        require_executable(executable)?;
    }
    if !paths.pub_cache.is_dir() {
        return Err(ToolError::new(format!(
            "Dart package cache is missing: {}",
            paths.pub_cache.display()
        )));
    }

    let output_root = paths.build_root.join("ui-development/flutter-tools");
    fs::create_dir_all(&output_root).map_err(ToolError::io)?;
    let diagnostic_root = output_root.join("snapshot-failure");
    if let Err(error) = fs::remove_dir_all(&diagnostic_root)
        && error.kind() != io::ErrorKind::NotFound
    {
        return Err(ToolError::io(error));
    }
    let temporary = TemporaryDirectory::create(&output_root, "snapshot")?;
    let package_config = temporary.path().join("package_config.json");
    write_canonical_package_config(&source_config, &package_config)?;

    let canonical_flutter = format!("{CANONICAL_TOOLCHAIN_ROOT}/flutter");
    let canonical_dart_sdk = format!("{canonical_flutter}/bin/cache/dart-sdk");
    let canonical_dartaotruntime = format!("{canonical_dart_sdk}/bin/dartaotruntime");
    let canonical_gen_kernel =
        format!("{canonical_dart_sdk}/bin/snapshots/gen_kernel_aot.dart.snapshot");
    let canonical_platform = format!("{canonical_dart_sdk}/lib/_internal/vm_platform_product.dill");
    let canonical_gen_snapshot = format!("{canonical_dart_sdk}/bin/utils/gen_snapshot");
    let canonical_script =
        format!("{canonical_flutter}/packages/flutter_tools/bin/flutter_tools.dart");
    let kernel_argument = "--output=/tmp/output/flutter_tools.dill";
    let packages_argument = "--packages=/tmp/output/package_config.json";

    let mut compile = flutter_tool_build_sandbox(paths, temporary.path());
    compile
        .args([
            &canonical_dartaotruntime,
            &canonical_gen_kernel,
            &format!("--platform={canonical_platform}"),
            "-Ddart.vm.product=true",
            "-Ddart.vm.asan=false",
            "-Ddart.vm.msan=false",
            "-Ddart.vm.tsan=false",
            "--target-os=linux",
            "--aot",
            "--no-embed-sources",
            kernel_argument,
            "--invocation-modes=compile",
            "--verbosity=error",
            packages_argument,
            &canonical_script,
        ])
        .stdout(Stdio::null());
    checked_status(
        &mut compile,
        "could not compile the canonical Flutter tool kernel",
    )?;

    let kernel = temporary.path().join("flutter_tools.dill");
    require_regular_file(&kernel)?;
    let mut snapshot = flutter_tool_build_sandbox(paths, temporary.path());
    snapshot
        .args([
            &canonical_gen_snapshot,
            "--deterministic",
            "--remove-script-timestamps-for-test",
            "--target-unknown-cpu",
            "--snapshot-kind=app-aot-elf",
            "--elf=/tmp/output/flutter_tools.snapshot",
            "/tmp/output/flutter_tools.dill",
        ])
        .stdout(Stdio::null());
    checked_status(
        &mut snapshot,
        "could not build the canonical Flutter tool AOT snapshot",
    )?;

    let generated = temporary.path().join("flutter_tools.snapshot");
    require_regular_file(&generated)?;
    require_x86_64_aot_elf(&generated)?;
    fs::set_permissions(&generated, fs::Permissions::from_mode(0o644)).map_err(ToolError::io)?;
    let expected = checksum_record(&paths.flutter_tool_checksum)?;
    let actual = sha256(&generated)?;
    let canonical_package_config_sha256 = sha256(&package_config)?;
    if actual != expected {
        fs::create_dir_all(&diagnostic_root).map_err(ToolError::io)?;
        let candidate = diagnostic_root.join("flutter_tools.snapshot");
        fs::copy(&generated, &candidate).map_err(ToolError::io)?;
        fs::set_permissions(&candidate, fs::Permissions::from_mode(0o644))
            .map_err(ToolError::io)?;
        let diagnostic_config = diagnostic_root.join("package_config.json");
        fs::copy(&package_config, &diagnostic_config).map_err(ToolError::io)?;
        fs::set_permissions(&diagnostic_config, fs::Permissions::from_mode(0o644))
            .map_err(ToolError::io)?;
        let inputs = format!(
            "\
expected_snapshot_sha256={expected}
generated_snapshot_sha256={actual}
dartaotruntime_sha256={}
flutter_tools_entrypoint_sha256={}
source_package_config_sha256={}
canonical_package_config_sha256={}
gen_kernel_aot_sha256={}
vm_platform_product_sha256={}
gen_snapshot_sha256={}
snapshot_kind=app-aot-elf
target_cpu=generic-x64
",
            sha256(&dartaotruntime)?,
            sha256(&source_script)?,
            sha256(&source_config)?,
            canonical_package_config_sha256,
            sha256(&gen_kernel)?,
            sha256(&platform)?,
            sha256(&gen_snapshot)?,
        );
        let diagnostic_inputs = diagnostic_root.join("inputs.txt");
        fs::write(&diagnostic_inputs, inputs).map_err(ToolError::io)?;
        fs::set_permissions(&diagnostic_inputs, fs::Permissions::from_mode(0o644))
            .map_err(ToolError::io)?;
        return Err(ToolError::new(format!(
            "canonical Flutter tool snapshot SHA-256 is {actual}, expected {expected}; preserved failure diagnostics at {}",
            diagnostic_root.display()
        )));
    }
    fs::rename(&generated, &paths.flutter_tool_snapshot).map_err(ToolError::io)?;
    println!(
        "Built canonical Flutter tool snapshot (sha256 {:.12}..., package config {:.12}...)",
        actual, canonical_package_config_sha256
    );
    Ok(())
}

fn flutter_tool_build_sandbox(paths: &BuildPaths, output: &Path) -> Command {
    let canonical_flutter = format!("{CANONICAL_TOOLCHAIN_ROOT}/flutter");
    let canonical_pub_cache = format!("{CANONICAL_TOOLCHAIN_ROOT}/pub-cache");
    let mut bwrap = Command::new("bwrap");
    bwrap
        .args([
            "--die-with-parent",
            "--unshare-user",
            "--unshare-pid",
            "--unshare-net",
            "--unshare-ipc",
            "--unshare-uts",
            "--unshare-cgroup-try",
            "--new-session",
            "--clearenv",
            "--ro-bind",
            "/",
            "/",
            "--tmpfs",
            "/opt",
            "--tmpfs",
            "/tmp",
            "--dir",
            "/tmp/home",
            "--dir",
            "/opt/denial-build",
            "--dir",
            CANONICAL_TOOLCHAIN_ROOT,
            "--ro-bind",
        ])
        .arg(&paths.flutter_sdk)
        .arg(&canonical_flutter)
        .arg("--ro-bind")
        .arg(&paths.pub_cache)
        .arg(&canonical_pub_cache)
        .arg("--bind")
        .arg(output)
        .arg("/tmp/output")
        .args([
            "--chdir",
            "/tmp",
            "--setenv",
            "HOME",
            "/tmp/home",
            "--setenv",
            "XDG_CACHE_HOME",
            "/tmp/home/.cache",
            "--setenv",
            "XDG_CONFIG_HOME",
            "/tmp/home/.config",
            "--setenv",
            "XDG_DATA_HOME",
            "/tmp/home/.local/share",
            "--setenv",
            "XDG_STATE_HOME",
            "/tmp/home/.local/state",
            "--setenv",
            "PATH",
            "/usr/local/bin:/usr/bin",
            "--setenv",
            "LANG",
            "C",
            "--setenv",
            "LC_ALL",
            "C",
            "--setenv",
            "TZ",
            "UTC",
            "--setenv",
            "CI",
            "true",
            "--setenv",
            "SOURCE_DATE_EPOCH",
            "0",
            "--setenv",
            "TMPDIR",
            "/tmp",
            "--setenv",
            "GIT_CONFIG_NOSYSTEM",
            "1",
            "--setenv",
            "GIT_CONFIG_GLOBAL",
            "/dev/null",
            "--setenv",
            "PUB_CACHE",
            &canonical_pub_cache,
            "--setenv",
            "DART_SUPPRESS_ANALYTICS",
            "true",
            "--setenv",
            "FLUTTER_ALREADY_LOCKED",
            "true",
            "--setenv",
            "FLUTTER_SUPPRESS_ANALYTICS",
            "true",
        ]);
    bwrap
}

fn write_canonical_package_config(source: &Path, destination: &Path) -> Result<(), ToolError> {
    let mut document: Value =
        serde_json::from_reader(File::open(source).map_err(ToolError::io)?)
            .map_err(|error| ToolError::new(format!("invalid Flutter package config: {error}")))?;
    let object = document
        .as_object_mut()
        .ok_or_else(|| ToolError::new("Flutter package config is not an object"))?;
    let original_pub_cache = object
        .get("pubCache")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::new("Flutter package config has no pubCache URI"))?
        .to_owned();
    if !original_pub_cache.starts_with("file:///") {
        return Err(ToolError::new(
            "Flutter package config pubCache is not an absolute file URI",
        ));
    }
    let canonical_pub_cache = format!("file://{CANONICAL_TOOLCHAIN_ROOT}/pub-cache");
    let canonical_flutter_tools =
        format!("file://{CANONICAL_TOOLCHAIN_ROOT}/flutter/packages/flutter_tools");
    let packages = object
        .get_mut("packages")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| ToolError::new("Flutter package config has no package list"))?;
    for package in packages {
        let package = package
            .as_object_mut()
            .ok_or_else(|| ToolError::new("Flutter package entry is not an object"))?;
        let root = package
            .get("rootUri")
            .and_then(Value::as_str)
            .ok_or_else(|| ToolError::new("Flutter package entry has no rootUri"))?
            .to_owned();
        let canonical = if root == "../" {
            canonical_flutter_tools.clone()
        } else if let Some(suffix) = root.strip_prefix(&original_pub_cache) {
            if !suffix.is_empty() && !suffix.starts_with('/') {
                return Err(ToolError::new(format!(
                    "package root is outside the pinned pub cache: {root}"
                )));
            }
            format!("{canonical_pub_cache}{suffix}")
        } else {
            return Err(ToolError::new(format!(
                "unexpected Flutter tool package root: {root}"
            )));
        };
        package.insert(String::from("rootUri"), Value::String(canonical));
    }
    object.insert(String::from("pubCache"), Value::String(canonical_pub_cache));
    object.insert(
        String::from("flutterRoot"),
        Value::String(format!("file://{CANONICAL_TOOLCHAIN_ROOT}/flutter")),
    );
    object.insert(
        String::from("flutterVersion"),
        Value::String(String::from(FLUTTER_SDK_VERSION)),
    );

    let mut file = File::create(destination).map_err(ToolError::io)?;
    serde_json::to_writer_pretty(&mut file, &document)
        .map_err(|error| ToolError::new(format!("could not write package config: {error}")))?;
    use std::io::Write;
    file.write_all(b"\n").map_err(ToolError::io)?;
    file.sync_all().map_err(ToolError::io)
}

fn resolve_ui_dependencies(paths: &BuildPaths) -> Result<(), ToolError> {
    let flutter = paths.flutter_sdk.join("bin/flutter");
    require_executable(&flutter)?;
    let mut command = Command::new(flutter);
    command
        .current_dir(paths.repository.join("dart_shell"))
        .env("PUB_CACHE", &paths.pub_cache)
        .env("DART_SUPPRESS_ANALYTICS", "true")
        .env("FLUTTER_ALREADY_LOCKED", "true")
        .env("FLUTTER_SUPPRESS_ANALYTICS", "true")
        .args([
            "--suppress-analytics",
            "--no-version-check",
            "pub",
            "get",
            "--offline",
        ]);
    checked_status(
        &mut command,
        "could not resolve the locked Denial UI dependencies offline",
    )
}

fn build_flutter_tool_runtime(paths: &BuildPaths) -> Result<(), ToolError> {
    let source_config = paths
        .flutter_sdk
        .join("packages/flutter_tools/.dart_tool/package_config.json");
    let mut document: Value =
        serde_json::from_reader(File::open(&source_config).map_err(ToolError::io)?)
            .map_err(|error| ToolError::new(format!("invalid Flutter package config: {error}")))?;
    let object = document
        .as_object_mut()
        .ok_or_else(|| ToolError::new("Flutter package config is not an object"))?;
    let original_pub_cache = object
        .get("pubCache")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::new("Flutter package config has no pubCache URI"))?
        .to_owned();
    if !original_pub_cache.starts_with("file:///") {
        return Err(ToolError::new(
            "Flutter package config pubCache is not an absolute file URI",
        ));
    }

    let output_parent = paths
        .flutter_tool_runtime
        .parent()
        .ok_or_else(|| ToolError::new("Flutter tool runtime has no parent directory"))?;
    let temporary = TemporaryDirectory::create(output_parent, "runtime")?;
    let packaged_pub_cache = temporary.path().join("pub-cache");
    fs::create_dir_all(&packaged_pub_cache).map_err(ToolError::io)?;

    let packages = object
        .get_mut("packages")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| ToolError::new("Flutter package config has no package list"))?;
    let canonical_pub_cache = fs::canonicalize(&paths.pub_cache).map_err(ToolError::io)?;
    let mut dependency_count = 0_usize;
    for package in packages {
        let package = package
            .as_object_mut()
            .ok_or_else(|| ToolError::new("Flutter package entry is not an object"))?;
        let root = package
            .get("rootUri")
            .and_then(Value::as_str)
            .ok_or_else(|| ToolError::new("Flutter package entry has no rootUri"))?
            .to_owned();
        if root == "../" {
            continue;
        }
        let suffix = root.strip_prefix(&original_pub_cache).ok_or_else(|| {
            ToolError::new(format!("unexpected Flutter tool package root: {root}"))
        })?;
        let relative = safe_uri_suffix(suffix)?;
        let source = fs::canonicalize(paths.pub_cache.join(&relative)).map_err(ToolError::io)?;
        if !source.starts_with(&canonical_pub_cache) {
            return Err(ToolError::new(format!(
                "Flutter tool dependency escapes the pinned Pub cache: {}",
                source.display()
            )));
        }
        copy_package_metadata(&source, &packaged_pub_cache.join(&relative))?;

        let relative_uri = relative
            .to_str()
            .ok_or_else(|| ToolError::new("Flutter tool dependency path is not valid UTF-8"))?;
        package.insert(
            String::from("rootUri"),
            Value::String(format!("../../../../pub-cache/{relative_uri}")),
        );
        dependency_count += 1;
    }
    let ui_dependency_count = copy_ui_dependency_sources(paths, &packaged_pub_cache)?;
    fs::write(
        packaged_pub_cache.join(PUB_CACHE_GENERATION_MARKER),
        format!("{FLUTTER_ENGINE_ABI}\n"),
    )
    .map_err(ToolError::io)?;
    fs::set_permissions(
        packaged_pub_cache.join(PUB_CACHE_GENERATION_MARKER),
        fs::Permissions::from_mode(0o644),
    )
    .map_err(ToolError::io)?;
    object.insert(
        String::from("pubCache"),
        Value::String(String::from("../../../../pub-cache")),
    );
    object.insert(
        String::from("flutterRoot"),
        Value::String(String::from(
            "file:///usr/lib/denial/ui-development/flutter",
        )),
    );

    let runtime_config = temporary.path().join("package_config.json");
    let mut file = File::create(&runtime_config).map_err(ToolError::io)?;
    serde_json::to_writer_pretty(&mut file, &document)
        .map_err(|error| ToolError::new(format!("could not write package config: {error}")))?;
    use std::io::Write;
    file.write_all(b"\n").map_err(ToolError::io)?;
    file.sync_all().map_err(ToolError::io)?;

    if paths.flutter_tool_runtime.exists() {
        let metadata = fs::symlink_metadata(&paths.flutter_tool_runtime).map_err(ToolError::io)?;
        if !metadata.file_type().is_dir() {
            return Err(ToolError::new(format!(
                "Flutter tool runtime is not a directory: {}",
                paths.flutter_tool_runtime.display()
            )));
        }
        fs::remove_dir_all(&paths.flutter_tool_runtime).map_err(ToolError::io)?;
    }
    fs::rename(temporary.path(), &paths.flutter_tool_runtime).map_err(ToolError::io)?;
    println!(
        "Prepared metadata for {dependency_count} Flutter tool dependencies and source for {ui_dependency_count} Denial UI dependencies"
    );
    Ok(())
}

fn copy_ui_dependency_sources(
    paths: &BuildPaths,
    packaged_pub_cache: &Path,
) -> Result<usize, ToolError> {
    let config = paths
        .repository
        .join("dart_shell/.dart_tool/package_config.json");
    let document: Value = serde_json::from_reader(File::open(&config).map_err(ToolError::io)?)
        .map_err(|error| {
            ToolError::new(format!(
                "invalid Denial UI package config {}: {error}",
                config.display()
            ))
        })?;
    let original_pub_cache = document
        .get("pubCache")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::new("Denial UI package config has no Pub cache URI"))?;
    if !original_pub_cache.starts_with("file:///") {
        return Err(ToolError::new(
            "Denial UI package config Pub cache is not an absolute file URI",
        ));
    }
    let packages = document
        .get("packages")
        .and_then(Value::as_array)
        .ok_or_else(|| ToolError::new("Denial UI package config has no package list"))?;
    let canonical_pub_cache = fs::canonicalize(&paths.pub_cache).map_err(ToolError::io)?;
    let mut dependency_count = 0_usize;

    for package in packages {
        let root = package
            .get("rootUri")
            .and_then(Value::as_str)
            .ok_or_else(|| ToolError::new("Denial UI package entry has no rootUri"))?;
        let Some(suffix) = root.strip_prefix(original_pub_cache) else {
            continue;
        };
        let relative = safe_uri_suffix(suffix)?;
        let mut components = relative.components();
        if components
            .next()
            .and_then(|value| value.as_os_str().to_str())
            != Some("hosted")
            || components
                .next()
                .and_then(|value| value.as_os_str().to_str())
                != Some("pub.dev")
        {
            return Err(ToolError::new(format!(
                "Denial UI dependency is outside the supported hosted cache: {root}"
            )));
        }
        let package_directory = components
            .next()
            .filter(|_| components.next().is_none())
            .ok_or_else(|| ToolError::new(format!("unexpected Denial UI dependency path: {root}")))?
            .as_os_str()
            .to_owned();
        let source = fs::canonicalize(paths.pub_cache.join(&relative)).map_err(ToolError::io)?;
        if !source.starts_with(&canonical_pub_cache) {
            return Err(ToolError::new(format!(
                "Denial UI dependency escapes the pinned Pub cache: {}",
                source.display()
            )));
        }
        let destination = packaged_pub_cache.join(&relative);
        copy_package_source(&source, &destination)?;

        let mut hash_name = package_directory;
        hash_name.push(".sha256");
        copy_runtime_tree(
            &paths
                .pub_cache
                .join("hosted-hashes/pub.dev")
                .join(&hash_name),
            &packaged_pub_cache
                .join("hosted-hashes/pub.dev")
                .join(hash_name),
        )?;
        dependency_count += 1;
    }

    if dependency_count == 0 {
        return Err(ToolError::new(
            "Denial UI package config did not identify any hosted dependencies",
        ));
    }
    Ok(dependency_count)
}

fn copy_package_source(source: &Path, destination: &Path) -> Result<(), ToolError> {
    copy_package_metadata(source, destination)?;
    copy_runtime_tree(&source.join("lib"), &destination.join("lib"))
}

fn copy_package_metadata(source: &Path, destination: &Path) -> Result<(), ToolError> {
    fs::create_dir_all(destination).map_err(ToolError::io)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o755)).map_err(ToolError::io)?;
    copy_runtime_tree(
        &source.join("pubspec.yaml"),
        &destination.join("pubspec.yaml"),
    )?;

    let mut entries = fs::read_dir(source)
        .map_err(ToolError::io)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(ToolError::io)?;
    entries.sort_by_key(|entry| entry.file_name());
    let mut license_count = 0_usize;
    for entry in entries {
        let name = entry.file_name();
        let Some(name_text) = name.to_str() else {
            continue;
        };
        let lowercase = name_text.to_ascii_lowercase();
        let is_legal_metadata = lowercase == "authors"
            || lowercase == "copying"
            || lowercase.starts_with("copying.")
            || lowercase == "license"
            || lowercase.starts_with("license.")
            || lowercase == "notice"
            || lowercase.starts_with("notice.");
        if is_legal_metadata {
            copy_runtime_tree(&entry.path(), &destination.join(name))?;
            if lowercase == "license" || lowercase.starts_with("license.") {
                license_count += 1;
            }
        }
    }
    if license_count == 0 {
        return Err(ToolError::new(format!(
            "Flutter tool dependency has no root license file: {}",
            source.display()
        )));
    }
    Ok(())
}

fn build_flutter_sdk_runtime(paths: &BuildPaths) -> Result<(), ToolError> {
    let parent = paths
        .flutter_sdk_runtime
        .parent()
        .ok_or_else(|| ToolError::new("Flutter SDK runtime has no parent directory"))?;
    let temporary = TemporaryDirectory::create(parent, "flutter-sdk-runtime")?;
    let destination = temporary.path();

    for relative in [
        "bin/cache/artifacts/engine/common/flutter_patched_sdk",
        "bin/cache/artifacts/engine/linux-x64/shader_lib",
        "bin/cache/artifacts/gradle_wrapper",
        "bin/cache/artifacts/material_fonts",
        "bin/cache/dart-sdk/lib",
        "bin/cache/pkg/sky_engine/lib",
        "packages/flutter/lib",
        "packages/flutter_localizations/lib",
        "packages/flutter_test/lib",
        "packages/flutter_tools/lib",
    ] {
        copy_sdk_path(paths, destination, relative)?;
    }

    for relative in [
        "AUTHORS",
        "LICENSE",
        "PATENT_GRANT",
        "bin/cache/artifacts/engine/linux-x64/impellerc",
        "bin/cache/artifacts/engine/linux-x64/isolate_snapshot.bin",
        "bin/cache/artifacts/engine/linux-x64/vm_isolate_snapshot.bin",
        "bin/cache/dart-sdk/LICENSE",
        "bin/cache/dart-sdk/revision",
        "bin/cache/dart-sdk/sdk_packages.yaml",
        "bin/cache/dart-sdk/version",
        "bin/cache/dart-sdk/bin/dart",
        "bin/cache/dart-sdk/bin/dartaotruntime",
        "bin/cache/dart-sdk/bin/dartvm",
        "bin/cache/dart-sdk/bin/snapshots/analysis_server.dart.snapshot",
        "bin/cache/dart-sdk/bin/snapshots/analysis_server_aot.dart.snapshot",
        "bin/cache/dart-sdk/bin/snapshots/dart_tooling_daemon_aot.dart.snapshot",
        "bin/cache/dart-sdk/bin/snapshots/dartdev_aot.dart.snapshot",
        "bin/cache/dart-sdk/bin/snapshots/dds_aot.dart.snapshot",
        "bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
        "bin/cache/pkg/flutter_gpu/pubspec.yaml",
        "bin/cache/pkg/sky_engine/LICENSE",
        "bin/cache/pkg/sky_engine/pubspec.yaml",
        "packages/flutter/LICENSE",
        "packages/flutter/pubspec.yaml",
        "packages/flutter_localizations/pubspec.yaml",
        "packages/flutter_test/pubspec.yaml",
        "packages/flutter_tools/pubspec.yaml",
    ] {
        copy_sdk_path(paths, destination, relative)?;
    }

    copy_small_cache_files(paths, destination)?;
    copy_flutter_version_markers(paths, destination)?;

    for relative in [
        "bin/cache/artifacts/engine/linux-x64-profile",
        "bin/cache/artifacts/engine/linux-x64-release",
        "bin/cache/artifacts/ios-deploy",
        "bin/cache/artifacts/libimobiledevice",
        "bin/cache/artifacts/libimobiledeviceglue",
        "bin/cache/artifacts/libplist",
        "bin/cache/artifacts/libusbmuxd",
        "bin/cache/artifacts/openssl",
    ] {
        create_runtime_directory(&destination.join(relative))?;
    }
    for relative in ["dev/.dartignore", "examples/.dartignore"] {
        create_runtime_marker(&destination.join(relative))?;
    }
    for relative in [
        "bin/cache/artifacts/libimobiledevice/idevicescreenshot",
        "bin/cache/artifacts/libimobiledevice/idevicesyslog",
        "bin/cache/artifacts/libusbmuxd/iproxy",
    ] {
        create_runtime_marker(&destination.join(relative))?;
    }

    if paths.flutter_sdk_runtime.exists() {
        let metadata = fs::symlink_metadata(&paths.flutter_sdk_runtime).map_err(ToolError::io)?;
        if !metadata.file_type().is_dir() {
            return Err(ToolError::new(format!(
                "Flutter SDK runtime is not a directory: {}",
                paths.flutter_sdk_runtime.display()
            )));
        }
        fs::remove_dir_all(&paths.flutter_sdk_runtime).map_err(ToolError::io)?;
    }
    fs::rename(temporary.path(), &paths.flutter_sdk_runtime).map_err(ToolError::io)?;
    let bytes = tree_bytes(&paths.flutter_sdk_runtime)?;
    println!(
        "Prepared Denial-scoped Flutter SDK runtime ({})",
        human_size(bytes)
    );
    Ok(())
}

fn build_ui_workspace_template(
    paths: &BuildPaths,
    identity: &PackageIdentity,
) -> Result<(), ToolError> {
    let parent = paths
        .ui_workspace_template
        .parent()
        .ok_or_else(|| ToolError::new("UI workspace template has no parent directory"))?;
    let temporary = TemporaryDirectory::create(parent, "workspace-template")?;
    let destination = temporary.path();
    let mut git = Command::new("git");
    git.current_dir(&paths.repository).args([
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
        ".gitignore",
        "LICENSE",
        "README.md",
        "dart_shell",
        "docs/UI_DEVELOPMENT.md",
        "protocol/generated/dart",
    ]);
    let output = git.output().map_err(ToolError::io)?;
    if !output.status.success() {
        return Err(ToolError::new(format!(
            "could not enumerate the Denial UI source snapshot: {}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }

    let mut copied = 0_usize;
    for bytes in output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|bytes| !bytes.is_empty())
    {
        let relative = Path::new(OsStr::from_bytes(bytes));
        if relative.is_absolute()
            || relative
                .components()
                .any(|component| !matches!(component, std::path::Component::Normal(_)))
        {
            return Err(ToolError::new(format!(
                "Git returned an unsafe UI source path: {}",
                relative.display()
            )));
        }
        copy_runtime_tree(
            &paths.repository.join(relative),
            &destination.join(relative),
        )?;
        copied += 1;
    }
    if copied == 0 {
        return Err(ToolError::new(
            "Git returned no files for the Denial UI source snapshot",
        ));
    }

    for required in [
        destination.join("dart_shell/pubspec.yaml"),
        destination.join("dart_shell/lib/main.dart"),
        destination.join("protocol/generated/dart/pubspec.yaml"),
        destination.join("dart_shell/.vscode/launch.json"),
        destination.join("dart_shell/.vscode/settings.json"),
    ] {
        require_regular_file(&required)?;
    }
    let source_revision = git_output(&paths.repository, &["rev-parse", "HEAD"])?;
    let marker = json!({
        "schema_version": 1,
        "ui_development_api": 1,
        "denial_version": &identity.version,
        "flutter_generation": FLUTTER_ENGINE_ABI,
        "source_ref": &identity.source_ref,
        "source_revision": source_revision,
        "source_state": if identity.version.ends_with(".dirty") {
            "working-tree"
        } else {
            "committed"
        },
        "workspace": "dart_shell"
    });
    let mut marker_bytes = serde_json::to_vec_pretty(&marker)
        .map_err(|error| ToolError::new(format!("could not encode UI source marker: {error}")))?;
    marker_bytes.push(b'\n');
    fs::write(destination.join(UI_SOURCE_MARKER), marker_bytes).map_err(ToolError::io)?;
    fs::set_permissions(
        destination.join(UI_SOURCE_MARKER),
        fs::Permissions::from_mode(0o644),
    )
    .map_err(ToolError::io)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o755)).map_err(ToolError::io)?;
    validate_tree(destination)?;

    if paths.ui_workspace_template.exists() {
        let metadata = fs::symlink_metadata(&paths.ui_workspace_template).map_err(ToolError::io)?;
        if !metadata.file_type().is_dir() {
            return Err(ToolError::new(format!(
                "UI workspace template is not a directory: {}",
                paths.ui_workspace_template.display()
            )));
        }
        fs::remove_dir_all(&paths.ui_workspace_template).map_err(ToolError::io)?;
    }
    fs::rename(temporary.path(), &paths.ui_workspace_template).map_err(ToolError::io)?;
    let bytes = tree_bytes(&paths.ui_workspace_template)?;
    println!(
        "Prepared version-matched Denial UI source snapshot ({copied} files, {})",
        human_size(bytes)
    );
    Ok(())
}

fn copy_sdk_path(paths: &BuildPaths, destination: &Path, relative: &str) -> Result<(), ToolError> {
    copy_runtime_tree(
        &paths.flutter_sdk.join(relative),
        &destination.join(relative),
    )
}

fn copy_small_cache_files(paths: &BuildPaths, destination: &Path) -> Result<(), ToolError> {
    let source = paths.flutter_sdk.join("bin/cache");
    let target = destination.join("bin/cache");
    create_runtime_directory(&target)?;
    let mut entries = fs::read_dir(&source)
        .map_err(ToolError::io)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(ToolError::io)?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let metadata = entry.metadata().map_err(ToolError::io)?;
        if metadata.is_file()
            && metadata.len() <= 1024 * 1024
            && entry.file_name() != OsStr::new("flutter_tools.snapshot")
        {
            copy_runtime_tree(&entry.path(), &target.join(entry.file_name()))?;
        }
    }
    Ok(())
}

fn copy_flutter_version_markers(paths: &BuildPaths, destination: &Path) -> Result<(), ToolError> {
    let source = paths.flutter_sdk.join("bin/internal");
    let target = destination.join("bin/internal");
    create_runtime_directory(&target)?;
    let mut entries = fs::read_dir(&source)
        .map_err(ToolError::io)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(ToolError::io)?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if path.extension() == Some(OsStr::new("version")) {
            copy_runtime_tree(&path, &target.join(entry.file_name()))?;
        }
    }
    Ok(())
}

fn create_runtime_directory(path: &Path) -> Result<(), ToolError> {
    fs::create_dir_all(path).map_err(ToolError::io)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).map_err(ToolError::io)
}

fn create_runtime_marker(path: &Path) -> Result<(), ToolError> {
    let parent = path
        .parent()
        .ok_or_else(|| ToolError::new("runtime marker has no parent directory"))?;
    create_runtime_directory(parent)?;
    File::create(path).map_err(ToolError::io)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o644)).map_err(ToolError::io)
}

fn safe_uri_suffix(suffix: &str) -> Result<PathBuf, ToolError> {
    let suffix = suffix
        .strip_prefix('/')
        .ok_or_else(|| ToolError::new(format!("package URI suffix is not absolute: {suffix}")))?;
    let path = PathBuf::from(suffix);
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|component| !matches!(component, std::path::Component::Normal(_)))
    {
        return Err(ToolError::new(format!(
            "unsafe Flutter tool package URI suffix: {suffix}"
        )));
    }
    Ok(path)
}

fn copy_runtime_tree(source: &Path, destination: &Path) -> Result<(), ToolError> {
    let metadata = fs::symlink_metadata(source).map_err(ToolError::io)?;
    if metadata.file_type().is_symlink() {
        return Err(ToolError::new(format!(
            "Flutter tool dependency contains a symbolic link: {}",
            source.display()
        )));
    }
    if metadata.file_type().is_dir() {
        fs::create_dir_all(destination).map_err(ToolError::io)?;
        fs::set_permissions(destination, fs::Permissions::from_mode(0o755))
            .map_err(ToolError::io)?;
        let mut entries = fs::read_dir(source)
            .map_err(ToolError::io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(ToolError::io)?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            copy_runtime_tree(&entry.path(), &destination.join(entry.file_name()))?;
        }
        return Ok(());
    }
    if !metadata.file_type().is_file() {
        return Err(ToolError::new(format!(
            "Flutter tool dependency contains a special file: {}",
            source.display()
        )));
    }
    let parent = destination
        .parent()
        .ok_or_else(|| ToolError::new("runtime copy destination has no parent directory"))?;
    create_runtime_directory(parent)?;
    fs::copy(source, destination).map_err(ToolError::io)?;
    let mode = if metadata.permissions().mode() & 0o111 == 0 {
        0o644
    } else {
        0o755
    };
    fs::set_permissions(destination, fs::Permissions::from_mode(mode)).map_err(ToolError::io)
}

fn package_rustflags(repository: &Path) -> Result<OsString, ToolError> {
    let repository = repository.to_str().ok_or_else(|| {
        ToolError::new("the repository path must be valid UTF-8 for Rust path remapping")
    })?;
    let mut flags = vec![format!("--remap-path-prefix={repository}=/usr/src/denial")];
    if let Some(home) = absolute_environment_path("HOME")? {
        let home = home
            .to_str()
            .ok_or_else(|| ToolError::new("HOME must be valid UTF-8 for Rust path remapping"))?;
        flags.push(format!("--remap-path-prefix={home}=/usr/src/denial-build"));
    }
    Ok(OsString::from(flags.join("\u{1f}")))
}

fn validate_host(paths: &BuildPaths) -> Result<(), ToolError> {
    if env::consts::OS != "linux" || env::consts::ARCH != "x86_64" {
        return Err(ToolError::new(
            "denial-ui-development currently supports Linux x86-64 only",
        ));
    }
    for command in ["bsdtar", "bwrap", "cargo", "git", "makepkg", "sha256sum"] {
        require_command(command)?;
    }
    require_regular_file(&paths.compositor.join("Cargo.lock"))?;
    require_regular_file(&paths.package_directory.join("PKGBUILD"))?;
    Ok(())
}

fn validate_package_inputs(paths: &BuildPaths) -> Result<(), ToolError> {
    require_executable(&paths.development_binary)?;
    require_executable(&paths.flutter_sdk.join("bin/cache/dart-sdk/bin/dart"))?;
    for path in [
        paths.flutter_sdk.join(".git/HEAD"),
        paths
            .flutter_sdk
            .join("packages/flutter/lib/src/gestures/binding.dart"),
        paths.flutter_tool_snapshot.clone(),
        paths.flutter_tool_runtime.join("package_config.json"),
        paths
            .flutter_sdk_runtime
            .join("bin/cache/dart-sdk/bin/dart"),
        paths
            .flutter_sdk_runtime
            .join("bin/cache/dart-sdk/bin/snapshots/dds_aot.dart.snapshot"),
        paths
            .flutter_sdk_runtime
            .join("bin/cache/artifacts/engine/linux-x64/impellerc"),
        paths
            .flutter_tool_runtime
            .join("pub-cache")
            .join(PUB_CACHE_GENERATION_MARKER),
        paths.ui_workspace_template.join("dart_shell/pubspec.yaml"),
        paths
            .ui_workspace_template
            .join("protocol/generated/dart/pubspec.yaml"),
        paths.ui_workspace_template.join(UI_SOURCE_MARKER),
        paths.flutter_tool_checksum.clone(),
        paths.debug_engine.clone(),
        paths.debug_engine_checksum.clone(),
    ] {
        require_regular_file(&path)?;
    }
    for path in [
        paths
            .flutter_sdk_runtime
            .join("bin/cache/dart-sdk/bin/dart"),
        paths
            .flutter_sdk_runtime
            .join("bin/cache/dart-sdk/bin/dartaotruntime"),
        paths
            .flutter_sdk_runtime
            .join("bin/cache/dart-sdk/bin/dartvm"),
        paths
            .flutter_sdk_runtime
            .join("bin/cache/artifacts/engine/linux-x64/impellerc"),
    ] {
        require_executable(&path)?;
    }

    let expected = checksum_record(&paths.debug_engine_checksum)?;
    let actual = sha256(&paths.debug_engine)?;
    if actual != expected {
        return Err(ToolError::new(format!(
            "debug engine SHA-256 is {actual}, expected {expected}"
        )));
    }
    let expected = checksum_record(&paths.flutter_tool_checksum)?;
    let actual = sha256(&paths.flutter_tool_snapshot)?;
    if actual != expected {
        return Err(ToolError::new(format!(
            "Flutter tool snapshot SHA-256 is {actual}, expected {expected}"
        )));
    }
    Ok(())
}

fn makepkg_command(paths: &BuildPaths, identity: &PackageIdentity) -> Command {
    let packager = env::var_os("DENIAL_PACKAGE_PACKAGER")
        .unwrap_or_else(|| OsString::from("Doctor Logix <doctor.logix@gmail.com>"));
    let mut command = Command::new("makepkg");
    command
        .current_dir(&paths.package_directory)
        .env("LC_ALL", "C")
        .env("SOURCE_DATE_EPOCH", &identity.source_date_epoch)
        .env("DENIAL_PACKAGE_SOURCE_ROOT", &paths.repository)
        .env("DENIAL_PACKAGE_UI_BINARY", &paths.development_binary)
        .env("DENIAL_PACKAGE_FLUTTER_SDK", &paths.flutter_sdk)
        .env(
            "DENIAL_PACKAGE_FLUTTER_TOOL_SNAPSHOT",
            &paths.flutter_tool_snapshot,
        )
        .env(
            "DENIAL_PACKAGE_FLUTTER_TOOL_RUNTIME",
            &paths.flutter_tool_runtime,
        )
        .env(
            "DENIAL_PACKAGE_FLUTTER_SDK_RUNTIME",
            &paths.flutter_sdk_runtime,
        )
        .env(
            "DENIAL_PACKAGE_UI_WORKSPACE_TEMPLATE",
            &paths.ui_workspace_template,
        )
        .env("DENIAL_PACKAGE_DEBUG_ENGINE_SOURCE", &paths.debug_engine)
        .env("DENIAL_PACKAGE_VERSION", &identity.version)
        .env("DENIAL_PACKAGE_RELEASE", &identity.release)
        .env("PKGDEST", &paths.package_root)
        .env("BUILDDIR", &paths.makepkg_root)
        .env("PACKAGER", packager);
    command
}

fn validate_package(
    paths: &BuildPaths,
    identity: &PackageIdentity,
    package: &Path,
) -> Result<(), ToolError> {
    require_regular_file(package)?;
    let extraction = TemporaryDirectory::create(&paths.makepkg_root, "validate-ui-development")?;
    let mut bsdtar = Command::new("bsdtar");
    bsdtar
        .args(["-xpf"])
        .arg(package)
        .arg("-C")
        .arg(extraction.path());
    checked_status(&mut bsdtar, "could not extract package for validation")?;

    let root = extraction.path();
    let package_info = fs::read_to_string(root.join(".PKGINFO")).map_err(ToolError::io)?;
    for expected in [
        format!("pkgname = {UI_PACKAGE_NAME}"),
        format!("pkgver = {}-{}", identity.version, identity.release),
        String::from("arch = x86_64"),
        format!("provides = denial-ui-development-engine={FLUTTER_ENGINE_ABI}"),
        format!("depend = denial-flutter-engine-abi={FLUTTER_ENGINE_ABI}"),
        format!("depend = denial>={UI_DENIAL_MINIMUM_VERSION}"),
        format!("depend = denial<{UI_DENIAL_VERSION_BEFORE}"),
        String::from("depend = git"),
        String::from("depend = glibc"),
        String::from("depend = libgcc"),
    ] {
        if !package_info.lines().any(|line| line == expected) {
            return Err(ToolError::new(format!(
                "package metadata is missing {expected:?}"
            )));
        }
    }

    require_mode(&root.join("usr/bin/denial-ui"), 0o755)?;
    let flutter_link = root.join("usr/bin/denial-flutter");
    if fs::read_link(&flutter_link).map_err(ToolError::io)? != Path::new("denial-ui") {
        return Err(ToolError::new(
            "usr/bin/denial-flutter does not target denial-ui",
        ));
    }
    let sdk_flutter_launcher = root.join("usr/lib/denial/ui-development/flutter/bin/flutter");
    require_mode(&sdk_flutter_launcher, 0o755)?;
    if sha256(&sdk_flutter_launcher)? != sha256(&root.join("usr/bin/denial-ui"))? {
        return Err(ToolError::new(
            "packaged Flutter SDK launcher does not match the native denial-ui client",
        ));
    }

    let packaged_engine = root.join("usr/lib/denial/ui-development/lib/libflutter_engine.so");
    require_mode(&packaged_engine, 0o755)?;
    let expected_engine_sha256 = checksum_record(&paths.debug_engine_checksum)?;
    let packaged_engine_sha256 = sha256(&packaged_engine)?;
    if packaged_engine_sha256 != expected_engine_sha256 {
        return Err(ToolError::new(format!(
            "packaged debug engine SHA-256 is {packaged_engine_sha256}, expected {expected_engine_sha256}"
        )));
    }
    let packaged_flutter_tool =
        root.join("usr/lib/denial/ui-development/flutter/bin/cache/flutter_tools.snapshot");
    require_x86_64_aot_elf(&packaged_flutter_tool)?;
    let expected_flutter_tool_sha256 = checksum_record(&paths.flutter_tool_checksum)?;
    let packaged_flutter_tool_sha256 = sha256(&packaged_flutter_tool)?;
    if packaged_flutter_tool_sha256 != expected_flutter_tool_sha256 {
        return Err(ToolError::new(format!(
            "packaged Flutter tool SHA-256 is {packaged_flutter_tool_sha256}, expected {expected_flutter_tool_sha256}"
        )));
    }
    let expected_flutter_tool_runtime_sha256 = sha256(
        &paths
            .flutter_sdk
            .join("bin/cache/dart-sdk/bin/dartaotruntime"),
    )?;
    let packaged_flutter_tool_runtime =
        root.join("usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dartaotruntime");
    let packaged_flutter_tool_runtime_sha256 = sha256(&packaged_flutter_tool_runtime)?;
    if packaged_flutter_tool_runtime_sha256 != expected_flutter_tool_runtime_sha256 {
        return Err(ToolError::new(format!(
            "packaged Flutter tool runtime SHA-256 is {packaged_flutter_tool_runtime_sha256}, expected {expected_flutter_tool_runtime_sha256}"
        )));
    }

    for required in [
        "usr/lib/denial/ui-development/data/icudtl.dat",
        "usr/lib/denial/ui-development/flutter/bin/cache/flutter_tools.snapshot",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dart",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dartvm",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dartaotruntime",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/lib/core/core.dart",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/snapshots/analysis_server.dart.snapshot",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/snapshots/analysis_server_aot.dart.snapshot",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/snapshots/dds_aot.dart.snapshot",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/snapshots/dart_tooling_daemon_aot.dart.snapshot",
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
        "usr/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/linux-x64/impellerc",
        "usr/lib/denial/ui-development/flutter/bin/cache/pkg/sky_engine/lib/_embedder.yaml",
        "usr/lib/denial/ui-development/flutter/bin/cache/pkg/sky_engine/lib/ui/ui.dart",
        "usr/lib/denial/ui-development/flutter/packages/flutter/lib/src/gestures/binding.dart",
        "usr/lib/denial/ui-development/flutter/packages/flutter_tools/.dart_tool/package_config.json",
        "usr/lib/denial/ui-development/pub-cache/hosted/pub.dev/args-2.7.0/pubspec.yaml",
        "usr/lib/denial/ui-development/pub-cache/hosted/pub.dev/args-2.7.0/LICENSE",
        "usr/lib/denial/ui-development/pub-cache/hosted/pub.dev/args-2.7.0/lib/args.dart",
        "usr/lib/denial/ui-development/pub-cache/hosted-hashes/pub.dev/args-2.7.0.sha256",
        "usr/lib/denial/ui-development/pub-cache/.denial-generation",
        "usr/share/denial/ui-development/manifest.json",
        "usr/share/denial/ui-development/flutter_tools.snapshot.sha256",
        "usr/share/denial/ui-development/workspace/.denial-ui-source.json",
        "usr/share/denial/ui-development/workspace/dart_shell/.vscode/launch.json",
        "usr/share/denial/ui-development/workspace/dart_shell/.vscode/settings.json",
        "usr/share/denial/ui-development/workspace/dart_shell/pubspec.yaml",
        "usr/share/denial/ui-development/workspace/dart_shell/lib/main.dart",
        "usr/share/denial/ui-development/workspace/protocol/generated/dart/pubspec.yaml",
        "usr/share/doc/denial-ui-development/BUILD_INFO.md",
        "usr/share/doc/denial-ui-development/FLUTTER_TOOL_BUILD_INFO.md",
        "usr/share/licenses/denial-ui-development/LICENSE.flutter",
        "usr/share/licenses/denial-ui-development/LICENSE.flutter-third-party",
        "usr/share/licenses/denial-ui-development/LICENSE.dart",
        "usr/share/licenses/denial-ui-development/LICENSE.denial",
    ] {
        require_regular_file(&root.join(required))?;
    }
    let editor_settings_path =
        root.join("usr/share/denial/ui-development/workspace/dart_shell/.vscode/settings.json");
    let editor_settings: Value =
        serde_json::from_reader(File::open(&editor_settings_path).map_err(ToolError::io)?)
            .map_err(|error| {
                ToolError::new(format!(
                    "could not parse packaged editor settings {}: {error}",
                    editor_settings_path.display()
                ))
            })?;
    for (key, expected) in [
        (
            "dart.sdkPath",
            "/usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk",
        ),
        (
            "dart.flutterSdkPath",
            "/usr/lib/denial/ui-development/flutter",
        ),
        ("dart.flutterHotReloadOnSave", "allIfDirty"),
    ] {
        if editor_settings.get(key).and_then(Value::as_str) != Some(expected) {
            return Err(ToolError::new(format!(
                "packaged editor setting {key} does not equal {expected:?}"
            )));
        }
    }
    require_one_regular_file(&[
        root.join("usr/share/man/man1/denial-ui.1"),
        root.join("usr/share/man/man1/denial-ui.1.gz"),
    ])?;
    require_executable(
        &root.join("usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dart"),
    )?;
    require_executable(
        &root.join("usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dartvm"),
    )?;
    require_executable(
        &root.join("usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dartaotruntime"),
    )?;
    require_executable(&root.join(
        "usr/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/linux-x64/impellerc",
    ))?;

    for forbidden in [
        "usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/resources/devtools",
        "usr/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/linux-x64/libflutter_linux_gtk.so",
        "usr/lib/denial/ui-development/flutter/packages/flutter/test",
        "usr/lib/denial/ui-development/flutter/packages/flutter_tools/test",
        "usr/share/denial/ui-development/denial.git.bundle",
        "usr/share/denial/ui-development/workspace/.git",
        "usr/share/denial/ui-development/workspace/dart_shell/.dart_tool",
        "usr/share/denial/ui-development/workspace/dart_shell/build",
    ] {
        let path = root.join(forbidden);
        if fs::symlink_metadata(&path).is_ok() {
            return Err(ToolError::new(format!(
                "development package contains excluded general-purpose SDK content: {}",
                path.display()
            )));
        }
    }

    let development_bytes = tree_bytes(&root.join("usr/lib/denial/ui-development"))?;
    const MAX_DEVELOPMENT_BYTES: u64 = 448 * 1024 * 1024;
    if development_bytes > MAX_DEVELOPMENT_BYTES {
        return Err(ToolError::new(format!(
            "development runtime is {}, above the {} size budget",
            human_size(development_bytes),
            human_size(MAX_DEVELOPMENT_BYTES)
        )));
    }
    println!(
        "Validated installed development runtime size: {}",
        human_size(development_bytes)
    );
    let workspace_bytes = tree_bytes(&root.join("usr/share/denial/ui-development/workspace"))?;
    const MAX_WORKSPACE_BYTES: u64 = 32 * 1024 * 1024;
    if workspace_bytes > MAX_WORKSPACE_BYTES {
        return Err(ToolError::new(format!(
            "editable UI source snapshot is {}, above the {} size budget",
            human_size(workspace_bytes),
            human_size(MAX_WORKSPACE_BYTES)
        )));
    }
    println!(
        "Validated editable UI source snapshot size: {}",
        human_size(workspace_bytes)
    );

    let manifest = fs::read_to_string(root.join("usr/share/denial/ui-development/manifest.json"))
        .map_err(ToolError::io)?;
    let expected_flutter_patch_series_sha256 =
        sha256(&paths.repository.join("patches/flutter/series.sha256"))?;
    let expected_debug_engine_args_sha256 = sha256(
        &paths
            .repository
            .join("prebuilt/flutter-engine/linux-x64-debug/args.gn"),
    )?;
    if !manifest.contains(&format!(
        "\"debug_engine_sha256\": \"{expected_engine_sha256}\""
    )) || !manifest.contains(&format!(
        "\"flutter_tool_sha256\": \"{expected_flutter_tool_sha256}\""
    )) || !manifest.contains(&format!(
        "\"dartaotruntime_sha256\": \"{expected_flutter_tool_runtime_sha256}\""
    )) || !manifest.contains("\"stage\": \"public-alpha\"")
        || !manifest.contains(&format!(
            "\"flutter_series_manifest_sha256\": \"{expected_flutter_patch_series_sha256}\""
        ))
        || !manifest.contains(&format!(
            "\"debug_engine_args_sha256\": \"{expected_debug_engine_args_sha256}\""
        ))
        || !manifest.contains(&format!(
            "\"denial_minimum_version\": \"{UI_DENIAL_MINIMUM_VERSION}\""
        ))
        || !manifest.contains(&format!(
            "\"denial_version_before\": \"{UI_DENIAL_VERSION_BEFORE}\""
        ))
        || !manifest.contains("\"engine_mode\": \"debug-jit\"")
        || !manifest.contains("\"flutter_tool_snapshot_kind\": \"app-aot-elf\"")
        || !manifest.contains("\"flutter_tool_runtime\": \"dartaotruntime\"")
        || !manifest.contains("\"editor_attach_mode\": \"non-pausing\"")
        || !manifest.contains("\"dap_debugger_control\": false")
        || !manifest.contains("\"hot_reload\": true")
        || !manifest.contains("\"flutter_inspector\": true")
        || !manifest.contains("\"version_matched_git_checkout\": true")
        || !manifest.contains(&format!("\"origin\": \"{DENIAL_GIT_REMOTE}\""))
        || !manifest.contains("\"github_access_required_for_initial_setup\": true")
        || !manifest.contains("\"exact_commit_verification\": true")
        || !manifest.contains("\"offline_shell_preparation_verified\": true")
        || !manifest.contains("\"non_pausing_editor_attach_tested\": true")
        || !manifest.contains("\"offline_source_closure\": false")
        || !manifest.contains("\"reproducible_package\": false")
        || !manifest.contains("\"independently_reproduced\": false")
    {
        return Err(ToolError::new(
            "packaged development manifest does not identify the validated runtime and Git checkout",
        ));
    }

    validate_tree(root)?;
    if let Some(home) = absolute_environment_path("HOME")? {
        let needle = home.as_os_str().as_encoded_bytes();
        for payload_root in [root.join("usr"), root.join("etc")] {
            if payload_root.exists()
                && !needle.is_empty()
                && let Some(path) = find_bytes_in_tree(&payload_root, needle)?
            {
                return Err(ToolError::new(format!(
                    "installed package payload leaks the build user's home path in {}",
                    path.display()
                )));
            }
        }
    }
    validate_packaged_flutter_tool(paths, root)?;
    Ok(())
}

fn packaged_source_identity(package_root: &Path) -> Result<(String, String), ToolError> {
    let marker_path = package_root
        .join("usr/share/denial/ui-development/workspace")
        .join(UI_SOURCE_MARKER);
    let marker = fs::read_to_string(&marker_path).map_err(ToolError::io)?;
    let marker: Value = serde_json::from_str(&marker).map_err(|error| {
        ToolError::new(format!(
            "could not decode packaged UI source marker {}: {error}",
            marker_path.display()
        ))
    })?;
    let source_ref = marker
        .get("source_ref")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::new("packaged UI source marker has no Git ref"))?;
    validate_source_ref(source_ref)?;
    let revision = marker
        .get("source_revision")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::new("packaged UI source marker has no Git revision"))?;
    if revision.len() != 40 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ToolError::new(
            "packaged UI source marker contains an invalid Git revision",
        ));
    }
    Ok((source_ref.to_owned(), revision.to_owned()))
}

fn validate_packaged_flutter_tool(
    paths: &BuildPaths,
    package_root: &Path,
) -> Result<(), ToolError> {
    const SANDBOX_SMOKE_ROOT: &str = "/tmp/denial-smoke";

    let smoke = TemporaryDirectory::create(&paths.makepkg_root, "smoke-ui-development")?;
    let source_root = smoke.path().join("source");
    let workspace = source_root.join("dart_shell");
    let cache = smoke.path().join("cache");
    let home = smoke.path().join("home");
    for directory in [&cache, &home] {
        fs::create_dir_all(directory).map_err(ToolError::io)?;
    }
    let (source_ref, source_revision) = packaged_source_identity(package_root)?;
    let mut clone = Command::new("git");
    clone
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .args(["clone", "--quiet", "--no-checkout", "--branch"])
        .arg(&source_ref)
        .args(["--template=", "--"])
        .arg(&paths.repository)
        .arg(&source_root);
    checked_status(
        &mut clone,
        "packaged Denial source metadata failed its local clone test",
    )?;
    let mut checkout = Command::new("git");
    checkout
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .arg("-C")
        .arg(&source_root)
        .args([
            "checkout",
            "--quiet",
            "-B",
            "main",
            source_revision.as_str(),
        ]);
    checked_status(
        &mut checkout,
        "packaged Denial Git revision could not be checked out",
    )?;
    let actual_revision = git_output(&source_root, &["rev-parse", "HEAD"])?;
    if actual_revision != source_revision {
        return Err(ToolError::new(format!(
            "packaged source metadata resolved to {actual_revision}, expected {source_revision}"
        )));
    }
    copy_runtime_tree(
        &package_root.join("usr/share/denial/ui-development/workspace"),
        &source_root,
    )?;
    require_regular_file(&source_root.join(".git/HEAD"))?;

    let development_root = package_root.join("usr/lib/denial/ui-development");
    let denial_ui = package_root.join("usr/bin/denial-ui");
    require_directory(&development_root)?;
    require_regular_file(&denial_ui)?;
    let sandbox_workspace = Path::new(SANDBOX_SMOKE_ROOT).join("source/dart_shell");
    let mut prepare = packaged_denial_ui_command(smoke.path(), package_root, &sandbox_workspace);
    prepare.args(["prepare"]).arg(&sandbox_workspace);
    checked_status(
        &mut prepare,
        "packaged Denial UI workspace failed its immutable offline preparation test",
    )?;
    for required in [
        smoke
            .path()
            .join("build/debug/bundle/data/flutter_assets/kernel_blob.bin"),
        smoke
            .path()
            .join("build/debug/bundle/data/flutter_assets/AssetManifest.bin"),
        smoke
            .path()
            .join("build/debug/bundle/lib/libflutter_engine.so"),
        smoke.path().join("build/pub-cache/.denial-generation"),
    ] {
        require_regular_file(&required)?;
    }

    let analysis_probe = workspace.join("lib/denial_analyzer_smoke.dart");
    fs::write(
        &analysis_probe,
        "\
import 'package:flutter/material.dart';

Color denialAnalyzerColor() => const Color(0xff000000);
VoidCallback denialAnalyzerCallback(VoidCallback callback) => callback;
",
    )
    .map_err(ToolError::io)?;
    let mut analyze = packaged_denial_ui_command(smoke.path(), package_root, &sandbox_workspace);
    analyze
        .args(["flutter", "analyze", "--no-pub"])
        .arg(sandbox_workspace.join("lib/denial_analyzer_smoke.dart"));
    checked_status(
        &mut analyze,
        "packaged Flutter analyzer could not resolve dart:ui through sky_engine",
    )?;
    Ok(())
}

fn packaged_denial_ui_command(smoke: &Path, package_root: &Path, workspace: &Path) -> Command {
    const SANDBOX_SMOKE_ROOT: &str = "/tmp/denial-smoke";
    const SANDBOX_PACKAGE_ROOT: &str = "/tmp/denial-package";

    let sandbox_smoke = Path::new(SANDBOX_SMOKE_ROOT);
    let sandbox_package = Path::new(SANDBOX_PACKAGE_ROOT);
    let home = sandbox_smoke.join("home");
    let cache = sandbox_smoke.join("cache");
    let development_root = sandbox_package.join("usr/lib/denial/ui-development");
    let denial_ui = sandbox_package.join("usr/bin/denial-ui");
    let mut bwrap = Command::new("bwrap");
    bwrap
        .args([
            "--die-with-parent",
            "--unshare-user",
            "--unshare-pid",
            "--unshare-net",
            "--unshare-ipc",
            "--unshare-uts",
            "--unshare-cgroup-try",
            "--new-session",
            "--clearenv",
            "--ro-bind",
            "/",
            "/",
            "--tmpfs",
            "/tmp",
            "--bind",
        ])
        .arg(smoke)
        .arg(sandbox_smoke)
        .arg("--ro-bind")
        .arg(package_root)
        .arg(sandbox_package)
        .arg("--chdir")
        .arg(workspace)
        .args(["--setenv", "HOME"])
        .arg(&home)
        .args(["--setenv", "XDG_CACHE_HOME"])
        .arg(&cache)
        .args(["--setenv", "XDG_CONFIG_HOME"])
        .arg(home.join(".config"))
        .args(["--setenv", "XDG_DATA_HOME"])
        .arg(home.join(".local/share"))
        .args(["--setenv", "XDG_STATE_HOME"])
        .arg(home.join(".local/state"))
        .args([
            "--setenv",
            "PATH",
            "/usr/local/bin:/usr/bin",
            "--setenv",
            "LANG",
            "C",
            "--setenv",
            "LC_ALL",
            "C",
            "--setenv",
            "TZ",
            "UTC",
            "--setenv",
            "CI",
            "true",
            "--setenv",
            "SOURCE_DATE_EPOCH",
            "0",
            "--setenv",
            "TMPDIR",
            "/tmp",
            "--setenv",
            "GIT_CONFIG_NOSYSTEM",
            "1",
            "--setenv",
            "GIT_CONFIG_GLOBAL",
            "/dev/null",
            "--setenv",
            "DART_SUPPRESS_ANALYTICS",
            "true",
            "--setenv",
            "FLUTTER_SUPPRESS_ANALYTICS",
            "true",
            "--setenv",
            "DENIAL_UI_DEVELOPMENT_ROOT",
        ])
        .arg(&development_root)
        .args(["--setenv", "DENIAL_UI_BUILD_ROOT"])
        .arg(sandbox_smoke.join("build"))
        .args(["--setenv", "DENIAL_UI_DEBUG_BUNDLE"])
        .arg(sandbox_smoke.join("build/debug/bundle"))
        .arg(denial_ui)
        .env_clear()
        .env("PATH", "/usr/local/bin:/usr/bin");
    bwrap
}

fn validate_tree(root: &Path) -> Result<(), ToolError> {
    visit_tree(root, &mut |path, metadata| {
        if path
            .file_name()
            .is_some_and(|name| name == OsStr::new(".git"))
        {
            return Err(ToolError::new(format!(
                "package unexpectedly contains Git metadata: {}",
                path.display()
            )));
        }
        if !metadata.file_type().is_symlink() && metadata.permissions().mode() & 0o002 != 0 {
            return Err(ToolError::new(format!(
                "package contains a world-writable path: {}",
                path.display()
            )));
        }
        Ok(())
    })
}

fn find_bytes_in_tree(root: &Path, needle: &[u8]) -> Result<Option<PathBuf>, ToolError> {
    let mut found = None;
    visit_tree(root, &mut |path, metadata| {
        if found.is_none() && metadata.file_type().is_file() && file_contains(path, needle)? {
            found = Some(path.to_path_buf());
        }
        Ok(())
    })?;
    Ok(found)
}

fn file_contains(path: &Path, needle: &[u8]) -> Result<bool, ToolError> {
    if needle.is_empty() {
        return Ok(false);
    }
    let mut file = File::open(path).map_err(ToolError::io)?;
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut overlap = Vec::new();
    loop {
        let count = file.read(&mut buffer).map_err(ToolError::io)?;
        if count == 0 {
            return Ok(false);
        }
        let mut search = Vec::with_capacity(overlap.len() + count);
        search.extend_from_slice(&overlap);
        search.extend_from_slice(&buffer[..count]);
        if search.windows(needle.len()).any(|window| window == needle) {
            return Ok(true);
        }
        let retain = needle.len().saturating_sub(1).min(search.len());
        overlap.clear();
        overlap.extend_from_slice(&search[search.len() - retain..]);
    }
}

fn visit_tree(
    path: &Path,
    visitor: &mut impl FnMut(&Path, &fs::Metadata) -> Result<(), ToolError>,
) -> Result<(), ToolError> {
    let metadata = fs::symlink_metadata(path).map_err(ToolError::io)?;
    visitor(path, &metadata)?;
    if metadata.file_type().is_dir() {
        for entry in fs::read_dir(path).map_err(ToolError::io)? {
            let entry = entry.map_err(ToolError::io)?;
            visit_tree(&entry.path(), visitor)?;
        }
    }
    Ok(())
}

fn require_regular_file(path: &Path) -> Result<(), ToolError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ToolError::new(format!("missing regular file {}: {error}", path.display()))
    })?;
    if metadata.file_type().is_file() {
        Ok(())
    } else {
        Err(ToolError::new(format!(
            "expected a regular file: {}",
            path.display()
        )))
    }
}

fn require_x86_64_aot_elf(path: &Path) -> Result<(), ToolError> {
    require_regular_file(path)?;
    let mut header = [0_u8; 20];
    File::open(path)
        .map_err(ToolError::io)?
        .read_exact(&mut header)
        .map_err(ToolError::io)?;
    let is_elf = header[..4] == [0x7f, b'E', b'L', b'F'];
    let is_64_bit_little_endian = header[4] == 2 && header[5] == 1 && header[6] == 1;
    let object_type = u16::from_le_bytes([header[16], header[17]]);
    let machine = u16::from_le_bytes([header[18], header[19]]);
    if is_elf && is_64_bit_little_endian && object_type == 3 && machine == 62 {
        Ok(())
    } else {
        Err(ToolError::new(format!(
            "expected an x86-64 AOT ELF shared object: {}",
            path.display()
        )))
    }
}

fn require_directory(path: &Path) -> Result<(), ToolError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        ToolError::new(format!("missing directory {}: {error}", path.display()))
    })?;
    if metadata.file_type().is_dir() {
        Ok(())
    } else {
        Err(ToolError::new(format!(
            "expected a directory: {}",
            path.display()
        )))
    }
}

fn require_one_regular_file(paths: &[PathBuf]) -> Result<(), ToolError> {
    if paths
        .iter()
        .any(|path| fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_file()))
    {
        Ok(())
    } else {
        Err(ToolError::new(format!(
            "none of the expected regular files exist: {}",
            paths
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        )))
    }
}

fn require_executable(path: &Path) -> Result<(), ToolError> {
    require_regular_file(path)?;
    let mode = fs::metadata(path)
        .map_err(ToolError::io)?
        .permissions()
        .mode();
    if mode & 0o111 == 0 {
        Err(ToolError::new(format!(
            "expected an executable file: {}",
            path.display()
        )))
    } else {
        Ok(())
    }
}

fn require_mode(path: &Path, expected: u32) -> Result<(), ToolError> {
    require_regular_file(path)?;
    let actual = fs::metadata(path)
        .map_err(ToolError::io)?
        .permissions()
        .mode()
        & 0o777;
    if actual == expected {
        Ok(())
    } else {
        Err(ToolError::new(format!(
            "{} has mode {actual:04o}, expected {expected:04o}",
            path.display()
        )))
    }
}

fn require_command(name: &str) -> Result<(), ToolError> {
    let path = env::var_os("PATH").ok_or_else(|| ToolError::new("PATH is unset"))?;
    if env::split_paths(&path).any(|directory| {
        let candidate = directory.join(name);
        fs::metadata(candidate)
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    }) {
        Ok(())
    } else {
        Err(ToolError::new(format!("{name} is required")))
    }
}

fn checked_status(command: &mut Command, context: &str) -> Result<(), ToolError> {
    print_command(command);
    let status = command.status().map_err(ToolError::io)?;
    if status.success() {
        Ok(())
    } else {
        Err(ToolError::new(format!("{context}: {status}")))
    }
}

fn checked_output(command: &mut Command, context: &str) -> Result<String, ToolError> {
    let output = command.output().map_err(ToolError::io)?;
    require_success(output, context)
}

fn require_success(output: Output, context: &str) -> Result<String, ToolError> {
    if output.status.success() {
        String::from_utf8(output.stdout)
            .map(|value| value.trim().to_owned())
            .map_err(|_| ToolError::new(format!("{context}: output is not valid UTF-8")))
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(ToolError::new(format!(
            "{context}: {}\n{}",
            output.status,
            stderr.trim()
        )))
    }
}

fn print_command(command: &Command) {
    print!("+ {}", command.get_program().to_string_lossy());
    for argument in command.get_args() {
        print!(" {}", argument.to_string_lossy());
    }
    println!();
}

fn git_output(repository: &Path, arguments: &[&str]) -> Result<String, ToolError> {
    let mut git = Command::new("git");
    git.arg("-C")
        .arg(repository)
        .args(arguments)
        .env("LC_ALL", "C");
    checked_output(&mut git, "Git command failed")
}

fn sha256(path: &Path) -> Result<String, ToolError> {
    let mut command = Command::new("sha256sum");
    command.arg("--").arg(path).env("LC_ALL", "C");
    let output = checked_output(&mut command, "sha256sum failed")?;
    let hash = output
        .split_whitespace()
        .next()
        .ok_or_else(|| ToolError::new("sha256sum returned no digest"))?;
    validate_sha256(hash)?;
    Ok(hash.to_owned())
}

fn checksum_record(path: &Path) -> Result<String, ToolError> {
    let contents = fs::read_to_string(path).map_err(ToolError::io)?;
    let hash = contents
        .split_whitespace()
        .next()
        .ok_or_else(|| ToolError::new(format!("empty checksum record: {}", path.display())))?;
    validate_sha256(hash)?;
    Ok(hash.to_owned())
}

fn validate_sha256(value: &str) -> Result<(), ToolError> {
    if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(ToolError::new(format!("invalid SHA-256 digest {value:?}")))
    }
}

fn cargo_package_version(manifest: &Path) -> Result<String, ToolError> {
    let contents = fs::read_to_string(manifest).map_err(ToolError::io)?;
    contents
        .lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix("version = \"")
                .and_then(|value| value.strip_suffix('"'))
                .map(str::to_owned)
        })
        .ok_or_else(|| {
            ToolError::new(format!(
                "could not read the package version from {}",
                manifest.display()
            ))
        })
}

fn validate_release_tag(tag: &str) -> Result<(), ToolError> {
    let Some(version) = tag.strip_prefix('v') else {
        return Err(ToolError::new(
            "DENIAL_RELEASE_TAG must have the form vMAJOR.MINOR.PATCH",
        ));
    };
    let components = version.split('.').collect::<Vec<_>>();
    if components.len() == 3
        && components
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        Ok(())
    } else {
        Err(ToolError::new(
            "DENIAL_RELEASE_TAG must have the form vMAJOR.MINOR.PATCH",
        ))
    }
}

fn validate_source_ref(source_ref: &str) -> Result<(), ToolError> {
    if source_ref.is_empty()
        || source_ref.len() > 255
        || source_ref.starts_with('-')
        || !source_ref
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'/' | b'-'))
    {
        return Err(ToolError::new(
            "the package source branch is empty or cannot be cloned safely",
        ));
    }
    Ok(())
}

fn one_output_path(output: &str, base: &Path) -> Result<PathBuf, ToolError> {
    let paths = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(PathBuf::from)
        .collect::<Vec<_>>();
    if paths.len() != 1 {
        return Err(ToolError::new(format!(
            "expected one package path from makepkg, received {}",
            paths.len()
        )));
    }
    let path = paths.into_iter().next().expect("length checked");
    Ok(if path.is_absolute() {
        path
    } else {
        base.join(path)
    })
}

fn absolute_environment_path(name: &str) -> Result<Option<PathBuf>, ToolError> {
    let Some(value) = env::var_os(name) else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if path.is_absolute() {
        Ok(Some(path))
    } else {
        Err(ToolError::new(format!(
            "{name} must be an absolute path: {}",
            path.display()
        )))
    }
}

fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn tree_bytes(root: &Path) -> Result<u64, ToolError> {
    let mut total = 0_u64;
    visit_tree(root, &mut |path, metadata| {
        if metadata.file_type().is_file() {
            total = total.checked_add(metadata.len()).ok_or_else(|| {
                ToolError::new(format!(
                    "runtime size overflow while visiting {}",
                    path.display()
                ))
            })?;
        }
        Ok(())
    })?;
    Ok(total)
}

struct TemporaryDirectory {
    path: PathBuf,
}

impl TemporaryDirectory {
    fn create(parent: &Path, prefix: &str) -> Result<Self, ToolError> {
        fs::create_dir_all(parent).map_err(ToolError::io)?;
        for _ in 0..128 {
            let sequence = TEMPORARY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!("{prefix}.{}.{}", std::process::id(), sequence));
            match fs::create_dir(&path) {
                Ok(()) => {
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                        .map_err(ToolError::io)?;
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(ToolError::io(error)),
            }
        }
        Err(ToolError::new(format!(
            "could not allocate a validation directory below {}",
            parent.display()
        )))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[derive(Debug)]
struct ToolError {
    message: String,
    usage: bool,
}

impl ToolError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            usage: false,
        }
    }

    fn usage(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            usage: true,
        }
    }

    fn io(error: io::Error) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for ToolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)?;
        if self.usage {
            write!(formatter, "\nTry 'cargo xtask --help'.")?;
        }
        Ok(())
    }
}

impl Error for ToolError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_package_config_normalizes_optional_flutter_version() {
        let temporary =
            TemporaryDirectory::create(&env::temp_dir(), "denial-package-config-test").unwrap();
        let first_source = temporary.path().join("first.json");
        let second_source = temporary.path().join("second.json");
        let first_output = temporary.path().join("first-canonical.json");
        let second_output = temporary.path().join("second-canonical.json");
        fs::write(
            &first_source,
            r#"{
  "configVersion": 2,
  "packages": [
    {
      "name": "example",
      "rootUri": "file:///tmp/first-cache/hosted/pub.dev/example-1.0.0",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    },
    {
      "name": "flutter_tools",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.10"
    }
  ],
  "generator": "pub",
  "generatorVersion": "3.12.2",
  "flutterRoot": "file:///tmp/first-flutter",
  "flutterVersion": "stale",
  "pubCache": "file:///tmp/first-cache"
}"#,
        )
        .unwrap();
        fs::write(
            &second_source,
            r#"{
  "configVersion": 2,
  "packages": [
    {
      "name": "example",
      "rootUri": "file:///var/tmp/second-cache/hosted/pub.dev/example-1.0.0",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    },
    {
      "name": "flutter_tools",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.10"
    }
  ],
  "generator": "pub",
  "generatorVersion": "3.12.2",
  "flutterRoot": "file:///var/tmp/second-flutter",
  "pubCache": "file:///var/tmp/second-cache"
}"#,
        )
        .unwrap();

        write_canonical_package_config(&first_source, &first_output).unwrap();
        write_canonical_package_config(&second_source, &second_output).unwrap();

        let first = fs::read(&first_output).unwrap();
        let second = fs::read(&second_output).unwrap();
        assert_eq!(first, second);
        let document: Value = serde_json::from_slice(&first).unwrap();
        assert_eq!(
            document.get("flutterVersion").and_then(Value::as_str),
            Some(FLUTTER_SDK_VERSION)
        );
    }
}
