//! Publish physical monitor membership without a whole-desktop Space::refresh.
use smithay::{
    desktop::space::SpaceElement,
    output::Output,
    utils::{Logical, Point, Rectangle},
};

pub(super) fn refresh_window_outputs<'a>(
    window: &impl SpaceElement,
    location: Point<i32, Logical>,
    outputs: impl IntoIterator<Item = (&'a Output, Rectangle<i32, Logical>)>,
) {
    // Match Space's root-relative overlap convention, including CSD/popups.
    let mut bounds = window.bbox();
    bounds.loc += location - window.geometry().loc;
    for (output, geometry) in outputs {
        if let Some(mut overlap) = geometry.intersection(bounds) {
            overlap.loc -= bounds.loc;
            window.output_enter(output, overlap);
        } else {
            window.output_leave(output);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use smithay::{
        output::{Mode, PhysicalProperties, Subpixel},
        utils::IsAlive,
    };
    use std::cell::RefCell;
    #[derive(Default)]
    struct Window(RefCell<Vec<(String, Option<Rectangle<i32, Logical>>)>>);
    impl IsAlive for Window {
        fn alive(&self) -> bool {
            true
        }
    }
    impl SpaceElement for Window {
        fn bbox(&self) -> Rectangle<i32, Logical> {
            Rectangle::new((10, 20).into(), (200, 100).into())
        }
        fn is_in_input_region(&self, _: &Point<f64, Logical>) -> bool {
            false
        }
        fn set_activate(&self, _: bool) {}
        fn output_enter(&self, output: &Output, overlap: Rectangle<i32, Logical>) {
            self.0.borrow_mut().push((output.name(), Some(overlap)));
        }
        fn output_leave(&self, output: &Output) {
            self.0.borrow_mut().push((output.name(), None));
        }
    }
    fn output(name: &str, refresh: i32) -> Output {
        let output = Output::new(
            name.to_owned(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "test".into(),
                model: name.into(),
                serial_number: name.into(),
            },
        );
        output.change_current_state(
            Some(Mode {
                size: (1000, 1000).into(),
                refresh,
            }),
            None,
            None,
            None,
        );
        output
    }
    #[test]
    fn map_move_and_overlap_publish_the_physical_monitor() {
        let slow = output("144Hz", 144_000);
        let fast = output("240Hz", 240_000);
        let monitors = [
            (&slow, Rectangle::new((0, 0).into(), (1000, 1000).into())),
            (&fast, Rectangle::new((1000, 0).into(), (1000, 1000).into())),
        ];
        let window = Window::default();
        refresh_window_outputs(&window, (100, 100).into(), monitors);
        assert!(window.0.borrow()[0].1.is_some());
        assert!(window.0.borrow()[1].1.is_none());
        window.0.borrow_mut().clear();
        refresh_window_outputs(&window, (1100, 100).into(), monitors);
        assert!(window.0.borrow()[0].1.is_none());
        assert_eq!(
            window.0.borrow()[1],
            (
                "240Hz".into(),
                Some(Rectangle::from_size((200, 100).into()))
            )
        );
        assert_eq!(fast.current_mode().unwrap().refresh, 240_000);
        window.0.borrow_mut().clear();
        refresh_window_outputs(&window, (900, 100).into(), monitors);
        assert_eq!(window.0.borrow()[0].1.unwrap().size.w, 100);
        assert_eq!(window.0.borrow()[1].1.unwrap().loc.x, 100);
    }
}
