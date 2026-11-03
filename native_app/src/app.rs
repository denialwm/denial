use std::{
    collections::{BTreeMap, HashMap},
    mem::size_of,
    sync::Arc,
    time::Duration,
};

use denial_flutter_engine::{EngineEvent, EngineHost, ScheduledTask, sys};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_keyboard, delegate_layer, delegate_output, delegate_pointer,
    delegate_registry, delegate_seat, delegate_touch, delegate_xdg_shell, delegate_xdg_window,
    output::{OutputHandler, OutputState},
    reexports::{
        calloop::{EventLoop, LoopHandle, channel},
        calloop_wayland_source::WaylandSource,
        protocols::wp::cursor_shape::v1::client::wp_cursor_shape_device_v1::{
            Shape, WpCursorShapeDeviceV1,
        },
    },
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        Capability, SeatHandler, SeatState,
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers},
        pointer::{
            AxisScroll, PointerEvent, PointerEventKind, PointerHandler,
            cursor_shape::CursorShapeManager,
        },
        touch::TouchHandler,
    },
    shell::{
        WaylandSurface,
        wlr_layer::{
            KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
            LayerSurfaceConfigure,
        },
        xdg::{
            XdgShell,
            window::{Window, WindowConfigure, WindowDecorations, WindowHandler},
        },
    },
};
use wayland_client::{
    Connection, QueueHandle,
    globals::registry_queue_init,
    protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_surface, wl_touch},
};

use crate::ime::Ime;
use crate::touch::{TouchEvent, TouchInput};
use crate::{AppExtension, config::Config, platform::Platform, renderer::Renderer};

pub enum Event {
    Engine(EngineEvent),
    Presented,
    Error(String),
    PlatformReply(denial_flutter_engine::PlatformMessage, Vec<u8>),
    TextureAvailable(i64),
}

pub fn run(config: Config, extension: AppExtension) -> Result<(), Box<dyn std::error::Error>> {
    let connection = Connection::connect_to_env()?;
    let (globals, queue) = registry_queue_init(&connection)?;
    let qh = queue.handle();
    let mut event_loop = EventLoop::<App>::try_new()?;
    let handle = event_loop.handle();
    WaylandSource::new(connection.clone(), queue).insert(handle.clone())?;
    let compositor = CompositorState::bind(&globals, &qh)?;
    // Shell globals stay bound for the lifetime of their surface role.
    let (_xdg_shell, _layer_shell, surface) = if config.overlay {
        let layer_shell = LayerShell::bind(&globals, &qh)?;
        let layer = layer_shell.create_layer_surface(
            &qh,
            compositor.create_surface(&qh),
            Layer::Overlay,
            Some(config.app_id.clone()),
            None,
        );
        // Without anchors, the compositor centers the surface on its output.
        layer.set_size(config.width, config.height);
        layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
        (None, Some(layer_shell), ShellSurface::Overlay(layer))
    } else {
        let xdg_shell = XdgShell::bind(&globals, &qh)?;
        let window = xdg_shell.create_window(
            compositor.create_surface(&qh),
            WindowDecorations::RequestServer,
            &qh,
        );
        window.set_app_id(config.app_id.clone());
        window.set_title(config.title.clone());
        window.set_min_size(Some((320, 240)));
        (Some(xdg_shell), None, ShellSurface::Window(window))
    };
    let (events, receiver) = channel::channel();
    handle.insert_source(receiver, |event, _, app| match event {
        channel::Event::Msg(event) => app.event(event),
        channel::Event::Closed => app.exit = true,
    })?;
    let mut app = App {
        host: None,
        renderer: None,
        surface,
        registry: RegistryState::new(&globals),
        seat_state: SeatState::new(&globals, &qh),
        output_state: OutputState::new(&globals, &qh),
        cursor_manager: CursorShapeManager::bind(&globals, &qh).ok(),
        cursor_device: None,
        ime: Ime::bind(&globals, &qh),
        keyboard: None,
        pointer: None,
        touch: None,
        touch_input: TouchInput::default(),
        input_seat: None,
        loop_handle: handle,
        qh,
        connection,
        events,
        width: config.width,
        height: config.height,
        scale: 1,
        config,
        platform: Platform::default(),
        extension,
        tasks: BTreeMap::new(),
        task_sequence: 0,
        vsync: Vec::new(),
        bootstrap_deadline: None,
        frame_pending: false,
        mapped: false,
        frame_interval: Duration::from_nanos(16_666_667),
        focus: false,
        modifiers: Modifiers::default(),
        pressed_keys: HashMap::new(),
        pointer_position: (0.0, 0.0),
        pointer_added: false,
        buttons: 0,
        enter_serial: None,
        cursor: "default",
        exit: false,
        error: None,
    };
    // Initial empty commit obtains the role's configure. No buffer is attached
    // until its size is acknowledged and the engine has produced a frame.
    app.surface.commit();
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        while !app.exit {
            let timeout = app.timeout();
            event_loop.dispatch(timeout, &mut app)?;
            app.run_due_tasks();
            app.connection.flush()?;
        }
        if let Some(error) = app.error.take() {
            return Err(error.into());
        }
        Ok(())
    })();
    // Shutdown joins engine workers before releasing EGL or Wayland resources,
    // including when event dispatch or a native callback reports an error.
    for texture in &app.extension.textures {
        texture.set_notifier(None);
    }
    let shutdown = app.host.take().map(EngineHost::shutdown).transpose();
    app.renderer.take();
    result?;
    shutdown?;
    Ok(())
}

/// The single Flutter view is presented either as a decorated window or as an
/// undecorated overlay, such as an authentication prompt.
enum ShellSurface {
    Window(Window),
    Overlay(LayerSurface),
}

impl ShellSurface {
    fn wl_surface(&self) -> &wl_surface::WlSurface {
        match self {
            Self::Window(window) => window.wl_surface(),
            Self::Overlay(layer) => layer.wl_surface(),
        }
    }

    fn commit(&self) {
        match self {
            Self::Window(window) => window.commit(),
            Self::Overlay(layer) => layer.commit(),
        }
    }
}

pub(crate) struct App {
    host: Option<EngineHost>,
    renderer: Option<Arc<Renderer>>,
    surface: ShellSurface,
    registry: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    cursor_manager: Option<CursorShapeManager>,
    cursor_device: Option<WpCursorShapeDeviceV1>,
    pub(crate) ime: Ime,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    touch: Option<wl_touch::WlTouch>,
    touch_input: TouchInput,
    input_seat: Option<wl_seat::WlSeat>,
    loop_handle: LoopHandle<'static, App>,
    qh: QueueHandle<App>,
    connection: Connection,
    events: channel::Sender<Event>,
    config: Config,
    width: u32,
    height: u32,
    scale: u32,
    platform: Platform,
    extension: AppExtension,
    tasks: BTreeMap<(u64, u64), ScheduledTask>,
    task_sequence: u64,
    vsync: Vec<isize>,
    bootstrap_deadline: Option<u64>,
    frame_pending: bool,
    mapped: bool,
    frame_interval: Duration,
    focus: bool,
    modifiers: Modifiers,
    pressed_keys: HashMap<u32, (u32, u32)>,
    pointer_position: (f64, f64),
    pointer_added: bool,
    buttons: i64,
    enter_serial: Option<u32>,
    cursor: &'static str,
    exit: bool,
    error: Option<String>,
}

impl App {
    fn fail(&mut self, error: impl ToString) {
        self.error.get_or_insert_with(|| error.to_string());
        self.exit = true;
    }

    fn start(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        let renderer = Arc::new(Renderer::new(
            &self.connection,
            self.surface.wl_surface(),
            self.physical_size(),
            self.events.clone(),
            self.extension.textures.clone(),
        )?);
        let host = EngineHost::start_with_dart_arguments(
            &self.config.project,
            renderer.clone(),
            &self.config.dart_arguments,
        )?;
        self.renderer = Some(renderer);
        self.host = Some(host);
        for texture in &self.extension.textures {
            self.host
                .as_ref()
                .unwrap()
                .engine()
                .register_external_texture(texture.id())?;
            let events = self.events.clone();
            texture.set_notifier(Some(Arc::new(move |id| {
                let _ = events.send(Event::TextureAvailable(id));
            })));
        }
        self.metrics()?;
        let engine = self.host.as_ref().unwrap().engine();
        engine.send_platform_message(
            c"flutter/settings",
            br#"{"textScaleFactor":1.0,"alwaysUse24HourFormat":true,"platformBrightness":"dark"}"#,
        )?;
        self.lifecycle()?;
        eprintln!(
            "denial-app: started {} using {}",
            self.config.app_id,
            self.config.project.engine_library.display()
        );
        Ok(())
    }

    fn configured(&mut self) {
        let result = if self.host.is_none() {
            self.start()
        } else {
            self.metrics().map_err(Into::into)
        };
        if let Err(error) = result {
            self.fail(error);
        }
    }

    fn physical_size(&self) -> (u32, u32) {
        (self.width * self.scale, self.height * self.scale)
    }

    fn metrics(&self) -> Result<(), denial_flutter_engine::EngineError> {
        let Some(host) = &self.host else {
            return Ok(());
        };
        let (width, height) = self.physical_size();
        if let Some(renderer) = &self.renderer {
            renderer.resize((width, height), self.scale);
        }
        host.engine()
            .send_window_metrics(&sys::FlutterWindowMetricsEvent {
                struct_size: size_of::<sys::FlutterWindowMetricsEvent>(),
                width: width as usize,
                height: height as usize,
                pixel_ratio: self.scale as f64,
                ..Default::default()
            })
    }

    fn lifecycle(&self) -> Result<(), denial_flutter_engine::EngineError> {
        if let Some(host) = &self.host {
            host.engine().send_platform_message(
                c"flutter/lifecycle",
                if self.focus {
                    b"AppLifecycleState.resumed"
                } else {
                    b"AppLifecycleState.inactive"
                },
            )?;
        }
        Ok(())
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Error(error) => self.fail(error),
            Event::Presented => {
                self.mapped = true;
                if !self.vsync.is_empty() {
                    self.request_frame();
                }
            }
            Event::Engine(EngineEvent::PlatformTask(task)) => {
                self.task_sequence = self.task_sequence.wrapping_add(1);
                self.tasks
                    .insert((task.target_time_nanos, self.task_sequence), task);
            }
            Event::Engine(EngineEvent::Vsync(baton)) => {
                self.vsync.push(baton);
                if self.mapped {
                    self.request_frame();
                } else if self.bootstrap_deadline.is_none()
                    && let Some(host) = &self.host
                {
                    self.bootstrap_deadline = Some(
                        host.engine().current_time_nanos() + self.frame_interval.as_nanos() as u64,
                    );
                }
            }
            Event::Engine(EngineEvent::PlatformMessage(mut message)) => {
                if crate::file_chooser::handles(&message.channel, &message.data) {
                    let events = self.events.clone();
                    std::thread::spawn(move || {
                        let data = crate::file_chooser::run(&message.data);
                        let _ = events.send(Event::PlatformReply(message, data));
                    });
                    return;
                }
                if message.channel == "denial/overlay" {
                    let reply = self.overlay_call(&message.data);
                    if let Some(host) = &self.host
                        && let Err(error) = host.respond(&mut message, reply)
                    {
                        self.fail(error);
                    }
                    return;
                }
                let mut reply = self.platform.handle(&message.channel, &message.data);
                if message.channel == "flutter/textinput" {
                    // A tap on a field asks again, even when it has the
                    // keyboard already: the compositor may have dismissed it.
                    let engage = serde_json::from_slice::<serde_json::Value>(&message.data)
                        .is_ok_and(|call| call["method"] == "TextInput.show");
                    self.ime.follow(self.platform.text_input_change(), engage);
                }
                if reply.data.is_empty()
                    && !reply.close
                    && reply.cursor.is_none()
                    && let Some(handler) = &self.extension.platform_handler
                    && let Some(data) = handler.handle(&message.channel, &message.data)
                {
                    reply.data = data;
                }
                if let Some(cursor) = reply.cursor {
                    self.cursor = cursor;
                    self.apply_cursor();
                }
                if let Some(host) = &self.host
                    && let Err(error) = host.respond(&mut message, &reply.data)
                {
                    self.fail(error);
                }
                if reply.close {
                    self.exit = true;
                }
            }
            Event::PlatformReply(mut message, data) => {
                if let Some(host) = &self.host
                    && let Err(error) = host.respond(&mut message, &data)
                {
                    self.fail(error);
                }
            }
            Event::TextureAvailable(id) => {
                if let Some(texture) = self
                    .extension
                    .textures
                    .iter()
                    .find(|texture| texture.id() == id)
                {
                    texture.acknowledge_notification();
                    if let Some(host) = &self.host
                        && let Err(error) = host.engine().mark_external_texture_frame_available(id)
                    {
                        self.fail(error);
                    }
                }
            }
        }
    }

    /// An overlay sizes itself to what it draws, so the compositor can
    /// treat all of it as the dialog: `resize` takes logical pixels.
    fn overlay_call(&mut self, data: &[u8]) -> &'static [u8] {
        let Ok(call) = serde_json::from_slice::<serde_json::Value>(data) else {
            return b"";
        };
        let ShellSurface::Overlay(layer) = &self.surface else {
            return b"";
        };
        if call["method"] != "resize" {
            return b"";
        }
        let size = |ix: usize| {
            call["args"][ix]
                .as_f64()
                .filter(|value| value.is_finite() && *value >= 1.0)
                .map(|value| value.ceil().min(4096.0) as u32)
        };
        let (Some(width), Some(height)) = (size(0), size(1)) else {
            return br#"["bad-size","Expected a width and a height",null]"#;
        };
        if (width, height) != (self.width, self.height) {
            layer.set_size(width, height);
            layer.commit();
        }
        b"[null]"
    }

    fn request_frame(&mut self) {
        if !self.frame_pending {
            if let Some(renderer) = &self.renderer {
                renderer.request_frame(&self.qh);
            }
            self.frame_pending = true;
            self.bootstrap_deadline = None;
        }
    }

    fn tick(&mut self) {
        self.bootstrap_deadline = None;
        if let Some(host) = &self.host {
            for baton in self.vsync.drain(..) {
                if let Err(error) = host.engine().on_vsync_after(baton, self.frame_interval) {
                    self.error.get_or_insert_with(|| error.to_string());
                    self.exit = true;
                }
            }
        }
    }

    fn timeout(&self) -> Option<Duration> {
        let task = self.tasks.first_key_value().map(|((time, _), _)| *time);
        let deadline = match (task, self.bootstrap_deadline) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }?;
        let now = self.host.as_ref()?.engine().current_time_nanos();
        Some(Duration::from_nanos(deadline.saturating_sub(now)))
    }

    fn run_due_tasks(&mut self) {
        let Some(host) = &self.host else {
            return;
        };
        let now = host.engine().current_time_nanos();
        // Bound one dispatch's work so input and configure events cannot be
        // starved by an engine continuously scheduling immediate tasks.
        for _ in 0..256 {
            if self
                .tasks
                .first_key_value()
                .is_none_or(|((time, _), _)| *time > now)
            {
                break;
            }
            let (_, task) = self.tasks.pop_first().unwrap();
            if let Err(error) = host.run_scheduled_task(task) {
                self.error.get_or_insert_with(|| error.to_string());
                self.exit = true;
                break;
            }
        }
        if self.bootstrap_deadline.is_some_and(|time| time <= now) {
            self.tick();
        }
    }

    fn key(&mut self, event: KeyEvent, down: bool) {
        if !self.focus {
            return;
        }
        let scalar = event
            .utf8
            .as_deref()
            .and_then(|s| s.chars().next())
            .map(u32::from)
            .unwrap_or(0);
        let key = if down {
            *self
                .pressed_keys
                .entry(event.raw_code)
                .or_insert((event.keysym.raw(), scalar))
        } else {
            self.pressed_keys
                .remove(&event.raw_code)
                .unwrap_or((event.keysym.raw(), scalar))
        };
        self.send_key(event.raw_code, key, down);
        if down
            && !self.modifiers.ctrl
            && !self.modifiers.alt
            && !self.modifiers.logo
            && let Some(host) = &self.host
            && let Err(error) =
                self.platform
                    .text_key(host.engine(), event.raw_code, event.utf8.as_deref())
        {
            self.fail(error);
        }
        self.ime.follow(self.platform.text_input_change(), false);
    }

    /// The on-screen keyboard's edit, for Flutter's `client`.
    pub(crate) fn input_method(
        &mut self,
        client: i64,
        transaction: &crate::wayland_frontend::input_method::InputMethodTransaction,
    ) {
        if let Some(host) = &self.host
            && let Err(error) = self
                .platform
                .input_method(host.engine(), client, transaction)
        {
            self.fail(error);
        }
        self.ime.follow(self.platform.text_input_change(), false);
    }

    fn send_key(&mut self, code: u32, key: (u32, u32), down: bool) {
        let m = self.modifiers;
        let modifiers = u32::from(m.shift)
            | u32::from(m.caps_lock) << 1
            | u32::from(m.ctrl) << 2
            | u32::from(m.alt) << 3
            | u32::from(m.num_lock) << 4
            | u32::from(m.logo) << 26;
        // Flutter's GTK wire format describes XKB symbols/codes; it requires
        // no GTK library. Preserve the down symbol for the matching up event.
        let data = serde_json::to_vec(&serde_json::json!({
            "keymap":"linux", "toolkit":"gtk", "keyCode":key.0, "scanCode":code + 8,
            "unicodeScalarValues":key.1, "modifiers":modifiers, "type":if down {"keydown"} else {"keyup"},
        })).unwrap();
        if let Some(host) = &self.host
            && let Err(error) = host
                .engine()
                .send_platform_message(c"flutter/keyevent", &data)
        {
            self.fail(error);
        }
    }

    fn release_keys(&mut self) {
        let keys = std::mem::take(&mut self.pressed_keys);
        for (code, key) in keys {
            self.send_key(code, key, false);
        }
        self.modifiers = Modifiers::default();
    }

    fn pointer_event(&mut self, phase: sys::FlutterPointerPhase, scroll: Option<(f64, f64)>) {
        let Some(host) = &self.host else {
            return;
        };
        let (scroll_x, scroll_y) = scroll.unwrap_or_default();
        let event = sys::FlutterPointerEvent {
            struct_size: size_of::<sys::FlutterPointerEvent>(),
            phase,
            timestamp: (host.engine().current_time_nanos() / 1000) as usize,
            x: self.pointer_position.0 * self.scale as f64,
            y: self.pointer_position.1 * self.scale as f64,
            device: 0,
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
            buttons: self.buttons,
            signal_kind: if scroll.is_some() {
                sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll
            } else {
                sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone
            },
            scroll_delta_x: scroll_x * self.scale as f64,
            scroll_delta_y: scroll_y * self.scale as f64,
            ..Default::default()
        };
        if let Err(error) = host.engine().send_pointer_events(&[event]) {
            self.fail(error);
        }
    }

    fn touch_events(&mut self, events: Vec<TouchEvent>) {
        let Some(host) = &self.host else {
            return;
        };
        if events.is_empty() {
            return;
        }
        let timestamp = (host.engine().current_time_nanos() / 1000) as usize;
        let events = events
            .into_iter()
            .map(|event| event.into_flutter(self.scale, timestamp))
            .collect::<Vec<_>>();
        if let Err(error) = host.engine().send_pointer_events(&events) {
            self.fail(error);
        }
    }

    fn apply_cursor(&self) {
        let Some(serial) = self.enter_serial else {
            return;
        };
        if self.cursor == "none" {
            if let Some(pointer) = &self.pointer {
                pointer.set_cursor(serial, None, 0, 0);
            }
        } else if let Some(device) = &self.cursor_device {
            device.set_shape(serial, shape(self.cursor));
        }
    }
}

impl WindowHandler for App {
    fn request_close(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &Window) {
        self.exit = true;
    }
    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &Window,
        configure: WindowConfigure,
        _: u32,
    ) {
        self.width = configure.new_size.0.map(|n| n.get()).unwrap_or(self.width);
        self.height = configure.new_size.1.map(|n| n.get()).unwrap_or(self.height);
        self.configured();
    }
}

impl LayerShellHandler for App {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) {
        self.exit = true;
    }
    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &LayerSurface,
        configure: LayerSurfaceConfigure,
        _: u32,
    ) {
        // Zero leaves an unanchored dimension to the requested size.
        if configure.new_size.0 > 0 {
            self.width = configure.new_size.0;
        }
        if configure.new_size.1 > 0 {
            self.height = configure.new_size.1;
        }
        self.configured();
    }
}

impl CompositorHandler for App {
    fn scale_factor_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        factor: i32,
    ) {
        self.scale = factor.max(1) as u32;
        if let Err(error) = self.metrics() {
            self.fail(error);
        }
    }
    fn transform_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: wl_output::Transform,
    ) {
    }
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {
        self.frame_pending = false;
        self.tick();
    }
    fn surface_enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        output: &wl_output::WlOutput,
    ) {
        if let Some(info) = self.output_state.info(output)
            && let Some(mode) = info.modes.iter().find(|m| m.current && m.refresh_rate > 0)
        {
            self.frame_interval =
                Duration::from_nanos(1_000_000_000_000 / mode.refresh_rate as u64);
        }
    }
    fn surface_leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for App {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl SeatHandler for App {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(
        &mut self,
        _: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if self.input_seat.as_ref().is_some_and(|s| s != &seat) {
            return;
        }
        self.input_seat = Some(seat.clone());
        self.ime.seat(&seat, qh);
        match capability {
            Capability::Keyboard if self.keyboard.is_none() => {
                match self.seat_state.get_keyboard_with_repeat(
                    qh,
                    &seat,
                    None,
                    self.loop_handle.clone(),
                    Box::new(|app, _, event| app.key(event, true)),
                ) {
                    Ok(keyboard) => self.keyboard = Some(keyboard),
                    Err(error) => self.fail(error),
                }
            }
            Capability::Pointer if self.pointer.is_none() => {
                match self.seat_state.get_pointer(qh, &seat) {
                    Ok(pointer) => {
                        self.cursor_device = self
                            .cursor_manager
                            .as_ref()
                            .map(|m| m.get_shape_device(&pointer, qh));
                        self.pointer = Some(pointer);
                    }
                    Err(error) => self.fail(error),
                }
            }
            Capability::Touch if self.touch.is_none() => {
                match self.seat_state.get_touch(qh, &seat) {
                    Ok(touch) => self.touch = Some(touch),
                    Err(error) => self.fail(error),
                }
            }
            _ => {}
        }
    }
    fn remove_capability(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if self.input_seat.as_ref() != Some(&seat) {
            return;
        }
        match capability {
            Capability::Keyboard => {
                self.release_keys();
                if let Some(keyboard) = self.keyboard.take() {
                    keyboard.release();
                }
                self.focus = false;
            }
            Capability::Pointer => {
                if let Some(device) = self.cursor_device.take() {
                    device.destroy();
                }
                if let Some(pointer) = self.pointer.take() {
                    pointer.release();
                }
                self.pointer_added = false;
                self.buttons = 0;
                self.enter_serial = None;
            }
            Capability::Touch => {
                let events = self.touch_input.cancel();
                self.touch_events(events);
                if let Some(touch) = self.touch.take() {
                    touch.release();
                }
            }
            _ => {}
        }
    }
    fn remove_seat(&mut self, conn: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat) {
        self.remove_capability(conn, qh, seat.clone(), Capability::Keyboard);
        self.remove_capability(conn, qh, seat.clone(), Capability::Pointer);
        self.remove_capability(conn, qh, seat.clone(), Capability::Touch);
        if self.input_seat.as_ref() == Some(&seat) {
            self.input_seat = None;
            self.ime.remove_seat();
        }
    }
}

impl KeyboardHandler for App {
    fn enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _: u32,
        codes: &[u32],
        syms: &[Keysym],
    ) {
        if surface != self.surface.wl_surface() {
            return;
        }
        self.focus = true;
        for (&code, sym) in codes.iter().zip(syms) {
            self.pressed_keys.insert(code, (sym.raw(), 0));
            self.send_key(code, (sym.raw(), 0), true);
        }
        if let Err(error) = self.lifecycle() {
            self.fail(error);
        }
    }
    fn leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _: u32,
    ) {
        if surface != self.surface.wl_surface() {
            return;
        }
        self.release_keys();
        self.focus = false;
        if let Err(error) = self.lifecycle() {
            self.fail(error);
        }
    }
    fn press_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        event: KeyEvent,
    ) {
        self.key(event, true);
    }
    fn repeat_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        event: KeyEvent,
    ) {
        self.key(event, true);
    }
    fn release_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        event: KeyEvent,
    ) {
        self.key(event, false);
    }
    fn update_modifiers(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        modifiers: Modifiers,
        _: RawModifiers,
        _: u32,
    ) {
        self.modifiers = modifiers;
    }
}

impl TouchHandler for App {
    fn down(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_touch::WlTouch,
        _: u32,
        _: u32,
        surface: wl_surface::WlSurface,
        id: i32,
        position: (f64, f64),
    ) {
        if &surface == self.surface.wl_surface() {
            let events = self.touch_input.down(id, position);
            self.touch_events(events);
        }
    }

    fn up(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_touch::WlTouch,
        _: u32,
        _: u32,
        id: i32,
    ) {
        let events = self.touch_input.up(id);
        self.touch_events(events);
    }

    fn motion(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_touch::WlTouch,
        _: u32,
        id: i32,
        position: (f64, f64),
    ) {
        let events = self.touch_input.motion(id, position);
        self.touch_events(events);
    }

    fn cancel(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_touch::WlTouch) {
        let events = self.touch_input.cancel();
        self.touch_events(events);
    }

    fn shape(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_touch::WlTouch,
        _: i32,
        _: f64,
        _: f64,
    ) {
    }

    fn orientation(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_touch::WlTouch,
        _: i32,
        _: f64,
    ) {
    }
}

impl PointerHandler for App {
    fn pointer_frame(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        use PointerEventKind::*;
        use sys::{
            FlutterPointerPhase_kAdd as ADD, FlutterPointerPhase_kCancel as CANCEL,
            FlutterPointerPhase_kDown as DOWN, FlutterPointerPhase_kHover as HOVER,
            FlutterPointerPhase_kMove as MOVE, FlutterPointerPhase_kRemove as REMOVE,
            FlutterPointerPhase_kUp as UP,
        };
        for event in events {
            if &event.surface != self.surface.wl_surface() {
                continue;
            }
            self.pointer_position = event.position;
            match &event.kind {
                Enter { serial } => {
                    self.enter_serial = Some(*serial);
                    self.apply_cursor();
                    self.pointer_event(ADD, None);
                    self.pointer_added = true;
                    self.pointer_event(HOVER, None);
                }
                Leave { .. } => {
                    if self.pointer_added {
                        if self.buttons != 0 {
                            self.pointer_event(CANCEL, None);
                        }
                        self.buttons = 0;
                        self.pointer_event(REMOVE, None);
                    }
                    self.pointer_added = false;
                    self.enter_serial = None;
                }
                Motion { .. } => {
                    self.pointer_event(if self.buttons == 0 { HOVER } else { MOVE }, None)
                }
                Press { button, .. } => {
                    let old = self.buttons;
                    self.buttons |= button_mask(*button);
                    if self.buttons != old {
                        self.pointer_event(if old == 0 { DOWN } else { MOVE }, None);
                    }
                }
                Release { button, .. } => {
                    let old = self.buttons;
                    self.buttons &= !button_mask(*button);
                    if self.buttons != old {
                        self.pointer_event(if self.buttons == 0 { UP } else { MOVE }, None);
                    }
                }
                Axis {
                    horizontal,
                    vertical,
                    ..
                } => {
                    let delta = (scroll_delta(*horizontal), scroll_delta(*vertical));
                    if delta != (0.0, 0.0) {
                        self.pointer_event(
                            if self.buttons == 0 { HOVER } else { MOVE },
                            Some(delta),
                        );
                    }
                }
            }
        }
    }
}

fn button_mask(button: u32) -> i64 {
    match button {
        0x110 => 1,
        0x111 => 2,
        0x112 => 4,
        0x113 | 0x116 => 8,
        0x114 | 0x115 => 16,
        _ => 0,
    }
}

fn scroll_delta(axis: AxisScroll) -> f64 {
    if axis.value120 != 0 {
        axis.value120 as f64
    } else if axis.discrete != 0 {
        axis.discrete as f64 * 120.0
    } else {
        axis.absolute * 5.3
    }
}

fn shape(name: &str) -> Shape {
    match name {
        "pointer" => Shape::Pointer,
        "text" => Shape::Text,
        "vertical-text" => Shape::VerticalText,
        "not-allowed" => Shape::NotAllowed,
        "wait" => Shape::Wait,
        "progress" => Shape::Progress,
        "context-menu" => Shape::ContextMenu,
        "help" => Shape::Help,
        "cell" => Shape::Cell,
        "crosshair" => Shape::Crosshair,
        "move" => Shape::Move,
        "grab" => Shape::Grab,
        "grabbing" => Shape::Grabbing,
        "no-drop" => Shape::NoDrop,
        "alias" => Shape::Alias,
        "copy" => Shape::Copy,
        "all-scroll" => Shape::AllScroll,
        "ew-resize" => Shape::EwResize,
        "ns-resize" => Shape::NsResize,
        "nwse-resize" => Shape::NwseResize,
        "nesw-resize" => Shape::NeswResize,
        "n-resize" => Shape::NResize,
        "s-resize" => Shape::SResize,
        "w-resize" => Shape::WResize,
        "e-resize" => Shape::EResize,
        "nw-resize" => Shape::NwResize,
        "ne-resize" => Shape::NeResize,
        "sw-resize" => Shape::SwResize,
        "se-resize" => Shape::SeResize,
        "col-resize" => Shape::ColResize,
        "row-resize" => Shape::RowResize,
        "zoom-in" => Shape::ZoomIn,
        "zoom-out" => Shape::ZoomOut,
        _ => Shape::Default,
    }
}

impl ProvidesRegistryState for App {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    registry_handlers![OutputState, SeatState];
}
delegate_compositor!(App);
delegate_output!(App);
delegate_seat!(App);
delegate_keyboard!(App);
delegate_pointer!(App);
delegate_touch!(App);
delegate_xdg_shell!(App);
delegate_xdg_window!(App);
delegate_layer!(App);
delegate_registry!(App);
