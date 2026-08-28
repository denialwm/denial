use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;

pub const SCALE_BASE: u32 = 120;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct OutputId(pub u64);

/// Flutter reserves non-negative view IDs for real Dart views. Denial maps a
/// physical output into the disjoint negative namespace without depending on
/// connector enumeration order.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RenderViewId(i64);

impl RenderViewId {
    pub fn for_output(output: OutputId) -> Option<Self> {
        let output = i64::try_from(output.0).ok()?;
        output.checked_add(1)?.checked_neg().map(Self)
    }

    pub const fn get(self) -> i64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LogicalPoint {
    pub x: i32,
    pub y: i32,
}

impl LogicalPoint {
    pub const fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LogicalRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl LogicalRect {
    pub fn right(self) -> f64 {
        self.x + self.width
    }

    pub fn bottom(self) -> f64 {
        self.y + self.height
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PixelSize {
    pub width: u32,
    pub height: u32,
}

impl PixelSize {
    pub const fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PixelRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl PixelRect {
    pub const fn size(self) -> PixelSize {
        PixelSize::new(self.width, self.height)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum OutputTransform {
    #[default]
    Normal,
    Rotate90,
    Rotate180,
    Rotate270,
    Flipped,
    Flipped90,
    Flipped180,
    Flipped270,
}

impl OutputTransform {
    pub const fn swaps_axes(self) -> bool {
        matches!(
            self,
            Self::Rotate90 | Self::Rotate270 | Self::Flipped90 | Self::Flipped270
        )
    }

    /// Maps a normalized point from the connector's native axes back into the
    /// logical output axes. This is the inverse of the projection Flutter uses
    /// for scanout and is primarily used by output-bound absolute input.
    pub const fn native_to_logical(self, x: f64, y: f64) -> (f64, f64) {
        match self {
            Self::Normal => (x, y),
            Self::Rotate90 => (y, 1.0 - x),
            Self::Rotate180 => (1.0 - x, 1.0 - y),
            Self::Rotate270 => (1.0 - y, x),
            Self::Flipped => (1.0 - x, y),
            Self::Flipped90 => (y, x),
            Self::Flipped180 => (x, 1.0 - y),
            Self::Flipped270 => (1.0 - y, 1.0 - x),
        }
    }

    /// Applies a cardinal rotation after this output's fixed panel-mount
    /// transform. Keeping the two operations separate lets automatic device
    /// orientation remain transient while `transform=` continues to describe
    /// how the panel is physically installed.
    pub const fn rotated_by(self, rotation: Self) -> Self {
        let turns = match rotation {
            Self::Normal => 0,
            Self::Rotate90 => 1,
            Self::Rotate180 => 2,
            Self::Rotate270 => 3,
            // Sensor orientation is rotational. Treat a reflected argument as
            // its rotational component so this helper cannot accidentally
            // toggle panel reflection.
            Self::Flipped => 0,
            Self::Flipped90 => 1,
            Self::Flipped180 => 2,
            Self::Flipped270 => 3,
        };
        let base = match self {
            Self::Normal | Self::Flipped => 0,
            Self::Rotate90 | Self::Flipped90 => 1,
            Self::Rotate180 | Self::Flipped180 => 2,
            Self::Rotate270 | Self::Flipped270 => 3,
        };
        let reflected = matches!(
            self,
            Self::Flipped | Self::Flipped90 | Self::Flipped180 | Self::Flipped270
        );
        match ((base + turns) & 3, reflected) {
            (0, false) => Self::Normal,
            (1, false) => Self::Rotate90,
            (2, false) => Self::Rotate180,
            (3, false) => Self::Rotate270,
            (0, true) => Self::Flipped,
            (1, true) => Self::Flipped90,
            (2, true) => Self::Flipped180,
            (3, true) => Self::Flipped270,
            _ => unreachable!(),
        }
    }

    pub const fn inverse_rotation(self) -> Self {
        match self {
            Self::Normal | Self::Flipped => Self::Normal,
            Self::Rotate90 | Self::Flipped90 => Self::Rotate270,
            Self::Rotate180 | Self::Flipped180 => Self::Rotate180,
            Self::Rotate270 | Self::Flipped270 => Self::Rotate90,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutputSpec {
    pub id: OutputId,
    pub name: String,
    pub position: LogicalPoint,
    pub mode: PixelSize,
    pub scale_120: u32,
    pub refresh_millihz: u32,
    pub transform: OutputTransform,
}

impl OutputSpec {
    pub fn logical_rect(&self) -> LogicalRect {
        let transformed = self.transformed_pixel_size();
        let scale = self.scale_120 as f64 / SCALE_BASE as f64;
        LogicalRect {
            x: self.position.x as f64,
            y: self.position.y as f64,
            width: transformed.width as f64 / scale,
            height: transformed.height as f64 / scale,
        }
    }

    pub const fn transformed_pixel_size(&self) -> PixelSize {
        if self.transform.swaps_axes() {
            PixelSize::new(self.mode.height, self.mode.width)
        } else {
            self.mode
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TopologyChange {
    Upsert(OutputSpec),
    Remove(OutputId),
}

#[derive(Clone, Debug, PartialEq)]
pub struct TopologySnapshot {
    pub epoch: u64,
    pub logical_bounds: Option<LogicalRect>,
    pub ticker: Option<OutputId>,
    pub outputs: Vec<OutputSpec>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TopologyCommit {
    pub previous_epoch: u64,
    pub epoch: u64,
    pub added: Vec<OutputId>,
    pub removed: Vec<OutputId>,
    pub changed: Vec<OutputId>,
}

impl TopologyCommit {
    pub fn is_noop(&self) -> bool {
        self.previous_epoch == self.epoch
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TopologyError {
    DuplicateName(String),
    EmptyName(OutputId),
    EmptyMode(OutputId),
    InvalidScale(OutputId),
    InvalidRefresh(OutputId),
    CoordinateOverflow(OutputId),
    OverlappingOutputs(String, String),
}

impl fmt::Display for TopologyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DuplicateName(name) => write!(formatter, "duplicate output name: {name}"),
            Self::EmptyName(id) => write!(formatter, "output {id:?} has an empty name"),
            Self::EmptyMode(id) => write!(formatter, "output {id:?} has an empty mode"),
            Self::InvalidScale(id) => write!(formatter, "output {id:?} has an invalid scale"),
            Self::InvalidRefresh(id) => {
                write!(formatter, "output {id:?} has an invalid refresh rate")
            }
            Self::CoordinateOverflow(id) => {
                write!(
                    formatter,
                    "output {id:?} exceeds the supported logical coordinate range"
                )
            }
            Self::OverlappingOutputs(first, second) => {
                write!(formatter, "outputs {first} and {second} overlap")
            }
        }
    }
}

impl Error for TopologyError {}

#[derive(Clone, Debug, Default)]
pub struct TopologyManager {
    epoch: u64,
    outputs: BTreeMap<OutputId, OutputSpec>,
    primary_output: Option<String>,
}

impl TopologyManager {
    pub fn new(outputs: impl IntoIterator<Item = OutputSpec>) -> Result<Self, TopologyError> {
        Self::new_with_primary_output(outputs, None)
    }

    pub fn new_with_primary_output(
        outputs: impl IntoIterator<Item = OutputSpec>,
        primary_output: Option<String>,
    ) -> Result<Self, TopologyError> {
        let mut manager = Self::default();
        let changes = outputs.into_iter().map(TopologyChange::Upsert);
        manager.apply_with_primary_output(changes, primary_output)?;
        Ok(manager)
    }

    pub fn apply(
        &mut self,
        changes: impl IntoIterator<Item = TopologyChange>,
    ) -> Result<TopologyCommit, TopologyError> {
        self.apply_with_primary_output(changes, self.primary_output.clone())
    }

    pub fn apply_with_primary_output(
        &mut self,
        changes: impl IntoIterator<Item = TopologyChange>,
        primary_output: Option<String>,
    ) -> Result<TopologyCommit, TopologyError> {
        let previous = self.outputs.clone();
        let mut staged = previous.clone();

        for change in changes {
            match change {
                TopologyChange::Upsert(output) => {
                    staged.insert(output.id, output);
                }
                TopologyChange::Remove(id) => {
                    staged.remove(&id);
                }
            }
        }

        validate_outputs(staged.values())?;

        let previous_ids = previous.keys().copied().collect::<BTreeSet<_>>();
        let staged_ids = staged.keys().copied().collect::<BTreeSet<_>>();
        let added = staged_ids
            .difference(&previous_ids)
            .copied()
            .collect::<Vec<_>>();
        let removed = previous_ids
            .difference(&staged_ids)
            .copied()
            .collect::<Vec<_>>();
        let changed = previous_ids
            .intersection(&staged_ids)
            .filter(|id| previous.get(id) != staged.get(id))
            .copied()
            .collect::<Vec<_>>();

        let previous_epoch = self.epoch;
        if !added.is_empty()
            || !removed.is_empty()
            || !changed.is_empty()
            || self.primary_output != primary_output
        {
            self.epoch = self.epoch.wrapping_add(1).max(1);
            self.outputs = staged;
            self.primary_output = primary_output;
        }

        Ok(TopologyCommit {
            previous_epoch,
            epoch: self.epoch,
            added,
            removed,
            changed,
        })
    }

    pub fn snapshot(&self) -> TopologySnapshot {
        let outputs = self.outputs.values().cloned().collect::<Vec<_>>();
        let logical_bounds = logical_bounds(&outputs);
        let ticker = self
            .primary_output
            .as_deref()
            .and_then(|name| outputs.iter().find(|output| output.name == name))
            .or_else(|| {
                outputs
                    .iter()
                    .max_by_key(|output| (output.refresh_millihz, std::cmp::Reverse(output.id)))
            })
            .map(|output| output.id);

        TopologySnapshot {
            epoch: self.epoch,
            logical_bounds,
            ticker,
            outputs,
        }
    }

    pub const fn epoch(&self) -> u64 {
        self.epoch
    }
}

fn validate_outputs<'a>(
    outputs: impl IntoIterator<Item = &'a OutputSpec>,
) -> Result<(), TopologyError> {
    let mut names = BTreeSet::new();
    let mut logical_rects: Vec<(String, LogicalRect)> = Vec::new();
    for output in outputs {
        if output.name.trim().is_empty() {
            return Err(TopologyError::EmptyName(output.id));
        }
        if !names.insert(output.name.clone()) {
            return Err(TopologyError::DuplicateName(output.name.clone()));
        }
        if output.mode.width == 0 || output.mode.height == 0 {
            return Err(TopologyError::EmptyMode(output.id));
        }
        if output.scale_120 == 0 {
            return Err(TopologyError::InvalidScale(output.id));
        }
        if output.refresh_millihz == 0 {
            return Err(TopologyError::InvalidRefresh(output.id));
        }

        let rect = output.logical_rect();
        if !rect.x.is_finite()
            || !rect.y.is_finite()
            || !rect.width.is_finite()
            || !rect.height.is_finite()
            || rect.right() > i32::MAX as f64
            || rect.bottom() > i32::MAX as f64
            || rect.x < i32::MIN as f64
            || rect.y < i32::MIN as f64
        {
            return Err(TopologyError::CoordinateOverflow(output.id));
        }
        for (other_name, other_rect) in &logical_rects {
            if logical_rects_overlap(rect, *other_rect) {
                let (first, second) = if output.name.as_str() < other_name.as_str() {
                    (output.name.clone(), other_name.clone())
                } else {
                    (other_name.clone(), output.name.clone())
                };
                return Err(TopologyError::OverlappingOutputs(first, second));
            }
        }
        logical_rects.push((output.name.clone(), rect));
    }
    Ok(())
}

fn logical_rects_overlap(first: LogicalRect, second: LogicalRect) -> bool {
    first.x < second.right()
        && second.x < first.right()
        && first.y < second.bottom()
        && second.y < first.bottom()
}

fn logical_bounds(outputs: &[OutputSpec]) -> Option<LogicalRect> {
    let first = outputs.first()?.logical_rect();
    let mut left = first.x;
    let mut top = first.y;
    let mut right = first.right();
    let mut bottom = first.bottom();

    for output in &outputs[1..] {
        let rect = output.logical_rect();
        left = left.min(rect.x);
        top = top.min(rect.y);
        right = right.max(rect.right());
        bottom = bottom.max(rect.bottom());
    }

    Some(LogicalRect {
        x: left,
        y: top,
        width: right - left,
        height: bottom - top,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Sampling {
    OneToOne,
    Scaled,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AtlasOutput {
    pub id: OutputId,
    pub logical_rect: LogicalRect,
    pub source_rect: PixelRect,
    pub pixel_size: PixelSize,
    pub transform: OutputTransform,
    pub sampling: Sampling,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AtlasPlan {
    pub topology_epoch: u64,
    pub logical_origin: (f64, f64),
    pub logical_size: (f64, f64),
    pub engine_scale_120: u32,
    pub pixel_size: PixelSize,
    pub outputs: Vec<AtlasOutput>,
}

/// One immutable physical raster projection derived from the same topology
/// generation as the Dart desktop atlas.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderOutputPlan {
    pub output_id: OutputId,
    pub render_view_id: RenderViewId,
    pub configuration_generation: u64,
    pub source_rect: PixelRect,
    pub target_size: PixelSize,
    pub scale_120: u32,
    pub source_to_target_transform: OutputProjection,
}

/// An affine mapping from the implicit Flutter view's physical pixels into a
/// native output buffer. Coefficients follow Flutter's two-dimensional
/// transformation layout:
///
/// `x' = scale_x * x + skew_x * y + translate_x`
/// `y' = skew_y * x + scale_y * y + translate_y`
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputProjection {
    pub scale_x: f64,
    pub skew_x: f64,
    pub translate_x: f64,
    pub skew_y: f64,
    pub scale_y: f64,
    pub translate_y: f64,
}

impl OutputProjection {
    fn for_output(output: &OutputSpec, source: PixelRect) -> Self {
        let oriented = output.transformed_pixel_size();
        let width = f64::from(oriented.width);
        let height = f64::from(oriented.height);
        let source_scale_x = width / f64::from(source.width);
        let source_scale_y = height / f64::from(source.height);

        // Map output-local, transformed pixels into the connector's native
        // pixel axes. These are the same eight geometric operations exposed by
        // wl_output, but Flutter applies them before KMS sees the buffer.
        let (scale_x, skew_x, translate_x, skew_y, scale_y, translate_y) = match output.transform {
            OutputTransform::Normal => (1.0, 0.0, 0.0, 0.0, 1.0, 0.0),
            OutputTransform::Rotate90 => (0.0, -1.0, height, 1.0, 0.0, 0.0),
            OutputTransform::Rotate180 => (-1.0, 0.0, width, 0.0, -1.0, height),
            OutputTransform::Rotate270 => (0.0, 1.0, 0.0, -1.0, 0.0, width),
            OutputTransform::Flipped => (-1.0, 0.0, width, 0.0, 1.0, 0.0),
            OutputTransform::Flipped90 => (0.0, 1.0, 0.0, 1.0, 0.0, 0.0),
            OutputTransform::Flipped180 => (1.0, 0.0, 0.0, 0.0, -1.0, height),
            OutputTransform::Flipped270 => (0.0, -1.0, height, -1.0, 0.0, width),
        };
        let source_x = f64::from(source.x);
        let source_y = f64::from(source.y);
        Self {
            scale_x: scale_x * source_scale_x,
            skew_x: skew_x * source_scale_y,
            translate_x: translate_x
                - scale_x * source_scale_x * source_x
                - skew_x * source_scale_y * source_y,
            skew_y: skew_y * source_scale_x,
            scale_y: scale_y * source_scale_y,
            translate_y: translate_y
                - skew_y * source_scale_x * source_x
                - scale_y * source_scale_y * source_y,
        }
    }
}

impl AtlasPlan {
    pub fn for_snapshot(snapshot: &TopologySnapshot) -> Option<Self> {
        let bounds = snapshot.logical_bounds?;
        let engine_scale_120 = snapshot
            .outputs
            .iter()
            .map(|output| output.scale_120)
            .max()
            .unwrap_or(SCALE_BASE);
        let engine_scale = engine_scale_120 as f64 / SCALE_BASE as f64;

        let width = scaled_edge(bounds.width, engine_scale);
        let height = scaled_edge(bounds.height, engine_scale);
        let mut outputs = Vec::with_capacity(snapshot.outputs.len());

        for output in &snapshot.outputs {
            let logical_rect = output.logical_rect();
            let left = scaled_edge(logical_rect.x - bounds.x, engine_scale);
            let top = scaled_edge(logical_rect.y - bounds.y, engine_scale);
            let right = scaled_edge(logical_rect.right() - bounds.x, engine_scale);
            let bottom = scaled_edge(logical_rect.bottom() - bounds.y, engine_scale);
            let source_rect = PixelRect {
                x: left,
                y: top,
                width: right.saturating_sub(left).max(1),
                height: bottom.saturating_sub(top).max(1),
            };
            let pixel_size = output.transformed_pixel_size();
            let sampling = if source_rect.size() == pixel_size {
                Sampling::OneToOne
            } else {
                Sampling::Scaled
            };
            outputs.push(AtlasOutput {
                id: output.id,
                logical_rect,
                source_rect,
                pixel_size,
                transform: output.transform,
                sampling,
            });
        }

        Some(Self {
            topology_epoch: snapshot.epoch,
            logical_origin: (bounds.x, bounds.y),
            logical_size: (bounds.width, bounds.height),
            engine_scale_120,
            pixel_size: PixelSize::new(width.max(1), height.max(1)),
            outputs,
        })
    }

    pub fn render_outputs(&self, snapshot: &TopologySnapshot) -> Option<Vec<RenderOutputPlan>> {
        if self.topology_epoch == 0
            || self.topology_epoch != snapshot.epoch
            || self.outputs.len() != snapshot.outputs.len()
        {
            return None;
        }

        snapshot
            .outputs
            .iter()
            .map(|output| {
                let atlas_output = self
                    .outputs
                    .iter()
                    .find(|planned| planned.id == output.id)?;
                Some(RenderOutputPlan {
                    output_id: output.id,
                    render_view_id: RenderViewId::for_output(output.id)?,
                    configuration_generation: snapshot.epoch,
                    source_rect: atlas_output.source_rect,
                    target_size: output.mode,
                    scale_120: output.scale_120,
                    source_to_target_transform: OutputProjection::for_output(
                        output,
                        atlas_output.source_rect,
                    ),
                })
            })
            .collect()
    }
}

fn scaled_edge(value: f64, scale: f64) -> u32 {
    (value * scale).round().clamp(0.0, u32::MAX as f64) as u32
}
