//! Output color: the sRGB scene converted to a display's own primaries, or
//! to BT.2100 PQ for a display in HDR, applied after composition so captures
//! keep the scene.

use super::color_space::{
    BT2020, Matrix, SRGB, SceneEncoding, Xy, bradford, invert, multiply, rgb_to_xyz, xyz,
};
use super::{DrmDeviceFd, OutputId};
use smithay::reexports::drm::control::{Device, connector};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// Displays this close to sRGB in every chromaticity are left untouched.
const SRGB_TOLERANCE: f64 = 0.004;

/// Linear-light sRGB-to-output matrix, column-major for a GLSL `mat3`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct OutputColor {
    pub(super) matrix: [f32; 9],
    /// SDR white in cd/m² when the output reads PQ (the matrix then goes to
    /// the signal's primaries); 0 for an SDR output.
    pub(super) pq_white: f32,
}

/// What a display's EDID says about its color.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(super) struct DisplayColor {
    pub(super) correction: Option<OutputColor>,
    pub(super) hdr: Option<HdrCapability>,
}

/// A display that accepts BT.2100 PQ (CTA-861 HDR static metadata).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct HdrCapability {
    pub(super) primaries: [Xy; 4],
    /// cd/m².
    pub(super) max_luminance: f64,
    pub(super) max_frame_average: f64,
    pub(super) min_luminance: f64,
}

/// How an output shows HDR: the SDR white it puts the desktop at and the
/// primaries its PQ signal carries.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct HdrMode {
    pub(super) white: f64,
    pub(super) primaries: SignalPrimaries,
}

/// BT.2020 is BT.2100's own. sRGB is for displays that show a PQ signal as
/// sRGB whatever colorimetry the connector states.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum SignalPrimaries {
    #[default]
    Bt2020,
    Srgb,
}

impl SignalPrimaries {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Bt2020 => "bt2020",
            Self::Srgb => "srgb",
        }
    }
}

/// An output showing HDR: its display and how it shows it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct HdrOutput {
    pub(super) display: HdrCapability,
    pub(super) white: f64,
    pub(super) primaries: SignalPrimaries,
}

/// BT.2408's reference white, where SDR content sits in an HDR signal.
pub(super) const DEFAULT_SDR_WHITE: f64 = 203.0;
pub(super) const SDR_WHITE_RANGE: std::ops::RangeInclusive<f64> = 80.0..=1000.0;

impl HdrOutput {
    /// How far above SDR white the display reaches.
    pub(super) fn headroom(self) -> f64 {
        (self.display.max_luminance / self.white).max(1.0)
    }

    pub(super) fn new(display: HdrCapability, mode: HdrMode) -> Self {
        Self {
            display,
            white: mode.white,
            primaries: mode.primaries,
        }
    }

    pub(super) fn mode(self) -> HdrMode {
        HdrMode {
            white: self.white,
            primaries: self.primaries,
        }
    }

    pub(super) fn output_color(self) -> OutputColor {
        // Both share D65, so this is only the change of primaries.
        let matrix = match self.primaries {
            SignalPrimaries::Bt2020 => rgb_to_xyz(BT2020)
                .and_then(invert)
                .zip(rgb_to_xyz(SRGB))
                .map(|(to_bt2020, from_srgb)| multiply(to_bt2020, from_srgb))
                .expect("sRGB and BT.2020 are valid primaries"),
            SignalPrimaries::Srgb => [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
        };
        OutputColor {
            matrix: column_major(matrix),
            pq_white: self.white as f32,
        }
    }
}

/// The mode per connector name for every output asked to show HDR.
static HDR_REQUESTS: Mutex<BTreeMap<String, HdrMode>> = Mutex::new(BTreeMap::new());

pub(super) fn hdr_request(output: &str) -> Option<HdrMode> {
    HDR_REQUESTS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(output)
        .copied()
}

/// Forgets every HDR request; true when there was one.
pub(super) fn clear_hdr_requests() -> bool {
    let mut requests = HDR_REQUESTS.lock().unwrap_or_else(PoisonError::into_inner);
    let any = !requests.is_empty();
    requests.clear();
    any
}

pub(super) fn set_hdr_request(output: &str, mode: Option<HdrMode>) {
    let mut requests = HDR_REQUESTS.lock().unwrap_or_else(PoisonError::into_inner);
    match mode {
        Some(mode) => requests.insert(output.to_owned(), mode),
        None => requests.remove(output),
    };
}

/// One output as the output pools were last built.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct HdrDisplay {
    pub(super) id: OutputId,
    pub(super) name: String,
    pub(super) display: HdrCapability,
    /// How it shows HDR, or `None` while it shows SDR.
    pub(super) active: Option<HdrMode>,
}

static HDR_DISPLAYS: Mutex<Vec<HdrDisplay>> = Mutex::new(Vec::new());
/// The scene's headroom as `f64` bits; zero while every output is SDR.
static SCENE_HEADROOM: AtomicU64 = AtomicU64::new(0);

pub(super) fn hdr_displays() -> Vec<HdrDisplay> {
    HDR_DISPLAYS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

pub(super) fn set_hdr_displays(displays: Vec<HdrDisplay>) {
    let headroom = displays
        .iter()
        .filter_map(|display| {
            display
                .active
                .map(|mode| HdrOutput::new(display.display, mode).headroom())
        })
        .reduce(f64::max);
    SCENE_HEADROOM.store(headroom.map_or(0, f64::to_bits), Ordering::Release);
    *HDR_DISPLAYS.lock().unwrap_or_else(PoisonError::into_inner) = displays;
}

pub(super) fn hdr_output(id: OutputId) -> Option<HdrOutput> {
    HDR_DISPLAYS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|display| display.id == id)
        .and_then(|display| {
            display
                .active
                .map(|mode| HdrOutput::new(display.display, mode))
        })
}

/// How the scene stores color. With an output in HDR it is extended: SDR
/// white stays 1.0 and highlights reach the brightest HDR display's headroom.
pub(super) fn scene_encoding() -> SceneEncoding {
    match SCENE_HEADROOM.load(Ordering::Acquire) {
        0 => SceneEncoding::SDR,
        bits => SceneEncoding {
            headroom: f64::from_bits(bits),
            extended: true,
        },
    }
}

/// Off shows every display's own response, to compare it with the correction.
static CORRECTION: AtomicBool = AtomicBool::new(true);

pub(super) fn correction_enabled() -> bool {
    CORRECTION.load(Ordering::Relaxed)
}

pub(super) fn set_correction(enabled: bool) {
    CORRECTION.store(enabled, Ordering::Relaxed);
}

/// A look: a 3D LUT over sRGB-encoded color. The desktop look grades the
/// whole scene before any display correction, so it reads the same on every
/// display and never in captures; an app look grades one app's windows and
/// is part of the scene.
#[derive(Debug, PartialEq)]
pub(super) struct Lut {
    pub(super) size: usize,
    pub(super) title: Option<String>,
    /// RGBA texels, red fastest, then green, then blue (the `.cube` order).
    pub(super) texels: Vec<f32>,
}

const LARGEST_LUT: usize = 65;

static DESKTOP_LUT: Mutex<Option<Arc<Lut>>> = Mutex::new(None);
/// Bumped on every change; zero means no look was ever loaded.
static DESKTOP_LUT_GENERATION: AtomicU64 = AtomicU64::new(0);

pub(super) fn desktop_lut_generation() -> u64 {
    DESKTOP_LUT_GENERATION.load(Ordering::Acquire)
}

pub(super) fn desktop_lut() -> Option<Arc<Lut>> {
    DESKTOP_LUT
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

pub(super) fn set_desktop_lut(lut: Option<Lut>) {
    *DESKTOP_LUT.lock().unwrap_or_else(PoisonError::into_inner) = lut.map(Arc::new);
    DESKTOP_LUT_GENERATION.fetch_add(1, Ordering::AcqRel);
}

static APP_LUTS: Mutex<BTreeMap<String, Arc<Lut>>> = Mutex::new(BTreeMap::new());
static APP_LUTS_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Whether any app has a look: lets every other texture skip the lookup.
pub(super) fn app_luts_active() -> bool {
    APP_LUTS_ACTIVE.load(Ordering::Acquire)
}

pub(super) fn app_lut(app_id: &str) -> Option<Arc<Lut>> {
    APP_LUTS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(app_id)
        .cloned()
}

pub(super) fn app_luts() -> Vec<(String, Arc<Lut>)> {
    APP_LUTS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .map(|(app_id, lut)| (app_id.clone(), Arc::clone(lut)))
        .collect()
}

pub(super) fn set_app_lut(app_id: &str, lut: Option<Lut>) {
    let mut luts = APP_LUTS.lock().unwrap_or_else(PoisonError::into_inner);
    match lut {
        Some(lut) => {
            luts.insert(app_id.to_owned(), Arc::new(lut));
        }
        None => {
            luts.remove(app_id);
        }
    }
    APP_LUTS_ACTIVE.store(!luts.is_empty(), Ordering::Release);
}

/// Parse an Adobe/Resolve `.cube` 3D LUT over the 0..1 domain.
pub(super) fn parse_cube(text: &str) -> Result<Lut, String> {
    let mut size = None;
    let mut title = None;
    let mut texels = Vec::new();
    for (index, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (keyword, rest) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
        let rest = rest.trim();
        let numbers = || -> Result<Vec<f32>, String> {
            rest.split_whitespace()
                .map(|word| word.parse::<f32>().ok().filter(|v| v.is_finite()))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| format!("line {}: expected numbers", index + 1))
        };
        match keyword {
            "TITLE" => title = Some(rest.trim_matches('"').to_owned()),
            "LUT_3D_SIZE" => {
                let n = rest
                    .parse::<usize>()
                    .ok()
                    .filter(|n| (2..=LARGEST_LUT).contains(n))
                    .ok_or_else(|| format!("LUT_3D_SIZE must be 2 to {LARGEST_LUT}"))?;
                size = Some(n);
                texels.reserve(n * n * n * 4);
            }
            "LUT_1D_SIZE" => return Err("1D LUTs are not supported; use a 3D LUT".into()),
            "DOMAIN_MIN" if numbers()? == [0.0; 3] => {}
            "DOMAIN_MAX" if numbers()? == [1.0; 3] => {}
            "LUT_3D_INPUT_RANGE" if numbers()? == [0.0, 1.0] => {}
            "DOMAIN_MIN" | "DOMAIN_MAX" | "LUT_3D_INPUT_RANGE" => {
                return Err("only LUTs over the 0..1 domain are supported".into());
            }
            _ if keyword.starts_with(|c: char| c.is_ascii_alphabetic()) => {}
            _ => {
                let rgb = numbers().map(|mut values| {
                    values.insert(0, keyword.parse().unwrap_or(f32::NAN));
                    values
                })?;
                if rgb.len() != 3 || !rgb.iter().all(|v| v.is_finite()) {
                    return Err(format!("line {}: expected three numbers", index + 1));
                }
                texels.extend_from_slice(&[rgb[0], rgb[1], rgb[2], 1.0]);
            }
        }
    }
    let size = size.ok_or("the file has no LUT_3D_SIZE")?;
    let expected = size * size * size;
    if texels.len() != expected * 4 {
        return Err(format!(
            "LUT_3D_SIZE {size} needs {expected} entries, the file has {}",
            texels.len() / 4
        ));
    }
    Ok(Lut {
        size,
        title: title.filter(|title| !title.is_empty()),
        texels,
    })
}

/// Read the output's EDID: its correction, if it needs one, and its HDR.
pub(super) fn read(drm: &DrmDeviceFd, id: OutputId) -> DisplayColor {
    let edid = || -> Option<Vec<u8>> {
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
                    .flatten();
            }
        }
        None
    };
    edid().map_or_else(DisplayColor::default, |edid| from_edid(&edid))
}

fn from_edid(edid: &[u8]) -> DisplayColor {
    if edid.len() < 128 || edid[..8] != [0, 255, 255, 255, 255, 255, 255, 0] {
        return DisplayColor::default();
    }
    let primaries = edid_chromaticities(edid);
    if primaries
        .iter()
        .any(|&(x, y)| !(0.0..1.0).contains(&x) || !(0.0..1.0).contains(&y) || y == 0.0)
    {
        return DisplayColor::default();
    }
    let near_srgb = primaries
        .iter()
        .zip(SRGB)
        .all(|(a, b)| (a.0 - b.0).abs() <= SRGB_TOLERANCE && (a.1 - b.1).abs() <= SRGB_TOLERANCE);
    let correction = (!near_srgb)
        .then(|| srgb_to(primaries))
        .flatten()
        .map(|matrix| OutputColor {
            matrix: column_major(matrix),
            pq_white: 0.0,
        });
    let hdr = hdr_static_metadata(edid).map(|(max, average, min)| HdrCapability {
        primaries,
        max_luminance: max,
        max_frame_average: average,
        min_luminance: min,
    });
    DisplayColor { correction, hdr }
}

fn column_major(matrix: Matrix) -> [f32; 9] {
    std::array::from_fn(|index| matrix[index % 3][index / 3] as f32)
}

/// The CTA-861 HDR static metadata block of a PQ display: its desired
/// maximum, frame-average maximum and minimum luminance in cd/m².
fn hdr_static_metadata(edid: &[u8]) -> Option<(f64, f64, f64)> {
    const PQ: u8 = 1 << 2;
    let extensions = usize::from(edid[126]);
    for block in edid[128..].chunks_exact(128).take(extensions) {
        // A CTA extension; its data blocks run from byte 4 to the DTD offset.
        if block[0] != 0x02 || block[2] < 4 {
            continue;
        }
        let end = usize::from(block[2]).min(127);
        let mut at = 4;
        while at < end {
            let (tag, length) = (block[at] >> 5, usize::from(block[at] & 31));
            let data = block.get(at + 1..at + 1 + length)?;
            at += 1 + length;
            // Extended tag 6: HDR static metadata.
            if tag != 7 || data.first() != Some(&6) || data.len() < 3 || data[1] & PQ == 0 {
                continue;
            }
            let code = |index: usize| data.get(index).copied().filter(|&code| code != 0);
            let max = code(3).map_or(1000.0, |code| 50.0 * 2f64.powf(f64::from(code) / 32.0));
            let average = code(4).map_or(max, |code| 50.0 * 2f64.powf(f64::from(code) / 32.0));
            let min = code(5).map_or(0.005, |code| {
                max * (f64::from(code) / 255.0).powi(2) / 100.0
            });
            return Some((max, average.min(max), min));
        }
    }
    None
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
        let color = from_edid(&edid_with(QD_OLED))
            .correction
            .expect("wide gamut needs correction");
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

    fn identity_cube(size: usize) -> String {
        let mut text =
            format!("# test\nTITLE \"Identity\"\nLUT_3D_SIZE {size}\nDOMAIN_MIN 0 0 0\n");
        let step = |i: usize| i as f32 / (size - 1) as f32;
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    text += &format!("{} {} {}\n", step(r), step(g), step(b));
                }
            }
        }
        text
    }

    #[test]
    fn a_cube_file_reads_red_fastest() {
        let lut = parse_cube(&identity_cube(3)).expect("valid cube");
        assert_eq!((lut.size, lut.title.as_deref()), (3, Some("Identity")));
        // Second entry: red has moved one step, green and blue have not.
        assert_eq!(&lut.texels[4..8], &[0.5, 0.0, 0.0, 1.0]);
        // Last entry is white.
        assert_eq!(&lut.texels[lut.texels.len() - 4..], &[1.0, 1.0, 1.0, 1.0]);
    }

    #[test]
    fn malformed_cube_files_are_refused() {
        let short = identity_cube(3)
            .lines()
            .take(20)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(parse_cube(&short).unwrap_err().contains("needs 27 entries"));
        assert!(parse_cube("LUT_1D_SIZE 4\n0 0 0\n").is_err());
        assert!(parse_cube("LUT_3D_SIZE 2\nDOMAIN_MAX 2 2 2\n").is_err());
        assert!(parse_cube("LUT_3D_SIZE 99\n").is_err());
        assert!(parse_cube("0 0 0\n").is_err());
        assert!(parse_cube(&identity_cube(2).replace("1 1 1", "1 nan 1")).is_err());
    }

    #[test]
    fn srgb_displays_and_bad_edids_are_left_alone() {
        assert_eq!(from_edid(&edid_with(SRGB)), DisplayColor::default());
        assert_eq!(
            from_edid(&edid_with([(0.0, 0.0); 4])),
            DisplayColor::default()
        );
        assert_eq!(from_edid(&[0; 64]), DisplayColor::default());
    }

    /// A base block plus one CTA extension holding an HDR static metadata
    /// block with the given EOTF bits and luminance codes.
    fn hdr_edid(eotf: u8, codes: &[u8]) -> Vec<u8> {
        let mut edid = edid_with(QD_OLED);
        edid[126] = 1;
        let mut cta = vec![0; 128];
        cta[0] = 0x02;
        cta[1] = 3;
        let mut block = vec![(7 << 5) | (3 + codes.len() as u8), 6, eotf, 1];
        block.extend_from_slice(codes);
        cta[4..4 + block.len()].copy_from_slice(&block);
        cta[2] = (4 + block.len()) as u8;
        edid.extend_from_slice(&cta);
        edid
    }

    #[test]
    fn a_pq_display_reports_its_luminance() {
        // The codes an AOC AG276QZD2 reports: about 455, 254 and 0.0003 cd/m².
        let hdr = from_edid(&hdr_edid(0b111, &[102, 75, 2]))
            .hdr
            .expect("PQ display");
        assert!((hdr.max_luminance - 455.5).abs() < 0.1, "{hdr:?}");
        assert!((hdr.max_frame_average - 253.8).abs() < 0.1, "{hdr:?}");
        assert!(
            hdr.min_luminance > 0.0 && hdr.min_luminance < 0.001,
            "{hdr:?}"
        );
        assert_eq!(hdr.primaries, edid_chromaticities(&edid_with(QD_OLED)));
    }

    #[test]
    fn only_pq_displays_offer_hdr() {
        assert!(from_edid(&hdr_edid(0b011, &[102])).hdr.is_none());
        assert!(from_edid(&edid_with(QD_OLED)).hdr.is_none());
        let unknown = from_edid(&hdr_edid(0b100, &[])).hdr.expect("PQ display");
        assert_eq!(unknown.max_luminance, 1000.0);
    }

    #[test]
    fn an_hdr_output_keeps_white_and_states_its_headroom() {
        let display = from_edid(&hdr_edid(0b111, &[102, 75, 2])).hdr.unwrap();
        let output = HdrOutput {
            display,
            white: DEFAULT_SDR_WHITE,
            primaries: SignalPrimaries::Bt2020,
        };
        assert!((output.headroom() - 455.5 / 203.0).abs() < 1e-3);
        let color = output.output_color();
        assert_eq!(color.pq_white, 203.0);
        let white = column_major_apply(color, [1.0, 1.0, 1.0]);
        assert!(white.iter().all(|v| (v - 1.0).abs() < 1e-4), "{white:?}");
        // sRGB red sits well inside BT.2020.
        let red = column_major_apply(color, [1.0, 0.0, 0.0]);
        assert!(red[0] > 0.6 && red[0] < 0.65 && red[1] > 0.0, "{red:?}");
        let dim = HdrOutput {
            display,
            white: 600.0,
            primaries: SignalPrimaries::Bt2020,
        };
        assert_eq!(dim.headroom(), 1.0);
        let srgb = HdrOutput {
            primaries: SignalPrimaries::Srgb,
            ..output
        };
        let red = column_major_apply(srgb.output_color(), [1.0, 0.0, 0.0]);
        assert_eq!(red, [1.0, 0.0, 0.0]);
    }

    #[test]
    fn the_scene_turns_extended_with_an_hdr_output() {
        let display = from_edid(&hdr_edid(0b111, &[102, 75, 2])).hdr.unwrap();
        let entry = |white: Option<f64>| HdrDisplay {
            id: OutputId(7),
            name: "DP-4".into(),
            display,
            active: white.map(|white| HdrMode {
                white,
                primaries: SignalPrimaries::Bt2020,
            }),
        };
        set_hdr_displays(vec![entry(None)]);
        assert_eq!(scene_encoding(), SceneEncoding::SDR);
        set_hdr_displays(vec![entry(Some(203.0))]);
        let scene = scene_encoding();
        assert!(scene.extended && (scene.headroom - 455.5 / 203.0).abs() < 1e-3);
        assert_eq!(
            hdr_output(OutputId(7)).map(|output| output.white),
            Some(203.0)
        );
        set_hdr_displays(Vec::new());
        assert_eq!(scene_encoding(), SceneEncoding::SDR);
    }
}
