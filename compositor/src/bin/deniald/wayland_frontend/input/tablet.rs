//! Graphics-tablet device lifecycle, output mapping, and tablet-v2 dispatch.

use super::*;

use smithay::backend::input::{
    ProximityState, TabletToolButtonEvent, TabletToolEvent, TabletToolProximityEvent,
    TabletToolTipEvent, TabletToolTipState,
};
use smithay::wayland::tablet_manager::{
    TabletDescriptor, TabletHandle, TabletSeatTrait, TabletToolHandle,
};

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

fn tablet_handles<E>(state: &mut RuntimeState, event: &E) -> (TabletHandle, TabletToolHandle)
where
    E: TabletToolEvent<LibinputInputBackend>,
{
    let (tablet_seat, display_handle) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        (frontend.seat.tablet_seat(), frontend.display_handle.clone())
    };
    let tablet = tablet_seat
        .add_tablet::<RuntimeState>(&display_handle, &TabletDescriptor::from(&event.device()));
    let tool_descriptor = event.tool();
    let tool = tablet_seat.add_tool::<RuntimeState>(state, &display_handle, &tool_descriptor);
    (tablet, tool)
}

fn queue_tool_axes<E>(tool: &TabletToolHandle, event: &E)
where
    E: TabletToolEvent<LibinputInputBackend>,
{
    if event.pressure_has_changed() {
        tool.pressure(event.pressure().clamp(0.0, 1.0));
    }
    if event.distance_has_changed() {
        tool.distance(event.distance().clamp(0.0, 1.0));
    }
    if event.tilt_has_changed() {
        tool.tilt(event.tilt());
    }
    if event.slider_has_changed() {
        tool.slider_position(event.slider_position().clamp(-1.0, 1.0));
    }
    if event.rotation_has_changed() {
        tool.rotation(event.rotation());
    }
    if event.wheel_has_changed() {
        tool.wheel(event.wheel_delta(), event.wheel_delta_discrete());
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
        let route = state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .input_route(position)
            .cloned();
        let focus = route.as_ref().map(|route| route.focus_at(position));
        return (focus, route);
    }
    let focus = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .surface_under(position);
    (focus, None)
}

#[cfg(not(feature = "flutter"))]
fn tablet_focus(
    state: &mut RuntimeState,
    position: Point<f64, Logical>,
) -> (Option<(WlSurface, Point<f64, Logical>)>, Option<()>) {
    let focus = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .surface_under(position);
    (focus, None)
}

struct RoutedToolMotion {
    tool: TabletToolHandle,
    #[cfg(not(feature = "flutter"))]
    position: Point<f64, Logical>,
    #[cfg(feature = "flutter")]
    route: Option<ClientInputRoute>,
}

fn route_tool_motion<E>(state: &mut RuntimeState, event: &E) -> Option<RoutedToolMotion>
where
    E: TabletToolEvent<LibinputInputBackend>,
{
    let position = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        tablet_position(frontend, event)?
    };
    let (tablet, tool) = tablet_handles(state, event);
    queue_tool_axes(&tool, event);
    let (focus, _route) = tablet_focus(state, position);
    tool.motion(
        position,
        focus,
        &tablet,
        SERIAL_COUNTER.next_serial(),
        event.time_msec(),
    );
    {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
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
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        (frontend.seat.tablet_seat(), frontend.display_handle.clone())
    };
    tablet_seat.add_tablet::<RuntimeState>(&display_handle, &TabletDescriptor::from(device));
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
    let tablet_seat = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .tablet_seat();
    tablet_seat.remove_tablet(&TabletDescriptor::from(device));
    if tablet_seat.count_tablets() == 0 {
        tablet_seat.clear_tools();
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
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
            InputEvent::TabletToolAxis { event, .. } => Some((event.tool(), event.time_msec())),
            InputEvent::TabletToolProximity { event, .. } => {
                Some((event.tool(), event.time_msec()))
            }
            InputEvent::TabletToolTip { event, .. } => Some((event.tool(), event.time_msec())),
            InputEvent::TabletToolButton { event, .. } => Some((event.tool(), event.time_msec())),
            _ => None,
        };
        if let Some((tool, time)) = tool {
            let tablet_seat = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .tablet_seat();
            if let Some(handle) = tablet_seat.get_tool(&tool) {
                handle.proximity_out(time);
            }
            tablet_seat.remove_tool(&tool);
            return true;
        }
    }

    match event {
        InputEvent::TabletToolAxis { event, .. } => route_tool_motion(state, event).is_some(),
        InputEvent::TabletToolProximity { event, .. } => match event.state() {
            ProximityState::In => route_tool_motion(state, event).is_some(),
            ProximityState::Out => {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let tool = frontend.seat.tablet_seat().get_tool(&event.tool());
                frontend
                    .tablet_output_mappings
                    .remove(event.device().sysname());
                if let Some(tool) = tool {
                    tool.proximity_out(event.time_msec());
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
                    tool.tip_down(serial, event.time_msec());
                    #[cfg(feature = "flutter")]
                    if let Some(route) = result.route.as_ref() {
                        if super::flutter_route::activate_client_route(state, route, serial) {
                            state.scene_sync.mark_dirty();
                        }
                    }
                    #[cfg(not(feature = "flutter"))]
                    {
                        let window = state
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
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
                TabletToolTipState::Up => tool.tip_up(event.time_msec()),
            }
            true
        }
        InputEvent::TabletToolButton { event, .. } => {
            let Some(result) = route_tool_motion(state, event) else {
                return true;
            };
            result.tool.button(
                event.button(),
                TabletToolButtonEvent::button_state(event),
                SERIAL_COUNTER.next_serial(),
                event.time_msec(),
            );
            true
        }
        _ => false,
    }
}
