/* A finite EGL Wayland workload, paced by frame callbacks. stdout is JSONL.
 * Presentation feedback reports actual display timestamps, not swap returns.
 * Generated xdg-shell/presentation headers belong in the build directory. */
#define _POSIX_C_SOURCE 200809L
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>
#include "xdg-shell-client-protocol.h"
#include "presentation-time-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wl_surface *surface;
static struct wl_surface *root_surface;
static struct xdg_surface *root_xdg;
static struct wl_subsurface *subsurface;
static struct wl_egl_window *window;
static EGLDisplay egl_display;
static EGLSurface egl_surface;
static bool configured, ready = true;
static bool static_content;
static bool static_presented;
static bool carrier, border_alpha;
static bool carrier_dirty;
static int buffer_scale = 1;
static volatile sig_atomic_t running = 1;
static int width = 960, height = 640;
static uint64_t frame;
static uint32_t clock_id;
static void update_carrier(void);

/* Opaque rectangles match Firefox's border-only transparency declaration.
 * Region coordinates are logical; buffer scale only affects pixel storage. */
static void set_opaque(struct wl_surface *s, int x, int y, bool border) {
    struct wl_region *r = wl_compositor_create_region(compositor);
    if (!border) {
        wl_region_add(r, x, y, width, height);
    } else if (width > 16 && height > 52) {
        wl_region_add(r, x + 8, y, width - 16, 44);
        wl_region_add(r, x, y + 44, width, height - 52);
        wl_region_add(r, x + 8, y + height - 8, width - 16, 8);
    }
    wl_surface_set_opaque_region(s, r);
    wl_region_destroy(r);
}

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void stop(int signum) { (void)signum; running = 0; }
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data; xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void clock_event(void *data, struct wp_presentation *p, uint32_t id) {
    (void)data; (void)p; clock_id = id;
}
static const struct wp_presentation_listener presentation_listener = {
    .clock_id = clock_event
};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 3);
    else if (!strcmp(interface, "wl_subcompositor"))
        subcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(interface, "wp_presentation")) {
        presentation = wl_registry_bind(registry, name, &wp_presentation_interface, 1);
        wp_presentation_add_listener(presentation, &presentation_listener, NULL);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {global, global_remove};
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(xdg, serial); configured = true;
    if (carrier_dirty) { carrier_dirty = false; update_carrier(); }
}
static const struct xdg_surface_listener surface_listener = { .configure = configure };
static void size(void *data, struct xdg_toplevel *toplevel, int32_t w, int32_t h,
                 struct wl_array *states) {
    (void)data; (void)toplevel; (void)states;
    if (w > 0 && h > 0) {
        bool resized = width != w || height != h;
        width = w; height = h;
        if (window) {
            wl_egl_window_resize(window, width * buffer_scale, height * buffer_scale, 0, 0);
            set_opaque(surface, 0, 0, carrier || border_alpha);
            // The accompanying xdg_surface.configure must be acknowledged
            // before committing a carrier buffer for this new geometry.
            if (carrier && resized) carrier_dirty = true;
        }
        if (static_content && resized) ready = true;
        printf("{\"event\":\"configured\",\"monotonic_ns\":%llu,\"width\":%d,\"height\":%d,"
               "\"buffer_width\":%d,\"buffer_height\":%d,\"buffer_scale\":%d}\n",
               (unsigned long long)now_ns(), width, height, width * buffer_scale, height * buffer_scale, buffer_scale);
    }
}
static void close_window(void *data, struct xdg_toplevel *toplevel) {
    (void)data; (void)toplevel; running = 0;
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = size, .close = close_window
};
static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
    (void)data; (void)time; wl_callback_destroy(callback);
    ready = !static_content || !static_presented;
}
static const struct wl_callback_listener frame_listener = { .done = frame_done };
struct carrier_data { void *pixels; size_t bytes; };
static void carrier_released(void *data, struct wl_buffer *buffer) {
    struct carrier_data *d = data;
    wl_buffer_destroy(buffer);
    munmap(d->pixels, d->bytes);
    free(d);
}
static const struct wl_buffer_listener carrier_listener = { .release = carrier_released };
static void update_carrier(void) {
    /* Keep the geometry and padding of Firefox's SHM carrier. Each resize
     * gets separate storage retained until wl_buffer.release; no reuse races. */
    int w = (width + 52) * buffer_scale, h = (height + 52) * buffer_scale;
    size_t bytes = (size_t)w * h * sizeof(uint32_t);
    if (bytes > INT32_MAX) { running = 0; return; }
    char name[] = "/tmp/denial-surface-control-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) { running = 0; return; }
    unlink(name);
    if (ftruncate(fd, (off_t)bytes) < 0) { close(fd); running = 0; return; }
    void *pixels = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { close(fd); running = 0; return; }
    struct carrier_data *d = calloc(1, sizeof(*d));
    if (!d) { munmap(pixels, bytes); close(fd); running = 0; return; }
    d->pixels = pixels; d->bytes = bytes;
    memset(pixels, 0, bytes);
    for (int y = 0; y < height * buffer_scale; y++) {
        for (int x = 0; x < width * buffer_scale; x++) {
            bool border = (x < 8 * buffer_scale || x >= (width - 8) * buffer_scale)
                && (y < 44 * buffer_scale || y >= (height - 8) * buffer_scale);
            ((uint32_t *)pixels)[(size_t)(y + 23 * buffer_scale) * w + x + 26 * buffer_scale]
                = border_alpha && border ? 0x8005070b : 0xff0a0f17;
        }
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)bytes);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buffer, &carrier_listener, d);
    wl_shm_pool_destroy(pool); close(fd);
    xdg_surface_set_window_geometry(root_xdg, 26, 23, width, height);
    set_opaque(root_surface, 26, 23, border_alpha);
    wl_surface_attach(root_surface, buffer, 0, 0);
    wl_surface_damage(root_surface, 0, 0, width + 52, height + 52);
    wl_surface_commit(root_surface);
    printf("{\"event\":\"carrier\",\"monotonic_ns\":%llu,\"width\":%d,\"height\":%d,\"bytes\":%zu,\"border_alpha\":%s}\n",
           (unsigned long long)now_ns(), w, h, bytes, border_alpha ? "true" : "false");
}
struct feedback_data { uint64_t frame, submitted; };
static void sync_output(void *data, struct wp_presentation_feedback *fb,
                        struct wl_output *output) { (void)data; (void)fb; (void)output; }
static void presented(void *data, struct wp_presentation_feedback *fb,
                      uint32_t hi, uint32_t lo, uint32_t ns, uint32_t refresh,
                      uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
    struct feedback_data *d = data;
    if (static_content) { static_presented = true; ready = false; }
    uint64_t time = (((uint64_t)hi << 32) | lo) * 1000000000 + ns;
    uint64_t seq = ((uint64_t)seq_hi << 32) | seq_lo;
    printf("{\"event\":\"presented\",\"frame\":%llu,\"submitted_ns\":%llu,"
           "\"presentation_ns\":%llu,\"received_ns\":%llu,\"refresh_ns\":%u,"
           "\"sequence\":%llu,\"flags\":%u}\n",
           (unsigned long long)d->frame, (unsigned long long)d->submitted,
           (unsigned long long)time, (unsigned long long)now_ns(), refresh,
           (unsigned long long)seq, flags);
    wp_presentation_feedback_destroy(fb); free(d);
}
static void discarded(void *data, struct wp_presentation_feedback *fb) {
    struct feedback_data *d = data;
    if (static_content && !static_presented) ready = true;
    printf("{\"event\":\"discarded\",\"frame\":%llu,\"received_ns\":%llu}\n",
           (unsigned long long)d->frame, (unsigned long long)now_ns());
    wp_presentation_feedback_destroy(fb); free(d);
}
static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = sync_output, .presented = presented, .discarded = discarded
};
static void draw(void) {
    int pixel_width = width * buffer_scale, pixel_height = height * buffer_scale;
    glViewport(0, 0, pixel_width, pixel_height);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.04f, 0.06f, 0.09f, 1); glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < 24; i++) {
        int w = pixel_width / 12 + 1, h = pixel_height / 8 + 1;
        uint64_t position_frame = static_content ? 0 : frame;
        int x = (position_frame * (i % 5 + 2) + i * 73) % pixel_width;
        int y = (position_frame * (i % 3 + 1) + i * 43) % pixel_height;
        glScissor(x, y, w, h);
        glClearColor((i % 3 + 1) / 3.0f, (i % 7 + 1) / 7.0f, 0.7f, 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    if (carrier || border_alpha) {
        /* Two translucent side bands at the top and bottom. Their opaque
         * complement is exactly the advertised region, including GL's Y flip. */
        int s = buffer_scale;
        glClearColor(0.02f, 0.03f, 0.045f, 0.5f);
        for (int side = 0; side < 2; side++) {
            int x = side ? pixel_width - 8 * s : 0;
            glScissor(x, 0, 8 * s, 8 * s); glClear(GL_COLOR_BUFFER_BIT);
            glScissor(x, pixel_height - 44 * s, 8 * s, 44 * s); glClear(GL_COLOR_BUFFER_BIT);
        }
    }
    struct wl_callback *callback = wl_surface_frame(surface);
    wl_callback_add_listener(callback, &frame_listener, NULL);
    if (presentation) {
        struct feedback_data *data = calloc(1, sizeof(*data));
        if (!data) { running = 0; return; }
        data->frame = frame; data->submitted = now_ns();
        struct wp_presentation_feedback *fb = wp_presentation_feedback(presentation, surface);
        wp_presentation_feedback_add_listener(fb, &feedback_listener, data);
    }
    ready = false;
    if (!eglSwapBuffers(egl_display, egl_surface)) {
        running = 0;
    } else if (static_content) {
        printf("{\"event\":\"static_submitted\",\"frame\":%llu,\"monotonic_ns\":%llu}\n",
               (unsigned long long)frame, (unsigned long long)now_ns());
    }
    frame++;
}
int main(int argc, char **argv) {
    double seconds = argc >= 2 ? strtod(argv[1], NULL) : 180;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--static")) {
            static_content = true;
        } else if (!strcmp(argv[i], "--carrier")) {
            carrier = true;
        } else if (!strcmp(argv[i], "--border-alpha")) {
            border_alpha = true;
        } else if (!strncmp(argv[i], "--scale=", 8)) {
            char *end;
            long scale = strtol(argv[i] + 8, &end, 10);
            if (end == argv[i] + 8 || *end || scale < 1 || scale > 4) return 2;
            buffer_scale = (int)scale;
        } else {
            return 2;
        }
    }
    if (!(seconds > 0 && seconds <= 600)) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGTERM, stop); signal(SIGINT, stop);
    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "Cannot connect to Wayland\n"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !wm) return 1;
    if (static_content && !presentation) {
        fprintf(stderr, "Static control requires presentation feedback\n"); return 1;
    }
    if (carrier && (!subcompositor || !shm)) return 1;
    root_surface = wl_compositor_create_surface(compositor);
    wl_surface_set_buffer_scale(root_surface, buffer_scale);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, root_surface);
    root_xdg = xdg;
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(toplevel, static_content ? "Denial static workload" : "Denial 120 fps workload");
    xdg_toplevel_set_app_id(toplevel, static_content ? "dev.denial.StaticWorkload" : "dev.denial.RenderWorkload");
    wl_surface_commit(root_surface);
    while (running && !configured) if (wl_display_dispatch(display) < 0) return 1;
    surface = root_surface;
    if (carrier) {
        surface = wl_compositor_create_surface(compositor);
        wl_surface_set_buffer_scale(surface, buffer_scale);
        subsurface = wl_subcompositor_get_subsurface(subcompositor, surface, root_surface);
        wl_subsurface_set_position(subsurface, 26, 23);
        wl_subsurface_set_desync(subsurface);
        update_carrier();
    }
    egl_display = eglGetDisplay((EGLNativeDisplayType)display);
    if (!eglInitialize(egl_display, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API)) return 1;
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, carrier || border_alpha ? 8 : 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE
    };
    EGLConfig config; EGLint count;
    if (!eglChooseConfig(egl_display, config_attributes, &config, 1, &count) || !count) return 1;
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext context = eglCreateContext(egl_display, config, EGL_NO_CONTEXT, context_attributes);
    window = wl_egl_window_create(surface, width * buffer_scale, height * buffer_scale);
    egl_surface = eglCreateWindowSurface(egl_display, config, (EGLNativeWindowType)window, NULL);
    if (!eglMakeCurrent(egl_display, egl_surface, egl_surface, context)) return 1;
    eglSwapInterval(egl_display, 0);
    set_opaque(surface, 0, 0, carrier || border_alpha);
    wl_display_roundtrip(display);
    printf("{\"event\":\"started\",\"monotonic_ns\":%llu,\"clock_id\":%u,"
           "\"presentation_available\":%s,\"requested_fps\":%u,\"static_content\":%s,\"carrier\":%s,\"border_alpha\":%s}\n",
           (unsigned long long)now_ns(), clock_id, presentation ? "true" : "false",
           static_content ? 0u : 120u, static_content ? "true" : "false",
           carrier ? "true" : "false", border_alpha ? "true" : "false");
    uint64_t end = now_ns() + (uint64_t)(seconds * 1e9);
    uint64_t avoided_waits = 0;
    while (running && now_ns() < end) {
        if (ready) draw();
        /* EGL may read the socket using its own queue, leaving our frame
         * callback pending. Dispatching that callback makes another frame
         * runnable: don't then block waiting for unrelated socket traffic. */
        while (!ready && wl_display_prepare_read(display) != 0)
            if (wl_display_dispatch_pending(display) < 0) goto done;
        if (ready) { avoided_waits++; continue; }
        int flushed = wl_display_flush(display);
        if (flushed < 0 && errno != EAGAIN) { wl_display_cancel_read(display); break; }
        struct pollfd p = {wl_display_get_fd(display), POLLIN | (flushed < 0 ? POLLOUT : 0), 0};
        int rc = poll(&p, 1, 100);
        if (rc > 0 && (p.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            wl_display_cancel_read(display); break;
        }
        if (rc > 0 && (p.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0) goto done;
        } else {
            wl_display_cancel_read(display);
            if (rc < 0 && errno != EINTR) goto done;
        }
        if (wl_display_dispatch_pending(display) < 0) break;
    }
done:
    printf("{\"event\":\"finished\",\"frames_submitted\":%llu,\"avoided_waits\":%llu}\n",
           (unsigned long long)frame, (unsigned long long)avoided_waits);
    eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(egl_display, egl_surface); eglDestroyContext(egl_display, context);
    wl_egl_window_destroy(window); eglTerminate(egl_display);
    xdg_toplevel_destroy(toplevel); xdg_surface_destroy(xdg);
    if (subsurface) { wl_subsurface_destroy(subsurface); wl_surface_destroy(surface); }
    wl_surface_destroy(root_surface);
    wl_display_flush(display); wl_display_disconnect(display);
    return 0;
}
