use std::collections::HashMap;
use std::error::Error;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use smithay::utils::{Logical, Point, Rectangle, Size};

const FORMAT_VERSION: u32 = 2;
const LEGACY_FORMAT_VERSION: u32 = 1;
const MAX_FILE_BYTES: u64 = 1024 * 1024;
const MAX_PLACEMENTS: usize = 256;
const MAX_APP_ID_BYTES: usize = 512;
const MAX_CONNECTOR_BYTES: usize = 256;
const MAX_WINDOW_DIMENSION: i32 = 16_384;

type StoreResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum WindowBackend {
    Wayland,
    X11,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct WindowPlacementState {
    #[serde(default)]
    pub maximized: bool,
    #[serde(default)]
    pub fullscreen: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct RestoredWindowPlacement {
    pub geometry: Rectangle<i32, Logical>,
    pub state: WindowPlacementState,
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub(super) struct WindowIdentity {
    backend: WindowBackend,
    #[serde(rename = "appId")]
    app_id: String,
}

impl WindowIdentity {
    pub(super) fn wayland(app_id: &str) -> Option<Self> {
        Self::new(WindowBackend::Wayland, app_id)
    }

    pub(super) fn x11(class: &str) -> Option<Self> {
        Self::new(WindowBackend::X11, class)
    }

    fn new(backend: WindowBackend, app_id: &str) -> Option<Self> {
        let app_id = app_id.trim();
        if app_id.is_empty()
            || app_id.len() > MAX_APP_ID_BYTES
            || app_id.chars().any(char::is_control)
        {
            return None;
        }
        Some(Self {
            backend,
            app_id: app_id.to_owned(),
        })
    }

    pub(super) fn backend(&self) -> WindowBackend {
        self.backend
    }

    pub(super) fn app_id(&self) -> &str {
        &self.app_id
    }

    fn valid(&self) -> bool {
        Self::new(self.backend, &self.app_id).as_ref() == Some(self)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct SavedWindowGeometry {
    output: String,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    #[serde(flatten)]
    state: WindowPlacementState,
    serial: u64,
}

impl SavedWindowGeometry {
    fn from_global(
        output: &str,
        output_geometry: Rectangle<i32, Logical>,
        geometry: Rectangle<i32, Logical>,
        state: WindowPlacementState,
        serial: u64,
    ) -> Option<Self> {
        if !valid_connector(output) || !valid_size(geometry.size) {
            return None;
        }
        Some(Self {
            output: output.to_owned(),
            x: geometry.loc.x.saturating_sub(output_geometry.loc.x),
            y: geometry.loc.y.saturating_sub(output_geometry.loc.y),
            width: geometry.size.w,
            height: geometry.size.h,
            state,
            serial,
        })
    }

    fn valid(&self) -> bool {
        valid_connector(&self.output)
            && valid_size(Size::from((self.width, self.height)))
            && self.serial > 0
    }

    fn restore(&self, output: Rectangle<i32, Logical>) -> Rectangle<i32, Logical> {
        let output_width = output.size.w.max(1);
        let output_height = output.size.h.max(1);
        let size = Size::from((
            self.width.clamp(1, output_width),
            self.height.clamp(1, output_height),
        ));
        let requested = Point::<i32, Logical>::from((
            output.loc.x.saturating_add(self.x),
            output.loc.y.saturating_add(self.y),
        ));
        let maximum_x = output
            .loc
            .x
            .saturating_add(output_width.saturating_sub(size.w));
        let maximum_y = output
            .loc
            .y
            .saturating_add(output_height.saturating_sub(size.h));
        Rectangle::new(
            Point::from((
                requested.x.clamp(output.loc.x, maximum_x),
                requested.y.clamp(output.loc.y, maximum_y),
            )),
            size,
        )
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct PersistedPlacement {
    #[serde(flatten)]
    identity: WindowIdentity,
    #[serde(flatten)]
    geometry: SavedWindowGeometry,
}

#[derive(Debug, Deserialize, Serialize)]
struct PlacementFile {
    version: u32,
    placements: Vec<PersistedPlacement>,
}

pub(super) struct WindowPlacementStore {
    path: Option<PathBuf>,
    placements: HashMap<WindowIdentity, SavedWindowGeometry>,
    next_serial: u64,
    dirty: bool,
}

impl WindowPlacementStore {
    pub(super) fn load(path: Option<PathBuf>) -> StoreResult<Self> {
        let Some(path) = path else {
            return Ok(Self::empty(None));
        };
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(Self::empty(Some(path)));
            }
            Err(error) => return Err(error.into()),
        };
        if file.metadata()?.len() > MAX_FILE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "window placement state exceeds the size limit",
            )
            .into());
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take(MAX_FILE_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "window placement state exceeds the size limit",
            )
            .into());
        }
        let persisted: PlacementFile = serde_json::from_slice(&bytes)?;
        if persisted.version != FORMAT_VERSION && persisted.version != LEGACY_FORMAT_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "unsupported window placement state version {}",
                    persisted.version
                ),
            )
            .into());
        }

        let loaded_legacy_format = persisted.version == LEGACY_FORMAT_VERSION;
        let mut records = persisted
            .placements
            .into_iter()
            .filter(|record| record.identity.valid() && record.geometry.valid())
            .collect::<Vec<_>>();
        records.sort_by_key(|record| record.geometry.serial);
        if records.len() > MAX_PLACEMENTS {
            records.drain(..records.len() - MAX_PLACEMENTS);
        }
        let mut placements = HashMap::with_capacity(records.len());
        let mut next_serial = 0;
        for record in records {
            next_serial = next_serial.max(record.geometry.serial);
            match placements.entry(record.identity) {
                std::collections::hash_map::Entry::Vacant(entry) => {
                    entry.insert(record.geometry);
                }
                std::collections::hash_map::Entry::Occupied(mut entry) => {
                    if record.geometry.serial >= entry.get().serial {
                        entry.insert(record.geometry);
                    }
                }
            }
        }
        Ok(Self {
            path: Some(path),
            placements,
            next_serial,
            dirty: loaded_legacy_format,
        })
    }

    pub(super) fn empty(path: Option<PathBuf>) -> Self {
        Self {
            path,
            placements: HashMap::new(),
            next_serial: 0,
            dirty: false,
        }
    }

    pub(super) fn len(&self) -> usize {
        self.placements.len()
    }

    pub(super) fn restored_placement(
        &self,
        identity: &WindowIdentity,
        outputs: impl IntoIterator<Item = (String, Rectangle<i32, Logical>)>,
        fallback_output: Rectangle<i32, Logical>,
    ) -> Option<RestoredWindowPlacement> {
        let saved = self.placements.get(identity)?;
        let output = outputs
            .into_iter()
            .find_map(|(connector, geometry)| (connector == saved.output).then_some(geometry))
            .unwrap_or(fallback_output);
        Some(RestoredWindowPlacement {
            geometry: saved.restore(output),
            state: saved.state,
        })
    }

    pub(super) fn remember(
        &mut self,
        identity: WindowIdentity,
        output: &str,
        output_geometry: Rectangle<i32, Logical>,
        geometry: Rectangle<i32, Logical>,
        state: WindowPlacementState,
    ) -> StoreResult<bool> {
        let serial = self.next_serial.saturating_add(1).max(1);
        let Some(saved) =
            SavedWindowGeometry::from_global(output, output_geometry, geometry, state, serial)
        else {
            return Ok(false);
        };
        let unchanged = self.placements.get(&identity).is_some_and(|current| {
            current.output == saved.output
                && current.x == saved.x
                && current.y == saved.y
                && current.width == saved.width
                && current.height == saved.height
                && current.state == saved.state
        });
        if unchanged && !self.dirty {
            return Ok(false);
        }
        if !unchanged {
            self.next_serial = serial;
            self.placements.insert(identity, saved);
            if self.placements.len() > MAX_PLACEMENTS
                && let Some(oldest) = self
                    .placements
                    .iter()
                    .min_by_key(|(identity, geometry)| (geometry.serial, *identity))
                    .map(|(identity, _)| identity.clone())
            {
                self.placements.remove(&oldest);
            }
            self.dirty = true;
        }
        self.persist()?;
        Ok(!unchanged)
    }

    fn persist(&mut self) -> StoreResult<()> {
        let Some(path) = self.path.clone() else {
            self.dirty = false;
            return Ok(());
        };
        let Some(parent) = path.parent() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "window placement state path has no parent",
            )
            .into());
        };
        fs::create_dir_all(parent)?;
        let mut records = self
            .placements
            .iter()
            .map(|(identity, geometry)| PersistedPlacement {
                identity: identity.clone(),
                geometry: geometry.clone(),
            })
            .collect::<Vec<_>>();
        records.sort_by(|left, right| left.identity.cmp(&right.identity));
        let mut payload = serde_json::to_vec_pretty(&PlacementFile {
            version: FORMAT_VERSION,
            placements: records,
        })?;
        payload.push(b'\n');
        if payload.len() as u64 > MAX_FILE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "serialized window placement state exceeds the size limit",
            )
            .into());
        }

        let temporary = temporary_path(&path);
        let result = (|| -> StoreResult<()> {
            let mut file = OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&payload)?;
            file.sync_all()?;
            fs::rename(&temporary, &path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        } else {
            self.dirty = false;
        }
        result
    }
}

pub(super) fn default_state_path() -> Option<PathBuf> {
    state_path(std::env::var_os("XDG_STATE_HOME"), std::env::var_os("HOME"))
}

fn state_path(xdg_state_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let state_root = xdg_state_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".local/state"))
        })?;
    Some(state_root.join("denial/window-placements.json"))
}

fn temporary_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map_or_else(|| OsString::from("window-placements.json"), OsString::from);
    name.push(format!(".tmp-{}", std::process::id()));
    path.with_file_name(name)
}

fn valid_connector(connector: &str) -> bool {
    !connector.is_empty()
        && connector.len() <= MAX_CONNECTOR_BYTES
        && !connector.chars().any(char::is_control)
}

fn valid_size(size: Size<i32, Logical>) -> bool {
    (1..=MAX_WINDOW_DIMENSION).contains(&size.w) && (1..=MAX_WINDOW_DIMENSION).contains(&size.h)
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(1);

    fn test_path(label: &str) -> PathBuf {
        let sequence = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!(
                "denial-window-placement-{label}-{}-{sequence}",
                std::process::id()
            ))
            .join("window-placements.json")
    }

    #[test]
    fn state_path_prefers_an_absolute_xdg_state_home() {
        assert_eq!(
            state_path(
                Some(OsString::from("/state")),
                Some(OsString::from("/home/test"))
            ),
            Some(PathBuf::from("/state/denial/window-placements.json"))
        );
        assert_eq!(
            state_path(
                Some(OsString::from("relative")),
                Some(OsString::from("/home/test"))
            ),
            Some(PathBuf::from(
                "/home/test/.local/state/denial/window-placements.json"
            ))
        );
        assert_eq!(state_path(None, None), None);
    }

    #[test]
    fn placement_round_trips_and_tracks_output_origin_changes() {
        let path = test_path("round-trip");
        let identity = WindowIdentity::wayland("org.example.Editor").unwrap();
        let output = Rectangle::new((2560, 0).into(), (2560, 1440).into());
        let geometry = Rectangle::new((3000, 220).into(), (900, 640).into());
        let state = WindowPlacementState {
            maximized: true,
            fullscreen: true,
        };
        let mut store = WindowPlacementStore::empty(Some(path.clone()));
        assert!(
            store
                .remember(
                    identity.clone(),
                    "DP-4",
                    output,
                    geometry,
                    WindowPlacementState::default(),
                )
                .unwrap()
        );
        assert!(
            store
                .remember(identity.clone(), "DP-4", output, geometry, state)
                .unwrap()
        );
        assert!(
            !store
                .remember(identity.clone(), "DP-4", output, geometry, state)
                .unwrap()
        );

        let loaded = WindowPlacementStore::load(Some(path.clone())).unwrap();
        assert_eq!(loaded.len(), 1);
        let moved_output = Rectangle::new((-2560, 0).into(), (2560, 1440).into());
        assert_eq!(
            loaded.restored_placement(
                &identity,
                [("DP-4".to_owned(), moved_output)],
                Rectangle::new((0, 0).into(), (1920, 1080).into()),
            ),
            Some(RestoredWindowPlacement {
                geometry: Rectangle::new((-2120, 220).into(), (900, 640).into()),
                state,
            })
        );

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn restore_clamps_a_stale_rectangle_to_the_current_output() {
        let saved = SavedWindowGeometry {
            output: "DP-4".into(),
            x: 2400,
            y: 1300,
            width: 2000,
            height: 1200,
            state: WindowPlacementState::default(),
            serial: 1,
        };
        assert_eq!(
            saved.restore(Rectangle::new((100, 50).into(), (1280, 720).into())),
            Rectangle::new((100, 50).into(), (1280, 720).into())
        );
    }

    #[test]
    fn missing_saved_connector_uses_the_fallback_output() {
        let identity = WindowIdentity::wayland("org.example.Editor").unwrap();
        let mut store = WindowPlacementStore::empty(None);
        store
            .remember(
                identity.clone(),
                "DP-4",
                Rectangle::new((2560, 0).into(), (2560, 1440).into()),
                Rectangle::new((3000, 220).into(), (900, 640).into()),
                WindowPlacementState::default(),
            )
            .unwrap();
        assert_eq!(
            store
                .restored_placement(
                    &identity,
                    [(
                        "DP-1".to_owned(),
                        Rectangle::new((0, 0).into(), (1920, 1080).into())
                    )],
                    Rectangle::new((0, 0).into(), (1920, 1080).into()),
                )
                .map(|placement| placement.geometry),
            Some(Rectangle::new((440, 220).into(), (900, 640).into()))
        );
    }

    #[test]
    fn wayland_and_x11_application_identities_do_not_collide() {
        let mut store = WindowPlacementStore::empty(None);
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        store
            .remember(
                WindowIdentity::wayland("example").unwrap(),
                "DP-1",
                output,
                Rectangle::new((100, 100).into(), (800, 600).into()),
                WindowPlacementState::default(),
            )
            .unwrap();
        store
            .remember(
                WindowIdentity::x11("example").unwrap(),
                "DP-1",
                output,
                Rectangle::new((200, 200).into(), (800, 600).into()),
                WindowPlacementState::default(),
            )
            .unwrap();
        assert_eq!(store.len(), 2);
    }

    #[test]
    fn store_is_bounded_to_the_most_recent_applications() {
        let mut store = WindowPlacementStore::empty(None);
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        for index in 0..=MAX_PLACEMENTS {
            store
                .remember(
                    WindowIdentity::wayland(&format!("org.example.App{index}")).unwrap(),
                    "DP-1",
                    output,
                    Rectangle::new((index as i32, 10).into(), (800, 600).into()),
                    WindowPlacementState::default(),
                )
                .unwrap();
        }
        assert_eq!(store.len(), MAX_PLACEMENTS);
        assert!(
            store
                .restored_placement(
                    &WindowIdentity::wayland("org.example.App0").unwrap(),
                    [("DP-1".to_owned(), output)],
                    output,
                )
                .is_none()
        );
    }

    #[test]
    fn invalid_identities_are_not_accepted() {
        assert!(WindowIdentity::wayland("").is_none());
        assert!(WindowIdentity::x11("bad\nclass").is_none());
        assert!(WindowIdentity::wayland(&"a".repeat(MAX_APP_ID_BYTES + 1)).is_none());
    }

    #[test]
    fn legacy_state_defaults_flags_and_is_migrated_on_the_next_write() {
        let path = test_path("legacy");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            r#"{
  "version": 1,
  "placements": [
    {
      "backend": "wayland",
      "appId": "org.example.Legacy",
      "output": "DP-1",
      "x": 100,
      "y": 120,
      "width": 800,
      "height": 600,
      "serial": 1
    }
  ]
}
"#,
        )
        .unwrap();

        let identity = WindowIdentity::wayland("org.example.Legacy").unwrap();
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let geometry = Rectangle::new((100, 120).into(), (800, 600).into());
        let mut loaded = WindowPlacementStore::load(Some(path.clone())).unwrap();
        assert_eq!(
            loaded.restored_placement(&identity, [("DP-1".to_owned(), output)], output),
            Some(RestoredWindowPlacement {
                geometry,
                state: WindowPlacementState::default(),
            })
        );
        assert!(
            !loaded
                .remember(
                    identity,
                    "DP-1",
                    output,
                    geometry,
                    WindowPlacementState::default(),
                )
                .unwrap()
        );
        let migrated: PlacementFile = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(migrated.version, FORMAT_VERSION);

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
