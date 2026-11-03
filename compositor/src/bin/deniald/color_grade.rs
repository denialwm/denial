//! The tuning editor's grade, baked over a target's base look into the one
//! 3D LUT the renderer already applies. Both work on the scene's encoded
//! values: sRGB primaries, gamma 2.2, SDR white at 1.
// Only the Flutter compositor reads displays and applies looks.
#![cfg_attr(not(feature = "flutter"), allow(dead_code))]

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use serde::{Deserialize, Serialize};

use super::output_color::Lut;

/// Zero everywhere is the identity.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(super) struct Grade {
    /// Stops.
    pub(super) exposure: f32,
    /// Log2 of the slope at middle grey; the ends stay put.
    pub(super) contrast: f32,
    /// Added to a saturation factor of one.
    pub(super) saturation: f32,
    /// Saturation that favours dull colors over vivid ones.
    pub(super) vibrance: f32,
    /// Warmer above zero, cooler below.
    pub(super) temperature: f32,
    /// Magenta above zero, green below.
    pub(super) tint: f32,
    /// Shadows: added per channel, fading out towards white.
    pub(super) lift: [f32; 3],
    /// Midtones: log2 of the inverse power per channel.
    pub(super) gamma: [f32; 3],
    /// Highlights: log2 of the multiplier per channel.
    pub(super) gain: [f32; 3],
}

/// Each control's range; the editor's sliders span the same.
const EXPOSURE: f32 = 3.0;
const CONTRAST: f32 = 1.5;
const LIFT: f32 = 0.25;
const GAMMA_GAIN: f32 = 1.5;

/// The size a grade without a base look bakes at.
const GRADE_LUT_SIZE: usize = 33;

/// Middle grey, encoded: the contrast pivot.
const PIVOT: f32 = 0.458_7;

impl Grade {
    pub(super) fn is_neutral(&self) -> bool {
        *self == Self::default()
    }

    pub(super) fn validate(&self) -> Result<(), String> {
        let scalars = [
            ("exposure", self.exposure, EXPOSURE),
            ("contrast", self.contrast, CONTRAST),
            ("saturation", self.saturation, 1.0),
            ("vibrance", self.vibrance, 1.0),
            ("temperature", self.temperature, 1.0),
            ("tint", self.tint, 1.0),
        ];
        let channels = [
            ("lift", self.lift, LIFT),
            ("gamma", self.gamma, GAMMA_GAIN),
            ("gain", self.gain, GAMMA_GAIN),
        ];
        let values = scalars.into_iter().chain(
            channels
                .into_iter()
                .flat_map(|(name, rgb, range)| rgb.map(|value| (name, value, range))),
        );
        for (name, value, range) in values {
            if !value.is_finite() || value.abs() > range {
                return Err(format!("{name} {value} is outside -{range}..={range}"));
            }
        }
        Ok(())
    }

    /// The grade's constants, worked out once per bake.
    fn prepared(&self) -> Prepared {
        let balance = white_balance(self.temperature, self.tint);
        let scale = self.exposure.exp2();
        Prepared {
            light: balance.map(|gain| gain * scale),
            slope: self.contrast.exp2(),
            lift: self.lift,
            gain: self.gain.map(f32::exp2),
            power: self.gamma.map(|gamma| (-gamma).exp2()),
            saturation: 1.0 + self.saturation,
            vibrance: self.vibrance,
        }
    }
}

struct Prepared {
    /// White balance times exposure, per channel.
    light: [f32; 3],
    slope: f32,
    lift: [f32; 3],
    gain: [f32; 3],
    power: [f32; 3],
    saturation: f32,
    vibrance: f32,
}

impl Prepared {
    /// One encoded color through the grade.
    fn apply(&self, encoded: [f32; 3]) -> [f32; 3] {
        let decode = |v: f32| v.max(0.0).powf(2.2);
        let encode = |v: f32| v.max(0.0).powf(1.0 / 2.2);
        // White balance and exposure act on light; contrast, then lift,
        // gamma and gain, act on the encoded values.
        let shaped = [0, 1, 2].map(|c| {
            let v = encode(decode(encoded[c]) * self.light[c]).min(1.0);
            let v = contrast_curve(v, self.slope);
            let lifted = v + self.lift[c] * (1.0 - v);
            (lifted * self.gain[c]).max(0.0).powf(self.power[c])
        });
        // Saturation acts on light around its luminance.
        let light = shaped.map(decode);
        let luma = 0.2126 * light[0] + 0.7152 * light[1] + 0.0722 * light[2];
        let high = light[0].max(light[1]).max(light[2]);
        let low = light[0].min(light[1]).min(light[2]);
        let chroma = if high > 0.0 { (high - low) / high } else { 0.0 };
        let factor = self.saturation * (1.0 + self.vibrance * (1.0 - chroma)).max(0.0);
        light.map(|v| encode(luma + (v - luma) * factor).min(1.0))
    }
}

/// Channel gains that move white along warm-cool and green-magenta while
/// keeping its luminance.
fn white_balance(temperature: f32, tint: f32) -> [f32; 3] {
    let gains = [
        (0.25 * temperature).exp2(),
        (-0.2 * tint).exp2(),
        (-0.25 * temperature).exp2(),
    ];
    let luma = 0.2126 * gains[0] + 0.7152 * gains[1] + 0.0722 * gains[2];
    gains.map(|gain| gain / luma)
}

/// An S-curve with `slope` at the pivot that keeps black and white.
fn contrast_curve(v: f32, slope: f32) -> f32 {
    if v <= PIVOT {
        PIVOT * (v / PIVOT).powf(slope)
    } else {
        1.0 - (1.0 - PIVOT) * ((1.0 - v) / (1.0 - PIVOT)).powf(slope)
    }
}

fn sample(lut: &Lut, color: [f32; 3]) -> [f32; 3] {
    let last = (lut.size - 1) as f32;
    let at = color.map(|v| v.clamp(0.0, 1.0) * last);
    let low = at.map(|v| (v.floor() as usize).min(lut.size - 2));
    let weight = [0, 1, 2].map(|c| at[c] - low[c] as f32);
    let texel = |r: usize, g: usize, b: usize| {
        let index = ((b * lut.size + g) * lut.size + r) * 4;
        [
            lut.texels[index],
            lut.texels[index + 1],
            lut.texels[index + 2],
        ]
    };
    let mut out = [0.0; 3];
    for corner in 0..8 {
        let pick = [corner & 1, (corner >> 1) & 1, (corner >> 2) & 1];
        let share: f32 = (0..3)
            .map(|c| {
                if pick[c] == 1 {
                    weight[c]
                } else {
                    1.0 - weight[c]
                }
            })
            .product();
        if share == 0.0 {
            continue;
        }
        let value = texel(low[0] + pick[0], low[1] + pick[1], low[2] + pick[2]);
        for c in 0..3 {
            out[c] += share * value[c];
        }
    }
    out
}

/// `grade` over `base`, at the base's size. Blue slices are shared out
/// across the cores: a 65³ base runs once per move of an editor control.
pub(super) fn bake(base: Option<&Lut>, grade: &Grade) -> Lut {
    let size = base.map_or(GRADE_LUT_SIZE, |base| base.size.max(2));
    let last = (size - 1) as f32;
    let grade = grade.prepared();
    let slice = size * size * 4;
    let mut texels = vec![0.0; size * slice];
    let workers = std::thread::available_parallelism().map_or(1, usize::from);
    let slices_per_worker = size.div_ceil(workers.min(size));
    std::thread::scope(|scope| {
        for (chunk, slices) in texels.chunks_mut(slices_per_worker * slice).enumerate() {
            let grade = &grade;
            scope.spawn(move || {
                for (offset, texel) in slices.chunks_exact_mut(4).enumerate() {
                    let index = chunk * slices_per_worker * size * size + offset;
                    let (r, g, b) = (index % size, index / size % size, index / (size * size));
                    let color = [r as f32 / last, g as f32 / last, b as f32 / last];
                    let color = base.map_or(color, |base| sample(base, color));
                    let [r, g, b] = grade.apply(color);
                    texel.copy_from_slice(&[r, g, b, 1.0]);
                }
            });
        }
    });
    let title = match base.and_then(|base| base.title.as_deref()) {
        Some(title) => format!("{title}, graded"),
        None => "Graded".to_owned(),
    };
    Lut {
        size,
        title: Some(title),
        texels,
    }
}

/// What a target shows: a base look from a `.cube` file and a grade over it.
#[derive(Clone, Default)]
pub(super) struct Look {
    pub(super) base: Option<Arc<Lut>>,
    pub(super) grade: Grade,
}

impl Look {
    /// The LUT to apply: none for a neutral look without a base, unless the
    /// target must keep one (`keep`).
    pub(super) fn baked(&self, keep: bool) -> Option<Lut> {
        if self.grade.is_neutral() && !keep {
            return self.base.as_deref().cloned();
        }
        Some(bake(self.base.as_deref(), &self.grade))
    }
}

static DESKTOP: Mutex<Option<Look>> = Mutex::new(None);
static APPS: Mutex<BTreeMap<String, Look>> = Mutex::new(BTreeMap::new());

/// Set once the editor opened: gaining or losing the desktop look restarts
/// the shell, so from then on the desktop keeps one until Denial restarts.
static KEEP_DESKTOP_LOOK: AtomicBool = AtomicBool::new(false);

pub(super) fn keep_desktop_look() {
    KEEP_DESKTOP_LOOK.store(true, Ordering::Relaxed);
}

pub(super) fn keeps_desktop_look() -> bool {
    KEEP_DESKTOP_LOOK.load(Ordering::Relaxed)
}

pub(super) fn desktop_look() -> Look {
    DESKTOP
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .unwrap_or_default()
}

/// Edits the desktop's look and hands its LUT to `install`, all under one
/// lock, so concurrent edits never install an older bake last.
pub(super) fn change_desktop_look(
    change: impl FnOnce(&mut Look),
    install: impl FnOnce(Option<Lut>),
) {
    let mut desktop = DESKTOP.lock().unwrap_or_else(PoisonError::into_inner);
    let look = desktop.get_or_insert_with(Look::default);
    change(look);
    install(look.baked(keeps_desktop_look()));
}

pub(super) fn app_look(app_id: &str) -> Look {
    APPS.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(app_id)
        .cloned()
        .unwrap_or_default()
}

/// As [change_desktop_look], for one app's look.
pub(super) fn change_app_look(
    app_id: &str,
    change: impl FnOnce(&mut Look),
    install: impl FnOnce(Option<Lut>),
) {
    let mut apps = APPS.lock().unwrap_or_else(PoisonError::into_inner);
    let mut look = apps.remove(app_id).unwrap_or_default();
    change(&mut look);
    install(look.baked(false));
    if look.base.is_some() || !look.grade.is_neutral() {
        apps.insert(app_id.to_owned(), look);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: [f32; 3], b: [f32; 3], tolerance: f32) -> bool {
        a.iter().zip(b).all(|(a, b)| (a - b).abs() <= tolerance)
    }

    #[test]
    fn a_neutral_grade_bakes_the_identity() {
        let lut = bake(None, &Grade::default());
        assert_eq!(lut.size, GRADE_LUT_SIZE);
        for color in [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0], [0.25, 0.5, 0.75]] {
            let out = sample(&lut, color);
            assert!(close(out, color, 1e-4), "{color:?} -> {out:?}");
        }
    }

    #[test]
    fn a_neutral_grade_keeps_its_base() {
        let warm = bake(
            None,
            &Grade {
                temperature: 0.8,
                ..Grade::default()
            },
        );
        let again = bake(Some(&warm), &Grade::default());
        for color in [[0.2, 0.4, 0.6], [0.9, 0.1, 0.5]] {
            assert!(close(sample(&again, color), sample(&warm, color), 1e-3));
        }
    }

    #[test]
    fn controls_move_colors_the_expected_way() {
        let grey = [PIVOT; 3];
        let brighter = Grade {
            exposure: 1.0,
            ..Grade::default()
        }
        .prepared()
        .apply(grey);
        assert!(brighter[1] > grey[1] + 0.1);
        let warm = Grade {
            temperature: 1.0,
            ..Grade::default()
        }
        .prepared()
        .apply(grey);
        assert!(warm[0] > warm[1] && warm[1] > warm[2], "{warm:?}");
        let contrast = Grade {
            contrast: 1.0,
            ..Grade::default()
        }
        .prepared();
        assert!(close(contrast.apply(grey), grey, 1e-4));
        assert!(contrast.apply([0.2; 3])[0] < 0.2);
        assert!(contrast.apply([0.8; 3])[0] > 0.8);
        assert!(close(contrast.apply([1.0; 3]), [1.0; 3], 1e-5));
        let grey_out = Grade {
            saturation: -1.0,
            ..Grade::default()
        }
        .prepared()
        .apply([0.8, 0.2, 0.2]);
        assert!(close(grey_out, [grey_out[0]; 3], 1e-4), "{grey_out:?}");
        let lifted = Grade {
            lift: [0.1, 0.0, 0.0],
            ..Grade::default()
        }
        .prepared()
        .apply([0.0; 3]);
        assert!(lifted[0] > 0.05 && lifted[1] == 0.0);
    }

    #[test]
    fn out_of_range_grades_are_refused() {
        assert!(Grade::default().validate().is_ok());
        let wild = Grade {
            gain: [0.0, 9.0, 0.0],
            ..Grade::default()
        };
        assert!(wild.validate().is_err());
        let broken = Grade {
            tint: f32::NAN,
            ..Grade::default()
        };
        assert!(broken.validate().is_err());
    }
}
