use super::*;

const INTERVAL: Duration = Duration::from_millis(10);
const FAST_INTERVAL: Duration = Duration::from_millis(5);
const FAST_OUTPUT: OutputId = OutputId(1);
const SLOW_OUTPUT: OutputId = OutputId(2);

fn scheduler(now: Instant) -> FrameScheduler {
    scheduler_with_timelines(now, &[(FAST_OUTPUT, INTERVAL)])
}

fn mixed_scheduler(now: Instant) -> FrameScheduler {
    scheduler_with_timelines(
        now,
        &[(FAST_OUTPUT, FAST_INTERVAL), (SLOW_OUTPUT, INTERVAL)],
    )
}

fn non_harmonic_mixed_scheduler(now: Instant) -> FrameScheduler {
    scheduler_with_timelines(
        now,
        &[
            (FAST_OUTPUT, Duration::from_millis(4)),
            (SLOW_OUTPUT, INTERVAL),
        ],
    )
}

fn scheduler_with_timelines(now: Instant, sources: &[(OutputId, Duration)]) -> FrameScheduler {
    let flutter_output = sources
        .iter()
        .copied()
        .min_by_key(|(output, interval)| (*interval, *output))
        .map(|(output, _)| output);
    FrameScheduler {
        outputs: OutputTimelines {
            timelines: sources
                .iter()
                .map(|(output, interval)| {
                    OutputTimeline::new(
                        TimelineSource {
                            output: *output,
                            interval: *interval,
                        },
                        now,
                    )
                })
                .collect(),
            ticks: Vec::with_capacity(sources.len()),
            flutter_output,
        },
        configured_outputs: sources.iter().map(|(output, _)| *output).collect(),
        dirty_outputs: BTreeMap::new(),
        render_requests: Vec::with_capacity(sources.len()),
        render_texture_ids: BTreeSet::new(),
        available_outputs: Vec::with_capacity(sources.len()),
        next_dirty_serial: 0,
        flutter_request_latched: false,
        flutter_outputs_dirty: false,
        flutter_tick: None,
        last_flutter_target: None,
        audit: None,
    }
}

fn pending(
    flutter_requested: bool,
    _app_textures_updated: bool,
    _producer_available: bool,
) -> PendingFrame {
    PendingFrame { flutter_requested }
}

#[test]
fn idle_display_ticks_without_rendering() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);

    let action = scheduler.step(now, pending(false, false, true));

    assert_eq!(scheduler.output_ticks().len(), 1);
    assert_eq!(action, FrameAction::Skip);
}

#[test]
fn app_or_flutter_events_cannot_create_an_early_tick() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.step(now, pending(false, false, true));

    let action = scheduler.step(now + Duration::from_millis(1), pending(true, true, true));

    assert!(scheduler.output_ticks().is_empty());
    assert_eq!(action, FrameAction::Skip);
}

#[test]
fn app_damage_waits_for_its_output_tick() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.step(now, pending(false, false, true));
    scheduler.mark_app_dirty(FAST_OUTPUT, [7]);

    assert_eq!(
        scheduler.step(now + Duration::from_millis(1), pending(false, false, true)),
        FrameAction::Skip
    );
    let render = scheduler.step(now + INTERVAL, pending(false, false, true));

    assert_eq!(
        render,
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert_eq!(scheduler.render_requests().len(), 1);
    assert_eq!(scheduler.render_requests()[0].tick.output, FAST_OUTPUT);
    assert_eq!(scheduler.render_texture_ids().collect::<Vec<_>>(), vec![7]);
}

#[test]
fn flutter_and_texture_damage_share_one_tick() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.mark_app_dirty(FAST_OUTPUT, [11]);

    let action = scheduler.step(now, pending(true, true, true));

    assert_eq!(
        action,
        FrameAction::Render {
            flutter_output: Some(FAST_OUTPUT)
        }
    );
    assert_eq!(scheduler.render_requests().len(), 1);
    assert_eq!(scheduler.render_texture_ids().collect::<Vec<_>>(), vec![11]);
}

#[test]
fn an_older_completion_cannot_clear_newer_output_damage() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.mark_app_dirty(FAST_OUTPUT, [7]);
    assert_eq!(
        scheduler.step(now, pending(false, false, true)),
        FrameAction::Render {
            flutter_output: None
        }
    );
    let old_serial = scheduler.render_requests()[0].dirty_serial;

    scheduler.mark_app_dirty(FAST_OUTPUT, [9]);
    scheduler.complete_render(FAST_OUTPUT, old_serial);

    assert!(scheduler.dirty_outputs.contains_key(&FAST_OUTPUT));
    assert_eq!(
        scheduler
            .dirty_outputs
            .get(&FAST_OUTPUT)
            .unwrap()
            .texture_ids
            .iter()
            .copied()
            .collect::<Vec<_>>(),
        vec![7, 9]
    );
}

#[test]
fn the_timeline_keeps_ticking_while_every_producer_is_idle() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.step(now, pending(false, false, true));

    let action = scheduler.step(now + INTERVAL, pending(false, false, true));

    assert_eq!(scheduler.output_ticks()[0].render_deadline, now + INTERVAL);
    assert_eq!(action, FrameAction::Skip);
}

#[test]
fn an_early_flutter_baton_waits_for_its_output_reservation() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);

    assert_eq!(
        scheduler.step_with_output_availability(now, pending(true, true, false), |_| false),
        FrameAction::Skip
    );
    let action =
        scheduler
            .step_with_output_availability(now + INTERVAL, pending(true, true, true), |_| true);

    assert_eq!(
        action,
        FrameAction::Render {
            flutter_output: Some(FAST_OUTPUT)
        }
    );
}

#[test]
fn each_tick_targets_the_following_presentation_edge() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.step(now + Duration::from_millis(1), pending(false, false, true));

    let tick = scheduler.output_ticks()[0];
    assert_eq!(tick.sequence, 1);
    assert_eq!(tick.interval, INTERVAL);
    assert_eq!(tick.render_deadline, now);
    assert_eq!(tick.presentation_target, now + INTERVAL);
}

#[test]
fn presentation_feedback_corrects_only_the_following_edge() {
    let now = Instant::now();
    let mut timeline = OutputTimeline::new(
        TimelineSource {
            output: FAST_OUTPUT,
            interval: INTERVAL,
        },
        now,
    );
    let first = timeline.take_tick(now).unwrap();

    timeline.observe_presentation(
        first.presentation_target,
        first.presentation_target + Duration::from_millis(4),
    );

    assert!(
        timeline
            .take_tick(now + INTERVAL - Duration::from_nanos(1))
            .is_none()
    );
    let corrected = timeline.take_tick(now + INTERVAL).unwrap();
    assert_eq!(corrected.render_deadline, now + INTERVAL);
    assert_eq!(
        corrected.presentation_target,
        now + INTERVAL * 2 + PHASE_LOCK_MAX_ADJUSTMENT
    );
    assert_eq!(corrected.interval, INTERVAL + PHASE_LOCK_MAX_ADJUSTMENT);
}

#[test]
fn presentation_feedback_ignores_complete_missed_periods() {
    let now = Instant::now();
    let mut timeline = OutputTimeline::new(
        TimelineSource {
            output: FAST_OUTPUT,
            interval: INTERVAL,
        },
        now,
    );
    let first = timeline.take_tick(now).unwrap();

    timeline.observe_presentation(
        first.presentation_target,
        first.presentation_target + INTERVAL + Duration::from_millis(2),
    );

    let corrected = timeline.take_tick(now + INTERVAL).unwrap();
    assert_eq!(
        corrected.presentation_target,
        now + INTERVAL * 2 + PHASE_LOCK_MAX_ADJUSTMENT
    );
}

#[test]
fn presentation_feedback_can_advance_the_following_phase() {
    let now = Instant::now();
    let mut timeline = OutputTimeline::new(
        TimelineSource {
            output: FAST_OUTPUT,
            interval: INTERVAL,
        },
        now,
    );
    let first = timeline.take_tick(now).unwrap();

    timeline.observe_presentation(
        first.presentation_target,
        first.presentation_target - Duration::from_millis(4),
    );

    let corrected = timeline.take_tick(now + INTERVAL).unwrap();
    assert_eq!(
        corrected.presentation_target,
        now + INTERVAL * 2 - PHASE_LOCK_MAX_ADJUSTMENT
    );
    assert_eq!(corrected.interval, INTERVAL - PHASE_LOCK_MAX_ADJUSTMENT);
}

#[test]
fn presentation_jitter_inside_the_deadband_does_not_move_the_timeline() {
    let now = Instant::now();
    let mut timeline = OutputTimeline::new(
        TimelineSource {
            output: FAST_OUTPUT,
            interval: INTERVAL,
        },
        now,
    );
    let first = timeline.take_tick(now).unwrap();

    timeline.observe_presentation(
        first.presentation_target,
        first.presentation_target + PHASE_LOCK_DEADBAND,
    );

    let next = timeline.take_tick(now + INTERVAL).unwrap();
    assert_eq!(next.presentation_target, now + INTERVAL * 2);
    assert_eq!(next.interval, INTERVAL);
}

#[test]
fn presentation_feedback_adjusts_only_its_output_timeline() {
    let now = Instant::now();
    let mut scheduler = mixed_scheduler(now);
    scheduler.step(now, pending(false, false, true));

    scheduler.step(now + FAST_INTERVAL, pending(false, false, true));
    scheduler.observe_presentation(
        SLOW_OUTPUT,
        now + INTERVAL,
        now + INTERVAL + Duration::from_millis(4),
    );
    scheduler.step(now + INTERVAL, pending(false, false, true));

    let fast = scheduler
        .output_ticks()
        .iter()
        .find(|tick| tick.output == FAST_OUTPUT)
        .unwrap();
    let slow = scheduler
        .output_ticks()
        .iter()
        .find(|tick| tick.output == SLOW_OUTPUT)
        .unwrap();
    assert_eq!(fast.presentation_target, now + FAST_INTERVAL * 3);
    assert_eq!(
        slow.presentation_target,
        now + INTERVAL * 2 + PHASE_LOCK_MAX_ADJUSTMENT
    );
}

#[test]
fn missed_intervals_collapse_to_the_latest_tick() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.step(now, pending(false, false, true));

    scheduler.step(
        now + INTERVAL * 4 + Duration::from_millis(1),
        pending(false, false, true),
    );

    let tick = scheduler.output_ticks()[0];
    assert_eq!(tick.sequence, 5);
    assert_eq!(tick.render_deadline, now + INTERVAL * 4);
    assert_eq!(tick.presentation_target, now + INTERVAL * 5);
}

#[test]
fn mixed_refresh_outputs_tick_at_their_own_rates() {
    let now = Instant::now();
    let mut scheduler = mixed_scheduler(now);
    let mut fast_ticks = 0;
    let mut slow_ticks = 0;

    for step in 0..=4 {
        scheduler.step(now + FAST_INTERVAL * step, pending(false, false, true));
        fast_ticks += scheduler
            .output_ticks()
            .iter()
            .filter(|tick| tick.output == FAST_OUTPUT)
            .count();
        slow_ticks += scheduler
            .output_ticks()
            .iter()
            .filter(|tick| tick.output == SLOW_OUTPUT)
            .count();
    }

    assert_eq!(fast_ticks, 5);
    assert_eq!(slow_ticks, 3);
}

#[test]
fn a_slower_output_cannot_dispatch_the_flutter_frame() {
    let now = Instant::now();
    let mut scheduler = non_harmonic_mixed_scheduler(now);
    scheduler.step(now, pending(false, false, true));
    scheduler.step(now + Duration::from_millis(4), pending(false, false, true));
    scheduler.step(now + Duration::from_millis(8), pending(false, false, true));

    assert_eq!(
        scheduler.step(now + INTERVAL, pending(true, false, true)),
        FrameAction::Skip
    );
    assert!(scheduler.dirty_outputs.is_empty());

    assert_eq!(
        scheduler.step(now + Duration::from_millis(12), pending(true, false, true),),
        FrameAction::Render {
            flutter_output: Some(FAST_OUTPUT)
        }
    );
    assert_eq!(scheduler.render_requests().len(), 1);
    assert_eq!(scheduler.render_requests()[0].tick.output, FAST_OUTPUT);
}

#[test]
fn continuous_flutter_uses_only_the_fastest_output_clock() {
    let now = Instant::now();
    let mut scheduler = non_harmonic_mixed_scheduler(now);
    let mut flutter_targets = Vec::new();
    let mut fast_renders = 0;
    let mut slow_renders = 0;

    for millisecond in 0..=40 {
        let action = scheduler.step(
            now + Duration::from_millis(millisecond),
            pending(true, false, true),
        );
        if let FrameAction::Render { flutter_output } = action {
            let completed = scheduler
                .render_requests()
                .iter()
                .map(|request| (request.tick.output, request.dirty_serial))
                .collect::<Vec<_>>();
            fast_renders += completed
                .iter()
                .filter(|(output, _)| *output == FAST_OUTPUT)
                .count();
            slow_renders += completed
                .iter()
                .filter(|(output, _)| *output == SLOW_OUTPUT)
                .count();
            for (output, serial) in completed {
                scheduler.complete_render(output, serial);
            }
            if flutter_output.is_some() {
                flutter_targets.push(
                    scheduler
                        .flutter_tick
                        .expect("Flutter action retains its tick")
                        .presentation_target,
                );
                scheduler.flutter_frame_dispatched();
            }
        }
    }

    assert_eq!(flutter_targets.len(), 11);
    assert_eq!(fast_renders, 11);
    assert_eq!(slow_renders, 5);
    assert!(flutter_targets.windows(2).all(|pair| pair[0] < pair[1]));
}

#[test]
fn changing_the_fastest_output_cannot_move_flutter_time_backwards() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    assert_eq!(
        scheduler.step(now, pending(true, false, true)),
        FrameAction::Render {
            flutter_output: Some(FAST_OUTPUT)
        }
    );
    let completed = scheduler.render_requests()[0];
    scheduler.complete_render(completed.tick.output, completed.dirty_serial);
    let first_target = scheduler
        .flutter_tick
        .expect("Flutter action retains its tick")
        .presentation_target;
    scheduler.flutter_frame_dispatched();

    scheduler.outputs = OutputTimelines {
        timelines: vec![OutputTimeline::new(
            TimelineSource {
                output: FAST_OUTPUT,
                interval: Duration::from_millis(1),
            },
            now + Duration::from_millis(1),
        )],
        ticks: Vec::with_capacity(1),
        flutter_output: Some(FAST_OUTPUT),
    };

    assert_eq!(
        scheduler.step(now + Duration::from_millis(1), pending(true, false, true),),
        FrameAction::Skip
    );
    assert_eq!(scheduler.last_flutter_target, Some(first_target));

    assert_eq!(
        scheduler.step(now + INTERVAL * 2, pending(true, false, true)),
        FrameAction::Render {
            flutter_output: Some(FAST_OUTPUT)
        }
    );
    assert!(
        scheduler
            .flutter_tick
            .expect("Flutter action retains its tick")
            .presentation_target
            > first_target
    );
}

#[test]
fn each_output_authorizes_only_its_own_dirty_tick() {
    let now = Instant::now();
    let mut scheduler = mixed_scheduler(now);
    scheduler.step(now, pending(false, false, true));
    scheduler.mark_app_dirty(SLOW_OUTPUT, [23]);
    assert_eq!(
        scheduler.step(now + FAST_INTERVAL, pending(false, false, true)),
        FrameAction::Skip
    );

    let action = scheduler.step(now + INTERVAL, pending(false, true, true));

    assert_eq!(scheduler.output_ticks().len(), 2);
    assert_eq!(
        action,
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert_eq!(scheduler.render_requests().len(), 1);
    assert_eq!(scheduler.render_requests()[0].tick.output, SLOW_OUTPUT);
    assert_eq!(scheduler.render_texture_ids().collect::<Vec<_>>(), vec![23]);
}

#[test]
fn unavailable_output_stays_dirty_without_blocking_another_output() {
    let now = Instant::now();
    let mut scheduler = mixed_scheduler(now);
    scheduler.mark_app_dirty(FAST_OUTPUT, [11]);
    scheduler.mark_app_dirty(SLOW_OUTPUT, [22]);

    let action =
        scheduler.step_with_output_availability(now, pending(false, true, true), |output| {
            output == SLOW_OUTPUT
        });
    assert_eq!(
        action,
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert_eq!(scheduler.render_requests().len(), 1);
    assert_eq!(scheduler.render_requests()[0].tick.output, SLOW_OUTPUT);
    let slow = scheduler.render_requests()[0];
    scheduler.complete_render(slow.tick.output, slow.dirty_serial);
    assert!(scheduler.dirty_outputs.contains_key(&FAST_OUTPUT));
    assert!(!scheduler.dirty_outputs.contains_key(&SLOW_OUTPUT));

    let action = scheduler.step_with_output_availability(
        now + FAST_INTERVAL,
        pending(false, false, true),
        |_| true,
    );
    assert_eq!(
        action,
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert_eq!(scheduler.render_requests().len(), 1);
    assert_eq!(scheduler.render_requests()[0].tick.output, FAST_OUTPUT);
}

#[test]
fn unavailable_flutter_clock_defers_scene_damage_until_it_can_render() {
    let now = Instant::now();
    let mut scheduler = mixed_scheduler(now);

    let action =
        scheduler.step_with_output_availability(now, pending(true, false, true), |output| {
            output == SLOW_OUTPUT
        });
    assert_eq!(action, FrameAction::Skip);
    assert!(scheduler.dirty_outputs.is_empty());
    assert!(scheduler.flutter_request_latched);

    let action = scheduler.step_with_output_availability(
        now + FAST_INTERVAL,
        pending(true, false, true),
        |_| true,
    );
    assert_eq!(
        action,
        FrameAction::Render {
            flutter_output: Some(FAST_OUTPUT)
        }
    );
    assert!(scheduler.dirty_outputs.contains_key(&FAST_OUTPUT));
    assert!(scheduler.dirty_outputs.contains_key(&SLOW_OUTPUT));
}

#[test]
fn independent_outputs_can_be_authorized_in_one_raster_queue_batch() {
    let now = Instant::now();
    let mut scheduler = mixed_scheduler(now);
    scheduler.mark_all_dirty();
    assert_eq!(
        scheduler.step(now, pending(false, true, false)),
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert_eq!(scheduler.render_requests().len(), 2);
    assert_eq!(
        scheduler
            .render_requests()
            .iter()
            .map(|request| request.tick.output)
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([FAST_OUTPUT, SLOW_OUTPUT])
    );
}

#[test]
fn parked_output_retains_texture_damage_until_its_wake_tick() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.mark_app_dirty(FAST_OUTPUT, [9]);

    scheduler.reconfigure_sources(
        BTreeSet::from([FAST_OUTPUT]),
        Vec::new(),
        now + Duration::from_millis(1),
    );
    scheduler.mark_app_dirty(FAST_OUTPUT, [11]);

    assert_eq!(
        scheduler.step(now + Duration::from_millis(2), pending(false, false, true)),
        FrameAction::Skip
    );
    assert!(scheduler.output_ticks().is_empty());
    assert_eq!(
        scheduler
            .dirty_outputs
            .get(&FAST_OUTPUT)
            .unwrap()
            .texture_ids
            .iter()
            .copied()
            .collect::<Vec<_>>(),
        vec![9, 11]
    );

    let wake = now + Duration::from_millis(3);
    scheduler.reconfigure_sources(
        BTreeSet::from([FAST_OUTPUT]),
        vec![TimelineSource {
            output: FAST_OUTPUT,
            interval: INTERVAL,
        }],
        wake,
    );

    assert_eq!(
        scheduler.step(wake, pending(false, false, true)),
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert_eq!(
        scheduler.render_texture_ids().collect::<Vec<_>>(),
        vec![9, 11]
    );
}

#[test]
fn waking_a_clean_output_forces_one_fresh_projection() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.reconfigure_sources(
        BTreeSet::from([FAST_OUTPUT]),
        Vec::new(),
        now + Duration::from_millis(1),
    );
    let wake = now + Duration::from_millis(2);
    scheduler.reconfigure_sources(
        BTreeSet::from([FAST_OUTPUT]),
        vec![TimelineSource {
            output: FAST_OUTPUT,
            interval: INTERVAL,
        }],
        wake,
    );

    assert_eq!(
        scheduler.step(wake, pending(false, false, true)),
        FrameAction::Render {
            flutter_output: None
        }
    );
    assert!(scheduler.render_texture_ids().next().is_none());
}

#[test]
fn removing_an_output_drops_its_parked_damage() {
    let now = Instant::now();
    let mut scheduler = scheduler(now);
    scheduler.mark_app_dirty(FAST_OUTPUT, [9]);

    scheduler.reconfigure_sources(BTreeSet::new(), Vec::new(), now + Duration::from_millis(1));

    assert!(scheduler.dirty_outputs.is_empty());
}
