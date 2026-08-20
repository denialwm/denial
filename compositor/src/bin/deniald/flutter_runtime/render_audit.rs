//! Optional instrumentation for the output render pipeline.

use super::*;

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
    last_frame_damage: String,
    last_buffer_damage: String,
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
            last_frame_damage: "-".to_owned(),
            last_buffer_damage: "-".to_owned(),
        }
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
        self.last_frame_damage = frame_region.compact_description();
        self.last_buffer_damage = buffer_region.compact_description();
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
            last_render_view_id = ?self.last_render_view_id,
            last_frame_damage = %self.last_frame_damage,
            last_buffer_damage = %self.last_buffer_damage,
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
        self.last_frame_damage.clear();
        self.last_frame_damage.push('-');
        self.last_buffer_damage.clear();
        self.last_buffer_damage.push('-');
    }
}
