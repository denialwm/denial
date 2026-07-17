#pragma once

#include "RuntimeLog.hpp"

#include "../src/defines.hpp"

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <cstdint>

namespace Denial::RuntimeInternal {

    inline bool makeFlutterContextCurrent(EGLDisplay display, EGLContext context, const char* label) {
        if (display == EGL_NO_DISPLAY || context == EGL_NO_CONTEXT)
            return false;

        if (eglGetCurrentContext() != context && eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context) != EGL_TRUE) {
            DENIAL_HOT_LOG(Log::ERR, "Denial {} make_current failed: eglGetError={}", label, eglGetError());
            return false;
        }

        if (!glGetString(GL_VERSION)) {
            DENIAL_HOT_LOG(Log::ERR, "Denial {} make_current produced no GL_VERSION: eglContext={} eglGetError={}", label, rc<uintptr_t>(eglGetCurrentContext()), eglGetError());
            return false;
        }

        return true;
    }

} // namespace Denial::RuntimeInternal
