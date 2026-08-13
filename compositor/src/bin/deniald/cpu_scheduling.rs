//! CPU scheduling policy for the compositor's latency-critical threads.
//!
//! Denial uses Linux's lowest `SCHED_RR` priority for its compositor, Volition
//! submission, Flutter display, and raster threads. This prevents ordinary
//! application load from starving presentation without outranking audio and
//! other deliberately higher-priority realtime work.
//!
//! Realtime is enabled only when `RLIMIT_RTTIME` can retain an infinite hard
//! limit. A finite soft limit still detects a runaway and drops the elevated
//! policy, but no scheduling fault may let the kernel kill the graphical
//! session. Hosts without a safe realtime envelope use a negative nice value
//! through RTKit instead. All other Denial threads are explicitly normalized,
//! and launched applications never inherit either policy.

use std::cell::RefCell;
use std::fs;
use std::io;
#[cfg(feature = "flutter")]
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU8, Ordering};
use std::sync::{Once, OnceLock};
use std::time::Duration;

#[cfg(feature = "flutter")]
use denial_flutter_engine::sys;
use tracing::{debug, info, warn};
use zbus::blocking::connection::Builder as ConnectionBuilder;
use zbus::blocking::{Connection, Proxy};

const RTKIT_SERVICE: &str = "org.freedesktop.RealtimeKit1";
const RTKIT_OBJECT: &str = "/org/freedesktop/RealtimeKit1";
const RTKIT_INTERFACE: &str = "org.freedesktop.RealtimeKit1";
const RTKIT_DBUS_TIMEOUT: Duration = Duration::from_secs(2);
const DEFAULT_RT_TIME_SOFT_US: libc::rlim_t = 200_000;
const PREFERRED_NICE_LEVEL: libc::c_int = -10;
const MAX_REGISTERED_PRIORITY_THREADS: usize = 8;

static INITIALIZE: Once = Once::new();
static PRIORITY_GUARD_START: Once = Once::new();
static RTKIT: OnceLock<RtKitClient> = OnceLock::new();
static SCHEDULING_ENABLED: AtomicBool = AtomicBool::new(false);
static RT_PRIORITY: AtomicI32 = AtomicI32::new(0);
static HIGH_PRIORITY_NICE: AtomicI32 = AtomicI32::new(0);
static RT_LIMIT_ARMED: AtomicBool = AtomicBool::new(false);
static RT_BUDGET_EXCEEDED: AtomicBool = AtomicBool::new(false);
static PRIORITY_THREAD_IDS: [AtomicI32; MAX_REGISTERED_PRIORITY_THREADS] =
    [const { AtomicI32::new(0) }; MAX_REGISTERED_PRIORITY_THREADS];
static PRIORITY_THREAD_ROLES: [AtomicU8; MAX_REGISTERED_PRIORITY_THREADS] =
    [const { AtomicU8::new(PriorityRole::Unknown as u8) }; MAX_REGISTERED_PRIORITY_THREADS];

thread_local! {
    static CURRENT_PRIORITY_REGISTRATION: RefCell<Option<ThreadRegistration>> =
        const { RefCell::new(None) };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PromotionSource {
    DirectRealtime,
    DirectHighPriority,
    RtKitHighPriority,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
enum PriorityRole {
    Unknown = 0,
    Compositor = 1,
    FlutterDisplay = 2,
    FlutterRaster = 3,
    Volition = 4,
}

impl PriorityRole {
    const fn label(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Compositor => "compositor",
            Self::FlutterDisplay => "flutter-display",
            Self::FlutterRaster => "flutter-raster",
            Self::Volition => "volition",
        }
    }

    const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Compositor,
            2 => Self::FlutterDisplay,
            3 => Self::FlutterRaster,
            4 => Self::Volition,
            _ => Self::Unknown,
        }
    }
}

impl PromotionSource {
    const fn label(self) -> &'static str {
        match self {
            Self::DirectRealtime | Self::DirectHighPriority => "direct",
            Self::RtKitHighPriority => "rtkit",
        }
    }

    const fn policy(self) -> &'static str {
        match self {
            Self::DirectRealtime => "SCHED_RR",
            Self::DirectHighPriority | Self::RtKitHighPriority => "SCHED_OTHER",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Promotion {
    source: PromotionSource,
    scheduler_value: libc::c_int,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RealtimeLimit {
    soft: libc::rlim_t,
    hard: libc::rlim_t,
}

struct RtKitClient {
    connection: Connection,
}

impl RtKitClient {
    fn connect() -> zbus::Result<Self> {
        let connection = ConnectionBuilder::system()?
            .method_timeout(RTKIT_DBUS_TIMEOUT)
            .build()?;
        Ok(Self { connection })
    }

    fn minimum_nice_level(&self) -> zbus::Result<libc::c_int> {
        let proxy = Proxy::new(
            &self.connection,
            RTKIT_SERVICE,
            RTKIT_OBJECT,
            RTKIT_INTERFACE,
        )?;
        proxy.get_property("MinNiceLevel")
    }

    fn make_thread_high_priority(
        &self,
        tid: libc::pid_t,
        nice_level: libc::c_int,
    ) -> zbus::Result<()> {
        let proxy = Proxy::new(
            &self.connection,
            RTKIT_SERVICE,
            RTKIT_OBJECT,
            RTKIT_INTERFACE,
        )?;
        proxy.call(
            "MakeThreadHighPriority",
            &(u64::try_from(tid).unwrap_or_default(), nice_level),
        )
    }
}

struct ThreadRegistration {
    slot: usize,
    tid: libc::pid_t,
}

impl Drop for ThreadRegistration {
    fn drop(&mut self) {
        if PRIORITY_THREAD_IDS[self.slot]
            .compare_exchange(self.tid, 0, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            PRIORITY_THREAD_ROLES[self.slot].store(PriorityRole::Unknown as u8, Ordering::Release);
        }
    }
}

/// Prepares Denial's process-wide scheduling policy. Calling this more than
/// once is harmless.
///
/// This intentionally runs while the compositor thread is still ordinary:
/// RTKit, graphics drivers, Flutter, and Denial's persistent workers must be
/// allowed to create their helper threads before the compositor is elevated.
pub(super) fn initialize() {
    INITIALIZE.call_once(initialize_once);
}

fn initialize_once() {
    clear_ambient_capabilities();

    if std::env::var("DENIAL_NO_RT")
        .ok()
        .as_deref()
        .is_some_and(flag_value_enabled)
    {
        info!("realtime CPU scheduling disabled by DENIAL_NO_RT");
        return;
    }
    SCHEDULING_ENABLED.store(true, Ordering::Release);
    HIGH_PRIORITY_NICE.store(PREFERRED_NICE_LEVEL, Ordering::Release);

    // Own the policy from a known ordinary baseline. A service manager or
    // host tuning daemon may have elevated the process before Denial starts;
    // retaining that value here would leak it into every driver and D-Bus
    // helper created during bootstrap.
    if let Err(error) = normalize_current_thread() {
        warn!(
            %error,
            "could not normalize inherited CPU scheduling before compositor startup"
        );
    }

    // Connect before elevating anything. zbus owns ordinary helper threads,
    // and background workers must not begin life as realtime tasks.
    match RtKitClient::connect() {
        Ok(client) => {
            match client.minimum_nice_level() {
                Ok(minimum) if minimum < 0 => {
                    // RTKit's minimum is the most negative value it permits.
                    // Stay at the preferred value unless the host is stricter.
                    HIGH_PRIORITY_NICE.store(PREFERRED_NICE_LEVEL.max(minimum), Ordering::Release);
                }
                Ok(minimum) => {
                    debug!(minimum, "rtkit reported no useful high-priority nice level");
                    HIGH_PRIORITY_NICE.store(0, Ordering::Release);
                }
                Err(error) => debug!(%error, "could not read rtkit minimum nice level"),
            }
            let _ = RTKIT.set(client);
        }
        Err(error) => {
            debug!(
                %error,
                "rtkit is unavailable; trying direct CPU-priority grants"
            );
        }
    }
    start_priority_guard();

    let current_limit = match current_rt_time_limit() {
        Ok(limit) => limit,
        Err(error) => {
            warn!(
                %error,
                "could not inspect RLIMIT_RTTIME; realtime disabled, high-priority fallback remains available"
            );
            return;
        }
    };
    let Some(limit) = safe_realtime_limit(current_limit) else {
        info!(
            rt_soft_limit_us = current_limit.rlim_cur,
            rt_hard_limit_us = current_limit.rlim_max,
            "realtime CPU scheduling is not safely containable; using high-priority normal scheduling"
        );
        return;
    };
    if let Err(error) = set_rt_time_limit(limit) {
        warn!(
            %error,
            "could not arm non-fatal RLIMIT_RTTIME guard; using high-priority normal scheduling"
        );
        return;
    }
    RT_LIMIT_ARMED.store(true, Ordering::Release);
    if let Err(error) = install_sigxcpu_handler() {
        let _ = restore_rt_time_soft_limit();
        RT_LIMIT_ARMED.store(false, Ordering::Release);
        warn!(
            %error,
            "could not install realtime overrun guard; using high-priority normal scheduling"
        );
        return;
    }

    // Linux reports 1 as the minimum SCHED_RR priority. Keep it dynamic for
    // correctness on any future supported architecture.
    // SAFETY: sched_get_priority_min has no pointer arguments or side effects.
    let priority = unsafe { libc::sched_get_priority_min(libc::SCHED_RR) };
    if priority <= 0 {
        warn!(
            priority,
            "kernel reported no usable SCHED_RR priority; using high-priority normal scheduling"
        );
        return;
    }
    RT_PRIORITY.store(priority, Ordering::Release);
    info!(
        priority,
        rt_soft_limit_us = limit.soft,
        rt_hard_limit = "infinity",
        "armed non-fatal realtime CPU scheduling"
    );
}

fn start_priority_guard() {
    PRIORITY_GUARD_START.call_once(|| {
        let spawn = std::thread::Builder::new()
            .name("denial-priority-guard".into())
            .spawn(|| {
                normalize_current_worker("priority-guard");
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    contain_unregistered_priority_threads();
                }
            });
        if let Err(error) = spawn {
            warn!(%error, "could not start the CPU-priority inheritance guard");
        }
    });
}

/// Elevates the compositor event-loop thread after startup workers and native
/// libraries have initialized.
pub(super) fn promote_compositor_thread() {
    promote_and_log(PriorityRole::Compositor);
}

/// Elevates a Volition atomic-commit lane. It normally sleeps in the kernel and
/// only runs long enough to advance the next already-rendered scanout at the
/// preceding commit's hardware-completion boundary.
pub(super) fn promote_volition_thread() {
    promote_and_log(PriorityRole::Volition);
}

fn promote_and_log(role: PriorityRole) {
    if !SCHEDULING_ENABLED.load(Ordering::Acquire) {
        return;
    }
    match promote_current_thread(role) {
        Ok(promotion) => info!(
            thread = role.label(),
            tid = current_tid(),
            policy = promotion.source.policy(),
            scheduler_value = promotion.scheduler_value,
            source = promotion.source.label(),
            "elevated latency-critical CPU scheduling"
        ),
        Err(error) => warn!(
            thread = role.label(),
            tid = current_tid(),
            %error,
            "could not elevate a latency-critical thread"
        ),
    }
}

/// Flutter calls this on each engine-managed thread after assigning its role.
/// Display and raster work participates in presentation latency; background
/// and normal engine workers explicitly discard any policy inherited from
/// their creator.
#[cfg(feature = "flutter")]
pub(super) unsafe extern "C" fn set_flutter_thread_priority(priority: sys::FlutterThreadPriority) {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let Some(role) = flutter_realtime_role(priority) else {
            if matches!(
                priority,
                sys::FlutterThreadPriority_kBackground | sys::FlutterThreadPriority_kNormal
            ) {
                normalize_current_worker("flutter-worker");
            } else {
                debug!(
                    unknown = priority,
                    "ignored unknown Flutter thread priority"
                );
            }
            return;
        };
        promote_and_log(role);
    }));
    if result.is_err() {
        // Never unwind through Flutter's C ABI.
        warn!("panic while setting Flutter thread priority");
    }
}

/// Drops inherited compositor priority before an ordinary worker begins any
/// native or blocking work.
pub(super) fn normalize_current_worker(role: &'static str) {
    if let Err(error) = normalize_current_thread() {
        warn!(
            thread = role,
            tid = current_tid(),
            %error,
            "could not restore ordinary worker CPU scheduling"
        );
    }
}

fn normalize_current_thread() -> io::Result<()> {
    let policy = scheduler_policy(0)?;
    if is_realtime_policy(policy) {
        // Linux lets an unprivileged owner lower realtime policy but not clear
        // an inherited RESET_ON_FORK flag.
        set_scheduler(0, normal_policy_preserving_reset(policy), 0)?;
    }
    if current_nice()? < 0 {
        set_nice(0, 0)?;
    }
    release_current_registration();
    Ok(())
}

/// Demotes any elevated helper thread that was created outside Denial's
/// registered compositor/Flutter thread set. This is a defense for native
/// libraries whose internal pthreads inherit Linux scheduling attributes.
pub(super) fn contain_unregistered_priority_threads() {
    let Ok(tasks) = fs::read_dir("/proc/self/task") else {
        return;
    };
    for task in tasks.flatten() {
        let Some(tid) = task
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<libc::pid_t>().ok())
        else {
            continue;
        };
        if is_registered_priority_thread(tid) {
            continue;
        }
        let policy = scheduler_policy(tid).ok();
        let realtime = policy.is_some_and(is_realtime_policy);
        let elevated_nice = nice_for_tid(tid).is_ok_and(|nice| nice < 0);
        if !realtime && !elevated_nice {
            continue;
        }
        let scheduler_demoted = !realtime
            || set_scheduler(
                tid,
                normal_policy_preserving_reset(policy.unwrap_or(libc::SCHED_OTHER)),
                0,
            )
            .is_ok();
        let nice_demoted = !elevated_nice || set_nice(tid, 0).is_ok();
        if scheduler_demoted && nice_demoted {
            warn!(
                tid,
                realtime,
                elevated_nice,
                "removed inherited CPU priority from an unregistered helper thread"
            );
        } else {
            warn!(
                tid,
                realtime,
                elevated_nice,
                "could not remove inherited CPU priority from an unregistered helper thread"
            );
        }
    }
}

fn is_registered_priority_thread(tid: libc::pid_t) -> bool {
    PRIORITY_THREAD_IDS
        .iter()
        .any(|slot| slot.load(Ordering::Acquire) == tid)
}

fn is_realtime_policy(policy: libc::c_int) -> bool {
    matches!(
        policy & !libc::SCHED_RESET_ON_FORK,
        libc::SCHED_RR | libc::SCHED_FIFO
    )
}

fn normal_policy_preserving_reset(policy: libc::c_int) -> libc::c_int {
    libc::SCHED_OTHER | (policy & libc::SCHED_RESET_ON_FORK)
}

#[cfg(feature = "flutter")]
fn flutter_realtime_role(priority: sys::FlutterThreadPriority) -> Option<PriorityRole> {
    match priority {
        sys::FlutterThreadPriority_kDisplay => Some(PriorityRole::FlutterDisplay),
        sys::FlutterThreadPriority_kRaster => Some(PriorityRole::FlutterRaster),
        sys::FlutterThreadPriority_kBackground | sys::FlutterThreadPriority_kNormal => None,
        _ => None,
    }
}

/// Restores a post-fork application child to ordinary scheduling before exec.
///
/// `SCHED_RESET_ON_FORK` already performs this in the kernel. This explicit
/// check is defense in depth and also covers the normal-scheduler fallback
/// when deniald itself inherited a negative nice level.
pub(super) fn reset_application_scheduling() -> io::Result<()> {
    set_scheduler(0, libc::SCHED_OTHER, 0)?;
    let policy = scheduler_policy(0)?;
    if policy & !libc::SCHED_RESET_ON_FORK != libc::SCHED_OTHER {
        return Err(io::Error::from_raw_os_error(libc::EPERM));
    }

    let nice = current_nice()?;
    if nice < 0 {
        // SAFETY: this lowers the child from an elevated negative nice value
        // to the ordinary value zero and touches no shared post-fork state.
        if unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, 0) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    if current_nice()? < 0 {
        return Err(io::Error::from_raw_os_error(libc::EPERM));
    }
    if RT_LIMIT_ARMED.load(Ordering::Acquire) {
        restore_rt_time_soft_limit()?;
    }
    Ok(())
}

fn promote_current_thread(role: PriorityRole) -> Result<Promotion, String> {
    let tid = register_current_thread(role)?;

    let realtime_error = if !RT_BUDGET_EXCEEDED.load(Ordering::Acquire) {
        let priority = RT_PRIORITY.load(Ordering::Acquire);
        if priority > 0 {
            match set_scheduler(tid, libc::SCHED_RR | libc::SCHED_RESET_ON_FORK, priority) {
                Ok(())
                    if !RT_BUDGET_EXCEEDED.load(Ordering::Acquire)
                        && scheduler_policy(tid).is_ok_and(is_realtime_policy) =>
                {
                    return Ok(Promotion {
                        source: PromotionSource::DirectRealtime,
                        scheduler_value: priority,
                    });
                }
                Ok(()) => {
                    let _ = set_scheduler(tid, libc::SCHED_OTHER | libc::SCHED_RESET_ON_FORK, 0);
                    Some("the realtime overrun guard raced with promotion".to_owned())
                }
                Err(error) => Some(error.to_string()),
            }
        } else {
            Some("safe realtime scheduling is unavailable".to_owned())
        }
    } else {
        Some("the process realtime budget was already exceeded".to_owned())
    };

    match promote_current_thread_high_priority(tid) {
        Ok(promotion) => Ok(promotion),
        Err(high_priority_error) => {
            release_current_registration();
            Err(format!(
                "realtime grant failed ({}); high-priority fallback failed ({high_priority_error})",
                realtime_error.as_deref().unwrap_or("unknown error")
            ))
        }
    }
}

fn promote_current_thread_high_priority(tid: libc::pid_t) -> Result<Promotion, String> {
    let nice_level = HIGH_PRIORITY_NICE.load(Ordering::Acquire);
    if nice_level >= 0 {
        return Err("no useful high-priority nice level is available".to_owned());
    }

    let direct_error = match set_nice(tid, nice_level) {
        Ok(()) if nice_for_tid(tid).is_ok_and(|nice| nice <= nice_level) => {
            return Ok(Promotion {
                source: PromotionSource::DirectHighPriority,
                scheduler_value: nice_level,
            });
        }
        Ok(()) => "kernel did not apply the requested nice level".to_owned(),
        Err(error) => error.to_string(),
    };
    let rtkit_error = match RTKIT.get() {
        Some(rtkit) => match rtkit.make_thread_high_priority(tid, nice_level) {
            Ok(()) if nice_for_tid(tid).is_ok_and(|nice| nice <= nice_level) => {
                return Ok(Promotion {
                    source: PromotionSource::RtKitHighPriority,
                    scheduler_value: nice_level,
                });
            }
            Ok(()) => Some("kernel did not expose the RTKit nice grant".to_owned()),
            Err(error) => Some(error.to_string()),
        },
        None => None,
    };

    // A timed-out D-Bus reply is ambiguous. Retain the grant when the kernel
    // confirms that RTKit applied it.
    if nice_for_tid(tid).is_ok_and(|nice| nice < 0) {
        return Ok(Promotion {
            source: PromotionSource::RtKitHighPriority,
            scheduler_value: nice_for_tid(tid).unwrap_or(nice_level),
        });
    }

    Err(match rtkit_error {
        Some(rtkit_error) => {
            format!("direct nice grant failed ({direct_error}); rtkit failed ({rtkit_error})")
        }
        None => format!("direct nice grant failed ({direct_error}); rtkit is unavailable"),
    })
}

fn register_current_thread(role: PriorityRole) -> Result<libc::pid_t, String> {
    let tid = current_tid();
    CURRENT_PRIORITY_REGISTRATION.with(|registration| {
        if let Some(registration) = registration.borrow().as_ref() {
            PRIORITY_THREAD_ROLES[registration.slot].store(role as u8, Ordering::Release);
            return Ok(tid);
        }
        for (slot_index, slot) in PRIORITY_THREAD_IDS.iter().enumerate() {
            let existing = slot.load(Ordering::Acquire);
            if existing == tid
                || slot
                    .compare_exchange(0, tid, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
            {
                PRIORITY_THREAD_ROLES[slot_index].store(role as u8, Ordering::Release);
                *registration.borrow_mut() = Some(ThreadRegistration {
                    slot: slot_index,
                    tid,
                });
                return Ok(tid);
            }
        }
        Err(format!(
            "all {MAX_REGISTERED_PRIORITY_THREADS} guarded priority thread slots are occupied"
        ))
    })
}

fn registered_priority_role(tid: libc::pid_t) -> PriorityRole {
    PRIORITY_THREAD_IDS
        .iter()
        .zip(&PRIORITY_THREAD_ROLES)
        .find_map(|(thread, role)| {
            (thread.load(Ordering::Acquire) == tid)
                .then(|| PriorityRole::from_code(role.load(Ordering::Acquire)))
        })
        .unwrap_or(PriorityRole::Unknown)
}

fn release_current_registration() {
    CURRENT_PRIORITY_REGISTRATION.with(|registration| {
        registration.borrow_mut().take();
    });
}

fn current_tid() -> libc::pid_t {
    // SAFETY: gettid has no arguments and cannot access caller-owned memory.
    unsafe { libc::syscall(libc::SYS_gettid) as libc::pid_t }
}

fn set_scheduler(tid: libc::pid_t, policy: libc::c_int, priority: libc::c_int) -> io::Result<()> {
    if set_scheduler_raw(tid, policy, priority) {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn set_scheduler_raw(tid: libc::pid_t, policy: libc::c_int, priority: libc::c_int) -> bool {
    let parameters = libc::sched_param {
        sched_priority: priority,
    };
    // SAFETY: the kernel reads a valid sched_param for the duration of this
    // syscall. Linux addresses a specific thread by TID here.
    unsafe {
        libc::syscall(
            libc::SYS_sched_setscheduler,
            tid,
            policy,
            &parameters as *const libc::sched_param,
        ) == 0
    }
}

fn scheduler_policy(tid: libc::pid_t) -> io::Result<libc::c_int> {
    // SAFETY: sched_getscheduler has no pointer arguments.
    let policy = unsafe { libc::syscall(libc::SYS_sched_getscheduler, tid) };
    if policy < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(policy as libc::c_int)
    }
}

fn scheduler_policy_raw(tid: libc::pid_t) -> Option<libc::c_int> {
    // SAFETY: sched_getscheduler has no pointer arguments and the raw syscall
    // is safe to use from the SIGXCPU handler.
    let policy = unsafe { libc::syscall(libc::SYS_sched_getscheduler, tid) };
    (policy >= 0).then_some(policy as libc::c_int)
}

fn demote_scheduler_raw(tid: libc::pid_t) -> bool {
    let Some(policy) = scheduler_policy_raw(tid) else {
        return false;
    };
    !is_realtime_policy(policy) || set_scheduler_raw(tid, normal_policy_preserving_reset(policy), 0)
}

fn current_nice() -> io::Result<libc::c_int> {
    nice_for_tid(0)
}

fn nice_for_tid(tid: libc::pid_t) -> io::Result<libc::c_int> {
    // getpriority may legitimately return -1, so errno must distinguish that
    // value from an error.
    // SAFETY: errno is thread-local and `tid` selects a Linux task owned by
    // this process (or the current thread when zero).
    unsafe {
        *libc::__errno_location() = 0;
        let nice = libc::getpriority(libc::PRIO_PROCESS, tid as libc::id_t);
        let error = *libc::__errno_location();
        if nice == -1 && error != 0 {
            Err(io::Error::from_raw_os_error(error))
        } else {
            Ok(nice)
        }
    }
}

fn set_nice(tid: libc::pid_t, nice: libc::c_int) -> io::Result<()> {
    // SAFETY: setpriority receives integral selectors and touches only the
    // selected task's scheduler state.
    if unsafe { libc::setpriority(libc::PRIO_PROCESS, tid as libc::id_t, nice) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn set_nice_raw(tid: libc::pid_t, nice: libc::c_int) -> bool {
    // SAFETY: the raw syscall is async-signal-safe and receives only integral
    // arguments.
    unsafe {
        libc::syscall(
            libc::SYS_setpriority,
            libc::PRIO_PROCESS,
            tid as libc::id_t,
            nice,
        ) == 0
    }
}

fn current_rt_time_limit() -> io::Result<libc::rlimit> {
    let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
    // SAFETY: getrlimit initializes the complete output structure on success.
    if unsafe { libc::getrlimit(libc::RLIMIT_RTTIME, limit.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the successful getrlimit call initialized `limit`.
    Ok(unsafe { limit.assume_init() })
}

fn safe_realtime_limit(current: libc::rlimit) -> Option<RealtimeLimit> {
    // A finite RLIMIT_RTTIME hard limit eventually becomes SIGKILL by kernel
    // contract. Denial is the user's whole graphical session, so realtime is
    // not worth enabling unless that terminal state is impossible.
    if current.rlim_max != libc::RLIM_INFINITY || current.rlim_cur == 0 {
        return None;
    }
    let soft = current.rlim_cur.min(DEFAULT_RT_TIME_SOFT_US);
    (soft > 0).then_some(RealtimeLimit {
        soft,
        hard: libc::RLIM_INFINITY,
    })
}

fn set_rt_time_limit(limit: RealtimeLimit) -> io::Result<()> {
    let limit = libc::rlimit {
        rlim_cur: limit.soft,
        rlim_max: limit.hard,
    };
    // SAFETY: `limit` is a valid immutable rlimit structure.
    if unsafe { libc::setrlimit(libc::RLIMIT_RTTIME, &limit) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn restore_rt_time_soft_limit() -> io::Result<()> {
    let current = current_rt_time_limit()?;
    set_rt_time_limit(RealtimeLimit {
        soft: current.rlim_max,
        hard: current.rlim_max,
    })
}

fn install_sigxcpu_handler() -> io::Result<()> {
    // SAFETY: zero is the documented baseline for sigaction before its mask,
    // handler, and flags are populated below.
    let mut action = unsafe { std::mem::zeroed::<libc::sigaction>() };
    // SAFETY: `action.sa_mask` is writable and properly aligned.
    if unsafe { libc::sigemptyset(&mut action.sa_mask) } != 0 {
        return Err(io::Error::last_os_error());
    }
    action.sa_flags = libc::SA_RESTART;
    action.sa_sigaction = handle_sigxcpu as *const () as usize;
    // SAFETY: `action` remains live for the complete sigaction call and the
    // installed function has the required C signal-handler ABI.
    if unsafe { libc::sigaction(libc::SIGXCPU, &action, std::ptr::null_mut()) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

unsafe extern "C" fn handle_sigxcpu(_signal: libc::c_int) {
    // SAFETY: errno storage is thread-local and valid in a signal handler.
    let saved_errno = unsafe { *libc::__errno_location() };
    RT_BUDGET_EXCEEDED.store(true, Ordering::SeqCst);
    RT_PRIORITY.store(0, Ordering::SeqCst);

    // Also normalize the signal recipient. A native helper that inherited
    // realtime policy may not yet be in Denial's registry.
    let current = current_tid();
    let recipient_role = registered_priority_role(current);
    let mut all_demoted = demote_scheduler_raw(current) & set_nice_raw(current, 0);
    for slot in &PRIORITY_THREAD_IDS {
        let tid = slot.load(Ordering::Acquire);
        if tid <= 0 || tid == current {
            continue;
        }
        // Retain RESET_ON_FORK while demoting: an unprivileged thread may not
        // clear that flag after it has been set.
        all_demoted &= demote_scheduler_raw(tid) & set_nice_raw(tid, 0);
    }

    let message: &[u8] = match (recipient_role, all_demoted) {
        (PriorityRole::Compositor, true) => {
            b"deniald: compositor thread exceeded realtime budget; dropped realtime CPU scheduling\n"
        }
        (PriorityRole::FlutterDisplay, true) => {
            b"deniald: Flutter display thread exceeded realtime budget; dropped realtime CPU scheduling\n"
        }
        (PriorityRole::FlutterRaster, true) => {
            b"deniald: Flutter raster thread exceeded realtime budget; dropped realtime CPU scheduling\n"
        }
        (PriorityRole::Volition, true) => {
            b"deniald: Volition thread exceeded realtime budget; dropped realtime CPU scheduling\n"
        }
        (PriorityRole::Unknown, true) => {
            b"deniald: unregistered thread exceeded realtime budget; dropped realtime CPU scheduling\n"
        }
        (PriorityRole::Compositor, false) => {
            b"deniald: compositor thread exceeded realtime budget; failed to drop all realtime CPU scheduling\n"
        }
        (PriorityRole::FlutterDisplay, false) => {
            b"deniald: Flutter display thread exceeded realtime budget; failed to drop all realtime CPU scheduling\n"
        }
        (PriorityRole::FlutterRaster, false) => {
            b"deniald: Flutter raster thread exceeded realtime budget; failed to drop all realtime CPU scheduling\n"
        }
        (PriorityRole::Volition, false) => {
            b"deniald: Volition thread exceeded realtime budget; failed to drop all realtime CPU scheduling\n"
        }
        (PriorityRole::Unknown, false) => {
            b"deniald: unregistered thread exceeded realtime budget; failed to drop all realtime CPU scheduling\n"
        }
    };
    // SAFETY: write is async-signal-safe and the static byte slice remains
    // valid for the duration of the call.
    let _ = unsafe { libc::write(libc::STDERR_FILENO, message.as_ptr().cast(), message.len()) };
    // SAFETY: restore the interrupted thread's errno before returning.
    unsafe {
        *libc::__errno_location() = saved_errno;
    }
}

fn clear_ambient_capabilities() {
    // Prevent a capability-based compositor wrapper from passing ambient
    // privileges through exec to arbitrary applications. This does not remove
    // deniald's current effective capabilities.
    // SAFETY: prctl receives only integral PR_CAP_AMBIENT_CLEAR_ALL arguments.
    let result = unsafe {
        libc::prctl(
            libc::PR_CAP_AMBIENT,
            libc::PR_CAP_AMBIENT_CLEAR_ALL,
            0,
            0,
            0,
        )
    };
    if result != 0 {
        warn!(
            error = %io::Error::last_os_error(),
            "could not clear ambient process capabilities"
        );
    }
}

fn flag_value_enabled(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn realtime_limit_keeps_an_infinite_hard_guard() {
        assert_eq!(
            safe_realtime_limit(libc::rlimit {
                rlim_cur: libc::RLIM_INFINITY,
                rlim_max: libc::RLIM_INFINITY,
            }),
            Some(RealtimeLimit {
                soft: DEFAULT_RT_TIME_SOFT_US,
                hard: libc::RLIM_INFINITY,
            })
        );
    }

    #[test]
    fn realtime_limit_rejects_a_fatal_hard_limit() {
        assert_eq!(
            safe_realtime_limit(libc::rlimit {
                rlim_cur: 90_000,
                rlim_max: libc::RLIM_INFINITY,
            }),
            Some(RealtimeLimit {
                soft: 90_000,
                hard: libc::RLIM_INFINITY,
            })
        );
        assert_eq!(
            safe_realtime_limit(libc::rlimit {
                rlim_cur: 90_000,
                rlim_max: 120_000,
            }),
            None
        );
        assert_eq!(
            safe_realtime_limit(libc::rlimit {
                rlim_cur: 0,
                rlim_max: libc::RLIM_INFINITY,
            }),
            None
        );
    }

    #[test]
    fn realtime_opt_out_values_are_explicit() {
        for enabled in ["1", " true ", "YES", "On"] {
            assert!(flag_value_enabled(enabled));
        }
        for disabled in ["", "0", "false", "anything"] {
            assert!(!flag_value_enabled(disabled));
        }
    }

    #[test]
    fn ordinary_worker_normalization_is_idempotent() {
        let worker = std::thread::spawn(|| {
            normalize_current_thread().expect("normalize ordinary worker");
            assert!(!is_realtime_policy(
                scheduler_policy(0).expect("worker scheduling policy")
            ));
            assert!(current_nice().is_ok_and(|nice| nice >= 0));
        });
        worker.join().expect("normalization worker");
    }

    #[test]
    fn priority_registration_retains_the_signal_recipient_role() {
        let worker = std::thread::spawn(|| {
            let tid =
                register_current_thread(PriorityRole::FlutterRaster).expect("register test thread");
            assert_eq!(registered_priority_role(tid), PriorityRole::FlutterRaster);
            release_current_registration();
            assert_eq!(registered_priority_role(tid), PriorityRole::Unknown);
        });
        worker.join().expect("priority registration worker");
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn only_display_and_raster_flutter_threads_are_realtime() {
        assert_eq!(
            flutter_realtime_role(sys::FlutterThreadPriority_kDisplay),
            Some(PriorityRole::FlutterDisplay)
        );
        assert_eq!(
            flutter_realtime_role(sys::FlutterThreadPriority_kRaster),
            Some(PriorityRole::FlutterRaster)
        );
        assert_eq!(
            flutter_realtime_role(sys::FlutterThreadPriority_kBackground),
            None
        );
        assert_eq!(
            flutter_realtime_role(sys::FlutterThreadPriority_kNormal),
            None
        );
    }

    #[test]
    #[ignore = "changes the test process scheduler; run explicitly on a session host"]
    fn host_realtime_promotion_probe() {
        initialize();
        let promotion =
            promote_current_thread(PriorityRole::Compositor).expect("latency-critical promotion");
        let policy = scheduler_policy(0).expect("current scheduling policy");
        let limit = current_rt_time_limit().expect("current realtime time limit");
        let base_policy = policy & !libc::SCHED_RESET_ON_FORK;
        // SAFETY: the child performs only scheduling/nice syscalls and _exit;
        // the parent waits for that exact child before restoring its policy.
        let child_was_normal = unsafe {
            let child = libc::fork();
            assert!(child >= 0, "fork failed: {}", io::Error::last_os_error());
            if child == 0 {
                let normal = reset_application_scheduling().is_ok()
                    && scheduler_policy(0).is_ok_and(|child_policy| {
                        child_policy & !libc::SCHED_RESET_ON_FORK == libc::SCHED_OTHER
                    })
                    && current_nice().is_ok_and(|nice| nice >= 0);
                libc::_exit(i32::from(!normal));
            }
            let mut status = 0;
            libc::waitpid(child, &mut status, 0) == child
                && libc::WIFEXITED(status)
                && libc::WEXITSTATUS(status) == 0
        };
        if base_policy == libc::SCHED_RR {
            set_scheduler(0, libc::SCHED_OTHER | libc::SCHED_RESET_ON_FORK, 0)
                .expect("restore ordinary scheduling after probe");
        }
        release_current_registration();
        restore_rt_time_soft_limit().expect("restore inherited realtime limit");
        assert_eq!(promotion.source, PromotionSource::DirectRealtime);
        assert_eq!(base_policy, libc::SCHED_RR);
        assert!(child_was_normal);
        assert!(limit.rlim_cur > 0);
        assert!(limit.rlim_cur < limit.rlim_max);
        assert_eq!(limit.rlim_max, libc::RLIM_INFINITY);
    }

    #[test]
    #[ignore = "deliberately consumes the host realtime soft budget"]
    fn host_realtime_overrun_demotes_instead_of_killing_the_process() {
        initialize();
        let promotion =
            promote_current_thread(PriorityRole::Compositor).expect("latency-critical promotion");
        assert_eq!(promotion.source, PromotionSource::DirectRealtime);

        let started = std::time::Instant::now();
        while started.elapsed() < Duration::from_millis(500) {
            std::hint::spin_loop();
        }

        let policy = scheduler_policy(0).expect("policy after realtime overrun")
            & !libc::SCHED_RESET_ON_FORK;
        assert_eq!(policy, libc::SCHED_OTHER);
        assert!(RT_BUDGET_EXCEEDED.load(Ordering::Acquire));
        assert_eq!(
            current_rt_time_limit()
                .expect("realtime limit after overrun")
                .rlim_max,
            libc::RLIM_INFINITY
        );
        release_current_registration();
        restore_rt_time_soft_limit().expect("restore inherited realtime limit");
    }

    #[test]
    fn application_child_reset_is_normal_and_not_elevated() {
        // SAFETY: after fork, the child performs only the raw scheduling/nice
        // checks above and _exit. The parent waits for that exact child.
        unsafe {
            let child = libc::fork();
            assert!(child >= 0, "fork failed: {}", io::Error::last_os_error());
            if child == 0 {
                let normal = reset_application_scheduling().is_ok()
                    && scheduler_policy(0).is_ok_and(|policy| {
                        policy & !libc::SCHED_RESET_ON_FORK == libc::SCHED_OTHER
                    })
                    && current_nice().is_ok_and(|nice| nice >= 0);
                libc::_exit(i32::from(!normal));
            }
            let mut status = 0;
            assert_eq!(libc::waitpid(child, &mut status, 0), child);
            assert!(libc::WIFEXITED(status));
            assert_eq!(libc::WEXITSTATUS(status), 0);
        }
    }
}
