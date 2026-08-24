//! Authorized output rendering, raster handoff, and scanout ownership.

use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum BufferState {
    Free,
    Rendering,
    Ready,
    Pending,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RenderTargetBlocked {
    ReadyHandoff,
    PoolExhausted,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct OutputPoolDescriptor<'a> {
    pub(super) output_id: OutputId,
    pub(super) render_view_id: RenderViewId,
    pub(super) configuration_generation: u64,
    pub(super) size: PixelSize,
    pub(super) initial_scanout: usize,
    pub(super) framebuffers: &'a [u32],
}

#[derive(Debug)]
pub(super) struct OutputBufferSlot {
    pub(super) framebuffer: u32,
    pub(super) state: BufferState,
    pub(super) output_refs: usize,
    pub(super) fence: Option<OwnedFd>,
    /// Pixels actually repainted while producing the Ready generation. This
    /// is distinct from `damage`, which is the repair history the slot still
    /// needs before it can represent the newest scene.
    pub(super) ready_damage: Option<DamageRegion>,
    pub(super) damage: DamageRegion,
    pub(super) screenshot_request_id: Option<u64>,
    pub(super) rendered_at: Option<Instant>,
    pub(super) ready_transaction: u64,
    pub(super) request: Option<OutputFrameRequest>,
}

#[derive(Debug)]
pub(super) struct OutputBufferPool {
    pub(super) output_id: OutputId,
    pub(super) render_view_id: RenderViewId,
    pub(super) configuration_generation: u64,
    pub(super) size: PixelSize,
    pub(super) slots: Vec<OutputBufferSlot>,
    pub(super) authorized_request: Option<AuthorizedOutputRequest>,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct AuthorizedOutputRequest {
    pub(super) request: OutputFrameRequest,
    pub(super) authorized_at: Instant,
}

#[derive(Debug)]
pub(super) struct OutputBufferBroker {
    pub(super) pools: Vec<OutputBufferPool>,
    pub(super) transaction: u64,
    pub(super) next_screenshot: Option<(OutputId, u64)>,
}

#[derive(Debug)]
pub struct ReadyOutputFrame {
    pub output_id: OutputId,
    pub render_view_id: RenderViewId,
    pub configuration_generation: u64,
    pub index: usize,
    pub fence: Option<OwnedFd>,
    pub damage: DamageRegion,
    pub screenshot_request_id: Option<u64>,
    pub rendered_at: Option<Instant>,
    pub request: OutputFrameRequest,
}

impl OutputBufferBroker {
    pub(super) fn new<'a>(
        descriptors: impl IntoIterator<Item = OutputPoolDescriptor<'a>>,
    ) -> Result<Self, &'static str> {
        let mut output_ids = HashSet::new();
        let mut render_view_ids = HashSet::new();
        let mut framebuffers = HashSet::new();
        let mut pools = Vec::new();
        let mut generation = None;
        for descriptor in descriptors {
            if descriptor.configuration_generation == 0
                || generation.is_some_and(|value| value != descriptor.configuration_generation)
                || !output_ids.insert(descriptor.output_id)
                || !render_view_ids.insert(descriptor.render_view_id)
                || descriptor.size.width == 0
                || descriptor.size.height == 0
                || descriptor.initial_scanout >= descriptor.framebuffers.len()
                || descriptor.framebuffers.len() < 3
                || descriptor
                    .framebuffers
                    .iter()
                    .any(|framebuffer| *framebuffer == 0 || !framebuffers.insert(*framebuffer))
            {
                return Err("invalid physical output framebuffer pool");
            }
            generation = Some(descriptor.configuration_generation);
            let slots = descriptor
                .framebuffers
                .iter()
                .copied()
                .enumerate()
                .map(|(index, framebuffer)| OutputBufferSlot {
                    framebuffer,
                    state: BufferState::Free,
                    output_refs: usize::from(index == descriptor.initial_scanout),
                    fence: None,
                    ready_damage: None,
                    damage: DamageRegion::full(descriptor.size.width, descriptor.size.height),
                    screenshot_request_id: None,
                    rendered_at: None,
                    ready_transaction: 0,
                    request: None,
                })
                .collect();
            pools.push(OutputBufferPool {
                output_id: descriptor.output_id,
                render_view_id: descriptor.render_view_id,
                configuration_generation: descriptor.configuration_generation,
                size: descriptor.size,
                slots,
                authorized_request: None,
            });
        }
        if pools.is_empty() {
            return Err("physical output framebuffer pools are empty");
        }
        pools.sort_by_key(|pool| pool.render_view_id);
        Ok(Self {
            pools,
            transaction: 0,
            next_screenshot: None,
        })
    }

    pub(super) fn begin_transaction(&mut self) {
        self.transaction = self.transaction.wrapping_add(1).max(1);
        for pool in &mut self.pools {
            for slot in &mut pool.slots {
                if slot.state == BufferState::Rendering && slot.output_refs == 0 {
                    slot.damage.invalidate();
                    slot.state = BufferState::Free;
                    slot.fence = None;
                    slot.ready_damage = None;
                    slot.rendered_at = None;
                    slot.screenshot_request_id = None;
                    slot.ready_transaction = 0;
                    slot.request = None;
                }
            }
        }
    }

    pub(super) fn target_available(&self, output: OutputId) -> bool {
        self.pools
            .iter()
            .find(|pool| pool.output_id == output)
            .is_some_and(|pool| {
                pool.authorized_request.is_none()
                    && !pool
                        .slots
                        .iter()
                        .any(|slot| slot.state != BufferState::Free)
                    && pool
                        .slots
                        .iter()
                        .any(|slot| slot.state == BufferState::Free && slot.output_refs == 0)
            })
    }

    pub(super) fn authorize(&mut self, request: OutputFrameRequest, now: Instant) -> Option<i64> {
        if request.dirty_serial == 0 || !self.target_available(request.tick.output) {
            return None;
        }
        let pool = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == request.tick.output)?;
        pool.authorized_request = Some(AuthorizedOutputRequest {
            request,
            authorized_at: now,
        });
        Some(pool.render_view_id.get())
    }

    pub(super) fn cancel_authorizations(&mut self, render_view_ids: &[i64]) {
        for pool in &mut self.pools {
            if render_view_ids.contains(&pool.render_view_id.get()) {
                pool.authorized_request = None;
            }
        }
    }

    pub(super) fn expire_authorizations(&mut self, now: Instant) -> usize {
        let mut expired = 0;
        for pool in &mut self.pools {
            let should_expire = pool.authorized_request.is_some_and(|authorization| {
                now.saturating_duration_since(authorization.authorized_at)
                    >= authorization.request.tick.interval.saturating_mul(2)
            });
            if should_expire {
                pool.authorized_request = None;
                expired += 1;
            }
        }
        expired
    }

    pub(super) fn acquire(
        &mut self,
        render_view_id: i64,
        size: PixelSize,
    ) -> Result<u32, RenderTargetBlocked> {
        let Some(pool) = self
            .pools
            .iter_mut()
            .find(|pool| pool.render_view_id.get() == render_view_id && pool.size == size)
        else {
            return Err(RenderTargetBlocked::PoolExhausted);
        };
        let Some(authorization) = pool.authorized_request else {
            return Err(RenderTargetBlocked::PoolExhausted);
        };
        if pool
            .slots
            .iter()
            .any(|slot| slot.state == BufferState::Ready)
        {
            return Err(RenderTargetBlocked::ReadyHandoff);
        }
        let Some(slot_index) = pool
            .slots
            .iter()
            .position(|slot| slot.state == BufferState::Free && slot.output_refs == 0)
        else {
            return Err(RenderTargetBlocked::PoolExhausted);
        };
        pool.authorized_request = None;
        let slot = &mut pool.slots[slot_index];
        slot.state = BufferState::Rendering;
        slot.fence = None;
        slot.ready_damage = None;
        slot.rendered_at = None;
        slot.screenshot_request_id = self
            .next_screenshot
            .filter(|(output, _)| *output == pool.output_id)
            .map(|(_, request_id)| request_id);
        slot.ready_transaction = 0;
        slot.request = Some(authorization.request);
        Ok(slot.framebuffer)
    }

    pub(super) fn validate_backing_store(
        &self,
        render_view_id: i64,
        framebuffer: u32,
        size: PixelSize,
    ) -> bool {
        self.pools.iter().any(|pool| {
            pool.render_view_id.get() == render_view_id
                && pool.size == size
                && pool
                    .slots
                    .iter()
                    .any(|slot| slot.framebuffer == framebuffer)
        })
    }

    pub(super) fn mark_ready(
        &mut self,
        render_view_id: i64,
        framebuffer: u32,
        frame_damage: &[sys::FlutterRect],
        buffer_damage: &[sys::FlutterRect],
        fence: Option<OwnedFd>,
        rendered_at: Option<Instant>,
    ) -> bool {
        let Some(pool) = self
            .pools
            .iter_mut()
            .find(|pool| pool.render_view_id.get() == render_view_id)
        else {
            return false;
        };
        let Some(index) = pool
            .slots
            .iter()
            .position(|slot| slot.framebuffer == framebuffer)
        else {
            return false;
        };
        if pool.slots[index].state != BufferState::Rendering
            || pool
                .slots
                .iter()
                .enumerate()
                .any(|(other_index, slot)| other_index != index && slot.state == BufferState::Ready)
        {
            return false;
        }
        let mut frame_damage_region = DamageRegion::empty(pool.size.width, pool.size.height);
        frame_damage_region.replace_from_flutter(frame_damage);
        let mut buffer_damage_region = DamageRegion::empty(pool.size.width, pool.size.height);
        buffer_damage_region.replace_from_flutter(buffer_damage);
        for (other_index, slot) in pool.slots.iter_mut().enumerate() {
            if other_index != index {
                slot.damage.union(&frame_damage_region);
            }
        }
        let slot = &mut pool.slots[index];
        slot.damage.clear();
        slot.ready_damage = Some(buffer_damage_region);
        slot.state = BufferState::Ready;
        slot.fence = fence;
        slot.rendered_at = rendered_at;
        slot.ready_transaction = self.transaction;
        true
    }

    pub(super) fn finish_transaction(&mut self) -> Vec<ReadyOutputFrame> {
        let transaction = self.transaction;
        let mut outputs = Vec::with_capacity(self.pools.len());
        for pool in &mut self.pools {
            let Some(index) = pool.slots.iter().position(|slot| {
                slot.state == BufferState::Ready && slot.ready_transaction == transaction
            }) else {
                continue;
            };
            let slot = &mut pool.slots[index];
            slot.state = BufferState::Pending;
            slot.ready_transaction = 0;
            let request = slot
                .request
                .take()
                .expect("a ready output must retain its timeline request");
            outputs.push(ReadyOutputFrame {
                output_id: pool.output_id,
                render_view_id: pool.render_view_id,
                configuration_generation: pool.configuration_generation,
                index,
                fence: slot.fence.take(),
                damage: slot
                    .ready_damage
                    .take()
                    .expect("a ready output must retain its raster damage"),
                screenshot_request_id: slot.screenshot_request_id.take(),
                rendered_at: slot.rendered_at.take(),
                request,
            });
        }
        if let Some((output, request_id)) = self.next_screenshot
            && outputs.iter().any(|frame| {
                frame.output_id == output && frame.screenshot_request_id == Some(request_id)
            })
        {
            self.next_screenshot = None;
        }
        outputs
    }

    pub(super) fn populate_existing_damage(
        &self,
        framebuffer: isize,
        output: &mut Vec<sys::FlutterRect>,
    ) -> bool {
        let Ok(framebuffer) = u32::try_from(framebuffer) else {
            return false;
        };
        let Some(slot) = self
            .pools
            .iter()
            .flat_map(|pool| &pool.slots)
            .find(|slot| slot.framebuffer == framebuffer)
        else {
            return false;
        };
        slot.damage.write_flutter(output);
        true
    }

    pub(super) fn publish(&mut self, output: &ReadyOutputFrame) -> Result<(), &'static str> {
        let slot = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == output.output_id)
            .and_then(|pool| pool.slots.get_mut(output.index))
            .ok_or("Flutter output publication slot is out of range")?;
        if slot.state != BufferState::Pending || slot.output_refs != 0 {
            return Err("Flutter output publication slot is not exclusively pending");
        }
        slot.state = BufferState::Free;
        slot.output_refs = 1;
        Ok(())
    }

    pub(super) fn release_output(
        &mut self,
        output: OutputId,
        index: usize,
    ) -> Result<(), &'static str> {
        let slot = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == output)
            .and_then(|pool| pool.slots.get_mut(index))
            .ok_or("Flutter released output slot is out of range")?;
        if slot.output_refs == 0 {
            return Err("released a Flutter buffer without an output owner");
        }
        slot.output_refs -= 1;
        Ok(())
    }

    pub(super) fn retain_output(
        &mut self,
        output: OutputId,
        index: usize,
    ) -> Result<(), &'static str> {
        let slot = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == output)
            .and_then(|pool| pool.slots.get_mut(index))
            .ok_or("Flutter retained output slot is out of range")?;
        if slot.state != BufferState::Free || slot.output_refs == 0 {
            return Err("retained a Flutter buffer without a published output owner");
        }
        slot.output_refs = slot
            .output_refs
            .checked_add(1)
            .ok_or("Flutter output reference count overflow")?;
        Ok(())
    }

    pub(super) fn tag_next_frame_for_screenshot(
        &mut self,
        output: OutputId,
        request_id: u64,
    ) -> Result<(), &'static str> {
        if request_id == 0
            || self.next_screenshot.is_some()
            || !self.pools.iter().any(|pool| pool.output_id == output)
        {
            return Err("a screenshot frame is already pending");
        }
        self.next_screenshot = Some((output, request_id));
        Ok(())
    }

    pub(super) fn cancel_screenshot_frame(&mut self, request_id: u64) {
        if self
            .next_screenshot
            .is_some_and(|(_, pending)| pending == request_id)
        {
            self.next_screenshot = None;
        }
        for slot in self.pools.iter_mut().flat_map(|pool| &mut pool.slots) {
            if slot.screenshot_request_id == Some(request_id) {
                slot.screenshot_request_id = None;
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum VsyncRegistration {
    Accepted,
    Duplicate,
    AtCapacity,
}

#[derive(Debug, Default)]
pub(super) struct PendingVsyncBatons {
    values: VecDeque<isize>,
}

impl PendingVsyncBatons {
    pub(super) fn register(&mut self, baton: isize) -> VsyncRegistration {
        if self.values.contains(&baton) {
            return VsyncRegistration::Duplicate;
        }
        if self.values.len() == MAX_PENDING_VSYNC_BATONS {
            return VsyncRegistration::AtCapacity;
        }
        self.values.push_back(baton);
        VsyncRegistration::Accepted
    }

    pub(super) fn complete(&mut self, baton: isize) -> bool {
        let Some(index) = self.values.iter().position(|candidate| *candidate == baton) else {
            return false;
        };
        self.values.remove(index);
        true
    }

    pub(super) fn has_pending(&self) -> bool {
        !self.values.is_empty()
    }

    pub(super) fn take_next(&mut self) -> Option<isize> {
        self.values.pop_front()
    }

    pub(super) fn restore_front(&mut self, baton: isize) {
        debug_assert!(self.values.len() < MAX_PENDING_VSYNC_BATONS);
        debug_assert!(!self.values.contains(&baton));
        self.values.push_front(baton);
    }

    pub(super) fn take_all(&mut self) -> VecDeque<isize> {
        mem::take(&mut self.values)
    }
}
