use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

/// Installs the candidate vector without allocating and returns the displaced
/// vector without dropping it. The journal is marked resolved before control
/// returns, so callers can defer destruction until hardware and frontend state
/// are finalized.
pub(super) fn install_candidate<T>(
    destination: &mut Vec<T>,
    candidate: &mut Vec<T>,
    resolved: &mut bool,
) -> Vec<T> {
    // `mem::replace` transfers both vectors without dropping either side.
    // Mark the journal resolved before the caller handles the displaced
    // vector, whose element destructors are not required to be infallible.
    let displaced = std::mem::replace(destination, std::mem::take(candidate));
    *resolved = true;
    displaced
}

/// Appends resources whose explicit clear failed after the old scanouts. The
/// returned prefix length is the only portion eligible for an old-framebuffer
/// rollback; quarantined resources must remain untouched for final teardown.
pub(super) fn append_quarantined<T>(restored: &mut Vec<T>, quarantined: &mut Vec<T>) -> usize {
    let rollback_count = restored.len();
    restored.append(quarantined);
    rollback_count
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(super) struct ScanoutKey {
    pub output: u64,
    pub crtc: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ScanoutOrigin {
    Reuse(usize),
    Create,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum ReconcilePlanError {
    InvalidOutput,
    InvalidCrtc,
    DuplicateOutput(u64),
    DuplicateCrtc(u32),
}

impl fmt::Display for ReconcilePlanError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidOutput => formatter.write_str("hotplug topology contains output zero"),
            Self::InvalidCrtc => formatter.write_str("hotplug topology contains CRTC zero"),
            Self::DuplicateOutput(output) => {
                write!(
                    formatter,
                    "output {output} occurs twice in hotplug topology"
                )
            }
            Self::DuplicateCrtc(crtc) => {
                write!(formatter, "CRTC {crtc} occurs twice in hotplug topology")
            }
        }
    }
}

impl std::error::Error for ReconcilePlanError {}

/// Builds the ownership-only part of a scanout transaction without touching
/// any DRM object. A surface is reusable only when both its logical output and
/// CRTC are unchanged. Everything else must be staged as a new surface while
/// the old vector remains alive and capable of driving the current atlas.
pub(super) fn plan_reconcile(
    current: &[ScanoutKey],
    desired: &[ScanoutKey],
) -> Result<Vec<ScanoutOrigin>, ReconcilePlanError> {
    let mut current_outputs = BTreeSet::new();
    let mut current_crtcs = BTreeSet::new();
    let mut existing = BTreeMap::new();
    for (index, key) in current.iter().copied().enumerate() {
        validate_key(key)?;
        if !current_outputs.insert(key.output) {
            return Err(ReconcilePlanError::DuplicateOutput(key.output));
        }
        if !current_crtcs.insert(key.crtc) {
            return Err(ReconcilePlanError::DuplicateCrtc(key.crtc));
        }
        existing.insert(key, index);
    }

    let mut outputs = BTreeSet::new();
    let mut crtcs = BTreeSet::new();
    let mut plan = Vec::with_capacity(desired.len());
    for key in desired {
        validate_key(*key)?;
        if !outputs.insert(key.output) {
            return Err(ReconcilePlanError::DuplicateOutput(key.output));
        }
        if !crtcs.insert(key.crtc) {
            return Err(ReconcilePlanError::DuplicateCrtc(key.crtc));
        }
        plan.push(
            existing
                .get(key)
                .copied()
                .map_or(ScanoutOrigin::Create, ScanoutOrigin::Reuse),
        );
    }
    Ok(plan)
}

fn validate_key(key: ScanoutKey) -> Result<(), ReconcilePlanError> {
    if key.output == 0 {
        return Err(ReconcilePlanError::InvalidOutput);
    }
    if key.crtc == 0 {
        return Err(ReconcilePlanError::InvalidCrtc);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum HotplugPhase {
    #[default]
    Staging,
    Validated,
    Committing,
    Presented,
    Finalized,
    RolledBack,
}

/// Small state journal used to make the point at which hardware rollback is
/// mandatory explicit. In particular, a TEST_ONLY failure never touches the
/// old scanout, while any successful real commit must be compensated if a
/// later commit, vblank wait, or frontend publication fails.
#[derive(Debug, Default)]
pub(super) struct HotplugProgress {
    phase: HotplugPhase,
    committed_outputs: usize,
}

impl HotplugProgress {
    pub(super) fn mark_validated(&mut self) {
        debug_assert_eq!(self.phase, HotplugPhase::Staging);
        self.phase = HotplugPhase::Validated;
    }

    pub(super) fn record_commit(&mut self) {
        debug_assert!(matches!(
            self.phase,
            HotplugPhase::Validated | HotplugPhase::Committing
        ));
        self.phase = HotplugPhase::Committing;
        self.committed_outputs = self.committed_outputs.saturating_add(1);
    }

    pub(super) fn mark_presented(&mut self) {
        debug_assert!(matches!(
            self.phase,
            HotplugPhase::Validated | HotplugPhase::Committing
        ));
        self.phase = HotplugPhase::Presented;
    }

    pub(super) fn mark_finalized(&mut self) {
        debug_assert_eq!(self.phase, HotplugPhase::Presented);
        self.phase = HotplugPhase::Finalized;
    }

    pub(super) fn mark_rolled_back(&mut self) {
        debug_assert!(self.rollback_required());
        self.phase = HotplugPhase::RolledBack;
    }

    pub(super) fn rollback_required(&self) -> bool {
        self.committed_outputs != 0
            && !matches!(
                self.phase,
                HotplugPhase::Finalized | HotplugPhase::RolledBack
            )
    }

    #[cfg(test)]
    fn phase(&self) -> HotplugPhase {
        self.phase
    }
}

#[cfg(test)]
#[path = "hotplug_transaction/tests.rs"]
mod tests;
