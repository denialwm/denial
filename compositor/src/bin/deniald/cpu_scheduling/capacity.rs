//! Optional per-thread CPU capacity request for latency-sensitive UI work.
//!
//! DENIAL_UI_CPU_MIN is a Linux utilization value in 0..=1024. Unset means
//! preserve the host policy. This is a runnable-task hint, not a clock floor.
use std::{io, sync::OnceLock};

// Linux sched_attr version 1; libc currently exposes only the shorter v0 ABI.
#[repr(C)]
#[derive(Default)]
struct SchedAttr {
    size: u32,
    sched_policy: u32,
    sched_flags: u64,
    sched_nice: i32,
    sched_priority: u32,
    sched_runtime: u64,
    sched_deadline: u64,
    sched_period: u64,
    sched_util_min: u32,
    sched_util_max: u32,
}

static MINIMUM: OnceLock<Option<u32>> = OnceLock::new();

fn parse_minimum(value: &str) -> Option<u32> {
    value
        .trim()
        .parse::<u32>()
        .ok()
        .filter(|value| *value <= 1024)
}

pub(super) fn apply_configured() -> io::Result<Option<u32>> {
    let minimum = MINIMUM.get_or_init(|| {
        let value = match std::env::var("DENIAL_UI_CPU_MIN") {
            Ok(value) => value,
            Err(std::env::VarError::NotPresent) => return None,
            Err(error) => {
                tracing::warn!(%error, "invalid DENIAL_UI_CPU_MIN; preserving host CPU policy");
                return None;
            }
        };
        let parsed = parse_minimum(&value);
        if parsed.is_none() {
            tracing::warn!(%value, "DENIAL_UI_CPU_MIN must be 0..=1024; preserving host CPU policy");
        }
        parsed
    });
    match *minimum {
        Some(minimum) => {
            request_minimum(minimum)?;
            Ok(Some(minimum))
        }
        None => Ok(None),
    }
}

fn request_minimum(minimum: u32) -> io::Result<()> {
    if minimum > 1024 {
        return Err(io::Error::from_raw_os_error(libc::EINVAL));
    }
    // KEEP_POLICY preserves reset-on-fork as well as the scheduling class.
    // Require the guard already installed by Denial's RT promotion; otherwise
    // an ordinary fallback thread could leak its explicit hint into workers.
    let policy = unsafe { libc::syscall(libc::SYS_sched_getscheduler, 0) };
    if policy < 0 {
        return Err(io::Error::last_os_error());
    }
    if policy as libc::c_int & libc::SCHED_RESET_ON_FORK == 0 {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "CPU hint requires reset-on-fork",
        ));
    }
    // sched_attr contains only integer fields; zero is valid for
    // ignored fields. KEEP_POLICY/PARAMS update the clamp atomically without
    // restoring stale RT priority if the overrun guard concurrently demotes us.
    let mut attr: SchedAttr = SchedAttr::default();
    attr.size = std::mem::size_of::<SchedAttr>() as u32;
    attr.sched_flags = (libc::SCHED_FLAG_KEEP_POLICY
        | libc::SCHED_FLAG_KEEP_PARAMS
        | libc::SCHED_FLAG_UTIL_CLAMP_MIN) as u64;
    attr.sched_util_min = minimum;
    // RESET_ON_FORK also resets utilization clamps in new workers and apps.
    // SAFETY: tid 0 addresses this thread; attr is initialized and lives
    // through the syscall. No process-global scheduler setting is modified.
    let result = unsafe { libc::syscall(libc::SYS_sched_setattr, 0, &attr, 0) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_capacity_configuration() {
        for invalid in ["", "-1", "1025", "512.0", "max", "4294967296"] {
            assert_eq!(parse_minimum(invalid), None);
        }
        assert_eq!(parse_minimum(" 512 "), Some(512));
        assert_eq!(parse_minimum("0"), Some(0));
        assert_eq!(parse_minimum("1024"), Some(1024));
    }

    fn attributes() -> SchedAttr {
        let mut attr: SchedAttr = SchedAttr::default();
        let size = std::mem::size_of::<SchedAttr>() as u32;
        assert_eq!(
            unsafe { libc::syscall(libc::SYS_sched_getattr, 0, &mut attr, size, 0) },
            0
        );
        attr
    }

    #[test]
    fn hint_preserves_priority_and_does_not_leak_to_new_threads() {
        // This is an actual kernel API check on an isolated ordinary worker.
        // Its reset-on-fork flag and hint disappear when the worker exits.
        std::thread::spawn(|| {
            let parameters = libc::sched_param { sched_priority: 0 };
            assert_eq!(
                unsafe {
                    libc::syscall(
                        libc::SYS_sched_setscheduler,
                        0,
                        libc::SCHED_OTHER | libc::SCHED_RESET_ON_FORK,
                        &parameters,
                    )
                },
                0
            );
            let before = attributes();
            request_minimum(512).expect("kernel must support the tested utilization-clamp API");
            let after = attributes();
            assert_eq!(after.sched_util_min, 512);
            assert_eq!(after.sched_util_max, before.sched_util_max);
            assert_eq!(after.sched_policy, before.sched_policy);
            assert_eq!(after.sched_priority, before.sched_priority);
            assert_eq!(after.sched_nice, before.sched_nice);
            assert_ne!(after.sched_flags & libc::SCHED_FLAG_RESET_ON_FORK as u64, 0);
            std::thread::spawn(|| {
                assert_eq!(attributes().sched_util_min, 0);
                // An ordinary worker must not acquire a hint without its guard.
                assert!(request_minimum(512).is_err());
                let parameters = libc::sched_param { sched_priority: 0 };
                assert_eq!(
                    unsafe {
                        libc::syscall(
                            libc::SYS_sched_setscheduler,
                            0,
                            libc::SCHED_OTHER | libc::SCHED_RESET_ON_FORK,
                            &parameters,
                        )
                    },
                    0
                );
                // A replacement UI thread promotes independently, then hints.
                request_minimum(512).unwrap();
                assert_eq!(attributes().sched_util_min, 512);
            })
            .join()
            .unwrap();
            assert_eq!(attributes().sched_util_min, 512);
        })
        .join()
        .unwrap();
    }
}
