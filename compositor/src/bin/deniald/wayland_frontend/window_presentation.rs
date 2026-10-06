//! Shell-owned maximize/fullscreen state and its reversible transitions.

use smithay::utils::{Logical, Rectangle};

/// The shell-owned presentation contract for one protocol window.
///
/// Normal windows have no entry. Fullscreen retains the state it overlays so
/// every exit path has one authoritative destination.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellWindowPresentation {
    Maximized {
        normal_geometry: Rectangle<i32, Logical>,
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
            | Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::Maximized { normal_geometry },
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
            Self::Maximized { .. } => None,
            Self::Fullscreen {
                return_geometry,
                underlay: ShellFullscreenUnderlay::Normal,
            } => Some(ShellFullscreenExit::Normal {
                geometry: return_geometry,
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
            | Self::Fullscreen {
                underlay: ShellFullscreenUnderlay::Maximized { normal_geometry },
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
            Self::Maximized { normal_geometry } => *normal_geometry = map(*normal_geometry),
            Self::Fullscreen {
                return_geometry,
                underlay,
            } => {
                *return_geometry = map(*return_geometry);
                match underlay {
                    ShellFullscreenUnderlay::Normal => {}
                    ShellFullscreenUnderlay::Maximized { normal_geometry }
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
