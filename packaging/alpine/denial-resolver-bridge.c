#include <resolv.h>

/* glibc's header aliases res_init to __res_init; musl exports res_init. */
#undef res_init
extern int res_init(void);

/*
 * gcompat 1.1.0 does not export the glibc spelling used by Flutter's
 * Linux resolver path.  musl provides the equivalent res_init entry point.
 * Keep this bridge process-local by adding it to deniald's DT_NEEDED list;
 * never export it through LD_PRELOAD to applications launched by Denial.
 */
int __res_init(void) {
    return res_init();
}
