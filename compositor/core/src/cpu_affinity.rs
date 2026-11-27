//! Linux CPU-mask backend, independent of Denial's thread classification.
//!
//! Priority and utilization clamps are deliberately outside this interface.
use std::io;

pub use rustix::thread::{CpuSet, Pid, sched_getaffinity, sched_setaffinity};

/// Passed only to compositor-owned tool children that bypass native app launch.
pub const APPLICATION_CPUS_ENV: &str = "DENIAL_APPLICATION_CPUS";

pub fn parse_list(value: &str) -> io::Result<CpuSet> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid CPU list");
    let mut mask = CpuSet::new();
    for part in value.trim().split(',') {
        let mut bounds = part.trim().split('-');
        let start = bounds
            .next()
            .ok_or_else(invalid)?
            .parse::<usize>()
            .map_err(|_| invalid())?;
        let end = bounds
            .next()
            .map(str::parse::<usize>)
            .transpose()
            .map_err(|_| invalid())?
            .unwrap_or(start);
        if bounds.next().is_some() || start > end || end >= CpuSet::MAX_CPU {
            return Err(invalid());
        }
        for cpu in start..=end {
            mask.set(cpu);
        }
    }
    if mask.count() == 0 {
        return Err(invalid());
    }
    Ok(mask)
}

pub fn cpu_list(mask: &CpuSet) -> String {
    (0..CpuSet::MAX_CPU)
        .filter(|&cpu| mask.is_set(cpu))
        .map(|cpu| cpu.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

pub fn is_subset(mask: &CpuSet, domain: &CpuSet) -> bool {
    (0..CpuSet::MAX_CPU).all(|cpu| !mask.is_set(cpu) || domain.is_set(cpu))
}

#[derive(Clone, Copy, Debug)]
pub struct Groups {
    pub applications: CpuSet,
    pub big: CpuSet,
    pub little: CpuSet,
}

impl Groups {
    pub fn new(applications: CpuSet, big: CpuSet, little: CpuSet) -> io::Result<Self> {
        if big.count() == 0
            || little.count() == 0
            || !is_subset(&big, &applications)
            || !is_subset(&little, &applications)
            || (0..CpuSet::MAX_CPU).any(|cpu| big.is_set(cpu) && little.is_set(cpu))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "big/little CPU masks must be nonempty, disjoint and inside the inherited CPU domain",
            ));
        }
        Ok(Self {
            applications,
            big,
            little,
        })
    }

    /// The lowest reported capacity is little; all higher tiers are big.
    /// Missing/homogeneous topology requires an explicit platform mapping.
    pub fn from_capacities(applications: CpuSet, capacities: &[(usize, u32)]) -> io::Result<Self> {
        let mut big = CpuSet::new();
        let mut little = CpuSet::new();
        let minimum = capacities
            .iter()
            .map(|(_, value)| *value)
            .min()
            .unwrap_or(0);
        let mut seen = CpuSet::new();
        for &(cpu, capacity) in capacities {
            if cpu >= CpuSet::MAX_CPU
                || !applications.is_set(cpu)
                || seen.is_set(cpu)
                || capacity == 0
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid CPU capacity data",
                ));
            }
            seen.set(cpu);
            if capacity == minimum {
                little.set(cpu);
            } else {
                big.set(cpu);
            }
        }
        if seen != applications {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "incomplete CPU capacity data",
            ));
        }
        Self::new(applications, big, little)
    }

    /// No allocation, environment access, locks or initialization: usable in
    /// the native launcher's post-fork pre-exec callback.
    pub fn restore_application(&self) -> io::Result<()> {
        sched_setaffinity(None, &self.applications).map_err(Into::into)
    }

    /// For synchronous library launch APIs without a pre-exec hook. Only the
    /// calling thread changes domain; restore it on success, error or unwind.
    pub fn with_application_affinity<T>(
        &self,
        launch: impl FnOnce() -> io::Result<T>,
    ) -> io::Result<T> {
        struct Restore(CpuSet);
        impl Drop for Restore {
            fn drop(&mut self) {
                let _ = sched_setaffinity(None, &self.0);
            }
        }
        let restore = Restore(sched_getaffinity(None)?);
        self.restore_application()?;
        let result = launch();
        sched_setaffinity(None, &restore.0)?;
        result
    }
}

/// Called at entry to compositor-owned command-line tools, before they create
/// threads or exec build tools. Ordinary application launches remove this value.
pub fn restore_tool_affinity() -> io::Result<()> {
    if let Some(value) = std::env::var_os(APPLICATION_CPUS_ENV) {
        let value = value.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "invalid application CPU list")
        })?;
        sched_setaffinity(None, &parse_list(value)?).map_err(io::Error::from)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_or_overlapping_domains() {
        for invalid in ["", "-1", "3-1", "1-2-3", "1,", "1048576"] {
            assert!(parse_list(invalid).is_err(), "{invalid}");
        }
        let all = parse_list("0-7").unwrap();
        assert!(Groups::new(all, parse_list("3-7").unwrap(), parse_list("0-3").unwrap()).is_err());
        assert!(Groups::new(all, parse_list("8").unwrap(), parse_list("0-2").unwrap()).is_err());
    }

    #[test]
    fn requires_complete_heterogeneous_capacity_information() {
        let all = parse_list("0-3").unwrap();
        let groups =
            Groups::from_capacities(all, &[(0, 429), (1, 429), (2, 854), (3, 1024)]).unwrap();
        assert_eq!(groups.big, parse_list("2-3").unwrap());
        assert_eq!(groups.little, parse_list("0-1").unwrap());
        assert!(Groups::from_capacities(all, &[(0, 429)]).is_err());
        assert!(Groups::from_capacities(all, &[(0, 429), (1, 429), (2, 429), (3, 429)]).is_err());
    }

    #[test]
    fn kernel_inheritance_background_override_and_application_restore() {
        // Only this disposable test thread and its child are restricted.
        std::thread::spawn(|| {
            let all = sched_getaffinity(None).unwrap();
            let cpus = (0..CpuSet::MAX_CPU)
                .filter(|&c| all.is_set(c))
                .collect::<Vec<_>>();
            if cpus.len() < 2 {
                return;
            }
            let mut big = CpuSet::new();
            big.set(cpus[0]);
            let mut little = CpuSet::new();
            little.set(cpus[1]);
            let groups = Groups::new(all, big, little).unwrap();
            sched_setaffinity(None, &groups.big).unwrap();
            std::thread::spawn(move || {
                assert_eq!(sched_getaffinity(None).unwrap(), groups.big);
                sched_setaffinity(None, &groups.little).unwrap();
                assert_eq!(sched_getaffinity(None).unwrap(), groups.little);
                groups.restore_application().unwrap();
                assert_eq!(sched_getaffinity(None).unwrap(), groups.applications);
            })
            .join()
            .unwrap();
            assert_eq!(sched_getaffinity(None).unwrap(), groups.big);
            groups
                .with_application_affinity(|| {
                    assert_eq!(sched_getaffinity(None).unwrap(), all);
                    std::thread::spawn(move || assert_eq!(sched_getaffinity(None).unwrap(), all))
                        .join()
                        .unwrap();
                    Ok(())
                })
                .unwrap();
            assert_eq!(sched_getaffinity(None).unwrap(), groups.big);
            let failed: io::Result<()> =
                groups.with_application_affinity(|| Err(io::Error::other("launch failed")));
            assert!(failed.is_err());
            assert_eq!(sched_getaffinity(None).unwrap(), groups.big);
            let panic = std::panic::catch_unwind(|| {
                let _: io::Result<()> =
                    groups.with_application_affinity(|| panic!("launch panicked"));
            });
            assert!(panic.is_err());
            assert_eq!(sched_getaffinity(None).unwrap(), groups.big);
        })
        .join()
        .unwrap();
    }
}
