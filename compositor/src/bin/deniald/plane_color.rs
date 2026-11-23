//! The desktop look and a display's gamut correction in the display engine.
//!
//! Where the primary plane has a color pipeline (DRM colorops) with a 3D
//! LUT, both are baked into that one table: the scene renders straight into
//! scanout and nothing copies it. Every other stage of the pipeline stays
//! bypassed. Where a plane has no such pipeline (NVIDIA, msm), the output is
//! HDR, or the driver refuses the table, the scanout copy does the same work
//! (`blit_to_scanout`).
//!
//! The table reproduces the copy's shader: the look sampled as GL filters
//! it, then gamma 2.2 decode, the gamut matrix and gamma 2.2 encode, at the
//! pipeline's nodes (17³ on amdgpu).

use super::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use super::output_color::Lut;

const DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE: u64 = 7;
const DRM_MODE_OBJECT_COLOROP: u32 = 0xfafa_fafa;
/// More stages than any pipeline has: a malformed NEXT chain ends here.
const MAX_STAGES: usize = 32;

/// The client asked for plane color pipelines and the driver agreed.
static ENABLED: AtomicBool = AtomicBool::new(false);
/// A desktop look can appear without new pools: no installed output copies
/// its scene only for a look and was made without one.
static LOOK_READY: AtomicBool = AtomicBool::new(false);
/// Bumped when KMS state may have changed behind Denial's back (a session
/// resume): every plane is committed again.
static EPOCH: AtomicU64 = AtomicU64::new(0);
/// Planes that refused their table this session; their outputs copy.
static REFUSED: Mutex<Vec<plane::Handle>> = Mutex::new(Vec::new());

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Colorop(RawResourceHandle);

impl From<RawResourceHandle> for Colorop {
    fn from(handle: RawResourceHandle) -> Self {
        Self(handle)
    }
}

impl From<Colorop> for RawResourceHandle {
    fn from(colorop: Colorop) -> Self {
        colorop.0
    }
}

impl From<Colorop> for u32 {
    fn from(colorop: Colorop) -> Self {
        colorop.0.get()
    }
}

impl ResourceHandle for Colorop {
    const FFI_TYPE: u32 = DRM_MODE_OBJECT_COLOROP;
}

/// Asks for plane color pipelines on the KMS device and turns off every
/// pipeline a previous session left set, so a crash never leaves its look on
/// a plane. Bounded diagnostics leave planes alone and copy instead.
pub(super) fn enable(drm: &impl ControlDevice, diagnostics: bool) {
    if diagnostics {
        return;
    }
    if let Err(error) =
        drm_ffi::set_capability(drm.as_fd(), DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE, true)
    {
        debug!(%error, "the display driver has no plane color pipelines");
        return;
    }
    ENABLED.store(true, Ordering::Release);
    reset_planes(drm);
}

/// Turns off every plane color pipeline: at startup, and before handing the
/// device to the next DRM master.
pub(super) fn reset_planes(drm: &impl ControlDevice) {
    if !ENABLED.load(Ordering::Acquire) {
        return;
    }
    let result = (|| -> Result<usize, Box<dyn Error>> {
        let mut request = AtomicModeReq::new();
        let mut planes = 0;
        for plane in drm.plane_handles()? {
            for (name, property, value) in properties(drm, plane)? {
                if name == "COLOR_PIPELINE" && value != 0 {
                    request.add_raw_property(plane.into(), property, 0);
                    planes += 1;
                }
            }
        }
        if planes > 0 {
            drm.atomic_commit(AtomicCommitFlags::TEST_ONLY, request.clone())?;
            drm.atomic_commit(AtomicCommitFlags::empty(), request)?;
        }
        Ok(planes)
    })();
    match result {
        Ok(0) => {}
        Ok(planes) => info!(planes, "turned off plane color pipelines left set"),
        Err(error) => warn!(%error, "could not turn off plane color pipelines left set"),
    }
}

/// Whether a desktop look can appear without new pools.
pub(super) fn look_ready() -> bool {
    LOOK_READY.load(Ordering::Acquire)
}

pub(super) fn set_look_ready(ready: bool) {
    LOOK_READY.store(ready, Ordering::Release);
}

/// KMS state may have changed behind Denial's back: commit every plane
/// again.
pub(super) fn invalidate() {
    EPOCH.fetch_add(1, Ordering::AcqRel);
}

/// One primary plane's pipeline, used for the desktop look and correction.
pub(super) struct PlaneColor {
    plane: plane::Handle,
    pipeline_property: property::Handle,
    /// Its first colorop: the COLOR_PIPELINE value that selects it.
    pipeline: u64,
    lut: Colorop,
    lut_size: usize,
    lut_data: property::Handle,
    lut_bypass: Option<property::Handle>,
    /// Every other stage, by its BYPASS property.
    others: Vec<(Colorop, property::Handle)>,
    /// The display's linear-light gamut matrix (column-major).
    gamut: Option<[f32; 9]>,
    /// The plane shows the look and correction; otherwise its pipeline is
    /// off and the scene copy applies them.
    shows: bool,
    /// What the plane was last committed to: the epoch, and the desktop
    /// look generation and correction switch when it shows them.
    applied: Option<(u64, Option<(u64, bool)>)>,
}

impl PlaneColor {
    /// The plane's first pipeline that has a 3D LUT and can bypass every
    /// other stage; None without one.
    pub(super) fn probe(
        drm: &impl ControlDevice,
        plane: plane::Handle,
        gamut: Option<[f32; 9]>,
    ) -> Result<Option<Self>, Box<dyn Error>> {
        let refused = REFUSED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(&plane);
        if !ENABLED.load(Ordering::Acquire) || refused {
            return Ok(None);
        }
        let Some((_, pipeline_property, _)) = properties(drm, plane)?
            .into_iter()
            .find(|(name, ..)| name == "COLOR_PIPELINE")
        else {
            return Ok(None);
        };
        let property::ValueType::Enum(pipelines) = drm.get_property(pipeline_property)?.value_type()
        else {
            return Ok(None);
        };
        for &pipeline in pipelines.values().0 {
            if let Some(color) = Self::pipeline(drm, plane, pipeline_property, pipeline, gamut)? {
                return Ok(Some(color));
            }
        }
        Ok(None)
    }

    fn pipeline(
        drm: &impl ControlDevice,
        plane: plane::Handle,
        pipeline_property: property::Handle,
        pipeline: u64,
        gamut: Option<[f32; 9]>,
    ) -> Result<Option<Self>, Box<dyn Error>> {
        let mut lut = None;
        let mut others = Vec::new();
        let mut next = pipeline;
        for _ in 0..MAX_STAGES {
            let Some(colorop) = u32::try_from(next)
                .ok()
                .and_then(std::num::NonZeroU32::new)
                .map(Colorop)
            else {
                break;
            };
            next = 0;
            let (mut kind, mut bypass, mut data, mut size) = (None, None, None, None);
            for (name, property, value) in properties(drm, colorop)? {
                match name.as_str() {
                    "TYPE" => kind = enum_name(drm, property, value)?,
                    "NEXT" => next = value,
                    "BYPASS" => bypass = Some(property),
                    "DATA" => data = Some(property),
                    "SIZE" => size = usize::try_from(value).ok(),
                    _ => {}
                }
            }
            match (kind.as_deref(), data, size) {
                (Some("3D LUT"), Some(data), Some(size)) if lut.is_none() && size >= 2 => {
                    lut = Some((colorop, size, data, bypass));
                }
                _ => match bypass {
                    Some(bypass) => others.push((colorop, bypass)),
                    // A stage that cannot be turned off would change color.
                    None => return Ok(None),
                },
            }
        }
        if next != 0 {
            return Ok(None);
        }
        Ok(lut.map(|(lut, lut_size, lut_data, lut_bypass)| Self {
            plane,
            pipeline_property,
            pipeline,
            lut,
            lut_size,
            lut_data,
            lut_bypass,
            others,
            gamut,
            shows: false,
            applied: None,
        }))
    }

    /// Whether the plane shows the look and correction (an SDR output), or
    /// keeps its pipeline off for the scene copy.
    pub(super) fn set_shows(&mut self, shows: bool) {
        self.shows = shows;
    }

    pub(super) fn shows(&self) -> bool {
        self.shows
    }

    /// Commits the plane to the current desktop look and correction switch
    /// unless it shows them already.
    pub(super) fn sync(&mut self, drm: &impl ControlDevice) -> Result<(), Box<dyn Error>> {
        let corrected = self.gamut.is_some() && super::output_color::correction_enabled();
        let wanted = (
            EPOCH.load(Ordering::Acquire),
            self.shows
                .then(|| (super::output_color::desktop_lut_generation(), corrected)),
        );
        if self.applied == Some(wanted) {
            return Ok(());
        }
        let look = self.shows.then(super::output_color::desktop_lut).flatten();
        let gamut = self.gamut.filter(|_| self.shows && corrected);
        let table =
            (look.is_some() || gamut.is_some()).then(|| bake(self.lut_size, look.as_deref(), gamut));
        let result = self.apply(drm, table.as_deref());
        // Turning off is retried only at the next epoch: a failing blocking
        // commit every iteration would stall the loop.
        self.applied = (result.is_ok() || !self.shows).then_some(wanted);
        result
    }

    /// Gives up on the plane for this session once its pipeline is off, so
    /// later pools copy the scene instead. When it cannot be turned off, the
    /// plane keeps showing what it last took and nothing copies on top.
    pub(super) fn refuse(&mut self, drm: &impl ControlDevice) -> Result<(), Box<dyn Error>> {
        self.shows = false;
        self.applied = None;
        self.sync(drm)?;
        REFUSED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(self.plane);
        Ok(())
    }

    /// Shows `table` (U0.32 RGB entries, red fastest) through the plane, or
    /// no color work when None.
    fn apply(&self, drm: &impl ControlDevice, table: Option<&[[u32; 3]]>) -> Result<(), Box<dyn Error>> {
        let mut request = AtomicModeReq::new();
        let blob = match table {
            Some(table) => {
                let mut bytes = Vec::with_capacity(table.len() * 16);
                for entry in table {
                    for channel in [entry[0], entry[1], entry[2], 0] {
                        bytes.extend_from_slice(&channel.to_ne_bytes());
                    }
                }
                let blob = drm_ffi::mode::create_property_blob(drm.as_fd(), &mut bytes)?.blob_id;
                request.add_raw_property(self.plane.into(), self.pipeline_property, self.pipeline);
                if let Some(bypass) = self.lut_bypass {
                    request.add_raw_property(self.lut.into(), bypass, 0);
                }
                request.add_raw_property(self.lut.into(), self.lut_data, u64::from(blob));
                for &(colorop, bypass) in &self.others {
                    request.add_raw_property(colorop.into(), bypass, 1);
                }
                Some(blob)
            }
            None => {
                request.add_raw_property(self.plane.into(), self.pipeline_property, 0);
                None
            }
        };
        let committed = drm
            .atomic_commit(AtomicCommitFlags::TEST_ONLY, request.clone())
            .and_then(|()| drm.atomic_commit(AtomicCommitFlags::empty(), request));
        // The committed colorop state holds its own reference to the blob.
        if let Some(blob) = blob {
            let _ = drm.destroy_property_blob(u64::from(blob));
        }
        Ok(committed?)
    }
}

/// The plane table for `look` then `gamut`, at `size`³ nodes, red fastest
/// (`index = r + size * (g + size * b)`), in U0.32.
pub(super) fn bake(size: usize, look: Option<&Lut>, gamut: Option<[f32; 9]>) -> Vec<[u32; 3]> {
    let last = (size.max(2) - 1) as f64;
    let mut table = Vec::with_capacity(size.pow(3));
    for b in 0..size {
        for g in 0..size {
            for r in 0..size {
                let mut rgb = [r as f64 / last, g as f64 / last, b as f64 / last];
                if let Some(look) = look {
                    let graded = super::color_grade::sample(look, rgb.map(|value| value as f32));
                    rgb = graded.map(f64::from);
                }
                if let Some(matrix) = gamut {
                    rgb = correct(&matrix, rgb);
                }
                table.push(rgb.map(|value| {
                    (value.clamp(0.0, 1.0) * f64::from(u32::MAX)).round() as u32
                }));
            }
        }
    }
    table
}

/// The copy shader's correction: gamma 2.2 decode, the gamut matrix
/// (column-major), gamma 2.2 encode, clamped as it clamps.
fn correct(matrix: &[f32; 9], rgb: [f64; 3]) -> [f64; 3] {
    let linear = rgb.map(|value| value.clamp(0.0, 1.0).powf(2.2));
    std::array::from_fn(|row| {
        let light = (0..3)
            .map(|column| f64::from(matrix[column * 3 + row]) * linear[column])
            .sum::<f64>();
        light.clamp(0.0, 1.0).powf(1.0 / 2.2)
    })
}

/// Every property of a KMS object with its name and value.
fn properties<T: ResourceHandle>(
    drm: &impl ControlDevice,
    handle: T,
) -> Result<Vec<(String, property::Handle, u64)>, Box<dyn Error>> {
    let mut named = Vec::new();
    for (property, value) in drm.get_properties(handle)? {
        let info = drm.get_property(property)?;
        named.push((info.name().to_string_lossy().into_owned(), property, value));
    }
    Ok(named)
}

/// The name of an enum property's value.
fn enum_name(
    drm: &impl ControlDevice,
    property: property::Handle,
    value: u64,
) -> Result<Option<String>, Box<dyn Error>> {
    let property::ValueType::Enum(values) = drm.get_property(property)?.value_type() else {
        return Ok(None);
    };
    Ok(values
        .values()
        .1
        .iter()
        .find(|entry| entry.value() == value)
        .map(|entry| entry.name().to_string_lossy().into_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(size: usize) -> Lut {
        let last = (size - 1) as f32;
        let mut texels = Vec::new();
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    texels.extend([r as f32 / last, g as f32 / last, b as f32 / last, 1.0]);
                }
            }
        }
        Lut {
            size,
            title: None,
            texels,
        }
    }

    #[test]
    fn red_runs_fastest_and_ends_reach_the_range() {
        let table = bake(17, None, Some([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]));
        assert_eq!(table.len(), 17 * 17 * 17);
        assert_eq!(table[0], [0, 0, 0]);
        assert_eq!(table[16], [u32::MAX, 0, 0]);
        assert_eq!(table[16 * 17], [0, u32::MAX, 0]);
        assert_eq!(table[16 * 17 * 17], [0, 0, u32::MAX]);
        assert_eq!(*table.last().unwrap(), [u32::MAX; 3]);
    }

    #[test]
    fn identity_look_between_nodes_is_identity() {
        // A 33³ identity sampled at 17³ nodes: every node of 17 is a node of
        // 33, and between nodes the filter is linear.
        let table = bake(17, Some(&identity(33)), None);
        let reference = bake(17, Some(&identity(5)), None);
        for (index, (entry, other)) in table.iter().zip(&reference).enumerate() {
            let r = index % 17;
            let expected = (r as f64 / 16.0 * f64::from(u32::MAX)).round() as i64;
            assert!((i64::from(entry[0]) - expected).abs() <= 256, "node {index}");
            for channel in 0..3 {
                assert!((i64::from(entry[channel]) - i64::from(other[channel])).abs() <= 256);
            }
        }
    }

    /// Reads every primary plane's pipelines on a real card, read-only (no
    /// DRM master needed). `DENIAL_PLANE_COLOR_TEST_CARD` (default
    /// /dev/dri/card1).
    #[test]
    #[ignore = "needs an amdgpu display card"]
    fn primary_planes_have_a_3d_lut_pipeline() {
        use smithay::reexports::drm::Device as _;
        use std::os::fd::AsFd as _;
        let path = std::env::var("DENIAL_PLANE_COLOR_TEST_CARD")
            .unwrap_or_else(|_| "/dev/dri/card1".into());
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap_or_else(|error| panic!("{path}: {error}"));
        let drm = DrmDeviceFd::new(DeviceFd::from(OwnedFd::from(file)));
        drm.set_client_capability(smithay::reexports::drm::ClientCapability::UniversalPlanes, true)
            .expect("universal planes");
        drm.set_client_capability(smithay::reexports::drm::ClientCapability::Atomic, true)
            .expect("atomic");
        drm_ffi::set_capability(drm.as_fd(), DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE, true)
            .expect("plane color pipelines");
        ENABLED.store(true, Ordering::Release);
        let mut found = 0;
        for plane in drm.plane_handles().expect("planes") {
            let primary = properties(&drm, plane)
                .expect("plane properties")
                .iter()
                .any(|(name, _, value)| name == "type" && *value == 1);
            if !primary {
                continue;
            }
            let color = PlaneColor::probe(&drm, plane, None).expect("probe");
            if let Some(color) = &color {
                eprintln!(
                    "{plane:?}: pipeline {} 3D LUT {}^3, {} other stages",
                    color.pipeline,
                    color.lut_size,
                    color.others.len()
                );
                found += 1;
            }
        }
        assert!(found > 0, "no primary plane has a 3D LUT pipeline");
    }

    #[test]
    fn correction_matches_the_copy_shader() {
        // Swaps red and green in linear light: a neutral stays neutral, a
        // primary moves to the other channel.
        let swap = [0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
        assert_eq!(correct(&swap, [0.5, 0.5, 0.5]).map(|v| (v * 1e6).round()), [500000.0; 3]);
        assert_eq!(correct(&swap, [1.0, 0.0, 0.0]), [0.0, 1.0, 0.0]);
    }
}
