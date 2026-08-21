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

    let policy =
        scheduler_policy(0).expect("policy after realtime overrun") & !libc::SCHED_RESET_ON_FORK;
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
                && scheduler_policy(0)
                    .is_ok_and(|policy| policy & !libc::SCHED_RESET_ON_FORK == libc::SCHED_OTHER)
                && current_nice().is_ok_and(|nice| nice >= 0);
            libc::_exit(i32::from(!normal));
        }
        let mut status = 0;
        assert_eq!(libc::waitpid(child, &mut status, 0), child);
        assert!(libc::WIFEXITED(status));
        assert_eq!(libc::WEXITSTATUS(status), 0);
    }
}
