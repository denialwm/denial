//! Window identity, placement, membership, and local-shell state.

use super::*;

impl WaylandFrontend {
    pub(crate) fn window_root_surface(&self, window: &Window) -> Option<WlSurface> {
        window.wl_surface().map(|surface| surface.into_owned())
    }

    pub(super) fn keyboard_focus_for_window(&self, window: &Window) -> Option<KeyboardFocusTarget> {
        if let Some(surface) = window.x11_surface() {
            // X11Surface implements the ICCCM focus handshake in addition to
            // forwarding wl_keyboard events to its associated wl_surface.
            surface.wl_surface()?;
            return Some(KeyboardFocusTarget::X11(surface.clone()));
        }
        self.window_root_surface(window)
            .map(KeyboardFocusTarget::Wayland)
    }

    /// Mints a one-shot token for a user launch initiated by Denial's shell.
    pub(crate) fn create_launch_activation_token(&mut self) -> String {
        self.xdg_activation_state
            .retain_tokens(|_, data| data.timestamp.elapsed() <= XDG_ACTIVATION_TOKEN_LIFETIME);
        let (token, _) = self.xdg_activation_state.create_external_token(None);
        token.to_string()
    }

    /// Raises a desktop window in both compositor and X11 stacking state.
    ///
    /// `Space` owns Denial's visual and Wayland hit-test order, but rootless
    /// Xwayland keeps an independent X stack. Leaving the latter unchanged can
    /// make an X client below the visible window continue receiving pointer
    /// events in their overlap.
    pub(super) fn raise_window(&mut self, window: &Window, activate: bool) {
        self.space.raise_element(window, activate);
        let Some(surface) = window.x11_surface().cloned() else {
            return;
        };
        // Override-redirect popups are deliberately absent from XWM's EWMH
        // client stack and are already placed by Xwayland at map time.
        if surface.is_override_redirect() {
            return;
        }
        let Some(xwm) = self.xwm.as_mut() else {
            return;
        };
        if let Err(error) = xwm.raise_window(&surface) {
            warn!(
                %error,
                window = surface.window_id(),
                "could not synchronize raised X11 window"
            );
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_for_id(&self, window_id: u64) -> Option<Window> {
        self.space
            .elements()
            .find(|window| {
                self.window_root_surface(window)
                    .as_ref()
                    .and_then(|surface| self.surface_id(surface))
                    == Some(window_id)
            })
            .cloned()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_shell_fullscreen_locked(&self, window: &Window) -> bool {
        self.window_root_surface(window)
            .is_some_and(|root_surface| self.shell_fullscreen_locks.contains(&root_surface.id()))
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_geometry_locked(&self, window: &Window) -> bool {
        let Some(root_surface) = self.window_root_surface(window) else {
            return false;
        };
        if self.shell_fullscreen_locks.contains(&root_surface.id())
            || self
                .exact_window_geometries
                .contains_key(&root_surface.id())
        {
            return true;
        }
        let Some(window_id) = self.surface_id(&root_surface) else {
            return false;
        };
        self.input_layout.as_ref().is_some_and(|layout| {
            layout
                .windows
                .iter()
                .any(|region| region.window_id == window_id && region.geometry_locked())
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn exact_window_geometry(&self, window: &Window) -> Option<Rectangle<i32, Logical>> {
        self.window_root_surface(window)
            .and_then(|surface| self.exact_window_geometries.get(&surface.id()).copied())
    }

    #[cfg(feature = "flutter")]
    pub(super) fn toggle_shell_fullscreen_lock(
        &mut self,
        window: &Window,
        client_fullscreen: bool,
    ) -> Option<ShellFullscreenTransition> {
        let root_surface = self.window_root_surface(window)?;
        let object_id = root_surface.id();
        let transition = shell_fullscreen_transition(
            client_fullscreen,
            self.shell_fullscreen_locks.contains(&object_id),
            self.window_geometry_locked(window),
        );
        match transition {
            ShellFullscreenTransition::ExitShell | ShellFullscreenTransition::ExitClient => {
                self.shell_fullscreen_locks.remove(&object_id);
                return Some(transition);
            }
            ShellFullscreenTransition::Blocked => return Some(transition),
            ShellFullscreenTransition::EnterShell => {}
        }
        let preserve_maximized = self.window_placement_state(window).maximized;
        let restore = self
            .shell_maximize_restore_geometries
            .get(&object_id)
            .copied()
            .or_else(|| self.restore_window_geometries.get(&object_id).copied())
            .unwrap_or_else(|| self.window_geometry_target(window));
        if preserve_maximized {
            self.shell_maximize_restore_geometries
                .entry(object_id.clone())
                .or_insert(restore);
        }
        self.shell_fullscreen_restore_geometries
            .insert(object_id.clone(), restore);
        self.shell_fullscreen_locks.insert(object_id);
        Some(transition)
    }

    pub(super) fn window_for_root_surface(&self, surface: &WlSurface) -> Option<Window> {
        self.space
            .elements()
            .find(|window| self.window_root_surface(window).as_ref() == Some(surface))
            .cloned()
    }

    pub(super) fn window_identity(&self, window: &Window) -> Option<WindowIdentity> {
        if let Some(toplevel) = window.toplevel() {
            return with_states(toplevel.wl_surface(), |states| {
                let attributes = states
                    .data_map
                    .get::<XdgToplevelSurfaceData>()?
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                WindowIdentity::wayland(attributes.app_id.as_deref()?)
            });
        }
        let x11 = window.x11_surface()?;
        (!x11.is_override_redirect())
            .then(|| x11.class())
            .and_then(|class| WindowIdentity::x11(&class))
    }

    pub(super) fn window_has_same_identity_sibling(
        &self,
        window: &Window,
        identity: &WindowIdentity,
    ) -> bool {
        self.space.elements().any(|candidate| {
            candidate != window && self.window_identity(candidate).as_ref() == Some(identity)
        })
    }

    pub(super) fn mark_client_geometry_state_request(&mut self, surface: &WlSurface) {
        self.client_geometry_state_requests.insert(surface.id());
    }

    pub(super) fn window_has_transient_parent(&self, window: &Window) -> bool {
        if let Some(toplevel) = window.toplevel() {
            return with_states(toplevel.wl_surface(), |states| {
                states
                    .data_map
                    .get::<XdgToplevelSurfaceData>()
                    .and_then(|attributes| {
                        attributes
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .parent
                            .clone()
                    })
                    .is_some()
            });
        }
        window
            .x11_surface()
            .is_some_and(|surface| surface.is_transient_for().is_some())
    }

    pub(super) fn fallback_output_geometry(&self) -> Option<Rectangle<i32, Logical>> {
        let pointer = Point::<i32, Logical>::from((
            self.pointer_location.x.floor() as i32,
            self.pointer_location.y.floor() as i32,
        ));
        self.outputs
            .iter()
            .find(|entry| entry.logical_geometry.contains(pointer))
            .or_else(|| self.outputs.first())
            .map(|entry| entry.logical_geometry)
    }

    pub(super) fn restored_placement_for_identity(
        &self,
        identity: &WindowIdentity,
        fallback_output: Rectangle<i32, Logical>,
    ) -> Option<RestoredWindowPlacement> {
        self.window_placements.restored_placement(
            identity,
            self.outputs
                .iter()
                .map(|entry| (entry.connector.clone(), entry.logical_geometry)),
            fallback_output,
        )
    }

    pub(super) fn window_placement_state(&self, window: &Window) -> WindowPlacementState {
        let state = if let Some(toplevel) = window.toplevel() {
            WindowPlacementState {
                maximized: toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
                fullscreen: toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
            }
        } else if let Some(x11) = window.x11_surface() {
            WindowPlacementState {
                maximized: x11.is_maximized(),
                fullscreen: x11.is_fullscreen(),
            }
        } else {
            WindowPlacementState::default()
        };
        #[cfg(feature = "flutter")]
        let state = self
            .window_root_surface(window)
            .map_or(state, |root| WindowPlacementState {
                maximized: state.maximized
                    || self
                        .shell_maximize_restore_geometries
                        .contains_key(&root.id()),
                fullscreen: state.fullscreen || self.shell_fullscreen_locks.contains(&root.id()),
            });
        state
    }

    #[cfg(feature = "flutter")]
    pub(super) fn apply_restored_window_state(
        &mut self,
        window: &Window,
        normal_geometry: Rectangle<i32, Logical>,
        state: WindowPlacementState,
    ) -> Rectangle<i32, Logical> {
        if !state.maximized && !state.fullscreen {
            return normal_geometry;
        }
        let Some(root) = self.window_root_surface(window) else {
            return normal_geometry;
        };
        let Some((output, output_geometry)) = self
            .output_for_geometry(normal_geometry)
            .map(|entry| (entry.output.clone(), entry.logical_geometry))
        else {
            return normal_geometry;
        };
        let object_id = root.id();
        let server_frame = shell_draws_server_frame(window);
        let mut target = normal_geometry;
        if state.maximized {
            let frame = self.maximize_work_area(Some(&output), output_geometry);
            target = shell_content_geometry(frame, server_frame);
            self.shell_maximize_restore_geometries
                .insert(object_id.clone(), normal_geometry);
        }
        if state.fullscreen {
            target = shell_content_geometry(output_geometry, server_frame);
            self.shell_fullscreen_restore_geometries
                .insert(object_id.clone(), normal_geometry);
            self.shell_fullscreen_locks.insert(object_id);
        }
        target
    }

    pub(super) fn restore_xdg_window_placement(
        &mut self,
        window: &Window,
    ) -> Option<(RestoredWindowPlacement, Rectangle<i32, Logical>)> {
        let toplevel = window.toplevel()?;
        let root = toplevel.wl_surface();
        let object_id = root.id();
        if self.restored_window_positions.contains(&object_id) {
            return None;
        }
        let (identity, has_parent, initial_configure_sent) = with_states(root, |states| {
            let Some(attributes) = states.data_map.get::<XdgToplevelSurfaceData>() else {
                return (None, false, false);
            };
            let attributes = attributes
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            (
                attributes
                    .app_id
                    .as_deref()
                    .and_then(WindowIdentity::wayland),
                attributes.parent.is_some(),
                attributes.initial_configure_sent,
            )
        });
        let identity = identity?;
        let fallback_output = self.fallback_output_geometry()?;
        let mut restored = self.restored_placement_for_identity(&identity, fallback_output)?;
        let client_state = WindowPlacementState {
            maximized: toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
            fullscreen: toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
        };
        let policy = initial_xdg_placement_policy(
            has_parent,
            self.window_has_same_identity_sibling(window, &identity),
            initial_configure_sent,
            self.client_geometry_state_requests.contains(&object_id),
            client_state,
            restored.state,
        );
        if policy == InitialXdgPlacementPolicy::SkipSaved {
            return None;
        }

        let (output_id, output_geometry) = self
            .output_for_geometry(restored.geometry)
            .map(|output| (output.id, output.logical_geometry))
            .or_else(|| {
                self.outputs
                    .first()
                    .map(|output| (output.id, output.logical_geometry))
            })?;
        restored.geometry = clamp_window_geometry(restored.geometry, output_geometry);

        if policy == InitialXdgPlacementPolicy::ClientSized {
            // A zero-sized initial XDG configure is an explicit instruction
            // for the client to choose its own dimensions. Keep only Denial's
            // output/location intent until the first committed client
            // geometry exists; injecting the saved application size here
            // stretches independent auxiliary toplevels to the main window.
            toplevel.with_pending_state(|pending| pending.size = None);
            self.space.relocate_element(window, restored.geometry.loc);
            self.update_window_output_membership(window);
            self.pending_client_sized_placements.insert(
                object_id.clone(),
                PendingClientSizedPlacement {
                    requested_location: restored.geometry.loc,
                    output_id,
                },
            );
            self.restored_window_positions.insert(object_id);
            info!(
                backend = ?identity.backend(),
                app_id = identity.app_id(),
                x = restored.geometry.loc.x,
                y = restored.geometry.loc.y,
                saved_width = restored.geometry.size.w,
                saved_height = restored.geometry.size.h,
                "restored saved window location; client chooses initial size"
            );
            return None;
        }

        let (minimum, maximum) = with_states(root, |states| {
            let mut cached = states.cached_state.get::<SurfaceCachedState>();
            let current = cached.current();
            (current.min_size, current.max_size)
        });
        restored.geometry.size = Size::from((
            constrain_dimension(restored.geometry.size.w, minimum.w, maximum.w),
            constrain_dimension(restored.geometry.size.h, minimum.h, maximum.h),
        ));
        restored.geometry = clamp_window_geometry(restored.geometry, output_geometry);
        #[cfg(feature = "flutter")]
        let target = self.apply_restored_window_state(window, restored.geometry, restored.state);
        #[cfg(not(feature = "flutter"))]
        let target = restored.geometry;
        toplevel.with_pending_state(|pending| pending.size = Some(target.size));
        self.set_window_geometry_target(window, target);
        self.restored_window_positions.insert(object_id);
        info!(
            backend = ?identity.backend(),
            app_id = identity.app_id(),
            x = target.loc.x,
            y = target.loc.y,
            width = target.size.w,
            height = target.size.h,
            maximized = restored.state.maximized,
            fullscreen = restored.state.fullscreen,
            "restored saved window placement"
        );
        Some((restored, target))
    }

    pub(super) fn defer_client_sized_window_placement(&mut self, window: &Window) -> bool {
        let Some(root) = self.window_root_surface(window) else {
            return false;
        };
        let geometry = self.window_geometry_target(window);
        let Some(output_id) = self
            .output_for_geometry(geometry)
            .map(|output| output.id)
            .or_else(|| self.outputs.first().map(|output| output.id))
        else {
            return false;
        };
        let object_id = root.id();
        self.configured_window_geometries.remove(&object_id);
        self.pending_client_sized_placements.insert(
            object_id,
            PendingClientSizedPlacement {
                requested_location: geometry.loc,
                output_id,
            },
        );
        true
    }

    pub(super) fn reconcile_client_sized_window_placement(
        &mut self,
        window: &Window,
    ) -> Option<Rectangle<i32, Logical>> {
        let root = self.window_root_surface(window)?;
        let object_id = root.id();
        let pending = self
            .pending_client_sized_placements
            .get(&object_id)
            .copied()?;
        let committed = window.geometry();
        if committed.size.w <= 0 || committed.size.h <= 0 {
            return None;
        }
        let output_geometry = self
            .outputs
            .iter()
            .find(|output| output.id == pending.output_id)
            .map(|output| output.logical_geometry)
            .or_else(|| self.fallback_output_geometry())?;
        let target = clamp_window_geometry(
            Rectangle::new(pending.requested_location, committed.size),
            output_geometry,
        );
        self.space.relocate_element(window, target.loc);
        self.update_window_output_membership(window);
        self.pending_client_sized_placements.remove(&object_id);
        info!(
            x = target.loc.x,
            y = target.loc.y,
            width = target.size.w,
            height = target.size.h,
            "placed client-sized Wayland window"
        );
        Some(target)
    }

    pub(super) fn remember_window_geometry(
        &mut self,
        window: &Window,
        geometry: Rectangle<i32, Logical>,
    ) {
        if self.window_has_transient_parent(window) {
            return;
        }
        let Some(identity) = self.window_identity(window) else {
            return;
        };
        let state = self.window_placement_state(window);
        let Some(output) = self.output_for_geometry(geometry) else {
            return;
        };
        let connector = output.connector.clone();
        let output_geometry = output.logical_geometry;
        if let Err(error) = self.window_placements.remember(
            identity.clone(),
            &connector,
            output_geometry,
            geometry,
            state,
        ) {
            warn!(
                %error,
                backend = ?identity.backend(),
                app_id = identity.app_id(),
                "could not persist window placement"
            );
        }
    }

    pub(super) fn remember_window_placement(&mut self, window: &Window) {
        let geometry = self
            .window_root_surface(window)
            .and_then(|root| {
                #[cfg(feature = "flutter")]
                if let Some(geometry) = self
                    .shell_maximize_restore_geometries
                    .get(&root.id())
                    .copied()
                {
                    return Some(geometry);
                }
                #[cfg(feature = "flutter")]
                if let Some(geometry) = self
                    .shell_fullscreen_restore_geometries
                    .get(&root.id())
                    .copied()
                {
                    return Some(geometry);
                }
                self.restore_window_geometries.get(&root.id()).copied()
            })
            .unwrap_or_else(|| self.window_geometry_target(window));
        self.remember_window_geometry(window, geometry);
    }

    pub(crate) fn window_geometry_target(&self, window: &Window) -> Rectangle<i32, Logical> {
        self.window_root_surface(window)
            .and_then(|surface| {
                self.exact_window_geometries
                    .get(&surface.id())
                    .or_else(|| self.configured_window_geometries.get(&surface.id()))
                    .copied()
            })
            .or_else(|| self.space.element_geometry(window))
            .unwrap_or_else(|| window.bbox())
    }

    pub(super) fn update_window_output_membership(&mut self, window: &Window) {
        let output_index = self.output_index_for_geometry(self.window_geometry_target(window));
        let output = output_index.map(|index| self.outputs[index].id);
        let output_scale = output_index
            .map(|index| {
                self.outputs[index]
                    .output
                    .current_scale()
                    .fractional_scale()
            })
            .unwrap_or(1.0);
        window.with_surfaces(|surface, states| {
            let preferred_scale = Self::client_preferred_scale(surface, output_scale);
            with_fractional_scale(states, |fractional_scale| {
                fractional_scale.set_preferred_scale(preferred_scale);
            });
        });
        #[cfg(feature = "flutter")]
        if let Some(root_surface) = self.window_root_surface(window) {
            if let Some(window_id) = self.surface_id(&root_surface) {
                self.input_root_ids.insert(root_surface.id(), window_id);
            } else {
                self.input_root_ids.remove(&root_surface.id());
            }
            self.output_window_membership
                .update(root_surface.id(), window.clone(), output);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn remove_window_output_membership(&mut self, surface: &WlSurface) {
        self.input_root_ids.remove(&surface.id());
        self.output_window_membership.remove(&surface.id());
    }

    pub(super) fn rebuild_window_output_membership(&mut self) {
        #[cfg(feature = "flutter")]
        {
            self.input_root_ids.clear();
            self.output_window_membership.clear();
        }
        let mut windows = std::mem::take(&mut self.window_membership_scratch);
        windows.clear();
        windows.extend(self.space.elements().cloned());
        for window in &windows {
            self.update_window_output_membership(window);
        }
        #[cfg(feature = "flutter")]
        self.update_cursor_output_membership();
        self.window_membership_scratch = windows;
    }

    pub(crate) fn set_window_geometry_target(
        &mut self,
        window: &Window,
        target: Rectangle<i32, Logical>,
    ) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        self.shell_vertical_restore_geometries
            .remove(&root_surface.id());
        if let Some(x11) = window.x11_surface()
            && !x11.is_override_redirect()
            && x11.last_configure() != target
            && let Err(error) = x11.configure(target)
        {
            warn!(%error, window = x11.window_id(), "could not configure X11 geometry");
        }
        // Space stores an element's *global geometry location*, not its
        // wl_surface render origin.  Window::geometry().loc is only the local
        // offset of the client geometry inside that surface (CSD shadows and
        // X11 frame extents commonly make it non-zero).  Applying that offset
        // here a second time makes the published geometry and native hitboxes
        // diverge, and feeds the offset back into every configure/commit cycle.
        self.space.relocate_element(window, target.loc);
        if window.geometry().size == target.size {
            // A move needs no client acknowledgement.  Reading the geometry
            // back from Space is already authoritative and avoids retaining a
            // stale target indefinitely when the client has no reason to
            // commit another buffer.
            self.configured_window_geometries.remove(&root_surface.id());
        } else {
            self.configured_window_geometries
                .insert(root_surface.id(), target);
        }
        self.update_window_output_membership(window);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_window_geometry_target_policy(
        &mut self,
        window: &Window,
        target: Rectangle<i32, Logical>,
        exact: bool,
    ) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        if exact {
            self.exact_window_geometries
                .insert(root_surface.id(), target);
        } else {
            self.exact_window_geometries.remove(&root_surface.id());
        }
        self.set_window_geometry_target(window, target);
    }

    pub(super) fn reconcile_committed_window_geometry(&mut self, window: &Window) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        let surface_id = root_surface.id();
        let exact = self.exact_window_geometries.get(&surface_id).copied();
        let target = exact.or_else(|| self.configured_window_geometries.get(&surface_id).copied());
        let Some(target) = target else {
            return;
        };
        let committed = window.geometry();
        // `target.loc` and Space's element location use the same global
        // geometry coordinate system.  `committed.loc` remains surface-local
        // and must affect rendering only (Space subtracts it internally).
        self.space.relocate_element(window, target.loc);
        if committed.size == target.size {
            self.configured_window_geometries.remove(&surface_id);
        } else if exact.is_some() {
            if let Some(toplevel) = window.toplevel() {
                toplevel.with_pending_state(|pending| {
                    pending.states.unset(xdg_toplevel::State::Fullscreen);
                    pending.states.unset(xdg_toplevel::State::Maximized);
                    pending.states.unset(xdg_toplevel::State::Resizing);
                    pending.fullscreen_output = None;
                    pending.size = Some(target.size);
                });
                toplevel.send_pending_configure();
            } else if let Some(x11) = window.x11_surface()
                && !x11.is_override_redirect()
                && x11.last_configure() != target
                && let Err(error) = x11.configure(target)
            {
                warn!(%error, window = x11.window_id(), "could not reassert exact X11 geometry");
            }
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_placement(
        &self,
        window: &Window,
        geometry: Rectangle<i32, Logical>,
        monitor_geometry: Rectangle<i32, Logical>,
        phase: WindowPlacementPhase,
        change: WindowPlacementChange,
    ) -> Option<WindowPlacement> {
        let root_surface = self.window_root_surface(window)?;
        let window_id = self.surface_id(&root_surface)?;
        let monitor_id = self
            .output_for_geometry(monitor_geometry)
            .and_then(|entry| i64::try_from(entry.id.0).ok())?;
        Some(WindowPlacement {
            window_id,
            monitor_id,
            // Workspaces are not split yet. Keep a real, stable ownership ID
            // rather than the protocol's invalid -1 sentinel.
            workspace_id: 1,
            phase,
            change,
            geometry: WindowGeometry {
                x: f64::from(geometry.loc.x) - self.atlas_origin.x,
                y: f64::from(geometry.loc.y) - self.atlas_origin.y,
                width: f64::from(geometry.size.w),
                height: f64::from(geometry.size.h),
            },
        })
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn replay_window_state_events(&self) -> Vec<PendingWindowEvent> {
        let mut events = Vec::new();
        for window in self.space.elements() {
            let Some(root_surface) = self.window_root_surface(window) else {
                continue;
            };
            let Some(window_id) = self.surface_id(&root_surface) else {
                continue;
            };
            let (fullscreen, client_maximized) = if let Some(toplevel) = window.toplevel() {
                (
                    toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
                    toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
                )
            } else if let Some(x11) = window.x11_surface() {
                (x11.is_fullscreen(), x11.is_maximized())
            } else {
                (false, false)
            };
            let shell_maximized = self
                .shell_maximize_restore_geometries
                .contains_key(&root_surface.id());
            let shell_fullscreen = self.shell_fullscreen_locks.contains(&root_surface.id());
            let maximized = client_maximized || shell_maximized;
            let fullscreen = fullscreen || shell_fullscreen;
            if fullscreen || maximized {
                if let Some(restore) = self
                    .shell_maximize_restore_geometries
                    .get(&root_surface.id())
                    .or_else(|| {
                        self.shell_fullscreen_restore_geometries
                            .get(&root_surface.id())
                    })
                    .or_else(|| self.restore_window_geometries.get(&root_surface.id()))
                    .copied()
                    && let Some(placement) = self.window_placement(
                        window,
                        restore,
                        self.window_geometry_target(window),
                        WindowPlacementPhase::End,
                        WindowPlacementChange::Resize,
                    )
                {
                    events.push(PendingWindowEvent::Placement(placement));
                }
                if maximized {
                    events.push(PendingWindowEvent::Action(
                        window_id,
                        WindowAction::Maximize,
                    ));
                }
                if fullscreen {
                    events.push(PendingWindowEvent::Action(
                        window_id,
                        WindowAction::ToggleFullscreen,
                    ));
                }
            }
            if self.minimized_windows.contains(&root_surface.id()) {
                events.push(PendingWindowEvent::Action(
                    window_id,
                    WindowAction::Minimize,
                ));
            }
        }

        let focused = self
            .seat
            .get_keyboard()
            .and_then(|keyboard| keyboard.current_focus());
        if let Some(window_id) = focused
            .as_ref()
            .and_then(|focus| focus.wl_surface())
            .and_then(|surface| self.owning_toplevel_surface(&surface))
            .filter(|surface| !self.minimized_windows.contains(&surface.id()))
            .as_ref()
            .and_then(|surface| self.surface_id(surface))
        {
            events.push(PendingWindowEvent::Activated(window_id));
        }
        events
    }

    pub(super) fn register_surface(&mut self, surface: &WlSurface) -> u64 {
        if let Some(surface_id) = self.surface_ids.get(&surface.id()).copied() {
            return surface_id;
        }

        let maximum = i64::MAX as u64;
        let mut surface_id = self.next_surface_id.clamp(1, maximum);
        let first_candidate = surface_id;
        while self.surfaces_by_id.contains_key(&surface_id) || {
            #[cfg(feature = "flutter")]
            {
                self.local_windows.contains(surface_id)
            }
            #[cfg(not(feature = "flutter"))]
            {
                false
            }
        } {
            surface_id = if surface_id == maximum {
                1
            } else {
                surface_id + 1
            };
            assert_ne!(
                surface_id, first_candidate,
                "exhausted positive Flutter texture identifiers"
            );
        }
        self.next_surface_id = if surface_id == maximum {
            1
        } else {
            surface_id + 1
        };
        self.surface_ids.insert(surface.id(), surface_id);
        self.surfaces_by_id.insert(surface_id, surface.clone());
        surface_id
    }

    #[cfg(feature = "flutter")]
    pub(super) fn create_local_flutter_window(
        &mut self,
        app_id: String,
        title: String,
        mut geometry: WindowGeometry,
    ) -> Result<u64, LocalWindowError> {
        // Dart speaks in atlas-relative logical coordinates, while native
        // window state follows Space and remains global across topology moves.
        geometry.x += self.atlas_origin.x;
        geometry.y += self.atlas_origin.y;
        let surfaces_by_id = &self.surfaces_by_id;
        self.local_windows.create(app_id, title, geometry, |id| {
            surfaces_by_id.contains_key(&id)
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn focused_local_flutter_window(&self) -> Option<u64> {
        self.local_windows.focused()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn is_local_flutter_window(&self, window_id: u64) -> bool {
        self.local_windows.contains(window_id)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn focus_local_flutter_window(&mut self, window_id: u64) -> bool {
        self.local_windows.focus(window_id)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn clear_local_flutter_focus(&mut self) {
        self.local_windows.clear_focus();
    }

    #[cfg(feature = "flutter")]
    pub(super) fn configure_local_flutter_window(
        &mut self,
        window_id: u64,
        mut geometry: WindowGeometry,
    ) -> bool {
        geometry.x += self.atlas_origin.x;
        geometry.y += self.atlas_origin.y;
        self.local_vertical_restore_geometries.remove(&window_id);
        self.local_windows.configure(window_id, geometry)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn local_flutter_window_geometry(&self, window_id: u64) -> Option<WindowGeometry> {
        self.local_windows
            .get(window_id)
            .map(|window| window.geometry)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn set_local_flutter_window_global_geometry(
        &mut self,
        window_id: u64,
        geometry: WindowGeometry,
    ) -> bool {
        self.local_vertical_restore_geometries.remove(&window_id);
        self.local_windows.configure(window_id, geometry)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn local_flutter_window_placement(
        &self,
        window_id: u64,
        phase: WindowPlacementPhase,
        change: WindowPlacementChange,
    ) -> Option<WindowPlacement> {
        let geometry = self.local_windows.get(window_id)?.geometry;
        let global_geometry = Rectangle::<i32, Logical>::new(
            Point::from((
                geometry
                    .x
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                geometry
                    .y
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
            )),
            Size::from((
                geometry.width.round().clamp(1.0, f64::from(i32::MAX)) as i32,
                geometry.height.round().clamp(1.0, f64::from(i32::MAX)) as i32,
            )),
        );
        let monitor_id = self
            .output_for_geometry(global_geometry)
            .and_then(|entry| i64::try_from(entry.id.0).ok())?;
        Some(WindowPlacement {
            window_id,
            monitor_id,
            workspace_id: 1,
            phase,
            change,
            geometry: WindowGeometry {
                x: geometry.x - self.atlas_origin.x,
                y: geometry.y - self.atlas_origin.y,
                width: geometry.width,
                height: geometry.height,
            },
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn remove_local_flutter_window(&mut self, window_id: u64) -> bool {
        self.local_vertical_restore_geometries.remove(&window_id);
        self.local_windows.remove(window_id)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_surface_minimized(&mut self, surface: ObjectId, minimized: bool) -> bool {
        let changed = if minimized {
            self.minimized_windows.insert(surface)
        } else {
            self.minimized_windows.remove(&surface)
        };
        if changed {
            self.invalidate_idle_inhibition();
        }
        changed
    }

    pub(super) fn remove_surface_state(&mut self, surface: &WlSurface, remove_identity: bool) {
        let object_id = surface.id();
        #[cfg(feature = "flutter")]
        self.remove_window_output_membership(surface);
        #[cfg(feature = "flutter")]
        self.idle_inhibitors.remove_surface(surface);
        #[cfg(feature = "flutter")]
        self.invalidate_idle_inhibition();
        #[cfg(feature = "flutter")]
        let stable_id = self.surface_ids.get(&object_id).copied();
        #[cfg(feature = "flutter")]
        let removes_toplevel = self
            .space
            .elements()
            .any(|window| self.window_root_surface(window).as_ref() == Some(surface));

        self.surface_buffers.remove(&object_id);
        self.configured_window_geometries.remove(&object_id);
        self.exact_window_geometries.remove(&object_id);
        self.restore_window_geometries.remove(&object_id);
        self.restored_window_positions.remove(&object_id);
        self.client_geometry_state_requests.remove(&object_id);
        self.pending_client_sized_placements.remove(&object_id);
        #[cfg(feature = "flutter")]
        self.shell_maximize_restore_geometries.remove(&object_id);
        #[cfg(feature = "flutter")]
        self.shell_fullscreen_restore_geometries.remove(&object_id);
        #[cfg(feature = "flutter")]
        self.shell_vertical_restore_geometries.remove(&object_id);
        if matches!(
            &self.cursor_status,
            CursorImageStatus::Surface(cursor_surface) if cursor_surface == surface
        ) {
            #[cfg(feature = "flutter")]
            self.update_cursor_image(CursorImageStatus::default_named());
            #[cfg(not(feature = "flutter"))]
            {
                self.cursor_status = CursorImageStatus::default_named();
            }
        }

        #[cfg(feature = "flutter")]
        {
            let cached_route_is_stale =
                self.client_input_route_cache.as_ref().is_some_and(|route| {
                    &route.surface == surface
                        || (removes_toplevel
                            && self.owning_toplevel_surface(&route.surface).as_ref()
                                == Some(surface))
                });
            let pointer_route_is_stale =
                self.client_pointer_capture.as_ref().is_some_and(|route| {
                    &route.surface == surface
                        || (removes_toplevel
                            && self.owning_toplevel_surface(&route.surface).as_ref()
                                == Some(surface))
                });
            let stale_touch_slots = self
                .client_touch_routes
                .iter()
                .filter_map(|(slot, route)| {
                    (&route.surface == surface
                        || (removes_toplevel
                            && self.owning_toplevel_surface(&route.surface).as_ref()
                                == Some(surface)))
                    .then_some(*slot)
                })
                .collect::<Vec<_>>();

            self.remove_surface_shm_frame(&object_id);
            self.pending_surface_commits.remove(&object_id);
            self.pending_frame_callback_windows.remove(&object_id);
            self.pending_input_method_frame_callbacks.remove(&object_id);
            self.pending_cursor_frame_callback_roots.remove(&object_id);
            self.pending_shm_snapshots.remove(&object_id);
            self.surface_buffer_revisions.remove(&object_id);
            self.minimized_windows.remove(&object_id);
            self.shell_fullscreen_locks.remove(&object_id);
            if let Some(stable_id) = stable_id {
                self.pointer_constraint_escape.forget_window(stable_id);
                self.pending_cursor_buffer_surface_ids.remove(&stable_id);
            }

            if cached_route_is_stale {
                self.client_input_route_cache = None;
            }
            if pointer_route_is_stale {
                self.client_pointer_capture = None;
                self.client_pointer_buttons.clear();
                self.client_pointer_presses.clear();
            }
            for slot in stale_touch_slots {
                self.client_touch_routes.remove(&slot);
            }
            if stable_id.is_some_and(|stable_id| {
                self.routed_pointer_target == RoutedPointerTarget::Client(stable_id)
            }) {
                self.set_routed_pointer_target(RoutedPointerTarget::Flutter);
            }
        }

        if remove_identity && let Some(stable_id) = self.surface_ids.remove(&object_id) {
            let removed = self.surfaces_by_id.remove(&stable_id);
            debug_assert!(
                removed
                    .as_ref()
                    .is_none_or(|candidate| candidate == surface)
            );
        }
    }
}
