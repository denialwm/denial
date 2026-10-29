//! Output gamut correction: the sRGB scene converted to a display's own
//! primaries, applied after composition so captures keep the sRGB scene.

use super::{DrmDeviceFd, OutputId};
use smithay::reexports::drm::control::{Device, connector};

type Matrix = [[f64; 3]; 3];
type Xy = (f64, f64);

const SRGB: [Xy; 4] = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06), (0.3127, 0.3290)];
/// Displays this close to sRGB in every chromaticity are left untouched.
const SRGB_TOLERANCE: f64 = 0.004;

/// Linear-light sRGB-to-output matrix, column-major for a GLSL `mat3`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct OutputColor {
    pub(super) matrix: [f32; 9],
}

/// Read the output's EDID and return its correction, if it needs one.
pub(super) fn read(drm: &DrmDeviceFd, id: OutputId) -> Option<OutputColor> {
    let handle = u32::try_from(id.0)
        .ok()
        .and_then(std::num::NonZeroU32::new)
        .map(connector::Handle::from)?;
    for (property, value) in drm.get_properties(handle).ok()? {
        let property = drm.get_property(property).ok()?;
        if property.name().to_str() == Ok("EDID") {
            let blob = property.value_type().convert_value(value).as_blob()?;
            return (blob != 0)
                .then(|| drm.get_property_blob(blob).ok())
                .flatten()
                .and_then(|edid| from_edid(&edid));
        }
    }
    None
}

fn from_edid(edid: &[u8]) -> Option<OutputColor> {
    if edid.len() < 128 || edid[..8] != [0, 255, 255, 255, 255, 255, 255, 0] {
        return None;
    }
    let primaries = edid_chromaticities(edid);
    if primaries
        .iter()
        .any(|&(x, y)| !(0.0..1.0).contains(&x) || !(0.0..1.0).contains(&y) || y == 0.0)
    {
        return None;
    }
    let near_srgb = primaries
        .iter()
        .zip(SRGB)
        .all(|(a, b)| (a.0 - b.0).abs() <= SRGB_TOLERANCE && (a.1 - b.1).abs() <= SRGB_TOLERANCE);
    if near_srgb {
        return None;
    }
    let matrix = srgb_to(primaries)?;
    let mut columns = [0.0; 9];
    for column in 0..3 {
        for row in 0..3 {
            columns[column * 3 + row] = matrix[row][column] as f32;
        }
    }
    Some(OutputColor { matrix: columns })
}

/// Red, green, blue and white, each 10 bits split over bytes 25..=34.
fn edid_chromaticities(edid: &[u8]) -> [Xy; 4] {
    let low = |byte: u8, shift: u8| u16::from((byte >> shift) & 3);
    let value = |high: u8, low: u16| f64::from((u16::from(high) << 2) | low) / 1024.0;
    let (rg, bw) = (edid[25], edid[26]);
    [
        (value(edid[27], low(rg, 6)), value(edid[28], low(rg, 4))),
        (value(edid[29], low(rg, 2)), value(edid[30], low(rg, 0))),
        (value(edid[31], low(bw, 6)), value(edid[32], low(bw, 4))),
        (value(edid[33], low(bw, 2)), value(edid[34], low(bw, 0))),
    ]
}

/// Relative colorimetric: sRGB white maps to the output's white (Bradford).
fn srgb_to(output: [Xy; 4]) -> Option<Matrix> {
    let source = rgb_to_xyz(SRGB)?;
    let destination = invert(rgb_to_xyz(output)?)?;
    let adapt = bradford(xyz(SRGB[3]), xyz(output[3]))?;
    Some(multiply(destination, multiply(adapt, source)))
}

fn xyz((x, y): Xy) -> [f64; 3] {
    [x / y, 1.0, (1.0 - x - y) / y]
}

fn rgb_to_xyz(primaries: [Xy; 4]) -> Option<Matrix> {
    let columns = [xyz(primaries[0]), xyz(primaries[1]), xyz(primaries[2])];
    let unscaled = transpose(columns);
    let scale = apply(invert(unscaled)?, xyz(primaries[3]));
    let mut matrix = unscaled;
    for row in &mut matrix {
        for (value, scale) in row.iter_mut().zip(scale) {
            *value *= scale;
        }
    }
    Some(matrix)
}

fn bradford(from: [f64; 3], to: [f64; 3]) -> Option<Matrix> {
    const CONE: Matrix = [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296],
    ];
    let (from, to) = (apply(CONE, from), apply(CONE, to));
    let mut gain = [[0.0; 3]; 3];
    for axis in 0..3 {
        gain[axis][axis] = to[axis] / from[axis];
    }
    Some(multiply(invert(CONE)?, multiply(gain, CONE)))
}

fn transpose(m: Matrix) -> Matrix {
    std::array::from_fn(|row| std::array::from_fn(|column| m[column][row]))
}

fn apply(m: Matrix, v: [f64; 3]) -> [f64; 3] {
    std::array::from_fn(|row| (0..3).map(|i| m[row][i] * v[i]).sum())
}

fn multiply(a: Matrix, b: Matrix) -> Matrix {
    std::array::from_fn(|row| {
        std::array::from_fn(|column| (0..3).map(|i| a[row][i] * b[i][column]).sum())
    })
}

fn invert(m: Matrix) -> Option<Matrix> {
    let cofactor = |row: usize, column: usize| {
        let (r0, r1) = ((row + 1) % 3, (row + 2) % 3);
        let (c0, c1) = ((column + 1) % 3, (column + 2) % 3);
        m[r0][c0] * m[r1][c1] - m[r0][c1] * m[r1][c0]
    };
    let determinant: f64 = (0..3)
        .map(|column| m[0][column] * cofactor(0, column))
        .sum();
    if determinant.abs() < 1e-12 {
        return None;
    }
    Some(std::array::from_fn(|row| {
        std::array::from_fn(|column| cofactor(column, row) / determinant)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edid_with(primaries: [Xy; 4]) -> Vec<u8> {
        let mut edid = vec![0; 128];
        edid[..8].copy_from_slice(&[0, 255, 255, 255, 255, 255, 255, 0]);
        let code = |v: f64| (v * 1024.0).round() as u16;
        let [r, g, b, w] = primaries.map(|(x, y)| (code(x), code(y)));
        let low = |v: u16| (v & 3) as u8;
        edid[25] = low(r.0) << 6 | low(r.1) << 4 | low(g.0) << 2 | low(g.1);
        edid[26] = low(b.0) << 6 | low(b.1) << 4 | low(w.0) << 2 | low(w.1);
        for (index, v) in [r.0, r.1, g.0, g.1, b.0, b.1, w.0, w.1]
            .into_iter()
            .enumerate()
        {
            edid[27 + index] = (v >> 2) as u8;
        }
        edid
    }

    fn column_major_apply(color: OutputColor, v: [f64; 3]) -> [f64; 3] {
        let m = color.matrix.map(f64::from);
        std::array::from_fn(|row| (0..3).map(|column| m[column * 3 + row] * v[column]).sum())
    }

    /// AOC AG276QZD2 (QD-OLED) as read from its EDID on iceland's DP-1.
    const QD_OLED: [Xy; 4] = [
        (0.6855, 0.3037),
        (0.2402, 0.7119),
        (0.1435, 0.0576),
        (0.3134, 0.3291),
    ];

    #[test]
    fn edid_chromaticities_round_trip_at_ten_bits() {
        let parsed = edid_chromaticities(&edid_with(QD_OLED));
        for (a, b) in parsed.iter().zip(QD_OLED) {
            assert!((a.0 - b.0).abs() < 0.001 && (a.1 - b.1).abs() < 0.001);
        }
    }

    #[test]
    fn a_wide_gamut_display_keeps_white_and_narrows_srgb_primaries() {
        let color = from_edid(&edid_with(QD_OLED)).expect("wide gamut needs correction");
        let white = column_major_apply(color, [1.0, 1.0, 1.0]);
        assert!(white.iter().all(|v| (v - 1.0).abs() < 1e-3), "{white:?}");
        for primary in 0..3 {
            let mut input = [0.0; 3];
            input[primary] = 1.0;
            let out = column_major_apply(color, input);
            // sRGB lies inside this gamut except a sliver of blue (its blue
            // primary sits just outside); the shader clamps that sliver.
            assert!(
                out.iter().all(|v| (-0.005..=1.0 + 1e-6).contains(v)),
                "{out:?}"
            );
            assert!(out[primary] > 0.6 && out[primary] < 1.0, "{out:?}");
        }
    }

    #[test]
    fn srgb_displays_and_bad_edids_are_left_alone() {
        assert!(from_edid(&edid_with(SRGB)).is_none());
        assert!(from_edid(&edid_with([(0.0, 0.0); 4])).is_none());
        assert!(from_edid(&[0; 64]).is_none());
    }
}
