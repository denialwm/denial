//! Optional instrumentation for the output render pipeline.

use super::*;

#[derive(Clone, Copy, Debug)]
pub(super) enum RenderAuditStage {
    ContextMakeCurrent,
    BackingStore,
    ExistingDamage,
    ExternalTexture,
    PresentCallback,
    RasterIdleCallback,
}

#[derive(Clone, Copy, Debug, Default)]
struct RenderTimingSummary {
    average_us: f64,
    p95_us: f64,
    p99_us: f64,
    max_us: f64,
}

#[derive(Debug, Default)]
struct RenderTiming {
    samples: u64,
    total: Duration,
    max: Duration,
    values: Vec<Duration>,
}

impl RenderTiming {
    fn record(&mut self, duration: Duration) {
        self.samples = self.samples.saturating_add(1);
        self.total = self.total.saturating_add(duration);
        self.max = self.max.max(duration);
        self.values.push(duration);
    }

    fn summary(&self) -> RenderTimingSummary {
        if self.samples == 0 {
            return RenderTimingSummary::default();
        }
        let mut values = self.values.clone();
        values.sort_unstable();
        RenderTimingSummary {
            average_us: self.total.as_secs_f64() * 1_000_000.0 / self.samples as f64,
            p95_us: percentile_us(&values, 95),
            p99_us: percentile_us(&values, 99),
            max_us: self.max.as_secs_f64() * 1_000_000.0,
        }
    }
}

fn percentile_us(values: &[Duration], percentile: usize) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let rank = (values.len().saturating_mul(percentile).saturating_add(99) / 100)
        .saturating_sub(1)
        .min(values.len() - 1);
    values[rank].as_secs_f64() * 1_000_000.0
}

#[derive(Debug)]
pub(super) struct RenderDamageAudit {
    interval_started: Instant,
    presented_outputs: u64,
    empty_transactions: u64,
    frame_rects: u64,
    buffer_rects: u64,
    frame_coverage: f64,
    buffer_coverage: f64,
    max_frame_coverage: f64,
    max_buffer_coverage: f64,
    full_frame_damage: u64,
    full_buffer_damage: u64,
    empty_frame_damage: u64,
    empty_buffer_damage: u64,
    sampled_transactions: u64,
    sampled_textures: u64,
    max_sampled_textures: usize,
    sampled_texture_counts: HashMap<i64, u64>,
    sampled_generation_advances: u64,
    sampled_generation_repeats: u64,
    last_sampled_generations: HashMap<i64, u64>,
    render_authorizations: u64,
    authorization_lateness: Duration,
    authorization_lateness_max: Duration,
    target_blocked_ready: u64,
    target_blocked_exhausted: u64,
    last_render_view_id: Option<i64>,
    last_frame_damage: Option<DamageRegion>,
    last_buffer_damage: Option<DamageRegion>,
    raster_started_at: Option<Instant>,
    raster_restarts: u64,
    context_make_current: RenderTiming,
    backing_store: RenderTiming,
    existing_damage: RenderTiming,
    external_texture: RenderTiming,
    present_callback: RenderTiming,
    raster_to_output_ready: RenderTiming,
    raster_transaction: RenderTiming,
    raster_idle_callback: RenderTiming,
    gpu_flutter_render: RenderTiming,
    gpu_scanout_blit: RenderTiming,
    gpu_frame: RenderTiming,
    gpu_timer_disjoint: u64,
    gpu_timer_abandoned: u64,
    gpu_timer_pending_max: usize,
}

impl RenderDamageAudit {
    pub(super) fn new() -> Self {
        Self {
            interval_started: Instant::now(),
            presented_outputs: 0,
            empty_transactions: 0,
            frame_rects: 0,
            buffer_rects: 0,
            frame_coverage: 0.0,
            buffer_coverage: 0.0,
            max_frame_coverage: 0.0,
            max_buffer_coverage: 0.0,
            full_frame_damage: 0,
            full_buffer_damage: 0,
            empty_frame_damage: 0,
            empty_buffer_damage: 0,
            sampled_transactions: 0,
            sampled_textures: 0,
            max_sampled_textures: 0,
            sampled_texture_counts: HashMap::new(),
            sampled_generation_advances: 0,
            sampled_generation_repeats: 0,
            last_sampled_generations: HashMap::new(),
            render_authorizations: 0,
            authorization_lateness: Duration::ZERO,
            authorization_lateness_max: Duration::ZERO,
            target_blocked_ready: 0,
            target_blocked_exhausted: 0,
            last_render_view_id: None,
            last_frame_damage: None,
            last_buffer_damage: None,
            raster_started_at: None,
            raster_restarts: 0,
            context_make_current: RenderTiming::default(),
            backing_store: RenderTiming::default(),
            existing_damage: RenderTiming::default(),
            external_texture: RenderTiming::default(),
            present_callback: RenderTiming::default(),
            raster_to_output_ready: RenderTiming::default(),
            raster_transaction: RenderTiming::default(),
            raster_idle_callback: RenderTiming::default(),
            gpu_flutter_render: RenderTiming::default(),
            gpu_scanout_blit: RenderTiming::default(),
            gpu_frame: RenderTiming::default(),
            gpu_timer_disjoint: 0,
            gpu_timer_abandoned: 0,
            gpu_timer_pending_max: 0,
        }
    }

    pub(super) fn record_stage(&mut self, stage: RenderAuditStage, duration: Duration) {
        match stage {
            RenderAuditStage::ContextMakeCurrent => self.context_make_current.record(duration),
            RenderAuditStage::BackingStore => self.backing_store.record(duration),
            RenderAuditStage::ExistingDamage => self.existing_damage.record(duration),
            RenderAuditStage::ExternalTexture => self.external_texture.record(duration),
            RenderAuditStage::PresentCallback => self.present_callback.record(duration),
            RenderAuditStage::RasterIdleCallback => self.raster_idle_callback.record(duration),
        }
    }

    pub(super) fn record_raster_start(&mut self, now: Instant) {
        self.raster_restarts = self
            .raster_restarts
            .saturating_add(u64::from(self.raster_started_at.replace(now).is_some()));
    }

    pub(super) fn record_output_ready(&mut self, now: Instant) {
        if let Some(started_at) = self.raster_started_at {
            self.raster_to_output_ready
                .record(now.saturating_duration_since(started_at));
        }
    }

    pub(super) fn record_raster_idle(&mut self, now: Instant) {
        if let Some(started_at) = self.raster_started_at.take() {
            self.raster_transaction
                .record(now.saturating_duration_since(started_at));
        }
    }

    pub(super) fn record_gpu_timing(
        &mut self,
        completed: Vec<(Duration, Duration, Duration)>,
        disjoint: u64,
        abandoned: u64,
        pending: usize,
    ) {
        for (flutter, scanout_blit, frame) in completed {
            self.gpu_flutter_render.record(flutter);
            self.gpu_scanout_blit.record(scanout_blit);
            self.gpu_frame.record(frame);
        }
        self.gpu_timer_disjoint = self.gpu_timer_disjoint.saturating_add(disjoint);
        self.gpu_timer_abandoned = self.gpu_timer_abandoned.saturating_add(abandoned);
        self.gpu_timer_pending_max = self.gpu_timer_pending_max.max(pending);
    }

    pub(super) fn record_target_blocked(&mut self, blocked: RenderTargetBlocked) {
        match blocked {
            RenderTargetBlocked::ReadyHandoff => {
                self.target_blocked_ready = self.target_blocked_ready.saturating_add(1);
            }
            RenderTargetBlocked::PoolExhausted => {
                self.target_blocked_exhausted = self.target_blocked_exhausted.saturating_add(1);
            }
        }
    }

    pub(super) fn record_present(
        &mut self,
        render_view_id: i64,
        size: PixelSize,
        frame_damage: &[sys::FlutterRect],
        buffer_damage: &[sys::FlutterRect],
    ) {
        let mut frame_region = DamageRegion::empty(size.width, size.height);
        let mut buffer_region = DamageRegion::empty(size.width, size.height);
        frame_region.replace_from_flutter(frame_damage);
        buffer_region.replace_from_flutter(buffer_damage);

        let target_pixels = (f64::from(size.width) * f64::from(size.height)).max(1.0);
        let frame_coverage = frame_region.damaged_area() / target_pixels;
        let buffer_coverage = buffer_region.damaged_area() / target_pixels;
        self.presented_outputs = self.presented_outputs.saturating_add(1);
        self.frame_rects = self
            .frame_rects
            .saturating_add(frame_region.rect_count() as u64);
        self.buffer_rects = self
            .buffer_rects
            .saturating_add(buffer_region.rect_count() as u64);
        self.frame_coverage += frame_coverage;
        self.buffer_coverage += buffer_coverage;
        self.max_frame_coverage = self.max_frame_coverage.max(frame_coverage);
        self.max_buffer_coverage = self.max_buffer_coverage.max(buffer_coverage);
        self.full_frame_damage = self
            .full_frame_damage
            .saturating_add(u64::from(frame_region.is_full()));
        self.full_buffer_damage = self
            .full_buffer_damage
            .saturating_add(u64::from(buffer_region.is_full()));
        self.empty_frame_damage = self
            .empty_frame_damage
            .saturating_add(u64::from(frame_region.is_empty()));
        self.empty_buffer_damage = self
            .empty_buffer_damage
            .saturating_add(u64::from(buffer_region.is_empty()));
        self.last_render_view_id = Some(render_view_id);
        self.last_frame_damage = Some(frame_region);
        self.last_buffer_damage = Some(buffer_region);
        self.maybe_report();
    }

    pub(super) fn record_empty_transaction(&mut self) {
        self.empty_transactions = self.empty_transactions.saturating_add(1);
        self.maybe_report();
    }

    pub(super) fn record_sampled_textures(&mut self, sampled: Option<&SampledBufferHoldBatch>) {
        let sampled_textures = sampled.map_or(0, SampledBufferHoldBatch::len);
        self.sampled_transactions = self.sampled_transactions.saturating_add(1);
        self.sampled_textures = self
            .sampled_textures
            .saturating_add(sampled_textures as u64);
        self.max_sampled_textures = self.max_sampled_textures.max(sampled_textures);
        if let Some(sampled) = sampled {
            for (texture_id, generation) in sampled.texture_generations() {
                let count = self.sampled_texture_counts.entry(texture_id).or_default();
                *count = count.saturating_add(1);
                if self.last_sampled_generations.insert(texture_id, generation) == Some(generation)
                {
                    self.sampled_generation_repeats =
                        self.sampled_generation_repeats.saturating_add(1);
                } else {
                    self.sampled_generation_advances =
                        self.sampled_generation_advances.saturating_add(1);
                }
            }
        }
    }

    pub(super) fn record_render_authorization(&mut self, lateness: Duration) {
        self.render_authorizations = self.render_authorizations.saturating_add(1);
        self.authorization_lateness = self.authorization_lateness.saturating_add(lateness);
        self.authorization_lateness_max = self.authorization_lateness_max.max(lateness);
    }

    fn sampled_texture_counts_description(&self) -> String {
        if self.sampled_texture_counts.is_empty() {
            return "-".to_owned();
        }
        let mut counts = self.sampled_texture_counts.iter().collect::<Vec<_>>();
        counts.sort_unstable_by_key(|(texture_id, _)| **texture_id);
        counts
            .into_iter()
            .map(|(texture_id, count)| format!("{texture_id}:{count}"))
            .collect::<Vec<_>>()
            .join(",")
    }

    pub(super) fn maybe_report(&mut self) {
        let elapsed = self.interval_started.elapsed();
        if elapsed < RENDER_AUDIT_INTERVAL {
            return;
        }

        let output_denominator = self.presented_outputs.max(1) as f64;
        let sampled_denominator = self.sampled_transactions.max(1) as f64;
        let authorization_denominator = self.render_authorizations.max(1) as f64;
        let last_frame_damage = self
            .last_frame_damage
            .as_ref()
            .map_or_else(|| "-".to_owned(), DamageRegion::compact_description);
        let last_buffer_damage = self
            .last_buffer_damage
            .as_ref()
            .map_or_else(|| "-".to_owned(), DamageRegion::compact_description);
        let context_make_current = self.context_make_current.summary();
        let backing_store = self.backing_store.summary();
        let existing_damage = self.existing_damage.summary();
        let external_texture = self.external_texture.summary();
        let present_callback = self.present_callback.summary();
        let raster_to_output_ready = self.raster_to_output_ready.summary();
        let raster_transaction = self.raster_transaction.summary();
        let raster_idle_callback = self.raster_idle_callback.summary();
        let gpu_flutter_render = self.gpu_flutter_render.summary();
        let gpu_scanout_blit = self.gpu_scanout_blit.summary();
        let gpu_frame = self.gpu_frame.summary();
        info!(
            target: "deniald::render_audit",
            source = "embedder",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            presented_outputs = self.presented_outputs,
            empty_transactions = self.empty_transactions,
            frame_damage_avg_pct = self.frame_coverage / output_denominator * 100.0,
            frame_damage_max_pct = self.max_frame_coverage * 100.0,
            frame_damage_avg_rects = self.frame_rects as f64 / output_denominator,
            frame_damage_full = self.full_frame_damage,
            frame_damage_empty = self.empty_frame_damage,
            buffer_damage_avg_pct = self.buffer_coverage / output_denominator * 100.0,
            buffer_damage_max_pct = self.max_buffer_coverage * 100.0,
            buffer_damage_avg_rects = self.buffer_rects as f64 / output_denominator,
            buffer_damage_full = self.full_buffer_damage,
            buffer_damage_empty = self.empty_buffer_damage,
            sampled_textures_avg = self.sampled_textures as f64 / sampled_denominator,
            sampled_textures_max = self.max_sampled_textures,
            sampled_texture_counts = %self.sampled_texture_counts_description(),
            sampled_generation_advances = self.sampled_generation_advances,
            sampled_generation_repeats = self.sampled_generation_repeats,
            authorization_lateness_avg_us = self.authorization_lateness.as_secs_f64()
                * 1_000_000.0
                / authorization_denominator,
            authorization_lateness_max_us = self.authorization_lateness_max.as_secs_f64()
                * 1_000_000.0,
            target_blocked_ready = self.target_blocked_ready,
            target_blocked_exhausted = self.target_blocked_exhausted,
            raster_restarts = self.raster_restarts,
            context_make_current_avg_us = context_make_current.average_us,
            context_make_current_p95_us = context_make_current.p95_us,
            context_make_current_p99_us = context_make_current.p99_us,
            context_make_current_max_us = context_make_current.max_us,
            backing_store_avg_us = backing_store.average_us,
            backing_store_p95_us = backing_store.p95_us,
            backing_store_p99_us = backing_store.p99_us,
            backing_store_max_us = backing_store.max_us,
            existing_damage_avg_us = existing_damage.average_us,
            existing_damage_p95_us = existing_damage.p95_us,
            existing_damage_p99_us = existing_damage.p99_us,
            existing_damage_max_us = existing_damage.max_us,
            external_texture_avg_us = external_texture.average_us,
            external_texture_p95_us = external_texture.p95_us,
            external_texture_p99_us = external_texture.p99_us,
            external_texture_max_us = external_texture.max_us,
            present_callback_avg_us = present_callback.average_us,
            present_callback_p95_us = present_callback.p95_us,
            present_callback_p99_us = present_callback.p99_us,
            present_callback_max_us = present_callback.max_us,
            raster_to_output_ready_avg_us = raster_to_output_ready.average_us,
            raster_to_output_ready_p95_us = raster_to_output_ready.p95_us,
            raster_to_output_ready_p99_us = raster_to_output_ready.p99_us,
            raster_to_output_ready_max_us = raster_to_output_ready.max_us,
            raster_transaction_avg_us = raster_transaction.average_us,
            raster_transaction_p95_us = raster_transaction.p95_us,
            raster_transaction_p99_us = raster_transaction.p99_us,
            raster_transaction_max_us = raster_transaction.max_us,
            raster_idle_callback_avg_us = raster_idle_callback.average_us,
            raster_idle_callback_p95_us = raster_idle_callback.p95_us,
            raster_idle_callback_p99_us = raster_idle_callback.p99_us,
            raster_idle_callback_max_us = raster_idle_callback.max_us,
            gpu_render_samples = self.gpu_frame.samples,
            gpu_flutter_render_avg_us = gpu_flutter_render.average_us,
            gpu_flutter_render_p95_us = gpu_flutter_render.p95_us,
            gpu_flutter_render_p99_us = gpu_flutter_render.p99_us,
            gpu_flutter_render_max_us = gpu_flutter_render.max_us,
            gpu_scanout_blit_avg_us = gpu_scanout_blit.average_us,
            gpu_scanout_blit_p95_us = gpu_scanout_blit.p95_us,
            gpu_scanout_blit_p99_us = gpu_scanout_blit.p99_us,
            gpu_scanout_blit_max_us = gpu_scanout_blit.max_us,
            gpu_frame_avg_us = gpu_frame.average_us,
            gpu_frame_p95_us = gpu_frame.p95_us,
            gpu_frame_p99_us = gpu_frame.p99_us,
            gpu_frame_max_us = gpu_frame.max_us,
            gpu_timer_disjoint = self.gpu_timer_disjoint,
            gpu_timer_abandoned = self.gpu_timer_abandoned,
            gpu_timer_pending_max = self.gpu_timer_pending_max,
            last_render_view_id = ?self.last_render_view_id,
            last_frame_damage = %last_frame_damage,
            last_buffer_damage = %last_buffer_damage,
            "Flutter per-output render audit"
        );

        self.interval_started = Instant::now();
        self.presented_outputs = 0;
        self.empty_transactions = 0;
        self.frame_rects = 0;
        self.buffer_rects = 0;
        self.frame_coverage = 0.0;
        self.buffer_coverage = 0.0;
        self.max_frame_coverage = 0.0;
        self.max_buffer_coverage = 0.0;
        self.full_frame_damage = 0;
        self.full_buffer_damage = 0;
        self.empty_frame_damage = 0;
        self.empty_buffer_damage = 0;
        self.sampled_transactions = 0;
        self.sampled_textures = 0;
        self.max_sampled_textures = 0;
        self.sampled_texture_counts.clear();
        self.sampled_generation_advances = 0;
        self.sampled_generation_repeats = 0;
        self.last_sampled_generations.clear();
        self.render_authorizations = 0;
        self.authorization_lateness = Duration::ZERO;
        self.authorization_lateness_max = Duration::ZERO;
        self.target_blocked_ready = 0;
        self.target_blocked_exhausted = 0;
        self.last_render_view_id = None;
        self.last_frame_damage = None;
        self.last_buffer_damage = None;
        self.raster_restarts = 0;
        self.context_make_current = RenderTiming::default();
        self.backing_store = RenderTiming::default();
        self.existing_damage = RenderTiming::default();
        self.external_texture = RenderTiming::default();
        self.present_callback = RenderTiming::default();
        self.raster_to_output_ready = RenderTiming::default();
        self.raster_transaction = RenderTiming::default();
        self.raster_idle_callback = RenderTiming::default();
        self.gpu_flutter_render = RenderTiming::default();
        self.gpu_scanout_blit = RenderTiming::default();
        self.gpu_frame = RenderTiming::default();
        self.gpu_timer_disjoint = 0;
        self.gpu_timer_abandoned = 0;
        self.gpu_timer_pending_max = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_timing_keeps_flutter_blit_and_total_separate() {
        let mut audit = RenderDamageAudit::new();
        audit.record_gpu_timing(
            vec![(
                Duration::from_millis(7),
                Duration::from_millis(2),
                Duration::from_millis(9),
            )],
            3,
            4,
            5,
        );

        assert_eq!(audit.gpu_flutter_render.samples, 1);
        assert_eq!(audit.gpu_flutter_render.total, Duration::from_millis(7));
        assert_eq!(audit.gpu_scanout_blit.total, Duration::from_millis(2));
        assert_eq!(audit.gpu_frame.total, Duration::from_millis(9));
        assert_eq!(audit.gpu_timer_disjoint, 3);
        assert_eq!(audit.gpu_timer_abandoned, 4);
        assert_eq!(audit.gpu_timer_pending_max, 5);
    }
}
