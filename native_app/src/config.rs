use std::{env, ffi::CString, path::PathBuf, sync::Arc};

use denial_flutter_engine::{DartRuntimeMode, EngineLibrary, EngineProject};

pub const HELP: &str = "denial-app --bundle DIR --engine FILE [--app-id ID] [--title TITLE]
           [--width PIXELS] [--height PIXELS] [--overlay]
           [--check] [-- DART_ARGS...]

Runs one existing release Flutter AOT bundle as a native Wayland application.
--engine defaults to $DENIAL_FLUTTER_BUNDLE/lib/libflutter_engine.so.
--overlay presents a centered, undecorated layer-shell overlay that takes
exclusive keyboard focus, instead of a window. Its namespace is the app ID.
--check validates the bundle and raw engine ABI without opening a window.
Dart arguments follow --. Installed app launchers select their adjacent bundle automatically.";

pub struct Config {
    pub project: EngineProject,
    pub app_id: String,
    pub title: String,
    pub width: u32,
    pub height: u32,
    pub overlay: bool,
    pub check: bool,
    pub dart_arguments: Vec<CString>,
}

impl Config {
    pub fn parse() -> Result<Option<Self>, String> {
        let executable = env::current_exe().map_err(|e| e.to_string())?;
        let app_name = executable
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let installed_app = match app_name {
            "denial-settings" => Some(("dev.denial.Settings", "Settings", 900, 620)),
            "denial-plugin-manager" => {
                Some(("dev.denial.PluginManager", "Denial Plugins", 980, 700))
            }
            _ => None,
        };
        let mut bundle = installed_app.map(|_| executable.parent().unwrap().to_path_buf());
        let mut engine = env::var_os("DENIAL_FLUTTER_BUNDLE")
            .map(|p| PathBuf::from(p).join("lib/libflutter_engine.so"));
        let mut app_id = "org.denial.NativeApp".to_owned();
        let mut title = "Denial app".to_owned();
        let (mut width, mut height) = (1000, 700);
        let mut overlay = false;
        let mut check = false;
        let mut dart_arguments = Vec::new();
        if let Some((id, app_title, w, h)) = installed_app {
            app_id = id.into();
            title = app_title.into();
            width = w;
            height = h;
            engine = Some(
                executable
                    .parent()
                    .unwrap()
                    .join("lib/libflutter_engine.so"),
            );
        }
        let mut args = env::args_os().skip(1);
        while let Some(arg) = args.next() {
            let arg = arg.to_str().ok_or("option is not UTF-8")?;
            if arg == "--" {
                for value in args {
                    dart_arguments.push(
                        CString::new(value.to_str().ok_or("Dart argument is not UTF-8")?)
                            .map_err(|_| "Dart argument contains NUL")?,
                    );
                }
                break;
            }
            if app_name == "denial-settings"
                && (matches!(arg, "--welcome" | "--autostart") || arg.starts_with("--page="))
            {
                if arg == "--welcome" {
                    title = "Welcome to Denial".into();
                    app_id = "dev.denial.Welcome".into();
                }
                dart_arguments.push(CString::new(arg).map_err(|_| "Dart argument contains NUL")?);
                continue;
            }
            if matches!(arg, "--help" | "-h") {
                println!("{HELP}");
                return Ok(None);
            }
            if arg == "--check" {
                check = true;
                continue;
            }
            if arg == "--overlay" {
                overlay = true;
                continue;
            }
            if !matches!(
                arg,
                "--bundle" | "--engine" | "--app-id" | "--title" | "--width" | "--height"
            ) {
                return Err(format!("unknown option: {arg}"));
            }
            let value = args
                .next()
                .ok_or_else(|| format!("missing value for {arg}"))?;
            match arg {
                "--bundle" => bundle = Some(PathBuf::from(value)),
                "--engine" => engine = Some(PathBuf::from(value)),
                "--app-id" => app_id = value.into_string().map_err(|_| "app ID is not UTF-8")?,
                "--title" => title = value.into_string().map_err(|_| "title is not UTF-8")?,
                "--width" | "--height" => {
                    let n = value
                        .to_str()
                        .and_then(|s| s.parse::<u32>().ok())
                        .filter(|n| (1..=16_384).contains(n))
                        .ok_or("window dimensions must be between 1 and 16384")?;
                    if arg == "--width" {
                        width = n;
                    } else {
                        height = n;
                    }
                }
                _ => unreachable!(),
            }
        }
        if dart_arguments
            .iter()
            .any(|arg| arg.as_bytes() == b"--welcome")
            && dart_arguments
                .iter()
                .any(|arg| arg.as_bytes() == b"--autostart")
        {
            let config = env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .or_else(|| env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")));
            if config.is_some_and(|p| p.join("denial/welcome").is_file()) {
                return Ok(None);
            }
        }
        let bundle = bundle
            .ok_or("--bundle is required")?
            .canonicalize()
            .map_err(|e| e.to_string())?;
        let engine_library = engine
            .ok_or("--engine or DENIAL_FLUTTER_BUNDLE is required")?
            .canonicalize()
            .map_err(|e| e.to_string())?;
        let project = EngineProject {
            engine_library,
            assets: bundle.join("data/flutter_assets"),
            icu_data: bundle.join("data/icudtl.dat"),
            runtime: DartRuntimeMode::Aot,
            aot_library: Some(bundle.join("lib/libapp.so")),
            resource_cache_max_bytes_threshold: 64 * 1024 * 1024,
            float_color: false,
        };
        for path in [
            &project.assets,
            &project.icu_data,
            project.aot_library.as_ref().unwrap(),
        ] {
            if !path.exists() {
                return Err(format!("missing bundle component: {}", path.display()));
            }
        }
        Ok(Some(Self {
            project,
            app_id,
            title,
            width,
            height,
            overlay,
            check,
            dart_arguments,
        }))
    }

    pub fn check(&self) -> Result<(), Box<dyn std::error::Error>> {
        // Loading checks the raw embedder proc table and Denial extension ABI.
        // It starts no engine, connects to no display and creates no UI state.
        let library = Arc::new(EngineLibrary::load(&self.project.engine_library)?);
        if !library.runs_aot_compiled_dart_code() {
            return Err("a release AOT engine is required".into());
        }
        let _aot = library.create_aot_data(self.project.aot_library.as_ref().unwrap())?;
        println!(
            "Bundle, AOT image and raw engine ABI OK: {}",
            self.project.assets.display()
        );
        Ok(())
    }
}
