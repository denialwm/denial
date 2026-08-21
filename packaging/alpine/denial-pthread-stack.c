#define _GNU_SOURCE

#include <alloca.h>
#include <pthread.h>
#include <stddef.h>

enum {
    denial_thread_stack_size = 8 * 1024 * 1024,
    denial_main_stack_reserve = 1024 * 1024,
    denial_page_size = 4096,
};

/*
 * Dart expects substantially more stack headroom than musl's small default
 * thread stacks provide.  This constructor runs before Dart or Flutter is
 * initialized: touching the main-thread reserve expands its grow-down mapping,
 * and pthread_setattr_default_np supplies glibc-sized stacks to later threads.
 */
__attribute__((constructor))
static void denial_prepare_musl_stacks(void) {
    volatile unsigned char *reserve = alloca(denial_main_stack_reserve);
    for (size_t offset = 0; offset < denial_main_stack_reserve;
         offset += denial_page_size) {
        reserve[offset] = 0;
    }
    reserve[denial_main_stack_reserve - 1] = 0;

    pthread_attr_t defaults;
    if (pthread_attr_init(&defaults) != 0) {
        return;
    }
    if (pthread_attr_setstacksize(&defaults, denial_thread_stack_size) == 0) {
        (void)pthread_setattr_default_np(&defaults);
    }
    (void)pthread_attr_destroy(&defaults);
}
