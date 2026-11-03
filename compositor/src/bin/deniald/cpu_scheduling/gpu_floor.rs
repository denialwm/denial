//! An interaction floor for a GPU whose kernel driver scales it by load.
//!
//! A devfreq governor such as simple_ondemand averages GPU utilization over a
//! polling window, typically 50 ms. Denial's frames are serialized: the GPU
//! waits while the CPU prepares each frame, and its work must finish before
//! the next vblank. A frame that misses its vblank halves the frame rate and
//! so lowers the measured load. The governor then sees headroom exactly when
//! frames are late, and an animation can run at the device's lowest useful
//! frequency from its first frame to its last.
//!
//! The semantic hint worker knows when the user interacts before any frame
//! work starts. For the same hold time as the CPU floors, the GPU's minimum
//! frequency becomes its highest operating point, and the previous minimum
//! returns afterwards. Thermal limits still apply: devfreq never raises the
//! minimum above the current maximum.
//!
//! Only a GPU devfreq device whose `min_freq` Denial may write is used. The
//! device's own packaging grants that permission with a udev rule, so a GPU
//! without devfreq, or one whose platform does not opt in, is unchanged.
//! DENIAL_GPU_HINTS=0 disables the floor.
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

const DEVFREQ: &str = "/sys/class/devfreq";
/// Kernel drivers whose devfreq device is a GPU. The msm driver binds its
/// Adreno GPU as a separate platform device named "adreno".
const GPU_DRIVERS: &[&str] = &["adreno"];
/// Records the minimum to restore while a floor is raised, so a later Denial
/// can undo the floor of one that exited before restoring it.
const RECORD: &str = "denial-gpu-floor";

pub(super) struct GpuFloor {
    device: PathBuf,
    min_freq: File,
    boost: u64,
    raised_from: Option<u64>,
    record: Option<PathBuf>,
}

impl GpuFloor {
    /// Finds the first GPU devfreq device Denial may raise. Returns `None`
    /// without a log line when the system has no such GPU at all.
    pub(super) fn discover() -> Option<Self> {
        let record = std::env::var_os("XDG_RUNTIME_DIR").map(|dir| Path::new(&dir).join(RECORD));
        let mut entries = fs::read_dir(DEVFREQ)
            .ok()?
            .flatten()
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
        entries.sort();
        for device in entries {
            let driver = fs::read_link(device.join("device/driver")).ok();
            let Some(driver) = driver.as_deref().and_then(Path::file_name) else {
                continue;
            };
            if !GPU_DRIVERS.iter().any(|known| driver == *known) {
                continue;
            }
            let path = device.join("min_freq");
            let min_freq = match OpenOptions::new().read(true).write(true).open(&path) {
                Ok(file) => file,
                Err(error) => {
                    tracing::info!(
                        %error,
                        device = %device.display(),
                        "GPU interaction floor unavailable: the platform does not let Denial raise this GPU"
                    );
                    continue;
                }
            };
            let Some(boost) = fs::read_to_string(device.join("available_frequencies"))
                .ok()
                .and_then(|list| highest_frequency(&list))
            else {
                continue;
            };
            let mut floor = Self {
                device,
                min_freq,
                boost,
                raised_from: None,
                record: record.clone(),
            };
            floor.recover();
            tracing::info!(
                device = %floor.device.display(),
                boost_hz = floor.boost,
                minimum_hz = floor.current(),
                "GPU interaction floor active"
            );
            return Some(floor);
        }
        None
    }

    /// Raises the minimum frequency for an interaction. A minimum that is
    /// already at least the boost, set by someone else, is left alone.
    pub(super) fn raise(&mut self) {
        if self.raised_from.is_some() {
            return;
        }
        let Some(current) = self.current() else {
            return;
        };
        if current >= self.boost {
            return;
        }
        if let Some(record) = &self.record {
            let contents = format_record(&self.device, current, self.boost);
            if let Err(error) = fs::write(record, contents) {
                tracing::debug!(%error, "could not record the GPU minimum before raising it");
            }
        }
        match self.write(self.boost) {
            Ok(()) => self.raised_from = Some(current),
            Err(error) => {
                tracing::debug!(%error, "could not raise the GPU interaction floor");
                self.forget();
            }
        }
    }

    /// Restores the minimum that [`Self::raise`] replaced.
    pub(super) fn lower(&mut self) {
        let Some(previous) = self.raised_from.take() else {
            return;
        };
        if let Err(error) = self.write(previous) {
            tracing::warn!(%error, previous_hz = previous, "could not restore the GPU minimum frequency");
            return;
        }
        self.forget();
    }

    /// Undoes a floor that an earlier Denial raised and never lowered. A
    /// minimum that has changed since then belongs to someone else.
    fn recover(&mut self) {
        let Some(record) = &self.record else {
            return;
        };
        let Some((device, previous, boost)) = fs::read_to_string(record)
            .ok()
            .and_then(|contents| parse_record(&contents))
        else {
            return;
        };
        if device == self.device && self.current() == Some(boost) {
            match self.write(previous) {
                Ok(()) => tracing::info!(
                    previous_hz = previous,
                    "restored a GPU minimum frequency left raised by an earlier Denial"
                ),
                Err(error) => {
                    tracing::warn!(%error, "could not restore an earlier GPU minimum frequency");
                    return;
                }
            }
        }
        self.forget();
    }

    fn forget(&self) {
        if let Some(record) = &self.record {
            let _ = fs::remove_file(record);
        }
    }

    fn current(&self) -> Option<u64> {
        let mut buffer = [0u8; 32];
        let length = self.min_freq.read_at(&mut buffer, 0).ok()?;
        std::str::from_utf8(&buffer[..length])
            .ok()?
            .trim()
            .parse()
            .ok()
    }

    fn write(&self, hz: u64) -> io::Result<()> {
        let value = hz.to_string();
        let written = self.min_freq.write_at(value.as_bytes(), 0)?;
        if written == value.len() {
            Ok(())
        } else {
            Err(io::ErrorKind::WriteZero.into())
        }
    }
}

impl Drop for GpuFloor {
    fn drop(&mut self) {
        self.lower();
    }
}

fn highest_frequency(list: &str) -> Option<u64> {
    list.split_whitespace()
        .filter_map(|value| value.parse::<u64>().ok())
        .max()
}

fn format_record(device: &Path, previous: u64, boost: u64) -> String {
    format!("{}\n{previous}\n{boost}\n", device.display())
}

fn parse_record(contents: &str) -> Option<(PathBuf, u64, u64)> {
    let mut lines = contents.lines();
    let device = PathBuf::from(lines.next()?);
    let previous = lines.next()?.parse().ok()?;
    let boost = lines.next()?.parse().ok()?;
    Some((device, previous, boost))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_highest_operating_point() {
        let list = "259000000 355000000 600000000 900000000 1150000000 975000000\n";
        assert_eq!(highest_frequency(list), Some(1_150_000_000));
        assert_eq!(highest_frequency(" \n"), None);
    }

    #[test]
    fn record_round_trips() {
        let device = Path::new("/sys/class/devfreq/3d00000.gpu");
        let record = format_record(device, 900_000_000, 1_150_000_000);
        assert_eq!(
            parse_record(&record),
            Some((device.to_owned(), 900_000_000, 1_150_000_000))
        );
        assert_eq!(
            parse_record("/sys/class/devfreq/x\nnot a number\n1\n"),
            None
        );
    }
}
