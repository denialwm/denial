use super::*;

fn geometry(x: f64) -> WindowGeometry {
    WindowGeometry {
        x,
        y: 20.0,
        width: 800.0,
        height: 600.0,
    }
}

#[test]
fn allocates_stable_high_ids_and_tracks_lifecycle() {
    let mut windows = LocalFlutterWindows::default();
    let first = windows
        .create(
            "org.denial.One".into(),
            "One".into(),
            geometry(10.0),
            |_| false,
        )
        .unwrap();
    let second = windows
        .create(
            "org.denial.Two".into(),
            "Two".into(),
            geometry(30.0),
            |_| false,
        )
        .unwrap();

    assert_eq!(first, MAX_WINDOW_ID);
    assert_eq!(second, MAX_WINDOW_ID - 1);
    assert_eq!(windows.focused(), Some(second));
    assert!(windows.configure(second, geometry(40.0)));
    assert_eq!(windows.get(second).unwrap().geometry, geometry(40.0));
    assert!(windows.remove(second));
    assert_eq!(windows.focused(), None);
    assert!(windows.contains(first));
}

#[test]
fn skips_ids_owned_by_an_external_surface() {
    let mut windows = LocalFlutterWindows::default();
    let id = windows
        .create(
            "org.denial.Local".into(),
            "Local".into(),
            geometry(0.0),
            |candidate| candidate == MAX_WINDOW_ID,
        )
        .unwrap();

    assert_eq!(id, MAX_WINDOW_ID - 1);
}
