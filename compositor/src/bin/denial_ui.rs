#![forbid(unsafe_code)]

use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command as Process, ExitCode, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

const FLUTTER_GENERATION: &str = "3.44.7.denial1";
const SYSTEM_ROOT: &str = "/usr/lib/denial/ui-development";
const PUB_CACHE_GENERATION_MARKER: &str = ".denial-generation";
const MAX_VM_SERVICE_BYTES: u64 = 64 * 1024;
const MAX_WORKSPACE_BYTES: usize = 4096;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn main() -> ExitCode {
    let executable = env::args_os()
        .next()
        .and_then(|path| PathBuf::from(path).file_name().map(OsStr::to_owned));
    let result = if executable
        .as_deref()
        .is_some_and(is_flutter_passthrough_executable)
    {
        run_flutter_passthrough(env::args_os().skip(1).collect())
    } else {
        run()
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("denial-ui: {error}");
            ExitCode::FAILURE
        }
    }
}

fn is_flutter_passthrough_executable(executable: &OsStr) -> bool {
    executable == OsStr::new("denial-flutter") || executable == OsStr::new("flutter")
}

fn run() -> Result<(), CliError> {
    let mut arguments = env::args_os().skip(1);
    let Some(command) = arguments.next() else {
        return Err(CliError::usage("a command is required"));
    };
    let remainder = arguments.collect::<Vec<_>>();
    match command.to_str() {
        Some("doctor") => {
            let workspace = optional_workspace(&remainder)?;
            doctor(workspace.as_deref())
        }
        Some("prepare") => {
            let workspace = required_workspace(&remainder)?;
            prepare(&workspace, PreparedRuntime::Debug)
        }
        Some("prepare-profile") => {
            let workspace = required_workspace(&remainder)?;
            prepare(&workspace, PreparedRuntime::Profile)
        }
        Some("uri") => {
            expect_no_arguments(&remainder)?;
            println!("{}", read_vm_service_uri()?);
            Ok(())
        }
        Some("attach") => {
            let workspace = required_workspace(&remainder)?;
            attach(&workspace, false)
        }
        Some("attach-profile") => {
            let workspace = required_workspace(&remainder)?;
            attach(&workspace, true)
        }
        Some("flutter") => run_flutter_passthrough(remainder),
        Some("version") | Some("--version") | Some("-V") => {
            expect_no_arguments(&remainder)?;
            println!(
                "denial-ui {} (Flutter generation {FLUTTER_GENERATION})",
                denial_core::VERSION
            );
            Ok(())
        }
        Some("help") | Some("--help") | Some("-h") => {
            expect_no_arguments(&remainder)?;
            print_help();
            Ok(())
        }
        Some(value) => Err(CliError::usage(format!("unknown command {value:?}"))),
        None => Err(CliError::usage("commands must be valid UTF-8")),
    }
}

fn print_help() {
    println!(
        "\
Usage: denial-ui COMMAND [WORKSPACE]

Commands:
  doctor              Inspect the workspace and installed development runtime
  prepare [WORKSPACE] Build and atomically install the JIT Flutter bundle
  prepare-profile     Build and atomically install the optimized AOT profile bundle
  uri                 Print the authenticated loopback Dart VM-service URI
  attach [WORKSPACE]  Attach the pinned Flutter tool to the live Denial shell
  attach-profile      Attach the pinned Flutter tool to an AOT profile shell
  flutter [ARGS...]   Run the package-pinned Flutter tool
  version             Show tool and Flutter-generation versions

WORKSPACE defaults to DENIAL_UI_WORKSPACE, the current Flutter project,
./dart_shell, or the workspace selected in Denial Settings.

Path overrides:
  DENIAL_UI_WORKSPACE
  DENIAL_UI_DEVELOPMENT_ROOT
  DENIAL_FLUTTER_SDK_ROOT
  DENIAL_UI_DEBUG_ENGINE
  DENIAL_UI_PROFILE_ENGINE
  DENIAL_UI_DEBUG_BUNDLE
  DENIAL_UI_PROFILE_BUNDLE
  DENIAL_UI_BUILD_ROOT
  DENIAL_UI_PUB_CACHE"
    );
}

fn expect_no_arguments(arguments: &[OsString]) -> Result<(), CliError> {
    if arguments.is_empty() {
        Ok(())
    } else {
        Err(CliError::usage("this command accepts no arguments"))
    }
}

fn optional_workspace(arguments: &[OsString]) -> Result<Option<PathBuf>, CliError> {
    if arguments.len() > 1 {
        return Err(CliError::usage("expected at most one workspace path"));
    }
    if let Some(path) = arguments.first() {
        return Ok(Some(validate_workspace(Path::new(path))?));
    }
    discover_workspace().transpose()
}

fn required_workspace(arguments: &[OsString]) -> Result<PathBuf, CliError> {
    optional_workspace(arguments)?.ok_or_else(|| {
        CliError::new(
            "could not discover a Flutter workspace; pass an explicit path or select one in Denial Settings",
        )
    })
}

fn discover_workspace() -> Option<Result<PathBuf, CliError>> {
    if let Some(path) = env::var_os("DENIAL_UI_WORKSPACE") {
        return Some(validate_workspace(Path::new(&path)));
    }
    let current = match env::current_dir() {
        Ok(path) => path,
        Err(error) => {
            return Some(Err(CliError::new(format!(
                "could not read the current directory: {error}"
            ))));
        }
    };
    if workspace_shape_is_valid(&current) {
        return Some(validate_workspace(&current));
    }
    let nested = current.join("dart_shell");
    if workspace_shape_is_valid(&nested) {
        return Some(validate_workspace(&nested));
    }
    configured_workspace().map(|path| validate_workspace(&path))
}

fn configured_workspace() -> Option<PathBuf> {
    let path = config_home()?.join("denial/ui-development.json");
    let metadata = fs::symlink_metadata(&path).ok()?;
    if !metadata.file_type().is_file() || metadata.len() > 64 * 1024 {
        return None;
    }
    let document: Value = serde_json::from_reader(File::open(path).ok()?).ok()?;
    if document.get("schema_version")?.as_u64()? != 1 {
        return None;
    }
    document
        .get("workspace")?
        .as_str()
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

fn workspace_shape_is_valid(path: &Path) -> bool {
    path.is_dir() && path.join("pubspec.yaml").is_file() && path.join("lib/main.dart").is_file()
}

fn validate_workspace(path: &Path) -> Result<PathBuf, CliError> {
    if path.as_os_str().is_empty() {
        return Err(CliError::new("Flutter workspace path must not be empty"));
    }
    let absolute = if path.is_absolute() {
        path.to_owned()
    } else {
        env::current_dir().map_err(CliError::io)?.join(path)
    };
    let canonical = fs::canonicalize(&absolute).map_err(|error| {
        CliError::new(format!(
            "could not resolve Flutter workspace {}: {error}",
            absolute.display()
        ))
    })?;
    let value = canonical
        .to_str()
        .filter(|value| value.len() <= MAX_WORKSPACE_BYTES && !value.as_bytes().contains(&0))
        .ok_or_else(|| {
            CliError::new("Flutter workspace path must be valid UTF-8 and at most 4,096 bytes")
        })?;
    if !workspace_shape_is_valid(Path::new(value)) {
        return Err(CliError::new(format!(
            "workspace {} must contain pubspec.yaml and lib/main.dart",
            canonical.display()
        )));
    }
    Ok(canonical)
}

#[derive(Debug)]
struct DevelopmentPaths {
    root: PathBuf,
    flutter_root: PathBuf,
    flutter_launcher: PathBuf,
    flutter_tool_runtime: PathBuf,
    flutter_tool: PathBuf,
    engine: PathBuf,
    profile_engine: PathBuf,
    icu: PathBuf,
    build_root: PathBuf,
    bundle: PathBuf,
    profile_bundle: PathBuf,
    pub_cache_seed: PathBuf,
    pub_cache: PathBuf,
}

impl DevelopmentPaths {
    fn resolve() -> Result<Self, CliError> {
        let cache = cache_home()
            .ok_or_else(|| CliError::new("HOME or an absolute XDG_CACHE_HOME is required"))?
            .join("denial");
        let root =
            env_path("DENIAL_UI_DEVELOPMENT_ROOT").unwrap_or_else(|| PathBuf::from(SYSTEM_ROOT));
        let installed = root
            .join("flutter/bin/cache/flutter_tools.snapshot")
            .is_file();
        let flutter_root = env_path("DENIAL_FLUTTER_SDK_ROOT").unwrap_or_else(|| {
            if installed {
                root.join("flutter")
            } else {
                cache.join("pc-dependencies/flutter")
            }
        });
        let engine = env_path("DENIAL_UI_DEBUG_ENGINE").unwrap_or_else(|| {
            if installed {
                root.join("lib/libflutter_engine.so")
            } else {
                cache.join("flutter-engine/linux-x64-debug/libflutter_engine.so")
            }
        });
        let profile_engine = env_path("DENIAL_UI_PROFILE_ENGINE").unwrap_or_else(|| {
            if installed {
                root.join("profile/lib/libflutter_engine.so")
            } else {
                cache.join("flutter-engine/linux-x64-profile/libflutter_engine.so")
            }
        });
        let packaged_icu = root.join("data/icudtl.dat");
        let icu = if installed && packaged_icu.is_file() {
            packaged_icu
        } else {
            flutter_root.join("bin/cache/artifacts/engine/linux-x64/icudtl.dat")
        };
        let build_root =
            env_path("DENIAL_UI_BUILD_ROOT").unwrap_or_else(|| cache.join("ui-development"));
        let bundle =
            env_path("DENIAL_UI_DEBUG_BUNDLE").unwrap_or_else(|| build_root.join("debug/bundle"));
        let profile_bundle = env_path("DENIAL_UI_PROFILE_BUNDLE")
            .unwrap_or_else(|| build_root.join("profile/bundle"));
        let pub_cache_seed = root.join("pub-cache");
        let pub_cache =
            env_path("DENIAL_UI_PUB_CACHE").unwrap_or_else(|| build_root.join("pub-cache"));
        require_absolute("development root", &root)?;
        require_absolute("Flutter SDK", &flutter_root)?;
        require_absolute("debug engine", &engine)?;
        require_absolute("profile engine", &profile_engine)?;
        require_absolute("build root", &build_root)?;
        require_absolute("debug bundle", &bundle)?;
        require_absolute("profile bundle", &profile_bundle)?;
        require_absolute("packaged Pub cache seed", &pub_cache_seed)?;
        require_absolute("user Pub cache", &pub_cache)?;
        let flutter_tool_runtime = flutter_root.join("bin/cache/dart-sdk/bin/dartaotruntime");
        let flutter_launcher = flutter_root.join("bin/flutter");
        let flutter_tool = flutter_root.join("bin/cache/flutter_tools.snapshot");
        Ok(Self {
            root,
            flutter_root,
            flutter_launcher,
            flutter_tool_runtime,
            flutter_tool,
            engine,
            profile_engine,
            icu,
            build_root,
            bundle,
            profile_bundle,
            pub_cache_seed,
            pub_cache,
        })
    }
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn require_absolute(label: &str, path: &Path) -> Result<(), CliError> {
    if path.is_absolute() {
        Ok(())
    } else {
        Err(CliError::new(format!(
            "{label} path must be absolute: {}",
            path.display()
        )))
    }
}

fn doctor(workspace: Option<&Path>) -> Result<(), CliError> {
    let paths = DevelopmentPaths::resolve()?;
    let mut ready = true;
    ready &= show_path("development package", &paths.root, Path::is_dir);
    if let Some(workspace) = workspace {
        ready &= show_path("workspace", workspace, Path::is_dir);
        ready &= show_path("pubspec", &workspace.join("pubspec.yaml"), Path::is_file);
        ready &= show_path(
            "entrypoint",
            &workspace.join("lib/main.dart"),
            Path::is_file,
        );
    } else {
        println!("missing  {:<20} not selected", "workspace");
        ready = false;
    }
    ready &= show_path("Flutter launcher", &paths.flutter_launcher, Path::is_file);
    ready &= show_path(
        "Flutter tool AOT runtime",
        &paths.flutter_tool_runtime,
        Path::is_file,
    );
    ready &= show_path("Flutter tool", &paths.flutter_tool, Path::is_file);
    ready &= show_path(
        "Flutter analyzer SDK",
        &paths
            .flutter_root
            .join("bin/cache/pkg/sky_engine/lib/ui/ui.dart"),
        Path::is_file,
    );
    ready &= show_path("debug engine", &paths.engine, Path::is_file);
    ready &= show_path("ICU data", &paths.icu, Path::is_file);
    ready &= show_path(
        "dependency seed",
        &paths.pub_cache_seed.join(PUB_CACHE_GENERATION_MARKER),
        Path::is_file,
    );
    show_path(
        "user Pub cache",
        &paths.pub_cache.join(PUB_CACHE_GENERATION_MARKER),
        Path::is_file,
    );
    ready &= show_path(
        "debug bundle",
        &paths.bundle.join("data/flutter_assets/kernel_blob.bin"),
        Path::is_file,
    );
    if let Some(path) = vm_service_path() {
        show_path("VM service", &path, Path::is_file);
    } else {
        println!("missing  {:<20} XDG_RUNTIME_DIR is unset", "VM service");
    }
    if paths.engine.is_file() {
        validate_debug_engine(&paths.engine)?;
    }
    if ready {
        Ok(())
    } else {
        Err(CliError::new(
            "live UI development is not fully prepared; inspect the missing paths above",
        ))
    }
}

fn show_path(label: &str, path: &Path, predicate: impl FnOnce(&Path) -> bool) -> bool {
    let exists = predicate(path);
    println!(
        "{:<8} {:<20} {}",
        if exists { "ok" } else { "missing" },
        label,
        path.display()
    );
    exists
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PreparedRuntime {
    Debug,
    Profile,
}

fn prepare(workspace: &Path, runtime: PreparedRuntime) -> Result<(), CliError> {
    let paths = DevelopmentPaths::resolve()?;
    validate_toolchain(&paths)?;
    let (engine, configured_bundle, build_mode, track_widget_creation, tree_shake_icons, target) =
        match runtime {
            PreparedRuntime::Debug => (
                &paths.engine,
                &paths.bundle,
                "debug",
                "true",
                "false",
                "copy_flutter_bundle",
            ),
            PreparedRuntime::Profile => (
                &paths.profile_engine,
                &paths.profile_bundle,
                "profile",
                "false",
                "true",
                "profile_bundle_linux-x64_assets",
            ),
        };
    validate_engine(engine, build_mode)?;
    let (build_root, bundle) = prepare_destinations(&paths, configured_bundle, build_mode)?;

    run_flutter(
        &paths,
        workspace,
        &[
            OsString::from("pub"),
            OsString::from("get"),
            OsString::from("--offline"),
        ],
        false,
    )?;

    let assembly = TemporaryDirectory::create(&build_root, "assembly")?;
    let bundle_parent = bundle
        .parent()
        .ok_or_else(|| CliError::new(format!("{build_mode} bundle has no parent directory")))?;
    let mut staging = TemporaryDirectory::create(bundle_parent, ".bundle")?;
    let mut previous = TemporaryDirectory::create(bundle_parent, ".previous")?;
    let assembly_output = assembly.path().to_owned();

    let assemble_arguments = vec![
        OsString::from("assemble"),
        OsString::from(format!("--output={}", assembly_output.display())),
        OsString::from("-dTargetFile=lib/main.dart"),
        OsString::from(format!("-dBuildMode={build_mode}")),
        OsString::from("-dTargetPlatform=linux-x64"),
        OsString::from("-dDartObfuscation=false"),
        OsString::from(format!("-dTrackWidgetCreation={track_widget_creation}")),
        OsString::from(format!("-dTreeShakeIcons={tree_shake_icons}")),
        OsString::from(target),
    ];
    run_flutter(&paths, workspace, &assemble_arguments, false)?;

    let assets = match runtime {
        PreparedRuntime::Debug => {
            // The JIT engine owns these snapshots, so do not duplicate them
            // in the prepared shell bundle.
            for redundant in [
                "vm_snapshot_data",
                "isolate_snapshot_data",
                ".last_build_id",
            ] {
                remove_regular_file_if_present(&assembly_output.join(redundant))?;
            }
            require_regular_file(&assembly_output.join("kernel_blob.bin"))?;
            assembly_output.clone()
        }
        PreparedRuntime::Profile => {
            require_regular_file(&assembly_output.join("lib/libapp.so"))?;
            let assets = assembly_output.join("flutter_assets");
            require_regular_file(&assets.join("AssetManifest.bin"))?;
            assets
        }
    };
    let staged_bundle = staging.path();
    copy_tree(&assets, &staged_bundle.join("data/flutter_assets"))?;
    copy_regular_file(&paths.icu, &staged_bundle.join("data/icudtl.dat"), 0o644)?;
    copy_regular_file(
        engine,
        &staged_bundle.join("lib/libflutter_engine.so"),
        0o755,
    )?;
    if runtime == PreparedRuntime::Profile {
        copy_regular_file(
            &assembly_output.join("lib/libapp.so"),
            &staged_bundle.join("lib/libapp.so"),
            0o755,
        )?;
    }
    write_private(
        &staged_bundle.join("workspace.path"),
        format!("{}\n", workspace.display()).as_bytes(),
    )?;

    let backup = previous.path().join("bundle");
    if fs::symlink_metadata(&bundle).is_ok() {
        let metadata = fs::symlink_metadata(&bundle).map_err(CliError::io)?;
        if !metadata.file_type().is_dir() {
            return Err(CliError::new(format!(
                "{build_mode} bundle target is not a directory: {}",
                bundle.display()
            )));
        }
        require_regular_file(&bundle.join("workspace.path"))?;
        fs::rename(&bundle, &backup).map_err(CliError::io)?;
    }
    if let Err(error) = fs::rename(staging.path(), &bundle) {
        if backup.exists() && !bundle.exists() {
            let _ = fs::rename(&backup, &bundle);
        }
        return Err(CliError::new(format!(
            "could not activate debug bundle {}: {error}",
            bundle.display()
        )));
    }
    staging.preserve();
    if backup.exists() {
        fs::remove_dir_all(&backup).map_err(CliError::io)?;
    }
    previous.preserve();
    fs::remove_dir_all(previous.path()).map_err(CliError::io)?;

    println!(
        "{}",
        match runtime {
            PreparedRuntime::Debug => format!(
                "Prepared Denial live UI bundle:\n  {}\n\nSelect this workspace in Settings > Developer, then enable live UI development.",
                bundle.display()
            ),
            PreparedRuntime::Profile => format!(
                "Prepared Denial optimized AOT profile bundle:\n  {}\n\nActivate it with: denialctl ui profile",
                bundle.display()
            ),
        }
    );
    Ok(())
}

fn prepare_destinations(
    paths: &DevelopmentPaths,
    configured_bundle: &Path,
    label: &str,
) -> Result<(PathBuf, PathBuf), CliError> {
    fs::create_dir_all(&paths.build_root).map_err(CliError::io)?;
    let build_root = fs::canonicalize(&paths.build_root).map_err(CliError::io)?;
    let bundle = lexical_absolute(configured_bundle)?;
    if !bundle.starts_with(&build_root) || bundle == build_root {
        return Err(CliError::new(format!(
            "{label} bundle must be below the build root {}: {}",
            build_root.display(),
            bundle.display()
        )));
    }
    let parent = bundle
        .parent()
        .ok_or_else(|| CliError::new(format!("{label} bundle has no parent directory")))?;
    fs::create_dir_all(parent).map_err(CliError::io)?;
    let parent = fs::canonicalize(parent).map_err(CliError::io)?;
    let name = bundle
        .file_name()
        .ok_or_else(|| CliError::new(format!("{label} bundle has no file name")))?;
    Ok((build_root, parent.join(name)))
}

fn lexical_absolute(path: &Path) -> Result<PathBuf, CliError> {
    require_absolute("path", path)?;
    let mut normalized = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(value) => normalized.push(value),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(CliError::new(format!(
                        "path escapes the filesystem root: {}",
                        path.display()
                    )));
                }
            }
            Component::Prefix(_) => {
                return Err(CliError::new("Windows path prefixes are unsupported"));
            }
        }
    }
    Ok(normalized)
}

fn validate_toolchain(paths: &DevelopmentPaths) -> Result<(), CliError> {
    for required in [
        &paths.flutter_tool_runtime,
        &paths.flutter_tool,
        &paths.icu,
        &paths
            .flutter_root
            .join("bin/cache/pkg/sky_engine/lib/_embedder.yaml"),
        &paths
            .flutter_root
            .join("bin/cache/pkg/sky_engine/lib/ui/ui.dart"),
    ] {
        require_regular_file(required)?;
    }
    require_regular_file(&paths.pub_cache_seed.join(PUB_CACHE_GENERATION_MARKER))
}

fn prepare_pub_cache(paths: &DevelopmentPaths) -> Result<(), CliError> {
    let source_marker = paths.pub_cache_seed.join(PUB_CACHE_GENERATION_MARKER);
    require_regular_file(&source_marker)?;
    let expected = fs::read(&source_marker).map_err(CliError::io)?;
    if String::from_utf8_lossy(&expected).trim() != FLUTTER_GENERATION {
        return Err(CliError::new(format!(
            "packaged dependency seed does not match Flutter generation {FLUTTER_GENERATION}"
        )));
    }
    let installed_marker = paths.pub_cache.join(PUB_CACHE_GENERATION_MARKER);
    if fs::read(&installed_marker).is_ok_and(|actual| actual == expected) {
        return Ok(());
    }

    let parent = paths
        .pub_cache
        .parent()
        .ok_or_else(|| CliError::new("user Pub cache has no parent directory"))?;
    fs::create_dir_all(parent).map_err(CliError::io)?;
    let mut staging = TemporaryDirectory::create(parent, ".pub-cache")?;
    copy_tree(&paths.pub_cache_seed, staging.path())?;

    let mut previous = TemporaryDirectory::create(parent, ".previous-pub-cache")?;
    let backup = previous.path().join("cache");
    if fs::symlink_metadata(&paths.pub_cache).is_ok() {
        let metadata = fs::symlink_metadata(&paths.pub_cache).map_err(CliError::io)?;
        if !metadata.file_type().is_dir() {
            return Err(CliError::new(format!(
                "user Pub cache target is not a directory: {}",
                paths.pub_cache.display()
            )));
        }
        require_regular_file(&installed_marker).map_err(|_| {
            CliError::new(format!(
                "refusing to replace an unmarked directory as the Denial Pub cache: {}",
                paths.pub_cache.display()
            ))
        })?;
        fs::rename(&paths.pub_cache, &backup).map_err(CliError::io)?;
    }
    if let Err(error) = fs::rename(staging.path(), &paths.pub_cache) {
        if backup.exists() && !paths.pub_cache.exists() {
            let _ = fs::rename(&backup, &paths.pub_cache);
        }
        return Err(CliError::new(format!(
            "could not activate the Denial Pub cache {}: {error}",
            paths.pub_cache.display()
        )));
    }
    staging.preserve();
    if backup.exists() {
        fs::remove_dir_all(&backup).map_err(CliError::io)?;
    }
    previous.preserve();
    fs::remove_dir_all(previous.path()).map_err(CliError::io)?;
    Ok(())
}

fn validate_debug_engine(path: &Path) -> Result<(), CliError> {
    validate_engine(path, "debug")
}

fn validate_engine(path: &Path, label: &str) -> Result<(), CliError> {
    require_regular_file(path)?;
    let bytes = fs::read(path).map_err(CliError::io)?;
    for symbol in [
        b"FlutterEngineGetProcAddresses\0".as_slice(),
        b"DenialFlutterEngineScheduleFrameForExternalTextures\0".as_slice(),
    ] {
        if !contains_bytes(&bytes, symbol) {
            return Err(CliError::new(format!(
                "{label} engine does not export {}: {}",
                String::from_utf8_lossy(&symbol[..symbol.len() - 1]),
                path.display()
            )));
        }
    }
    Ok(())
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

fn require_regular_file(path: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CliError::new(format!("missing regular file {}: {error}", path.display()))
    })?;
    if metadata.file_type().is_file() {
        Ok(())
    } else {
        Err(CliError::new(format!(
            "expected a regular file: {}",
            path.display()
        )))
    }
}

fn remove_regular_file_if_present(path: &Path) -> Result<(), CliError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(CliError::io(error)),
    };
    if !metadata.file_type().is_file() {
        return Err(CliError::new(format!(
            "expected a regular generated file: {}",
            path.display()
        )));
    }
    fs::remove_file(path).map_err(CliError::io)
}

fn run_flutter(
    paths: &DevelopmentPaths,
    workspace: &Path,
    arguments: &[OsString],
    replace: bool,
) -> Result<(), CliError> {
    validate_toolchain(paths)?;
    prepare_pub_cache(paths)?;
    let mut process = flutter_process(paths, arguments);
    process.current_dir(workspace);
    if replace {
        let error = process.exec();
        Err(CliError::new(format!(
            "could not start the pinned Flutter tool: {error}"
        )))
    } else {
        let status = process.status().map_err(|error| {
            CliError::new(format!("could not start the pinned Flutter tool: {error}"))
        })?;
        if status.success() {
            Ok(())
        } else {
            Err(CliError::new(format!(
                "pinned Flutter tool exited with {status}"
            )))
        }
    }
}

fn flutter_process(paths: &DevelopmentPaths, arguments: &[OsString]) -> Process {
    let mut process = Process::new(&paths.flutter_tool_runtime);
    process
        .arg(&paths.flutter_tool)
        .arg("--suppress-analytics")
        .arg("--no-version-check")
        .args(arguments)
        .env("FLUTTER_ROOT", &paths.flutter_root)
        .env("FLUTTER_ALREADY_LOCKED", "true")
        .env("DART_SUPPRESS_ANALYTICS", "true")
        .env("FLUTTER_SUPPRESS_ANALYTICS", "true")
        .env("PUB_ENVIRONMENT", "denial_ui_development")
        .env("PUB_CACHE", &paths.pub_cache)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    process
}

fn run_flutter_passthrough(arguments: Vec<OsString>) -> Result<(), CliError> {
    let paths = DevelopmentPaths::resolve()?;
    let workspace = env::current_dir().map_err(CliError::io)?;
    let arguments = attach_with_browser_devtools(arguments);
    run_flutter(&paths, &workspace, &arguments, true)
}

fn attach_with_browser_devtools(mut arguments: Vec<OsString>) -> Vec<OsString> {
    if arguments.first().is_some_and(|value| value == "attach")
        && !arguments
            .iter()
            .any(|value| value == "--devtools" || value == "--no-devtools")
    {
        arguments.insert(1, OsString::from("--devtools"));
    }
    arguments
}

fn attach(workspace: &Path, profile: bool) -> Result<(), CliError> {
    let paths = DevelopmentPaths::resolve()?;
    let uri = read_vm_service_uri()?;
    let mut arguments = vec![OsString::from("attach"), OsString::from("--devtools")];
    if profile {
        arguments.push(OsString::from("--profile"));
    }
    arguments.extend([OsString::from("--debug-url"), OsString::from(uri)]);
    run_flutter(&paths, workspace, &arguments, true)
}

fn read_vm_service_uri() -> Result<String, CliError> {
    let path = vm_service_path().ok_or_else(|| {
        CliError::new("XDG_RUNTIME_DIR is unset; run this inside the Denial user session")
    })?;
    let metadata = fs::symlink_metadata(&path)
        .map_err(|_| CliError::new("live UI development is not exposing a Dart VM service"))?;
    if !metadata.file_type().is_file() {
        return Err(CliError::new(format!(
            "VM-service endpoint is not a regular file: {}",
            path.display()
        )));
    }
    if metadata.uid() != current_uid() {
        return Err(CliError::new(format!(
            "VM-service endpoint is not owned by the current user: {}",
            path.display()
        )));
    }
    if metadata.permissions().mode() & 0o777 != 0o600 {
        return Err(CliError::new(format!(
            "VM-service endpoint permissions are not 0600: {}",
            path.display()
        )));
    }
    let mut bytes = Vec::new();
    File::open(&path)
        .map_err(CliError::io)?
        .take(MAX_VM_SERVICE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(CliError::io)?;
    if bytes.len() as u64 > MAX_VM_SERVICE_BYTES {
        return Err(CliError::new("VM-service endpoint exceeds 64 KiB"));
    }
    let document: Value = serde_json::from_slice(&bytes)
        .map_err(|error| CliError::new(format!("malformed VM-service endpoint: {error}")))?;
    let uri = document
        .as_object()
        .filter(|object| object.len() == 1)
        .and_then(|object| object.get("uri"))
        .and_then(Value::as_str)
        .filter(|uri| valid_vm_service_uri(uri))
        .ok_or_else(|| CliError::new("VM-service endpoint contains an invalid URI"))?;
    Ok(uri.to_owned())
}

fn valid_vm_service_uri(uri: &str) -> bool {
    let Some(remainder) = uri.strip_prefix("http://127.0.0.1:") else {
        return false;
    };
    let Some((port, path)) = remainder.split_once('/') else {
        return false;
    };
    !port.is_empty()
        && port.bytes().all(|byte| byte.is_ascii_digit())
        && port.parse::<u16>().is_ok_and(|port| port != 0)
        && !path.is_empty()
        && !uri
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte == 0)
}

fn vm_service_path() -> Option<PathBuf> {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .map(|path| path.join("denial/flutter-vm-service.json"))
}

fn current_uid() -> u32 {
    fs::metadata("/proc/self")
        .map(|metadata| metadata.uid())
        .unwrap_or(u32::MAX)
}

fn cache_home() -> Option<PathBuf> {
    env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".cache"))
        })
}

fn config_home() -> Option<PathBuf> {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".config"))
        })
}

fn copy_tree(source: &Path, destination: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(source).map_err(CliError::io)?;
    if !metadata.file_type().is_dir() {
        return Err(CliError::new(format!(
            "asset source is not a directory: {}",
            source.display()
        )));
    }
    fs::create_dir_all(destination).map_err(CliError::io)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o755)).map_err(CliError::io)?;
    for entry in fs::read_dir(source).map_err(CliError::io)? {
        let entry = entry.map_err(CliError::io)?;
        let file_type = entry.file_type().map_err(CliError::io)?;
        let target = destination.join(entry.file_name());
        if file_type.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if file_type.is_file() {
            copy_regular_file(&entry.path(), &target, 0o644)?;
        } else {
            return Err(CliError::new(format!(
                "Flutter assets contain an unsupported entry: {}",
                entry.path().display()
            )));
        }
    }
    Ok(())
}

fn copy_regular_file(source: &Path, destination: &Path, mode: u32) -> Result<(), CliError> {
    require_regular_file(source)?;
    let parent = destination
        .parent()
        .ok_or_else(|| CliError::new("copy destination has no parent directory"))?;
    fs::create_dir_all(parent).map_err(CliError::io)?;
    fs::copy(source, destination).map_err(CliError::io)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(mode)).map_err(CliError::io)
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<(), CliError> {
    let parent = path
        .parent()
        .ok_or_else(|| CliError::new("private file has no parent directory"))?;
    fs::create_dir_all(parent).map_err(CliError::io)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(CliError::io)?;
    file.write_all(bytes).map_err(CliError::io)?;
    file.sync_all().map_err(CliError::io)
}

struct TemporaryDirectory {
    path: PathBuf,
    remove: bool,
}

impl TemporaryDirectory {
    fn create(parent: &Path, prefix: &str) -> Result<Self, CliError> {
        fs::create_dir_all(parent).map_err(CliError::io)?;
        for _ in 0..128 {
            let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!("{prefix}.{}.{}", std::process::id(), sequence));
            match fs::create_dir(&path) {
                Ok(()) => {
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                        .map_err(CliError::io)?;
                    return Ok(Self { path, remove: true });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(CliError::io(error)),
            }
        }
        Err(CliError::new(format!(
            "could not allocate a temporary directory below {}",
            parent.display()
        )))
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn preserve(&mut self) {
        self.remove = false;
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        if self.remove {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[derive(Debug)]
struct CliError {
    message: String,
    usage: bool,
}

impl CliError {
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

    fn io(error: std::io::Error) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)?;
        if self.usage {
            write!(formatter, "\nTry 'denial-ui --help'.")?;
        }
        Ok(())
    }
}

impl Error for CliError {}

#[cfg(test)]
mod tests {
    use super::{
        attach_with_browser_devtools, contains_bytes, is_flutter_passthrough_executable,
        lexical_absolute, valid_vm_service_uri,
    };
    use std::ffi::{OsStr, OsString};
    use std::path::{Path, PathBuf};

    #[test]
    fn normalizes_absolute_paths_without_touching_the_filesystem() {
        assert_eq!(
            lexical_absolute(Path::new("/tmp/a/../b/./bundle")).unwrap(),
            PathBuf::from("/tmp/b/bundle")
        );
    }

    #[test]
    fn accepts_only_authenticated_loopback_service_shapes() {
        assert!(valid_vm_service_uri("http://127.0.0.1:42781/9fR2vM0x=/"));
        assert!(!valid_vm_service_uri("http://0.0.0.0:42781/token/"));
        assert!(!valid_vm_service_uri("http://127.0.0.1:0/token/"));
        assert!(!valid_vm_service_uri("http://127.0.0.1:42/"));
    }

    #[test]
    fn finds_complete_binary_symbols() {
        assert!(contains_bytes(b"before\0symbol\0after", b"symbol\0"));
        assert!(!contains_bytes(b"symbolic", b"symbol\0"));
    }

    #[test]
    fn recognizes_both_installed_flutter_entry_points() {
        assert!(is_flutter_passthrough_executable(OsStr::new(
            "denial-flutter"
        )));
        assert!(is_flutter_passthrough_executable(OsStr::new("flutter")));
        assert!(!is_flutter_passthrough_executable(OsStr::new("denial-ui")));
    }

    #[test]
    fn enables_browser_devtools_for_attach_without_overriding_an_explicit_choice() {
        assert_eq!(
            attach_with_browser_devtools(vec![
                OsString::from("attach"),
                OsString::from("--machine"),
            ]),
            vec![
                OsString::from("attach"),
                OsString::from("--devtools"),
                OsString::from("--machine"),
            ]
        );
        assert_eq!(
            attach_with_browser_devtools(vec![
                OsString::from("attach"),
                OsString::from("--no-devtools"),
            ]),
            vec![OsString::from("attach"), OsString::from("--no-devtools"),]
        );
    }
}
