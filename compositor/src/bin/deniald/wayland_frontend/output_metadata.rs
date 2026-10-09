//! Native panel metadata, deliberately independent of logical layout/rotation.

use super::{DrmDeviceFd, OutputId, PhysicalProperties, Subpixel};
use smithay::reexports::drm::control::{Device, connector};

pub(super) fn unknown(name: &str) -> PhysicalProperties {
    from_native(name, None, Subpixel::Unknown, None)
}

/// None means an I/O failure, not authoritative missing monitor metadata.
pub(super) fn read(drm: &DrmDeviceFd, id: OutputId, name: &str) -> Option<PhysicalProperties> {
    let Some(handle) = u32::try_from(id.0)
        .ok()
        .and_then(|id| std::num::NonZeroU32::new(id).map(connector::Handle::from))
    else {
        return Some(unknown(name));
    };
    let info = drm.get_connector(handle, false).ok()?;
    if info.state() != connector::State::Connected || info.to_string() != name {
        return Some(unknown(name));
    }
    let props = drm.get_properties(handle).ok()?;
    let mut edid = None;
    for (handle, value) in props {
        let property = drm.get_property(handle).ok()?;
        if property.name().to_str() == Ok("EDID") {
            if let Some(blob) = property.value_type().convert_value(value).as_blob()
                && blob != 0
            {
                edid = Some(drm.get_property_blob(blob).ok()?);
            }
            break;
        }
    }
    Some(from_native(
        name,
        info.size(),
        info.subpixel().into(),
        edid.as_deref(),
    ))
}

pub(super) fn resolve(
    read: Option<PhysicalProperties>,
    previous: Option<PhysicalProperties>,
    name: &str,
) -> PhysicalProperties {
    read.or(previous).unwrap_or_else(|| unknown(name))
}

fn valid_size(size: Option<(u32, u32)>) -> Option<(i32, i32)> {
    let (w, h) = size?;
    if w == 0 || h == 0 {
        return None;
    }
    Some((i32::try_from(w).ok()?, i32::try_from(h).ok()?))
}

fn from_native(
    name: &str,
    size: Option<(u32, u32)>,
    subpixel: Subpixel,
    edid: Option<&[u8]>,
) -> PhysicalProperties {
    let mut properties = PhysicalProperties {
        size: valid_size(size).unwrap_or((0, 0)).into(),
        subpixel,
        make: "Unknown".into(),
        model: name.into(),
        // A connector ID is not a monitor serial number.
        serial_number: String::new(),
    };
    let Some(base) = edid.and_then(valid_edid_base) else {
        return properties;
    };
    if valid_size(size).is_none() && base[21] != 0 && base[22] != 0 {
        // One zero byte in EDID 1.4 describes aspect ratio, not centimetres.
        properties.size = (i32::from(base[21]) * 10, i32::from(base[22]) * 10).into();
    }
    let vendor = u16::from_be_bytes([base[8], base[9]]);
    let letters = [(vendor >> 10) & 31, (vendor >> 5) & 31, vendor & 31];
    if vendor & 0x8000 == 0 && letters.iter().all(|letter| (1..=26).contains(letter)) {
        properties.make = letters
            .iter()
            .map(|letter| (b'A' + *letter as u8 - 1) as char)
            .collect();
    }
    let product = u16::from_le_bytes([base[10], base[11]]);
    if product != 0 {
        properties.model = format!("{product:04X}");
    }
    let serial = u32::from_le_bytes(base[12..16].try_into().unwrap());
    if serial != 0 && serial != u32::MAX {
        properties.serial_number = serial.to_string();
    }
    for descriptor in base[54..126].chunks_exact(18) {
        if descriptor[..3] != [0, 0, 0] || descriptor[4] != 0 {
            continue;
        }
        if let Some(text) = descriptor_text(&descriptor[5..18]) {
            match descriptor[3] {
                0xfc => properties.model = text,
                0xff => properties.serial_number = text,
                _ => {}
            }
        }
    }
    properties
}

fn valid_edid_base(data: &[u8]) -> Option<&[u8]> {
    if data.len() < 128
        || data[..8] != [0, 255, 255, 255, 255, 255, 255, 0]
        || data[18] != 1
        || data[19] > 4
    {
        return None;
    }
    let length = (usize::from(data[126]) + 1) * 128;
    let blocks = data.get(..length)?;
    if blocks
        .chunks_exact(128)
        .any(|block| block.iter().fold(0u8, |sum, b| sum.wrapping_add(*b)) != 0)
    {
        return None;
    }
    Some(&data[..128])
}

fn descriptor_text(bytes: &[u8]) -> Option<String> {
    let end = bytes
        .iter()
        .position(|b| *b == b'\n')
        .unwrap_or(bytes.len());
    let text = &bytes[..end];
    if !text.iter().all(|b| (0x20..=0x7e).contains(b)) {
        return None;
    }
    let text = std::str::from_utf8(text).ok()?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

pub(super) fn same(a: &PhysicalProperties, b: &PhysicalProperties) -> bool {
    a.size == b.size
        && a.subpixel == b.subpixel
        && a.make == b.make
        && a.model == b.model
        && a.serial_number == b.serial_number
}

#[cfg(test)]
mod tests {
    use super::*;

    fn checksum(data: &mut [u8]) {
        data[127] = 0;
        data[127] = 0u8.wrapping_sub(data.iter().fold(0u8, |sum, b| sum.wrapping_add(*b)));
    }

    fn edid() -> Vec<u8> {
        let mut data = vec![0; 128];
        data[..8].copy_from_slice(&[0, 255, 255, 255, 255, 255, 255, 0]);
        data[8..10].copy_from_slice(&0x0443u16.to_be_bytes()); // ABC
        data[10..12].copy_from_slice(&0x1234u16.to_le_bytes());
        data[12..16].copy_from_slice(&42u32.to_le_bytes());
        data[18] = 1;
        data[19] = 4;
        data[21] = 52;
        data[22] = 29;
        data[57] = 0xfc;
        data[59..72].copy_from_slice(b"Real Panel\n  ");
        checksum(&mut data);
        data
    }

    #[test]
    fn io_failure_preserves_known_metadata_but_missing_edid_does_not() {
        let previous = from_native("DP-1", None, Subpixel::Unknown, Some(&edid()));
        assert!(same(
            &previous,
            &resolve(None, Some(previous.clone()), "DP-1")
        ));
        assert!(!same(
            &previous,
            &resolve(Some(unknown("DP-1")), Some(previous.clone()), "DP-1")
        ));
        assert_eq!(resolve(None, None, "DP-1").make, "Unknown");
    }

    #[test]
    fn native_dimensions_and_subpixel_take_precedence() {
        let p = from_native(
            "DP-1",
            Some((521, 293)),
            Subpixel::HorizontalBgr,
            Some(&edid()),
        );
        assert_eq!(p.size, (521, 293).into());
        assert_eq!(p.subpixel, Subpixel::HorizontalBgr);
        assert_eq!(
            (p.make.as_str(), p.model.as_str(), p.serial_number.as_str()),
            ("ABC", "Real Panel", "42")
        );
    }

    #[test]
    fn missing_and_invalid_metadata_stay_unknown() {
        for size in [None, Some((0, 20)), Some((20, 0)), Some((u32::MAX, 20))] {
            let p = from_native("eDP-1", size, Subpixel::Unknown, None);
            assert_eq!(p.size, (0, 0).into());
            assert_eq!(p.make, "Unknown");
            assert_eq!(p.model, "eDP-1");
            assert!(p.serial_number.is_empty());
        }
        let good = edid();
        for length in 0..128 {
            assert!(valid_edid_base(&good[..length]).is_none());
        }
        let mut bad = good.clone();
        bad[21] ^= 1;
        assert!(valid_edid_base(&bad).is_none());
        bad = good.clone();
        bad[0] = 1;
        checksum(&mut bad);
        assert!(valid_edid_base(&bad).is_none());
        bad = good;
        bad[126] = 1;
        checksum(&mut bad);
        assert!(valid_edid_base(&bad).is_none());
        bad.extend([0; 128]);
        assert!(valid_edid_base(&bad).is_some());
        bad[128] = 1;
        assert!(valid_edid_base(&bad).is_none());
    }

    #[test]
    fn aspect_ratio_and_malformed_text_are_not_metadata() {
        let mut data = edid();
        data[22] = 0;
        data[59] = 0xff;
        data[8..10].copy_from_slice(&0u16.to_be_bytes());
        checksum(&mut data);
        let p = from_native("DP-1", None, Subpixel::None, Some(&data));
        assert_eq!(p.size, (0, 0).into());
        assert_eq!(p.make, "Unknown");
        assert_eq!(p.model, "1234");
        assert_eq!(p.subpixel, Subpixel::None);
    }

    #[test]
    fn reconnect_refreshes_identity_and_rotation_does_not_change_panel_axes() {
        let first = from_native("DP-1", None, Subpixel::VerticalRgb, Some(&edid()));
        assert_eq!(first.size, (520, 290).into());
        // Transform is intentionally not an input: the same native properties
        // accompany Normal, 90/180/270 and flipped logical configurations.
        let rotated = from_native("DP-1", None, Subpixel::VerticalRgb, Some(&edid()));
        assert!(same(&first, &rotated));
        let output = smithay::output::Output::new("DP-1".into(), first.clone());
        use smithay::utils::Transform;
        for transform in [
            Transform::Normal,
            Transform::_90,
            Transform::_180,
            Transform::_270,
            Transform::Flipped,
            Transform::Flipped90,
            Transform::Flipped180,
            Transform::Flipped270,
        ] {
            output.change_current_state(None, Some(transform), None, None);
            assert!(same(&first, &output.physical_properties()));
        }
        let mut replacement = edid();
        replacement[12] = 43;
        checksum(&mut replacement);
        let reconnected = from_native("DP-1", None, Subpixel::VerticalRgb, Some(&replacement));
        assert!(!same(&first, &reconnected));
        assert!(!same(
            &first,
            &from_native("DP-1", None, Subpixel::Unknown, None)
        ));
    }
}
