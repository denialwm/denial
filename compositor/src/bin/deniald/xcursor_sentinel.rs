//! Private Xcursor theme used to distinguish toolkit cursors from application artwork.

use std::env;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

pub(super) const THEME_NAME: &str = "Denial-Sentinel";
pub(super) const THEME_CORE_VALUE: &str = "1";

const XCURSOR_MAGIC: u32 = 0x7275_6358;
const XCURSOR_FILE_VERSION: u32 = 0x0001_0000;
const XCURSOR_IMAGE_TYPE: u32 = 0xfffd_0002;
const XCURSOR_IMAGE_VERSION: u32 = 1;
const XCURSOR_FILE_HEADER_LENGTH: u32 = 16;
const XCURSOR_TOC_LENGTH: u32 = 12;
const XCURSOR_IMAGE_HEADER_LENGTH: u32 = 36;
const XCURSOR_NOMINAL_SIZE: u32 = 32;

// Xwayland does not tell a compositor whether an X cursor came from a toolkit
// theme or was drawn by the application. This private theme turns the former
// into an internal protocol: every semantic cursor family is a one-pixel black
// marker with a distinct, very low alpha value. Denial decodes the marker and
// renders its own themed artwork. Any non-marker buffer remains application
// artwork and is published unchanged (notably game cursors).
//
// Alpha may not be zero: Xwayland collapses a fully transparent X cursor to a
// null Wayland cursor before the compositor can inspect it.
struct CursorFamily {
    shape: &'static str,
    alpha: u8,
    names: &'static [&'static str],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CursorOverride {
    Hidden,
    Named(&'static str),
}

const CURSOR_FAMILIES: &[CursorFamily] = &[
    CursorFamily {
        shape: "default",
        alpha: 1,
        names: &[
            "X_cursor",
            "arrow",
            "center_ptr",
            "default",
            "double_arrow",
            "down-arrow",
            "draft",
            "draft_large",
            "draft_small",
            "draped_box",
            "icon",
            "left-arrow",
            "left_ptr",
            "right-arrow",
            "right_ptr",
            "sb_down_arrow",
            "sb_left_arrow",
            "sb_right_arrow",
            "sb_up_arrow",
            "top_left_arrow",
            "wayland-cursor",
            "x-cursor",
        ],
    },
    CursorFamily {
        shape: "help",
        alpha: 2,
        names: &[
            "dnd-ask",
            "help",
            "left_ptr_help",
            "question_arrow",
            "whats_this",
        ],
    },
    CursorFamily {
        shape: "pointer",
        alpha: 3,
        names: &["hand1", "hand2", "link", "pointer", "pointing_hand"],
    },
    CursorFamily {
        shape: "progress",
        alpha: 4,
        names: &["half-busy", "left_ptr_watch", "progress"],
    },
    CursorFamily {
        shape: "wait",
        alpha: 5,
        names: &["wait", "watch"],
    },
    CursorFamily {
        shape: "crosshair",
        alpha: 6,
        names: &[
            "cell",
            "color-picker",
            "cross",
            "cross_reverse",
            "crosshair",
            "diamond_cross",
            "dot_box_mask",
            "dotbox",
            "plus",
            "target",
            "tcross",
            "zoom-in",
            "zoom-out",
        ],
    },
    CursorFamily {
        shape: "text",
        alpha: 7,
        names: &["ibeam", "text", "vertical-text", "xterm"],
    },
    CursorFamily {
        shape: "pencil",
        alpha: 8,
        names: &["pencil"],
    },
    CursorFamily {
        shape: "not-allowed",
        alpha: 9,
        names: &[
            "circle",
            "crossed_circle",
            "dnd-no-drop",
            "dnd-none",
            "dnd_no_drop",
            "forbidden",
            "no-drop",
            "not-allowed",
            "pirate",
        ],
    },
    CursorFamily {
        shape: "ns-resize",
        alpha: 10,
        names: &[
            "bottom_side",
            "n-resize",
            "ns-resize",
            "row-resize",
            "s-resize",
            "sb_v_double_arrow",
            "size-ver",
            "size_ver",
            "split_v",
            "top_side",
            "v_double_arrow",
        ],
    },
    CursorFamily {
        shape: "ew-resize",
        alpha: 11,
        names: &[
            "col-resize",
            "e-resize",
            "ew-resize",
            "h_double_arrow",
            "left_side",
            "right_side",
            "sb_h_double_arrow",
            "size-hor",
            "size_hor",
            "split_h",
            "w-resize",
        ],
    },
    CursorFamily {
        shape: "nwse-resize",
        alpha: 12,
        names: &[
            "bottom_right_corner",
            "fd_double_arrow",
            "nw-resize",
            "nwse-resize",
            "se-resize",
            "size-fdiag",
            "size_fdiag",
            "top_left_corner",
        ],
    },
    CursorFamily {
        shape: "nesw-resize",
        alpha: 13,
        names: &[
            "bd_double_arrow",
            "bottom_left_corner",
            "ne-resize",
            "nesw-resize",
            "size-bdiag",
            "size_bdiag",
            "sw-resize",
            "top_right_corner",
        ],
    },
    CursorFamily {
        shape: "move",
        alpha: 14,
        names: &[
            "all-resize",
            "all-scroll",
            "closedhand",
            "dnd-move",
            "fleur",
            "grab",
            "grabbing",
            "move",
            "openhand",
            "pointer_move",
            "size_all",
        ],
    },
    CursorFamily {
        shape: "alias",
        alpha: 15,
        names: &[
            "alias",
            "context-menu",
            "copy",
            "dnd-copy",
            "dnd-link",
            "up-arrow",
        ],
    },
];

#[derive(Debug)]
struct SentinelTheme {
    search_path: String,
}

static SENTINEL_THEME: OnceLock<SentinelTheme> = OnceLock::new();

pub(super) fn install() -> Result<(), Box<dyn std::error::Error>> {
    if SENTINEL_THEME.get().is_some() {
        return Ok(());
    }
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .ok_or("XDG_RUNTIME_DIR is required for the Xcursor sentinel theme")?;
    let runtime = PathBuf::from(runtime);
    if !runtime.is_absolute() {
        return Err("XDG_RUNTIME_DIR must be absolute for the Xcursor sentinel theme".into());
    }

    let search_root = runtime.join("denial").join("xcursor-themes");
    let cursor_directory = search_root.join(THEME_NAME).join("cursors");
    fs::create_dir_all(&cursor_directory)?;
    fs::set_permissions(&search_root, fs::Permissions::from_mode(0o700))?;
    fs::set_permissions(
        search_root.join(THEME_NAME),
        fs::Permissions::from_mode(0o700),
    )?;
    fs::set_permissions(&cursor_directory, fs::Permissions::from_mode(0o700))?;

    for family in CURSOR_FAMILIES {
        let cursor = sentinel_cursor_file(family.alpha);
        for name in family.names {
            write_if_changed(&cursor_directory.join(name), &cursor)?;
        }
    }
    write_if_changed(
        &search_root.join(THEME_NAME).join("index.theme"),
        b"[Icon Theme]\nName=Denial Xwayland Sentinel\nComment=One-pixel marker cursors rendered by Denial\n",
    )?;

    let search_path = xcursor_search_path(&search_root)?;
    SENTINEL_THEME
        .set(SentinelTheme { search_path })
        .map_err(|_| "Xcursor sentinel theme was activated concurrently")?;
    Ok(())
}

pub(super) fn is_active() -> bool {
    SENTINEL_THEME.get().is_some()
}

pub(super) fn environment() -> Option<[(&'static str, &'static str); 3]> {
    let theme = SENTINEL_THEME.get()?;
    Some([
        ("XCURSOR_THEME", THEME_NAME),
        ("XCURSOR_THEME_CORE", THEME_CORE_VALUE),
        ("XCURSOR_PATH", &theme.search_path),
    ])
}

pub(super) fn apply_to_command(command: &mut Command) {
    if let Some(environment) = environment() {
        command.envs(environment);
    }
}

pub(super) fn override_for_marker(width: u32, height: u32, rgba: &[u8]) -> Option<CursorOverride> {
    if width != 1 || height != 1 || rgba.len() != 4 || rgba[..3] != [0, 0, 0] {
        return None;
    }
    if rgba[3] == 0 {
        // Wine represents a null Win32 cursor with a one-pixel, all-zero X
        // pixmap cursor rather than XFixesHideCursor. Xwayland consequently
        // publishes a real wl_surface for it; preserve the application's hide
        // intent instead of allowing the previous Denial shape to remain.
        return Some(CursorOverride::Hidden);
    }
    CURSOR_FAMILIES
        .iter()
        .find(|family| family.alpha == rgba[3])
        .map(|family| CursorOverride::Named(family.shape))
}

fn sentinel_cursor_file(alpha: u8) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(68);
    let image_position = XCURSOR_FILE_HEADER_LENGTH + XCURSOR_TOC_LENGTH;
    for value in [
        XCURSOR_MAGIC,
        XCURSOR_FILE_HEADER_LENGTH,
        XCURSOR_FILE_VERSION,
        1,
        XCURSOR_IMAGE_TYPE,
        XCURSOR_NOMINAL_SIZE,
        image_position,
        XCURSOR_IMAGE_HEADER_LENGTH,
        XCURSOR_IMAGE_TYPE,
        XCURSOR_NOMINAL_SIZE,
        XCURSOR_IMAGE_VERSION,
        1,                      // width
        1,                      // height
        0,                      // x hotspot
        0,                      // y hotspot
        0,                      // frame delay
        u32::from(alpha) << 24, // black ARGB marker pixel
    ] {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    bytes
}

fn write_if_changed(path: &Path, contents: &[u8]) -> io::Result<()> {
    match fs::read(path) {
        Ok(existing) if existing == contents => return Ok(()),
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "refusing to replace sentinel-theme symlink {}",
                path.display()
            ),
        ));
    }
    fs::write(path, contents)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

fn xcursor_search_path(search_root: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let mut paths = vec![search_root.to_path_buf()];
    if let Some(existing) = env::var_os("XCURSOR_PATH").filter(|value| !value.is_empty()) {
        paths.extend(env::split_paths(&existing));
    } else {
        let home = env::var_os("HOME").map(PathBuf::from);
        if let Some(data_home) = env::var_os("XDG_DATA_HOME").map(PathBuf::from) {
            paths.push(data_home.join("icons"));
        } else if let Some(home) = &home {
            paths.push(home.join(".local/share/icons"));
        }
        if let Some(home) = home {
            paths.push(home.join(".icons"));
        }
        let data_directories = env::var_os("XDG_DATA_DIRS")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| OsString::from("/usr/local/share:/usr/share"));
        paths.extend(env::split_paths(&data_directories).map(|path| path.join("icons")));
        paths.push(PathBuf::from("/usr/share/pixmaps"));
    }
    env::join_paths(paths)?
        .into_string()
        .map_err(|_| "Xcursor search path is not valid UTF-8".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_is_a_single_nearly_transparent_xcursor_image() {
        let bytes = sentinel_cursor_file(3);
        let words = bytes
            .chunks_exact(4)
            .map(|word| u32::from_le_bytes(word.try_into().unwrap()))
            .collect::<Vec<_>>();
        assert_eq!(bytes.len(), 68);
        assert_eq!(words[0], XCURSOR_MAGIC);
        assert_eq!(words[3], 1);
        assert_eq!(words[4], XCURSOR_IMAGE_TYPE);
        assert_eq!(words[6], 28);
        assert_eq!(&words[11..], &[1, 1, 0, 0, 0, 0x0300_0000]);
    }

    #[test]
    fn markers_round_trip_to_their_semantic_shapes() {
        for family in CURSOR_FAMILIES {
            assert_eq!(
                override_for_marker(1, 1, &[0, 0, 0, family.alpha]),
                Some(CursorOverride::Named(family.shape))
            );
        }
    }

    #[test]
    fn all_zero_wine_cursor_decodes_as_hidden() {
        assert_eq!(
            override_for_marker(1, 1, &[0, 0, 0, 0]),
            Some(CursorOverride::Hidden)
        );
    }

    #[test]
    fn decoder_rejects_non_markers() {
        assert_eq!(override_for_marker(2, 1, &[0, 0, 0, 3]), None);
        assert_eq!(override_for_marker(1, 1, &[1, 0, 0, 3]), None);
        assert_eq!(override_for_marker(1, 1, &[0, 0, 0, 16]), None);
    }

    #[test]
    fn cursor_names_and_marker_codes_are_unique() {
        let mut names = std::collections::HashSet::new();
        let mut alphas = std::collections::HashSet::new();
        for family in CURSOR_FAMILIES {
            assert!(alphas.insert(family.alpha));
            assert_ne!(family.alpha, 0);
            for name in family.names {
                assert!(names.insert(*name), "duplicate cursor alias {name}");
            }
        }
    }
}
