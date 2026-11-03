//! Native client-tree composition, independent of shell placement/effects.
//!
//! Plans retain Wayland's client-local geometry. Desktop movement, overview
//! transforms and workspace animations do not invalidate the client image.
//! Popup trees remain independent scene siblings. GPU storage, input revisions
//! and fence ownership are supplied by the external-texture renderer.

use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

use denial_flutter_engine::ExternalTexturePresentation;

use crate::wayland_frontend::canvas_rect_to_buffer;
use crate::wire::SurfaceLayerDescription;

const NATIVE_WINDOW_TEXTURE_NAMESPACE: u64 = 1 << 62;

/// Whether `texture_id` names a merged native window image.
pub(in crate::flutter_runtime) const fn is_native_window_texture(texture_id: i64) -> bool {
    texture_id >= NATIVE_WINDOW_TEXTURE_NAMESPACE as i64
}
const MAX_NATIVE_WINDOW_PLANS: usize = 32;
const MAX_NATIVE_WINDOW_LAYERS: usize = 32;
const MAX_NATIVE_WINDOW_DIMENSION: u32 = 8192;
const MAX_NATIVE_WINDOW_PIXELS: u64 = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ClientRect {
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) width: f64,
    pub(super) height: f64,
}

impl ClientRect {
    pub(super) fn new(x: f64, y: f64, width: f64, height: f64) -> Option<Self> {
        let rect = Self {
            x,
            y,
            width,
            height,
        };
        (x.is_finite()
            && y.is_finite()
            && width.is_finite()
            && height.is_finite()
            && width > 0.0
            && height > 0.0
            && (x + width).is_finite()
            && (y + height).is_finite())
        .then_some(rect)
    }

    fn right(self) -> f64 {
        self.x + self.width
    }
    fn bottom(self) -> f64 {
        self.y + self.height
    }

    fn intersection(self, other: Self) -> Option<Self> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        Self::new(
            x,
            y,
            self.right().min(other.right()) - x,
            self.bottom().min(other.bottom()) - y,
        )
    }

    fn contains(self, other: Self) -> bool {
        self.x <= other.x
            && self.y <= other.y
            && self.right() >= other.right()
            && self.bottom() >= other.bottom()
    }
}

/// Whether the merge pass reproduces an input's presentation: none, or a
/// virtual canvas that only crops its buffer. Canvases that place the image
/// or paint a background, such as mobile inset strips, keep the surface tree.
pub(super) fn reproduces_presentation(presentation: &ExternalTexturePresentation) -> bool {
    // The engine applies only presentations with a canvas width.
    let presented = presentation.width > 0.0;
    if !presented {
        return true;
    }
    let [x, y, width, height] = presentation.source;
    let canvas = [0.0, 0.0, presentation.width, presentation.height];
    let paints_background = presentation.background[2] > 0.0 && presentation.background[3] > 0.0;
    presentation.width.is_finite()
        && presentation.height.is_finite()
        && presentation.height > 0.0
        && presentation.destination == canvas
        && !paints_background
        && ClientRect::new(x, y, width, height).is_some()
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct NativeWindowLayer {
    pub(super) texture_id: i64,
    pub(super) destination: ClientRect,
    pub(super) source: ClientRect,
    pub(super) transform: u32,
    pub(super) opacity: f32,
    pub(super) opaque: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ClientVertex {
    pub(super) position: [f32; 2],
    pub(super) uv: [f32; 2],
}

impl NativeWindowLayer {
    /// Inverse of RotatedBox followed by the optional horizontal reflection,
    /// matching the existing Wayland buffer-transform contract. Crops remain
    /// in buffer coordinates even when the destination axes are swapped.
    pub(super) fn uv_at(&self, point: [f64; 2], buffer_size: [u32; 2]) -> Option<[f32; 2]> {
        if buffer_size.contains(&0) {
            return None;
        }
        let mut u = (point[0] - self.destination.x) / self.destination.width;
        let v = (point[1] - self.destination.y) / self.destination.height;
        if self.transform & 4 != 0 {
            u = 1.0 - u;
        }
        let [u, v] = match self.transform & 3 {
            0 => [u, v],
            1 => [v, 1.0 - u],
            2 => [1.0 - u, 1.0 - v],
            _ => [1.0 - v, u],
        };
        Some([
            ((self.source.x + u * self.source.width) / f64::from(buffer_size[0])) as f32,
            ((self.source.y + v * self.source.height) / f64::from(buffer_size[1])) as f32,
        ])
    }

    /// Strict crop texel limits used by the native sampler, including crops
    /// narrower than one texel. The input may be an older accepted mailbox
    /// buffer during resize; never sample beyond its actual backing.
    pub(super) fn sample_limits(&self, buffer_size: [u32; 2]) -> Option<[f32; 4]> {
        let source = self.source.intersection(ClientRect::new(
            0.0,
            0.0,
            f64::from(buffer_size[0]),
            f64::from(buffer_size[1]),
        )?)?;
        let half_x = (source.width * 0.5).min(0.5);
        let half_y = (source.height * 0.5).min(0.5);
        Some([
            ((source.x + half_x) / f64::from(buffer_size[0])) as f32,
            ((source.y + half_y) / f64::from(buffer_size[1])) as f32,
            ((source.right() - half_x) / f64::from(buffer_size[0])) as f32,
            ((source.bottom() - half_y) / f64::from(buffer_size[1])) as f32,
        ])
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct NativeWindowPlan {
    pub(super) window_id: u64,
    pub(super) texture_id: i64,
    pub(super) canvas: ClientRect,
    pub(super) scale: f64,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) layers: Vec<NativeWindowLayer>,
}

impl NativeWindowPlan {
    pub(super) fn new(
        window_id: u64,
        canvas: ClientRect,
        scale: f64,
        surfaces: &[SurfaceLayerDescription],
    ) -> Option<Self> {
        if window_id == 0
            || window_id >= NATIVE_WINDOW_TEXTURE_NAMESPACE
            || !scale.is_finite()
            || !(1.0..=8.0).contains(&scale)
            || ClientRect::new(canvas.x, canvas.y, canvas.width, canvas.height).is_none()
        {
            return None;
        }
        let width = (canvas.width * scale).ceil();
        let height = (canvas.height * scale).ceil();
        if width < 1.0
            || height < 1.0
            || width > f64::from(MAX_NATIVE_WINDOW_DIMENSION)
            || height > f64::from(MAX_NATIVE_WINDOW_DIMENSION)
        {
            return None;
        }
        let width = width as u32;
        let height = height as u32;
        if u64::from(width) * u64::from(height) > MAX_NATIVE_WINDOW_PIXELS {
            return None;
        }
        let mut layers = Vec::new();
        let mut opaque_covers = Vec::<ClientRect>::new();
        for surface in surfaces.iter().rev() {
            if surface.popup_root_surface_id != 0
                || surface.texture_id == 0
                || surface.opacity == 0.0
            {
                continue;
            }
            // Synthetic sources must not depend on other synthetic sources.
            if surface.texture_id >= NATIVE_WINDOW_TEXTURE_NAMESPACE
                || surface.transform > 7
                || !surface.opacity.is_finite()
                || !(0.0..=1.0).contains(&surface.opacity)
                || surface.width == 0
                || surface.height == 0
            {
                return None;
            }
            let destination = ClientRect::new(
                surface.surface_x,
                surface.surface_y,
                surface.surface_width,
                surface.surface_height,
            )?;
            let Some(visible) = destination.intersection(canvas) else {
                continue;
            };
            if opaque_covers.iter().any(|cover| cover.contains(visible)) {
                continue;
            }
            let source = ClientRect::new(
                surface.texture_source_x,
                surface.texture_source_y,
                surface.texture_source_width,
                surface.texture_source_height,
            )?;
            if source.x < 0.0
                || source.y < 0.0
                || source.right() > f64::from(surface.width)
                || source.bottom() > f64::from(surface.height)
            {
                return None;
            }
            if surface.opaque && surface.opacity == 1.0 {
                opaque_covers.push(visible);
            }
            layers.push(NativeWindowLayer {
                texture_id: i64::try_from(surface.texture_id).ok()?,
                destination,
                source,
                transform: surface.transform,
                opacity: surface.opacity,
                opaque: surface.opaque,
            });
            if layers.len() > MAX_NATIVE_WINDOW_LAYERS {
                return None;
            }
        }
        // Preserve the existing zero-copy route for a single contributing image.
        if layers.len() < 2 {
            return None;
        }
        layers.reverse();
        Some(Self {
            window_id,
            texture_id: (NATIVE_WINDOW_TEXTURE_NAMESPACE | window_id) as i64,
            canvas,
            scale,
            width,
            height,
            layers,
        })
    }

    /// Cropped inputs are published as virtual canvases, so layer sources
    /// address those canvases. Map them into the buffers the pass samples,
    /// using the presentation current with each input buffer, in layer order.
    /// `None` marks a layer without a current buffer; it is not drawn.
    pub(super) fn presented(
        &self,
        presentations: &[Option<ExternalTexturePresentation>],
    ) -> Option<Self> {
        if presentations.len() != self.layers.len() {
            return None;
        }
        let mut layers = Vec::with_capacity(self.layers.len());
        for (layer, presentation) in self.layers.iter().zip(presentations) {
            let Some(presentation) = presentation else {
                continue;
            };
            if !reproduces_presentation(presentation) {
                return None;
            }
            let source = layer.source;
            let [x, y, width, height] = canvas_rect_to_buffer(
                Some(presentation),
                [source.x, source.y, source.width, source.height],
            );
            layers.push(NativeWindowLayer {
                source: ClientRect::new(x, y, width, height)?,
                ..layer.clone()
            });
        }
        Some(Self {
            window_id: self.window_id,
            texture_id: self.texture_id,
            canvas: self.canvas,
            scale: self.scale,
            width: self.width,
            height: self.height,
            layers,
        })
    }

    pub(super) fn vertices(
        &self,
        layer: &NativeWindowLayer,
        buffer_size: [u32; 2],
    ) -> Option<[ClientVertex; 4]> {
        let visible = layer.destination.intersection(self.canvas)?;
        let points = [
            [visible.x, visible.y],
            [visible.right(), visible.y],
            [visible.x, visible.bottom()],
            [visible.right(), visible.bottom()],
        ];
        let mut vertices = [ClientVertex {
            position: [0.0; 2],
            uv: [0.0; 2],
        }; 4];
        for (vertex, point) in vertices.iter_mut().zip(points) {
            vertex.position = [
                ((point[0] - self.canvas.x) * self.scale) as f32,
                ((point[1] - self.canvas.y) * self.scale) as f32,
            ];
            vertex.uv = layer.uv_at(point, buffer_size)?;
        }
        Some(vertices)
    }
}

#[derive(Debug)]
pub(super) struct VersionedWindowPlan {
    pub(super) revision: u64,
    pub(super) plan: NativeWindowPlan,
}

/// Geometry revision is separate from input buffer revisions. Replacing a
/// child buffer invalidates the merged image without rebuilding its geometry.
#[derive(Default)]
pub(super) struct NativeWindowRegistry {
    plans: HashMap<i64, Arc<VersionedWindowPlan>>,
    dependents: HashMap<i64, BTreeSet<i64>>,
    next_revision: u64,
}

impl NativeWindowRegistry {
    pub(super) fn upsert(&mut self, plan: NativeWindowPlan) -> Option<Arc<VersionedWindowPlan>> {
        if let Some(previous) = self.plans.get(&plan.texture_id)
            && previous.plan == plan
        {
            return Some(Arc::clone(previous));
        }
        if !self.plans.contains_key(&plan.texture_id) && self.plans.len() >= MAX_NATIVE_WINDOW_PLANS
        {
            return None;
        }
        let revision = self.next_revision.checked_add(1)?;
        self.next_revision = revision;
        self.remove(plan.texture_id);
        for layer in &plan.layers {
            self.dependents
                .entry(layer.texture_id)
                .or_default()
                .insert(plan.texture_id);
        }
        let versioned = Arc::new(VersionedWindowPlan { revision, plan });
        self.plans
            .insert(versioned.plan.texture_id, Arc::clone(&versioned));
        Some(versioned)
    }

    /// System images also use high IDs (allocated down from i64::MAX).
    /// Namespace magnitude alone does not establish a native client image.
    pub(super) fn handles_texture(&self, texture_id: i64) -> bool {
        self.plans.contains_key(&texture_id)
    }

    pub(super) fn get(&self, texture_id: i64) -> Option<Arc<VersionedWindowPlan>> {
        self.plans.get(&texture_id).map(Arc::clone)
    }

    pub(super) fn remove(&mut self, texture_id: i64) {
        if let Some(previous) = self.plans.remove(&texture_id) {
            for layer in &previous.plan.layers {
                if let Some(dependents) = self.dependents.get_mut(&layer.texture_id) {
                    dependents.remove(&texture_id);
                    if dependents.is_empty() {
                        self.dependents.remove(&layer.texture_id);
                    }
                }
            }
        }
    }

    pub(super) fn include_dependents(&self, changed: &mut Vec<i64>) {
        let mut additional = BTreeSet::new();
        for input in changed.iter() {
            if let Some(dependents) = self.dependents.get(input) {
                additional.extend(dependents.iter().copied());
            }
        }
        for texture_id in additional {
            if !changed.contains(&texture_id) {
                changed.push(texture_id);
            }
        }
    }
}

#[cfg(test)]
#[path = "native_window/tests.rs"]
mod tests;
