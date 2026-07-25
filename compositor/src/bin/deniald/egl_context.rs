use std::error::Error;
#[cfg(feature = "flutter")]
use std::ops::Deref;

use smithay::backend::egl::context::{ContextPriority, GlAttributes, PixelFormatRequirements};
#[cfg(feature = "flutter")]
use smithay::backend::egl::ffi as egl_ffi;
use smithay::backend::egl::{EGLContext, EGLDisplay, Error as EglError};
use tracing::{info, warn};

const PREFERRED_GLES_VERSION: (u8, u8) = (3, 2);
const FALLBACK_GLES_VERSION: (u8, u8) = (3, 0);
#[cfg(feature = "flutter")]
const EGL_CONTEXT_RELEASE_BEHAVIOR_KHR: egl_ffi::EGLint = 0x2097;
#[cfg(feature = "flutter")]
const EGL_CONTEXT_RELEASE_BEHAVIOR_NONE_KHR: egl_ffi::EGLint = 0;

fn attributes(version: (u8, u8)) -> GlAttributes {
    GlAttributes {
        version,
        profile: None,
        debug: false,
        vsync: false,
    }
}

fn pixel_format_requirements() -> PixelFormatRequirements {
    PixelFormatRequirements {
        hardware_accelerated: Some(true),
        color_bits: Some(24),
        float_color_buffer: false,
        alpha_bits: None,
        depth_bits: None,
        stencil_bits: None,
        multisampling: Some(0),
    }
}

fn create_preferred_context(
    role: &'static str,
    mut create: impl FnMut(GlAttributes, PixelFormatRequirements) -> Result<EGLContext, EglError>,
) -> Result<EGLContext, Box<dyn Error>> {
    match create(
        attributes(PREFERRED_GLES_VERSION),
        pixel_format_requirements(),
    ) {
        Ok(context) => {
            info!(role, version = "3.2", "created hardware GLES context");
            return Ok(context);
        }
        Err(error) => {
            warn!(
                role,
                %error,
                "could not create GLES 3.2 context; falling back to GLES 3.0"
            );
        }
    }

    create(
        attributes(FALLBACK_GLES_VERSION),
        pixel_format_requirements(),
    )
    .inspect(|_context| {
        info!(role, version = "3.0", "created hardware GLES context");
    })
    .map_err(|error| {
        format!("could not create {role} GLES 3.2 or GLES 3.0 context: {error}").into()
    })
}

pub fn create_render_context(display: &EGLDisplay) -> Result<EGLContext, Box<dyn Error>> {
    create_preferred_context("compositor", |attributes, requirements| {
        EGLContext::new_with_config_and_priority(
            display,
            attributes,
            requirements,
            ContextPriority::High,
        )
    })
}

#[cfg(feature = "flutter")]
pub struct SharedEglContext {
    context: EGLContext,
    display: EGLDisplay,
    raw: egl_ffi::egl::types::EGLContext,
}

// SAFETY: this wrapper has the same threading contract as Smithay's
// EGLContext: it may move between threads only while it is not current.
#[cfg(feature = "flutter")]
unsafe impl Send for SharedEglContext {}

#[cfg(feature = "flutter")]
impl Deref for SharedEglContext {
    type Target = EGLContext;

    fn deref(&self) -> &Self::Target {
        &self.context
    }
}

#[cfg(feature = "flutter")]
impl Drop for SharedEglContext {
    fn drop(&mut self) {
        // The Smithay wrapper is externally managed, so this owner must both
        // unbind and destroy the raw context before its display reference dies.
        let _ = self.context.unbind();
        // SAFETY: `raw` was created on `display`, is owned exactly once by this
        // wrapper, and has been unbound from the current thread above.
        unsafe {
            egl_ffi::egl::DestroyContext(**self.display.get_display_handle(), self.raw);
        }
    }
}

#[cfg(feature = "flutter")]
fn supports(display: &EGLDisplay, extension: &str) -> bool {
    display
        .extensions()
        .iter()
        .any(|candidate| candidate == extension)
}

#[cfg(feature = "flutter")]
fn create_shared_version(
    shared: &EGLContext,
    version: (u8, u8),
) -> Result<SharedEglContext, Box<dyn Error>> {
    let display = shared.display().clone();
    let mut attributes = Vec::<egl_ffi::EGLint>::with_capacity(13);
    if supports(&display, "EGL_IMG_context_priority") {
        attributes.push(egl_ffi::egl::CONTEXT_PRIORITY_LEVEL_IMG as egl_ffi::EGLint);
        attributes.push(egl_ffi::egl::CONTEXT_PRIORITY_HIGH_IMG as egl_ffi::EGLint);
    }
    // The reset-notification strategy must match across Mesa share groups.
    // Smithay creates the compositor/root context with EGL's default strategy,
    // so requesting LOSE_CONTEXT_ON_RESET only for this child makes
    // eglCreateContext fail with EGL_BAD_MATCH. Leave the attribute unset and
    // inherit the root context's compatible default.
    if supports(&display, "EGL_KHR_context_flush_control") {
        // Flutter explicitly publishes every completed frame with glFlush
        // before exporting its native fence. The EGL default would flush the
        // same context again whenever clear_current unbinds it.
        attributes.push(EGL_CONTEXT_RELEASE_BEHAVIOR_KHR);
        attributes.push(EGL_CONTEXT_RELEASE_BEHAVIOR_NONE_KHR);
    }
    attributes.push(egl_ffi::egl::CONTEXT_MAJOR_VERSION as egl_ffi::EGLint);
    attributes.push(egl_ffi::EGLint::from(version.0));
    attributes.push(egl_ffi::egl::CONTEXT_MINOR_VERSION as egl_ffi::EGLint);
    attributes.push(egl_ffi::EGLint::from(version.1));
    attributes.push(egl_ffi::egl::NONE as egl_ffi::EGLint);

    // SAFETY: Smithay loaded EGL for this live display, and binding the GLES
    // API changes only this thread's context-creation API.
    let bound = unsafe { egl_ffi::egl::BindAPI(egl_ffi::egl::OPENGL_ES_API) };
    if bound == egl_ffi::egl::FALSE {
        // SAFETY: eglGetError reads and clears this thread's EGL error state.
        let error = unsafe { egl_ffi::egl::GetError() };
        return Err(format!("eglBindAPI(EGL_OPENGL_ES_API) failed: 0x{error:x}").into());
    }

    let display_handle = display.get_display_handle();
    let raw_display = **display_handle;
    let config = shared.config_id();
    // SAFETY: the display/config/share handles all belong to the live
    // compositor EGL context, and `attributes` is terminated by EGL_NONE.
    let raw = unsafe {
        egl_ffi::egl::CreateContext(
            raw_display,
            config,
            shared.get_context_handle(),
            attributes.as_ptr(),
        )
    };
    if raw == egl_ffi::egl::NO_CONTEXT {
        // SAFETY: eglGetError reads and clears this thread's EGL error state.
        let error = unsafe { egl_ffi::egl::GetError() };
        return Err(format!(
            "eglCreateContext for GLES {}.{} failed: 0x{error:x}",
            version.0, version.1
        )
        .into());
    }

    // SAFETY: the three handles remain valid for the returned owner's
    // lifetime. SharedEglContext destroys `raw`; Smithay is told that the
    // wrapped context is externally managed and therefore will not destroy it.
    let context = match unsafe { EGLContext::from_raw(raw_display, config, raw) } {
        Ok(context) => context,
        Err(error) => {
            // SAFETY: wrapping failed before ownership could escape; destroy
            // the context exactly once on the display that created it.
            unsafe {
                egl_ffi::egl::DestroyContext(raw_display, raw);
            }
            return Err(format!("could not wrap the shared EGL context: {error}").into());
        }
    };
    Ok(SharedEglContext {
        context,
        display,
        raw,
    })
}

#[cfg(feature = "flutter")]
pub fn create_shared_context(
    role: &'static str,
    shared: &EGLContext,
) -> Result<SharedEglContext, Box<dyn Error>> {
    let no_implicit_flush = supports(shared.display(), "EGL_KHR_context_flush_control");
    if !no_implicit_flush {
        warn!(
            role,
            "EGL_KHR_context_flush_control unavailable; Flutter context unbinds may flush"
        );
    }

    match create_shared_version(shared, PREFERRED_GLES_VERSION) {
        Ok(context) => {
            info!(
                role,
                version = "3.2",
                no_implicit_flush,
                "created hardware shared GLES context"
            );
            Ok(context)
        }
        Err(error) => {
            warn!(
                role,
                %error,
                "could not create shared GLES 3.2 context; falling back to GLES 3.0"
            );
            create_shared_version(shared, FALLBACK_GLES_VERSION)
                .inspect(|_context| {
                    info!(
                        role,
                        version = "3.0",
                        no_implicit_flush,
                        "created hardware shared GLES context"
                    );
                })
                .map_err(|fallback| {
                    format!(
                        "could not create {role} shared GLES 3.2 ({error}) or GLES 3.0 ({fallback})"
                    )
                    .into()
                })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_contexts_request_hardware_gles_without_msaa_or_vsync() {
        let attributes = attributes(PREFERRED_GLES_VERSION);
        let requirements = pixel_format_requirements();

        assert_eq!(attributes.version, (3, 2));
        assert!(!attributes.debug);
        assert!(!attributes.vsync);
        assert_eq!(requirements.hardware_accelerated, Some(true));
        assert_eq!(requirements.multisampling, Some(0));
    }
}
