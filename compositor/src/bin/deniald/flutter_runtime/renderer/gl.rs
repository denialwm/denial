//! Shared EGL context ownership and GLES object lifetimes.

use super::*;

pub(super) struct ContextBinding {
    pub(super) context: egl_context::SharedEglContext,
    pub(super) owner: Option<ThreadId>,
}

impl ContextBinding {
    pub(super) fn new(context: egl_context::SharedEglContext) -> Self {
        Self {
            context,
            owner: None,
        }
    }

    pub(super) fn make_current(&mut self) -> bool {
        let thread = thread::current().id();
        if self.owner.is_some_and(|owner| owner != thread) {
            error!("refusing to bind an EGL context still owned by another thread");
            return false;
        }
        // SAFETY: ownership above prevents the context from becoming current
        // on two threads. Flutter later releases it through clear_current().
        match unsafe { self.context.make_current() } {
            Ok(()) => {
                self.owner = Some(thread);
                true
            }
            Err(error) => {
                error!(%error, "could not make Flutter EGL context current");
                false
            }
        }
    }

    pub(super) fn clear_current(&mut self) -> bool {
        let thread = thread::current().id();
        if self.owner.is_some_and(|owner| owner != thread) {
            error!("refusing to unbind a Flutter EGL context from the wrong thread");
            return false;
        }
        match self.context.unbind() {
            Ok(()) => {
                self.owner = None;
                true
            }
            Err(error) => {
                error!(%error, "could not clear Flutter EGL context");
                false
            }
        }
    }
}

#[derive(Clone, Copy)]
pub(super) struct GlApi {
    pub(super) gen_textures: unsafe extern "system" fn(i32, *mut u32),
    pub(super) bind_texture: unsafe extern "system" fn(u32, u32),
    pub(super) tex_parameter_i: unsafe extern "system" fn(u32, u32, i32),
    pub(super) tex_image_2d:
        unsafe extern "system" fn(u32, i32, i32, i32, i32, i32, u32, u32, *const c_void),
    pub(super) image_target_texture: unsafe extern "system" fn(u32, *const c_void),
    pub(super) delete_textures: unsafe extern "system" fn(i32, *const u32),
    pub(super) gen_framebuffers: unsafe extern "system" fn(i32, *mut u32),
    pub(super) bind_framebuffer: unsafe extern "system" fn(u32, u32),
    pub(super) framebuffer_texture_2d: unsafe extern "system" fn(u32, u32, u32, u32, i32),
    pub(super) check_framebuffer_status: unsafe extern "system" fn(u32) -> u32,
    pub(super) create_shader: unsafe extern "system" fn(u32) -> u32,
    pub(super) shader_source: unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32),
    pub(super) compile_shader: unsafe extern "system" fn(u32),
    pub(super) get_shader_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    pub(super) get_shader_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    pub(super) delete_shader: unsafe extern "system" fn(u32),
    pub(super) create_program: unsafe extern "system" fn() -> u32,
    pub(super) attach_shader: unsafe extern "system" fn(u32, u32),
    pub(super) link_program: unsafe extern "system" fn(u32),
    pub(super) get_program_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    pub(super) get_program_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    pub(super) delete_program: unsafe extern "system" fn(u32),
    pub(super) use_program: unsafe extern "system" fn(u32),
    pub(super) get_uniform_location: unsafe extern "system" fn(u32, *const c_char) -> i32,
    pub(super) uniform_1i: unsafe extern "system" fn(i32, i32),
    pub(super) active_texture: unsafe extern "system" fn(u32),
    pub(super) enable: unsafe extern "system" fn(u32),
    pub(super) disable: unsafe extern "system" fn(u32),
    pub(super) is_enabled: unsafe extern "system" fn(u32) -> u8,
    pub(super) get_boolean_v: unsafe extern "system" fn(u32, *mut u8),
    pub(super) color_mask: unsafe extern "system" fn(u8, u8, u8, u8),
    pub(super) draw_arrays: unsafe extern "system" fn(u32, i32, i32),
    pub(super) delete_framebuffers: unsafe extern "system" fn(i32, *const u32),
    pub(super) gen_renderbuffers: unsafe extern "system" fn(i32, *mut u32),
    pub(super) bind_renderbuffer: unsafe extern "system" fn(u32, u32),
    pub(super) renderbuffer_storage: unsafe extern "system" fn(u32, u32, i32, i32),
    pub(super) framebuffer_renderbuffer: unsafe extern "system" fn(u32, u32, u32, u32),
    pub(super) delete_renderbuffers: unsafe extern "system" fn(i32, *const u32),
    pub(super) get_integer_v: unsafe extern "system" fn(u32, *mut i32),
    pub(super) viewport: unsafe extern "system" fn(i32, i32, i32, i32),
    pub(super) get_error: unsafe extern "system" fn() -> u32,
    pub(super) flush: unsafe extern "system" fn(),
    pub(super) finish: unsafe extern "system" fn(),
}

impl GlApi {
    pub(super) fn load() -> Result<Self, Box<dyn Error>> {
        macro_rules! symbol {
            ($name:literal, $kind:ty) => {{
                // SAFETY: an EGL context is current while this table is built.
                let address = unsafe { get_proc_address($name) };
                if address.is_null() {
                    return Err(format!("required OpenGL symbol {} is unavailable", $name).into());
                }
                // SAFETY: each concrete signature below comes from GLES2/EGL
                // headers and the symbol was resolved from the active driver.
                unsafe { mem::transmute::<*const c_void, $kind>(address) }
            }};
        }

        Ok(Self {
            gen_textures: symbol!("glGenTextures", unsafe extern "system" fn(i32, *mut u32)),
            bind_texture: symbol!("glBindTexture", unsafe extern "system" fn(u32, u32)),
            tex_parameter_i: symbol!("glTexParameteri", unsafe extern "system" fn(u32, u32, i32)),
            tex_image_2d: symbol!(
                "glTexImage2D",
                unsafe extern "system" fn(u32, i32, i32, i32, i32, i32, u32, u32, *const c_void)
            ),
            image_target_texture: symbol!(
                "glEGLImageTargetTexture2DOES",
                unsafe extern "system" fn(u32, *const c_void)
            ),
            delete_textures: symbol!(
                "glDeleteTextures",
                unsafe extern "system" fn(i32, *const u32)
            ),
            gen_framebuffers: symbol!(
                "glGenFramebuffers",
                unsafe extern "system" fn(i32, *mut u32)
            ),
            bind_framebuffer: symbol!("glBindFramebuffer", unsafe extern "system" fn(u32, u32)),
            framebuffer_texture_2d: symbol!(
                "glFramebufferTexture2D",
                unsafe extern "system" fn(u32, u32, u32, u32, i32)
            ),
            check_framebuffer_status: symbol!(
                "glCheckFramebufferStatus",
                unsafe extern "system" fn(u32) -> u32
            ),
            create_shader: symbol!("glCreateShader", unsafe extern "system" fn(u32) -> u32),
            shader_source: symbol!(
                "glShaderSource",
                unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32)
            ),
            compile_shader: symbol!("glCompileShader", unsafe extern "system" fn(u32)),
            get_shader_iv: symbol!(
                "glGetShaderiv",
                unsafe extern "system" fn(u32, u32, *mut i32)
            ),
            get_shader_info_log: symbol!(
                "glGetShaderInfoLog",
                unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char)
            ),
            delete_shader: symbol!("glDeleteShader", unsafe extern "system" fn(u32)),
            create_program: symbol!("glCreateProgram", unsafe extern "system" fn() -> u32),
            attach_shader: symbol!("glAttachShader", unsafe extern "system" fn(u32, u32)),
            link_program: symbol!("glLinkProgram", unsafe extern "system" fn(u32)),
            get_program_iv: symbol!(
                "glGetProgramiv",
                unsafe extern "system" fn(u32, u32, *mut i32)
            ),
            get_program_info_log: symbol!(
                "glGetProgramInfoLog",
                unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char)
            ),
            delete_program: symbol!("glDeleteProgram", unsafe extern "system" fn(u32)),
            use_program: symbol!("glUseProgram", unsafe extern "system" fn(u32)),
            get_uniform_location: symbol!(
                "glGetUniformLocation",
                unsafe extern "system" fn(u32, *const c_char) -> i32
            ),
            uniform_1i: symbol!("glUniform1i", unsafe extern "system" fn(i32, i32)),
            active_texture: symbol!("glActiveTexture", unsafe extern "system" fn(u32)),
            enable: symbol!("glEnable", unsafe extern "system" fn(u32)),
            disable: symbol!("glDisable", unsafe extern "system" fn(u32)),
            is_enabled: symbol!("glIsEnabled", unsafe extern "system" fn(u32) -> u8),
            get_boolean_v: symbol!("glGetBooleanv", unsafe extern "system" fn(u32, *mut u8)),
            color_mask: symbol!("glColorMask", unsafe extern "system" fn(u8, u8, u8, u8)),
            draw_arrays: symbol!("glDrawArrays", unsafe extern "system" fn(u32, i32, i32)),
            delete_framebuffers: symbol!(
                "glDeleteFramebuffers",
                unsafe extern "system" fn(i32, *const u32)
            ),
            gen_renderbuffers: symbol!(
                "glGenRenderbuffers",
                unsafe extern "system" fn(i32, *mut u32)
            ),
            bind_renderbuffer: symbol!("glBindRenderbuffer", unsafe extern "system" fn(u32, u32)),
            renderbuffer_storage: symbol!(
                "glRenderbufferStorage",
                unsafe extern "system" fn(u32, u32, i32, i32)
            ),
            framebuffer_renderbuffer: symbol!(
                "glFramebufferRenderbuffer",
                unsafe extern "system" fn(u32, u32, u32, u32)
            ),
            delete_renderbuffers: symbol!(
                "glDeleteRenderbuffers",
                unsafe extern "system" fn(i32, *const u32)
            ),
            get_integer_v: symbol!("glGetIntegerv", unsafe extern "system" fn(u32, *mut i32)),
            viewport: symbol!("glViewport", unsafe extern "system" fn(i32, i32, i32, i32)),
            get_error: symbol!("glGetError", unsafe extern "system" fn() -> u32),
            flush: symbol!("glFlush", unsafe extern "system" fn()),
            finish: symbol!("glFinish", unsafe extern "system" fn()),
        })
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct GlTarget {
    pub(super) output_id: OutputId,
    pub(super) render_view_id: RenderViewId,
    pub(super) configuration_generation: u64,
    pub(super) size: PixelSize,
    pub(super) buffer_index: usize,
    pub(super) scanout_image: usize,
    pub(super) render_image: usize,
    pub(super) scanout_texture: u32,
    pub(super) scanout_framebuffer: u32,
    pub(super) render_texture: u32,
    pub(super) render_framebuffer: u32,
}

impl GlTarget {
    pub(super) fn needs_blit(self) -> bool {
        self.render_framebuffer != self.scanout_framebuffer
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct ShaderBlit {
    pub(super) program: u32,
    pub(super) source_uniform: i32,
}

const SCANOUT_VERTEX_SHADER: &[u8] = b"#version 300 es\n\
precision highp float;\n\
out vec2 texture_coordinate;\n\
void main() {\n\
    vec2 position = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n\
    texture_coordinate = position;\n\
    gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);\n\
}\n\0";

const SCANOUT_FRAGMENT_SHADER: &[u8] = b"#version 300 es\n\
precision highp float;\n\
uniform sampler2D source_texture;\n\
in vec2 texture_coordinate;\n\
layout(location = 0) out vec4 fragment_color;\n\
void main() {\n\
    fragment_color = texture(source_texture, texture_coordinate);\n\
}\n\0";

pub(super) fn create_shader_blit(gl: GlApi) -> Result<ShaderBlit, Box<dyn Error>> {
    let vertex = compile_shader(gl, gl::VERTEX_SHADER, SCANOUT_VERTEX_SHADER)?;
    let fragment = match compile_shader(gl, gl::FRAGMENT_SHADER, SCANOUT_FRAGMENT_SHADER) {
        Ok(fragment) => fragment,
        Err(error) => {
            // SAFETY: `vertex` was created in the current context above.
            unsafe { (gl.delete_shader)(vertex) };
            return Err(error);
        }
    };
    // SAFETY: a compatible GLES context is current and both shader names are
    // valid in it until they are deleted after the link attempt.
    let program = unsafe {
        let program = (gl.create_program)();
        if program != 0 {
            (gl.attach_shader)(program, vertex);
            (gl.attach_shader)(program, fragment);
            (gl.link_program)(program);
        }
        (gl.delete_shader)(vertex);
        (gl.delete_shader)(fragment);
        program
    };
    if program == 0 {
        return Err("could not allocate Flutter scanout-copy shader program".into());
    }
    let mut linked = 0;
    // SAFETY: `program` is a live program in the current GLES context.
    unsafe { (gl.get_program_iv)(program, gl::LINK_STATUS, &mut linked) };
    if linked == 0 {
        let log = program_info_log(gl, program);
        // SAFETY: the failed program remains live until this deletion.
        unsafe { (gl.delete_program)(program) };
        return Err(format!("could not link Flutter scanout-copy shader: {log}").into());
    }
    // SAFETY: the name is NUL-terminated and the linked program is live.
    let source_uniform = unsafe { (gl.get_uniform_location)(program, c"source_texture".as_ptr()) };
    if source_uniform < 0 {
        // SAFETY: the linked program remains live until this deletion.
        unsafe { (gl.delete_program)(program) };
        return Err("Flutter scanout-copy shader omitted its source sampler".into());
    }
    Ok(ShaderBlit {
        program,
        source_uniform,
    })
}

fn compile_shader(gl: GlApi, kind: u32, source: &[u8]) -> Result<u32, Box<dyn Error>> {
    debug_assert_eq!(source.last(), Some(&0));
    // SAFETY: a compatible GLES context is current, `source` is NUL-terminated,
    // and the driver copies it during this call.
    let shader = unsafe {
        let shader = (gl.create_shader)(kind);
        if shader != 0 {
            let source = source.as_ptr().cast::<c_char>();
            (gl.shader_source)(shader, 1, &source, ptr::null());
            (gl.compile_shader)(shader);
        }
        shader
    };
    if shader == 0 {
        return Err("could not allocate Flutter scanout-copy shader".into());
    }
    let mut compiled = 0;
    // SAFETY: `shader` is live in the current GLES context.
    unsafe { (gl.get_shader_iv)(shader, gl::COMPILE_STATUS, &mut compiled) };
    if compiled == 0 {
        let log = shader_info_log(gl, shader);
        // SAFETY: the failed shader remains live until this deletion.
        unsafe { (gl.delete_shader)(shader) };
        return Err(format!("could not compile Flutter scanout-copy shader: {log}").into());
    }
    Ok(shader)
}

fn shader_info_log(gl: GlApi, shader: u32) -> String {
    let mut length = 0;
    // SAFETY: `shader` is live in the current GLES context.
    unsafe { (gl.get_shader_iv)(shader, gl::INFO_LOG_LENGTH, &mut length) };
    gl_info_log(length, |capacity, written, bytes| unsafe {
        // SAFETY: the output buffer contains `capacity` writable bytes.
        (gl.get_shader_info_log)(shader, capacity, written, bytes)
    })
}

fn program_info_log(gl: GlApi, program: u32) -> String {
    let mut length = 0;
    // SAFETY: `program` is live in the current GLES context.
    unsafe { (gl.get_program_iv)(program, gl::INFO_LOG_LENGTH, &mut length) };
    gl_info_log(length, |capacity, written, bytes| unsafe {
        // SAFETY: the output buffer contains `capacity` writable bytes.
        (gl.get_program_info_log)(program, capacity, written, bytes)
    })
}

fn gl_info_log(length: i32, read: impl FnOnce(i32, *mut i32, *mut c_char)) -> String {
    let capacity = usize::try_from(length.max(1)).unwrap_or(1).min(64 * 1024);
    let mut bytes = vec![0u8; capacity];
    let mut written = 0;
    read(
        i32::try_from(capacity).unwrap_or(i32::MAX),
        &mut written,
        bytes.as_mut_ptr().cast(),
    );
    let written = usize::try_from(written.max(0))
        .unwrap_or(0)
        .min(bytes.len());
    bytes.truncate(written);
    String::from_utf8_lossy(&bytes)
        .trim_end_matches('\0')
        .to_owned()
}

pub(super) fn destroy_shader_blit(gl: GlApi, shader_blit: &mut Option<ShaderBlit>) {
    let Some(shader_blit) = shader_blit.take() else {
        return;
    };
    // SAFETY: cleanup runs with the owning GLES context current and this
    // program was created exactly once by `create_shader_blit`.
    unsafe { (gl.delete_program)(shader_blit.program) };
}

pub(super) fn destroy_targets(gl: GlApi, display: &EGLDisplayHandle, targets: &mut Vec<GlTarget>) {
    for target in targets.drain(..).rev() {
        // SAFETY: cleanup runs with the owning shared EGL context current;
        // every object/image was created exactly once by this handler.
        unsafe {
            if target.render_framebuffer != 0
                && target.render_framebuffer != target.scanout_framebuffer
            {
                (gl.delete_framebuffers)(1, &target.render_framebuffer);
            }
            if target.render_texture != 0 {
                (gl.delete_textures)(1, &target.render_texture);
            }
            if target.scanout_framebuffer != 0 {
                (gl.delete_framebuffers)(1, &target.scanout_framebuffer);
            }
            if target.scanout_texture != 0 {
                (gl.delete_textures)(1, &target.scanout_texture);
            }
            if target.render_image != 0 {
                egl_ffi::egl::DestroyImageKHR(
                    display.handle,
                    target.render_image as egl_ffi::egl::types::EGLImageKHR,
                );
            }
            if target.scanout_image != 0 {
                egl_ffi::egl::DestroyImageKHR(
                    display.handle,
                    target.scanout_image as egl_ffi::egl::types::EGLImageKHR,
                );
            }
        }
    }
}

fn destroy_depth_stencil(gl: GlApi, renderbuffer: &mut u32) {
    if *renderbuffer == 0 {
        return;
    }
    // SAFETY: cleanup runs with the owning shared GLES context current and
    // this renderbuffer was created exactly once by the handler.
    unsafe { (gl.delete_renderbuffers)(1, renderbuffer) };
    *renderbuffer = 0;
}

pub(super) fn destroy_depth_stencils(gl: GlApi, renderbuffers: &mut Vec<u32>) {
    for renderbuffer in renderbuffers.iter_mut() {
        destroy_depth_stencil(gl, renderbuffer);
    }
    renderbuffers.clear();
}
