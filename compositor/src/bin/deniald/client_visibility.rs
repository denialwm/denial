//! Which client textures the composer left out of the last frame it drew for
//! each output: hidden whole under opaque draws above them. The Wayland side
//! gives a window it cannot see one frame callback a second instead of one
//! per refresh, so a client nobody sees stops drawing frames nobody shows.
//!
//! A texture is hidden when the last composed frame of some output left it
//! out and no output's last composed frame showed it. An output whose frame
//! the composer did not draw reports nothing.

use std::sync::Mutex;

struct View {
    view_id: i64,
    shown: Vec<i64>,
    hidden: Vec<i64>,
}

static VIEWS: Mutex<Vec<View>> = Mutex::new(Vec::new());

fn views() -> std::sync::MutexGuard<'static, Vec<View>> {
    VIEWS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The composer drew a frame of `view_id`: `shown` textures have a draw that
/// changes pixels, `hidden` ones were in the scene and changed none.
pub(crate) fn composed(view_id: i64, shown: &[i64], hidden: &[i64]) {
    let mut views = views();
    let index = match views.iter().position(|view| view.view_id == view_id) {
        Some(index) => index,
        None => {
            views.push(View {
                view_id,
                shown: Vec::new(),
                hidden: Vec::new(),
            });
            views.len() - 1
        }
    };
    let view = &mut views[index];
    view.shown.clear();
    view.shown.extend_from_slice(shown);
    view.hidden.clear();
    view.hidden.extend_from_slice(hidden);
}

/// `view_id` showed a frame the composer did not draw, or went away: what it
/// left out is unknown.
pub(crate) fn forget(view_id: i64) {
    views().retain(|view| view.view_id != view_id);
}

/// Whether the textures of `texture_ids` (a window's surfaces) are all
/// hidden: one is left out somewhere and none is shown anywhere. Surfaces the
/// scene does not hold, such as a root that only carries its subsurfaces,
/// count for neither.
pub(crate) fn all_hidden(texture_ids: &[i64]) -> bool {
    let views = views();
    views.iter().any(|view| {
        texture_ids
            .iter()
            .any(|texture_id| view.hidden.contains(texture_id))
    }) && !views.iter().any(|view| {
        texture_ids
            .iter()
            .any(|texture_id| view.shown.contains(texture_id))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test: the record is process-wide.
    #[test]
    fn hidden_only_where_no_output_shows_it() {
        composed(1, &[10], &[20, 30]);
        assert!(all_hidden(&[20]));
        assert!(!all_hidden(&[10]));
        assert!(!all_hidden(&[40]));
        assert!(!all_hidden(&[]));
        // A root the scene does not hold, carrying a hidden subsurface.
        assert!(all_hidden(&[40, 20]));
        // A popup of the hidden window shows.
        assert!(!all_hidden(&[20, 10]));
        // Another output shows the texture.
        composed(2, &[30], &[]);
        assert!(!all_hidden(&[30]));
        // The composer did not draw output 1's frame.
        forget(1);
        assert!(!all_hidden(&[20]));
        forget(2);
    }
}
