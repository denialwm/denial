//! Coordinated logind sleep preparation and locked display restoration.

use super::*;

#[derive(Debug, Default)]
pub(super) struct SleepTransitionState {
    restore_outputs: BTreeSet<OutputId>,
    blanking_outputs: BTreeSet<OutputId>,
    preparing: bool,
    delay_release_pending: bool,
}

impl SleepTransitionState {
    fn prepare(
        &mut self,
        outputs: impl IntoIterator<Item = (OutputId, bool, Option<bool>)>,
    ) -> Vec<idle_policy::IdlePowerRequest> {
        if self.preparing {
            return Vec::new();
        }
        self.preparing = true;
        self.delay_release_pending = true;
        self.restore_outputs.clear();
        self.blanking_outputs.clear();
        for (output, powered, pending_power) in outputs {
            let restore = pending_power.unwrap_or(powered);
            if restore {
                self.restore_outputs.insert(output);
            }
            if powered || restore {
                self.blanking_outputs.insert(output);
            }
        }
        self.blanking_outputs
            .iter()
            .copied()
            .map(|output| idle_policy::IdlePowerRequest {
                output,
                powered: false,
            })
            .collect()
    }

    fn resume(&mut self) -> Vec<idle_policy::IdlePowerRequest> {
        self.preparing = false;
        self.delay_release_pending = false;
        self.blanking_outputs.clear();
        std::mem::take(&mut self.restore_outputs)
            .into_iter()
            .map(|output| idle_policy::IdlePowerRequest {
                output,
                powered: true,
            })
            .collect()
    }

    fn take_delay_release_if_blanked(
        &mut self,
        outputs: impl IntoIterator<Item = (OutputId, bool)>,
    ) -> bool {
        if !self.delay_release_pending {
            return false;
        }
        let powered = outputs
            .into_iter()
            .filter_map(|(output, powered)| powered.then_some(output))
            .collect::<BTreeSet<_>>();
        if self
            .blanking_outputs
            .iter()
            .any(|output| powered.contains(output))
        {
            return false;
        }
        self.delay_release_pending = false;
        true
    }
}

pub(super) fn synchronize_sleep_transition(scanouts: &[Scanout], events: &mut RuntimeState) {
    let transition = events
        .system_controls
        .as_ref()
        .and_then(system_controls::SystemControls::take_sleep_transition);
    let Some(transition) = transition else {
        return;
    };

    match transition {
        system_controls::SleepTransition::Preparing => {
            ensure_session_locked(events);
            let outputs = scanouts
                .iter()
                .map(|scanout| {
                    (
                        scanout.output.id,
                        scanout.powered,
                        events
                            .output_power_requests
                            .get(&scanout.output.id)
                            .copied(),
                    )
                })
                .collect::<Vec<_>>();
            let requests = events.sleep_transition.prepare(outputs);
            events.queue_idle_power_requests(requests);
            info!("secured the session and queued display power-off before system sleep");
        }
        system_controls::SleepTransition::Resumed => {
            // PrepareForSleep(false) can also report a failed sleep. Remaining
            // locked is the fail-closed result in either case.
            ensure_session_locked(events);
            let requests = events.sleep_transition.resume();
            events.queue_idle_power_requests(requests);
            info!("queued locked display restoration after system sleep");
        }
    }
}

pub(super) fn release_sleep_delay_if_ready(scanouts: &[Scanout], events: &mut RuntimeState) {
    if !events.sleep_transition.take_delay_release_if_blanked(
        scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.powered)),
    ) {
        return;
    }
    let released = events
        .system_controls
        .as_ref()
        .is_some_and(system_controls::SystemControls::release_sleep_delay);
    if released {
        info!("released the logind delay inhibitor after display power-off");
    } else {
        warn!("sleep preparation completed without a logind delay inhibitor");
    }
}

fn ensure_session_locked(events: &mut RuntimeState) {
    if let Some(authentication) = events.authentication.as_ref() {
        if !authentication.locked() {
            authentication.lock();
        }
        // Close Wayland input routing in this turn, before releasing logind or
        // allowing any later Flutter work to observe the transition.
        synchronize_authentication_boundary(events);
    } else {
        warn!("could not lock for system sleep: authentication is unavailable");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(id: u64) -> OutputId {
        OutputId(id)
    }

    #[test]
    fn preparation_blanks_and_restores_only_effectively_powered_outputs() {
        let mut state = SleepTransitionState::default();
        let requests = state.prepare([
            (output(1), true, None),
            (output(2), false, None),
            (output(3), false, Some(true)),
            (output(4), true, Some(false)),
        ]);
        assert_eq!(
            requests,
            [
                idle_policy::IdlePowerRequest {
                    output: output(1),
                    powered: false,
                },
                idle_policy::IdlePowerRequest {
                    output: output(3),
                    powered: false,
                },
                idle_policy::IdlePowerRequest {
                    output: output(4),
                    powered: false,
                },
            ]
        );
        assert!(!state.take_delay_release_if_blanked([
            (output(1), true),
            (output(3), false),
            (output(4), false),
        ]));
        assert!(state.take_delay_release_if_blanked([
            (output(1), false),
            (output(3), false),
            (output(4), false),
        ]));
        assert_eq!(
            state.resume(),
            [
                idle_policy::IdlePowerRequest {
                    output: output(1),
                    powered: true,
                },
                idle_policy::IdlePowerRequest {
                    output: output(3),
                    powered: true,
                },
            ]
        );
    }

    #[test]
    fn duplicate_preparation_and_release_are_idempotent() {
        let mut state = SleepTransitionState::default();
        assert_eq!(state.prepare([(output(1), true, None)]).len(), 1);
        assert!(state.prepare([(output(2), true, None)]).is_empty());
        assert!(state.take_delay_release_if_blanked([(output(1), false)]));
        assert!(!state.take_delay_release_if_blanked([(output(1), false)]));
        assert_eq!(
            state.resume(),
            [idle_policy::IdlePowerRequest {
                output: output(1),
                powered: true,
            }]
        );
    }
}
