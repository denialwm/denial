//! Non-blocking GLES timestamp queries used only by the render audit.

use super::*;

const GL_EXTENSIONS: u32 = 0x1f03;
const GL_QUERY_RESULT: u32 = 0x8866;
const GL_QUERY_RESULT_AVAILABLE: u32 = 0x8867;
const GL_TIMESTAMP_EXT: u32 = 0x8e28;
const GL_GPU_DISJOINT_EXT: u32 = 0x8fbb;
const MAX_PENDING_GPU_TIMINGS: usize = 256;

fn extension_list_has(extensions: &str, requested: &str) -> bool {
    extensions
        .split_ascii_whitespace()
        .any(|extension| extension == requested)
}

#[derive(Clone, Copy)]
struct GpuTimerApi {
    gen_queries: unsafe extern "system" fn(i32, *mut u32),
    delete_queries: unsafe extern "system" fn(i32, *const u32),
    query_counter: unsafe extern "system" fn(u32, u32),
    get_query_object_uiv: unsafe extern "system" fn(u32, u32, *mut u32),
    get_query_object_ui64v: unsafe extern "system" fn(u32, u32, *mut u64),
    get_integer_v: unsafe extern "system" fn(u32, *mut i32),
}

impl GpuTimerApi {
    fn load() -> Option<Self> {
        macro_rules! optional_symbol {
            ($name:literal, $kind:ty) => {{
                // SAFETY: the render EGL context is current while the audit
                // timer table is loaded.
                let address = unsafe { get_proc_address($name) };
                if address.is_null() {
                    return None;
                }
                // SAFETY: the signature comes from GL_EXT_disjoint_timer_query.
                unsafe { mem::transmute::<*const c_void, $kind>(address) }
            }};
        }

        let get_string =
            optional_symbol!("glGetString", unsafe extern "system" fn(u32) -> *const u8);
        // SAFETY: GL_EXTENSIONS is queried from the current render context.
        let extensions = unsafe { get_string(GL_EXTENSIONS) };
        if extensions.is_null() {
            return None;
        }
        // SAFETY: GLES owns a NUL-terminated extension string for the
        // lifetime of the current context.
        let extensions = unsafe { CStr::from_ptr(extensions.cast()) }.to_string_lossy();
        if !extension_list_has(&extensions, "GL_EXT_disjoint_timer_query") {
            return None;
        }

        Some(Self {
            gen_queries: optional_symbol!(
                "glGenQueriesEXT",
                unsafe extern "system" fn(i32, *mut u32)
            ),
            delete_queries: optional_symbol!(
                "glDeleteQueriesEXT",
                unsafe extern "system" fn(i32, *const u32)
            ),
            query_counter: optional_symbol!(
                "glQueryCounterEXT",
                unsafe extern "system" fn(u32, u32)
            ),
            get_query_object_uiv: optional_symbol!(
                "glGetQueryObjectuivEXT",
                unsafe extern "system" fn(u32, u32, *mut u32)
            ),
            get_query_object_ui64v: optional_symbol!(
                "glGetQueryObjectui64vEXT",
                unsafe extern "system" fn(u32, u32, *mut u64)
            ),
            get_integer_v: optional_symbol!(
                "glGetIntegerv",
                unsafe extern "system" fn(u32, *mut i32)
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::extension_list_has;

    #[test]
    fn timer_extension_detection_requires_an_exact_token() {
        assert!(extension_list_has(
            "GL_EXT_texture GL_EXT_disjoint_timer_query GL_EXT_sync",
            "GL_EXT_disjoint_timer_query"
        ));
        assert!(!extension_list_has(
            "GL_EXT_disjoint_timer_query_webgl2 GL_EXT_sync",
            "GL_EXT_disjoint_timer_query"
        ));
    }
}

#[derive(Clone, Copy, Debug)]
struct GpuTimestampSet {
    start: u32,
    flutter_end: u32,
    end: u32,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct GpuRenderTiming {
    pub(super) flutter: Duration,
    pub(super) scanout_blit: Duration,
    pub(super) frame: Duration,
}

#[derive(Debug, Default)]
pub(super) struct GpuTimingUpdate {
    pub(super) completed: Vec<GpuRenderTiming>,
    pub(super) disjoint: u64,
    pub(super) abandoned: u64,
    pub(super) pending: usize,
}

pub(super) struct GpuTimingState {
    api: GpuTimerApi,
    active: HashMap<u32, GpuTimestampSet>,
    pending: VecDeque<GpuTimestampSet>,
    abandoned_since_poll: u64,
}

impl GpuTimingState {
    pub(super) fn load() -> Option<Self> {
        Some(Self {
            api: GpuTimerApi::load()?,
            active: HashMap::new(),
            pending: VecDeque::new(),
            abandoned_since_poll: 0,
        })
    }

    pub(super) fn begin(&mut self, framebuffer: u32) {
        if let Some(previous) = self.active.remove(&framebuffer) {
            self.delete(previous);
            self.abandoned_since_poll = self.abandoned_since_poll.saturating_add(1);
        }
        let mut queries = [0; 3];
        // SAFETY: the raster context is current and `queries` contains storage
        // for exactly three query names.
        unsafe { (self.api.gen_queries)(3, queries.as_mut_ptr()) };
        let timestamps = GpuTimestampSet {
            start: queries[0],
            flutter_end: queries[1],
            end: queries[2],
        };
        if timestamps.start == 0 || timestamps.flutter_end == 0 || timestamps.end == 0 {
            self.delete(timestamps);
            self.abandoned_since_poll = self.abandoned_since_poll.saturating_add(1);
            return;
        }
        // QueryCounter inserts a marker without starting an elapsed-time
        // query, so it cannot nest with Skia's own optional timer queries.
        // SAFETY: the generated query is live in the current context.
        unsafe { (self.api.query_counter)(timestamps.start, GL_TIMESTAMP_EXT) };
        self.active.insert(framebuffer, timestamps);
    }

    pub(super) fn mark_flutter_complete(&mut self, framebuffer: u32) {
        let Some(timestamps) = self.active.get(&framebuffer) else {
            return;
        };
        // SAFETY: Flutter has submitted its output work before entering the
        // present callback, and this live marker follows it in the same GLES
        // context. Denial's optional scanout blit has not been issued yet.
        unsafe {
            (self.api.query_counter)(timestamps.flutter_end, GL_TIMESTAMP_EXT);
        }
    }

    pub(super) fn finish(&mut self, framebuffer: u32) {
        let Some(timestamps) = self.active.remove(&framebuffer) else {
            return;
        };
        // SAFETY: this marker is inserted after Skia rendering and Denial's
        // final scanout blit in the same current context.
        unsafe { (self.api.query_counter)(timestamps.end, GL_TIMESTAMP_EXT) };
        self.pending.push_back(timestamps);
        while self.pending.len() > MAX_PENDING_GPU_TIMINGS {
            if let Some(stale) = self.pending.pop_front() {
                self.delete(stale);
                self.abandoned_since_poll = self.abandoned_since_poll.saturating_add(1);
            }
        }
    }

    pub(super) fn poll(&mut self) -> GpuTimingUpdate {
        let mut update = GpuTimingUpdate {
            abandoned: mem::take(&mut self.abandoned_since_poll),
            ..GpuTimingUpdate::default()
        };
        let mut disjoint = 0;
        // SAFETY: the raster context is current and the output pointer is
        // valid. Reading the flag acknowledges any clock discontinuity.
        unsafe { (self.api.get_integer_v)(GL_GPU_DISJOINT_EXT, &mut disjoint) };
        if disjoint != 0 {
            update.disjoint = self.pending.len() as u64;
            while let Some(timestamps) = self.pending.pop_front() {
                self.delete(timestamps);
            }
            update.pending = self.pending.len();
            return update;
        }

        while let Some(timestamps) = self.pending.front().copied() {
            let mut available = 0;
            // SAFETY: the query remains live and the output pointer is valid.
            unsafe {
                (self.api.get_query_object_uiv)(
                    timestamps.end,
                    GL_QUERY_RESULT_AVAILABLE,
                    &mut available,
                )
            };
            if available == 0 {
                break;
            }
            let _ = self.pending.pop_front();
            let mut start = 0;
            let mut flutter_end = 0;
            let mut end = 0;
            // Availability of the later marker guarantees both results can be
            // read without waiting on the GPU.
            // SAFETY: both query names are live and the outputs are valid.
            unsafe {
                (self.api.get_query_object_ui64v)(timestamps.start, GL_QUERY_RESULT, &mut start);
                (self.api.get_query_object_ui64v)(
                    timestamps.flutter_end,
                    GL_QUERY_RESULT,
                    &mut flutter_end,
                );
                (self.api.get_query_object_ui64v)(timestamps.end, GL_QUERY_RESULT, &mut end);
            }
            if end >= flutter_end && flutter_end >= start {
                update.completed.push(GpuRenderTiming {
                    flutter: Duration::from_nanos(flutter_end.saturating_sub(start)),
                    scanout_blit: Duration::from_nanos(end.saturating_sub(flutter_end)),
                    frame: Duration::from_nanos(end.saturating_sub(start)),
                });
            } else {
                update.disjoint = update.disjoint.saturating_add(1);
            }
            self.delete(timestamps);
        }
        update.pending = self.pending.len();
        update
    }

    pub(super) fn clear(&mut self) {
        let active = self
            .active
            .drain()
            .map(|(_, timestamps)| timestamps)
            .collect::<Vec<_>>();
        for timestamps in active {
            self.delete(timestamps);
        }
        while let Some(timestamps) = self.pending.pop_front() {
            self.delete(timestamps);
        }
    }

    fn delete(&self, timestamps: GpuTimestampSet) {
        let queries = [timestamps.start, timestamps.flutter_end, timestamps.end];
        let count = queries.iter().filter(|query| **query != 0).count() as i32;
        if count == 0 {
            return;
        }
        if count == 3 {
            // SAFETY: all three adjacent names were generated together and have
            // not previously been deleted.
            unsafe { (self.api.delete_queries)(3, queries.as_ptr()) };
        } else {
            for query in queries.into_iter().filter(|query| *query != 0) {
                // SAFETY: every non-zero name is a generated live query.
                unsafe { (self.api.delete_queries)(1, &query) };
            }
        }
    }
}
