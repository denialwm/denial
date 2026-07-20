use std::error::Error;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use smithay::backend::drm::DrmDevice;
use smithay::output::Mode as OutputMode;
use smithay::reexports::drm::control::{AtomicCommitFlags, RawResourceHandle, framebuffer};
use tracing::info;

use super::flutter_runtime::{FlutterRuntime, ReadyFrame};
use super::kms_state::{AtlasSwapchain, Scanout};
use super::{PresentedOutput, RuntimeState};

const MAX_ATOMIC_PLANE_PROPERTIES: usize = 6;
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
    repeated: bool,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct PhysicalVsync {
    pub(super) interval: Duration,
    pub(super) observed_at: Instant,
    pub(super) presented_at: Option<Duration>,
}

#[derive(Debug, Default)]
struct ReadyFenceSlot {
    fence: Option<OwnedFd>,
    users: usize,
    token: u64,
    signaled: bool,
}

impl ReadyFenceSlot {
    fn is_available(&self) -> bool {
        self.users == 0 && self.fence.is_none() && self.token == 0 && !self.signaled
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

    fn can_submit(&self) -> bool {
        self.users > 0 && self.signaled
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
        }
        Ok(())
    }
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
    ready: Option<OutputFrame>,
    submitted: Option<OutputFrame>,
    lookahead_required: bool,
    interval: Duration,
    request: AtomicPlaneRequest,
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
    /// Outputs whose physical edge released at least one wl_surface.frame
    /// callback. Like the C++ runtime, each gets exactly one lookahead commit
    /// so the client has a complete interval in which to produce its buffer.
    callback_outputs: Vec<OutputId>,
    /// Outputs with a callback committed after their one-shot lookahead had
    /// already completed. Querying this before the idle fast path is the Rust
    /// equivalent of C++ `SurfaceRegistry::hasFrameCallbacks`.
    callback_demand_outputs: Vec<OutputId>,
    /// One Flutter render fence per atlas slot. Pipelines borrow the fd only
    /// for their synchronous atomic ioctl; no Arc allocation or refcount is
    /// needed to fan a frame out across independently clocked outputs.
    ready_fences: Vec<ReadyFenceSlot>,
    ticker: usize,
    latest_index: usize,
    presented_frames: u64,
    repeated_frames: u64,
    superseded_ready_frames: u64,
}

impl OutputScheduler {
    pub(super) fn new(
        scanouts: &[Scanout],
        initial_index: usize,
        buffer_count: usize,
        runtime: &mut FlutterRuntime,
        events: &mut RuntimeState,
    ) -> Result<Self, Box<dyn Error>> {
        if scanouts.is_empty() {
            return Err("independent output scheduler needs at least one scanout".into());
        }
        if initial_index >= buffer_count {
            return Err("initial atlas index exceeds the scheduler buffer pool".into());
        }
        let broker_index = runtime.enable_independent_scanout(scanouts.len())?;
        if broker_index != initial_index {
            return Err("Flutter and KMS disagree about the initial atlas buffer".into());
        }
        let ticker = scanouts
            .iter()
            .enumerate()
            .max_by_key(|(_, scanout)| OutputMode::from(scanout.output.mode).refresh)
            .map(|(index, _)| index)
            .ok_or("independent output scheduler has no ticker")?;
        let pipelines = scanouts
            .iter()
            .enumerate()
            .map(|(scanout_index, scanout)| OutputPipeline {
                scanout_index,
                scanning: initial_index,
                ready: None,
                submitted: None,
                lookahead_required: false,
                interval: refresh_interval(scanout),
                request: AtomicPlaneRequest::new(scanout),
            })
            .collect::<Vec<_>>();
        events.pending.clear();
        events.completed_page_flips.clear();
        info!(
            ticker = scanouts[ticker].output.name,
            refresh_millihz = OutputMode::from(scanouts[ticker].output.mode).refresh,
            pool_outputs = scanouts.len(),
            "enabled independently clocked atlas outputs"
        );
        Ok(Self {
            pipelines,
            affected_pipelines: Vec::with_capacity(scanouts.len()),
            submitted_outputs: Vec::with_capacity(scanouts.len()),
            presented_outputs: Vec::with_capacity(scanouts.len()),
            callback_outputs: Vec::with_capacity(scanouts.len()),
            callback_demand_outputs: Vec::with_capacity(scanouts.len()),
            ready_fences: std::iter::repeat_with(ReadyFenceSlot::default)
                .take(buffer_count)
                .collect(),
            ticker,
            latest_index: initial_index,
            presented_frames: 0,
            repeated_frames: 0,
            superseded_ready_frames: 0,
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
        } = ready;
        if self
            .ready_fences
            .get(index)
            .is_none_or(|slot| !slot.is_available())
        {
            return Err("Flutter published an atlas slot still awaiting KMS submission".into());
        }
        self.affected_pipelines.clear();
        self.affected_pipelines
            .extend(
                self.pipelines
                    .iter()
                    .enumerate()
                    .filter_map(|(pipeline_index, pipeline)| {
                        let rect = scanouts[pipeline.scanout_index].source_rect;
                        damage
                            .intersects_pixel_rect(rect.x, rect.y, rect.width, rect.height)
                            .then_some(pipeline_index)
                    }),
            );
        runtime.publish_to_outputs(index, self.affected_pipelines.len())?;
        self.latest_index = index;
        if self.affected_pipelines.is_empty() {
            return Ok(None);
        }

        let watch_fence = fence
            .as_ref()
            .map(|fence| fence.as_fd().try_clone_to_owned())
            .transpose()?;
        let token = next_ready_fence_token();
        self.ready_fences[index].claim(fence, self.affected_pipelines.len(), token)?;
        for pipeline_index in self.affected_pipelines.iter().copied() {
            let pipeline = &mut self.pipelines[pipeline_index];
            if let Some(superseded) = pipeline.ready.take() {
                self.superseded_ready_frames = self.superseded_ready_frames.saturating_add(1);
                if self.superseded_ready_frames == 1 {
                    info!(
                        output = scanouts[pipeline.scanout_index].output.name,
                        "Flutter atlas mailbox superseded its first unsubmitted output frame"
                    );
                }
                runtime.release_output(superseded.index)?;
                let slot = self
                    .ready_fences
                    .get_mut(superseded.index)
                    .ok_or("superseded Flutter fence index exceeds the atlas pool")?;
                slot.release_user()?;
            }
            pipeline.ready = Some(OutputFrame {
                index,
                repeated: false,
            });
        }
        Ok(watch_fence.map(|fence| ReadyFenceWatch {
            fence,
            signal: ReadyFenceSignal { index, token },
        }))
    }

    pub(super) fn acknowledge_ready_fences(
        &mut self,
        signals: impl IntoIterator<Item = ReadyFenceSignal>,
    ) {
        for signal in signals {
            if let Some(slot) = self.ready_fences.get_mut(signal.index) {
                slot.mark_signaled(signal.token);
            }
        }
    }

    pub(super) fn submit_ready(
        &mut self,
        drm: &DrmDevice,
        swapchain: &AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<usize, Box<dyn Error>> {
        self.submitted_outputs.clear();
        let mut queue_error = None;
        let (pipelines, ready_fences) = (&mut self.pipelines, &mut self.ready_fences);
        for pipeline in pipelines {
            if pipeline.submitted.is_some() || pipeline.ready.is_none() {
                continue;
            }
            let scanout = &scanouts[pipeline.scanout_index];
            let frame = pipeline.ready.as_ref().expect("checked ready output frame");
            let frame_index = frame.index;
            if !ready_fences[frame_index].can_submit() {
                // Keep unfinished GPU work out of KMS. An IN_FENCE_FD queued
                // here would occupy the CRTC's sole pending commit until the
                // fence signaled, suppressing physical edges and allowing the
                // producer mailbox to build a burst behind it. The calloop
                // fence watch wakes the scheduler as soon as this frame is
                // genuinely eligible for the next vblank.
                continue;
            }
            let framebuffer = swapchain.buffers[frame_index].framebuffer();
            if let Err(error) = pipeline.request.queue(
                drm,
                framebuffer,
                ready_fences[frame_index].fence.as_ref().map(AsFd::as_fd),
            ) {
                queue_error = Some(error);
                break;
            }
            events.pending.insert(scanout.output.crtc);
            pipeline.submitted = pipeline.ready.take();
            // A real ready frame satisfies the physical edge promised after
            // the preceding client callback; no repeat is needed as well.
            pipeline.lookahead_required = false;
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
        Ok(self.submitted_outputs.len())
    }

    pub(super) fn handle_completions(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<Option<PhysicalVsync>, Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchain, scanouts, events, true)
    }

    pub(super) fn retire_completions_for_shutdown(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchain, scanouts, events, false)?;
        Ok(())
    }

    fn handle_completions_inner(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
        deliver_ticker_vsync: bool,
    ) -> Result<Option<PhysicalVsync>, Box<dyn Error>> {
        self.presented_outputs.clear();
        let mut ticker_vsync = None;
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
            if !presented.repeated {
                let previous = pipeline.scanning;
                pipeline.scanning = presented.index;
                if let Err(error) = runtime.release_output(previous) {
                    processing_error = Some(error);
                    break;
                }
                swapchain.present(presented.index);
                self.latest_index = presented.index;
            } else {
                self.repeated_frames = self.repeated_frames.saturating_add(1);
            }
            // Frame callbacks are paced by every physical edge, including a
            // deliberately repeated scanout. Presentation feedback batches
            // are empty for repeats, so sharing this list is safe.
            self.presented_outputs.push(PresentedOutput {
                id: scanouts[pipeline.scanout_index].output.id,
                observed_at: completion.observed_at,
                presented_at: completion.presented_at,
                sequence: completion.sequence,
            });
            self.presented_frames = self.presented_frames.saturating_add(1);
            if deliver_ticker_vsync && pipeline_index == self.ticker {
                ticker_vsync = Some(PhysicalVsync {
                    interval: pipeline.interval,
                    observed_at: completion.observed_at,
                    presented_at: completion.presented_at,
                });
            }
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.outputs_presented(&self.presented_outputs, &mut self.callback_outputs)?;
            for output_id in self.callback_outputs.iter().copied() {
                if let Some(pipeline) = self
                    .pipelines
                    .iter_mut()
                    .find(|pipeline| scanouts[pipeline.scanout_index].output.id == output_id)
                {
                    pipeline.lookahead_required = true;
                }
            }
        }
        if let Some(error) = processing_error {
            return Err(error);
        }
        Ok(ticker_vsync)
    }

    pub(super) fn ensure_output_pulses(
        &mut self,
        runtime: &FlutterRuntime,
        drm: &DrmDevice,
        swapchain: &AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<usize, Box<dyn Error>> {
        if std::mem::take(&mut events.frame_callback_demand) {
            if let Some(frontend) = events.wayland.as_ref() {
                frontend.outputs_with_frame_callback_demand(&mut self.callback_demand_outputs);
            } else {
                self.callback_demand_outputs.clear();
            }
        }
        let mut queued = 0usize;
        for (pipeline_index, pipeline) in self.pipelines.iter_mut().enumerate() {
            if pipeline.submitted.is_some() || pipeline.ready.is_some() {
                continue;
            }
            let producer_demand = pipeline_index == self.ticker && runtime.has_pending_vsync();
            let scanout = &scanouts[pipeline.scanout_index];
            let client_callback_demand = self
                .callback_demand_outputs
                .iter()
                .position(|output_id| *output_id == scanout.output.id);
            if !output_pulse_required(
                pipeline.lookahead_required,
                producer_demand,
                client_callback_demand.is_some(),
            ) {
                continue;
            }
            let framebuffer = swapchain.buffers[pipeline.scanning].framebuffer();
            pipeline.request.queue(drm, framebuffer, None)?;
            events.pending.insert(scanout.output.crtc);
            pipeline.submitted = Some(OutputFrame {
                index: pipeline.scanning,
                repeated: true,
            });
            pipeline.lookahead_required = false;
            if let Some(demand_index) = client_callback_demand {
                self.callback_demand_outputs.swap_remove(demand_index);
            }
            queued = queued.saturating_add(1);
        }
        Ok(queued)
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
        if self.pipelines.len() != scanouts.len() {
            return Err("output scheduler topology no longer matches KMS scanouts".into());
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

    pub(super) fn repeated_frames(&self) -> u64 {
        self.repeated_frames
    }

    pub(super) fn superseded_ready_frames(&self) -> u64 {
        self.superseded_ready_frames
    }
}

fn refresh_interval(scanout: &Scanout) -> Duration {
    let refresh = u64::try_from(OutputMode::from(scanout.output.mode).refresh)
        .ok()
        .filter(|refresh| *refresh > 0)
        .unwrap_or(60_000);
    Duration::from_nanos(1_000_000_000_000 / refresh)
}

const fn output_pulse_required(
    lookahead_required: bool,
    producer_demand: bool,
    client_callback_demand: bool,
) -> bool {
    lookahead_required || producer_demand || client_callback_demand
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;

    use super::{ReadyFenceSlot, output_pulse_required};

    #[test]
    fn ready_fence_slot_closes_only_after_its_last_pipeline_user() {
        let mut slot = ReadyFenceSlot::default();
        assert!(slot.is_available());
        slot.claim(None, 2, 11).unwrap();
        assert!(!slot.is_available());
        assert!(slot.can_submit());
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
        assert!(!slot.can_submit());
        assert!(!slot.mark_signaled(20));
        assert!(!slot.can_submit());
        assert!(slot.mark_signaled(21));
        assert!(slot.can_submit());

        slot.release_user().unwrap();
        assert!(!slot.mark_signaled(21));
        assert!(slot.is_available());
    }

    #[test]
    fn a_late_client_callback_restarts_an_idle_output() {
        assert!(!output_pulse_required(false, false, false));
        assert!(output_pulse_required(false, false, true));
        assert!(output_pulse_required(true, false, false));
        assert!(output_pulse_required(false, true, false));
    }
}
