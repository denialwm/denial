//! Cursor publication and frontend identity.

use super::*;

impl WaylandFrontend {
    #[cfg(feature = "flutter")]
    pub(super) fn update_cursor_image(&mut self, image: CursorImageStatus) {
        let shape = if self.clipboard_drag_active {
            "default"
        } else {
            software_cursor_shape(&image)
        };
        self.cursor_status = image;
        if self.pointer_cursor_visible
            && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_))
        {
            self.queue_cursor_shape(shape);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn update_tablet_cursor_image(&mut self, image: CursorImageStatus) {
        let shape = software_cursor_shape(&image);
        self.cursor_status = image;
        if self.pointer_cursor_visible {
            self.queue_cursor_shape(shape);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn queue_cursor_shape(&mut self, shape: &'static str) {
        if self.pending_cursor_shape == Some(shape)
            || (self.pending_cursor_shape.is_none() && self.published_cursor_shape == Some(shape))
        {
            return;
        }
        self.pending_cursor_shape = Some(shape);
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn request_flutter_cursor_shape(&mut self, shape: &'static str) {
        if !self.pointer_cursor_visible {
            return;
        }
        if self.clipboard_drag_active {
            self.queue_cursor_shape("default");
            return;
        }
        if let Some(shape) = accepted_flutter_cursor_shape(self.routed_pointer_target, shape) {
            self.queue_cursor_shape(shape);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_clipboard_drag_active(&mut self, active: bool) {
        if self.clipboard_drag_active == active {
            if active && self.pointer_cursor_visible {
                self.queue_cursor_shape("default");
            }
            return;
        }
        self.clipboard_drag_active = active;
        self.published_cursor_shape = None;
        self.pending_cursor_shape = if !self.pointer_cursor_visible {
            Some("none")
        } else if active {
            Some("default")
        } else {
            match self.routed_pointer_target {
                RoutedPointerTarget::Flutter => None,
                RoutedPointerTarget::Client(_) => Some(software_cursor_shape(&self.cursor_status)),
            }
        };
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_routed_pointer_target(&mut self, target: RoutedPointerTarget) {
        if self.routed_pointer_target == target {
            return;
        }
        self.routed_pointer_target = target;
        self.published_cursor_shape = None;
        if !self.pointer_cursor_visible {
            self.pending_cursor_shape = Some("none");
            self.pending_cursor_position = None;
            return;
        }
        if self.clipboard_drag_active {
            self.pending_cursor_shape = Some("default");
            return;
        }
        match target {
            // Dart's MouseRegion owns cursor selection again.  Discard a
            // client update which has not crossed the bridge yet so it cannot
            // overwrite the newer Flutter shape after the route switch.
            RoutedPointerTarget::Flutter => self.pending_cursor_shape = None,
            // Do not retain the previous client (or Flutter) shape while the
            // newly entered client is waiting to call wl_pointer.set_cursor.
            RoutedPointerTarget::Client(_) => self.pending_cursor_shape = Some("default"),
        }
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_cursor_shape_update(&mut self) -> Option<&'static str> {
        let shape = self.pending_cursor_shape.take()?;
        self.published_cursor_shape = Some(shape);
        Some(shape)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn queue_cursor_position(&mut self) {
        self.pending_cursor_position = cursor_position_for_modality(
            self.pointer_cursor_visible,
            self.flutter_scene_pointer_position(),
        );
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_pointer_cursor_visible(&mut self, visible: bool) {
        if self.pointer_cursor_visible == visible {
            return;
        }
        self.pointer_cursor_visible = visible;
        self.published_cursor_shape = None;
        if !visible {
            self.pending_cursor_shape = Some("none");
            self.pending_cursor_position = None;
            return;
        }

        let active_shape = if self.clipboard_drag_active {
            "default"
        } else {
            match self.routed_pointer_target {
                RoutedPointerTarget::Flutter => "default",
                RoutedPointerTarget::Client(_) => software_cursor_shape(&self.cursor_status),
            }
        };
        self.pending_cursor_shape = Some(cursor_shape_for_modality(visible, active_shape));
        self.pending_cursor_position = cursor_position_for_modality(
            visible && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_)),
            self.flutter_scene_pointer_position(),
        );
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_cursor_position_update(&mut self) -> Option<(f64, f64)> {
        self.pending_cursor_position.take()
    }

    pub fn socket_name(&self) -> &OsStr {
        &self.socket_name
    }

    pub fn xdisplay_name(&self) -> OsString {
        OsString::from(format!(":{}", self.xdisplay))
    }
}
