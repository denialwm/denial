//! The device's own lights follow the settings document and the screen.
//!
//! A light is a multicolor LED under `/sys/class/leds`, such as a phone's
//! logo or trigger lights. Settings lists the ones the system does not drive
//! and keeps the user's choice in the settings document:
//!
//! ```json
//! "lights": {
//!   "offWithScreen": true,
//!   "leds": { "rgb:logo": { "on": true, "color": "#ff2a00" } }
//! }
//! ```
//!
//! Denial applies it when it starts, after every settings revision and, with
//! `offWithScreen`, when the screens go dark or light again. A light the
//! document does not name is left as it is. The device's packaging lets
//! Denial write the lights with a udev rule; lights are looked up at each
//! change, so a driver that binds after Denial starts is still found.
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

const LEDS: &str = "/sys/class/leds";

/// The user's choice for every light, from the settings document.
#[derive(Debug, Default, PartialEq)]
pub(super) struct LightSettings {
    pub(super) off_with_screen: bool,
    pub(super) lights: Vec<LightSetting>,
}

#[derive(Debug, PartialEq)]
pub(super) struct LightSetting {
    pub(super) name: String,
    pub(super) on: bool,
    pub(super) color: [u8; 3],
}

pub(super) struct Lights {
    leds: PathBuf,
    revision: Option<u64>,
    lit: bool,
    /// What each light was last set to: its colour, or `None` for off.
    applied: BTreeMap<String, Option<[u8; 3]>>,
}

impl Default for Lights {
    fn default() -> Self {
        Self::with_leds(LEDS)
    }
}

impl Lights {
    fn with_leds(leds: impl Into<PathBuf>) -> Self {
        Self {
            leds: leds.into(),
            revision: None,
            lit: true,
            applied: BTreeMap::new(),
        }
    }

    /// Whether the settings revision or the screens changed since the last
    /// [`Lights::apply`].
    pub(super) fn stale(&self, revision: u64, lit: bool) -> bool {
        self.revision != Some(revision) || self.lit != lit
    }

    /// Sets every light the settings name, writing only those that change.
    pub(super) fn apply(&mut self, revision: u64, lit: bool, settings: &LightSettings) {
        self.revision = Some(revision);
        self.lit = lit;
        let dark = settings.off_with_screen && !lit;
        for light in &settings.lights {
            let wanted = (light.on && !dark).then_some(light.color);
            if self.applied.get(&light.name) == Some(&wanted) {
                continue;
            }
            let Some(folder) = light_folder(&self.leds, &light.name) else {
                continue;
            };
            match set(&folder, wanted) {
                Ok(()) => {
                    self.applied.insert(light.name.clone(), wanted);
                }
                Err(error) => {
                    // Remembered as applied, so a light Denial may not write
                    // warns once per change, not on every revision.
                    self.applied.insert(light.name.clone(), wanted);
                    tracing::warn!(%error, light = %light.name, "could not set a light");
                }
            }
        }
    }
}

/// The light's sysfs folder, when the name is a plain multicolor LED.
fn light_folder(leds: &Path, name: &str) -> Option<PathBuf> {
    if name.is_empty() || name.starts_with('.') || name.contains('/') {
        return None;
    }
    let folder = leds.join(name);
    folder.join("multi_intensity").exists().then_some(folder)
}

fn set(folder: &Path, color: Option<[u8; 3]>) -> std::io::Result<()> {
    let Some(color) = color else {
        return write(&folder.join("brightness"), "0");
    };
    let max: u32 = fs::read_to_string(folder.join("max_brightness"))?
        .trim()
        .parse()
        .map_err(|_| std::io::Error::other("max_brightness is not a number"))?;
    let index = fs::read_to_string(folder.join("multi_index"))?;
    let intensity = index
        .split_whitespace()
        .map(|channel| {
            let value = match channel {
                "red" => color[0],
                "green" => color[1],
                "blue" => color[2],
                _ => 0,
            };
            (u32::from(value) * max / 255).to_string()
        })
        .collect::<Vec<_>>()
        .join(" ");
    write(&folder.join("multi_intensity"), &intensity)?;
    write(&folder.join("brightness"), &max.to_string())
}

fn write(attribute: &Path, value: &str) -> std::io::Result<()> {
    // Truncating like a shell redirection: sysfs ignores it, plain files in
    // the tests need it.
    OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(attribute)?
        .write_all(value.as_bytes())
}

/// `#rrggbb`.
pub(super) fn parse_color(value: &str) -> Option<[u8; 3]> {
    let hex = value.strip_prefix('#')?;
    if hex.len() != 6 || !hex.is_ascii() {
        return None;
    }
    let channel = |at: usize| u8::from_str_radix(&hex[at..at + 2], 16).ok();
    Some([channel(0)?, channel(2)?, channel(4)?])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    fn light(root: &Path, name: &str, index: &str) -> PathBuf {
        let folder = root.join(name);
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("max_brightness"), "255\n").unwrap();
        fs::write(folder.join("multi_index"), format!("{index}\n")).unwrap();
        fs::write(folder.join("multi_intensity"), "0 0 0\n").unwrap();
        fs::write(folder.join("brightness"), "0\n").unwrap();
        folder
    }

    fn settings(off_with_screen: bool, on: bool) -> LightSettings {
        LightSettings {
            off_with_screen,
            lights: vec![LightSetting {
                name: "rgb:logo".into(),
                on,
                color: [255, 42, 0],
            }],
        }
    }

    #[test]
    fn lights_follow_the_settings_and_the_screen() {
        let root = std::env::temp_dir().join(format!("denial-lights-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let logo = light(&root, "rgb:logo", "blue green red");
        let mut lights = Lights::with_leds(&root);

        assert!(lights.stale(1, true));
        lights.apply(1, true, &settings(true, true));
        assert_eq!(read(&logo.join("multi_intensity")), "0 42 255");
        assert_eq!(read(&logo.join("brightness")), "255");
        assert!(!lights.stale(1, true));

        fs::write(logo.join("brightness"), "x").unwrap();
        lights.apply(1, true, &settings(true, true));
        assert_eq!(
            read(&logo.join("brightness")),
            "x",
            "an unchanged light writes nothing"
        );

        lights.apply(1, false, &settings(true, true));
        assert_eq!(
            read(&logo.join("brightness")),
            "0",
            "dark screens turn it off"
        );
        lights.apply(1, true, &settings(true, true));
        assert_eq!(
            read(&logo.join("brightness")),
            "255",
            "lit screens turn it on again"
        );

        lights.apply(2, false, &settings(false, true));
        assert_eq!(
            read(&logo.join("brightness")),
            "255",
            "kept on with the screen off"
        );
        lights.apply(3, false, &settings(false, false));
        assert_eq!(read(&logo.join("brightness")), "0");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn only_plain_multicolor_names_are_written() {
        let root = std::env::temp_dir().join(format!("denial-light-names-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        light(&root, "rgb:logo", "red green blue");
        fs::create_dir_all(root.join("white:flash")).unwrap();
        assert!(light_folder(&root, "rgb:logo").is_some());
        assert!(light_folder(&root, "white:flash").is_none());
        assert!(light_folder(&root, "../rgb:logo").is_none());
        assert!(light_folder(&root, "").is_none());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn colors_are_hex_triplets() {
        assert_eq!(parse_color("#ff2a00"), Some([255, 42, 0]));
        assert_eq!(parse_color("ff2a00"), None);
        assert_eq!(parse_color("#ff2a0"), None);
        assert_eq!(parse_color("#gg0000"), None);
    }
}
