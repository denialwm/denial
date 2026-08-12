use std::error::Error;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use smithay::backend::drm::DrmDevice;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::reexports::drm::control::{AtomicCommitFlags, RawResourceHandle, framebuffer};
use tracing::{info, warn};

use super::flutter_runtime::{FlutterRuntime, ReadyFrame};
use super::frame_scheduler::FrameTick;
use super::kms_state::{AtlasSwapchain, Scanout};
use super::{PresentedOutput, RuntimeState, render_audit_enabled};

const MAX_ATOMIC_PLANE_PROPERTIES: usize = 6;
const OUTPUT_SCHEDULER_AUDIT_INTERVAL: Duration = Duration::from_secs(1);
static NEXT_READY_FENCE_TOKEN: AtomicU64 = AtomicU64::new(1);

fn next_ready_fence_token() -> u64 {
    loop {
        let token = NEXT_READY_FENCE_TOKEN.fetch_add(1, Ordering::Relaxed);
        if token != 0 {
            return token;
        }
    }
}

#[derive(Debug)]
struct OutputFrame {
    index: usize,
    screenshot_request_id: Option<u64>,
}

#[derive(Debug, Default)]
struct ReadyFenceSlot {
    fence: Option<OwnedFd>,
    users: usize,
    token: u64,
    signaled: bool,
    discard_on_signal: bool,
}

impl ReadyFenceSlot {
    fn is_available(&self) -> bool {
        self.users == 0
            && self.fence.is_none()
            && self.token == 0
            && !self.signaled
            && !self.discard_on_signal
    }

    fn claim(
        &mut self,
        fence: Option<OwnedFd>,
        users: usize,
        token: u64,
    ) -> Result<(), &'static str> {
        if users == 0 || token == 0 || !self.is_available() {
            return Err("Flutter fence slot is already claimed or has no users");
        }
        self.signaled = fence.is_none();
        self.fence = fence;
        self.users = users;
        self.token = token;
        Ok(())
    }

    fn mark_signaled(&mut self, token: u64) -> bool {
        if token == 0 || token != self.token || self.users == 0 {
            return false;
        }
        self.signaled = true;
        true
    }

    fn can_queue(&self, submission: FenceSubmission) -> bool {
        self.users > 0 && (submission == FenceSubmission::Kernel || self.signaled)
    }

    fn release_user(&mut self) -> Result<(), &'static str> {
        self.users = self
            .users
            .checked_sub(1)
            .ok_or("Flutter frame has no pending fence user")?;
        if self.users == 0 {
            self.fence = None;
            self.token = 0;
            self.signaled = false;
            self.discard_on_signal = false;
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FenceSubmission {
    /// Give the exported sync_file to KMS through IN_FENCE_FD.
    Kernel,
    /// Wait for the sync_file in calloop, then queue the framebuffer without it.
    Userspace,
}

fn is_in_fence_capability_error(error: &std::io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::EPERM | libc::EINVAL | libc::EOPNOTSUPP | libc::ENOSYS)
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ReadyFenceSignal {
    index: usize,
    token: u64,
}

#[derive(Debug)]
pub(super) struct ReadyFenceWatch {
    fence: OwnedFd,
    signal: ReadyFenceSignal,
}

#[derive(Debug, Default)]
pub(super) struct ReadySubmission {
    pub(super) submitted: usize,
    pub(super) fence_watch: Option<ReadyFenceWatch>,
}

impl ReadyFenceWatch {
    pub(super) fn into_parts(self) -> (OwnedFd, ReadyFenceSignal) {
        (self.fence, self.signal)
    }
}

#[derive(Debug)]
struct AtomicPlaneRequest {
    objects: [u32; 1],
    property_counts: [u32; 1],
    properties: [u32; MAX_ATOMIC_PLANE_PROPERTIES],
    values: [u64; MAX_ATOMIC_PLANE_PROPERTIES],
    property_count: usize,
    fence_index: Option<usize>,
}

impl AtomicPlaneRequest {
    fn new(scanout: &Scanout) -> Self {
        let plane: RawResourceHandle = scanout.surface.plane().into();
        let mut request = Self {
            objects: [u32::from(plane)],
            property_counts: [0],
            properties: [0; MAX_ATOMIC_PLANE_PROPERTIES],
            values: [0; MAX_ATOMIC_PLANE_PROPERTIES],
            property_count: 0,
            fence_index: None,
        };
        let properties = scanout.plane_properties;
        let source = scanout.source_rect;
        request.push(properties.framebuffer, 0);
        request.push(properties.source_x, u64::from(source.x) << 16);
        request.push(properties.source_y, u64::from(source.y) << 16);
        request.push(properties.source_width, u64::from(source.width) << 16);
        request.push(properties.source_height, u64::from(source.height) << 16);
        if let Some(property) = properties.in_fence_fd {
            request.fence_index = Some(request.property_count);
            request.push(property, u64::MAX);
        }
        request.property_counts[0] =
            u32::try_from(request.property_count).expect("atomic plane property count fits u32");
        request
    }

    fn push(&mut self, property: smithay::reexports::drm::control::property::Handle, value: u64) {
        debug_assert!(self.property_count < MAX_ATOMIC_PLANE_PROPERTIES);
        self.properties[self.property_count] = u32::from(property);
        self.values[self.property_count] = value;
        self.property_count += 1;
    }

    fn queue(
        &mut self,
        drm: &DrmDevice,
        framebuffer: framebuffer::Handle,
        fence: Option<BorrowedFd<'_>>,
    ) -> std::io::Result<()> {
        self.values[0] = u64::from(u32::from(framebuffer));
        debug_assert!(fence.is_none() || self.fence_index.is_some());
        if let Some(index) = self.fence_index {
            self.values[index] = fence
                .map(|fence| i64::from(fence.as_raw_fd()) as u64)
                .unwrap_or(u64::MAX);
        }
        // DRM_MODE_ATOMIC copies these property arrays during the ioctl.
        // NONBLOCK defers the hardware commit, not access to user memory, so
        // the fixed request remains reusable after this call returns.
        drm_ffi::mode::atomic_commit(
            drm.as_fd(),
            (AtomicCommitFlags::PAGE_FLIP_EVENT | AtomicCommitFlags::NONBLOCK).bits(),
            &mut self.objects,
            &mut self.property_counts,
            &mut self.properties[..self.property_count],
            &mut self.values[..self.property_count],
        )
    }
}

#[derive(Debug)]
struct OutputPipeline {
    scanout_index: usize,
    scanning: usize,
    scanning_screenshot_request_id: Option<u64>,
    ready: Option<OutputFrame>,
    submitted: Option<OutputFrame>,
    powering_off: bool,
    request: AtomicPlaneRequest,
}

#[derive(Debug)]
struct OutputSchedulerAudit {
    interval_started: Instant,
    ready_published_at: Vec<Option<Instant>>,
    fence_signaled_at: Vec<Option<Instant>>,
    last_sequences: Vec<Option<u32>>,
    last_presented_at: Vec<Option<Instant>>,
    submitted_at: Vec<Option<Instant>>,
    ready_published: u64,
    ready_with_fence: u64,
    fence_signals: u64,
    real_submissions: u64,
    presentations: u64,
    sequence_samples: u64,
    sequence_delta_total: u64,
    sequence_delta_max: u32,
    missed_vblanks: u64,
    ready_to_fence: AuditLatency,
    fence_to_submit: AuditLatency,
    ready_to_submit: AuditLatency,
    render_to_publish: AuditLatency,
    presentation_delivery: AuditLatency,
    presentation_to_submit: AuditLatency,
    submit_to_presentation: AuditLatency,
}

#[derive(Debug, Default)]
struct AuditLatency {
    samples: u64,
    total: Duration,
    max: Duration,
}

impl AuditLatency {
    fn record(&mut self, duration: Duration) {
        self.samples = self.samples.saturating_add(1);
        self.total = self.total.saturating_add(duration);
        self.max = self.max.max(duration);
    }

    fn average_us(&self) -> f64 {
        if self.samples == 0 {
            return 0.0;
        }
        self.total.as_secs_f64() * 1_000_000.0 / self.samples as f64
    }
}

impl OutputSchedulerAudit {
    fn new(buffer_count: usize, output_count: usize) -> Self {
        Self {
            interval_started: Instant::now(),
            ready_published_at: vec![None; buffer_count],
            fence_signaled_at: vec![None; buffer_count],
            last_sequences: vec![None; output_count],
            last_presented_at: vec![None; output_count],
            submitted_at: vec![None; output_count],
            ready_published: 0,
            ready_with_fence: 0,
            fence_signals: 0,
            real_submissions: 0,
            presentations: 0,
            sequence_samples: 0,
            sequence_delta_total: 0,
            sequence_delta_max: 0,
            missed_vblanks: 0,
            ready_to_fence: AuditLatency::default(),
            fence_to_submit: AuditLatency::default(),
            ready_to_submit: AuditLatency::default(),
            render_to_publish: AuditLatency::default(),
            presentation_delivery: AuditLatency::default(),
            presentation_to_submit: AuditLatency::default(),
            submit_to_presentation: AuditLatency::default(),
        }
    }

    fn record_ready(&mut self, index: usize, has_fence: bool, rendered_at: Option<Instant>) {
        self.maybe_report();
        self.ready_published = self.ready_published.saturating_add(1);
        if has_fence {
            self.ready_with_fence = self.ready_with_fence.saturating_add(1);
        }
        let now = Instant::now();
        if let Some(rendered_at) = rendered_at {
            self.render_to_publish
                .record(now.saturating_duration_since(rendered_at));
        }
        if let Some(published_at) = self.ready_published_at.get_mut(index) {
            *published_at = Some(now);
        }
        if let Some(signaled_at) = self.fence_signaled_at.get_mut(index) {
            *signaled_at = (!has_fence).then_some(now);
        }
    }

    fn record_fence_signal(&mut self, index: usize) {
        self.maybe_report();
        self.fence_signals = self.fence_signals.saturating_add(1);
        let now = Instant::now();
        if let Some(Some(published_at)) = self.ready_published_at.get(index) {
            self.ready_to_fence
                .record(now.duration_since(*published_at));
        }
        if let Some(signaled_at) = self.fence_signaled_at.get_mut(index) {
            *signaled_at = Some(now);
        }
    }

    fn record_real_submission(&mut self, output_index: usize, buffer_index: usize) {
        self.maybe_report();
        self.real_submissions = self.real_submissions.saturating_add(1);
        let now = Instant::now();
        if let Some(Some(presented_at)) = self.last_presented_at.get(output_index) {
            self.presentation_to_submit
                .record(now.saturating_duration_since(*presented_at));
        }
        if let Some(submitted_at) = self.submitted_at.get_mut(output_index) {
            *submitted_at = Some(now);
        }
        if let Some(published_at) = self
            .ready_published_at
            .get_mut(buffer_index)
            .and_then(Option::take)
        {
            self.ready_to_submit
                .record(now.duration_since(published_at));
        }
        if let Some(signaled_at) = self
            .fence_signaled_at
            .get_mut(buffer_index)
            .and_then(Option::take)
        {
            self.fence_to_submit.record(now.duration_since(signaled_at));
        }
    }

    fn record_presentation(
        &mut self,
        output_index: usize,
        observed_at: Instant,
        sequence: Option<u64>,
    ) {
        self.maybe_report();
        self.presentations = self.presentations.saturating_add(1);
        let delivered_at = Instant::now();
        self.presentation_delivery
            .record(delivered_at.saturating_duration_since(observed_at));
        if let Some(submitted_at) = self
            .submitted_at
            .get_mut(output_index)
            .and_then(Option::take)
        {
            self.submit_to_presentation
                .record(observed_at.saturating_duration_since(submitted_at));
        }
        if let Some(presented_at) = self.last_presented_at.get_mut(output_index) {
            *presented_at = Some(observed_at);
        }
        let Some(sequence) = sequence.map(|sequence| sequence as u32) else {
            return;
        };
        let Some(last_sequence) = self.last_sequences.get_mut(output_index) else {
            return;
        };
        if let Some(previous) = *last_sequence {
            let delta = sequence.wrapping_sub(previous);
            self.sequence_samples = self.sequence_samples.saturating_add(1);
            self.sequence_delta_total = self.sequence_delta_total.saturating_add(u64::from(delta));
            self.sequence_delta_max = self.sequence_delta_max.max(delta);
            self.missed_vblanks = self
                .missed_vblanks
                .saturating_add(u64::from(delta.saturating_sub(1)));
        }
        *last_sequence = Some(sequence);
    }

    fn maybe_report(&mut self) {
        let elapsed = self.interval_started.elapsed();
        if elapsed < OUTPUT_SCHEDULER_AUDIT_INTERVAL {
            return;
        }

        info!(
            target: "deniald::render_audit",
            source = "output_scheduler",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            ready_published = self.ready_published,
            ready_with_fence = self.ready_with_fence,
            fence_signals = self.fence_signals,
            real_submissions = self.real_submissions,
            presentations = self.presentations,
            sequence_samples = self.sequence_samples,
            sequence_delta_avg = if self.sequence_samples == 0 {
                0.0
            } else {
                self.sequence_delta_total as f64 / self.sequence_samples as f64
            },
            sequence_delta_max = self.sequence_delta_max,
            missed_vblanks = self.missed_vblanks,
            ready_to_fence_avg_us = self.ready_to_fence.average_us(),
            ready_to_fence_max_us = self.ready_to_fence.max.as_secs_f64() * 1_000_000.0,
            fence_to_submit_avg_us = self.fence_to_submit.average_us(),
            fence_to_submit_max_us = self.fence_to_submit.max.as_secs_f64() * 1_000_000.0,
            ready_to_submit_avg_us = self.ready_to_submit.average_us(),
            ready_to_submit_max_us = self.ready_to_submit.max.as_secs_f64() * 1_000_000.0,
            render_to_publish_avg_us = self.render_to_publish.average_us(),
            render_to_publish_max_us = self.render_to_publish.max.as_secs_f64() * 1_000_000.0,
            presentation_delivery_avg_us = self.presentation_delivery.average_us(),
            presentation_delivery_max_us = self.presentation_delivery.max.as_secs_f64() * 1_000_000.0,
            presentation_to_submit_avg_us = self.presentation_to_submit.average_us(),
            presentation_to_submit_max_us = self.presentation_to_submit.max.as_secs_f64() * 1_000_000.0,
            submit_to_presentation_avg_us = self.submit_to_presentation.average_us(),
            submit_to_presentation_max_us = self.submit_to_presentation.max.as_secs_f64() * 1_000_000.0,
            "KMS output scheduler audit"
        );

        self.interval_started = Instant::now();
        self.ready_published = 0;
        self.ready_with_fence = 0;
        self.fence_signals = 0;
        self.real_submissions = 0;
        self.presentations = 0;
        self.sequence_samples = 0;
        self.sequence_delta_total = 0;
        self.sequence_delta_max = 0;
        self.missed_vblanks = 0;
        self.ready_to_fence = AuditLatency::default();
        self.fence_to_submit = AuditLatency::default();
        self.ready_to_submit = AuditLatency::default();
        self.render_to_publish = AuditLatency::default();
        self.presentation_delivery = AuditLatency::default();
        self.presentation_to_submit = AuditLatency::default();
        self.submit_to_presentation = AuditLatency::default();
    }
}

pub(super) struct OutputScheduler {
    pipelines: Vec<OutputPipeline>,
    /// Reused damage fan-out scratch. Flutter can raster faster than the
    /// slowest CRTC, so allocating this list for every ready atlas would put
    /// allocator traffic directly in the frame handoff path.
    affected_pipelines: Vec<usize>,
    /// Outputs whose KMS commit succeeded in the current submit pass. Keeping
    /// this allocation lets the Wayland frontend route every window once and
    /// flush clients once, even when one atlas frame touches several CRTCs.
    submitted_outputs: Vec<OutputId>,
    /// Page flips retired by one calloop dispatch, published to Wayland as one
    /// batch so Space refresh and socket flushing do not scale with outputs.
    presented_outputs: Vec<PresentedOutput>,
    /// One Flutter render fence per atlas slot. Pipelines borrow the fd only
    /// for their synchronous atomic ioctl; no Arc allocation or refcount is
    /// needed to fan a frame out across independently clocked outputs.
    ready_fences: Vec<ReadyFenceSlot>,
    fence_submission: FenceSubmission,
    audit: Option<OutputSchedulerAudit>,
    /// Buffer ownership retained while every physical output is DPMS-off.
    /// Flutter's independent-scanout broker requires one initial owner, and
    /// parking it also gives the first waking output a truthful framebuffer.
    parked: Option<usize>,
    latest_index: usize,
    presented_frames: u64,
}

impl OutputScheduler {
    pub(super) fn new(
        scanouts: &[Scanout],
        initial_index: usize,
        buffer_count: usize,
        runtime: &mut FlutterRuntime,
        events: &mut RuntimeState,
    ) -> Result<Self, Box<dyn Error>> {
        if initial_index >= buffer_count {
            return Err("initial atlas index exceeds the scheduler buffer pool".into());
        }
        let powered_outputs = scanouts.iter().filter(|scanout| scanout.powered).count();
        let broker_index = runtime.enable_independent_scanout(powered_outputs.max(1))?;
        if broker_index != initial_index {
            return Err("Flutter and KMS disagree about the initial atlas buffer".into());
        }
        runtime.set_outputs_visible(powered_outputs > 0)?;
        let pipelines = scanouts
            .iter()
            .enumerate()
            .filter(|(_, scanout)| scanout.powered)
            .map(|(scanout_index, scanout)| OutputPipeline {
                scanout_index,
                scanning: initial_index,
                scanning_screenshot_request_id: None,
                ready: None,
                submitted: None,
                powering_off: false,
                request: AtomicPlaneRequest::new(scanout),
            })
            .collect::<Vec<_>>();
        events.pending.clear();
        events.completed_page_flips.clear();
        if powered_outputs > 0 {
            info!(
                powered_outputs,
                pool_outputs = scanouts.len(),
                "enabled atlas output pipelines"
            );
        } else {
            info!(
                pool_outputs = scanouts.len(),
                "parked Flutter atlas while every output is powered off"
            );
        }
        Ok(Self {
            pipelines,
            affected_pipelines: Vec::with_capacity(scanouts.len()),
            submitted_outputs: Vec::with_capacity(scanouts.len()),
            presented_outputs: Vec::with_capacity(scanouts.len()),
            ready_fences: std::iter::repeat_with(ReadyFenceSlot::default)
                .take(buffer_count)
                .collect(),
            fence_submission: FenceSubmission::Kernel,
            audit: render_audit_enabled()
                .then(|| OutputSchedulerAudit::new(buffer_count, powered_outputs)),
            parked: (powered_outputs == 0).then_some(initial_index),
            latest_index: initial_index,
            presented_frames: 0,
        })
    }

    pub(super) fn publish_ready(
        &mut self,
        runtime: &FlutterRuntime,
        ready: ReadyFrame,
        scanouts: &[Scanout],
    ) -> Result<Option<ReadyFenceWatch>, Box<dyn Error>> {
        let ReadyFrame {
            index,
            fence,
            damage,
            screenshot_request_id,
            rendered_at,
        } = ready;
        if self
            .ready_fences
            .get(index)
            .is_none_or(|slot| !slot.is_available())
        {
            return Err("Flutter published an atlas slot still awaiting KMS submission".into());
        }
        if let Some(audit) = self.audit.as_mut() {
            audit.record_ready(index, fence.is_some(), rendered_at);
        }
        self.affected_pipelines.clear();
        self.affected_pipelines
            .extend(
                self.pipelines
                    .iter()
                    .enumerate()
                    .filter_map(|(pipeline_index, pipeline)| {
                        if pipeline.powering_off {
                            return None;
                        }
                        let rect = scanouts[pipeline.scanout_index].source_rect;
                        damage
                            .intersects_pixel_rect(rect.x, rect.y, rect.width, rect.height)
                            .then_some(pipeline_index)
                    }),
            );
        if self.affected_pipelines.is_empty() {
            let Some(fence) = fence else {
                // The raster thread completed this atlas synchronously, so a
                // frame which touches no powered output can be recycled now.
                runtime.publish_to_outputs(index, 0)?;
                return Ok(None);
            };
            let watch_fence = fence.as_fd().try_clone_to_owned()?;
            let token = next_ready_fence_token();
            // Keep the buffer out of Flutter's free list until its GPU fence
            // signals even though no KMS pipeline will consume it.
            runtime.publish_to_outputs(index, 1)?;
            self.ready_fences[index].claim(Some(fence), 1, token)?;
            self.ready_fences[index].discard_on_signal = true;
            return Ok(Some(ReadyFenceWatch {
                fence: watch_fence,
                signal: ReadyFenceSignal { index, token },
            }));
        }
        if self
            .affected_pipelines
            .iter()
            .any(|pipeline_index| self.pipelines[*pipeline_index].ready.is_some())
        {
            return Err("cannot replace an unsubmitted Flutter output frame".into());
        }
        runtime.publish_to_outputs(index, self.affected_pipelines.len())?;
        self.latest_index = index;

        let token = next_ready_fence_token();
        self.ready_fences[index].claim(fence, self.affected_pipelines.len(), token)?;
        for pipeline_index in self.affected_pipelines.iter().copied() {
            let pipeline = &mut self.pipelines[pipeline_index];
            pipeline.ready = Some(OutputFrame {
                index,
                screenshot_request_id,
            });
        }
        if self.fence_submission == FenceSubmission::Userspace
            && let Some(fence) = self.ready_fences[index].fence.as_ref()
        {
            return Ok(Some(ReadyFenceWatch {
                fence: fence.as_fd().try_clone_to_owned()?,
                signal: ReadyFenceSignal { index, token },
            }));
        }
        // Every affected plane advertised IN_FENCE_FD before Flutter enabled
        // native fences. Prefer giving the fence directly to KMS, but retain
        // enough ownership to fall back to a calloop wait if the first real
        // fenced commit proves that the advertised property is unusable.
        Ok(None)
    }

    pub(super) fn acknowledge_ready_fences(
        &mut self,
        runtime: &FlutterRuntime,
        signals: impl IntoIterator<Item = ReadyFenceSignal>,
    ) -> Result<(), Box<dyn Error>> {
        for signal in signals {
            if let Some(slot) = self.ready_fences.get_mut(signal.index) {
                let signaled = slot.mark_signaled(signal.token);
                if signaled && let Some(audit) = self.audit.as_mut() {
                    audit.record_fence_signal(signal.index);
                }
                if signaled && slot.discard_on_signal {
                    runtime.release_output(signal.index)?;
                    slot.release_user()?;
                }
            }
        }
        Ok(())
    }

    pub(super) fn submit_ready(
        &mut self,
        drm: &DrmDevice,
        swapchain: &AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<ReadySubmission, Box<dyn Error>> {
        self.submitted_outputs.clear();
        let mut queue_error = None;
        let mut fence_watch = None;
        let (pipelines, ready_fences, audit) =
            (&mut self.pipelines, &mut self.ready_fences, &mut self.audit);
        for (pipeline_index, pipeline) in pipelines.iter_mut().enumerate() {
            if pipeline.powering_off || pipeline.submitted.is_some() || pipeline.ready.is_none() {
                continue;
            }
            let scanout = &scanouts[pipeline.scanout_index];
            let frame = pipeline.ready.as_ref().expect("checked ready output frame");
            let frame_index = frame.index;
            if !ready_fences[frame_index].can_queue(self.fence_submission) {
                // Kernel submission can queue an unfinished sync_file directly.
                // The userspace fallback waits until the same file is readable.
                continue;
            }
            let framebuffer = swapchain.buffers[frame_index].framebuffer();
            let fence = (self.fence_submission == FenceSubmission::Kernel)
                .then(|| ready_fences[frame_index].fence.as_ref().map(AsFd::as_fd))
                .flatten();
            if let Err(error) = pipeline.request.queue(drm, framebuffer, fence) {
                if self.fence_submission == FenceSubmission::Kernel
                    && fence.is_some()
                    && is_in_fence_capability_error(&error)
                {
                    let slot = &ready_fences[frame_index];
                    fence_watch = Some(ReadyFenceWatch {
                        fence: slot
                            .fence
                            .as_ref()
                            .expect("a failed fenced commit retains its sync_file")
                            .as_fd()
                            .try_clone_to_owned()?,
                        signal: ReadyFenceSignal {
                            index: frame_index,
                            token: slot.token,
                        },
                    });
                    self.fence_submission = FenceSubmission::Userspace;
                    warn!(
                        %error,
                        "KMS rejected a real IN_FENCE_FD commit; waiting for GPU fences in userspace"
                    );
                    break;
                }
                queue_error = Some(error);
                break;
            }
            events.pending.insert(scanout.output.crtc);
            pipeline.submitted = pipeline.ready.take();
            if let Some(audit) = audit.as_mut() {
                audit.record_real_submission(pipeline_index, frame_index);
            }
            ready_fences[frame_index].release_user()?;
            if ready_fences[frame_index].users == 0 {
                // The atomic ioctl has taken its own reference to IN_FENCE_FD
                // before returning, so userspace can close the final fd now.
                debug_assert!(ready_fences[frame_index].fence.is_none());
            }
            self.submitted_outputs.push(scanout.output.id);
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.outputs_submitted(&self.submitted_outputs)?;
        }
        if let Some(error) = queue_error {
            return Err(error.into());
        }
        Ok(ReadySubmission {
            submitted: self.submitted_outputs.len(),
            fence_watch,
        })
    }

    /// A completed Flutter atlas must remain in the runtime broker while any
    /// output is still waiting to submit the preceding generation. This
    /// bounds producer work without replacing a buffer whose GPU fence may
    /// still be pending.
    pub(super) fn can_accept_ready(&self) -> bool {
        self.pipelines
            .iter()
            .all(|pipeline| pipeline.ready.is_none())
    }

    pub(super) fn handle_completions(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchain, scanouts, events)
    }

    pub(super) fn retire_completions_for_shutdown(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchain, scanouts, events)?;
        Ok(())
    }

    fn handle_completions_inner(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.presented_outputs.clear();
        let mut processing_error = None;
        while let Some(completion) = events.completed_page_flips.pop_front() {
            let Some(pipeline_index) = self.pipelines.iter().position(|pipeline| {
                scanouts[pipeline.scanout_index].output.crtc == completion.crtc
            }) else {
                continue;
            };
            let pipeline = &mut self.pipelines[pipeline_index];
            let Some(presented) = pipeline.submitted.take() else {
                continue;
            };
            let previous = pipeline.scanning;
            pipeline.scanning = presented.index;
            pipeline.scanning_screenshot_request_id = presented.screenshot_request_id;
            if let Err(error) = runtime.release_output(previous) {
                processing_error = Some(error);
                break;
            }
            swapchain.present(presented.index);
            self.latest_index = presented.index;

            let presentation = PresentedOutput {
                id: scanouts[pipeline.scanout_index].output.id,
                observed_at: completion.observed_at,
                presented_at: completion.presented_at,
                sequence: completion.sequence,
            };
            if let Some(audit) = self.audit.as_mut() {
                audit.record_presentation(
                    pipeline_index,
                    completion.observed_at,
                    completion.sequence,
                );
            }
            self.presented_outputs.push(presentation);
            self.presented_frames = self.presented_frames.saturating_add(1);
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.outputs_presented(&self.presented_outputs)?;
        }
        if let Some(error) = processing_error {
            return Err(error);
        }
        Ok(())
    }

    pub(super) fn presented_outputs(&self) -> &[PresentedOutput] {
        &self.presented_outputs
    }

    pub(super) fn process_screencopies_at_tick(
        &self,
        tick: FrameTick,
        renderer: &mut GlesRenderer,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        let Some(buffer_index) = self.framebuffer_index_for_output(tick.output, scanouts) else {
            return Ok(());
        };
        let Some(frontend) = events.wayland.as_mut() else {
            return Ok(());
        };
        if !frontend.has_pending_screencopy_for_output(tick.output) {
            return Ok(());
        }
        let timestamp = tick
            .presented_at
            .unwrap_or_else(|| frontend.screencopy_clock_now());
        frontend.process_screencopies(
            renderer,
            &mut swapchain.buffers[buffer_index].dmabuf,
            tick.output,
            timestamp,
        )
    }

    pub(super) fn framebuffer_index_for_output(
        &self,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Option<usize> {
        self.pipelines
            .iter()
            .find(|pipeline| {
                !pipeline.powering_off && scanouts[pipeline.scanout_index].output.id == output
            })
            .map(|pipeline| pipeline.scanning)
    }

    pub(super) fn screenshot_framebuffer_for_output(
        &self,
        output: OutputId,
        request_id: u64,
        scanouts: &[Scanout],
    ) -> Option<usize> {
        self.pipelines
            .iter()
            .find(|pipeline| {
                !pipeline.powering_off
                    && scanouts[pipeline.scanout_index].output.id == output
                    && pipeline.scanning_screenshot_request_id == Some(request_id)
            })
            .map(|pipeline| pipeline.scanning)
    }

    pub(super) fn has_submitted(&self) -> bool {
        self.pipelines
            .iter()
            .any(|pipeline| pipeline.submitted.is_some())
    }

    pub(super) fn has_pending_scanout_work(&self) -> bool {
        self.pipelines
            .iter()
            .any(|pipeline| pipeline.ready.is_some() || pipeline.submitted.is_some())
    }

    pub(super) fn begin_power_off(
        &mut self,
        runtime: &FlutterRuntime,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Result<bool, Box<dyn Error>> {
        let Some(pipeline) = self
            .pipelines
            .iter_mut()
            .find(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
        else {
            return Ok(false);
        };
        pipeline.powering_off = true;
        if let Some(ready) = pipeline.ready.take() {
            runtime.release_output(ready.index)?;
            self.ready_fences
                .get_mut(ready.index)
                .ok_or("DPMS output frame exceeds the Flutter fence pool")?
                .release_user()?;
        }
        let submitted = pipeline.submitted.is_some();
        self.repair_latest_index();
        Ok(submitted)
    }

    pub(super) fn cancel_power_off(&mut self, output: OutputId, scanouts: &[Scanout]) {
        if let Some(pipeline) = self
            .pipelines
            .iter_mut()
            .find(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
        {
            pipeline.powering_off = false;
        }
    }

    pub(super) fn power_off(
        &mut self,
        runtime: &FlutterRuntime,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Result<(), Box<dyn Error>> {
        let Some(index) = self
            .pipelines
            .iter()
            .position(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
        else {
            return Ok(());
        };
        if self.pipelines[index].submitted.is_some() {
            return Err("cannot power off an output with a submitted page flip".into());
        }

        let pipeline = self.pipelines.remove(index);
        if let Some(ready) = pipeline.ready {
            runtime.release_output(ready.index)?;
            self.ready_fences
                .get_mut(ready.index)
                .ok_or("DPMS output frame exceeds the Flutter fence pool")?
                .release_user()?;
        }
        if self.pipelines.is_empty() {
            debug_assert!(self.parked.is_none());
            self.parked = Some(pipeline.scanning);
            self.latest_index = pipeline.scanning;
        } else {
            runtime.release_output(pipeline.scanning)?;
            self.repair_latest_index();
        }
        Ok(())
    }

    pub(super) fn stable_framebuffer_index(&self) -> usize {
        self.parked
            .or_else(|| self.pipelines.first().map(|pipeline| pipeline.scanning))
            .unwrap_or(self.latest_index)
    }

    pub(super) fn power_on(
        &mut self,
        runtime: &FlutterRuntime,
        scanout_index: usize,
        framebuffer_index: usize,
        scanouts: &[Scanout],
    ) -> Result<(), Box<dyn Error>> {
        let output = scanouts
            .get(scanout_index)
            .ok_or("DPMS wake references a missing scanout")?;
        if self
            .pipelines
            .iter()
            .any(|pipeline| pipeline.scanout_index == scanout_index)
        {
            return Ok(());
        }

        if self.pipelines.is_empty() {
            if self.parked != Some(framebuffer_index) {
                return Err("DPMS wake disagrees with the parked Flutter buffer".into());
            }
            self.parked = None;
        } else {
            runtime.retain_outputs(framebuffer_index, 1)?;
        }
        self.pipelines.push(OutputPipeline {
            scanout_index,
            scanning: framebuffer_index,
            scanning_screenshot_request_id: None,
            ready: None,
            submitted: None,
            powering_off: false,
            request: AtomicPlaneRequest::new(output),
        });
        self.latest_index = framebuffer_index;
        Ok(())
    }

    fn repair_latest_index(&mut self) {
        let still_owned = self.parked == Some(self.latest_index)
            || self.pipelines.iter().any(|pipeline| {
                pipeline.scanning == self.latest_index
                    || pipeline
                        .ready
                        .as_ref()
                        .is_some_and(|frame| frame.index == self.latest_index)
                    || pipeline
                        .submitted
                        .as_ref()
                        .is_some_and(|frame| frame.index == self.latest_index)
            });
        if !still_owned
            && let Some(scanning) = self
                .parked
                .or_else(|| self.pipelines.first().map(|pipeline| pipeline.scanning))
        {
            self.latest_index = scanning;
        }
    }

    /// Brings every CRTC onto one complete atlas generation before a topology
    /// transaction. The steady-state path is deliberately per-output; the
    /// temporary convergence gives the existing rollback journal one truthful
    /// framebuffer to restore if hotplug validation fails.
    pub(super) fn converge_for_topology(
        &mut self,
        runtime: &FlutterRuntime,
        drm: &DrmDevice,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<usize, Box<dyn Error>> {
        if self.has_pending_scanout_work() {
            return Err("cannot converge outputs while a frame is ready or submitted".into());
        }
        if self.pipelines.len() != scanouts.iter().filter(|scanout| scanout.powered).count() {
            return Err("output scheduler topology no longer matches KMS scanouts".into());
        }

        if self.pipelines.is_empty() {
            events.pending.clear();
            events.completed_page_flips.clear();
            return self
                .parked
                .ok_or_else(|| "powered-off scheduler lost its parked atlas".into());
        }

        let converged = self.latest_index;
        runtime.retain_outputs(converged, self.pipelines.len())?;
        let framebuffer = swapchain.buffers[converged].framebuffer();
        if let Err(error) = super::commit_atlas_now(drm, scanouts, framebuffer) {
            for _ in 0..self.pipelines.len() {
                runtime.release_output(converged)?;
            }
            return Err(error);
        }

        for pipeline in &mut self.pipelines {
            if let Some(ready) = pipeline.ready.take() {
                runtime.release_output(ready.index)?;
            }
            runtime.release_output(pipeline.scanning)?;
            pipeline.scanning = converged;
        }
        self.ready_fences.fill_with(ReadyFenceSlot::default);
        swapchain.present(converged);
        events.pending.clear();
        events.completed_page_flips.clear();
        Ok(converged)
    }

    pub(super) fn presented_frames(&self) -> u64 {
        self.presented_frames
    }
}

#[cfg(test)]
mod tests {
    use std::io;
    use std::os::unix::net::UnixStream;
    use std::time::Instant;

    use super::{
        FenceSubmission, OutputSchedulerAudit, ReadyFenceSlot, is_in_fence_capability_error,
    };

    #[test]
    fn ready_fence_slot_closes_only_after_its_last_pipeline_user() {
        let mut slot = ReadyFenceSlot::default();
        assert!(slot.is_available());
        slot.claim(None, 2, 11).unwrap();
        assert!(!slot.is_available());
        assert!(slot.can_queue(FenceSubmission::Kernel));
        assert!(slot.can_queue(FenceSubmission::Userspace));
        assert!(slot.claim(None, 1, 12).is_err());

        slot.release_user().unwrap();
        assert_eq!(slot.users, 1);
        slot.release_user().unwrap();
        assert!(slot.is_available());
        assert!(slot.release_user().is_err());
        assert!(slot.claim(None, 0, 13).is_err());
        assert!(slot.claim(None, 1, 0).is_err());
    }

    #[test]
    fn ready_fence_slot_ignores_stale_signals() {
        let mut slot = ReadyFenceSlot::default();
        let (fence, _peer) = UnixStream::pair().unwrap();
        slot.claim(Some(fence.into()), 1, 21).unwrap();
        assert!(slot.can_queue(FenceSubmission::Kernel));
        assert!(!slot.can_queue(FenceSubmission::Userspace));
        assert!(!slot.mark_signaled(20));
        assert!(!slot.can_queue(FenceSubmission::Userspace));
        assert!(slot.mark_signaled(21));
        assert!(slot.can_queue(FenceSubmission::Userspace));

        slot.release_user().unwrap();
        assert!(!slot.mark_signaled(21));
        assert!(slot.is_available());
    }

    #[test]
    fn discarded_gpu_frame_is_not_reusable_until_its_fence_user_retires() {
        let mut slot = ReadyFenceSlot::default();
        let (fence, _peer) = UnixStream::pair().unwrap();
        slot.claim(Some(fence.into()), 1, 31).unwrap();
        slot.discard_on_signal = true;

        assert!(!slot.is_available());
        slot.release_user().unwrap();
        assert!(slot.is_available());
    }

    #[test]
    fn fenced_commit_capability_errors_are_narrowly_classified() {
        for errno in [libc::EPERM, libc::EINVAL, libc::EOPNOTSUPP, libc::ENOSYS] {
            assert!(is_in_fence_capability_error(&io::Error::from_raw_os_error(
                errno
            )));
        }
        for errno in [libc::EACCES, libc::EBUSY, libc::ENOMEM] {
            assert!(!is_in_fence_capability_error(
                &io::Error::from_raw_os_error(errno)
            ));
        }
    }

    #[test]
    fn scheduler_audit_counts_wrapped_drm_sequence_gaps() {
        let mut audit = OutputSchedulerAudit::new(4, 1);
        let now = Instant::now();
        audit.record_presentation(0, now, Some(u64::from(u32::MAX - 1)));
        audit.record_presentation(0, now, Some(1));

        assert_eq!(audit.presentations, 2);
        assert_eq!(audit.sequence_samples, 1);
        assert_eq!(audit.sequence_delta_total, 3);
        assert_eq!(audit.sequence_delta_max, 3);
        assert_eq!(audit.missed_vblanks, 2);
    }
}
