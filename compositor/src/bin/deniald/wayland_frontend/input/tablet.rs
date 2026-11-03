//! Graphics-tablet device lifecycle, output mapping, and tablet-v2 dispatch.

use super::*;

use smithay::backend::input::{
    ProximityState, TabletToolButtonEvent, TabletToolEvent, TabletToolProximityEvent,
    TabletToolTipEvent, TabletToolTipState,
};
use smithay::input::tablet::tool::{
    AxisFrame, ButtonEvent as ToolButtonEvent, DownEvent as ToolDownEvent,
    MotionEvent as ToolMotionEvent, ProximityInEvent, ProximityOutEvent, TabletToolHandle,
    UpEvent as ToolUpEvent,
};
use smithay::input::tablet::{TabletDescriptor, TabletSeatTrait};

#[derive(Clone, Copy)]
struct TabletOutputMapping {
    bounds: Rectangle<i32, Logical>,
    transform: OutputTransform,
}

fn preferred_tablet_output_index(
    associated_output: Option<&str>,
    retained_output: Option<&str>,
    pointer: Point<i32, Logical>,
    outputs: &[(&str, Rectangle<i32, Logical>)],
) -> Option<usize> {
    associated_output
        .and_then(|name| outputs.iter().position(|(candidate, _)| *candidate == name))
        .or_else(|| {
            retained_output
                .and_then(|name| outputs.iter().position(|(candidate, _)| *candidate == name))
        })
        .or_else(|| {
            outputs
                .iter()
                .position(|(_, geometry)| geometry.contains(pointer))
        })
        .or((!outputs.is_empty()).then_some(0))
}

fn tablet_output_mapping(
    frontend: &mut WaylandFrontend,
    device: &LibinputDevice,
) -> Option<TabletOutputMapping> {
    if let Some(output) = frontend
        .tablet_output_mappings
        .get(device.sysname())
        .and_then(|connector| {
            frontend
                .outputs
                .iter()
                .find(|output| &output.connector == connector)
        })
    {
        return Some(TabletOutputMapping {
            bounds: output.logical_geometry,
            transform: output.transform,
        });
    }

    let device_id = device.sysname().to_owned();
    let associated_output = device.output_name().map(|name| name.into_owned());
    let retained_output = frontend.tablet_output_mappings.get(&device_id).cloned();
    let pointer = frontend.pointer_location.to_i32_round();
    let candidates = frontend
        .outputs
        .iter()
        .map(|output| (output.connector.as_str(), output.logical_geometry))
        .collect::<Vec<_>>();
    let index = preferred_tablet_output_index(
        associated_output.as_deref(),
        retained_output.as_deref(),
        pointer,
        &candidates,
    )?;
    let output = &frontend.outputs[index];
    if retained_output.as_deref() != Some(output.connector.as_str()) {
        info!(
            device = %device.name(),
            device_id,
            output = %output.connector,
            associated_output = ?associated_output,
            "mapped graphics tablet to output"
        );
    }
    frontend
        .tablet_output_mappings
        .insert(device_id, output.connector.clone());
    Some(TabletOutputMapping {
        bounds: output.logical_geometry,
        transform: output.transform,
    })
}

fn tablet_position<E>(frontend: &mut WaylandFrontend, event: &E) -> Option<Point<f64, Logical>>
where
    E: AbsolutePositionEvent<LibinputInputBackend> + Event<LibinputInputBackend>,
{
    let mapping = tablet_output_mapping(frontend, &event.device())?;
    let position = output_bound_absolute_position(event, mapping.bounds, mapping.transform);
    Some(frontend.clamp_pointer(position))
}

fn tool_handle<E>(state: &mut RuntimeState, event: &E) -> TabletToolHandle<RuntimeState>
where
    E: TabletToolEvent<LibinputInputBackend>,
{
    let (tablet_seat, display_handle) = {
        let frontend = state.frontend();
        (frontend.seat.tablet_seat(), frontend.display_handle.clone())
    };
    let descriptor = event.tool();
    tablet_seat
        .get_tool(&descriptor)
        .unwrap_or_else(|| tablet_seat.add_wp_tool(state, &display_handle, &descriptor))
}

fn axis_frame<E>(event: &E) -> AxisFrame
where
    E: TabletToolEvent<LibinputInputBackend>,
{
    AxisFrame {
        pressure: event
            .pressure_has_changed()
            .then(|| event.pressure().clamp(0.0, 1.0)),
        distance: event
            .distance_has_changed()
            .then(|| event.distance().clamp(0.0, 1.0)),
        tilt: event.tilt_has_changed().then(|| event.tilt()),
        rotation: event.rotation_has_changed().then(|| event.rotation()),
        slider: event
            .slider_has_changed()
            .then(|| event.slider_position().clamp(-1.0, 1.0)),
        wheel: event
            .wheel_has_changed()
            .then(|| (event.wheel_delta(), event.wheel_delta_discrete())),
    }
}

#[cfg(feature = "flutter")]
fn tablet_focus(
    state: &mut RuntimeState,
    position: Point<f64, Logical>,
) -> (
    Option<(WlSurface, Point<f64, Logical>)>,
    Option<ClientInputRoute>,
) {
    if state.flutter_active {
        let route = state.frontend_mut().input_route(position).cloned();
        let focus = route
            .as_ref()
            .map(|route| route.focus_at(position))
            .map(|(surface, location)| (surface.0, location));
        return (focus, route);
    }
    let focus = state
        .frontend()
        .surface_under(position)
        .map(|(surface, location)| (surface.0, location));
    (focus, None)
}

#[cfg(not(feature = "flutter"))]
fn tablet_focus(
    state: &mut RuntimeState,
    position: Point<f64, Logical>,
) -> (Option<(WlSurface, Point<f64, Logical>)>, Option<()>) {
    let focus = state
        .frontend()
        .surface_under(position)
        .map(|(surface, location)| (surface.0, location));
    (focus, None)
}

struct RoutedToolMotion {
    tool: TabletToolHandle<RuntimeState>,
    #[cfg(not(feature = "flutter"))]
    position: Point<f64, Logical>,
    #[cfg(feature = "flutter")]
    route: Option<ClientInputRoute>,
}

/// Move the tool to the event's position, entering proximity first when the
/// tool is not yet over a tablet. The caller adds its own events and ends the
/// tool frame.
fn route_tool_motion<E>(state: &mut RuntimeState, event: &E) -> Option<RoutedToolMotion>
where
    E: TabletToolEvent<LibinputInputBackend>,
{
    let position = {
        let frontend = state.frontend_mut();
        tablet_position(frontend, event)?
    };
    let tool = tool_handle(state, event);
    let (focus, _route) = tablet_focus(state, position);
    let serial = SERIAL_COUNTER.next_serial();
    let time = event.time();
    if tool.current_tablet().is_none() {
        let (tablet_seat, display_handle) = {
            let frontend = state.frontend();
            (frontend.seat.tablet_seat(), frontend.display_handle.clone())
        };
        let descriptor = TabletDescriptor::from(&event.device());
        let tablet = tablet_seat
            .get_tablet(&descriptor)
            .unwrap_or_else(|| tablet_seat.add_wp_tablet(&display_handle, &descriptor));
        tool.proximity_in(
            state,
            focus,
            tablet,
            &ProximityInEvent {
                location: position,
                axis: Some(axis_frame(event)),
                serial,
                time,
            },
        );
    } else {
        tool.axis(state, axis_frame(event));
        tool.motion(
            state,
            focus,
            &ToolMotionEvent {
                location: position,
                serial,
                time,
            },
        );
    }
    {
        let frontend = state.frontend_mut();
        frontend.pointer_location = position;
        #[cfg(feature = "flutter")]
        if _route.is_some() {
            frontend.set_pointer_cursor_visible(true);
            frontend.queue_cursor_position();
        }
    }
    state.scene_sync.mark_dirty();
    Some(RoutedToolMotion {
        tool,
        #[cfg(not(feature = "flutter"))]
        position,
        #[cfg(feature = "flutter")]
        route: _route,
    })
}

pub(super) fn register_device(state: &mut RuntimeState, device: &LibinputDevice) -> bool {
    if !Device::has_capability(device, DeviceCapability::TabletTool) {
        return false;
    }
    let (tablet_seat, display_handle) = {
        let frontend = state.frontend();
        (frontend.seat.tablet_seat(), frontend.display_handle.clone())
    };
    tablet_seat.add_wp_tablet(&display_handle, &TabletDescriptor::from(device));
    info!(
        device = %device.name(),
        device_id = device.sysname(),
        associated_output = ?device.output_name(),
        "registered graphics tablet"
    );
    true
}

pub(super) fn unregister_device(state: &mut RuntimeState, device: &LibinputDevice) -> bool {
    if !Device::has_capability(device, DeviceCapability::TabletTool) {
        return false;
    }
    let tablet_seat = state.frontend().seat.tablet_seat();
    tablet_seat.remove_tablet(&TabletDescriptor::from(device));
    if tablet_seat.count_tablets() == 0 {
        tablet_seat.clear_tools();
    }
    state
        .frontend_mut()
        .tablet_output_mappings
        .remove(device.sysname());
    info!(
        device = %device.name(),
        device_id = device.sysname(),
        "unregistered graphics tablet"
    );
    true
}

pub(super) fn process_event(
    state: &mut RuntimeState,
    event: &InputEvent<LibinputInputBackend>,
) -> bool {
    #[cfg(feature = "flutter")]
    if state.secure_session_locked() {
        let tool = match event {
            InputEvent::TabletToolAxis { event, .. } => Some((event.tool(), event.time())),
            InputEvent::TabletToolProximity { event, .. } => Some((event.tool(), event.time())),
            InputEvent::TabletToolTip { event, .. } => Some((event.tool(), event.time())),
            InputEvent::TabletToolButton { event, .. } => Some((event.tool(), event.time())),
            _ => None,
        };
        if let Some((tool, time)) = tool {
            let tablet_seat = state.frontend().seat.tablet_seat();
            if let Some(handle) = tablet_seat.get_tool(&tool) {
                if handle.current_tablet().is_some() {
                    let serial = SERIAL_COUNTER.next_serial();
                    handle.proximity_out(state, &ProximityOutEvent { serial, time });
                    handle.frame(state, time);
                }
            }
            tablet_seat.remove_tool(&tool);
            return true;
        }
    }

    match event {
        InputEvent::TabletToolAxis { event, .. } => {
            if let Some(result) = route_tool_motion(state, event) {
                result.tool.frame(state, event.time());
                return true;
            }
            false
        }
        InputEvent::TabletToolProximity { event, .. } => match event.state() {
            ProximityState::In => {
                if let Some(result) = route_tool_motion(state, event) {
                    result.tool.frame(state, event.time());
                    return true;
                }
                false
            }
            ProximityState::Out => {
                let frontend = state.frontend_mut();
                let tool = frontend.seat.tablet_seat().get_tool(&event.tool());
                frontend
                    .tablet_output_mappings
                    .remove(event.device().sysname());
                if let Some(tool) = tool.filter(|tool| tool.current_tablet().is_some()) {
                    let serial = SERIAL_COUNTER.next_serial();
                    tool.proximity_out(
                        state,
                        &ProximityOutEvent {
                            serial,
                            time: event.time(),
                        },
                    );
                    tool.frame(state, event.time());
                }
                true
            }
        },
        InputEvent::TabletToolTip { event, .. } => {
            let Some(result) = route_tool_motion(state, event) else {
                return true;
            };
            let tool = result.tool;
            match TabletToolTipEvent::tip_state(event) {
                TabletToolTipState::Down => {
                    let serial = SERIAL_COUNTER.next_serial();
                    tool.down(
                        state,
                        &ToolDownEvent {
                            serial,
                            time: event.time(),
                        },
                    );
                    #[cfg(feature = "flutter")]
                    if let Some(route) = result.route.as_ref() {
                        if super::flutter_route::activate_client_route(state, route, serial) {
                            state.scene_sync.mark_dirty();
                        }
                    }
                    #[cfg(not(feature = "flutter"))]
                    {
                        let window = state
                            .frontend()
                            .space
                            .element_under(result.position)
                            .map(|(window, _)| window.clone());
                        if let Some(window) = window {
                            super::super::window_management::activate_window(
                                state, &window, serial,
                            );
                        }
                    }
                }
                TabletToolTipState::Up => tool.up(
                    state,
                    &ToolUpEvent {
                        serial: SERIAL_COUNTER.next_serial(),
                        time: event.time(),
                    },
                ),
            }
            tool.frame(state, event.time());
            true
        }
        InputEvent::TabletToolButton { event, .. } => {
            let Some(result) = route_tool_motion(state, event) else {
                return true;
            };
            result.tool.button(
                state,
                &ToolButtonEvent {
                    serial: SERIAL_COUNTER.next_serial(),
                    button: event.button(),
                    state: TabletToolButtonEvent::button_state(event),
                    time: event.time(),
                },
            );
            result.tool.frame(state, event.time());
            true
        }
        _ => false,
    }
}
