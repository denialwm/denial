//! Small native GLES client-tree pass. No Flutter scene or shell effects.
//!
//! Called only with the owning raster context current, after the embedder's
//! external-texture contract flushes Impeller. Unchanged client trees reuse
//! their result without entering this pass. Input and destination ownership
//! must extend through the actual reader/writer fence, independently of Rust
//! call return. All modified GLES state is restored before returning.

use std::ffi::{CStr, c_char, c_void};

use super::native_window::NativeWindowPlan;

const TEXTURE_2D: u32 = 0x0DE1;
const TEXTURE0: u32 = 0x84C0;
const DRAW_FRAMEBUFFER: u32 = 0x8CA9;
const COLOR_ATTACHMENT0: u32 = 0x8CE0;
const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const CAPS: [u32; 7] = [0x0BE2, 0x0B44, 0x0B71, 0x0C11, 0x0B90, 0x8C89, 0x0BD0];

#[derive(Clone, Copy)]
struct WindowGlApi {
    gen_framebuffers: unsafe extern "system" fn(i32, *mut u32),
    delete_framebuffers: unsafe extern "system" fn(i32, *const u32),
    bind_framebuffer: unsafe extern "system" fn(u32, u32),
    framebuffer_texture_2d: unsafe extern "system" fn(u32, u32, u32, u32, i32),
    check_framebuffer_status: unsafe extern "system" fn(u32) -> u32,
    create_shader: unsafe extern "system" fn(u32) -> u32,
    shader_source: unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32),
    compile_shader: unsafe extern "system" fn(u32),
    get_shader_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    get_shader_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    delete_shader: unsafe extern "system" fn(u32),
    create_program: unsafe extern "system" fn() -> u32,
    attach_shader: unsafe extern "system" fn(u32, u32),
    link_program: unsafe extern "system" fn(u32),
    get_program_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    get_program_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    delete_program: unsafe extern "system" fn(u32),
    use_program: unsafe extern "system" fn(u32),
    get_uniform_location: unsafe extern "system" fn(u32, *const c_char) -> i32,
    uniform_1i: unsafe extern "system" fn(i32, i32),
    uniform_1f: unsafe extern "system" fn(i32, f32),
    uniform_2f: unsafe extern "system" fn(i32, f32, f32),
    uniform_4fv: unsafe extern "system" fn(i32, i32, *const f32),
    gen_samplers: unsafe extern "system" fn(i32, *mut u32),
    delete_samplers: unsafe extern "system" fn(i32, *const u32),
    sampler_parameter_i: unsafe extern "system" fn(u32, u32, i32),
    bind_sampler: unsafe extern "system" fn(u32, u32),
    active_texture: unsafe extern "system" fn(u32),
    bind_texture: unsafe extern "system" fn(u32, u32),
    viewport: unsafe extern "system" fn(i32, i32, i32, i32),
    get_integer_v: unsafe extern "system" fn(u32, *mut i32),
    get_boolean_v: unsafe extern "system" fn(u32, *mut u8),
    is_enabled: unsafe extern "system" fn(u32) -> u8,
    enable: unsafe extern "system" fn(u32),
    disable: unsafe extern "system" fn(u32),
    color_mask: unsafe extern "system" fn(u8, u8, u8, u8),
    blend_func_separate: unsafe extern "system" fn(u32, u32, u32, u32),
    blend_equation_separate: unsafe extern "system" fn(u32, u32),
    clear_buffer_fv: unsafe extern "system" fn(u32, i32, *const f32),
    draw_arrays: unsafe extern "system" fn(u32, i32, i32),
    get_error: unsafe extern "system" fn() -> u32,
}

impl WindowGlApi {
    fn load(mut resolve: impl FnMut(&CStr) -> *const c_void) -> Result<Self, String> {
        macro_rules! load {
            ($name:literal, $ty:ty) => {{
                let name = CStr::from_bytes_with_nul(concat!($name, "\0").as_bytes()).unwrap();
                let address = resolve(name);
                if address.is_null() {
                    return Err(format!("native window GLES symbol unavailable: {}", $name));
                }
                // SAFETY: each signature is the corresponding GLES3 header ABI.
                unsafe { std::mem::transmute::<*const c_void, $ty>(address) }
            }};
        }
        Ok(Self {
            gen_framebuffers: load!(
                "glGenFramebuffers",
                unsafe extern "system" fn(i32, *mut u32)
            ),
            delete_framebuffers: load!(
                "glDeleteFramebuffers",
                unsafe extern "system" fn(i32, *const u32)
            ),
            bind_framebuffer: load!("glBindFramebuffer", unsafe extern "system" fn(u32, u32)),
            framebuffer_texture_2d: load!(
                "glFramebufferTexture2D",
                unsafe extern "system" fn(u32, u32, u32, u32, i32)
            ),
            check_framebuffer_status: load!(
                "glCheckFramebufferStatus",
                unsafe extern "system" fn(u32) -> u32
            ),
            create_shader: load!("glCreateShader", unsafe extern "system" fn(u32) -> u32),
            shader_source: load!(
                "glShaderSource",
                unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32)
            ),
            compile_shader: load!("glCompileShader", unsafe extern "system" fn(u32)),
            get_shader_iv: load!(
                "glGetShaderiv",
                unsafe extern "system" fn(u32, u32, *mut i32)
            ),
            get_shader_info_log: load!(
                "glGetShaderInfoLog",
                unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char)
            ),
            delete_shader: load!("glDeleteShader", unsafe extern "system" fn(u32)),
            create_program: load!("glCreateProgram", unsafe extern "system" fn() -> u32),
            attach_shader: load!("glAttachShader", unsafe extern "system" fn(u32, u32)),
            link_program: load!("glLinkProgram", unsafe extern "system" fn(u32)),
            get_program_iv: load!(
                "glGetProgramiv",
                unsafe extern "system" fn(u32, u32, *mut i32)
            ),
            get_program_info_log: load!(
                "glGetProgramInfoLog",
                unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char)
            ),
            delete_program: load!("glDeleteProgram", unsafe extern "system" fn(u32)),
            use_program: load!("glUseProgram", unsafe extern "system" fn(u32)),
            get_uniform_location: load!(
                "glGetUniformLocation",
                unsafe extern "system" fn(u32, *const c_char) -> i32
            ),
            uniform_1i: load!("glUniform1i", unsafe extern "system" fn(i32, i32)),
            uniform_1f: load!("glUniform1f", unsafe extern "system" fn(i32, f32)),
            uniform_2f: load!("glUniform2f", unsafe extern "system" fn(i32, f32, f32)),
            uniform_4fv: load!(
                "glUniform4fv",
                unsafe extern "system" fn(i32, i32, *const f32)
            ),
            gen_samplers: load!("glGenSamplers", unsafe extern "system" fn(i32, *mut u32)),
            delete_samplers: load!(
                "glDeleteSamplers",
                unsafe extern "system" fn(i32, *const u32)
            ),
            sampler_parameter_i: load!(
                "glSamplerParameteri",
                unsafe extern "system" fn(u32, u32, i32)
            ),
            bind_sampler: load!("glBindSampler", unsafe extern "system" fn(u32, u32)),
            active_texture: load!("glActiveTexture", unsafe extern "system" fn(u32)),
            bind_texture: load!("glBindTexture", unsafe extern "system" fn(u32, u32)),
            viewport: load!("glViewport", unsafe extern "system" fn(i32, i32, i32, i32)),
            get_integer_v: load!("glGetIntegerv", unsafe extern "system" fn(u32, *mut i32)),
            get_boolean_v: load!("glGetBooleanv", unsafe extern "system" fn(u32, *mut u8)),
            is_enabled: load!("glIsEnabled", unsafe extern "system" fn(u32) -> u8),
            enable: load!("glEnable", unsafe extern "system" fn(u32)),
            disable: load!("glDisable", unsafe extern "system" fn(u32)),
            color_mask: load!("glColorMask", unsafe extern "system" fn(u8, u8, u8, u8)),
            blend_func_separate: load!(
                "glBlendFuncSeparate",
                unsafe extern "system" fn(u32, u32, u32, u32)
            ),
            blend_equation_separate: load!(
                "glBlendEquationSeparate",
                unsafe extern "system" fn(u32, u32)
            ),
            clear_buffer_fv: load!(
                "glClearBufferfv",
                unsafe extern "system" fn(u32, i32, *const f32)
            ),
            draw_arrays: load!("glDrawArrays", unsafe extern "system" fn(u32, i32, i32)),
            get_error: load!("glGetError", unsafe extern "system" fn() -> u32),
        })
    }

    fn shader(self, kind: u32, source: &'static CStr) -> Result<u32, String> {
        // SAFETY: caller created this API for its current live GLES context.
        unsafe {
            let shader = (self.create_shader)(kind);
            if shader == 0 {
                return Err("native window shader allocation failed".into());
            }
            (self.shader_source)(shader, 1, &source.as_ptr(), std::ptr::null());
            (self.compile_shader)(shader);
            let mut okay = 0;
            (self.get_shader_iv)(shader, 0x8B81, &mut okay);
            if okay == 0 {
                let mut bytes = [0_u8; 8192];
                let mut written = 0;
                (self.get_shader_info_log)(
                    shader,
                    bytes.len() as i32,
                    &mut written,
                    bytes.as_mut_ptr().cast(),
                );
                (self.delete_shader)(shader);
                return Err(format!(
                    "native window shader: {}",
                    String::from_utf8_lossy(&bytes[..(written.max(0) as usize).min(bytes.len())])
                ));
            }
            Ok(shader)
        }
    }
}

const VERTEX: &CStr = c"#version 300 es
precision highp float;
uniform vec4 positions[2];
uniform vec4 coordinates[2];
uniform vec2 output_size;
out highp vec2 uv;
void main() {
  int pair = gl_VertexID / 2;
  vec2 p = (gl_VertexID % 2 == 0) ? positions[pair].xy : positions[pair].zw;
  uv = (gl_VertexID % 2 == 0) ? coordinates[pair].xy : coordinates[pair].zw;
  gl_Position = vec4(p / output_size * 2.0 - 1.0, 0.0, 1.0);
}";
const FRAGMENT: &CStr = c"#version 300 es
precision highp float;
uniform sampler2D client;
uniform vec4 source_limits;
uniform float opacity;
in highp vec2 uv;
out vec4 color;
void main() {
  if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) discard;
  color = texture(client, clamp(uv, source_limits.xy, source_limits.zw)) * opacity;
}";

struct GlState {
    framebuffer: i32,
    program: i32,
    active_texture: i32,
    texture: i32,
    sampler: i32,
    viewport: [i32; 4],
    mask: [u8; 4],
    caps: [bool; 7],
    blend: [i32; 6],
}

impl GlState {
    fn capture(gl: WindowGlApi) -> Self {
        let mut state = Self {
            framebuffer: 0,
            program: 0,
            active_texture: 0,
            texture: 0,
            sampler: 0,
            viewport: [0; 4],
            mask: [0; 4],
            caps: [false; 7],
            blend: [0; 6],
        };
        // SAFETY: all query outputs have the size required by GLES3.
        unsafe {
            (gl.get_integer_v)(0x8CA6, &mut state.framebuffer);
            (gl.get_integer_v)(0x8B8D, &mut state.program);
            (gl.get_integer_v)(0x84E0, &mut state.active_texture);
            (gl.get_integer_v)(0x0BA2, state.viewport.as_mut_ptr());
            (gl.get_boolean_v)(0x0C23, state.mask.as_mut_ptr());
            for (saved, cap) in state.caps.iter_mut().zip(CAPS) {
                *saved = (gl.is_enabled)(cap) != 0;
            }
            for (saved, name) in state
                .blend
                .iter_mut()
                .zip([0x80C9, 0x80C8, 0x80CB, 0x80CA, 0x8009, 0x883D])
            {
                (gl.get_integer_v)(name, saved);
            }
            (gl.active_texture)(TEXTURE0);
            (gl.get_integer_v)(0x8069, &mut state.texture);
            (gl.get_integer_v)(0x8919, &mut state.sampler);
        }
        state
    }

    fn restore(&self, gl: WindowGlApi) {
        // SAFETY: values came from this same current context before the pass.
        unsafe {
            (gl.use_program)(self.program as u32);
            (gl.bind_texture)(TEXTURE_2D, self.texture as u32);
            (gl.bind_sampler)(0, self.sampler as u32);
            (gl.active_texture)(self.active_texture as u32);
            (gl.bind_framebuffer)(DRAW_FRAMEBUFFER, self.framebuffer as u32);
            (gl.viewport)(
                self.viewport[0],
                self.viewport[1],
                self.viewport[2],
                self.viewport[3],
            );
            (gl.color_mask)(self.mask[0], self.mask[1], self.mask[2], self.mask[3]);
            (gl.blend_func_separate)(
                self.blend[0] as u32,
                self.blend[1] as u32,
                self.blend[2] as u32,
                self.blend[3] as u32,
            );
            (gl.blend_equation_separate)(self.blend[4] as u32, self.blend[5] as u32);
            for (enabled, cap) in self.caps.iter().zip(CAPS) {
                if *enabled {
                    (gl.enable)(cap);
                } else {
                    (gl.disable)(cap);
                }
            }
        }
    }
}

#[derive(Clone, Copy)]
pub(super) struct NativeWindowInput {
    pub(super) texture_id: i64,
    pub(super) name: u32,
    pub(super) size: [u32; 2],
}

pub(super) struct NativeWindowGl {
    gl: WindowGlApi,
    program: u32,
    framebuffer: u32,
    sampler: u32,
    positions: i32,
    coordinates: i32,
    output_size: i32,
    client: i32,
    limits: i32,
    opacity: i32,
}

impl NativeWindowGl {
    /// The resolver and every later operation must use the same share group.
    pub(super) fn new(resolve: impl FnMut(&CStr) -> *const c_void) -> Result<Self, String> {
        let gl = WindowGlApi::load(resolve)?;
        let vertex = gl.shader(0x8B31, VERTEX)?;
        let fragment = match gl.shader(0x8B30, FRAGMENT) {
            Ok(fragment) => fragment,
            Err(error) => {
                unsafe { (gl.delete_shader)(vertex) };
                return Err(error);
            }
        };
        // SAFETY: owning GLES context is current; each object is created once.
        let program = unsafe {
            let program = (gl.create_program)();
            (gl.attach_shader)(program, vertex);
            (gl.attach_shader)(program, fragment);
            (gl.link_program)(program);
            (gl.delete_shader)(vertex);
            (gl.delete_shader)(fragment);
            program
        };
        let mut linked = 0;
        unsafe { (gl.get_program_iv)(program, 0x8B82, &mut linked) };
        if linked == 0 {
            let mut bytes = [0_u8; 8192];
            let mut written = 0;
            unsafe {
                (gl.get_program_info_log)(
                    program,
                    bytes.len() as i32,
                    &mut written,
                    bytes.as_mut_ptr().cast(),
                );
                (gl.delete_program)(program);
            }
            return Err(format!(
                "native window program: {}",
                String::from_utf8_lossy(&bytes[..(written.max(0) as usize).min(bytes.len())])
            ));
        }
        let mut framebuffer = 0;
        let mut sampler = 0;
        unsafe {
            (gl.gen_framebuffers)(1, &mut framebuffer);
            (gl.gen_samplers)(1, &mut sampler);
            for (key, value) in [
                (0x2801, 0x2601),
                (0x2800, 0x2601),
                (0x2802, 0x812F),
                (0x2803, 0x812F),
            ] {
                (gl.sampler_parameter_i)(sampler, key, value);
            }
        }
        let location = |name: &CStr| unsafe { (gl.get_uniform_location)(program, name.as_ptr()) };
        let mut result = Self {
            gl,
            program,
            framebuffer,
            sampler,
            positions: location(c"positions[0]"),
            coordinates: location(c"coordinates[0]"),
            output_size: location(c"output_size"),
            client: location(c"client"),
            limits: location(c"source_limits"),
            opacity: location(c"opacity"),
        };
        let error = unsafe { (gl.get_error)() };
        if framebuffer == 0
            || sampler == 0
            || error != 0
            || [
                result.positions,
                result.coordinates,
                result.output_size,
                result.client,
                result.limits,
                result.opacity,
            ]
            .contains(&-1)
        {
            result.destroy();
            return Err(format!("native window GLES setup failed: 0x{error:x}"));
        }
        Ok(result)
    }

    pub(super) fn validate_target(&mut self, name: u32) -> Result<(), String> {
        let gl = self.gl;
        let mut previous = 0;
        unsafe {
            (gl.get_integer_v)(0x8CA6, &mut previous);
            (gl.bind_framebuffer)(DRAW_FRAMEBUFFER, self.framebuffer);
            (gl.framebuffer_texture_2d)(DRAW_FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, name, 0);
        }
        let status = unsafe { (gl.check_framebuffer_status)(DRAW_FRAMEBUFFER) };
        unsafe {
            (gl.framebuffer_texture_2d)(DRAW_FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, 0, 0);
            (gl.bind_framebuffer)(DRAW_FRAMEBUFFER, previous as u32);
        }
        let error = unsafe { (gl.get_error)() };
        if name == 0 || status != FRAMEBUFFER_COMPLETE || error != 0 {
            Err(format!(
                "native target FBO status {status:#x}, GLES {error:#x}"
            ))
        } else {
            Ok(())
        }
    }

    pub(super) fn render(
        &mut self,
        plan: &NativeWindowPlan,
        inputs: &[NativeWindowInput],
        output_texture: u32,
    ) -> Result<usize, String> {
        if self.program == 0
            || output_texture == 0
            || inputs.len() != plan.layers.len()
            || inputs.iter().zip(&plan.layers).any(|(input, layer)| {
                input.texture_id != layer.texture_id
                    || input.name == 0
                    || input.name == output_texture
                    || input.size.contains(&0)
            })
        {
            return Err("invalid native window draw inputs".into());
        }
        // Calculate every safe draw before changing context state.
        let mut draws = Vec::with_capacity(inputs.len());
        for (input, layer) in inputs.iter().zip(&plan.layers) {
            let Some(vertices) = plan.vertices(layer, input.size) else {
                continue;
            };
            let Some(limits) = layer.sample_limits(input.size) else {
                continue;
            };
            let positions: [f32; 8] =
                std::array::from_fn(|index| vertices[index / 2].position[index % 2]);
            let coordinates: [f32; 8] =
                std::array::from_fn(|index| vertices[index / 2].uv[index % 2]);
            draws.push((*input, positions, coordinates, limits, layer.opacity));
        }
        let gl = self.gl;
        let saved = GlState::capture(gl);
        let status;
        // SAFETY: caller retains all input/output texture objects in this
        // current context; uniform arrays contain eight/four live floats.
        unsafe {
            (gl.bind_framebuffer)(DRAW_FRAMEBUFFER, self.framebuffer);
            (gl.framebuffer_texture_2d)(
                DRAW_FRAMEBUFFER,
                COLOR_ATTACHMENT0,
                TEXTURE_2D,
                output_texture,
                0,
            );
            status = (gl.check_framebuffer_status)(DRAW_FRAMEBUFFER);
            if status == FRAMEBUFFER_COMPLETE {
                (gl.viewport)(0, 0, plan.width as i32, plan.height as i32);
                for cap in CAPS {
                    (gl.disable)(cap);
                }
                (gl.color_mask)(1, 1, 1, 1);
                (gl.clear_buffer_fv)(0x1800, 0, [0.0_f32; 4].as_ptr());
                (gl.enable)(0x0BE2);
                (gl.blend_func_separate)(1, 0x0303, 1, 0x0303);
                (gl.blend_equation_separate)(0x8006, 0x8006);
                (gl.use_program)(self.program);
                (gl.active_texture)(TEXTURE0);
                (gl.bind_sampler)(0, self.sampler);
                (gl.uniform_1i)(self.client, 0);
                (gl.uniform_2f)(self.output_size, plan.width as f32, plan.height as f32);
                for (input, positions, coordinates, limits, opacity) in &draws {
                    (gl.bind_texture)(TEXTURE_2D, input.name);
                    (gl.uniform_4fv)(self.positions, 2, positions.as_ptr());
                    (gl.uniform_4fv)(self.coordinates, 2, coordinates.as_ptr());
                    (gl.uniform_4fv)(self.limits, 1, limits.as_ptr());
                    (gl.uniform_1f)(self.opacity, *opacity);
                    (gl.draw_arrays)(0x0005, 0, 4);
                }
            }
            // A retained FBO attachment must never extend storage lifetime
            // past the cache/image/reader-fence owners used for byte accounting.
            (gl.framebuffer_texture_2d)(DRAW_FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, 0, 0);
        }
        let draw_error = unsafe { (gl.get_error)() };
        saved.restore(gl);
        let restore_error = unsafe { (gl.get_error)() };
        if status != FRAMEBUFFER_COMPLETE || draw_error != 0 || restore_error != 0 {
            return Err(format!(
                "native window draw failed: FBO=0x{status:x} draw=0x{draw_error:x} restore=0x{restore_error:x}"
            ));
        }
        Ok(draws.len())
    }

    /// Explicit cleanup; never issue GLES calls from an arbitrary Rust Drop.
    pub(super) fn destroy(&mut self) {
        unsafe {
            if self.framebuffer != 0 {
                (self.gl.delete_framebuffers)(1, &self.framebuffer);
                self.framebuffer = 0;
            }
            if self.sampler != 0 {
                (self.gl.delete_samplers)(1, &self.sampler);
                self.sampler = 0;
            }
            if self.program != 0 {
                (self.gl.delete_program)(self.program);
                self.program = 0;
            }
        }
    }
}
