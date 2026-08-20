use super::*;

#[test]
fn output_score_prefers_center_then_overlap_then_distance_stably() {
    let baseline = OutputCandidateScore {
        contains_center: false,
        overlap: 100,
        distance: 50,
    };
    assert!(output_candidate_is_better(
        OutputCandidateScore {
            contains_center: true,
            overlap: 1,
            distance: 500,
        },
        baseline,
    ));
    assert!(output_candidate_is_better(
        OutputCandidateScore {
            overlap: 101,
            ..baseline
        },
        baseline,
    ));
    assert!(output_candidate_is_better(
        OutputCandidateScore {
            distance: 49,
            ..baseline
        },
        baseline,
    ));
    assert!(!output_candidate_is_better(baseline, baseline));
}

#[test]
fn popup_anchor_selects_the_monitor_it_belongs_to() {
    let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
    let desired = Rectangle::new((1800, 100).into(), (400, 300).into());

    assert_eq!(
        choose_popup_output([left, right], (2000, 200).into(), desired),
        Some(right),
    );
}

#[test]
fn popup_without_an_on_screen_anchor_prefers_visible_overlap() {
    let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
    let desired = Rectangle::new((2100, 100).into(), (400, 300).into());

    assert_eq!(
        choose_popup_output([left, right], (-100, -100).into(), desired),
        Some(right),
    );
}

#[test]
fn popup_output_distance_saturates_for_extreme_client_coordinates() {
    let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
    assert_eq!(
        point_distance_squared(output, Point::from((i32::MIN, i32::MIN))),
        i64::MAX
    );
    let positive_extreme = point_distance_squared(output, Point::from((i32::MAX, i32::MAX)));
    assert!(positive_extreme > 0);
    assert!(positive_extreme < i64::MAX);
}

#[test]
fn moves_a_window_from_a_removed_output_onto_a_survivor() {
    let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
    let window = Rectangle::new((2200, 120).into(), (800, 600).into());

    assert_eq!(
        migrate_window_geometry(
            window,
            &[(OutputId(1), left), (OutputId(2), right)],
            &[(OutputId(1), left)],
        ),
        Rectangle::new((280, 120).into(), (800, 600).into()),
    );
}

#[test]
fn extreme_window_coordinates_do_not_overflow_monitor_selection_or_migration() {
    let old = Rectangle::new((i32::MIN, i32::MIN).into(), (1920, 1080).into());
    let destination = Rectangle::new(
        (i32::MAX - 1919, i32::MAX - 1079).into(),
        (1920, 1080).into(),
    );
    let window = Rectangle::new((i32::MIN, i32::MIN).into(), (i32::MAX, i32::MAX).into());

    assert_eq!(
        choose_output_geometry(&[(OutputId(1), old)], window).map(|candidate| candidate.0),
        Some(OutputId(1))
    );
    assert_eq!(
        migrate_window_geometry(window, &[(OutputId(1), old)], &[(OutputId(1), destination)],).loc,
        destination.loc
    );
}
