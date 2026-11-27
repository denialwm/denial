//! Scene texture ids of merged native windows, and the warning when one is copied.

pub const NATIVE_WINDOW_TEXTURE_NAMESPACE: u64 = 1 << 62;

/// Whether `texture_id` names a merged native window image.
pub const fn is_native_window_texture(texture_id: i64) -> bool {
    texture_id >= NATIVE_WINDOW_TEXTURE_NAMESPACE as i64
}

/// The surface texture a scene texture stands for: a merged native window
/// image stands for its window's root surface.
pub const fn surface_texture(texture_id: i64) -> i64 {
    if is_native_window_texture(texture_id) {
        texture_id & !(NATIVE_WINDOW_TEXTURE_NAMESPACE as i64)
    } else {
        texture_id
    }
}

/// Zero copy is the rule: a window whose layers are copied into one image
/// says so, at most once in this long, with how often since.
const COPY_WARNING_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

/// Call for each merge of `texture_id`'s layers that draws pixels.
pub fn warn_window_copied(
    texture_id: i64,
    app: Option<&str>,
    layers: usize,
    size: (u32, u32),
    renderer: &'static str,
) {
    // Per window: when it last warned and its copies since.
    static COPIED: std::sync::Mutex<Vec<(i64, std::time::Instant, u64)>> =
        std::sync::Mutex::new(Vec::new());
    let now = std::time::Instant::now();
    let mut copied = COPIED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let copies = match copied.iter_mut().find(|entry| entry.0 == texture_id) {
        Some(entry) => {
            entry.2 += 1;
            if now.duration_since(entry.1) < COPY_WARNING_INTERVAL {
                return;
            }
            entry.1 = now;
            std::mem::take(&mut entry.2)
        }
        None => {
            copied.retain(|entry| now.duration_since(entry.1) < 6 * COPY_WARNING_INTERVAL);
            copied.push((texture_id, now, 0));
            1
        }
    };
    drop(copied);
    tracing::warn!(
        window = surface_texture(texture_id),
        app = app.unwrap_or("?"),
        layers,
        width = size.0,
        height = size.1,
        copies,
        renderer,
        "window copied: its layers are merged into one image instead of sampled as they are"
    );
}
