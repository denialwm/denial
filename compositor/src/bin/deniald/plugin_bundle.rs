//! Native validation and bounded startup recovery for compiled compositions.
//! This is not a plugin loader: the payload is one ordinary release AOT shell.
//!
//! Two rules decide whether a composition loads. It was built for this Denial
//! (Flutter generation and installed source identity), and the session's
//! engine accepts it, which is proven by starting it rather than predicted
//! from the engine's checksum. A composition carries no engine of its own.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Deserialize)]
struct Manifest {
    schema: u32,
    mode: String,
    platform: String,
    /// The engine the composition was compiled against. It explains a failed
    /// start; it never refuses one.
    #[serde(default)]
    engine_sha256: Option<String>,
    app_sha256: String,
    assets_sha256: String,
    flutter_generation: String,
    #[serde(default)]
    source_identity: serde_json::Value,
}

fn hash_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut hash = Sha256::new();
    let mut bytes = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut bytes).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        hash.update(&bytes[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn entries(root: &Path, output: &mut Vec<PathBuf>) -> Result<(), String> {
    for item in fs::read_dir(root).map_err(|e| e.to_string())? {
        let path = item.map_err(|e| e.to_string())?.path();
        let metadata = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        if metadata.file_type().is_symlink() || (!metadata.is_file() && !metadata.is_dir()) {
            return Err(format!(
                "bundle contains a link or special file: {}",
                path.display()
            ));
        }
        if metadata.permissions().mode() & 0o222 != 0 {
            return Err(format!(
                "bundle is not sealed read-only: {}",
                path.display()
            ));
        }
        if metadata.is_dir() {
            entries(&path, output)?;
        }
        output.push(path);
    }
    Ok(())
}

// Same byte-level format as the manager's treeDigest, including directory names.
fn hash_tree(root: &Path) -> Result<String, String> {
    let mut paths = Vec::new();
    entries(root, &mut paths)?;
    paths.sort();
    let mut hash = Sha256::new();
    for path in paths {
        let relative = path
            .strip_prefix(root)
            .map_err(|e| e.to_string())?
            .to_str()
            .ok_or("bundle filenames must be UTF-8")?;
        hash.update(relative.as_bytes());
        hash.update([0]);
        if path.is_file() {
            hash.update(format!("file:{}\n", hash_file(&path)?));
        } else {
            hash.update(b"directory\n");
        }
    }
    Ok(format!("{:x}", hash.finalize()))
}

/// Why a sealed composition has to be rebuilt: it was built for another
/// release, or it did not start on an engine other than the one it was
/// compiled against. Every other rejection means a damaged or unsupported
/// bundle.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum UpdateReason {
    FlutterGeneration,
    Source,
    Engine,
}

#[derive(Debug)]
pub(super) struct Rejection {
    pub(super) message: String,
    pub(super) update: Option<UpdateReason>,
}

impl From<String> for Rejection {
    fn from(message: String) -> Self {
        Self {
            message,
            update: None,
        }
    }
}

impl From<&str> for Rejection {
    fn from(message: &str) -> Self {
        message.to_owned().into()
    }
}

/// The installed shell's source identity, or `None` for a development bundle
/// without one.
pub(super) fn installed_source_identity(
    official: &Path,
) -> Result<Option<serde_json::Value>, String> {
    let source_marker = official.join(".denial-ui-source.json");
    if !source_marker.exists() {
        return Ok(None);
    }
    let installed: serde_json::Value =
        serde_json::from_reader(File::open(&source_marker).map_err(|e| e.to_string())?)
            .map_err(|e| format!("invalid installed source identity: {e}"))?;
    Ok(installed.is_object().then_some(installed))
}

pub(super) fn validate(bundle: &Path, official: &Path) -> Result<PathBuf, String> {
    validate_bundle(bundle, official).map_err(|rejection| rejection.message)
}

pub(super) fn validate_bundle(bundle: &Path, official: &Path) -> Result<PathBuf, Rejection> {
    if !bundle.is_absolute() {
        return Err("plugin bundle path must be absolute".into());
    }
    let bundle = fs::canonicalize(bundle).map_err(|e| e.to_string())?;
    if fs::metadata(&bundle)
        .map_err(|e| e.to_string())?
        .permissions()
        .mode()
        & 0o222
        != 0
    {
        return Err("plugin bundle directory is not sealed read-only".into());
    }
    let manifest_path = bundle.join("denial-plugin-bundle.json");
    if fs::metadata(&manifest_path)
        .map_err(|e| e.to_string())?
        .len()
        > 64 * 1024
    {
        return Err("plugin bundle manifest exceeds 64 KiB".into());
    }
    let manifest: Manifest =
        serde_json::from_reader(File::open(&manifest_path).map_err(|e| e.to_string())?)
            .map_err(|e| format!("invalid plugin bundle manifest: {e}"))?;
    let platform = match std::env::consts::ARCH {
        "x86_64" => "linux-x64",
        "aarch64" => "linux-arm64",
        _ => "unsupported",
    };
    if manifest.schema != 1 || manifest.mode != "release" || manifest.platform != platform {
        return Err(
            "plugin bundle mode, architecture, or Flutter generation is incompatible".into(),
        );
    }
    if manifest.flutter_generation != denial_core::FLUTTER_ENGINE_ABI {
        return Err(Rejection {
            message: "plugin bundle mode, architecture, or Flutter generation is incompatible"
                .into(),
            update: Some(UpdateReason::FlutterGeneration),
        });
    }
    let source_marker = official.join(".denial-ui-source.json");
    if source_marker.exists() {
        let Some(installed) = installed_source_identity(official)? else {
            return Err("plugin bundle source does not match installed Denial; prepare the matching build tools and rebuild".into());
        };
        if manifest.source_identity != installed {
            // The bundle itself may be intact. It was sealed for the identity
            // of another installed release, which a rebuild can replace.
            return Err(Rejection {
                message: "plugin bundle source does not match installed Denial; prepare the matching build tools and rebuild".into(),
                update: Some(UpdateReason::Source),
            });
        }
    }
    let mut all = Vec::new();
    entries(&bundle, &mut all)?;
    // The engine is not compared: the session's engine runs every
    // composition, and starting it is the proof that it accepts this one.
    if hash_file(&bundle.join("lib/libapp.so"))? != manifest.app_sha256 {
        return Err("plugin bundle checksum mismatch: lib/libapp.so".into());
    }
    if hash_tree(&bundle.join("data/flutter_assets"))? != manifest.assets_sha256 {
        return Err("plugin bundle assets checksum mismatch".into());
    }
    Ok(bundle)
}

/// Whether [bundle] was compiled against an engine other than the session's.
/// False when either side cannot tell; this only explains a failed start.
pub(super) fn built_for_another_engine(bundle: &Path, official: &Path) -> bool {
    let built = File::open(bundle.join("denial-plugin-bundle.json"))
        .ok()
        .and_then(|file| serde_json::from_reader::<_, Manifest>(file).ok())
        .and_then(|manifest| manifest.engine_sha256);
    let official_engine = if official.join("lib/libflutter_engine.so").is_file() {
        official.join("lib/libflutter_engine.so")
    } else {
        official.join("libflutter_engine.so")
    };
    match (built, hash_file(&official_engine)) {
        (Some(built), Ok(running)) => built != running,
        _ => false,
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
struct Selection {
    schema: u32,
    selected: Option<PathBuf>,
    previous: Option<PathBuf>,
    pending: Option<PathBuf>,
    last_start_ms: u64,
    recent_starts: u32,
}

/// The command that rebuilds a composition left behind by a Denial update.
/// The plugin manager is a separate package; without it the packaged shell
/// simply stays active.
pub(super) fn resume_arguments() -> Option<Vec<String>> {
    let configured = std::env::var_os("DENIAL_PLUGINS_BINARY")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.is_file());
    let binary = configured.or_else(|| {
        let paths = std::env::var_os("PATH")?;
        std::env::split_paths(&paths)
            .filter(|directory| directory.is_absolute())
            .map(|directory| directory.join("denial-plugins"))
            .find(|path| path.is_file())
    })?;
    Some(vec![
        binary.into_os_string().into_string().ok()?,
        "resume".into(),
    ])
}

pub(super) struct PluginSelection {
    path: Option<PathBuf>,
    value: Selection,
    /// The confirmed composition whose start at login the previous process
    /// did not survive.
    interrupted: Option<PathBuf>,
}

impl PluginSelection {
    pub(super) fn open(path: Option<PathBuf>) -> Result<Self, String> {
        let value = if let Some(path) = path.as_deref().filter(|p| p.exists()) {
            let bytes = fs::read(path).map_err(|e| e.to_string())?;
            if bytes.len() > 64 * 1024 {
                return Err("plugin selection exceeds 64 KiB".into());
            }
            let value: Selection = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            if value.schema != 1 {
                return Err("unsupported plugin selection schema".into());
            }
            value
        } else {
            Selection {
                schema: 1,
                ..Selection::default()
            }
        };
        let mut selection = Self {
            path,
            value,
            interrupted: None,
        };
        // A prior process died while preparing or validating startup. Never
        // retry that candidate automatically in the next login.
        if let Some(pending) = selection.value.pending.take() {
            if selection.value.selected.as_ref() == Some(&pending) {
                selection.interrupted = Some(pending);
            }
            if selection.value.selected.is_some() {
                selection.value.previous = selection.value.selected.take();
            }
            selection.persist()?;
        }
        Ok(selection)
    }

    pub(super) fn empty() -> Self {
        Self {
            path: None,
            value: Selection {
                schema: 1,
                ..Selection::default()
            },
            interrupted: None,
        }
    }

    pub(super) fn interrupted(&self) -> Option<&Path> {
        self.interrupted.as_deref()
    }

    pub(super) fn selected(&self) -> Option<&Path> {
        self.value.selected.as_deref()
    }
    pub(super) fn previous(&self) -> Option<&Path> {
        self.value.previous.as_deref()
    }

    pub(super) fn begin(&mut self, bundle: &Path, automatic: bool) -> Result<(), String> {
        let before = self.value.clone();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_millis() as u64;
        if automatic && now.saturating_sub(self.value.last_start_ms) < 60_000 {
            self.value.recent_starts = self.value.recent_starts.saturating_add(1);
        } else {
            self.value.recent_starts = 1;
        }
        if automatic && self.value.recent_starts > 2 {
            self.restore()?;
            return Err(
                "repeated custom shell startups were stopped; packaged shell selected".into(),
            );
        }
        self.value.last_start_ms = now;
        self.value.pending = Some(bundle.to_owned());
        self.save_or_restore(before)
    }

    pub(super) fn confirm(&mut self) -> Result<(), String> {
        let before = self.value.clone();
        if let Some(bundle) = self.value.pending.take() {
            if self.value.selected.as_ref() != Some(&bundle) {
                if let Some(previous) = self.value.selected.replace(bundle) {
                    self.value.previous = Some(previous);
                }
            }
            self.save_or_restore(before)?;
        }
        Ok(())
    }

    pub(super) fn reject(&mut self) -> Result<(), String> {
        if self.value.pending.is_none() {
            return Ok(());
        }
        let before = self.value.clone();
        if self.value.pending.is_some() && self.value.pending == self.value.selected {
            self.value.selected = None;
        }
        self.value.pending = None;
        self.save_or_restore(before)
    }

    pub(super) fn restore(&mut self) -> Result<(), String> {
        if self.value.selected.is_none() && self.value.pending.is_none() {
            return Ok(());
        }
        let before = self.value.clone();
        if self.value.selected.is_some() {
            self.value.previous = self.value.selected.take();
        }
        self.value.pending = None;
        self.save_or_restore(before)
    }

    fn save_or_restore(&mut self, before: Selection) -> Result<(), String> {
        let result = self.persist();
        if result.is_err() {
            self.value = before;
        }
        result
    }

    fn persist(&self) -> Result<(), String> {
        let Some(path) = self.path.as_ref() else {
            return Err("plugin selection storage is unavailable".into());
        };
        let parent = path
            .parent()
            .ok_or("plugin selection has no parent directory")?;
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let temp = path.with_extension(format!("{}.tmp", std::process::id()));
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec_pretty(&self.value).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(temp, path).map_err(|e| e.to_string())?;
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())
    }
}

/// Sealed bundle fixtures shared by native validation and controller tests.
#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    pub(crate) struct Fixture(pub(crate) PathBuf);
    impl Fixture {
        pub(crate) fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "denial-plugin-native-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        pub(crate) fn state(&self) -> PathBuf {
            self.0.join("selection.json")
        }
        pub(crate) fn bundle(&self) -> (PathBuf, PathBuf) {
            let bundle = self.0.join("bundle");
            let official = self.0.join("official");
            fs::create_dir_all(bundle.join("lib")).unwrap();
            fs::create_dir_all(bundle.join("data/flutter_assets/nested")).unwrap();
            fs::create_dir_all(official.join("lib")).unwrap();
            fs::write(official.join("lib/libflutter_engine.so"), b"engine").unwrap();
            fs::write(bundle.join("lib/libapp.so"), b"app").unwrap();
            fs::write(bundle.join("data/flutter_assets/nested/asset"), b"asset").unwrap();
            seal(&bundle.join("data/flutter_assets"));
            let manifest = serde_json::json!({
                "schema": 1, "mode": "release", "platform": if cfg!(target_arch = "aarch64") { "linux-arm64" } else { "linux-x64" },
                "flutter_generation": denial_core::FLUTTER_ENGINE_ABI,
                "engine_sha256": hash_file(&official.join("lib/libflutter_engine.so")).unwrap(),
                "app_sha256": hash_file(&bundle.join("lib/libapp.so")).unwrap(),
                "assets_sha256": hash_tree(&bundle.join("data/flutter_assets")).unwrap(),
            });
            fs::write(
                bundle.join("denial-plugin-bundle.json"),
                serde_json::to_vec(&manifest).unwrap(),
            )
            .unwrap();
            seal(&bundle);
            (bundle, official)
        }
    }
    pub(crate) fn seal(path: &Path) {
        if path.is_dir() {
            for entry in fs::read_dir(path).unwrap() {
                seal(&entry.unwrap().path());
            }
        }
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if path.is_dir() { 0o555 } else { 0o444 }),
        )
        .unwrap();
    }
    pub(crate) fn unseal(path: &Path) {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        if path.is_dir() {
            for entry in fs::read_dir(path).unwrap() {
                unseal(&entry.unwrap().path());
            }
        }
    }
    pub(crate) fn set_manifest_field(bundle: &Path, key: &str, value: serde_json::Value) {
        unseal(bundle);
        let path = bundle.join("denial-plugin-bundle.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        manifest[key] = value;
        fs::write(path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        seal(bundle);
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            unseal(&self.0);
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;
    #[test]
    #[ignore = "requires an actual manager-built sealed bundle and packaged engine"]
    fn validates_manager_built_bundle() {
        let bundle = std::env::var_os("DENIAL_PLUGIN_TEST_BUNDLE").expect("bundle fixture");
        let official = std::env::var_os("DENIAL_PLUGIN_TEST_OFFICIAL").expect("official fixture");
        validate(Path::new(&bundle), Path::new(&official)).unwrap();
    }

    #[test]
    fn validates_sealed_bundle_on_any_engine_and_rejects_changed_assets() {
        let fixture = Fixture::new();
        let (bundle, official) = fixture.bundle();
        assert_eq!(validate(&bundle, &official).unwrap(), bundle);
        assert!(!built_for_another_engine(&bundle, &official));
        // Another engine is tried, not refused; the difference is only known.
        fs::write(official.join("lib/libflutter_engine.so"), b"other-engine").unwrap();
        assert_eq!(validate(&bundle, &official).unwrap(), bundle);
        assert!(built_for_another_engine(&bundle, &official));
        fs::write(official.join("lib/libflutter_engine.so"), b"engine").unwrap();
        let asset = bundle.join("data/flutter_assets/nested/asset");
        fs::set_permissions(&asset, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            validate(&bundle, &official)
                .unwrap_err()
                .contains("read-only")
        );
        fs::write(&asset, b"corrupt").unwrap();
        seal(&asset);
        assert!(
            validate(&bundle, &official)
                .unwrap_err()
                .contains("assets checksum")
        );
    }

    #[test]
    fn installed_source_identity_must_match_even_with_the_same_engine() {
        let fixture = Fixture::new();
        let (bundle, official) = fixture.bundle();
        let identity =
            serde_json::json!({"source_revision": "installed", "source_sha256": "exact-inputs"});
        fs::write(
            official.join(".denial-ui-source.json"),
            serde_json::to_vec(&identity).unwrap(),
        )
        .unwrap();
        assert!(
            validate(&bundle, &official)
                .unwrap_err()
                .contains("source does not match")
        );
        unseal(&bundle);
        let path = bundle.join("denial-plugin-bundle.json");
        let mut manifest: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        manifest["source_identity"] = identity;
        fs::write(path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        seal(&bundle);
        assert_eq!(validate(&bundle, &official).unwrap(), bundle);
        fs::write(
            official.join(".denial-ui-source.json"),
            b"{\"source_revision\":\"new-release\"}",
        )
        .unwrap();
        assert!(
            validate(&bundle, &official)
                .unwrap_err()
                .contains("source does not match")
        );
    }

    #[test]
    fn only_another_installed_release_counts_as_an_update() {
        let fixture = Fixture::new();
        let (bundle, official) = fixture.bundle();
        let previous = serde_json::json!({"source_revision": "0.2.1"});
        set_manifest_field(&bundle, "source_identity", previous.clone());
        fs::write(
            official.join(".denial-ui-source.json"),
            serde_json::to_vec(&previous).unwrap(),
        )
        .unwrap();
        assert!(validate_bundle(&bundle, &official).is_ok());

        // An engine experiment keeps the installed source identity: the
        // composition is still loaded, on the experimental engine.
        fs::write(official.join("lib/libflutter_engine.so"), b"experiment").unwrap();
        assert!(validate_bundle(&bundle, &official).is_ok());

        fs::write(
            official.join(".denial-ui-source.json"),
            b"{\"source_revision\":\"0.3.0\"}",
        )
        .unwrap();
        let rejection = validate_bundle(&bundle, &official).unwrap_err();
        assert!(rejection.message.contains("source does not match"));
        assert_eq!(rejection.update, Some(UpdateReason::Source));

        set_manifest_field(
            &bundle,
            "flutter_generation",
            serde_json::json!("3.44.7.denial1"),
        );
        assert_eq!(
            validate_bundle(&bundle, &official).unwrap_err().update,
            Some(UpdateReason::FlutterGeneration)
        );
    }

    #[test]
    fn damaged_or_unsupported_bundles_are_not_updates() {
        let fixture = Fixture::new();
        let (bundle, official) = fixture.bundle();
        set_manifest_field(&bundle, "mode", serde_json::json!("profile"));
        assert_eq!(
            validate_bundle(&bundle, &official).unwrap_err().update,
            None
        );
        set_manifest_field(&bundle, "mode", serde_json::json!("release"));
        unseal(&bundle);
        fs::write(bundle.join("lib/libapp.so"), b"changed").unwrap();
        seal(&bundle);
        let rejection = validate_bundle(&bundle, &official).unwrap_err();
        assert!(rejection.message.contains("checksum mismatch"));
        assert_eq!(rejection.update, None);
    }

    #[test]
    fn pending_startup_is_never_retried_after_a_process_exit() {
        let fixture = Fixture::new();
        let mut state = PluginSelection::open(Some(fixture.state())).unwrap();
        state.begin(Path::new("/working"), false).unwrap();
        state.confirm().unwrap();
        state.begin(Path::new("/broken"), false).unwrap();
        let recovered = PluginSelection::open(Some(fixture.state())).unwrap();
        assert_eq!(recovered.selected(), None);
        assert_eq!(recovered.previous(), Some(Path::new("/working")));
        // A composition that was only requested is not the user's
        // confirmed one.
        assert_eq!(recovered.interrupted(), None);
    }

    #[test]
    fn an_interrupted_start_of_the_confirmed_composition_is_remembered_once() {
        let fixture = Fixture::new();
        let mut state = PluginSelection::open(Some(fixture.state())).unwrap();
        state.begin(Path::new("/working"), false).unwrap();
        state.confirm().unwrap();
        state.begin(Path::new("/working"), true).unwrap();
        let recovered = PluginSelection::open(Some(fixture.state())).unwrap();
        assert_eq!(recovered.selected(), None);
        assert_eq!(recovered.previous(), Some(Path::new("/working")));
        assert_eq!(recovered.interrupted(), Some(Path::new("/working")));
        let later = PluginSelection::open(Some(fixture.state())).unwrap();
        assert_eq!(later.interrupted(), None);
    }

    #[test]
    fn only_confirmation_promotes_candidates_and_retains_rollback() {
        let fixture = Fixture::new();
        let mut state = PluginSelection::open(Some(fixture.state())).unwrap();
        state.begin(Path::new("/first"), false).unwrap();
        assert_eq!(state.selected(), None);
        state.confirm().unwrap();
        state.begin(Path::new("/second"), false).unwrap();
        assert_eq!(state.selected(), Some(Path::new("/first")));
        state.confirm().unwrap();
        assert_eq!(state.previous(), Some(Path::new("/first")));
        assert_eq!(state.selected(), Some(Path::new("/second")));
        state.restore().unwrap();
        let reloaded = PluginSelection::open(Some(fixture.state())).unwrap();
        assert_eq!(reloaded.selected(), None);
        assert_eq!(reloaded.previous(), Some(Path::new("/second")));
    }

    #[test]
    fn repeated_starts_are_bounded_even_if_a_frame_was_produced() {
        let fixture = Fixture::new();
        let mut state = PluginSelection::open(Some(fixture.state())).unwrap();
        state.begin(Path::new("/crashing"), false).unwrap();
        state.confirm().unwrap();
        state.begin(Path::new("/crashing"), true).unwrap();
        state.confirm().unwrap();
        assert!(state.begin(Path::new("/crashing"), true).is_err());
        assert_eq!(state.selected(), None);
    }
}
