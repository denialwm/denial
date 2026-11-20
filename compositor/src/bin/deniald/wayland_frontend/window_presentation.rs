//! Shell-owned maximize/fullscreen state and its reversible transitions.

use smithay::utils::{Logical, Point, Rectangle, Size};

/// Part of an output's work area: each edge as a share of it, in millionths
/// so the presentation record stays `Eq`.
///
/// A share is a rule, not a rectangle: it is resolved again whenever the
/// work area changes, so a window on the left half stays the left half when
/// a bar appears.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct AreaShare {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
}

impl AreaShare {
    const UNIT: u32 = 1_000_000;

    /// `x`, `y`, `width` and `height` are shares within 0..1.
    pub(super) fn from_fractions(x: f64, y: f64, width: f64, height: f64) -> Self {
        let unit = |value: f64| (value.clamp(0.0, 1.0) * f64::from(Self::UNIT)).round() as u32;
        let left = unit(x);
        let top = unit(y);
        Self {
            left,
            top,
            right: unit(x + width).max(left),
            bottom: unit(y + height).max(top),
        }
    }

    /// The whole work area, which is maximize.
    pub(super) const fn is_whole(self) -> bool {
        self.left == 0 && self.top == 0 && self.right == Self::UNIT && self.bottom == Self::UNIT
    }

    /// This share of `area`. Edges are resolved, not sizes, so neighbouring
    /// shares meet without a gap or an overlap.
    pub(super) fn of(self, area: Rectangle<i32, Logical>) -> Rectangle<i32, Logical> {
        let edge = |origin: i32, extent: i32, share: u32| {
            let offset = (i64::from(extent) * i64::from(share) + i64::from(Self::UNIT / 2))
                / i64::from(Self::UNIT);
            origin.saturating_add(offset as i32)
        };
        let left = edge(area.loc.x, area.size.w, self.left);
        let top = edge(area.loc.y, area.size.h, self.top);
        let right = edge(area.loc.x, area.size.w, self.right);
        let bottom = edge(area.loc.y, area.size.h, self.bottom);
        Rectangle::new(
            Point::from((left, top)),
            Size::from(((right - left).max(1), (bottom - top).max(1))),
        )
    }
}

/// The shell-owned presentation contract for one protocol window.
///
/// Normal windows have no entry. Fullscreen retains the state it overlays so
/// every exit path has one authoritative destination.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellWindowPresentation {
    Maximized {
        normal_geometry: Rectangle<i32, Logical>,
    },
    /// Part of the work area, as edge snapping places a window. The client is
    /// not told it is maximized.
    Area {
        normal_geometry: Rectangle<i32, Logical>,
        share: AreaShare,
    },
    Fullscreen {
        return_geometry: Rectangle<i32, Logical>,
        underlay: ShellFullscreenUnderlay,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellFullscreenUnderlay {
    Normal,
    Maximized {
        normal_geometry: Rectangle<i32, Logical>,
    },
    LayoutMaximized {
        normal_geometry: Rectangle<i32, Logical>,
    },
    Area {
        normal_geometry: Rectangle<i32, Logical>,
        share: AreaShare,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellFixedMaximizeTransition {
    RestoreNormal {
        geometry: Rectangle<i32, Logical>,
    },
    SelectMaximized {
        normal_geometry: Rectangle<i32, Logical>,
        existing_geometry: Option<Rectangle<i32, Logical>>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellFullscreenExit {
    Normal {
        geometry: Rectangle<i32, Logical>,
    },
    Maximized {
        normal_geometry: Rectangle<i32, Logical>,
        geometry: Rectangle<i32, Logical>,
        layout_owned: bool,
    },
    Area {
        normal_geometry: Rectangle<i32, Logical>,
        geometry: Rectangle<i32, Logical>,
        share: AreaShare,
    },
}

impl ShellWindowPresentation {
    pub(super) fn fullscreen(
        return_geometry: Rectangle<i32, Logical>,
        previous: Option<Self>,
        layout_normal_geometry: Option<Rectangle<i32, Logical>>,
    ) -> Self {
        let underlay = match (previous, layout_normal_geometry) {
            (Some(Self::Maximized { normal_geometry }), _) => {
                ShellFullscreenUnderlay::Maximized { normal_geometry }
            }
            (
                Some(Self::Area {
                    normal_geometry,
                    share,
                }),
                _,
            ) => ShellFullscreenUnderlay::Area {
                normal_geometry,
                share,
            },
            (_, Some(normal_geometry)) => {
                ShellFullscreenUnderlay::LayoutMaximized { normal_geometry }
            }
            _ => ShellFullscreenUnderlay::Normal,
        };
        Self::Fullscreen {
            return_geometry,
            underlay,
        }
    }

    pub(super) const fn is_fullscreen(self) -> bool {
        matches!(self, Self::Fullscreen { .. })
    }

    /// The share of the work area this window keeps, if it keeps one.
    pub(super) const fn area_share(self) -> Option<AreaShare> {
        match self {
            Self::Area { share, .. } => Some(share),
            _ => None,
        }
    }

    pub(super) const fn has_maximized_underlay(self) -> bool {
        matches!(
            self,
            Self::Maximized { .. }
                | Self::Fullscreen {
                    underlay: ShellFullscreenUnderlay::Maximized { .. }
                        | ShellFullscreenUnderlay::LayoutMaximized { .. },
                    ..
                }
        )
    }

    pub(super) const fn normal_geometry(self) -> Rectangle<i32, Logical> {
        match self {
            Self::Maximized { normal_geometry }
            | Self::Area {
                normal_geometry, ..
            }
            | Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::Maximized { normal_geometry },
                ..
            }
            | Self::Fullscreen {
                underlay:
                    ShellFullscreenUnderlay::Area {
                        normal_geometry, ..
                    },
                ..
            }
            | Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::LayoutMaximized { normal_geometry },
                ..
            } => normal_geometry,
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Normal,
            } => return_geometry,
        }
    }

    pub(super) const fn toggle_fixed_maximize(self) -> ShellFixedMaximizeTransition {
        match self {
            Self::Maximized { normal_geometry } => ShellFixedMaximizeTransition::RestoreNormal {
                geometry: normal_geometry,
            },
            // Maximizing a snapped window keeps the place it had before it
            // was snapped as the one to restore.
            Self::Area {
                normal_geometry, ..
            }
            | Self::Fullscreen {
                underlay:
                    ShellFullscreenUnderlay::Area {
                        normal_geometry, ..
                    },
                ..
            } => ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry,
                existing_geometry: None,
            },
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Maximized { normal_geometry },
            } => ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry,
                existing_geometry: Some(return_geometry),
            },
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Normal,
            } => ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry: return_geometry,
                existing_geometry: None,
            },
            Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::LayoutMaximized { normal_geometry },
                ..
            } => ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry,
                existing_geometry: None,
            },
        }
    }

    pub(super) const fn exit_fullscreen(self) -> Option<ShellFullscreenExit> {
        match self {
            Self::Maximized { .. } | Self::Area { .. } => None,
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Normal,
            } => Some(ShellFullscreenExit::Normal {
                geometry: return_geometry,
            }),
            Self::Fullscreen {
                return_geometry,
                underlay:
                    ShellFullscreenUnderlay::Area {
                        normal_geometry,
                        share,
                    },
            } => Some(ShellFullscreenExit::Area {
                normal_geometry,
                geometry: return_geometry,
                share,
            }),
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Maximized { normal_geometry },
            } => Some(ShellFullscreenExit::Maximized {
                normal_geometry,
                geometry: return_geometry,
                layout_owned: false,
            }),
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::LayoutMaximized { normal_geometry },
            } => Some(ShellFullscreenExit::Maximized {
                normal_geometry,
                geometry: return_geometry,
                layout_owned: true,
            }),
        }
    }

    pub(super) fn update_normal_geometry(&mut self, geometry: Rectangle<i32, Logical>) {
        match self {
            Self::Maximized { normal_geometry }
            | Self::Area {
                normal_geometry, ..
            }
            | Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::Maximized { normal_geometry },
                ..
            }
            | Self::Fullscreen {
                underlay:
                    ShellFullscreenUnderlay::Area {
                        normal_geometry, ..
                    },
                ..
            }
            | Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::LayoutMaximized { normal_geometry },
                ..
            } => *normal_geometry = geometry,
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Normal,
            } => *return_geometry = geometry,
        }
    }

    pub(super) fn map_geometries(
        &mut self,
        mut map: impl FnMut(Rectangle<i32, Logical>) -> Rectangle<i32, Logical>,
    ) {
        match self {
            Self::Maximized { normal_geometry }
            | Self::Area {
                normal_geometry, ..
            } => *normal_geometry = map(*normal_geometry),
            Self::Fullscreen {
                return_geometry,
                underlay,
            } => {
                *return_geometry = map(*return_geometry);
                match underlay {
                    ShellFullscreenUnderlay::Normal => {}
                    ShellFullscreenUnderlay::Maximized { normal_geometry }
                    | ShellFullscreenUnderlay::Area {
                        normal_geometry, ..
                    }
                    | ShellFullscreenUnderlay::LayoutMaximized { normal_geometry } => {
                        *normal_geometry = map(*normal_geometry);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geometry(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
        Rectangle::new((x, y).into(), (width, height).into())
    }

    #[test]
    fn maximize_fullscreen_maximize_restore_is_one_reversible_chain() {
        let normal = geometry(20, 40, 900, 700);
        let maximized = geometry(8, 32, 1904, 1040);
        let fullscreen = ShellWindowPresentation::fullscreen(
            maximized,
            Some(ShellWindowPresentation::Maximized {
                normal_geometry: normal,
            }),
            None,
        );

        assert_eq!(
            fullscreen.toggle_fixed_maximize(),
            ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry: normal,
                existing_geometry: Some(maximized),
            }
        );
        assert_eq!(
            ShellWindowPresentation::Maximized {
                normal_geometry: normal,
            }
            .toggle_fixed_maximize(),
            ShellFixedMaximizeTransition::RestoreNormal { geometry: normal }
        );
    }

    #[test]
    fn neighbouring_shares_meet_without_a_gap() {
        let work_area = geometry(8, 40, 1905, 1033);
        let left = AreaShare::from_fractions(0.0, 0.0, 0.5, 1.0).of(work_area);
        let right = AreaShare::from_fractions(0.5, 0.0, 0.5, 1.0).of(work_area);

        assert_eq!(left.loc.x, work_area.loc.x);
        assert_eq!(left.loc.x + left.size.w, right.loc.x);
        assert_eq!(
            right.loc.x + right.size.w,
            work_area.loc.x + work_area.size.w
        );
        assert_eq!(left.size.h, work_area.size.h);
        assert!(AreaShare::from_fractions(0.0, 0.0, 1.0, 1.0).is_whole());
        assert!(!AreaShare::from_fractions(0.0, 0.0, 0.5, 1.0).is_whole());
        assert_eq!(
            AreaShare::from_fractions(0.0, 0.0, 1.0, 1.0).of(work_area),
            work_area
        );
    }

    #[test]
    fn a_snapped_window_keeps_its_free_place_through_fullscreen_and_maximize() {
        let normal = geometry(20, 40, 900, 700);
        let snapped = geometry(8, 32, 952, 1040);
        let share = AreaShare::from_fractions(0.0, 0.0, 0.5, 1.0);
        let area = ShellWindowPresentation::Area {
            normal_geometry: normal,
            share,
        };

        assert_eq!(area.normal_geometry(), normal);
        assert!(!area.has_maximized_underlay());
        assert_eq!(
            area.toggle_fixed_maximize(),
            ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry: normal,
                existing_geometry: None,
            }
        );
        let fullscreen = ShellWindowPresentation::fullscreen(snapped, Some(area), None);
        assert!(!fullscreen.has_maximized_underlay());
        assert_eq!(
            fullscreen.exit_fullscreen(),
            Some(ShellFullscreenExit::Area {
                normal_geometry: normal,
                geometry: snapped,
                share,
            })
        );
    }

    #[test]
    fn fullscreen_retains_scrolling_maximize_as_a_layout_owned_underlay() {
        let normal = geometry(50, 60, 800, 600);
        let maximized = geometry(8, 32, 1904, 1040);
        let fullscreen = ShellWindowPresentation::fullscreen(maximized, None, Some(normal));

        assert_eq!(
            fullscreen.exit_fullscreen(),
            Some(ShellFullscreenExit::Maximized {
                normal_geometry: normal,
                geometry: maximized,
                layout_owned: true,
            })
        );
    }
}
