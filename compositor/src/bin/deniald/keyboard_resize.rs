//! Keyboard resizing uses logical pixels, independently of output scale.

#[cfg(feature = "flutter")]
use smithay::utils::{Logical, Rectangle, Size};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum KeyboardResize {
    GrowWidth,
    ShrinkWidth,
    GrowHeight,
    ShrinkHeight,
    ResetHeight,
    ResetWidth,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum ResizeStep {
    Pixels(f64),
    Percent(f64),
}

impl Default for ResizeStep {
    fn default() -> Self {
        Self::Percent(2.0)
    }
}

impl ResizeStep {
    /// Unsigned positive amounts: `32`, `32px`, or `10%`.
    pub(super) fn parse(value: &str) -> Option<Self> {
        let (number, percent) = if let Some(number) = value.strip_suffix('%') {
            (number, true)
        } else {
            (value.strip_suffix("px").unwrap_or(value), false)
        };
        if number.is_empty()
            || !number
                .bytes()
                .all(|byte| byte.is_ascii_digit() || byte == b'.')
        {
            return None;
        }
        let amount: f64 = number.parse().ok()?;
        let limit = if percent { 100.0 } else { 32768.0 };
        if !amount.is_finite() || amount <= 0.0 || amount > limit {
            return None;
        }
        Some(if percent {
            Self::Percent(amount)
        } else {
            Self::Pixels(amount)
        })
    }

    #[cfg(feature = "flutter")]
    fn pixels(self, extent: i32) -> i32 {
        let pixels = match self {
            Self::Pixels(amount) => amount,
            Self::Percent(amount) => f64::from(extent.max(1)) * amount / 100.0,
        };
        pixels.round().max(1.0) as i32
    }
}

#[cfg(feature = "flutter")]
impl KeyboardResize {
    pub(super) fn layout_change(
        self,
        work_area: Rectangle<i32, Logical>,
        step: ResizeStep,
    ) -> (
        super::window_layout::LayoutAxis,
        super::window_layout::LayoutSizeChange,
    ) {
        use super::window_layout::{LayoutAxis, LayoutSizeChange};
        let (axis, sign) = match self {
            Self::GrowWidth => (LayoutAxis::Horizontal, 1),
            Self::ShrinkWidth => (LayoutAxis::Horizontal, -1),
            Self::GrowHeight => (LayoutAxis::Vertical, 1),
            Self::ShrinkHeight => (LayoutAxis::Vertical, -1),
            Self::ResetWidth => return (LayoutAxis::Horizontal, LayoutSizeChange::Reset),
            Self::ResetHeight => return (LayoutAxis::Vertical, LayoutSizeChange::Reset),
        };
        (
            axis,
            LayoutSizeChange::Adjust(f64::from(step.pixels(axis.main_extent(work_area)) * sign)),
        )
    }

    pub(super) fn geometry(
        self,
        mut current: Rectangle<i32, Logical>,
        work_area: Rectangle<i32, Logical>,
        minimum: Size<i32, Logical>,
        maximum: Size<i32, Logical>,
        step: ResizeStep,
    ) -> Rectangle<i32, Logical> {
        use super::window_grab::constrain_dimension;
        match self {
            Self::GrowWidth | Self::ShrinkWidth => {
                let delta =
                    step.pixels(work_area.size.w) * if self == Self::GrowWidth { 1 } else { -1 };
                current.size.w =
                    constrain_dimension(current.size.w.saturating_add(delta), minimum.w, maximum.w);
            }
            Self::GrowHeight | Self::ShrinkHeight => {
                let delta =
                    step.pixels(work_area.size.h) * if self == Self::GrowHeight { 1 } else { -1 };
                current.size.h =
                    constrain_dimension(current.size.h.saturating_add(delta), minimum.h, maximum.h);
            }
            Self::ResetWidth => {
                current.loc.x = work_area.loc.x;
                current.size.w = constrain_dimension(work_area.size.w, minimum.w, maximum.w);
            }
            Self::ResetHeight => {
                current.loc.y = work_area.loc.y;
                current.size.h = constrain_dimension(work_area.size.h, minimum.h, maximum.h);
            }
        }
        current
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_accept_pixels_and_percent_and_reject_invalid_amounts() {
        assert_eq!(ResizeStep::parse("32"), Some(ResizeStep::Pixels(32.0)));
        assert_eq!(ResizeStep::parse("32px"), Some(ResizeStep::Pixels(32.0)));
        assert_eq!(ResizeStep::parse("2.5%"), Some(ResizeStep::Percent(2.5)));
        for value in [
            "", "0", "0%", "-5", "+5", "NaN", "inf", "101%", "32769", "2em", "1e3", "1.2.3",
        ] {
            assert_eq!(ResizeStep::parse(value), None, "{value}");
        }
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn resizing_preserves_position_and_other_axis_and_obeys_client_limits() {
        let current = Rectangle::new((1200, 90).into(), (500, 400).into());
        let work = Rectangle::new((1000, 30).into(), (1000, 800).into());
        let min = Size::from((450, 350));
        let max = Size::from((550, 450));
        for (action, size) in [
            (KeyboardResize::GrowWidth, (550, 400)),
            (KeyboardResize::ShrinkWidth, (450, 400)),
            (KeyboardResize::GrowHeight, (500, 450)),
            (KeyboardResize::ShrinkHeight, (500, 350)),
        ] {
            let result = action.geometry(current, work, min, max, ResizeStep::Percent(10.0));
            assert_eq!(result.loc, current.loc);
            assert_eq!(result.size, Size::from(size));
        }
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn percentages_use_work_area_and_reset_is_idempotent() {
        let current = Rectangle::new((-1500, 90).into(), (500, 400).into());
        let work = Rectangle::new((-1920, 30).into(), (1920, 1000).into());
        let min = Size::from((1, 1));
        let max = Size::from((0, 0));
        assert_eq!(
            KeyboardResize::GrowWidth
                .geometry(current, work, min, max, ResizeStep::default())
                .size
                .w,
            538
        );
        assert_eq!(
            KeyboardResize::ShrinkHeight
                .geometry(current, work, min, max, ResizeStep::Pixels(32.0))
                .size
                .h,
            368
        );
        let reset =
            KeyboardResize::ResetHeight.geometry(current, work, min, max, ResizeStep::default());
        assert_eq!(
            reset,
            Rectangle::new((-1500, 30).into(), (500, 1000).into())
        );
        assert_eq!(
            KeyboardResize::ResetHeight.geometry(reset, work, min, max, ResizeStep::default()),
            reset
        );
        assert_eq!(ResizeStep::Percent(0.01).pixels(100), 1);
    }
    #[cfg(feature = "flutter")]
    #[test]
    fn width_reset_is_physical_constrained_and_idempotent() {
        use super::super::window_layout::{LayoutAxis, LayoutSizeChange};
        let current = Rectangle::new((1200, 90).into(), (500, 400).into());
        let work = Rectangle::new((1000, 30).into(), (1000, 800).into());
        let min = Size::from((450, 350));
        let max = Size::from((750, 450));
        let reset =
            KeyboardResize::ResetWidth.geometry(current, work, min, max, ResizeStep::default());
        assert_eq!(reset, Rectangle::new((1000, 90).into(), (750, 400).into()));
        assert_eq!(
            KeyboardResize::ResetWidth.geometry(reset, work, min, max, ResizeStep::default()),
            reset
        );
        assert_eq!(
            KeyboardResize::ResetWidth.layout_change(work, ResizeStep::default()),
            (LayoutAxis::Horizontal, LayoutSizeChange::Reset)
        );
        assert_eq!(
            KeyboardResize::ResetHeight.layout_change(work, ResizeStep::default()),
            (LayoutAxis::Vertical, LayoutSizeChange::Reset)
        );
    }
}
