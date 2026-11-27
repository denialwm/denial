//! The GLES entry points the renderers call, resolved from the driver.

use std::error::Error;
use std::ffi::{c_char, c_void};
use std::mem;

use smithay::backend::egl::get_proc_address;

#[derive(Clone, Copy)]
pub struct GlApi {
    pub gen_textures: unsafe extern "system" fn(i32, *mut u32),
    pub bind_texture: unsafe extern "system" fn(u32, u32),
    pub tex_parameter_i: unsafe extern "system" fn(u32, u32, i32),
    pub tex_image_2d:
        unsafe extern "system" fn(u32, i32, i32, i32, i32, i32, u32, u32, *const c_void),
    pub tex_image_3d:
        unsafe extern "system" fn(u32, i32, i32, i32, i32, i32, i32, u32, u32, *const c_void),
    pub image_target_texture: unsafe extern "system" fn(u32, *const c_void),
    pub delete_textures: unsafe extern "system" fn(i32, *const u32),
    pub gen_framebuffers: unsafe extern "system" fn(i32, *mut u32),
    pub bind_framebuffer: unsafe extern "system" fn(u32, u32),
    pub framebuffer_texture_2d: unsafe extern "system" fn(u32, u32, u32, u32, i32),
    pub check_framebuffer_status: unsafe extern "system" fn(u32) -> u32,
    pub create_shader: unsafe extern "system" fn(u32) -> u32,
    pub shader_source: unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32),
    pub compile_shader: unsafe extern "system" fn(u32),
    pub get_shader_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    pub get_shader_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    pub delete_shader: unsafe extern "system" fn(u32),
    pub create_program: unsafe extern "system" fn() -> u32,
    pub attach_shader: unsafe extern "system" fn(u32, u32),
    pub link_program: unsafe extern "system" fn(u32),
    pub get_program_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    pub get_program_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    pub delete_program: unsafe extern "system" fn(u32),
    pub use_program: unsafe extern "system" fn(u32),
    pub get_uniform_location: unsafe extern "system" fn(u32, *const c_char) -> i32,
    pub uniform_1i: unsafe extern "system" fn(i32, i32),
    pub uniform_matrix_3fv: unsafe extern "system" fn(i32, i32, u8, *const f32),
    pub uniform_3fv: unsafe extern "system" fn(i32, i32, *const f32),
    pub uniform_4fv: unsafe extern "system" fn(i32, i32, *const f32),
    pub uniform_1f: unsafe extern "system" fn(i32, f32),
    pub active_texture: unsafe extern "system" fn(u32),
    pub enable: unsafe extern "system" fn(u32),
    pub disable: unsafe extern "system" fn(u32),
    pub is_enabled: unsafe extern "system" fn(u32) -> u8,
    pub get_boolean_v: unsafe extern "system" fn(u32, *mut u8),
    pub color_mask: unsafe extern "system" fn(u8, u8, u8, u8),
    pub draw_arrays: unsafe extern "system" fn(u32, i32, i32),
    pub delete_framebuffers: unsafe extern "system" fn(i32, *const u32),
    pub gen_renderbuffers: unsafe extern "system" fn(i32, *mut u32),
    pub bind_renderbuffer: unsafe extern "system" fn(u32, u32),
    pub renderbuffer_storage: unsafe extern "system" fn(u32, u32, i32, i32),
    pub framebuffer_renderbuffer: unsafe extern "system" fn(u32, u32, u32, u32),
    pub delete_renderbuffers: unsafe extern "system" fn(i32, *const u32),
    pub get_integer_v: unsafe extern "system" fn(u32, *mut i32),
    pub viewport: unsafe extern "system" fn(i32, i32, i32, i32),
    pub scissor: unsafe extern "system" fn(i32, i32, i32, i32),
    pub get_error: unsafe extern "system" fn() -> u32,
    pub flush: unsafe extern "system" fn(),
    pub finish: unsafe extern "system" fn(),
}

impl GlApi {
    pub fn load() -> Result<Self, Box<dyn Error>> {
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
            tex_image_3d: symbol!(
                "glTexImage3D",
                unsafe extern "system" fn(
                    u32,
                    i32,
                    i32,
                    i32,
                    i32,
                    i32,
                    i32,
                    u32,
                    u32,
                    *const c_void,
                )
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
            uniform_matrix_3fv: symbol!(
                "glUniformMatrix3fv",
                unsafe extern "system" fn(i32, i32, u8, *const f32)
            ),
            uniform_3fv: symbol!(
                "glUniform3fv",
                unsafe extern "system" fn(i32, i32, *const f32)
            ),
            uniform_4fv: symbol!(
                "glUniform4fv",
                unsafe extern "system" fn(i32, i32, *const f32)
            ),
            uniform_1f: symbol!("glUniform1f", unsafe extern "system" fn(i32, f32)),
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
            scissor: symbol!("glScissor", unsafe extern "system" fn(i32, i32, i32, i32)),
            get_error: symbol!("glGetError", unsafe extern "system" fn() -> u32),
            flush: symbol!("glFlush", unsafe extern "system" fn()),
            finish: symbol!("glFinish", unsafe extern "system" fn()),
        })
    }
}
