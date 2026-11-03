//! Shell edge swipes that start over client windows.
//!
//! Flutter publishes edge regions with its input layout. A touch that starts
//! in one over a client goes to that client as usual. Once it travels inward,
//! even on a thumb's diagonal, the compositor cancels the client's touch and
//! hands the contact to Flutter from where it went down, as Android's system
//! gestures pilfer pointers from the window below.

use smithay::utils::{Logical, Point};

use super::super::super::wire::{EdgeSwipeRegion, InputEdge};

/// Inward travel, in logical pixels, at which the shell claims the contact.
const CLAIM_DISTANCE: f64 = 12.0;
/// Travel along the edge or outward, in logical pixels, after which the
/// contact stays with the client for good.
const RELEASE_DISTANCE: f64 = 16.0;
/// Travel along the edge allowed per unit of inward travel: a swipe leaning
/// up to about 56 degrees away from straight inward still counts.
const ALONG_PER_INWARD: f64 = 1.5;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(in super::super) struct EdgeSwipeCandidate {
    pub edge: InputEdge,
    /// Where the contact went down, in compositor coordinates.
    pub origin: Point<f64, Logical>,
    pub origin_time_usec: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in super::super) enum EdgeSwipeDecision {
    Pending,
    Claim,
    Release,
}

impl EdgeSwipeCandidate {
    /// A candidate for a contact that went down at `position`, if its scene
    /// position lies in one of the published regions.
    pub fn at(
        regions: &[EdgeSwipeRegion],
        scene_position: Point<f64, Logical>,
        position: Point<f64, Logical>,
        time_usec: u64,
    ) -> Option<Self> {
        regions
            .iter()
            .find(|region| region.rect.contains(scene_position.x, scene_position.y))
            .map(|region| Self {
                edge: region.edge,
                origin: position,
                origin_time_usec: time_usec,
            })
    }

    pub fn decide(&self, position: Point<f64, Logical>) -> EdgeSwipeDecision {
        let delta = position - self.origin;
        let (inward, along) = match self.edge {
            InputEdge::Left => (delta.x, delta.y.abs()),
            InputEdge::Right => (-delta.x, delta.y.abs()),
            InputEdge::Top => (delta.y, delta.x.abs()),
        };
        if inward >= CLAIM_DISTANCE && along <= inward * ALONG_PER_INWARD {
            EdgeSwipeDecision::Claim
        } else if -inward >= RELEASE_DISTANCE
            || (along >= RELEASE_DISTANCE && along > inward.max(0.0) * ALONG_PER_INWARD)
        {
            EdgeSwipeDecision::Release
        } else {
            EdgeSwipeDecision::Pending
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::super::super::wire::InputRect;
    use super::*;

    fn regions() -> Vec<EdgeSwipeRegion> {
        vec![
            EdgeSwipeRegion {
                rect: InputRect {
                    x: 0.0,
                    y: 48.0,
                    width: 24.0,
                    height: 800.0,
                },
                edge: InputEdge::Left,
            },
            EdgeSwipeRegion {
                rect: InputRect {
                    x: 376.0,
                    y: 48.0,
                    width: 24.0,
                    height: 800.0,
                },
                edge: InputEdge::Right,
            },
        ]
    }

    fn candidate(x: f64, y: f64) -> Option<EdgeSwipeCandidate> {
        // The scene is offset from compositor space, as on a second output.
        let origin = Point::from((1000.0, 0.0));
        EdgeSwipeCandidate::at(
            &regions(),
            Point::from((x, y)),
            origin + Point::from((x, y)),
            7,
        )
    }

    fn moved(candidate: EdgeSwipeCandidate, dx: f64, dy: f64) -> EdgeSwipeDecision {
        candidate.decide(candidate.origin + Point::from((dx, dy)))
    }

    #[test]
    fn only_touches_inside_a_region_are_candidates() {
        assert!(candidate(30.0, 400.0).is_none());
        assert!(candidate(10.0, 20.0).is_none());
        let left = candidate(10.0, 400.0).expect("left edge candidate");
        assert_eq!(left.edge, InputEdge::Left);
        assert_eq!(left.origin, Point::from((1010.0, 400.0)));
        assert_eq!(left.origin_time_usec, 7);
        assert_eq!(
            candidate(390.0, 400.0).expect("right edge candidate").edge,
            InputEdge::Right
        );
    }

    #[test]
    fn inward_travel_claims_the_contact() {
        let left = candidate(4.0, 400.0).unwrap();
        assert_eq!(moved(left, 6.0, 2.0), EdgeSwipeDecision::Pending);
        assert_eq!(moved(left, 12.0, 4.0), EdgeSwipeDecision::Claim);
        let right = candidate(396.0, 400.0).unwrap();
        assert_eq!(moved(right, 12.0, 0.0), EdgeSwipeDecision::Pending);
        assert_eq!(moved(right, -12.0, -3.0), EdgeSwipeDecision::Claim);
    }

    #[test]
    fn scrolling_along_the_edge_or_outward_releases_the_contact() {
        let left = candidate(20.0, 400.0).unwrap();
        assert_eq!(moved(left, 3.0, 16.0), EdgeSwipeDecision::Release);
        assert_eq!(moved(left, 3.0, -16.0), EdgeSwipeDecision::Release);
        assert_eq!(moved(left, -16.0, 0.0), EdgeSwipeDecision::Release);
        // A diagonal leaning mostly along the edge is a scroll, not a swipe.
        assert_eq!(moved(left, 10.0, 16.0), EdgeSwipeDecision::Release);
        assert_eq!(moved(left, 12.0, 19.0), EdgeSwipeDecision::Release);
    }

    #[test]
    fn a_thumb_diagonal_still_claims_the_contact() {
        let left = candidate(4.0, 400.0).unwrap();
        assert_eq!(moved(left, 11.0, 15.0), EdgeSwipeDecision::Pending);
        assert_eq!(moved(left, 12.0, 13.0), EdgeSwipeDecision::Claim);
        assert_eq!(moved(left, 14.0, -21.0), EdgeSwipeDecision::Claim);
        let right = candidate(396.0, 400.0).unwrap();
        assert_eq!(moved(right, -16.0, 20.0), EdgeSwipeDecision::Claim);
    }

    #[test]
    fn a_pull_down_from_the_top_edge_claims_the_contact() {
        let top = EdgeSwipeCandidate {
            edge: InputEdge::Top,
            origin: Point::from((200.0, 10.0)),
            origin_time_usec: 7,
        };
        assert_eq!(moved(top, 2.0, 6.0), EdgeSwipeDecision::Pending);
        assert_eq!(moved(top, 4.0, 12.0), EdgeSwipeDecision::Claim);
        assert_eq!(moved(top, 16.0, 3.0), EdgeSwipeDecision::Release);
        assert_eq!(moved(top, 0.0, -16.0), EdgeSwipeDecision::Release);
    }
}
