//! Colorimetry shared by the color-management protocol and the renderer:
//! image descriptions with their named primaries and transfer functions, and
//! the conversion of a surface's colors into the scene encoding.
//!
//! The scene is sRGB-primaried and gamma 2.2 encoded, with 1.0 at SDR
//! reference white. Each tagged surface is decoded to linear light, anchored
//! at its own reference white, moved to the scene primaries, tone mapped into
//! the scene's headroom and encoded again.

pub(crate) type Matrix = [[f64; 3]; 3];
pub(crate) type Xy = (f64, f64);
/// Red, green and blue primaries, then the white point.
pub(crate) type Chromaticities = [Xy; 4];

const D65: Xy = (0.3127, 0.3290);
const ILLUMINANT_C: Xy = (0.310, 0.316);
pub(crate) const SRGB: Chromaticities = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06), D65];
pub(crate) const BT2020: Chromaticities = [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046), D65];

/// `wp_color_manager_v1.primaries` values and their chromaticities. CIE 1931
/// XYZ has a blue primary at y = 0, so its matrix is written out instead.
pub(crate) fn named_primaries(name: u32) -> Option<Chromaticities> {
    Some(match name {
        1 => SRGB,
        2 => [(0.67, 0.33), (0.21, 0.71), (0.14, 0.08), ILLUMINANT_C],
        3 => [(0.64, 0.33), (0.29, 0.60), (0.15, 0.06), D65],
        4 => [(0.630, 0.340), (0.310, 0.595), (0.155, 0.070), D65],
        5 => [(0.681, 0.319), (0.243, 0.692), (0.145, 0.049), ILLUMINANT_C],
        6 => BT2020,
        7 => [(1.0, 0.0), (0.0, 1.0), (0.0, 0.0), (1.0 / 3.0, 1.0 / 3.0)],
        8 => [
            (0.680, 0.320),
            (0.265, 0.690),
            (0.150, 0.060),
            (0.314, 0.351),
        ],
        9 => [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060), D65],
        10 => [(0.64, 0.33), (0.21, 0.71), (0.15, 0.06), D65],
        _ => return None,
    })
}

pub(crate) const NAMED_PRIMARIES: [u32; 10] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
const CIE1931_XYZ: u32 = 7;

/// `wp_color_manager_v1.transfer_function`, or a pure power curve.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TransferFunction {
    Named(u32),
    /// Exponent times 10000, 10000..=100000.
    Power(u32),
}

pub(crate) mod tf {
    pub(crate) const BT1886: u32 = 1;
    pub(crate) const GAMMA22: u32 = 2;
    pub(crate) const GAMMA28: u32 = 3;
    pub(crate) const ST240: u32 = 4;
    pub(crate) const EXT_LINEAR: u32 = 5;
    pub(crate) const LOG_100: u32 = 6;
    pub(crate) const LOG_316: u32 = 7;
    pub(crate) const XVYCC: u32 = 8;
    pub(crate) const SRGB: u32 = 9;
    pub(crate) const EXT_SRGB: u32 = 10;
    pub(crate) const ST2084_PQ: u32 = 11;
    pub(crate) const ST428: u32 = 12;
    pub(crate) const HLG: u32 = 13;
    pub(crate) const COMPOUND_POWER_2_4: u32 = 14;
}

/// Named transfer functions a client of `version` may use: version 2
/// deprecated the ambiguous sRGB pair and added compound power 2.4.
pub(crate) fn named_transfer_functions(version: u32) -> Vec<u32> {
    let mut names = vec![
        tf::BT1886,
        tf::GAMMA22,
        tf::GAMMA28,
        tf::ST240,
        tf::EXT_LINEAR,
        tf::LOG_100,
        tf::LOG_316,
        tf::XVYCC,
        tf::ST2084_PQ,
        tf::ST428,
        tf::HLG,
    ];
    if version < 2 {
        names.extend([tf::SRGB, tf::EXT_SRGB]);
    } else {
        names.push(tf::COMPOUND_POWER_2_4);
    }
    names
}

/// Luminances in cd/m².
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Luminances {
    pub(crate) min: f64,
    pub(crate) max: f64,
    pub(crate) reference: f64,
}

impl TransferFunction {
    /// The luminances implied when a client sets none.
    pub(crate) fn default_luminances(self) -> Luminances {
        match self {
            Self::Named(tf::BT1886) => Luminances {
                min: 0.01,
                max: 100.0,
                reference: 100.0,
            },
            Self::Named(tf::ST2084_PQ) => Luminances {
                min: 0.005,
                max: 10_000.005,
                reference: 203.0,
            },
            Self::Named(tf::HLG) => Luminances {
                min: 0.005,
                max: 1000.0,
                reference: 203.0,
            },
            _ => Luminances {
                min: 0.2,
                max: 80.0,
                reference: 80.0,
            },
        }
    }
}

/// The rendering intents Denial honours.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RenderIntent {
    /// Highlights above the scene's headroom roll off.
    Perceptual,
    /// Colors are reproduced exactly where they fit and clipped elsewhere.
    Relative,
}

impl RenderIntent {
    pub(crate) fn from_protocol(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::Perceptual),
            1 => Some(Self::Relative),
            _ => None,
        }
    }
}

/// A complete parametric image description.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ImageDescription {
    pub(crate) tf: TransferFunction,
    pub(crate) primaries: Chromaticities,
    pub(crate) primaries_named: Option<u32>,
    pub(crate) luminances: Luminances,
    pub(crate) target_primaries: Chromaticities,
    /// Minimum and maximum, cd/m².
    pub(crate) target_luminance: (f64, f64),
    pub(crate) max_cll: Option<f64>,
    pub(crate) max_fall: Option<f64>,
}

impl ImageDescription {
    /// What the scene expects: sRGB primaries and gamma 2.2 with the
    /// default sRGB luminances.
    pub(crate) fn srgb() -> Self {
        Self::named(1, TransferFunction::Named(tf::GAMMA22))
    }

    /// Windows scRGB: sRGB primaries, extended linear, 1.0 at 80 cd/m²,
    /// reference white assumed at 203 cd/m².
    pub(crate) fn windows_scrgb() -> Self {
        let mut description = Self::named(1, TransferFunction::Named(tf::EXT_LINEAR));
        description.luminances = Luminances {
            min: 0.0,
            max: 80.0,
            reference: 203.0,
        };
        description.target_primaries = BT2020;
        description.target_luminance = (0.0, 10_000.0);
        description
    }

    /// Windows BT.2100: BT.2020 primaries and PQ.
    pub(crate) fn windows_bt2100() -> Self {
        Self::named(6, TransferFunction::Named(tf::ST2084_PQ))
    }

    /// A display showing BT.2100 PQ: SDR white at the desktop's white, the
    /// display's own gamut and luminance as the target.
    pub(crate) fn hdr_output(output: crate::output_color::HdrOutput) -> Self {
        let display = output.display;
        let mut description = Self::windows_bt2100();
        description.luminances.reference = output.white;
        description.target_primaries = display.primaries;
        description.target_luminance = (display.min_luminance, display.max_luminance);
        description.max_cll = Some(display.max_luminance);
        description.max_fall = Some(display.max_frame_average);
        description
    }

    fn named(primaries: u32, tf: TransferFunction) -> Self {
        let chromaticities = named_primaries(primaries).expect("known named primaries");
        let luminances = tf.default_luminances();
        Self {
            tf,
            primaries: chromaticities,
            primaries_named: Some(primaries),
            luminances,
            target_primaries: chromaticities,
            target_luminance: (luminances.min, luminances.max),
            max_cll: None,
            max_fall: None,
        }
    }

    /// The brightest light the content claims, relative to its reference
    /// white.
    fn peak(&self) -> f64 {
        let ceiling = self.max_cll.map_or(self.target_luminance.1, |cll| {
            cll.min(self.target_luminance.1)
        });
        ceiling / self.luminances.reference
    }

    /// Whether the renderer can convert this content: its primaries span a
    /// color space and its luminances are finite.
    pub(crate) fn supported(&self) -> bool {
        let luminances = [
            self.luminances.min,
            self.luminances.max,
            self.luminances.reference,
            self.target_luminance.0,
            self.target_luminance.1,
        ];
        luminances.iter().all(|value| value.is_finite())
            && self.luminances.reference > 0.0
            && self.to_xyz().and_then(invert).is_some()
            && (self.target_primaries == self.primaries
                || rgb_to_xyz(self.target_primaries).is_some())
    }

    /// The conversion of this content into `scene`, or None when the content
    /// already is the scene encoding.
    pub(crate) fn transform(
        &self,
        intent: RenderIntent,
        scene: SceneEncoding,
    ) -> Option<SurfaceTransform> {
        let relative = self.luminances.max / self.luminances.reference;
        let (code, params, scale) = match self.tf {
            TransferFunction::Power(exponent) => (
                Decode::Power,
                [exponent as f32 / 10_000.0, 0.0, 0.0, 0.0],
                relative,
            ),
            TransferFunction::Named(name) => match name {
                // Clients that tag sRGB mean ordinary content, which sRGB
                // displays show with gamma 2.2: the scene encoding.
                tf::GAMMA22 | tf::SRGB | tf::EXT_SRGB => {
                    (Decode::Power, [2.2, 0.0, 0.0, 0.0], relative)
                }
                tf::GAMMA28 => (Decode::Power, [2.8, 0.0, 0.0, 0.0], relative),
                tf::ST428 => (Decode::Power, [2.6, 0.0, 0.0, 0.0], relative * 52.37 / 48.0),
                tf::COMPOUND_POWER_2_4 => (Decode::PiecewiseSrgb, [0.0; 4], relative),
                tf::BT1886 => {
                    // BT.1886 annex 1, in cd/m², then relative to reference.
                    let (white, black) = (self.luminances.max, self.luminances.min.max(0.0));
                    let (w, b) = (white.powf(1.0 / 2.4), black.powf(1.0 / 2.4));
                    let gain = (w - b).powf(2.4);
                    let lift = b / (w - b);
                    (
                        Decode::Bt1886,
                        [
                            lift as f32,
                            (gain / self.luminances.reference) as f32,
                            0.0,
                            0.0,
                        ],
                        1.0,
                    )
                }
                tf::ST2084_PQ => (Decode::Pq, [0.0; 4], 10_000.0 / self.luminances.reference),
                tf::HLG => {
                    // BT.2100 system gamma for the nominal peak.
                    let peak = self.luminances.max;
                    let gamma = 1.2 + 0.42 * (peak / 1000.0).log10();
                    (
                        Decode::Hlg,
                        [(gamma - 1.0) as f32, 0.0, 0.0, 0.0],
                        peak / self.luminances.reference,
                    )
                }
                tf::EXT_LINEAR => (Decode::Linear, [0.0; 4], relative),
                tf::ST240 => (Decode::St240, [0.0; 4], relative),
                tf::LOG_100 => (Decode::Log, [2.0, 0.0, 0.0, 0.0], relative),
                tf::LOG_316 => (Decode::Log, [2.5, 0.0, 0.0, 0.0], relative),
                tf::XVYCC => (Decode::Bt709, [0.0; 4], relative),
                _ => (Decode::Power, [2.2, 0.0, 0.0, 0.0], relative),
            },
        };
        let to_xyz = self.to_xyz()?;
        let to_scene = multiply(
            invert(rgb_to_xyz(SRGB)?)?,
            multiply(bradford(xyz(self.primaries[3]), xyz(D65))?, to_xyz),
        );
        let identity = code == Decode::Power
            && params[0] == 2.2
            && (scale - 1.0).abs() < 1e-3
            && (0..3).all(|row| {
                (0..3).all(|column| {
                    let expected = if row == column { 1.0 } else { 0.0 };
                    (to_scene[row][column] - expected).abs() < 2e-3
                })
            });
        if identity && !scene.extended {
            return None;
        }
        let mut matrix = [0.0; 9];
        for column in 0..3 {
            for row in 0..3 {
                matrix[column * 3 + row] = (to_scene[row][column] * scale) as f32;
            }
        }
        let headroom = scene.headroom.max(1.0);
        let knee = match intent {
            RenderIntent::Perceptual => 0.75 * headroom,
            RenderIntent::Relative => headroom,
        };
        Some(SurfaceTransform {
            decode: code as i32,
            params,
            matrix,
            luma: [
                to_xyz[1][0] as f32,
                to_xyz[1][1] as f32,
                to_xyz[1][2] as f32,
            ],
            tone: [
                self.peak() as f32,
                knee as f32,
                headroom as f32,
                f32::from(u8::from(scene.extended)),
            ],
            float: matches!(code, Decode::Pq | Decode::Hlg | Decode::Linear) || scene.extended,
        })
    }

    fn to_xyz(&self) -> Option<Matrix> {
        if self.primaries_named == Some(CIE1931_XYZ) {
            return Some([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]);
        }
        rgb_to_xyz(self.primaries)
    }

    /// One line for `denialctl color surfaces`.
    pub(crate) fn summary(&self) -> String {
        let primaries = match self.primaries_named {
            Some(1) => "sRGB".to_owned(),
            Some(2) => "PAL-M".to_owned(),
            Some(3) => "PAL".to_owned(),
            Some(4) => "NTSC".to_owned(),
            Some(5) => "generic film".to_owned(),
            Some(6) => "BT.2020".to_owned(),
            Some(7) => "CIE XYZ".to_owned(),
            Some(8) => "DCI-P3".to_owned(),
            Some(9) => "Display P3".to_owned(),
            Some(10) => "Adobe RGB".to_owned(),
            _ => {
                let [r, g, b, w] = self.primaries;
                format!(
                    "R {:.3},{:.3} G {:.3},{:.3} B {:.3},{:.3} W {:.4},{:.4}",
                    r.0, r.1, g.0, g.1, b.0, b.1, w.0, w.1
                )
            }
        };
        let tf = match self.tf {
            TransferFunction::Power(exponent) => format!("power {:.4}", exponent as f64 / 10_000.0),
            TransferFunction::Named(name) => match name {
                tf::BT1886 => "BT.1886",
                tf::GAMMA22 => "gamma 2.2",
                tf::GAMMA28 => "gamma 2.8",
                tf::ST240 => "ST 240",
                tf::EXT_LINEAR => "extended linear",
                tf::LOG_100 => "log 100:1",
                tf::LOG_316 => "log 316:1",
                tf::XVYCC => "xvYCC",
                tf::SRGB => "sRGB",
                tf::EXT_SRGB => "extended sRGB",
                tf::ST2084_PQ => "PQ",
                tf::ST428 => "ST 428",
                tf::HLG => "HLG",
                tf::COMPOUND_POWER_2_4 => "compound power 2.4",
                _ => "unknown",
            }
            .to_owned(),
        };
        let mut line = format!(
            "{primaries}, {tf}, reference {} cd/m², peak {} cd/m²",
            self.luminances.reference.round(),
            (self.peak() * self.luminances.reference).round()
        );
        if self.target_primaries != self.primaries {
            line += ", mastering primaries set";
        }
        line
    }
}

/// One immutable image description. Protocol objects that refer to the same
/// record share its identity, and identities are never reused.
#[derive(Debug)]
pub(crate) struct DescriptionRecord {
    pub(crate) identity: u64,
    pub(crate) description: ImageDescription,
    /// Whether `get_information` may describe it: true for descriptions
    /// the compositor made, false for client-made ones.
    pub(crate) informative: bool,
}

static NEXT_IDENTITY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

impl DescriptionRecord {
    pub(crate) fn new(description: ImageDescription, informative: bool) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            identity: NEXT_IDENTITY.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            description,
            informative,
        })
    }
}

/// `wp_color_representation_surface_v1.alpha_mode`.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum AlphaMode {
    #[default]
    PremultipliedElectrical = 0,
    PremultipliedOptical = 1,
    Straight = 2,
}

impl AlphaMode {
    pub(crate) fn from_protocol(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::PremultipliedElectrical),
            1 => Some(Self::PremultipliedOptical),
            2 => Some(Self::Straight),
            _ => None,
        }
    }
}

/// What a committed surface says about its pixels. Untagged surfaces with
/// premultiplied electrical alpha carry none. Equal values describe the same
/// pixels, whichever records they came from.
#[derive(Debug)]
pub(crate) struct SurfaceColor {
    pub(crate) description: Option<(std::sync::Arc<DescriptionRecord>, RenderIntent)>,
    pub(crate) alpha: AlphaMode,
}

impl PartialEq for SurfaceColor {
    fn eq(&self, other: &Self) -> bool {
        self.alpha == other.alpha
            && match (&self.description, &other.description) {
                (Some((a, a_intent)), Some((b, b_intent))) => {
                    a_intent == b_intent && a.description == b.description
                }
                (None, None) => true,
                _ => false,
            }
    }
}

impl SurfaceColor {
    /// Whether the renderer must draw this surface's pixels into a copy.
    pub(crate) fn needs_pass(&self, scene: SceneEncoding) -> bool {
        self.alpha != AlphaMode::default() || self.transform(scene).is_some()
    }

    /// The conversion into `scene`, None when the pixels already are the
    /// scene encoding; then only a non-default alpha mode needs a pass.
    pub(crate) fn transform(&self, scene: SceneEncoding) -> Option<SurfaceTransform> {
        let (record, intent) = self.description.as_ref()?;
        record.description.transform(*intent, scene)
    }
}

/// How the scene stores color.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct SceneEncoding {
    /// The brightest scene value, relative to SDR reference white.
    pub(crate) headroom: f64,
    /// The scene keeps values outside 0..=headroom: wider gamuts as negative
    /// components.
    pub(crate) extended: bool,
}

impl SceneEncoding {
    pub(crate) const SDR: Self = Self {
        headroom: 1.0,
        extended: false,
    };
}

/// Decoders of the conversion shader, by `decode` code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Decode {
    /// Mirrored power curve, exponent in params.x.
    Power = 0,
    /// IEC 61966-2-1 piecewise curve, mirrored.
    PiecewiseSrgb = 1,
    /// BT.1886: params.y · max(V + params.x, 0)^2.4.
    Bt1886 = 2,
    /// SMPTE ST 2084, 1.0 = 10000 cd/m².
    Pq = 3,
    /// HLG inverse OETF, then the OOTF with system gamma params.x + 1.
    Hlg = 4,
    Linear = 5,
    /// SMPTE ST 240 inverse OETF, mirrored.
    St240 = 6,
    /// Logarithmic, params.x decades.
    Log = 7,
    /// BT.709 inverse OETF, mirrored (xvYCC).
    Bt709 = 8,
}

/// Uniforms of the surface conversion shader.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct SurfaceTransform {
    pub(crate) decode: i32,
    pub(crate) params: [f32; 4],
    /// Column-major: decoded source light to scene linear light, with the
    /// source reference white at 1.0.
    pub(crate) matrix: [f32; 9],
    /// The source's luminance weights, for the HLG OOTF.
    pub(crate) luma: [f32; 3],
    /// Content peak, knee, headroom, extended flag.
    pub(crate) tone: [f32; 4],
    /// The converted copy needs more than 8 bits per channel.
    pub(crate) float: bool,
}

pub(crate) fn xyz((x, y): Xy) -> [f64; 3] {
    [x / y, 1.0, (1.0 - x - y) / y]
}

pub(crate) fn valid_chromaticities(primaries: &Chromaticities) -> bool {
    primaries
        .iter()
        .all(|&(x, y)| x.is_finite() && y.is_finite() && y > 0.0 && x >= 0.0 && x + y <= 1.0 + 1e-9)
}

pub(crate) fn rgb_to_xyz(primaries: Chromaticities) -> Option<Matrix> {
    if !valid_chromaticities(&primaries) {
        return None;
    }
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

pub(crate) fn bradford(from: [f64; 3], to: [f64; 3]) -> Option<Matrix> {
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

pub(crate) fn transpose(m: Matrix) -> Matrix {
    std::array::from_fn(|row| std::array::from_fn(|column| m[column][row]))
}

pub(crate) fn apply(m: Matrix, v: [f64; 3]) -> [f64; 3] {
    std::array::from_fn(|row| (0..3).map(|i| m[row][i] * v[i]).sum())
}

pub(crate) fn multiply(a: Matrix, b: Matrix) -> Matrix {
    std::array::from_fn(|row| {
        std::array::from_fn(|column| (0..3).map(|i| a[row][i] * b[i][column]).sum())
    })
}

pub(crate) fn invert(m: Matrix) -> Option<Matrix> {
    let cofactor = |row: usize, column: usize| {
        let (r0, r1) = ((row + 1) % 3, (row + 2) % 3);
        let (c0, c1) = ((column + 1) % 3, (column + 2) % 3);
        m[r0][c0] * m[r1][c1] - m[r0][c1] * m[r1][c0]
    };
    let determinant: f64 = (0..3)
        .map(|column| m[0][column] * cofactor(0, column))
        .sum();
    if determinant.abs() < 1e-12 || !determinant.is_finite() {
        return None;
    }
    Some(std::array::from_fn(|row| {
        std::array::from_fn(|column| cofactor(column, row) / determinant)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column_major_apply(matrix: [f32; 9], v: [f64; 3]) -> [f64; 3] {
        let m = matrix.map(f64::from);
        std::array::from_fn(|row| (0..3).map(|column| m[column * 3 + row] * v[column]).sum())
    }

    #[test]
    fn the_scene_encoding_needs_no_conversion() {
        assert!(
            ImageDescription::srgb()
                .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
                .is_none()
        );
    }

    #[test]
    fn every_named_primary_set_converts_white_to_white() {
        for name in NAMED_PRIMARIES {
            let mut description = ImageDescription::srgb();
            description.primaries = named_primaries(name).unwrap();
            description.primaries_named = Some(name);
            description.tf = TransferFunction::Named(tf::EXT_LINEAR);
            let transform = description
                .transform(RenderIntent::Relative, SceneEncoding::SDR)
                .unwrap_or_else(|| panic!("primaries {name} need a conversion"));
            let white = column_major_apply(transform.matrix, [1.0, 1.0, 1.0]);
            assert!(
                white.iter().all(|v| (v - 1.0).abs() < 1e-3),
                "{name}: {white:?}"
            );
        }
    }

    #[test]
    fn tagged_srgb_is_the_scene_encoding_and_compound_power_is_not() {
        let mut description = ImageDescription::srgb();
        description.tf = TransferFunction::Named(tf::SRGB);
        assert!(
            description
                .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
                .is_none()
        );
        description.tf = TransferFunction::Named(tf::COMPOUND_POWER_2_4);
        let transform = description
            .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
            .unwrap();
        assert_eq!(transform.decode, Decode::PiecewiseSrgb as i32);
    }

    #[test]
    fn bt2020_red_lands_outside_srgb() {
        let description = ImageDescription::windows_bt2100();
        let transform = description
            .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
            .unwrap();
        let red = column_major_apply(transform.matrix, [1.0, 0.0, 0.0]);
        // PQ 1.0 is 10000 cd/m², 49x the 203 cd/m² reference.
        assert!(
            red[0] > 49.0 * 1.5 && red[1] < 0.0 && red[2] < 0.0,
            "{red:?}"
        );
        assert_eq!(transform.decode, Decode::Pq as i32);
        assert!(transform.float);
        assert!((transform.tone[0] - 10_000.0 / 203.0).abs() < 0.01);
    }

    #[test]
    fn scrgb_reference_white_is_2_5375() {
        let transform = ImageDescription::windows_scrgb()
            .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
            .unwrap();
        let white = column_major_apply(transform.matrix, [2.5375, 2.5375, 2.5375]);
        assert!(white.iter().all(|v| (v - 1.0).abs() < 1e-3), "{white:?}");
    }

    #[test]
    fn bt1886_reaches_its_reference_white_at_one() {
        let mut description = ImageDescription::srgb();
        description.tf = TransferFunction::Named(tf::BT1886);
        description.luminances = description.tf.default_luminances();
        let transform = description
            .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
            .unwrap();
        let [lift, gain, ..] = transform.params.map(f64::from);
        let white = gain * (1.0 + lift).powf(2.4);
        let black = gain * lift.powf(2.4);
        assert!((white - 1.0).abs() < 1e-4, "{white}");
        assert!((black - 0.0001).abs() < 1e-5, "{black}");
    }

    #[test]
    fn hlg_uses_the_nominal_system_gamma() {
        let mut description = ImageDescription::windows_bt2100();
        description.tf = TransferFunction::Named(tf::HLG);
        description.luminances = description.tf.default_luminances();
        let transform = description
            .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
            .unwrap();
        assert!((transform.params[0] - 0.2).abs() < 1e-6);
        let luma: f32 = transform.luma.iter().sum();
        assert!((luma - 1.0).abs() < 1e-4);
    }

    #[test]
    fn relative_intent_clips_instead_of_rolling_off() {
        let description = ImageDescription::windows_bt2100();
        let perceptual = description
            .transform(RenderIntent::Perceptual, SceneEncoding::SDR)
            .unwrap();
        let relative = description
            .transform(RenderIntent::Relative, SceneEncoding::SDR)
            .unwrap();
        assert!(perceptual.tone[1] < 1.0);
        assert_eq!(relative.tone[1], 1.0);
    }

    #[test]
    fn degenerate_primaries_are_unsupported() {
        let mut description = ImageDescription::srgb();
        assert!(description.supported());
        description.primaries = [(0.3, 0.3), (0.3, 0.3), (0.3, 0.3), D65];
        description.primaries_named = None;
        assert!(!description.supported());
    }
}
