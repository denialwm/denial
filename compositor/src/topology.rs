use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;

pub const SCALE_BASE: u32 = 120;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct OutputId(pub u64);

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
        }
    }
}

impl Error for TopologyError {}

#[derive(Clone, Debug, Default)]
pub struct TopologyManager {
    epoch: u64,
    outputs: BTreeMap<OutputId, OutputSpec>,
}

impl TopologyManager {
    pub fn new(outputs: impl IntoIterator<Item = OutputSpec>) -> Result<Self, TopologyError> {
        let mut manager = Self::default();
        let changes = outputs.into_iter().map(TopologyChange::Upsert);
        manager.apply(changes)?;
        Ok(manager)
    }

    pub fn apply(
        &mut self,
        changes: impl IntoIterator<Item = TopologyChange>,
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
        if !added.is_empty() || !removed.is_empty() || !changed.is_empty() {
            self.epoch = self.epoch.wrapping_add(1).max(1);
            self.outputs = staged;
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
        let ticker = outputs
            .iter()
            .max_by_key(|output| (output.refresh_millihz, std::cmp::Reverse(output.id)))
            .map(|output| output.id);

        TopologySnapshot {
            epoch: self.epoch,
            logical_bounds,
            ticker,
            outputs,
        }
    }
}

fn validate_outputs<'a>(
    outputs: impl IntoIterator<Item = &'a OutputSpec>,
) -> Result<(), TopologyError> {
    let mut names = BTreeSet::new();
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
    }
    Ok(())
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
    pub scanout_size: PixelSize,
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
            let scanout_size = output.transformed_pixel_size();
            let sampling = if source_rect.size() == scanout_size {
                Sampling::OneToOne
            } else {
                Sampling::Scaled
            };
            outputs.push(AtlasOutput {
                id: output.id,
                logical_rect,
                source_rect,
                scanout_size,
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
}

fn scaled_edge(value: f64, scale: f64) -> u32 {
    (value * scale).round().clamp(0.0, u32::MAX as f64) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(
        id: u64,
        name: &str,
        position: (i32, i32),
        mode: (u32, u32),
        scale_120: u32,
        refresh_millihz: u32,
    ) -> OutputSpec {
        OutputSpec {
            id: OutputId(id),
            name: name.into(),
            position: LogicalPoint::new(position.0, position.1),
            mode: PixelSize::new(mode.0, mode.1),
            scale_120,
            refresh_millihz,
            transform: OutputTransform::Normal,
        }
    }

    #[test]
    fn normalizes_negative_coordinates_without_changing_global_origin() {
        let manager = TopologyManager::new([
            output(1, "left", (-1920, 0), (1920, 1080), 120, 60_000),
            output(2, "main", (0, -360), (2560, 1440), 120, 200_000),
        ])
        .unwrap();

        let snapshot = manager.snapshot();
        assert_eq!(snapshot.logical_bounds.unwrap().x, -1920.0);
        assert_eq!(snapshot.logical_bounds.unwrap().y, -360.0);
        assert_eq!(snapshot.ticker, Some(OutputId(2)));

        let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
        assert_eq!(atlas.logical_origin, (-1920.0, -360.0));
        assert_eq!(atlas.pixel_size, PixelSize::new(4480, 1440));
        assert_eq!(atlas.outputs[0].source_rect.x, 0);
        assert_eq!(atlas.outputs[0].source_rect.y, 360);
        assert_eq!(atlas.outputs[1].source_rect.x, 1920);
        assert_eq!(atlas.outputs[1].source_rect.y, 0);
    }

    #[test]
    fn vertical_and_l_shaped_layouts_are_not_special_cases() {
        let manager = TopologyManager::new([
            output(1, "top", (0, -1080), (1920, 1080), 120, 60_000),
            output(2, "main", (0, 0), (2560, 1440), 120, 144_000),
            output(3, "right", (2560, 360), (1920, 1080), 120, 75_000),
        ])
        .unwrap();

        let atlas = AtlasPlan::for_snapshot(&manager.snapshot()).unwrap();
        assert_eq!(atlas.pixel_size, PixelSize::new(4480, 2520));
        assert!(
            atlas
                .outputs
                .iter()
                .all(|output| output.sampling == Sampling::OneToOne)
        );
    }

    #[test]
    fn fractional_and_mixed_scale_are_explicit_in_the_atlas_plan() {
        let manager = TopologyManager::new([
            output(1, "hidpi", (0, 0), (3840, 2160), 240, 120_000),
            output(2, "fractional", (1920, 0), (2560, 1440), 150, 165_000),
        ])
        .unwrap();

        let snapshot = manager.snapshot();
        let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
        assert_eq!(atlas.engine_scale_120, 240);
        assert_eq!(atlas.outputs[0].sampling, Sampling::OneToOne);
        assert_eq!(atlas.outputs[1].sampling, Sampling::Scaled);
        assert_eq!(atlas.outputs[1].scanout_size, PixelSize::new(2560, 1440));
    }

    #[test]
    fn rotation_swaps_logical_and_scanout_axes() {
        let mut portrait = output(1, "portrait", (0, 0), (1080, 1920), 120, 60_000);
        portrait.transform = OutputTransform::Rotate90;
        let manager = TopologyManager::new([portrait]).unwrap();
        let snapshot = manager.snapshot();
        assert_eq!(snapshot.logical_bounds.unwrap().width, 1920.0);
        assert_eq!(snapshot.logical_bounds.unwrap().height, 1080.0);
        assert_eq!(
            AtlasPlan::for_snapshot(&snapshot).unwrap().outputs[0].scanout_size,
            PixelSize::new(1920, 1080)
        );
    }

    #[test]
    fn hotplug_transaction_is_atomic_and_epoch_only_changes_for_real_work() {
        let mut manager =
            TopologyManager::new([output(1, "main", (0, 0), (2560, 1440), 120, 200_000)]).unwrap();
        let original = manager.snapshot();

        let noop = manager
            .apply([TopologyChange::Upsert(original.outputs[0].clone())])
            .unwrap();
        assert!(noop.is_noop());

        let commit = manager
            .apply([
                TopologyChange::Upsert(output(2, "side", (-1920, 0), (1920, 1080), 120, 60_000)),
                TopologyChange::Upsert(output(1, "main", (0, -100), (2560, 1440), 120, 200_000)),
            ])
            .unwrap();
        assert_eq!(commit.added, vec![OutputId(2)]);
        assert_eq!(commit.changed, vec![OutputId(1)]);
        assert_eq!(commit.epoch, original.epoch + 1);

        let before_invalid = manager.snapshot();
        let invalid = output(3, "side", (0, 0), (1280, 720), 120, 60_000);
        assert!(matches!(
            manager.apply([TopologyChange::Upsert(invalid)]),
            Err(TopologyError::DuplicateName(_))
        ));
        assert_eq!(manager.snapshot(), before_invalid);
    }

    #[test]
    fn removing_the_last_output_is_a_valid_hotplug_state() {
        let mut manager =
            TopologyManager::new([output(1, "main", (0, 0), (1920, 1080), 120, 60_000)]).unwrap();
        manager
            .apply([TopologyChange::Remove(OutputId(1))])
            .unwrap();
        let snapshot = manager.snapshot();
        assert!(snapshot.outputs.is_empty());
        assert!(snapshot.logical_bounds.is_none());
        assert!(snapshot.ticker.is_none());
        assert!(AtlasPlan::for_snapshot(&snapshot).is_none());
    }
}
