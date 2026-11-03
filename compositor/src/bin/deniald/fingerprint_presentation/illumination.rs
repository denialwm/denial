//! Panel illumination capability, separate from authentication and image data.
use std::fs;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::sync::Arc;

use serde::Deserialize;
use smithay::backend::drm::DrmDeviceFd;
use smithay::reexports::drm::control::{Device as ControlDevice, connector, property};

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(super) enum Backend {
    #[default]
    DrmProperty,
    AstonAa551Fd,
}

// include/uapi/linux/aston_fp_illumination.h, ABI v1. Fixed-width fields and
// pointers passed to ioctl keep the wire layout identical on 32/64-bit hosts.
#[repr(C)]
struct AstonInfo {
    version: u32,
    panel_width: u32,
    panel_height: u32,
    max_duration_ms: u32,
    enabled: u32,
    panel_on: u32,
    compatible: [u8; 40],
}
impl Default for AstonInfo {
    fn default() -> Self {
        Self {
            version: 0,
            panel_width: 0,
            panel_height: 0,
            max_duration_ms: 0,
            enabled: 0,
            panel_on: 0,
            compatible: [0; 40],
        }
    }
}
const GET_INFO: libc::c_ulong = 0x8040_6100;
const SET: libc::c_ulong = 0x4004_6101;

fn info(fd: &OwnedFd) -> io::Result<AstonInfo> {
    let mut value = AstonInfo::default();
    // SAFETY: the kernel writes exactly the fixed 64-byte UAPI structure.
    if unsafe { libc::ioctl(fd.as_raw_fd(), GET_INFO, &mut value) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(value)
}
fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
fn validate_info(
    value: &AstonInfo,
    panel: &str,
    width: u32,
    height: u32,
    duration: u32,
) -> io::Result<()> {
    let name = value
        .compatible
        .split(|b| *b == 0)
        .next()
        .unwrap_or_default();
    if value.version != 1
        || value.panel_width != width
        || value.panel_height != height
        || name != panel.as_bytes()
        || panel != "oneplus,aston-boe-aa551"
        || value.enabled != 0
        || value.panel_on > 1
        || value.max_duration_ms < duration
        || value.max_duration_ms > 30_000
    {
        return Err(invalid(
            "panel illumination identity, ownership or timeout mismatch",
        ));
    }
    Ok(())
}

pub(super) fn validate_aston(
    fd: &OwnedFd,
    panel: &str,
    width: u32,
    height: u32,
    duration: u32,
) -> io::Result<()> {
    let node = fs::symlink_metadata("/dev/aston_fp_illumination")?;
    let descriptor = fs::metadata(format!("/proc/self/fd/{}", fd.as_raw_fd()))?;
    if !node.file_type().is_char_device()
        || node.uid() != 0
        || node.mode() & 0o077 != 0
        || !descriptor.file_type().is_char_device()
        || descriptor.rdev() != node.rdev()
    {
        return Err(invalid("unexpected panel illumination descriptor"));
    }
    validate_info(&info(fd)?, panel, width, height, duration)
}

#[derive(Clone)]
pub(super) enum Control {
    Drm {
        connector: connector::Handle,
        property: property::Handle,
        original: u64,
        on: u64,
    },
    Aston {
        fd: Arc<OwnedFd>,
    },
}
impl Control {
    fn set_aston(fd: &OwnedFd, enabled: bool) -> io::Result<()> {
        let value = u32::from(enabled);
        // SAFETY: this descriptor has the verified kernel driver identity and
        // SET reads one u32. It accepts no arbitrary DSI command or pathname.
        if unsafe { libc::ioctl(fd.as_raw_fd(), SET, &value) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    pub(super) fn enable(&self, drm: &DrmDeviceFd) -> io::Result<()> {
        match self {
            Self::Drm {
                connector,
                property,
                on,
                ..
            } => drm.set_property(*connector, *property, *on),
            Self::Aston { fd } => Self::set_aston(fd, true),
        }
    }
    pub(super) fn restore(&self, drm: &DrmDeviceFd) -> io::Result<()> {
        match self {
            Self::Drm {
                connector,
                property,
                original,
                ..
            } => drm.set_property(*connector, *property, *original),
            Self::Aston { fd } => Self::set_aston(fd, false),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn valid() -> AstonInfo {
        let mut value = AstonInfo {
            version: 1,
            panel_width: 1264,
            panel_height: 2780,
            max_duration_ms: 30_000,
            ..Default::default()
        };
        let name = b"oneplus,aston-boe-aa551";
        value.compatible[..name.len()].copy_from_slice(name);
        value
    }
    fn check(value: &AstonInfo) -> io::Result<()> {
        validate_info(value, "oneplus,aston-boe-aa551", 1264, 2780, 10_000)
    }
    #[test]
    fn fixed_kernel_abi_and_identity() {
        assert_eq!(std::mem::size_of::<AstonInfo>(), 64);
        assert!(check(&valid()).is_ok());
        let mut v = valid();
        v.version = 2;
        assert!(check(&v).is_err());
        let mut v = valid();
        v.panel_width = 1220;
        assert!(check(&v).is_err());
        let mut v = valid();
        v.compatible[0] = b'x';
        assert!(check(&v).is_err());
    }
    #[test]
    fn reject_owned_or_unbounded_illumination() {
        let mut v = valid();
        v.enabled = 1;
        assert!(check(&v).is_err());
        let mut v = valid();
        v.panel_on = 2;
        assert!(check(&v).is_err());
        let mut v = valid();
        v.max_duration_ms = 9999;
        assert!(check(&v).is_err());
        let mut v = valid();
        v.max_duration_ms = 30_001;
        assert!(check(&v).is_err());
    }
}
