//! Desktop pets (`protocol/denial-pet-v1.xml`): layer surfaces the user can
//! drop on a window's edge or corner, which the window then carries.
//!
//! The shell decides and draws; Denial guards. A pet declares the point it
//! holds on by, the holds it accepts and how it stacks while held. A press on
//! it hands its drag to Denial (`PetMoveGrab`), which moves the layer with the
//! pointer. Meanwhile the shell, which knows what the user sees, names the
//! hold the pet would take if let go (`PetRequest`). Denial checks that the
//! pet accepts that hold and that the window may hold pets, and applies the
//! last one when the user lets go. The shell then draws the pet with its
//! window and reports how fast it moves on screen, which Denial forwards.
//!
//! The pet learns where it was let go free, which is only its own place, or
//! which kind of hold has it; then how fast its window carries it, never
//! where the window is. While held, the layer's anchors and margins are
//! ignored, so the pet cannot move itself. A pet that watches the pointer
//! learns which way it is, about once a second, never how far. From version
//! 3 a pet also learns how fast the user drags it, so it can sway; with it,
//! it can work out roughly where it was dropped (the Doctor's choice,
//! 2026-10-09).

use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use super::*;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::wayland_server::{Client, DataInit, Dispatch, GlobalDispatch, New};
use smithay::wayland::compositor::get_role;
use smithay::wayland::shell::wlr_layer::Anchor;

use super::super::window_grab::PetMoveGrab;
use super::super::wire::PetDescription;

pub mod protocol {
    pub mod server {
        #![allow(
            dead_code,
            non_camel_case_types,
            non_upper_case_globals,
            non_snake_case,
            unused_imports,
            unused_unsafe,
            unused_variables,
            clippy::all,
            missing_docs
        )]
        use wayland_server;
        use wayland_server::protocol::*;
        pub mod __interfaces {
            use wayland_server::backend as wayland_backend;
            use wayland_server::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/denial-pet-v1.xml");
        }
        use self::__interfaces::*;
        wayland_scanner::generate_server_code!("protocol/denial-pet-v1.xml");
    }
}

use protocol::server::denial_pet_manager_v1::{self, DenialPetManagerV1};
use protocol::server::denial_pet_v1::{self, DenialPetV1, Hold, Stacking};

#[cfg(test)]
#[path = "pet/tests.rs"]
mod tests;

/// The fastest a shell may say a pet is carried, in logical px/s: beyond any
/// animation, so a bad value cannot fling the pet.
const FASTEST_CARRY: f64 = 100_000.0;

/// How often watching pets learn which way the pointer is: about every 60
/// frames at 60 Hz.
const POINTING: Duration = Duration::from_secs(1);

/// A direction whose cosine with the last one sent is above this, within
/// 2°, is not sent again.
const SAME_WAY: f64 = 0.999_4;

/// The first version that hears how fast the user drags it.
const DRAG_SPEED_VERSION: u32 = 3;

/// How fast a pet the user drags moves is measured over at least this long,
/// sent again when it changes by this much, in logical px/s, and zero once
/// it has not moved for this long: as the shell measures a carried pet's
/// (`DesktopPetCarry`).
const DRAG_SAMPLE: Duration = Duration::from_millis(16);
const DRAG_TOLERANCE: f64 = 1.0;
const DRAG_STILL: Duration = Duration::from_millis(48);

pub(super) fn init(display: &DisplayHandle) {
    display.create_global::<RuntimeState, DenialPetManagerV1, _>(3, ());
}

/// The pets known to the frontend.
#[derive(Default)]
pub(super) struct Pets {
    surfaces: Vec<WlSurface>,
    /// The timer that tells watching pets where the pointer is, while any
    /// watches.
    pointing: Option<RegistrationToken>,
    /// The timer that tells dragged pets they stopped, while any moves.
    stilling: Option<RegistrationToken>,
}

/// A pet's state, kept in its surface's data map.
#[derive(Default)]
struct PetState {
    /// The protocol object; none once it is destroyed.
    resource: Option<DenialPetV1>,
    /// In surface-local logical coordinates; none for the default, the
    /// middle of the bottom edge.
    anchor: Option<Point<f64, Logical>>,
    holds: u32,
    below: bool,
    place: Place,
    /// Whether the last velocity it was sent is not zero.
    carried: bool,
    /// While the user drags it: where its top left was, and when, as its
    /// speed is measured from there; and the speed it was last sent.
    dragged_from: Option<(Point<f64, Logical>, Instant)>,
    drag_speed: Point<f64, Logical>,
    /// Whether it watches the pointer.
    watching: bool,
    /// The direction to the pointer it was last sent.
    pointed: Option<Point<f64, Logical>>,
}

/// Where a pet is.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
enum Place {
    /// Where its anchors and margins put it.
    #[default]
    Free,
    /// The user is dragging it: its top left, global, and the hold the
    /// shell last named for it, if any.
    Dragged {
        at: Point<f64, Logical>,
        held: Option<Held>,
    },
    /// The user let it go free at `at` and it has not set new anchors or
    /// margins since: those it had then.
    Dropped {
        at: Point<f64, Logical>,
        layout: Layout,
    },
    /// A window holds it.
    Held(Held),
}

/// A layer's anchors and margins (top, right, bottom, left).
type Layout = (Anchor, [i32; 4]);

/// The window holding a pet, by which hold, and where along an edge.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct Held {
    pub(super) window_id: u64,
    pub(super) hold: Hold,
    /// From the edge's left or top end, as a share of it.
    pub(super) share: f64,
}

fn with_pet<T>(surface: &WlSurface, f: impl FnOnce(&mut PetState) -> T) -> Option<T> {
    if !surface.is_alive() {
        return None;
    }
    with_states(surface, |states| {
        let pet = states.data_map.get::<Mutex<PetState>>()?;
        let mut pet = pet.lock().unwrap_or_else(PoisonError::into_inner);
        pet.resource.is_some().then(|| f(&mut pet))
    })
}

fn layout_of(layer: &DesktopLayerSurface) -> Layout {
    let state = layer.cached_state();
    let margin = state.margin;
    (
        state.anchor,
        [margin.top, margin.right, margin.bottom, margin.left],
    )
}

/// The point of `frame` that `hold` holds by, `share` along an edge.
pub(super) fn hold_point(
    frame: Rectangle<f64, Logical>,
    hold: Hold,
    share: f64,
) -> Point<f64, Logical> {
    let (left, top) = (frame.loc.x, frame.loc.y);
    let (right, bottom) = (left + frame.size.w, top + frame.size.h);
    let across = left + share * frame.size.w;
    let down = top + share * frame.size.h;
    let (x, y) = match hold {
        Hold::Top => (across, top),
        Hold::Bottom => (across, bottom),
        Hold::Left => (left, down),
        Hold::Right => (right, down),
        Hold::TopLeft => (left, top),
        Hold::TopRight => (right, top),
        Hold::BottomLeft => (left, bottom),
        Hold::BottomRight => (right, bottom),
    };
    Point::from((x, y))
}

/// The direction from a pet's `anchor` to the `pointer`, a unit vector, if
/// it is worth sending after `last`: none while the pointer is on the anchor
/// or within 2° of the last direction sent.
pub(super) fn pointing(
    anchor: Point<f64, Logical>,
    pointer: Point<f64, Logical>,
    last: Option<Point<f64, Logical>>,
) -> Option<Point<f64, Logical>> {
    let (x, y) = (pointer.x - anchor.x, pointer.y - anchor.y);
    let length = x.hypot(y);
    // Also false for a length that is not a number.
    if !(length >= 1.0) {
        return None;
    }
    let way = Point::from((x / length, y / length));
    match last {
        Some(last) if last.x * way.x + last.y * way.y > SAME_WAY => None,
        _ => Some(way),
    }
}

/// How fast a dragged pet moved from `from` to `to` in `elapsed`, if that is
/// long enough to tell: within the fastest a pet is carried.
pub(super) fn drag_speed(
    from: Point<f64, Logical>,
    to: Point<f64, Logical>,
    elapsed: Duration,
) -> Option<Point<f64, Logical>> {
    if elapsed < DRAG_SAMPLE {
        return None;
    }
    let seconds = elapsed.as_secs_f64();
    let (x, y) = ((to.x - from.x) / seconds, (to.y - from.y) / seconds);
    (x.is_finite() && y.is_finite()).then(|| {
        Point::from((
            x.clamp(-FASTEST_CARRY, FASTEST_CARRY),
            y.clamp(-FASTEST_CARRY, FASTEST_CARRY),
        ))
    })
}

/// Whether a dragged pet's `speed` is worth sending after `last`: it changed
/// by enough, or it started or stopped.
pub(super) fn drag_speed_changed(speed: Point<f64, Logical>, last: Point<f64, Logical>) -> bool {
    let zero = Point::<f64, Logical>::default();
    (speed.x - last.x).hypot(speed.y - last.y) >= DRAG_TOLERANCE || (speed == zero) != (last == zero)
}

/// The hold a shell names for a pet, if the pet accepts it: one protocol
/// hold value among `holds`, with its share along an edge.
pub(super) fn accepted_hold(holds: u32, hold: u32, share: f64) -> Option<(Hold, f64)> {
    if hold.count_ones() != 1 || holds & hold == 0 || !share.is_finite() {
        return None;
    }
    let hold = Hold::try_from(hold).ok()?;
    Some((hold, share.clamp(0.0, 1.0)))
}

impl WaylandFrontend {
    /// The visible frame of a window that may hold pets, global: its content
    /// with the frame the shell draws around it. None for windows that let
    /// pets go: fullscreen, maximized or unmapped ones.
    fn hold_frame(&self, window: &Window) -> Option<Rectangle<f64, Logical>> {
        let presentation = self.managed_window_presentation(window);
        if presentation.fullscreen || presentation.maximized {
            return None;
        }
        let geometry = self.window_geometry_target(window);
        if geometry.size.w <= 0 || geometry.size.h <= 0 {
            return None;
        }
        // As the shell's DesktopWindowPlacement.frame.
        let border = if presentation.server_side_decorated {
            f64::from(SHELL_FRAME_BORDER)
        } else {
            0.0
        };
        let geometry = geometry.to_f64();
        Some(Rectangle::new(
            Point::from((geometry.loc.x - border, geometry.loc.y - border)),
            Size::from((
                geometry.size.w + border * 2.0,
                geometry.size.h + border * 2.0,
            )),
        ))
    }

    /// Where a window holds a pet: the global point its anchor is at.
    fn held_point(&self, held: &Held) -> Option<Point<f64, Logical>> {
        let window = self.window_for_id(held.window_id)?;
        let frame = self.hold_frame(&window)?;
        Some(hold_point(frame, held.hold, held.share))
    }

    /// A pet's surface, by its object id.
    fn pet_surface(&self, pet_id: u64) -> Option<WlSurface> {
        self.pets
            .surfaces
            .iter()
            .find(|surface| surface.is_alive() && self.surface_id(surface) == Some(pet_id))
            .cloned()
    }

    /// A pet's layer, if `surface` is a mapped layer's root and a pet, with
    /// its output and its place by its own anchors and margins, global.
    fn pet_layer(
        &self,
        surface: &WlSurface,
    ) -> Option<(DesktopLayerSurface, &WaylandOutput, Rectangle<i32, Logical>)> {
        with_pet(surface, |_| ())?;
        let (root, output_id) = self.layer_root_surface(surface)?;
        if root != *surface {
            return None;
        }
        let output = self.outputs.iter().find(|entry| entry.id == output_id)?;
        let map = layer_map_for_output(&output.output);
        let layer = map
            .layer_for_surface(surface, WindowSurfaceType::TOPLEVEL)?
            .clone();
        let mut geometry = map.layer_geometry(&layer)?;
        geometry.loc = saturating_point_add(output.logical_geometry.loc, geometry.loc);
        Some((layer, output, geometry))
    }

    /// A pet's anchor, in its own logical coordinates, `size` big.
    fn pet_anchor(pet: &PetState, size: Size<i32, Logical>) -> Point<f64, Logical> {
        pet.anchor
            .unwrap_or_else(|| Point::from((f64::from(size.w) / 2.0, f64::from(size.h))))
    }

    /// Where the shell is to show a layer surface, global, and what it is to
    /// know of it if it is a pet. Called for every layer published.
    pub(super) fn pet_presentation(
        &self,
        layer: &DesktopLayerSurface,
        arranged: Rectangle<i32, Logical>,
    ) -> (Point<f64, Logical>, Option<PetDescription>) {
        let Some((place, anchor, holds, below)) = with_pet(layer.wl_surface(), |pet| {
            (
                pet.place,
                Self::pet_anchor(pet, arranged.size),
                pet.holds,
                pet.below,
            )
        }) else {
            return (arranged.loc.to_f64(), None);
        };
        let description = |dragged: bool, held: Option<Held>| PetDescription {
            holds,
            anchor_x: anchor.x,
            anchor_y: anchor.y,
            below,
            dragged,
            held: held.map(|held| (held.window_id, held.hold as u32, held.share)),
        };
        let free = (arranged.loc.to_f64(), Some(description(false, None)));
        match place {
            Place::Free => free,
            // The shell draws a pet it named a hold for with that window.
            Place::Dragged { at, held } => (at, Some(description(true, held))),
            Place::Dropped { at, layout } => {
                if layout == layout_of(layer) {
                    (at, Some(description(false, None)))
                } else {
                    // The pet set its own place since: it rules again.
                    with_pet(layer.wl_surface(), |pet| {
                        if pet.place == place {
                            pet.place = Place::Free;
                        }
                    });
                    free
                }
            }
            Place::Held(held) => match self.held_point(&held) {
                Some(point) => (point - anchor, Some(description(false, Some(held)))),
                // Released before the next scene.
                None => free,
            },
        }
    }

    /// Lets go of the pets whose windows went, maximized or went fullscreen:
    /// they go back to their anchors and margins. Run before each scene.
    pub(super) fn settle_pets(&mut self) {
        self.pets.surfaces.retain(|surface| surface.is_alive());
        for surface in self.pets.surfaces.clone() {
            let Some(Place::Held(held)) = with_pet(&surface, |pet| pet.place) else {
                continue;
            };
            if self.held_point(&held).is_some() {
                continue;
            }
            with_pet(&surface, |pet| {
                pet.place = Place::Free;
                Self::stop_carrying(pet);
                if let Some(resource) = &pet.resource {
                    resource.released();
                }
            });
        }
    }

    /// Tells a pet it is no longer carried, if it was.
    fn stop_carrying(pet: &mut PetState) {
        if std::mem::take(&mut pet.carried)
            && let Some(resource) = &pet.resource
        {
            resource.carried(0.0, 0.0);
        }
    }

    /// The user takes hold of a pet, `pointer` being where they pressed:
    /// it is lifted off whatever held it. Gives where they hold it from its
    /// top left.
    pub(super) fn lift_pet(
        &mut self,
        surface: &WlSurface,
        pointer: Point<f64, Logical>,
    ) -> Option<Point<f64, Logical>> {
        let (layer, _, arranged) = self.pet_layer(surface)?;
        let (at, _) = self.pet_presentation(&layer, arranged);
        with_pet(surface, |pet| {
            // It keeps its hold until the shell names another, so the shell
            // goes on drawing it with its window.
            let held = match pet.place {
                Place::Held(held) => Some(held),
                _ => None,
            };
            pet.place = Place::Dragged { at, held };
            Self::stop_carrying(pet);
            pet.dragged_from = Some((at, Instant::now()));
            pet.drag_speed = Point::default();
        })?;
        Some(pointer - at)
    }

    /// The user drags a pet with its top left to `at`, global. The hold the
    /// shell named stays until it names another. Gives its id, unless it is
    /// no longer a pet.
    pub(crate) fn drag_pet(&mut self, surface: &WlSurface, at: Point<f64, Logical>) -> Option<u64> {
        self.pet_layer(surface)?;
        let id = self.surface_id(surface)?;
        let moving = with_pet(surface, |pet| {
            let Place::Dragged { held, .. } = pet.place else {
                return false;
            };
            pet.place = Place::Dragged { at, held };
            Self::feel_drag(pet, at, Instant::now())
        })?;
        if moving {
            self.watch_dragged_pets();
        }
        Some(id)
    }

    /// A pet the user drags reached `at` at `now`: one that asks hears how
    /// fast it moves. Gives whether it was last told it moves.
    fn feel_drag(pet: &mut PetState, at: Point<f64, Logical>, now: Instant) -> bool {
        let asks = pet
            .resource
            .as_ref()
            .is_some_and(|resource| resource.version() >= DRAG_SPEED_VERSION);
        let Some((from, since)) = pet.dragged_from.filter(|_| asks) else {
            return false;
        };
        let Some(speed) = drag_speed(from, at, now.saturating_duration_since(since)) else {
            return pet.carried;
        };
        pet.dragged_from = Some((at, now));
        if drag_speed_changed(speed, pet.drag_speed)
            && let Some(resource) = &pet.resource
        {
            resource.carried(speed.x, speed.y);
            pet.drag_speed = speed;
            pet.carried = speed != Point::default();
        }
        pet.carried
    }

    /// Tells dragged pets when they stop moving, while any moves.
    fn watch_dragged_pets(&mut self) {
        if self.pets.stilling.is_some() {
            return;
        }
        let timer = self.loop_handle.insert_source(
            Timer::from_duration(DRAG_STILL),
            |_, _, state: &mut RuntimeState| {
                let Some(frontend) = state.wayland.as_mut() else {
                    return TimeoutAction::Drop;
                };
                if frontend.still_dragged_pets(Instant::now()) {
                    TimeoutAction::ToDuration(DRAG_STILL)
                } else {
                    frontend.pets.stilling = None;
                    TimeoutAction::Drop
                }
            },
        );
        match timer {
            Ok(token) => self.pets.stilling = Some(token),
            Err(error) => warn!(%error, "could not watch dragged pets"),
        }
    }

    /// Tells each dragged pet that has not moved for a while that it
    /// stopped. Gives whether any still moves.
    fn still_dragged_pets(&mut self, now: Instant) -> bool {
        self.pets.surfaces.retain(|surface| surface.is_alive());
        let mut moving = false;
        for surface in self.pets.surfaces.clone() {
            with_pet(&surface, |pet| {
                if !pet.carried || !matches!(pet.place, Place::Dragged { .. }) {
                    return;
                }
                let Some((at, since)) = pet.dragged_from else {
                    return;
                };
                if now.saturating_duration_since(since) < DRAG_STILL {
                    moving = true;
                    return;
                }
                pet.dragged_from = Some((at, now));
                pet.drag_speed = Point::default();
                Self::stop_carrying(pet);
            });
        }
        moving
    }

    /// The shell names the hold a dragged pet would take if let go now, or
    /// none: the window's object id, the protocol hold value and the share
    /// along an edge. Kept only if the pet is being dragged, accepts that
    /// hold and the window may hold pets. Gives whether the pet changed.
    pub(super) fn hold_pet(&mut self, pet_id: u64, hold: Option<(u64, u32, f64)>) -> bool {
        let Some(surface) = self.pet_surface(pet_id) else {
            return false;
        };
        let Some(holds) = with_pet(&surface, |pet| pet.holds) else {
            return false;
        };
        let held = match hold {
            None => None,
            Some((window_id, hold, share)) => {
                let Some((hold, share)) = accepted_hold(holds, hold, share) else {
                    warn!(pet_id, hold, "ignored a hold the pet does not accept");
                    return false;
                };
                let holds_pets = self
                    .window_for_id(window_id)
                    .is_some_and(|window| self.hold_frame(&window).is_some());
                if !holds_pets {
                    return false;
                }
                Some(Held {
                    window_id,
                    hold,
                    share,
                })
            }
        };
        with_pet(&surface, |pet| match pet.place {
            Place::Dragged { at, held: was } if was != held => {
                pet.place = Place::Dragged { at, held };
                true
            }
            _ => false,
        })
        .unwrap_or(false)
    }

    /// The shell shows a held pet moving at `velocity`, logical px/s, its
    /// window's animations included: the pet feels it. Ignored for a pet that
    /// is not held, which includes one the user drags.
    pub(super) fn carry_pet(&mut self, pet_id: u64, velocity: Point<f64, Logical>) {
        if !velocity.x.is_finite() || !velocity.y.is_finite() {
            return;
        }
        let Some(surface) = self.pet_surface(pet_id) else {
            return;
        };
        let velocity = Point::<f64, Logical>::from((
            velocity.x.clamp(-FASTEST_CARRY, FASTEST_CARRY),
            velocity.y.clamp(-FASTEST_CARRY, FASTEST_CARRY),
        ));
        with_pet(&surface, |pet| {
            if !matches!(pet.place, Place::Held(_)) {
                return;
            }
            let moving = velocity != Point::default();
            if !moving && !pet.carried {
                return;
            }
            if let Some(resource) = &pet.resource {
                resource.carried(velocity.x, velocity.y);
                pet.carried = moving;
            }
        });
    }

    /// Tells pets that watch the pointer about once a second which way it
    /// is, while any watches.
    fn watch_pointer(&mut self) {
        if self.pets.pointing.is_some() {
            return;
        }
        let timer = self.loop_handle.insert_source(
            Timer::from_duration(POINTING),
            |_, _, state: &mut RuntimeState| {
                let Some(frontend) = state.wayland.as_mut() else {
                    return TimeoutAction::Drop;
                };
                if frontend.point_pets() {
                    TimeoutAction::ToDuration(POINTING)
                } else {
                    frontend.pets.pointing = None;
                    TimeoutAction::Drop
                }
            },
        );
        match timer {
            Ok(token) => self.pets.pointing = Some(token),
            Err(error) => warn!(%error, "could not watch the pointer for pets"),
        }
    }

    /// Tells each pet that watches the pointer which way it is from its
    /// anchor, if that changed. Gives whether any pet still watches.
    fn point_pets(&mut self) -> bool {
        self.pets.surfaces.retain(|surface| surface.is_alive());
        let pointer = self.seat.get_pointer().map(|pointer| pointer.current_location());
        let mut watching = false;
        for surface in self.pets.surfaces.clone() {
            if with_pet(&surface, |pet| pet.watching) != Some(true) {
                continue;
            }
            watching = true;
            let (Some(pointer), Some((layer, _, arranged))) = (pointer, self.pet_layer(&surface))
            else {
                continue;
            };
            let (at, _) = self.pet_presentation(&layer, arranged);
            with_pet(&surface, |pet| {
                // While the user drags it, the pointer only shows where they
                // hold it.
                if matches!(pet.place, Place::Dragged { .. }) {
                    return;
                }
                let anchor = at + Self::pet_anchor(pet, arranged.size);
                if let Some(way) = pointing(anchor, pointer, pet.pointed)
                    && let Some(resource) = &pet.resource
                {
                    resource.pointer(way.x, way.y);
                    pet.pointed = Some(way);
                }
            });
        }
        watching
    }

    /// The user lets go of a pet: held by the hold the shell named last, or
    /// free where it is. Either way the pet hears of it.
    pub(crate) fn drop_pet(&mut self, surface: &WlSurface) {
        let Some((layer, output, _)) = self.pet_layer(surface) else {
            return;
        };
        let origin = output.logical_geometry.loc;
        let layout = layout_of(&layer);
        // The window may have stopped holding pets since the shell named it.
        let held = with_pet(surface, |pet| match pet.place {
            Place::Dragged { held, .. } => held,
            _ => None,
        })
        .flatten()
        .filter(|held| self.held_point(held).is_some());
        with_pet(surface, |pet| {
            let Place::Dragged { at, .. } = pet.place else {
                return;
            };
            let Some(resource) = pet.resource.clone() else {
                return;
            };
            // It stops before it lands.
            pet.dragged_from = None;
            pet.drag_speed = Point::default();
            Self::stop_carrying(pet);
            match held {
                Some(held) => {
                    pet.place = Place::Held(held);
                    resource.held(held.hold);
                }
                None => {
                    let at = Point::from((at.x.round(), at.y.round()));
                    pet.place = Place::Dropped { at, layout };
                    // Its own place, from its own output: nothing of others.
                    resource.placed(at.x as i32 - origin.x, at.y as i32 - origin.y);
                }
            }
        });
    }
}

impl GlobalDispatch<DenialPetManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<DenialPetManagerV1>,
        _data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

/// A pet object's surface.
pub(super) struct PetUserData {
    surface: WlSurface,
}

impl Dispatch<DenialPetManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &DenialPetManagerV1,
        request: denial_pet_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            denial_pet_manager_v1::Request::GetPet { id, surface } => {
                let pet = data_init.init(
                    id,
                    PetUserData {
                        surface: surface.clone(),
                    },
                );
                if get_role(&surface) != Some(LAYER_SURFACE_ROLE) {
                    resource.post_error(
                        denial_pet_manager_v1::Error::Role,
                        "a pet must be a layer surface",
                    );
                    return;
                }
                let taken = with_states(&surface, |states| {
                    states
                        .data_map
                        .insert_if_missing_threadsafe(|| Mutex::new(PetState::default()));
                    let mut state = states
                        .data_map
                        .get::<Mutex<PetState>>()
                        .expect("pet state")
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    if state.resource.is_some() {
                        return true;
                    }
                    *state = PetState {
                        resource: Some(pet.clone()),
                        ..PetState::default()
                    };
                    false
                });
                if taken {
                    resource.post_error(
                        denial_pet_manager_v1::Error::AlreadyConstructed,
                        "the surface already has a pet object",
                    );
                    return;
                }
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.pets.surfaces.push(surface);
                }
                // The shell learns it is a pet.
                state.scene_sync.mark_dirty();
            }
            denial_pet_manager_v1::Request::Destroy => {}
        }
    }
}

impl Dispatch<DenialPetV1, PetUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &DenialPetV1,
        request: denial_pet_v1::Request,
        data: &PetUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        let surface = &data.surface;
        match request {
            // The shell knows every pet's anchor, holds and stacking.
            denial_pet_v1::Request::SetAnchor { x, y } => {
                if !x.is_finite() || !y.is_finite() {
                    return;
                }
                if with_pet(surface, |pet| pet.anchor = Some(Point::from((x, y)))).is_some() {
                    state.scene_sync.mark_dirty();
                }
            }
            denial_pet_v1::Request::SetHolds { holds } => {
                if with_pet(surface, |pet| pet.holds = holds).is_some() {
                    state.scene_sync.mark_dirty();
                }
            }
            denial_pet_v1::Request::SetStacking { stacking } => {
                let below = matches!(stacking.into_result(), Ok(Stacking::Below));
                if with_pet(surface, |pet| pet.below = below).is_some() {
                    state.scene_sync.mark_dirty();
                }
            }
            denial_pet_v1::Request::Move { seat, serial } => {
                begin_pet_drag(state, surface, &seat, Serial::from(serial));
            }
            denial_pet_v1::Request::WatchPointer => {
                let watching = with_pet(surface, |pet| {
                    pet.watching = true;
                    pet.pointed = None;
                });
                if watching.is_some()
                    && let Some(frontend) = state.wayland.as_mut()
                {
                    frontend.watch_pointer();
                }
            }
            // The timer stops once no pet watches.
            denial_pet_v1::Request::IgnorePointer => {
                with_pet(surface, |pet| pet.watching = false);
            }
            denial_pet_v1::Request::Destroy => {}
        }
    }

    fn destroyed(state: &mut Self, _client: ClientId, _resource: &DenialPetV1, data: &PetUserData) {
        // A plain layer surface again, where its anchors and margins put it.
        let was = with_pet(&data.surface, |pet| *pet = PetState::default());
        if let Some(frontend) = state.wayland.as_mut() {
            frontend
                .pets
                .surfaces
                .retain(|surface| surface != &data.surface && surface.is_alive());
        }
        if was.is_some() {
            state.scene_sync.mark_dirty();
        }
    }
}

/// A press on a pet hands its drag to Denial. Only a current press on the
/// pet itself does: anything else is ignored, so a pet cannot move itself.
fn begin_pet_drag(
    state: &mut RuntimeState,
    surface: &WlSurface,
    seat: &wl_seat::WlSeat,
    serial: Serial,
) {
    let Some(seat) = Seat::<RuntimeState>::from_resource(seat) else {
        return;
    };
    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    if frontend.pet_layer(surface).is_none() {
        return;
    }
    let start_data = frontend
        .take_client_pointer_press(surface, serial)
        .or_else(|| checked_pointer_grab(&seat, surface, serial));
    let on_pet = start_data
        .as_ref()
        .and_then(|start| start.focus.as_ref())
        .and_then(|(focus, _)| frontend.layer_root_surface(focus))
        .is_some_and(|(root, _)| root == *surface);
    let (Some(start_data), true) = (start_data, on_pet) else {
        warn!(?serial, "rejected a pet move without a press on the pet");
        return;
    };
    let Some(hold) = frontend.lift_pet(surface, start_data.location) else {
        return;
    };
    let Some(pointer) = seat.get_pointer() else {
        return;
    };
    pointer.set_grab(
        state,
        PetMoveGrab::new(start_data, surface.clone(), hold),
        serial,
        Focus::Clear,
    );
    state.scene_sync.mark_dirty();
}
