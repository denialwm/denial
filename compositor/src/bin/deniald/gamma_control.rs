//! DRM gamma-LUT ownership shared by Denial's software dimmer and Wayland clients.

use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::os::fd::AsFd;

const MAX_GAMMA_LUT_ENTRIES: u32 = 65_536;
const SOFTWARE_DIMMING_PACKET_BYTES: usize = 10;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum SoftwareDimmingRequest {
    Read { output: OutputId },
    Set { output: OutputId, level: f64 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SoftwareDimmingRequestError {
    InvalidSize(usize),
    UnsupportedCommand(u8),
    InvalidOutput(i64),
}

impl fmt::Display for SoftwareDimmingRequestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize(size) => {
                write!(formatter, "invalid software-dimming packet size {size}")
            }
            Self::UnsupportedCommand(command) => {
                write!(formatter, "unsupported software-dimming command {command}")
            }
            Self::InvalidOutput(output) => {
                write!(formatter, "invalid software-dimming output id {output}")
            }
        }
    }
}

impl Error for SoftwareDimmingRequestError {}

pub(super) fn decode_software_dimming_request(
    packet: &[u8],
) -> Result<SoftwareDimmingRequest, SoftwareDimmingRequestError> {
    if packet.len() != SOFTWARE_DIMMING_PACKET_BYTES {
        return Err(SoftwareDimmingRequestError::InvalidSize(packet.len()));
    }
    let command = packet[0];
    if command > 1 {
        return Err(SoftwareDimmingRequestError::UnsupportedCommand(command));
    }
    let monitor_id = i64::from_le_bytes(
        packet[1..9]
            .try_into()
            .expect("software-dimming output id has a fixed packet width"),
    );
    let output = u64::try_from(monitor_id)
        .ok()
        .filter(|output| *output != 0)
        .map(OutputId)
        .ok_or(SoftwareDimmingRequestError::InvalidOutput(monitor_id))?;
    match command {
        0 => Ok(SoftwareDimmingRequest::Read { output }),
        1 => Ok(SoftwareDimmingRequest::Set {
            output,
            level: f64::from(packet[9].min(100)) / 100.0,
        }),
        _ => unreachable!("software-dimming command was range checked"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct SoftwareDimmingState {
    pub(super) output: OutputId,
    pub(super) level: f64,
    pub(super) supported: bool,
}

#[derive(Debug)]
struct OutputGamma {
    crtc: crtc::Handle,
    property: property::Handle,
    size: u32,
    original_blob: u64,
    original_ramp: Option<Vec<u16>>,
    installed_blob: Option<u64>,
    external_ramp: Option<Vec<u16>>,
    dirty: bool,
}

impl OutputGamma {
    fn matches(&self, scanout: &Scanout) -> bool {
        self.crtc == scanout.output.crtc
    }
}

#[derive(Debug, Default)]
pub(super) struct GammaController {
    outputs: BTreeMap<OutputId, OutputGamma>,
    unsupported: BTreeMap<OutputId, crtc::Handle>,
    internal_levels: BTreeMap<OutputId, f64>,
}

#[derive(Debug, Default)]
pub(super) struct GammaApplyOutcome {
    pub(super) failed_external: Vec<OutputId>,
    pub(super) failed_outputs: BTreeSet<OutputId>,
}

impl GammaController {
    fn topology_matches<I>(&self, scanouts: I) -> bool
    where
        I: ExactSizeIterator<Item = (OutputId, crtc::Handle)>,
    {
        self.outputs.len() + self.unsupported.len() == scanouts.len()
            && scanouts.into_iter().all(|(output, crtc)| {
                self.outputs
                    .get(&output)
                    .is_some_and(|state| state.crtc == crtc)
                    || self
                        .unsupported
                        .get(&output)
                        .is_some_and(|known| *known == crtc)
            })
    }

    pub(super) fn reconcile_if_needed(
        &mut self,
        drm: &DrmDevice,
        scanouts: &[Scanout],
        force_reapply: bool,
    ) -> Option<BTreeMap<OutputId, u32>> {
        if !force_reapply
            && self.topology_matches(
                scanouts
                    .iter()
                    .map(|scanout| (scanout.output.id, scanout.output.crtc)),
            )
        {
            return None;
        }

        self.unsupported
            .retain(|output, _| scanouts.iter().any(|scanout| scanout.output.id == *output));
        if force_reapply {
            self.unsupported.clear();
        }
        self.outputs.retain(|output, state| {
            if scanouts.iter().any(|scanout| scanout.output.id == *output) {
                return true;
            }
            if let Err(error) = restore_output(drm, state) {
                warn!(?output, %error, "could not restore gamma for a removed output");
            }
            false
        });

        for scanout in scanouts {
            let output = scanout.output.id;
            let retained = self
                .outputs
                .get(&output)
                .is_some_and(|state| state.matches(scanout));
            if retained {
                if force_reapply && let Some(state) = self.outputs.get_mut(&output) {
                    state.dirty = true;
                }
                continue;
            }

            if self
                .unsupported
                .get(&output)
                .is_some_and(|crtc| *crtc == scanout.output.crtc)
            {
                continue;
            }

            if let Some(mut previous) = self.outputs.remove(&output)
                && let Err(error) = restore_output(drm, &mut previous)
            {
                warn!(?output, %error, "could not restore gamma before changing its CRTC");
            }
            match probe_output(drm, scanout) {
                Ok(state) => {
                    self.unsupported.remove(&output);
                    info!(
                        output = scanout.output.name,
                        gamma_size = state.size,
                        "registered DRM gamma-LUT control"
                    );
                    self.outputs.insert(output, state);
                }
                Err(error) => {
                    self.unsupported.insert(output, scanout.output.crtc);
                    debug!(
                        output = scanout.output.name,
                        %error,
                        "DRM gamma-LUT control is unavailable"
                    );
                }
            }
        }

        Some(
            self.outputs
                .iter()
                .map(|(output, state)| (*output, state.size))
                .collect(),
        )
    }

    pub(super) fn apply(
        &mut self,
        drm: &DrmDevice,
        external_changes: impl IntoIterator<Item = (OutputId, Option<Vec<u16>>)>,
        internal_requests: &[SoftwareDimmingRequest],
    ) -> GammaApplyOutcome {
        self.apply_with(external_changes, internal_requests, |state, level| {
            apply_output(drm, state, level)
        })
    }

    fn apply_with(
        &mut self,
        external_changes: impl IntoIterator<Item = (OutputId, Option<Vec<u16>>)>,
        internal_requests: &[SoftwareDimmingRequest],
        mut apply: impl FnMut(&mut OutputGamma, f64) -> Result<(), String>,
    ) -> GammaApplyOutcome {
        for (output, ramp) in external_changes {
            if let Some(state) = self.outputs.get_mut(&output) {
                state.external_ramp = ramp;
                state.dirty = true;
            }
        }
        for request in internal_requests {
            if let SoftwareDimmingRequest::Set { output, level } = *request {
                self.internal_levels.insert(output, level.clamp(0.0, 1.0));
                if let Some(state) = self.outputs.get_mut(&output) {
                    state.dirty = true;
                }
            }
        }

        let mut outcome = GammaApplyOutcome::default();
        let (outputs, internal_levels) = (&mut self.outputs, &self.internal_levels);
        for (&output, state) in outputs.iter_mut().filter(|(_, state)| state.dirty) {
            let level = internal_levels
                .get(&output)
                .copied()
                .unwrap_or(1.0)
                .clamp(0.0, 1.0);
            let had_external = state.external_ramp.is_some();
            if let Err(error) = apply(state, level) {
                warn!(?output, %error, "could not apply DRM gamma LUT");
                outcome.failed_outputs.insert(output);
                if had_external {
                    outcome.failed_external.push(output);
                    state.external_ramp = None;
                    if let Err(reset_error) = apply(state, level) {
                        warn!(?output, %reset_error, "could not restore the internal gamma layer after a client failure");
                    }
                }
                // A failed DRM apply is terminal for this state transition. Retrying the
                // same rejected LUT every frame cannot make it valid; a new client ramp,
                // dimming request, modeset, or topology change will mark it dirty again.
                state.dirty = false;
            }
        }
        outcome
    }

    pub(super) fn internal_level(&self, output: OutputId) -> f64 {
        self.internal_levels
            .get(&output)
            .copied()
            .unwrap_or(1.0)
            .clamp(0.0, 1.0)
    }

    pub(super) fn software_state(&self, output: OutputId, failed: bool) -> SoftwareDimmingState {
        SoftwareDimmingState {
            output,
            level: self.internal_level(output),
            supported: self.outputs.contains_key(&output) && !failed,
        }
    }

    pub(super) fn restore_all(&mut self, drm: &DrmDevice) -> Vec<String> {
        let mut failures = Vec::new();
        for (output, mut state) in std::mem::take(&mut self.outputs) {
            if let Err(error) = restore_output(drm, &mut state) {
                failures.push(format!("output {} gamma restore failed: {error}", output.0));
            }
        }
        failures
    }
}

pub(super) fn synchronize_gamma_control(
    drm: &DrmDevice,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    internal_requests: &[SoftwareDimmingRequest],
    force_reapply: bool,
) -> Vec<SoftwareDimmingState> {
    #[cfg(feature = "flutter")]
    let pending_controls = events
        .pending_software_dimming
        .drain(..)
        .map(PendingSoftwareDimming::into_parts)
        .collect::<Vec<_>>();
    let requests = internal_requests.to_vec();
    #[cfg(feature = "flutter")]
    let requests = {
        let mut requests = requests;
        requests.extend(pending_controls.iter().map(|(request, _)| *request));
        requests
    };
    let capabilities = {
        let mut controller = events
            .gamma_control
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        controller.reconcile_if_needed(drm, scanouts, force_reapply)
    };
    if let (Some(frontend), Some(capabilities)) = (events.wayland.as_mut(), capabilities) {
        frontend.set_gamma_capabilities(capabilities);
    }
    let external_changes = events
        .wayland
        .as_mut()
        .map(|frontend| frontend.take_gamma_changes())
        .unwrap_or_default();
    let (outcome, mut states) = {
        let mut controller = events
            .gamma_control
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let outcome = controller.apply(drm, external_changes, &requests);
        let states = requests
            .iter()
            .map(|request| {
                let output = match *request {
                    SoftwareDimmingRequest::Read { output }
                    | SoftwareDimmingRequest::Set { output, .. } => output,
                };
                controller.software_state(output, outcome.failed_outputs.contains(&output))
            })
            .collect::<Vec<_>>();
        (outcome, states)
    };
    if let Some(frontend) = events.wayland.as_mut() {
        for output in outcome.failed_external {
            frontend.gamma_control_failed(output);
        }
    }
    #[cfg(feature = "flutter")]
    {
        for ((request, reply), state) in pending_controls
            .into_iter()
            .zip(states.iter().skip(internal_requests.len()).copied())
        {
            let result = if state.supported {
                match request {
                    SoftwareDimmingRequest::Read { .. } => Ok(serde_json::json!({
                        "monitor_id": state.output.0,
                        "level": state.level,
                        "supported": true,
                    })),
                    SoftwareDimmingRequest::Set { .. } => Ok(serde_json::json!({
                        "accepted": true,
                        "monitor_id": state.output.0,
                        "level": state.level,
                    })),
                }
            } else if matches!(request, SoftwareDimmingRequest::Read { .. }) {
                Ok(serde_json::json!({
                    "monitor_id": state.output.0,
                    "level": state.level,
                    "supported": false,
                }))
            } else {
                Err(OutputControlFailure::new(
                    "unavailable",
                    "the output does not expose a usable DRM gamma LUT",
                ))
            };
            let _ = reply.send(result);
        }
    }
    states.truncate(internal_requests.len());
    states
}

fn probe_output(drm: &DrmDevice, scanout: &Scanout) -> Result<OutputGamma, Box<dyn Error>> {
    let mut gamma_lut = None;
    let mut gamma_lut_size = None;
    for (handle, value) in drm.get_properties(scanout.output.crtc)? {
        let info = drm.get_property(handle)?;
        let Ok(name) = info.name().to_str() else {
            continue;
        };
        match name {
            "GAMMA_LUT" if matches!(info.value_type(), property::ValueType::Blob) => {
                gamma_lut = Some((handle, value));
            }
            "GAMMA_LUT_SIZE"
                if matches!(info.value_type(), property::ValueType::UnsignedRange(_, _)) =>
            {
                gamma_lut_size = Some(value);
            }
            _ => {}
        }
    }
    let (property, original_blob) = gamma_lut.ok_or("missing GAMMA_LUT property")?;
    let size = u32::try_from(gamma_lut_size.ok_or("missing GAMMA_LUT_SIZE property")?)?;
    if !(2..=MAX_GAMMA_LUT_ENTRIES).contains(&size) {
        return Err(format!("invalid gamma LUT size {size}").into());
    }
    let original_ramp = if original_blob == 0 {
        None
    } else {
        match drm.get_property_blob(original_blob) {
            Ok(bytes) => decode_drm_lut(&bytes, size),
            Err(error) => {
                warn!(
                    output = scanout.output.name,
                    %error,
                    "could not read the inherited DRM gamma LUT; using a linear base"
                );
                None
            }
        }
    };
    Ok(OutputGamma {
        crtc: scanout.output.crtc,
        property,
        size,
        original_blob,
        original_ramp,
        installed_blob: None,
        external_ramp: None,
        dirty: false,
    })
}

fn decode_drm_lut(bytes: &[u8], size: u32) -> Option<Vec<u16>> {
    let size = usize::try_from(size).ok()?;
    if bytes.len() != size.checked_mul(8)? {
        return None;
    }
    let mut ramp = vec![0u16; size.checked_mul(3)?];
    for (index, entry) in bytes.chunks_exact(8).enumerate() {
        ramp[index] = u16::from_ne_bytes(entry[0..2].try_into().ok()?);
        ramp[size + index] = u16::from_ne_bytes(entry[2..4].try_into().ok()?);
        ramp[size * 2 + index] = u16::from_ne_bytes(entry[4..6].try_into().ok()?);
    }
    Some(ramp)
}

fn apply_output(drm: &DrmDevice, state: &mut OutputGamma, level: f64) -> Result<(), String> {
    state.dirty = false;
    if state.external_ramp.is_none() && level >= 1.0 {
        install_blob(drm, state, state.original_blob, None)?;
        return Ok(());
    }

    let size = usize::try_from(state.size).map_err(|error| error.to_string())?;
    let expected = size
        .checked_mul(3)
        .ok_or_else(|| "gamma ramp length overflow".to_owned())?;
    let mut bytes = match state.external_ramp.as_deref() {
        Some(ramp) if ramp.len() == expected => compose_drm_lut(ramp, size, level),
        Some(ramp) => {
            return Err(format!(
                "gamma ramp has {} entries, expected {expected}",
                ramp.len()
            ));
        }
        None => match state.original_ramp.as_deref() {
            Some(ramp) => compose_drm_lut(ramp, size, level),
            None => compose_drm_lut(&linear_ramp(state.size), size, level),
        },
    };
    let blob = drm_ffi::mode::create_property_blob(drm.as_fd(), &mut bytes)
        .map_err(|error| format!("creating GAMMA_LUT blob failed: {error}"))?;
    let blob = u64::from(blob.blob_id);
    install_blob(drm, state, blob, Some(blob))
}

fn compose_drm_lut(base: &[u16], size: usize, level: f64) -> Vec<u8> {
    let level = level.clamp(0.0, 1.0);
    let mut bytes = Vec::with_capacity(size.saturating_mul(8));
    for index in 0..size {
        for channel in 0..3 {
            let value = (f64::from(base[channel * size + index]) * level).round() as u16;
            bytes.extend_from_slice(&value.to_ne_bytes());
        }
        bytes.extend_from_slice(&0u16.to_ne_bytes());
    }
    bytes
}

fn linear_ramp(size: u32) -> Vec<u16> {
    let denominator = u64::from(size.saturating_sub(1).max(1));
    let channel = (0..size)
        .map(|index| ((u64::from(index) * u64::from(u16::MAX)) / denominator) as u16)
        .collect::<Vec<_>>();
    let mut ramp = Vec::with_capacity(channel.len().saturating_mul(3));
    ramp.extend_from_slice(&channel);
    ramp.extend_from_slice(&channel);
    ramp.extend_from_slice(&channel);
    ramp
}

fn install_blob(
    drm: &DrmDevice,
    state: &mut OutputGamma,
    blob: u64,
    owned_blob: Option<u64>,
) -> Result<(), String> {
    if let Err(error) = drm.set_property(
        state.crtc,
        state.property,
        property::Value::Blob(blob).into(),
    ) {
        if let Some(blob) = owned_blob
            && let Err(destroy_error) = drm.destroy_property_blob(blob)
        {
            warn!(blob, %destroy_error, "could not destroy rejected gamma LUT blob");
        }
        state.dirty = true;
        return Err(format!("setting GAMMA_LUT failed: {error}"));
    }
    if let Some(previous) = std::mem::replace(&mut state.installed_blob, owned_blob)
        && let Err(error) = drm.destroy_property_blob(previous)
    {
        warn!(blob = previous, %error, "could not destroy replaced gamma LUT blob");
    }
    Ok(())
}

fn restore_output(drm: &DrmDevice, state: &mut OutputGamma) -> Result<(), String> {
    let result = install_blob(drm, state, state.original_blob, None);
    if result.is_err()
        && let Some(blob) = state.installed_blob.take()
        && let Err(error) = drm.destroy_property_blob(blob)
    {
        warn!(blob, %error, "could not release the compositor gamma LUT blob");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topology_match_requires_the_same_outputs_and_crtcs() {
        let first_crtc = from_u32(1).expect("nonzero CRTC handle");
        let second_crtc = from_u32(2).expect("nonzero CRTC handle");
        let changed_crtc = from_u32(3).expect("nonzero CRTC handle");
        let mut controller = GammaController::default();
        controller.outputs.insert(
            OutputId(10),
            OutputGamma {
                crtc: first_crtc,
                property: from_u32(4).expect("nonzero property handle"),
                size: 256,
                original_blob: 0,
                original_ramp: None,
                installed_blob: None,
                external_ramp: None,
                dirty: false,
            },
        );
        controller.unsupported.insert(OutputId(20), second_crtc);

        assert!(controller.topology_matches(
            [(OutputId(20), second_crtc), (OutputId(10), first_crtc)].into_iter()
        ));
        assert!(!controller.topology_matches(
            [(OutputId(10), changed_crtc), (OutputId(20), second_crtc)].into_iter()
        ));
        assert!(!controller.topology_matches([(OutputId(10), first_crtc)].into_iter()));
        assert!(
            !controller.topology_matches(
                [
                    (OutputId(10), first_crtc),
                    (OutputId(20), second_crtc),
                    (OutputId(30), changed_crtc),
                ]
                .into_iter()
            )
        );
    }

    #[test]
    fn rejected_external_gamma_is_not_retried_without_a_new_change() {
        let output = OutputId(10);
        let mut controller = GammaController::default();
        controller.outputs.insert(
            output,
            OutputGamma {
                crtc: from_u32(1).expect("nonzero CRTC handle"),
                property: from_u32(2).expect("nonzero property handle"),
                size: 2,
                original_blob: 0,
                original_ramp: None,
                installed_blob: None,
                external_ramp: None,
                dirty: false,
            },
        );

        let mut attempts = 0;
        let outcome = controller.apply_with([(output, Some(vec![0; 6]))], &[], |state, _level| {
            attempts += 1;
            // Match install_blob's behavior when DRM rejects the property.
            state.dirty = true;
            Err("rejected gamma LUT".to_owned())
        });

        assert_eq!(
            attempts, 2,
            "client apply and internal restore are attempted"
        );
        assert_eq!(outcome.failed_external, vec![output]);
        assert_eq!(outcome.failed_outputs, BTreeSet::from([output]));
        let state = controller.outputs.get(&output).expect("known output");
        assert!(state.external_ramp.is_none());
        assert!(!state.dirty, "the rejected transition must remain latched");

        let outcome = controller.apply_with(
            std::iter::empty::<(OutputId, Option<Vec<u16>>)>(),
            &[],
            |_state, _level| panic!("an unchanged failed LUT must not be retried"),
        );
        assert!(outcome.failed_external.is_empty());
        assert!(outcome.failed_outputs.is_empty());

        let mut retried_after_change = false;
        let outcome =
            controller.apply_with([(output, Some(vec![u16::MAX; 6]))], &[], |state, _level| {
                retried_after_change = true;
                state.dirty = false;
                Ok(())
            });
        assert!(retried_after_change, "a new client ramp must be attempted");
        assert!(outcome.failed_external.is_empty());
        assert!(outcome.failed_outputs.is_empty());
    }

    #[test]
    fn decodes_software_dimming_requests() {
        let mut read = [0u8; SOFTWARE_DIMMING_PACKET_BYTES];
        read[1..9].copy_from_slice(&42i64.to_le_bytes());
        assert_eq!(
            decode_software_dimming_request(&read),
            Ok(SoftwareDimmingRequest::Read {
                output: OutputId(42)
            })
        );

        let mut set = read;
        set[0] = 1;
        set[9] = 37;
        assert_eq!(
            decode_software_dimming_request(&set),
            Ok(SoftwareDimmingRequest::Set {
                output: OutputId(42),
                level: 0.37,
            })
        );
    }

    #[test]
    fn rejects_invalid_software_dimming_packets() {
        assert_eq!(
            decode_software_dimming_request(&[0; 9]),
            Err(SoftwareDimmingRequestError::InvalidSize(9))
        );
        let mut invalid = [0u8; SOFTWARE_DIMMING_PACKET_BYTES];
        invalid[0] = 2;
        assert_eq!(
            decode_software_dimming_request(&invalid),
            Err(SoftwareDimmingRequestError::UnsupportedCommand(2))
        );
    }

    #[test]
    fn linear_ramp_covers_the_full_unsigned_range() {
        let ramp = linear_ramp(4);
        assert_eq!(&ramp[..4], &[0, 21_845, 43_690, 65_535]);
        assert_eq!(&ramp[4..8], &ramp[..4]);
        assert_eq!(&ramp[8..], &ramp[..4]);
    }

    #[test]
    fn decodes_interleaved_drm_color_lut_entries() {
        let mut bytes = Vec::new();
        for values in [[1u16, 2, 3], [4, 5, 6]] {
            for value in values {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            bytes.extend_from_slice(&0u16.to_ne_bytes());
        }
        assert_eq!(decode_drm_lut(&bytes, 2), Some(vec![1, 4, 2, 5, 3, 6]));
    }

    #[test]
    fn internal_dimming_multiplies_every_external_gamma_channel() {
        let bytes = compose_drm_lut(&[100, 200, 300, 400, 500, 600], 2, 0.5);
        assert_eq!(
            decode_drm_lut(&bytes, 2),
            Some(vec![50, 100, 150, 200, 250, 300]),
        );
    }
}
