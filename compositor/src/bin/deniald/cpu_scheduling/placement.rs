//! Opt-in big-default allocation; names are bounded compatibility rules for
//! unmodified libraries, never evidence that arbitrary normal work is background.
use denial_core::cpu_affinity::{self, CpuSet, Groups, Pid, sched_getaffinity, sched_setaffinity};
use std::{
    fs, io,
    sync::{Mutex, OnceLock},
};

static GROUPS: OnceLock<Option<Groups>> = OnceLock::new();
// Prevent the guard from narrowing a spawning thread during a library launch
// that cannot install our normal pre-exec callback. Never locked after fork.
static LIBRARY_LAUNCH: Mutex<()> = Mutex::new(());

/// Called once on the sole startup thread, before native/engine workers exist.
pub(super) fn initialize() -> Option<String> {
    let groups = GROUPS.get_or_init(|| {
        match std::env::var("DENIAL_CPU_PLACEMENT").as_deref() {
            Err(std::env::VarError::NotPresent) | Ok("0") => return None,
            Ok("1") => {},
            _ => { tracing::warn!("DENIAL_CPU_PLACEMENT must be 0 or 1; CPU allocation disabled"); return None; }
        }
        match configure() {
            Ok(groups) => {
                tracing::info!(big=%cpu_affinity::cpu_list(&groups.big), little=%cpu_affinity::cpu_list(&groups.little),
                    applications=%cpu_affinity::cpu_list(&groups.applications), "enabled big-default CPU allocation");
                Some(groups)
            },
            Err(error) => { tracing::warn!(%error, "CPU allocation unavailable; retaining inherited affinity (explicit DENIAL_BIG_CPUS and DENIAL_LITTLE_CPUS may supply missing topology)"); None }
        }
    });
    groups
        .as_ref()
        .map(|groups| cpu_affinity::cpu_list(&groups.applications))
}

fn configure() -> io::Result<Groups> {
    let original = sched_getaffinity(None)?;
    let groups = match (
        std::env::var("DENIAL_BIG_CPUS"),
        std::env::var("DENIAL_LITTLE_CPUS"),
    ) {
        (Ok(big), Ok(little)) => Groups::new(
            original,
            cpu_affinity::parse_list(&big)?,
            cpu_affinity::parse_list(&little)?,
        )?,
        (Err(std::env::VarError::NotPresent), Err(std::env::VarError::NotPresent)) => {
            let capacities = (0..CpuSet::MAX_CPU)
                .filter(|&cpu| original.is_set(cpu))
                .map(|cpu| {
                    let value = fs::read_to_string(format!(
                        "/sys/devices/system/cpu/cpu{cpu}/cpu_capacity"
                    ))?;
                    let capacity = value.trim().parse().map_err(|_| {
                        io::Error::new(io::ErrorKind::InvalidData, "invalid kernel CPU capacity")
                    })?;
                    Ok((cpu, capacity))
                })
                .collect::<io::Result<Vec<_>>>()?;
            Groups::from_capacities(original, &capacities)?
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "both explicit CPU masks must be set together",
            ));
        }
    };
    // Verify both classes before enabling the policy, then leave the creator
    // on big so driver/engine rendering workers inherit the right domain.
    let result = apply(None, &groups.little).and_then(|()| apply(None, &groups.big));
    if let Err(error) = result {
        groups.restore_application()?;
        return Err(error);
    }
    Ok(groups)
}

pub(super) fn enabled() -> bool {
    GROUPS.get().is_some_and(Option::is_some)
}

fn apply(tid: Option<Pid>, mask: &CpuSet) -> io::Result<()> {
    if sched_getaffinity(tid)? != *mask {
        sched_setaffinity(tid, mask)?;
    }
    let actual = sched_getaffinity(tid)?;
    if actual.count() == 0 || !cpu_affinity::is_subset(&actual, mask) {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "kernel did not retain requested CPU class",
        ));
    }
    Ok(())
}

pub(super) fn current(background: bool) {
    let Some(Some(groups)) = GROUPS.get() else {
        return;
    };
    if let Err(error) = apply(
        None,
        if background {
            &groups.little
        } else {
            &groups.big
        },
    ) {
        tracing::warn!(%error, background, "could not place current Denial worker");
    }
}

pub(super) fn restore_application() -> io::Result<()> {
    match GROUPS.get() {
        Some(Some(groups)) => groups.restore_application(),
        _ => Ok(()),
    }
}

pub(super) fn with_application_affinity<T>(
    launch: impl FnOnce() -> io::Result<T>,
) -> io::Result<T> {
    let Some(Some(groups)) = GROUPS.get() else {
        return launch();
    };
    let _guard = LIBRARY_LAUNCH
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    groups.with_application_affinity(launch)
}

fn background_name(name: &str) -> bool {
    matches!(
        name,
        "denial-portal-i"
            | "denial-priority"
            | "denial-control"
            | "denial-control-"
            | "denial-authenti"
            | "denial-audio"
            | "denial-brightne"
            | "denial-session-"
            | "denial-notifica"
            | "denial-orientat"
            | "denial-screensh"
            | "denial-xembed-t"
            | "denial-child-re"
            | "denial-clipboar"
            | "Shm dropping th"
            | "Dart Profiler T"
    ) || name.strip_prefix("deniald:zcq").is_some_and(decimal_suffix)
}

fn decimal_suffix(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// Late library workers can overwrite inherited affinity (Mesa disk cache).
/// Reuse the existing slow priority guard; native owned workers are set at entry.
/// This reconciler deliberately does not promise pre-first-job classification
/// for unmodified third-party background queues.
pub(super) fn reconcile() {
    let Some(Some(groups)) = GROUPS.get() else {
        return;
    };
    let _guard = LIBRARY_LAUNCH
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Ok(tasks) = fs::read_dir("/proc/self/task") else {
        return;
    };
    for entry in tasks.flatten() {
        let Some(tid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<i32>().ok())
            .and_then(Pid::from_raw)
        else {
            continue;
        };
        let Ok(name) = fs::read_to_string(entry.path().join("comm")) else {
            continue;
        };
        let name = name.trim();
        let background = background_name(name)
            || matches!(
                super::scheduler_policy(tid.as_raw_pid()),
                Ok(libc::SCHED_BATCH | libc::SCHED_IDLE)
            )
            || super::nice_for_tid(tid.as_raw_pid()).is_ok_and(|nice| nice == 19);
        if let Err(error) = apply(
            Some(tid),
            if background {
                &groups.little
            } else {
                &groups.big
            },
        ) {
            if error.raw_os_error() != Some(libc::ESRCH) {
                tracing::warn!(%error, tid=tid.as_raw_pid(), %name, "could not reconcile Denial CPU allocation");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn application_exec_restores_original_domain() {
        use std::os::unix::process::CommandExt;
        use std::process::Command;
        // Isolate the process-wide configuration from the rest of the suite.
        if std::env::var_os("DENIAL_AFFINITY_TEST_CHILD").is_none() {
            assert!(Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "cpu_scheduling::placement::tests::application_exec_restores_original_domain"])
                .env("DENIAL_AFFINITY_TEST_CHILD", "1")
                .status().unwrap().success());
            return;
        }
        let all = sched_getaffinity(None).unwrap();
        let cpus = (0..CpuSet::MAX_CPU)
            .filter(|&cpu| all.is_set(cpu))
            .collect::<Vec<_>>();
        if cpus.len() < 2 {
            return;
        }
        let mut big = CpuSet::new();
        big.set(cpus[0]);
        let mut little = CpuSet::new();
        little.set(cpus[1]);
        GROUPS
            .set(Some(Groups::new(all, big, little).unwrap()))
            .unwrap();
        sched_setaffinity(None, &big).unwrap();
        let mut command = Command::new("/bin/cat");
        command.arg("/proc/self/status");
        // SAFETY: exercise the same syscall-only callback used by app launch.
        unsafe {
            command.pre_exec(super::super::reset_application_scheduling);
        }
        let output = command.output().unwrap();
        assert!(output.status.success());
        let status = String::from_utf8(output.stdout).unwrap();
        let mask = status
            .lines()
            .find_map(|line| line.strip_prefix("Cpus_allowed_list:"))
            .unwrap();
        assert_eq!(cpu_affinity::parse_list(mask).unwrap(), all);
        assert_eq!(sched_getaffinity(None).unwrap(), big);
    }

    #[test]
    fn mixed_and_unknown_workers_retain_big_default() {
        for name in [
            "deniald:zcfq0",
            "deniald:zfq0",
            "deniald:gdrv0",
            "deniald:gl0",
            "io.flutter.io",
            "io.worker.1",
            "DartWorker",
            "blocking-1",
            "deniald",
            "denial-screenco",
        ] {
            assert!(!background_name(name), "{name}");
        }
        for name in [
            "deniald:zcq0",
            "denial-priority",
            "denial-screensh",
            "Shm dropping th",
            "denial-control-",
        ] {
            assert!(background_name(name), "{name}");
        }
    }
}
