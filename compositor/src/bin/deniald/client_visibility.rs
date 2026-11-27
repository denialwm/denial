//! Which client textures the composer left out of the last frame it drew for
//! each output: hidden whole under opaque draws above them. The Wayland side
//! gives a window it cannot see one frame callback a second instead of one
//! per refresh, so a client nobody sees stops drawing frames nobody shows.
//!
//! A texture is hidden when the last composed frame of some output hid it
//! under opaque draws and no output's last composed frame showed it. A
//! texture off an output is not hidden there: another output shows it. An
//! output whose last frame the composer did not draw hides nothing and keeps
//! showing what its last composed frame showed.

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

/// `view_id` showed a frame the composer did not draw: what it hides is
/// unknown. What it showed last stays shown, so a client on that output
/// keeps its frames until the composer draws the output again.
pub(crate) fn forget(view_id: i64) {
    if let Some(view) = views().iter_mut().find(|view| view.view_id == view_id) {
        view.hidden.clear();
    }
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

/// Whether no output's last composed frame showed any texture of
/// `texture_ids`, whether the scene held them or not. False while the
/// composer accounts for no output, as when GLES draws every frame: then
/// nothing is known.
pub(crate) fn unseen(texture_ids: &[i64]) -> bool {
    let views = views();
    !views.is_empty()
        && !texture_ids.is_empty()
        && !views.iter().any(|view| {
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
        // Output 2 hid 10 under an opaque window, but output 1, whose last
        // frame the composer did not draw, showed it last.
        composed(2, &[], &[10]);
        assert!(!all_hidden(&[10]));
        // Unseen: shown by no output, held in a scene or not.
        assert!(!unseen(&[10]));
        assert!(unseen(&[20]));
        assert!(unseen(&[50]));
        assert!(!unseen(&[]));
        composed(1, &[], &[]);
        composed(2, &[], &[]);
    }
}
