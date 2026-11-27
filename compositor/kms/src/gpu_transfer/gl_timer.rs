//! Optional audit timestamps. Results never add a completion wait.
use super::*;

pub(super) struct GlTimer {
    queries: [u32; 2],
    counter: unsafe extern "system" fn(u32, u32),
    result: unsafe extern "system" fn(u32, u32, *mut u64),
    available: unsafe extern "system" fn(u32, u32, *mut u32),
    delete: unsafe extern "system" fn(i32, *const u32),
}
impl GlTimer {
    pub(super) fn load(gl: &gl::Gles2) -> Option<Self> {
        // SAFETY: owning destination context is current; driver owns this string.
        let extensions = unsafe { gl.GetString(gl::EXTENSIONS) };
        if extensions.is_null() {
            return None;
        }
        // SAFETY: non-null driver-owned NUL-terminated GL string.
        if !unsafe { CStr::from_ptr(extensions.cast()) }
            .to_string_lossy()
            .split_ascii_whitespace()
            .any(|e| e == "GL_EXT_disjoint_timer_query")
        {
            return None;
        }
        macro_rules! symbol {
            ($name:literal, $signature:ty) => {{
                // SAFETY: current EGL context, valid static symbol name.
                let p = unsafe { get_proc_address($name) };
                if p.is_null() {
                    return None;
                }
                // SAFETY: signatures specified by GL_EXT_disjoint_timer_query.
                unsafe { std::mem::transmute::<*const std::ffi::c_void, $signature>(p) }
            }};
        }
        let generate = symbol!("glGenQueriesEXT", unsafe extern "system" fn(i32, *mut u32));
        let mut timer = Self {
            queries: [0; 2],
            counter: symbol!("glQueryCounterEXT", unsafe extern "system" fn(u32, u32)),
            result: symbol!(
                "glGetQueryObjectui64vEXT",
                unsafe extern "system" fn(u32, u32, *mut u64)
            ),
            available: symbol!(
                "glGetQueryObjectuivEXT",
                unsafe extern "system" fn(u32, u32, *mut u32)
            ),
            delete: symbol!(
                "glDeleteQueriesEXT",
                unsafe extern "system" fn(i32, *const u32)
            ),
        };
        // SAFETY: two writable query names in the current context.
        unsafe {
            generate(2, timer.queries.as_mut_ptr());
        }
        if timer.queries.contains(&0) {
            return None;
        }
        Some(timer)
    }
    pub(super) fn begin(&self, gl: &gl::Gles2) {
        let mut disjoint = 0;
        // SAFETY: valid query and output on its owning current context.
        unsafe {
            gl.GetIntegerv(0x8fbb, &mut disjoint);
            (self.counter)(self.queries[0], 0x8e28);
        }
    }
    pub(super) fn end(&self) {
        // SAFETY: allocated query on its owning current context.
        unsafe {
            (self.counter)(self.queries[1], 0x8e28);
        }
    }
    pub(super) fn read(&self, gl: &gl::Gles2) -> Option<f64> {
        let mut disjoint = 0;
        let mut available = 0;
        // SAFETY: valid output storage; completion was already checked, but
        // availability is checked separately to avoid any audit-induced wait.
        unsafe {
            gl.GetIntegerv(0x8fbb, &mut disjoint);
            (self.available)(self.queries[1], 0x8867, &mut available);
        }
        if disjoint != 0 || available == 0 {
            return None;
        }
        let mut start = 0;
        let mut end = 0;
        // SAFETY: later marker available, both live queries can be read without waiting.
        unsafe {
            (self.result)(self.queries[0], 0x8866, &mut start);
            (self.result)(self.queries[1], 0x8866, &mut end);
        }
        end.checked_sub(start).map(|ns| ns as f64 / 1000.0)
    }
}
impl Drop for GlTimer {
    fn drop(&mut self) {
        // SAFETY: Destination drops the timer before unbinding its owning context.
        unsafe {
            (self.delete)(2, self.queries.as_ptr());
        }
    }
}
