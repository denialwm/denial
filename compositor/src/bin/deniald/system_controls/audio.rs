use super::*;

#[repr(C)]
struct PaThreadedMainloop {
    _private: [u8; 0],
}

#[repr(C)]
struct PaMainloopApi {
    _private: [u8; 0],
}

#[repr(C)]
struct PaContext {
    _private: [u8; 0],
}

#[repr(C)]
struct PaOperation {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PaSampleSpec {
    format: c_int,
    rate: u32,
    channels: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PaChannelMap {
    channels: u8,
    map: [c_int; 32],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PaCVolume {
    channels: u8,
    values: [u32; 32],
}

#[repr(C)]
struct PaServerInfo {
    user_name: *const c_char,
    host_name: *const c_char,
    server_version: *const c_char,
    server_name: *const c_char,
    sample_spec: PaSampleSpec,
    default_sink_name: *const c_char,
    default_source_name: *const c_char,
    cookie: u32,
    channel_map: PaChannelMap,
}

#[repr(C)]
struct PaSinkInfoPrefix {
    name: *const c_char,
    index: u32,
    description: *const c_char,
    sample_spec: PaSampleSpec,
    channel_map: PaChannelMap,
    owner_module: u32,
    volume: PaCVolume,
    mute: c_int,
}

#[repr(C)]
struct PaProplist {
    _private: [u8; 0],
}

#[repr(C)]
struct PaSinkInputInfoPrefix {
    index: u32,
    name: *const c_char,
    owner_module: u32,
    client: u32,
    sink: u32,
    sample_spec: PaSampleSpec,
    channel_map: PaChannelMap,
    volume: PaCVolume,
    buffer_usec: u64,
    sink_usec: u64,
    resample_method: *const c_char,
    driver: *const c_char,
    mute: c_int,
    proplist: *mut PaProplist,
}

type ContextStateCallback = Option<unsafe extern "C" fn(*mut PaContext, *mut c_void)>;
type ServerInfoCallback =
    Option<unsafe extern "C" fn(*mut PaContext, *const PaServerInfo, *mut c_void)>;
type SinkInfoCallback =
    Option<unsafe extern "C" fn(*mut PaContext, *const PaSinkInfoPrefix, c_int, *mut c_void)>;
type SinkInputInfoCallback =
    Option<unsafe extern "C" fn(*mut PaContext, *const PaSinkInputInfoPrefix, c_int, *mut c_void)>;
type SuccessCallback = Option<unsafe extern "C" fn(*mut PaContext, c_int, *mut c_void)>;
type SubscriptionCallback = Option<unsafe extern "C" fn(*mut PaContext, u32, u32, *mut c_void)>;

struct PulseApi {
    _library: Library,
    mainloop_new: unsafe extern "C" fn() -> *mut PaThreadedMainloop,
    mainloop_free: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_start: unsafe extern "C" fn(*mut PaThreadedMainloop) -> c_int,
    mainloop_stop: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_lock: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_unlock: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_wait: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    mainloop_get_api: unsafe extern "C" fn(*mut PaThreadedMainloop) -> *mut PaMainloopApi,
    context_new: unsafe extern "C" fn(*mut PaMainloopApi, *const c_char) -> *mut PaContext,
    context_unref: unsafe extern "C" fn(*mut PaContext),
    context_connect:
        unsafe extern "C" fn(*mut PaContext, *const c_char, u32, *const c_void) -> c_int,
    context_disconnect: unsafe extern "C" fn(*mut PaContext),
    context_get_state: unsafe extern "C" fn(*const PaContext) -> c_int,
    context_set_state_callback:
        unsafe extern "C" fn(*mut PaContext, ContextStateCallback, *mut c_void),
    context_set_subscribe_callback:
        unsafe extern "C" fn(*mut PaContext, SubscriptionCallback, *mut c_void),
    context_subscribe:
        unsafe extern "C" fn(*mut PaContext, u32, SuccessCallback, *mut c_void) -> *mut PaOperation,
    context_get_server_info:
        unsafe extern "C" fn(*mut PaContext, ServerInfoCallback, *mut c_void) -> *mut PaOperation,
    context_get_sink_info_by_name: unsafe extern "C" fn(
        *mut PaContext,
        *const c_char,
        SinkInfoCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_volume_by_name: unsafe extern "C" fn(
        *mut PaContext,
        *const c_char,
        *const PaCVolume,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_mute_by_name: unsafe extern "C" fn(
        *mut PaContext,
        *const c_char,
        c_int,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_get_sink_input_info_list: unsafe extern "C" fn(
        *mut PaContext,
        SinkInputInfoCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_get_sink_input_info: unsafe extern "C" fn(
        *mut PaContext,
        u32,
        SinkInputInfoCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_input_volume: unsafe extern "C" fn(
        *mut PaContext,
        u32,
        *const PaCVolume,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_input_mute: unsafe extern "C" fn(
        *mut PaContext,
        u32,
        c_int,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    operation_unref: unsafe extern "C" fn(*mut PaOperation),
    cvolume_avg: unsafe extern "C" fn(*const PaCVolume) -> u32,
    cvolume_set: unsafe extern "C" fn(*mut PaCVolume, u32, u32) -> *mut PaCVolume,
    proplist_gets: unsafe extern "C" fn(*const PaProplist, *const c_char) -> *const c_char,
}

impl PulseApi {
    fn load() -> Result<Self, String> {
        // SAFETY: the library name is fixed and every copied symbol remains
        // valid because the Library is retained by PulseApi for its lifetime.
        unsafe {
            let library = Library::new("libpulse.so.0")
                .map_err(|error| format!("could not load libpulse.so.0: {error}"))?;
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("missing libpulse symbol {}: {error}", $name))?
                };
            }
            Ok(Self {
                mainloop_new: symbol!("pa_threaded_mainloop_new"),
                mainloop_free: symbol!("pa_threaded_mainloop_free"),
                mainloop_start: symbol!("pa_threaded_mainloop_start"),
                mainloop_stop: symbol!("pa_threaded_mainloop_stop"),
                mainloop_lock: symbol!("pa_threaded_mainloop_lock"),
                mainloop_unlock: symbol!("pa_threaded_mainloop_unlock"),
                mainloop_wait: symbol!("pa_threaded_mainloop_wait"),
                mainloop_signal: symbol!("pa_threaded_mainloop_signal"),
                mainloop_get_api: symbol!("pa_threaded_mainloop_get_api"),
                context_new: symbol!("pa_context_new"),
                context_unref: symbol!("pa_context_unref"),
                context_connect: symbol!("pa_context_connect"),
                context_disconnect: symbol!("pa_context_disconnect"),
                context_get_state: symbol!("pa_context_get_state"),
                context_set_state_callback: symbol!("pa_context_set_state_callback"),
                context_set_subscribe_callback: symbol!("pa_context_set_subscribe_callback"),
                context_subscribe: symbol!("pa_context_subscribe"),
                context_get_server_info: symbol!("pa_context_get_server_info"),
                context_get_sink_info_by_name: symbol!("pa_context_get_sink_info_by_name"),
                context_set_sink_volume_by_name: symbol!("pa_context_set_sink_volume_by_name"),
                context_set_sink_mute_by_name: symbol!("pa_context_set_sink_mute_by_name"),
                context_get_sink_input_info_list: symbol!("pa_context_get_sink_input_info_list"),
                context_get_sink_input_info: symbol!("pa_context_get_sink_input_info"),
                context_set_sink_input_volume: symbol!("pa_context_set_sink_input_volume"),
                context_set_sink_input_mute: symbol!("pa_context_set_sink_input_mute"),
                operation_unref: symbol!("pa_operation_unref"),
                cvolume_avg: symbol!("pa_cvolume_avg"),
                cvolume_set: symbol!("pa_cvolume_set"),
                proplist_gets: symbol!("pa_proplist_gets"),
                _library: library,
            })
        }
    }
}

struct PulseSignal {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
}

struct PulseSubscription {
    commands: SyncSender<AudioCommand>,
}

const PA_SUBSCRIPTION_MASK_SINK: u32 = 1 << 0;
const PA_SUBSCRIPTION_MASK_SINK_INPUT: u32 = 1 << 2;
const PA_SUBSCRIPTION_MASK_SERVER: u32 = 1 << 7;
const PA_SUBSCRIPTION_EVENT_FACILITY_MASK: u32 = 0x0f;
const PA_SUBSCRIPTION_EVENT_SINK: u32 = 0;
const PA_SUBSCRIPTION_EVENT_SINK_INPUT: u32 = 2;
const PA_SUBSCRIPTION_EVENT_SERVER: u32 = 7;

unsafe extern "C" fn on_subscription_event(
    _context: *mut PaContext,
    event_type: u32,
    _index: u32,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: PulseConnection retains the subscription allocation until the
    // callback is unregistered and the threaded mainloop has stopped.
    let subscription = unsafe { &*userdata.cast::<PulseSubscription>() };
    match event_type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK {
        PA_SUBSCRIPTION_EVENT_SINK | PA_SUBSCRIPTION_EVENT_SERVER => {
            let _ = subscription.commands.try_send(AudioCommand::ReadLevel);
        }
        PA_SUBSCRIPTION_EVENT_SINK_INPUT => {
            let _ = subscription.commands.try_send(AudioCommand::RequestStreams);
        }
        _ => {}
    }
}

unsafe extern "C" fn on_context_state(_context: *mut PaContext, userdata: *mut c_void) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: PulseConnection pins this allocation until after the context is
    // disconnected and its threaded mainloop has stopped.
    let signal = unsafe { &*userdata.cast::<PulseSignal>() };
    // SAFETY: the callback is invoked by the live mainloop owning this handle.
    unsafe { (signal.signal)(signal.mainloop, 0) };
}

struct PulseConnection {
    mainloop: *mut PaThreadedMainloop,
    context: *mut PaContext,
    signal: Box<PulseSignal>,
    subscription: Box<PulseSubscription>,
    started: bool,
}

impl PulseConnection {
    fn connect(
        api: &PulseApi,
        subscription_commands: SyncSender<AudioCommand>,
    ) -> Result<Self, &'static str> {
        // SAFETY: all handles are created and destroyed through the matching
        // libpulse API and remain confined to the audio worker.
        unsafe {
            let mainloop = (api.mainloop_new)();
            if mainloop.is_null() {
                return Err("could not allocate PulseAudio mainloop");
            }
            let application = c"Denial Rust";
            let context = (api.context_new)((api.mainloop_get_api)(mainloop), application.as_ptr());
            if context.is_null() {
                (api.mainloop_free)(mainloop);
                return Err("could not allocate PulseAudio context");
            }
            let mut connection = Self {
                mainloop,
                context,
                signal: Box::new(PulseSignal {
                    mainloop,
                    signal: api.mainloop_signal,
                }),
                subscription: Box::new(PulseSubscription {
                    commands: subscription_commands,
                }),
                started: false,
            };
            (api.context_set_state_callback)(
                context,
                Some(on_context_state),
                (&mut *connection.signal as *mut PulseSignal).cast(),
            );
            (api.context_set_subscribe_callback)(
                context,
                Some(on_subscription_event),
                (&mut *connection.subscription as *mut PulseSubscription).cast(),
            );
            if (api.context_connect)(context, ptr::null(), 0, ptr::null()) < 0
                || (api.mainloop_start)(mainloop) < 0
            {
                connection.close(api);
                return Err("could not start PulseAudio connection");
            }
            connection.started = true;
            (api.mainloop_lock)(mainloop);
            while context_state_is_good((api.context_get_state)(context))
                && (api.context_get_state)(context) != PA_CONTEXT_READY
            {
                (api.mainloop_wait)(mainloop);
            }
            let ready = (api.context_get_state)(context) == PA_CONTEXT_READY;
            (api.mainloop_unlock)(mainloop);
            if !ready {
                connection.close(api);
                return Err("PulseAudio context did not become ready");
            }

            (api.mainloop_lock)(mainloop);
            let query = SuccessQuery {
                mainloop,
                signal: api.mainloop_signal,
                state: Mutex::new(SuccessQueryState {
                    done: false,
                    success: false,
                }),
            };
            let operation = (api.context_subscribe)(
                context,
                PA_SUBSCRIPTION_MASK_SINK
                    | PA_SUBSCRIPTION_MASK_SINK_INPUT
                    | PA_SUBSCRIPTION_MASK_SERVER,
                Some(on_success),
                (&query as *const SuccessQuery).cast_mut().cast(),
            );
            let subscribed = wait_for_success(api, &connection, operation, &query);
            (api.mainloop_unlock)(mainloop);
            if !subscribed {
                connection.close(api);
                return Err("could not subscribe to PulseAudio state changes");
            }
            info!("Denial Rust audio connected through native libpulse");
            Ok(connection)
        }
    }

    fn close(&mut self, api: &PulseApi) {
        // SAFETY: close is called at most once for handles owned by this value.
        unsafe {
            if !self.context.is_null() {
                if self.started {
                    (api.mainloop_lock)(self.mainloop);
                    (api.context_set_subscribe_callback)(self.context, None, ptr::null_mut());
                    (api.context_disconnect)(self.context);
                    (api.mainloop_unlock)(self.mainloop);
                }
                if self.started {
                    (api.mainloop_stop)(self.mainloop);
                }
                self.started = false;
                (api.context_unref)(self.context);
                self.context = ptr::null_mut();
            }
            if !self.mainloop.is_null() {
                (api.mainloop_free)(self.mainloop);
                self.mainloop = ptr::null_mut();
            }
        }
    }
}

const PA_CONTEXT_READY: c_int = 4;

fn context_state_is_good(state: c_int) -> bool {
    (0..=PA_CONTEXT_READY).contains(&state)
}

struct ServerQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<ServerQueryState>,
}

struct ServerQueryState {
    done: bool,
    sink: Option<CString>,
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

unsafe extern "C" fn on_server_info(
    _context: *mut PaContext,
    info: *const PaServerInfo,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query lives on the waiting worker stack until this callback has
    // completed and the operation is unreferenced.
    let query = unsafe { &*userdata.cast::<ServerQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if !info.is_null() {
        // SAFETY: libpulse owns a valid info record for this callback.
        let sink = unsafe { (*info).default_sink_name };
        if !sink.is_null() {
            // SAFETY: PulseAudio strings are NUL-terminated for callback life.
            state.sink = Some(unsafe { CStr::from_ptr(sink) }.to_owned());
        }
    }
    state.done = true;
    drop(state);
    // SAFETY: this is the live mainloop associated with the query.
    unsafe { (query.signal)(query.mainloop, 0) };
}

struct SinkQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<SinkQueryState>,
}

struct SinkQueryState {
    done: bool,
    sink: Option<PulseSinkState>,
}

struct PulseSinkState {
    volume: PaCVolume,
    channels: u8,
    muted: bool,
}

unsafe extern "C" fn on_sink_info(
    _context: *mut PaContext,
    info: *const PaSinkInfoPrefix,
    end_of_list: c_int,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the operation completes.
    let query = unsafe { &*userdata.cast::<SinkQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if end_of_list != 0 {
        state.done = true;
    } else if !info.is_null() {
        // SAFETY: libpulse supplies a valid ABI-stable prefix for the callback.
        let info = unsafe { &*info };
        let channels = if info.channel_map.channels > 0 {
            info.channel_map.channels
        } else {
            info.volume.channels
        };
        if channels > 0 {
            state.sink = Some(PulseSinkState {
                volume: info.volume,
                channels,
                muted: info.mute != 0,
            });
        }
    }
    let done = state.done;
    drop(state);
    if done {
        // SAFETY: this is the live mainloop associated with the query.
        unsafe { (query.signal)(query.mainloop, 0) };
    }
}

struct SinkInputQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<SinkInputQueryState>,
}

struct SinkInputQueryState {
    done: bool,
    input: Option<PulseSinkInputState>,
}

struct PulseSinkInputState {
    channels: u8,
    muted: bool,
}

unsafe extern "C" fn on_sink_input_info(
    _context: *mut PaContext,
    info: *const PaSinkInputInfoPrefix,
    end_of_list: c_int,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the introspection operation completes.
    let query = unsafe { &*userdata.cast::<SinkInputQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if end_of_list != 0 {
        state.done = true;
    } else if !info.is_null() {
        // SAFETY: libpulse supplies the stable sink-input prefix for callback life.
        let info = unsafe { &*info };
        let channels = if info.channel_map.channels > 0 {
            info.channel_map.channels
        } else {
            info.volume.channels
        };
        if channels > 0 {
            state.input = Some(PulseSinkInputState {
                channels,
                muted: info.mute != 0,
            });
        }
    }
    let done = state.done;
    drop(state);
    if done {
        // SAFETY: this is the live mainloop associated with the query.
        unsafe { (query.signal)(query.mainloop, 0) };
    }
}

struct SinkInputListQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    proplist_gets: unsafe extern "C" fn(*const PaProplist, *const c_char) -> *const c_char,
    cvolume_avg: unsafe extern "C" fn(*const PaCVolume) -> u32,
    state: Mutex<SinkInputListQueryState>,
}

struct SinkInputListQueryState {
    done: bool,
    success: bool,
    streams: Vec<AudioStreamState>,
}

unsafe extern "C" fn on_sink_input_list(
    _context: *mut PaContext,
    info: *const PaSinkInputInfoPrefix,
    end_of_list: c_int,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the list operation completes.
    let query = unsafe { &*userdata.cast::<SinkInputListQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if end_of_list < 0 {
        state.done = true;
    } else if end_of_list > 0 {
        state.done = true;
        state.success = true;
    } else if !info.is_null() && state.streams.len() < MAX_AUDIO_STREAMS {
        // SAFETY: libpulse supplies the stable sink-input prefix for callback life.
        let info = unsafe { &*info };
        // SAFETY: volume is a complete pa_cvolume copied from libpulse.
        let average = unsafe { (query.cvolume_avg)(&info.volume) };
        state.streams.push(AudioStreamState {
            id: info.index,
            // SAFETY: every inspected string is owned by libpulse for callback life.
            name: unsafe { pulse_stream_name(query.proplist_gets, info) },
            level_percent: ((f64::from(average) / 65_536.0).clamp(0.0, 1.0) * 100.0).round() as u8,
            muted: info.mute != 0,
        });
    }
    let done = state.done;
    drop(state);
    if done {
        // SAFETY: this is the live mainloop associated with the query.
        unsafe { (query.signal)(query.mainloop, 0) };
    }
}

unsafe fn pulse_stream_name(
    proplist_gets: unsafe extern "C" fn(*const PaProplist, *const c_char) -> *const c_char,
    info: &PaSinkInputInfoPrefix,
) -> String {
    let mut selected = ptr::null();
    if !info.proplist.is_null() {
        for property in [c"application.name", c"media.name", c"application.id"] {
            // SAFETY: proplist and property are valid for the active callback.
            let value = unsafe { proplist_gets(info.proplist, property.as_ptr()) };
            if !value.is_null() {
                selected = value;
                break;
            }
        }
    }
    if selected.is_null() {
        selected = info.name;
    }
    let name = if selected.is_null() {
        "Unknown application".into()
    } else {
        // SAFETY: selected is a callback-lifetime NUL-terminated PulseAudio string.
        unsafe { CStr::from_ptr(selected) }
            .to_string_lossy()
            .into_owned()
    };
    truncate_utf8(name, MAX_AUDIO_STREAM_NAME_BYTES)
}

fn truncate_utf8(mut value: String, maximum: usize) -> String {
    if value.len() <= maximum {
        return value;
    }
    let mut boundary = maximum;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
    value
}

struct SuccessQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<SuccessQueryState>,
}

struct SuccessQueryState {
    done: bool,
    success: bool,
}

unsafe extern "C" fn on_success(_context: *mut PaContext, success: c_int, userdata: *mut c_void) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the operation completes.
    let query = unsafe { &*userdata.cast::<SuccessQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    state.success = success != 0;
    state.done = true;
    drop(state);
    // SAFETY: this is the live mainloop associated with the query.
    unsafe { (query.signal)(query.mainloop, 0) };
}

fn query_default_sink(api: &PulseApi, connection: &PulseConnection) -> Option<CString> {
    // SAFETY: the threaded mainloop lock serializes every context operation;
    // the stack query stays live until its operation is complete or the
    // context leaves a usable state.
    unsafe {
        let query = ServerQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(ServerQueryState {
                done: false,
                sink: None,
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_server_info)(
            connection.context,
            Some(on_server_info),
            (&query as *const ServerQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        lock_unpoisoned(&query.state).sink.take()
    }
}

fn query_sink(api: &PulseApi, connection: &PulseConnection, sink: &CStr) -> Option<PulseSinkState> {
    // SAFETY: see query_default_sink; the same ownership and locking rules
    // apply to this introspection operation.
    unsafe {
        let query = SinkQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SinkQueryState {
                done: false,
                sink: None,
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_sink_info_by_name)(
            connection.context,
            sink.as_ptr(),
            Some(on_sink_info),
            (&query as *const SinkQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        lock_unpoisoned(&query.state).sink.take()
    }
}

fn query_sink_input(
    api: &PulseApi,
    connection: &PulseConnection,
    stream_id: u32,
) -> Option<PulseSinkInputState> {
    // SAFETY: the threaded-mainloop lock serializes this operation and the
    // stack query stays live through the terminal callback.
    unsafe {
        let query = SinkInputQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SinkInputQueryState {
                done: false,
                input: None,
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_sink_input_info)(
            connection.context,
            stream_id,
            Some(on_sink_input_info),
            (&query as *const SinkInputQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        lock_unpoisoned(&query.state).input.take()
    }
}

fn query_sink_inputs(
    api: &PulseApi,
    connection: &PulseConnection,
) -> Option<Vec<AudioStreamState>> {
    // SAFETY: the threaded-mainloop lock serializes this operation and the
    // callback never retains any server-owned pointers.
    unsafe {
        let query = SinkInputListQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            proplist_gets: api.proplist_gets,
            cvolume_avg: api.cvolume_avg,
            state: Mutex::new(SinkInputListQueryState {
                done: false,
                success: false,
                streams: Vec::with_capacity(16),
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_sink_input_info_list)(
            connection.context,
            Some(on_sink_input_list),
            (&query as *const SinkInputListQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        let mut state = lock_unpoisoned(&query.state);
        state.success.then(|| std::mem::take(&mut state.streams))
    }
}

fn wait_for_success(
    api: &PulseApi,
    connection: &PulseConnection,
    operation: *mut PaOperation,
    query: &SuccessQuery,
) -> bool {
    if operation.is_null() {
        return false;
    }
    // SAFETY: caller holds the threaded mainloop lock; query stays alive until
    // the operation callback finishes or the context fails.
    unsafe {
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
    }
    lock_unpoisoned(&query.state).success
}

fn read_pulse_level(api: &PulseApi, connection: &PulseConnection) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    // SAFETY: state.volume is a complete pa_cvolume copied from libpulse.
    let current = unsafe { (api.cvolume_avg)(&state.volume) } as f64 / 65_536.0;
    Some(current.clamp(0.0, 1.0))
}

fn set_pulse_level(api: &PulseApi, connection: &PulseConnection, target: f64) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    let target = target.clamp(0.0, MAX_AUDIO_LEVEL);
    let pulse_level = (target * 65_536.0).round() as u32;
    let mut volume = PaCVolume::default();
    // SAFETY: volume is a complete pa_cvolume and channels came from the
    // validated server record. The context stays locked through completion.
    unsafe {
        (api.cvolume_set)(&mut volume, u32::from(state.channels), pulse_level);
        (api.mainloop_lock)(connection.mainloop);
    }
    let volume_query = SuccessQuery {
        mainloop: connection.mainloop,
        signal: api.mainloop_signal,
        state: Mutex::new(SuccessQueryState {
            done: false,
            success: false,
        }),
    };
    // SAFETY: sink and volume remain live through the synchronous wait.
    let volume_operation = unsafe {
        (api.context_set_sink_volume_by_name)(
            connection.context,
            sink.as_ptr(),
            &volume,
            Some(on_success),
            (&volume_query as *const SuccessQuery).cast_mut().cast(),
        )
    };
    let volume_applied = wait_for_success(api, connection, volume_operation, &volume_query);
    // SAFETY: balances the lock acquired above.
    unsafe { (api.mainloop_unlock)(connection.mainloop) };
    if !volume_applied {
        return None;
    }

    if target > 0.0 && state.muted {
        // Raising a level is an explicit request to hear that output.
        // SAFETY: the context operation is serialized by the mainloop lock.
        unsafe { (api.mainloop_lock)(connection.mainloop) };
        let mute_query = SuccessQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SuccessQueryState {
                done: false,
                success: false,
            }),
        };
        // SAFETY: sink remains live through the synchronous wait.
        let mute_operation = unsafe {
            (api.context_set_sink_mute_by_name)(
                connection.context,
                sink.as_ptr(),
                0,
                Some(on_success),
                (&mute_query as *const SuccessQuery).cast_mut().cast(),
            )
        };
        let unmuted = wait_for_success(api, connection, mute_operation, &mute_query);
        // SAFETY: balances the lock acquired above.
        unsafe { (api.mainloop_unlock)(connection.mainloop) };
        if !unmuted {
            return None;
        }
    }

    Some(target.clamp(0.0, 1.0))
}

fn adjust_pulse_level(api: &PulseApi, connection: &PulseConnection, delta: f64) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    // SAFETY: state.volume is a valid pa_cvolume copied from libpulse.
    let current = unsafe { (api.cvolume_avg)(&state.volume) } as f64 / 65_536.0;
    let target = (current + delta).clamp(0.0, MAX_AUDIO_LEVEL);
    set_pulse_level(api, connection, target)
}

fn toggle_pulse_mute(api: &PulseApi, connection: &PulseConnection) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    // SAFETY: the context operation is serialized by the threaded-mainloop lock.
    unsafe { (api.mainloop_lock)(connection.mainloop) };
    let query = SuccessQuery {
        mainloop: connection.mainloop,
        signal: api.mainloop_signal,
        state: Mutex::new(SuccessQueryState {
            done: false,
            success: false,
        }),
    };
    // SAFETY: sink remains live through the synchronous wait.
    let operation = unsafe {
        (api.context_set_sink_mute_by_name)(
            connection.context,
            sink.as_ptr(),
            if state.muted { 0 } else { 1 },
            Some(on_success),
            (&query as *const SuccessQuery).cast_mut().cast(),
        )
    };
    let applied = wait_for_success(api, connection, operation, &query);
    // SAFETY: balances the lock acquired above.
    unsafe { (api.mainloop_unlock)(connection.mainloop) };
    if !applied {
        return None;
    }
    // SAFETY: state.volume is a valid server-provided pa_cvolume.
    let level = unsafe { (api.cvolume_avg)(&state.volume) } as f64 / 65_536.0;
    Some(level.clamp(0.0, 1.0))
}

fn set_pulse_stream_level(
    api: &PulseApi,
    connection: &PulseConnection,
    stream_id: u32,
    target: f64,
) -> Option<()> {
    let state = query_sink_input(api, connection, stream_id)?;
    let target = target.clamp(0.0, 1.0);
    let mut volume = PaCVolume::default();
    // SAFETY: volume is a complete pa_cvolume and the channel count came from
    // the queried sink-input record.
    unsafe {
        (api.cvolume_set)(
            &mut volume,
            u32::from(state.channels),
            (target * 65_536.0).round() as u32,
        );
        (api.mainloop_lock)(connection.mainloop);
    }
    let volume_query = SuccessQuery {
        mainloop: connection.mainloop,
        signal: api.mainloop_signal,
        state: Mutex::new(SuccessQueryState {
            done: false,
            success: false,
        }),
    };
    // SAFETY: volume remains live through the synchronous wait.
    let operation = unsafe {
        (api.context_set_sink_input_volume)(
            connection.context,
            stream_id,
            &volume,
            Some(on_success),
            (&volume_query as *const SuccessQuery).cast_mut().cast(),
        )
    };
    let applied = wait_for_success(api, connection, operation, &volume_query);
    // SAFETY: balances the lock acquired above.
    unsafe { (api.mainloop_unlock)(connection.mainloop) };
    if !applied {
        return None;
    }

    if target > 0.0 && state.muted {
        // SAFETY: the context operation is serialized by the mainloop lock.
        unsafe { (api.mainloop_lock)(connection.mainloop) };
        let mute_query = SuccessQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SuccessQueryState {
                done: false,
                success: false,
            }),
        };
        // SAFETY: no borrowed callback data escapes the wait.
        let operation = unsafe {
            (api.context_set_sink_input_mute)(
                connection.context,
                stream_id,
                0,
                Some(on_success),
                (&mute_query as *const SuccessQuery).cast_mut().cast(),
            )
        };
        let unmuted = wait_for_success(api, connection, operation, &mute_query);
        // SAFETY: balances the lock acquired above.
        unsafe { (api.mainloop_unlock)(connection.mainloop) };
        if !unmuted {
            return None;
        }
    }
    Some(())
}

pub(super) fn run_audio_worker(
    commands: Receiver<AudioCommand>,
    events: SystemControlEventSender,
    subscription_commands: SyncSender<AudioCommand>,
) {
    let api = match PulseApi::load() {
        Ok(api) => api,
        Err(error) => {
            warn!(%error, "native audio controls are unavailable");
            while !matches!(commands.recv(), Ok(AudioCommand::Stop) | Err(_)) {}
            return;
        }
    };
    let mut connection: Option<PulseConnection> = None;
    let mut failure_latched = false;
    'worker: while let Ok(first) = commands.recv() {
        let mut level = None;
        let mut delta = 0.0;
        let mut toggle_mute = false;
        let mut state_requested = false;
        let mut request_serial = 0;
        let mut streams_requested = false;
        let mut stream_levels = HashMap::<u32, f64>::new();

        let mut absorb = |command: AudioCommand| -> bool {
            match command {
                AudioCommand::ReadLevel => state_requested = true,
                AudioCommand::SetLevel {
                    level: next,
                    request_serial: serial,
                } => {
                    level = Some(next.clamp(0.0, 1.0));
                    delta = 0.0;
                    request_serial = serial;
                    state_requested = true;
                }
                AudioCommand::Adjust(next) => {
                    if let Some(current) = level.as_mut() {
                        *current = (*current + next).clamp(0.0, MAX_AUDIO_LEVEL);
                    } else {
                        delta = (delta + next).clamp(-MAX_AUDIO_LEVEL, MAX_AUDIO_LEVEL);
                    }
                    request_serial = 0;
                    state_requested = true;
                }
                AudioCommand::ToggleMute => {
                    toggle_mute = !toggle_mute;
                    state_requested = true;
                    request_serial = 0;
                }
                AudioCommand::RequestStreams => streams_requested = true,
                AudioCommand::SetStreamLevel { stream_id, level } => {
                    stream_levels.insert(stream_id, level.clamp(0.0, 1.0));
                    streams_requested = true;
                }
                AudioCommand::Stop => return false,
            }
            true
        };

        if !absorb(first) {
            break;
        }
        while let Ok(command) = commands.try_recv() {
            if !absorb(command) {
                break 'worker;
            }
        }
        if connection.is_none() {
            match PulseConnection::connect(&api, subscription_commands.clone()) {
                Ok(active) => connection = Some(active),
                Err(error) => {
                    if !std::mem::replace(&mut failure_latched, true) {
                        warn!(%error, "native audio connection failed");
                    }
                    continue;
                }
            }
        }
        let Some(active) = connection.as_ref() else {
            continue;
        };
        let mut operation_failed = false;
        if let Some(level) = level {
            operation_failed |= set_pulse_level(&api, active, level).is_none();
        }
        if !operation_failed && delta != 0.0 {
            operation_failed |= adjust_pulse_level(&api, active, delta).is_none();
        }
        if !operation_failed && toggle_mute {
            operation_failed |= toggle_pulse_mute(&api, active).is_none();
        }
        if !operation_failed {
            for (stream_id, stream_level) in stream_levels {
                if set_pulse_stream_level(&api, active, stream_id, stream_level).is_none() {
                    // A stream can legitimately disappear between the UI
                    // snapshot and this write. Refresh the list without
                    // discarding the otherwise healthy Pulse connection.
                    streams_requested = true;
                }
            }
        }
        if !operation_failed && state_requested {
            if let Some(level) = read_pulse_level(&api, active) {
                let _ = events.try_send(SystemControlEvent::AudioLevel {
                    level,
                    request_serial,
                });
            } else {
                operation_failed = true;
            }
        }
        if !operation_failed && streams_requested {
            if let Some(streams) = query_sink_inputs(&api, active) {
                let _ = events.try_send(SystemControlEvent::AudioStreams(streams));
            } else {
                operation_failed = true;
            }
        }
        if operation_failed {
            if !std::mem::replace(&mut failure_latched, true) {
                warn!("native PulseAudio operation failed; reconnecting");
            }
            if let Some(mut active) = connection.take() {
                active.close(&api);
            }
        } else {
            failure_latched = false;
        }
    }
    if let Some(mut active) = connection {
        active.close(&api);
    }
}

#[cfg(test)]
#[path = "audio/tests.rs"]
mod tests;
