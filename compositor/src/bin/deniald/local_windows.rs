//! Trusted Flutter applications represented as normal Denial windows.
//!
//! These records deliberately contain no Wayland resource or external
//! texture. Rust owns their stable identity and geometry mirror; the embedded
//! Dart shell selects and renders their in-bundle widget tree by `app_id`.

use std::collections::BTreeMap;

use super::wire::WindowGeometry;

const MAX_LOCAL_FLUTTER_WINDOWS: usize = 256;
const MAX_WINDOW_ID: u64 = i64::MAX as u64;

#[derive(Clone, Debug, PartialEq)]
pub(super) struct LocalFlutterWindow {
    pub(super) id: u64,
    pub(super) app_id: String,
    pub(super) title: String,
    /// Global compositor logical coordinates, not atlas-relative coordinates.
    pub(super) geometry: WindowGeometry,
}

#[derive(Debug)]
pub(super) enum LocalWindowError {
    Capacity,
    IdentifierExhausted,
}

#[derive(Debug)]
pub(super) struct LocalFlutterWindows {
    windows: BTreeMap<u64, LocalFlutterWindow>,
    focused: Option<u64>,
    next_id: u64,
}

impl Default for LocalFlutterWindows {
    fn default() -> Self {
        Self {
            windows: BTreeMap::new(),
            focused: None,
            // Wayland surface IDs grow upward from one. Allocating local IDs
            // downward keeps the two domains disjoint in ordinary operation;
            // the collision callback below remains the authoritative guard.
            next_id: MAX_WINDOW_ID,
        }
    }
}

impl LocalFlutterWindows {
    pub(super) fn create(
        &mut self,
        app_id: String,
        title: String,
        geometry: WindowGeometry,
        mut external_id_in_use: impl FnMut(u64) -> bool,
    ) -> Result<u64, LocalWindowError> {
        if self.windows.len() >= MAX_LOCAL_FLUTTER_WINDOWS {
            return Err(LocalWindowError::Capacity);
        }

        let first_candidate = self.next_id.clamp(1, MAX_WINDOW_ID);
        let mut candidate = first_candidate;
        loop {
            if !self.windows.contains_key(&candidate) && !external_id_in_use(candidate) {
                break;
            }
            candidate = previous_id(candidate);
            if candidate == first_candidate {
                return Err(LocalWindowError::IdentifierExhausted);
            }
        }
        self.next_id = previous_id(candidate);
        self.windows.insert(
            candidate,
            LocalFlutterWindow {
                id: candidate,
                app_id,
                title,
                geometry,
            },
        );
        self.focused = Some(candidate);
        Ok(candidate)
    }

    pub(super) fn contains(&self, window_id: u64) -> bool {
        self.windows.contains_key(&window_id)
    }

    pub(super) fn get(&self, window_id: u64) -> Option<&LocalFlutterWindow> {
        self.windows.get(&window_id)
    }

    pub(super) fn iter(&self) -> impl Iterator<Item = &LocalFlutterWindow> {
        self.windows.values()
    }

    pub(super) fn focus(&mut self, window_id: u64) -> bool {
        if !self.windows.contains_key(&window_id) {
            return false;
        }
        self.focused = Some(window_id);
        true
    }

    pub(super) fn clear_focus(&mut self) {
        self.focused = None;
    }

    pub(super) fn focused(&self) -> Option<u64> {
        self.focused.filter(|id| self.windows.contains_key(id))
    }

    pub(super) fn configure(&mut self, window_id: u64, geometry: WindowGeometry) -> bool {
        let Some(window) = self.windows.get_mut(&window_id) else {
            return false;
        };
        if window.geometry == geometry {
            return false;
        }
        window.geometry = geometry;
        true
    }

    pub(super) fn remove(&mut self, window_id: u64) -> bool {
        let removed = self.windows.remove(&window_id).is_some();
        if self.focused == Some(window_id) {
            self.focused = None;
        }
        removed
    }
}

const fn previous_id(id: u64) -> u64 {
    if id <= 1 { MAX_WINDOW_ID } else { id - 1 }
}

#[cfg(test)]
mod tests {
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
}
