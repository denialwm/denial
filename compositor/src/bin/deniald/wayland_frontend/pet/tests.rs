use super::*;

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rectangle<f64, Logical> {
    Rectangle::new(Point::from((x, y)), Size::from((w, h)))
}

fn point(x: f64, y: f64) -> Point<f64, Logical> {
    Point::from((x, y))
}

#[test]
fn holds_are_on_the_frame() {
    let frame = rect(100.0, 200.0, 400.0, 300.0);
    assert_eq!(hold_point(frame, Hold::Top, 0.25), point(200.0, 200.0));
    assert_eq!(hold_point(frame, Hold::Bottom, 0.5), point(300.0, 500.0));
    assert_eq!(hold_point(frame, Hold::Left, 0.5), point(100.0, 350.0));
    assert_eq!(hold_point(frame, Hold::Right, 1.0), point(500.0, 500.0));
    assert_eq!(
        hold_point(frame, Hold::BottomRight, 0.3),
        point(500.0, 500.0)
    );
}

#[test]
fn a_pet_takes_only_a_hold_it_accepts() {
    let edges = Hold::Top as u32 | Hold::Bottom as u32;
    assert_eq!(
        accepted_hold(edges, Hold::Top as u32, 0.25),
        Some((Hold::Top, 0.25))
    );
    assert_eq!(accepted_hold(edges, Hold::Left as u32, 0.5), None);
    // One hold at a time, a known one, along the edge.
    assert_eq!(accepted_hold(edges, edges, 0.5), None);
    assert_eq!(accepted_hold(0xffff_ffff, 1 << 9, 0.5), None);
    assert_eq!(accepted_hold(edges, Hold::Top as u32, f64::NAN), None);
    assert_eq!(
        accepted_hold(edges, Hold::Bottom as u32, 1.2),
        Some((Hold::Bottom, 1.0))
    );
}

#[test]
fn a_dragged_pet_learns_how_fast_it_moves() {
    let from = point(100.0, 100.0);
    let ms = Duration::from_millis;
    // 20 px right and 10 down in 20 ms.
    assert_eq!(
        drag_speed(from, point(120.0, 110.0), ms(20)),
        Some(point(1000.0, 500.0))
    );
    // Too soon to tell, and within the fastest it is carried.
    assert_eq!(drag_speed(from, point(120.0, 110.0), ms(5)), None);
    assert_eq!(
        drag_speed(from, point(1e9, 100.0), ms(16)),
        Some(point(FASTEST_CARRY, 0.0))
    );
    assert_eq!(drag_speed(from, point(f64::NAN, 0.0), ms(20)), None);
    // A change under 1 px/s is not worth sending; stopping always is.
    let moving = point(1000.0, 500.0);
    assert!(!drag_speed_changed(point(1000.5, 500.0), moving));
    assert!(drag_speed_changed(point(1002.0, 500.0), moving));
    assert!(drag_speed_changed(point(0.0, 0.0), point(0.5, 0.0)));
    assert!(!drag_speed_changed(point(0.0, 0.0), point(0.0, 0.0)));
}

#[test]
fn a_pet_learns_only_which_way_the_pointer_is() {
    let anchor = point(100.0, 100.0);
    let way = pointing(anchor, point(400.0, 500.0), None).unwrap();
    assert!((way.x - 0.6).abs() < 1e-12 && (way.y - 0.8).abs() < 1e-12);
    // As far again the same way says nothing new.
    assert_eq!(pointing(anchor, point(700.0, 900.0), Some(way)), None);
    // Nor does a turn within 2°; a larger one does.
    let turned = |degrees: f64| {
        let angle = 0.8f64.atan2(0.6) + degrees.to_radians();
        point(100.0 + 300.0 * angle.cos(), 100.0 + 300.0 * angle.sin())
    };
    assert_eq!(pointing(anchor, turned(1.5), Some(way)), None);
    assert!(pointing(anchor, turned(2.5), Some(way)).is_some());
    // Nothing while the pointer is on the anchor.
    assert_eq!(pointing(anchor, point(100.4, 99.8), None), None);
    assert_eq!(pointing(anchor, point(f64::NAN, 0.0), None), None);
}
