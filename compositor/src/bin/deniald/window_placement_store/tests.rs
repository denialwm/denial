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
    let output = Rectangle::new((2560, 563).into(), (2560, 1440).into());
    let geometry = Rectangle::new((3000, 783).into(), (900, 640).into());
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
    let moved_output = Rectangle::new((-2560, 120).into(), (2560, 1440).into());
    assert_eq!(
        loaded.restored_placement(
            &identity,
            [("DP-4".to_owned(), moved_output)],
            Rectangle::new((0, 0).into(), (1920, 1080).into()),
        ),
        Some(RestoredWindowPlacement {
            geometry: Rectangle::new((-2120, 340).into(), (900, 640).into()),
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

#[test]
fn version_two_state_flags_are_dropped_when_provenance_is_unknown() {
    let path = test_path("unprovenanced-state");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        r#"{
  "version": 2,
  "placements": [
{
  "backend": "wayland",
  "appId": "org.example.Streamer",
  "output": "DP-1",
  "x": 100,
  "y": 120,
  "width": 800,
  "height": 600,
  "maximized": false,
  "fullscreen": true,
  "serial": 1
}
  ]
}
"#,
    )
    .unwrap();

    let identity = WindowIdentity::wayland("org.example.Streamer").unwrap();
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
