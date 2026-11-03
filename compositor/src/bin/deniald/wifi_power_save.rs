//! Wi-Fi station power save follows the screens.
//!
//! In power save a Wi-Fi chip sleeps between beacons, and a frame that arrives
//! after a quiet gap waits for the chip's next wake. On the WCN7850 that is up
//! to a quarter of a second, which a game or a remote shell feels on every
//! reply. While any output is lit Denial holds power save off; once every
//! output is dark it allows power save again, where it costs nothing a user
//! notices.
//!
//! A Wi-Fi driver opts in with a `power_save_allowed` attribute on its device,
//! and the device's packaging lets Denial write it with a udev rule. Devices
//! are looked up at each change, so one that binds after Denial starts is
//! still found. Without such a device nothing changes.
use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

const NET: &str = "/sys/class/net";

pub(super) struct WifiPowerSave {
    net: PathBuf,
    lit: Option<bool>,
}

impl Default for WifiPowerSave {
    fn default() -> Self {
        Self::with_net(NET)
    }
}

impl WifiPowerSave {
    fn with_net(net: impl Into<PathBuf>) -> Self {
        Self {
            net: net.into(),
            lit: None,
        }
    }

    /// Holds power save off while `lit`; writes only when the state changes.
    pub(super) fn sync(&mut self, lit: bool) {
        if self.lit == Some(lit) {
            return;
        }
        self.lit = Some(lit);
        for attribute in attributes(&self.net) {
            write(&attribute, !lit);
        }
    }
}

impl Drop for WifiPowerSave {
    fn drop(&mut self) {
        if self.lit == Some(true) {
            for attribute in attributes(&self.net) {
                write(&attribute, true);
            }
        }
    }
}

/// One writable attribute per Wi-Fi device, however many interfaces it has.
fn attributes(net: &Path) -> BTreeSet<PathBuf> {
    let Ok(entries) = fs::read_dir(net) else {
        return BTreeSet::new();
    };
    entries
        .flatten()
        .filter_map(|entry| fs::canonicalize(entry.path().join("device")).ok())
        .map(|device| device.join("power_save_allowed"))
        .filter(|attribute| attribute.exists())
        .collect()
}

fn write(attribute: &Path, allowed: bool) {
    let value: &[u8] = if allowed { b"1" } else { b"0" };
    let result = OpenOptions::new()
        .write(true)
        .open(attribute)
        .and_then(|mut file| file.write_all(value));
    match result {
        Ok(()) => tracing::info!(attribute = %attribute.display(), allowed, "Wi-Fi power save"),
        Err(error) => tracing::warn!(
            %error,
            attribute = %attribute.display(),
            "could not change Wi-Fi power save"
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    #[test]
    fn lit_screens_hold_power_save_off_and_dark_screens_allow_it() {
        let root = std::env::temp_dir().join(format!("denial-wifi-ps-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let device = root.join("devices/wifi");
        let net = root.join("net");
        fs::create_dir_all(&device).unwrap();
        fs::create_dir_all(net.join("wlan0")).unwrap();
        fs::create_dir_all(net.join("lo")).unwrap();
        std::os::unix::fs::symlink(&device, net.join("wlan0/device")).unwrap();
        let attribute = device.join("power_save_allowed");
        fs::write(&attribute, "1").unwrap();

        let mut policy = WifiPowerSave::with_net(&net);
        policy.sync(true);
        assert_eq!(read(&attribute), "0");
        fs::write(&attribute, "x").unwrap();
        policy.sync(true);
        assert_eq!(read(&attribute), "x", "an unchanged state writes nothing");
        policy.sync(false);
        assert_eq!(read(&attribute), "1");
        policy.sync(true);
        drop(policy);
        assert_eq!(read(&attribute), "1", "exit allows power save again");
        fs::remove_dir_all(&root).unwrap();
    }
}
