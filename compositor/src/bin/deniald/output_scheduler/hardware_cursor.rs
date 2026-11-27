//! Immutable KMS cursor buffers. A primary frame carries its cursor ownership
//! through raster and page flip, so promotion and fallback change both planes together.
use super::*;
use crate::flutter_runtime::ShmTextureFrame;
use crate::{AtomicCommitFlags, ControlDevice, DrmDeviceFd, Fourcc, Modifier, framebuffer};
use smithay::backend::drm::PlaneClaim;
use smithay::reexports::drm::{
    Device, DriverCapability, buffer::Buffer, control::dumbbuffer::DumbBuffer,
};
use std::collections::VecDeque;

pub(crate) struct CursorSprite {
    pub(crate) output: OutputId,
    pub(crate) image: ShmTextureFrame,
    pub(crate) transform: OutputTransform,
    pub(crate) x: i32,
    pub(crate) y: i32,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

/// The desktop look, which the display applies to the primary plane (or the
/// scanout copy applies to the scene) but not to the cursor plane. The cursor
/// image carries it instead, as it carries the gamut correction.
pub(super) struct CursorLook {
    pub(super) generation: u64,
    pub(super) lut: Arc<crate::output_color::Lut>,
}

struct CursorBuffer {
    fd: DrmDeviceFd,
    fb: framebuffer::Handle,
    bo: DumbBuffer,
    source: ShmTextureFrame,
    transform: OutputTransform,
    size: (u32, u32),
    gamut: Option<[f32; 9]>,
    look: Option<u64>,
}

impl CursorBuffer {
    fn matches(
        &self,
        sprite: &CursorSprite,
        gamut: Option<[f32; 9]>,
        look: Option<&CursorLook>,
    ) -> bool {
        self.size == (sprite.width, sprite.height)
            && self.transform == sprite.transform
            && self.gamut == gamut
            && self.look == look.map(|look| look.generation)
            && self.source.same_cursor_pixels(&sprite.image)
    }
}

impl Drop for CursorBuffer {
    fn drop(&mut self) {
        let _ = crate::kms_state::close_scanout_framebuffer(&self.fd, self.fb);
        let _ = self.fd.destroy_dumb_buffer(self.bo);
    }
}

#[derive(Clone)]
struct Position {
    buffer: Arc<CursorBuffer>,
    x: i32,
    y: i32,
}
impl PartialEq for Position {
    fn eq(&self, rhs: &Self) -> bool {
        Arc::ptr_eq(&self.buffer, &rhs.buffer) && self.x == rhs.x && self.y == rhs.y
    }
}

pub(super) struct HardwareCursor {
    fd: DrmDeviceFd,
    _claim: PlaneClaim,
    plane: volition::CursorPlane,
    crtc: u32,
    size: (u32, u32),
    cache: VecDeque<Arc<CursorBuffer>>,
    desired: Option<Position>,
    // Hold both generations until the primary flip completes.
    applied: Option<Position>,
    queued: Option<Option<Position>>,
    pub(super) scanning: bool,
    rejected_size: Option<(u32, u32)>,
    moves: u64,
}

fn fits_plane(sprite: (u32, u32), plane: (u32, u32)) -> bool {
    sprite.0 > 0 && sprite.1 > 0 && sprite.0 <= plane.0 && sprite.1 <= plane.1
}

impl HardwareCursor {
    pub(super) fn discover(scanout: &Scanout) -> Option<Self> {
        if denial_core::environment::flag("DENIAL_NO_HARDWARE_CURSOR") {
            return None;
        }
        let info = scanout.surface.planes().cursor.iter().find(|p| {
            p.formats.iter().any(|f| {
                f.code == Fourcc::Argb8888
                    && matches!(f.modifier, Modifier::Linear | Modifier::Invalid)
            })
        })?;
        let claim = scanout.surface.claim_plane(info.handle)?;
        let fd = scanout.surface.device_fd().clone();
        let dim = |cap| {
            u32::try_from(fd.get_driver_capability(cap).ok()?)
                .ok()
                .filter(|x| (1..=2048).contains(x))
        };
        let size = (
            dim(DriverCapability::CursorWidth)?,
            dim(DriverCapability::CursorHeight)?,
        );
        let names = [
            "FB_ID", "CRTC_ID", "SRC_X", "SRC_Y", "SRC_W", "SRC_H", "CRTC_X", "CRTC_Y", "CRTC_W",
            "CRTC_H",
        ];
        let properties = names
            .into_iter()
            .map(|name| crate::kms_state::named_property(&fd, info.handle, name))
            .collect::<Result<Vec<_>, _>>()
            .ok()?
            .try_into()
            .ok()?;
        info!(output=%scanout.output.name, plane=?info.handle, ?size, "discovered hardware cursor plane");
        Some(Self {
            fd,
            _claim: claim,
            plane: volition::CursorPlane {
                object: info.handle,
                properties,
            },
            crtc: scanout.output.crtc.into(),
            size,
            cache: VecDeque::new(),
            desired: None,
            applied: None,
            queued: None,
            scanning: false,
            rejected_size: None,
            moves: 0,
        })
    }

    fn command(&self, position: Option<&Position>) -> volition::CursorCommit {
        let mut values = [0; 10];
        if let Some(p) = position {
            let (w, h) = (u64::from(self.size.0), u64::from(self.size.1));
            values = [
                u64::from(u32::from(p.buffer.fb)),
                u64::from(self.crtc),
                0,
                0,
                w << 16,
                h << 16,
                p.x as i64 as u64,
                p.y as i64 as u64,
                w,
                h,
            ];
        }
        volition::CursorCommit {
            plane: self.plane,
            values,
        }
    }

    fn buffer(
        &mut self,
        s: &CursorSprite,
        gamut: Option<[f32; 9]>,
        look: Option<&CursorLook>,
    ) -> std::io::Result<Arc<CursorBuffer>> {
        let size = (s.width, s.height);
        if let Some(i) = self
            .cache
            .iter()
            .position(|buffer| buffer.matches(s, gamut, look))
        {
            let b = self.cache.remove(i).unwrap();
            self.cache.push_front(b.clone());
            return Ok(b);
        }
        let mut bo = self
            .fd
            .create_dumb_buffer(self.size, Fourcc::Argb8888, 32)?;
        let pitch = bo.pitch() as usize;
        let upload = (|| {
            let mut pixels = self.fd.map_dumb_buffer(&mut bo)?;
            pixels.fill(0);
            paint(
                &mut pixels,
                pitch,
                s,
                gamut,
                look.map(|look| look.lut.as_ref()),
            );
            drop(pixels);
            crate::kms_state::cursor_framebuffer(&self.fd, bo.size(), bo.pitch(), bo.handle())
        })();
        let fb = match upload {
            Ok(fb) => fb,
            Err(e) => {
                let _ = self.fd.destroy_dumb_buffer(bo);
                return Err(e);
            }
        };
        let b = Arc::new(CursorBuffer {
            fd: self.fd.clone(),
            fb,
            bo,
            source: s.image.clone(),
            transform: s.transform,
            size,
            gamut,
            look: look.map(|look| look.generation),
        });
        self.cache.push_front(b.clone());
        // Bound both the animation working set and memory on large-plane GPUs.
        let bytes = u64::from(bo.pitch()) * u64::from(self.size.1);
        self.cache
            .truncate((16 * 1024 * 1024 / bytes).clamp(1, 16) as usize);
        Ok(b)
    }

    pub(super) fn select(
        &mut self,
        sprite: Option<&CursorSprite>,
        gamut: Option<[f32; 9]>,
        look: Option<&CursorLook>,
    ) -> bool {
        let Some(s) = sprite else {
            self.desired = None;
            self.rejected_size = None;
            return false;
        };
        let size = (s.width, s.height);
        if !fits_plane(size, self.size) || self.rejected_size == Some(size) {
            self.desired = None;
            return false;
        }
        self.rejected_size = None;
        if let Some(current) = self.desired.as_mut()
            && current.buffer.matches(s, gamut, look)
        {
            current.x = s.x;
            current.y = s.y;
            return true;
        }
        let next = self.buffer(s, gamut, look).and_then(|buffer| {
            let p = Position {
                buffer,
                x: s.x,
                y: s.y,
            };
            // All cached images have the same allocation layout. Validate on promotion.
            if self.desired.is_none() {
                self.command(Some(&p))
                    .apply(self.fd.as_fd(), AtomicCommitFlags::TEST_ONLY)?;
            }
            Ok(p)
        });
        match next {
            Ok(p) => {
                self.desired = Some(p);
                true
            }
            Err(e)
                if matches!(
                    e.raw_os_error(),
                    Some(libc::EBUSY | libc::EINTR | libc::EAGAIN)
                ) =>
            {
                self.desired = None;
                false
            }
            Err(e) => {
                self.reject_size(size, &e);
                false
            }
        }
    }

    // A rejected candidate may arrive while a different commit is in
    // flight. Its buffer still has to become applied on the page flip.
    fn reject_size(&mut self, size: (u32, u32), error: &dyn std::fmt::Display) {
        warn!(plane=?self.plane.object, %error, ?size, "hardware cursor refused; using Stagecraft");
        self.rejected_size = Some(size);
        self.desired = None;
    }

    pub(super) fn submission_rejected(&mut self, error: &dyn std::fmt::Display) {
        if let Some(position) = self.queued.take().flatten() {
            self.reject_size(position.buffer.size, error);
        }
    }
    pub(super) fn wanted(&self) -> bool {
        self.desired.is_some()
    }
    pub(super) fn pending(&self) -> bool {
        self.scanning && self.desired.is_some() && self.desired != self.applied
    }
    pub(super) fn update(&self, hw: bool) -> Option<volition::CursorCommit> {
        let target = if hw { self.desired.as_ref() } else { None };
        (target != self.applied.as_ref()).then(|| self.command(target))
    }
    pub(super) fn scheduled(&mut self, hw: bool) {
        self.queued = Some(if hw { self.desired.clone() } else { None });
    }
    pub(super) fn presented(&mut self, hw: bool) {
        let previous_transform = self.applied.as_ref().map(|p| p.buffer.transform);
        if let Some(next) = self.queued.take() {
            self.applied = next;
        }
        let transform = self.applied.as_ref().map(|p| p.buffer.transform);
        if hw != self.scanning || transform != previous_transform {
            info!(plane=?self.plane.object, hardware=hw, ?transform, "cursor ownership presented");
        }
        self.scanning = hw;
    }
    pub(super) fn move_only(&mut self) {
        let fd = self.fd.clone();
        self.move_with(|command| command.apply(fd.as_fd(), AtomicCommitFlags::NONBLOCK));
    }
    /// Moves the cursor with `commit`, which may carry the primary plane too.
    pub(super) fn move_with(
        &mut self,
        commit: impl FnOnce(volition::CursorCommit) -> std::io::Result<()>,
    ) {
        if !self.pending() {
            return;
        }
        // Latch a new orientation together with the first primary frame in
        // that orientation. Motion and animation within it remain independent.
        if self.desired.as_ref().map(|p| p.buffer.transform)
            != self.applied.as_ref().map(|p| p.buffer.transform)
        {
            return;
        }
        match commit(self.command(self.desired.as_ref())) {
            Ok(()) => {
                self.applied = self.desired.clone();
                self.moves += 1;
                if self.moves == 1 || self.moves.is_multiple_of(256) {
                    info!(plane=?self.plane.object,updates=self.moves,"cursor-only KMS commit");
                }
            }
            Err(e)
                if matches!(
                    e.raw_os_error(),
                    Some(libc::EBUSY | libc::EAGAIN | libc::EINTR)
                ) => {}
            Err(e) => {
                if let Some(position) = &self.desired {
                    self.reject_size(position.buffer.size, &e);
                }
            }
        }
    }
}
impl Drop for HardwareCursor {
    fn drop(&mut self) {
        if self.scanning || self.queued.is_some() {
            let _ = self
                .command(None)
                .apply(self.fd.as_fd(), AtomicCommitFlags::empty());
        }
    }
}

// Match Stagecraft's bilinear sampling of premultiplied RGBA, then write
// little-endian KMS ARGB8888. Transparent padding belongs to the fixed plane.
// The look and correction follow the primary plane's order: look, then gamut.
fn paint(
    dst: &mut [u8],
    stride: usize,
    s: &CursorSprite,
    gamut: Option<[f32; 9]>,
    look: Option<&crate::output_color::Lut>,
) {
    let src = s.image.pixels();
    let sw = s.image.width() as usize;
    let axis = |coordinate: f64, extent: u32| {
        let v = (coordinate * f64::from(extent) - 0.5).clamp(0., f64::from(extent - 1));
        (
            v as usize,
            (v as usize + 1).min(extent as usize - 1),
            v.fract(),
        )
    };
    for y in 0..s.height {
        let v = (f64::from(y) + 0.5) / f64::from(s.height);
        for x in 0..s.width {
            let u = (f64::from(x) + 0.5) / f64::from(s.width);
            // Sample the original artwork at the logical position of this
            // native pixel. Only the artwork rotates, never the plane padding.
            let (source_x, source_y) = s.transform.native_to_logical(u, v);
            let (x0, x1, fx) = axis(source_x, s.image.width());
            let (y0, y1, fy) = axis(source_y, s.image.height());
            let sample = |c: usize| {
                let row = |y| {
                    f64::from(src[4 * (y * sw + x0) + c]) * (1. - fx)
                        + f64::from(src[4 * (y * sw + x1) + c]) * fx
                };
                row(y0) * (1. - fy) + row(y1) * fy
            };
            let a = sample(3);
            let mut rgb = [sample(0), sample(1), sample(2)];
            if a > 0. && (look.is_some() || gamut.is_some()) {
                let mut color = rgb.map(|v| v / a);
                if let Some(look) = look {
                    color =
                        crate::color_grade::sample(look, color.map(|v| v as f32)).map(f64::from);
                }
                if let Some(matrix) = gamut {
                    color = crate::plane_color::correct(&matrix, color);
                }
                rgb = color.map(|v| v * a);
            }
            let i = y as usize * stride + x as usize * 4;
            dst[i..i + 4].copy_from_slice(&[
                rgb[2].round() as u8,
                rgb[1].round() as u8,
                rgb[0].round() as u8,
                a.round() as u8,
            ]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlarge_cursor_falls_back_without_resizing() {
        assert!(fits_plane((64, 47), (64, 64)));
        assert!(!fits_plane((64, 65), (64, 64)));
        assert!(!fits_plane((65, 40), (64, 64)));
        assert!(!fits_plane((0, 40), (64, 64)));
    }

    #[test]
    fn cursor_pixels_follow_the_panel_transform_inside_a_padded_plane() {
        use OutputTransform::*;
        // Non-square artwork with a distinct value in every texel.
        let image =
            ShmTextureFrame::new_owned(3, 2, 1, (1..=6).flat_map(|c| [0, 0, c, 255]).collect())
                .unwrap();
        for (transform, expected) in [
            (Normal, [1, 2, 3, 4, 5, 6]),
            (Rotate90, [3, 6, 2, 5, 1, 4]),
            (Rotate180, [6, 5, 4, 3, 2, 1]),
            (Rotate270, [4, 1, 5, 2, 6, 3]),
            (Flipped, [3, 2, 1, 6, 5, 4]),
            (Flipped90, [1, 4, 2, 5, 3, 6]),
            (Flipped180, [4, 5, 6, 1, 2, 3]),
            (Flipped270, [6, 3, 5, 2, 4, 1]),
        ] {
            let (width, height) = if transform.swaps_axes() {
                (2, 3)
            } else {
                (3, 2)
            };
            let sprite = CursorSprite {
                output: OutputId(1),
                transform,
                x: 0,
                y: 0,
                width,
                height,
                image: image.clone(),
            };
            let mut plane = [0; 64];
            paint(&mut plane, 16, &sprite, None, None);
            for y in 0..4 {
                for x in 0..4 {
                    let pixel = &plane[(y * 4 + x) * 4..(y * 4 + x + 1) * 4];
                    let expected = if x < width as usize && y < height as usize {
                        [expected[y * width as usize + x], 0, 0, 255]
                    } else {
                        [0; 4]
                    };
                    assert_eq!(pixel, expected, "{transform:?} at ({x},{y})");
                }
            }
        }
    }

    #[test]
    fn scaled_cursor_preserves_premultiplied_alpha_and_transparent_padding() {
        let sprite = CursorSprite {
            output: OutputId(1),
            transform: OutputTransform::Normal,
            x: -3,
            y: 10,
            width: 3,
            height: 1,
            image: ShmTextureFrame::new_owned(2, 1, 1, vec![128, 0, 0, 128, 0, 0, 64, 64]).unwrap(),
        };
        let mut buffer = [0; 32];
        paint(&mut buffer, 16, &sprite, None, None);
        assert_eq!(
            &buffer[..12],
            &[0, 0, 128, 128, 32, 0, 64, 96, 64, 0, 0, 64]
        );
        assert_eq!(&buffer[12..], &[0; 20]);
    }

    #[test]
    fn the_desktop_look_grades_the_cursor_before_premultiplying() {
        // A look that inverts every channel.
        let mut texels = Vec::new();
        for b in [0., 1.] {
            for g in [0., 1.] {
                for r in [0., 1.] {
                    texels.extend([1. - r, 1. - g, 1. - b, 1.]);
                }
            }
        }
        let look = crate::output_color::Lut {
            size: 2,
            title: None,
            texels,
        };
        let sprite = CursorSprite {
            output: OutputId(1),
            transform: OutputTransform::Normal,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            // Opaque red, and half-transparent half-red (premultiplied).
            image: ShmTextureFrame::new_owned(2, 1, 1, vec![255, 0, 0, 255, 64, 0, 0, 128])
                .unwrap(),
        };
        let mut buffer = [0; 8];
        paint(&mut buffer, 8, &sprite, None, Some(&look));
        // BGRA: cyan, and (0.5, 1, 1) at alpha 128.
        assert_eq!(buffer, [255, 255, 0, 255, 128, 128, 64, 128]);
    }
}
