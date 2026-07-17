#pragma once

#include "Runtime.hpp"

#include <EGL/egl.h>
#include <EGL/eglext.h>

namespace Denial {

    // Private state shared only by CRuntime implementation units. Keeping the
    // definition out of Runtime.hpp prevents Flutter/EGL implementation detail
    // from becoming part of the compositor-facing runtime interface.
    struct CRuntime::SFlutterRuntime {
        SFlutterRuntime();
        ~SFlutterRuntime();

        SFlutterRuntime(const SFlutterRuntime&)                = delete;
        SFlutterRuntime&     operator=(const SFlutterRuntime&) = delete;

        DenialEngineHostRef* host            = nullptr;
        EGLDisplay           eglDisplay      = EGL_NO_DISPLAY;
        EGLContext           renderContext   = EGL_NO_CONTEXT;
        EGLContext           resourceContext = EGL_NO_CONTEXT;

        // Used only on the Hypr main thread by the scene-to-scanout consumer.
        EGLContext presentationContext = EGL_NO_CONTEXT;

        // Orders the presentation-context copy after Flutter raster work.
        EGLSyncKHR sceneRenderFence = EGL_NO_SYNC_KHR;

        // Orders reuse of the single scene texture after an asynchronous copy.
        EGLSyncKHR sceneCopyFence = EGL_NO_SYNC_KHR;
    };

} // namespace Denial
