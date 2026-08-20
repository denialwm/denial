//! Resident-output geometry and animated projection transitions.

use super::*;

#[derive(Clone, Copy, Debug)]
pub(crate) struct RuntimeRenderOutput {
    pub(crate) output_id: OutputId,
    pub(crate) render_view_id: RenderViewId,
    pub(crate) configuration_generation: u64,
    pub(crate) target_size: PixelSize,
    pub(crate) transform: OutputTransform,
    pub(crate) logical_x: f64,
    pub(crate) logical_y: f64,
    pub(crate) logical_width: f64,
    pub(crate) logical_height: f64,
}

impl RuntimeRenderOutput {
    pub(crate) fn intersects(self, x: f64, y: f64, width: f64, height: f64) -> bool {
        width > 0.0
            && height > 0.0
            && x < self.logical_x + self.logical_width
            && y < self.logical_y + self.logical_height
            && x + width > self.logical_x
            && y + height > self.logical_y
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum OutputGeometryTransition {
    Immediate,
    AnimatedRotation,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct OutputRotationAdvance {
    pub(crate) advanced: bool,
    pub(crate) geometry_published: bool,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct AnimatedOutputRotation {
    pub(crate) frame_index: usize,
    pub(crate) initial_angle: f64,
    pub(crate) initial_scale_x: f64,
    pub(crate) initial_scale_y: f64,
}

#[derive(Debug)]
pub(crate) struct OutputRotationAnimation {
    pub(crate) started_at: Instant,
    before_resize_targets: Vec<RenderOutput>,
    after_resize_targets: Vec<RenderOutput>,
    frame: Vec<RenderOutput>,
    outputs: Vec<AnimatedOutputRotation>,
    resized: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct OutputRotationSample {
    pub(crate) complete: bool,
    pub(crate) geometry_resize_due: bool,
}

#[derive(Debug)]
pub(crate) struct PendingOutputGeometry {
    pub(crate) snapshot: TopologySnapshot,
    pub(crate) atlas: AtlasPlan,
    pub(crate) ffi_outputs: Vec<RenderOutput>,
    pub(crate) runtime_outputs: Vec<RuntimeRenderOutput>,
}

impl OutputRotationAnimation {
    pub(crate) fn new(
        previous: &[RuntimeRenderOutput],
        previous_targets: &[RenderOutput],
        current: &[RuntimeRenderOutput],
        targets: &[RenderOutput],
        now: Instant,
    ) -> Option<Self> {
        if previous.len() != previous_targets.len() || current.len() != targets.len() {
            return None;
        }
        let mut before_resize_targets = Vec::with_capacity(targets.len());
        let mut outputs = Vec::new();
        for (frame_index, output) in current.iter().enumerate() {
            let previous = previous
                .iter()
                .find(|previous| previous.output_id == output.output_id)?;
            let mut before_target = *previous_targets
                .iter()
                .find(|target| target.render_view_id == previous.render_view_id.get())?;
            let delta = shortest_rotation_delta(previous.transform, output.transform);
            if delta != 0 {
                let (initial_scale_x, initial_scale_y) = if delta.unsigned_abs() & 1 == 1 {
                    (
                        f64::from(output.target_size.width) / f64::from(output.target_size.height),
                        f64::from(output.target_size.height) / f64::from(output.target_size.width),
                    )
                } else {
                    (1.0, 1.0)
                };
                debug_assert_eq!(
                    targets[frame_index].render_view_id,
                    output.render_view_id.get()
                );
                let animation = AnimatedOutputRotation {
                    frame_index,
                    initial_angle: -f64::from(delta) * std::f64::consts::FRAC_PI_2,
                    initial_scale_x,
                    initial_scale_y,
                };
                before_target.source_to_target_transform = rotated_render_transform(
                    before_target.source_to_target_transform,
                    before_target.target_width as f64,
                    before_target.target_height as f64,
                    -animation.initial_angle,
                    animation.initial_scale_x,
                    animation.initial_scale_y,
                );
                outputs.push(animation);
            }
            before_resize_targets.push(before_target);
        }
        if outputs.is_empty() {
            return None;
        }
        let after_resize_targets = targets.to_vec();
        let frame = before_resize_targets.clone();
        Some(Self {
            started_at: now,
            before_resize_targets,
            after_resize_targets,
            frame,
            outputs,
            resized: false,
        })
    }

    pub(crate) fn sample(&mut self, now: Instant) -> (&[RenderOutput], OutputRotationSample) {
        let linear = now.saturating_duration_since(self.started_at).as_secs_f64()
            / OUTPUT_ROTATION_ANIMATION_DURATION.as_secs_f64();
        let complete = linear >= 1.0;
        let eased = ease_in_out_cubic(linear.clamp(0.0, 1.0));
        let geometry_resize_due = !self.resized && eased >= OUTPUT_ROTATION_RESIZE_PROGRESS;
        self.resized |= geometry_resize_due;
        let targets = if self.resized {
            &self.after_resize_targets
        } else {
            &self.before_resize_targets
        };
        self.frame.copy_from_slice(targets);
        for animated in &self.outputs {
            let output = &mut self.frame[animated.frame_index];
            output.source_to_target_transform = animated_rotation_transform(
                output.source_to_target_transform,
                output.target_width as f64,
                output.target_height as f64,
                *animated,
                eased,
            );
        }
        (
            &self.frame,
            OutputRotationSample {
                complete,
                geometry_resize_due,
            },
        )
    }
}

fn transform_turns(transform: OutputTransform) -> i8 {
    match transform {
        OutputTransform::Normal | OutputTransform::Flipped => 0,
        OutputTransform::Rotate90 | OutputTransform::Flipped90 => 1,
        OutputTransform::Rotate180 | OutputTransform::Flipped180 => 2,
        OutputTransform::Rotate270 | OutputTransform::Flipped270 => 3,
    }
}

pub(crate) fn shortest_rotation_delta(previous: OutputTransform, current: OutputTransform) -> i8 {
    match (transform_turns(current) - transform_turns(previous)).rem_euclid(4) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => -1,
        _ => unreachable!(),
    }
}

fn ease_in_out_cubic(progress: f64) -> f64 {
    if progress < 0.5 {
        4.0 * progress * progress * progress
    } else {
        1.0 - (-2.0 * progress + 2.0).powi(3) / 2.0
    }
}

pub(crate) fn animated_rotation_transform(
    target: RenderOutputTransform,
    target_width: f64,
    target_height: f64,
    animation: AnimatedOutputRotation,
    progress: f64,
) -> RenderOutputTransform {
    let remaining = 1.0 - progress;
    let angle = animation.initial_angle * remaining;
    let scale_x = animation.initial_scale_x.powf(remaining);
    let scale_y = animation.initial_scale_y.powf(remaining);
    rotated_render_transform(target, target_width, target_height, angle, scale_x, scale_y)
}

fn rotated_render_transform(
    target: RenderOutputTransform,
    target_width: f64,
    target_height: f64,
    angle: f64,
    scale_x: f64,
    scale_y: f64,
) -> RenderOutputTransform {
    let (sin, cos) = angle.sin_cos();
    let center_x = target_width * 0.5;
    let center_y = target_height * 0.5;
    let presentation = RenderOutputTransform {
        scale_x: scale_x * cos,
        skew_x: -scale_x * sin,
        translate_x: center_x - scale_x * cos * center_x + scale_x * sin * center_y,
        skew_y: scale_y * sin,
        scale_y: scale_y * cos,
        translate_y: center_y - scale_y * sin * center_x - scale_y * cos * center_y,
    };
    compose_render_transforms(presentation, target)
}

/// Returns `after(before(point))` in Flutter's affine field layout.
fn compose_render_transforms(
    after: RenderOutputTransform,
    before: RenderOutputTransform,
) -> RenderOutputTransform {
    RenderOutputTransform {
        scale_x: after.scale_x * before.scale_x + after.skew_x * before.skew_y,
        skew_x: after.scale_x * before.skew_x + after.skew_x * before.scale_y,
        translate_x: after.scale_x * before.translate_x
            + after.skew_x * before.translate_y
            + after.translate_x,
        skew_y: after.skew_y * before.scale_x + after.scale_y * before.skew_y,
        scale_y: after.skew_y * before.skew_x + after.scale_y * before.scale_y,
        translate_y: after.skew_y * before.translate_x
            + after.scale_y * before.translate_y
            + after.translate_y,
    }
}
