//! Runtime pipeline, scheduling, and resource-lifetime tests.

use super::*;

fn assert_near(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < 1.0e-9,
        "expected {expected}, got {actual}"
    );
}

#[test]
fn output_rotation_uses_the_shortest_cardinal_path() {
    assert_eq!(
        shortest_rotation_delta(OutputTransform::Normal, OutputTransform::Rotate90),
        1
    );
    assert_eq!(
        shortest_rotation_delta(OutputTransform::Normal, OutputTransform::Rotate270),
        -1
    );
    assert_eq!(
        shortest_rotation_delta(OutputTransform::Rotate270, OutputTransform::Normal),
        1
    );
    assert_eq!(
        shortest_rotation_delta(OutputTransform::Flipped90, OutputTransform::Flipped270),
        2
    );
}

#[test]
fn animated_projection_has_exact_filled_cardinal_endpoints() {
    let target = RenderOutputTransform {
        scale_x: 0.0,
        skew_x: -1.0,
        translate_x: 1920.0,
        skew_y: 1.0,
        scale_y: 0.0,
        translate_y: 0.0,
    };
    let animation = AnimatedOutputRotation {
        frame_index: 0,
        initial_angle: -std::f64::consts::FRAC_PI_2,
        initial_scale_x: 1920.0 / 1080.0,
        initial_scale_y: 1080.0 / 1920.0,
    };

    let initial = animated_rotation_transform(target, 1920.0, 1080.0, animation, 0.0);
    assert_near(initial.scale_x, 1920.0 / 1080.0);
    assert_near(initial.skew_x, 0.0);
    assert_near(initial.translate_x, 0.0);
    assert_near(initial.skew_y, 0.0);
    assert_near(initial.scale_y, 1080.0 / 1920.0);
    assert_near(initial.translate_y, 0.0);

    let final_projection = animated_rotation_transform(target, 1920.0, 1080.0, animation, 1.0);
    assert_eq!(final_projection, target);
}

#[test]
fn output_rotation_defers_canvas_resize_until_the_final_quarter() {
    let output_id = OutputId(1);
    let render_view_id = RenderViewId::for_output(output_id).unwrap();
    let previous_runtime = RuntimeRenderOutput {
        output_id,
        render_view_id,
        configuration_generation: 7,
        target_size: PixelSize::new(1080, 1920),
        transform: OutputTransform::Normal,
        logical_x: 0.0,
        logical_y: 0.0,
        logical_width: 1080.0,
        logical_height: 1920.0,
    };
    let current_runtime = RuntimeRenderOutput {
        transform: OutputTransform::Rotate90,
        logical_width: 1920.0,
        logical_height: 1080.0,
        ..previous_runtime
    };
    let identity = RenderOutputTransform {
        scale_x: 1.0,
        skew_x: 0.0,
        translate_x: 0.0,
        skew_y: 0.0,
        scale_y: 1.0,
        translate_y: 0.0,
    };
    let previous_target = RenderOutput {
        render_view_id: render_view_id.get(),
        configuration_generation: 7,
        source_physical_x: 0.0,
        source_physical_y: 0.0,
        source_physical_width: 1080.0,
        source_physical_height: 1920.0,
        target_width: 1080,
        target_height: 1920,
        scale_120: SCALE_BASE,
        source_to_target_transform: identity,
    };
    let final_transform = RenderOutputTransform {
        scale_x: 0.0,
        skew_x: -1.0,
        translate_x: 1080.0,
        skew_y: 1.0,
        scale_y: 0.0,
        translate_y: 0.0,
    };
    let current_target = RenderOutput {
        source_physical_width: 1920.0,
        source_physical_height: 1080.0,
        source_to_target_transform: final_transform,
        ..previous_target
    };
    let started_at = Instant::now();
    let mut animation = OutputRotationAnimation::new(
        &[previous_runtime],
        &[previous_target],
        &[current_runtime],
        &[current_target],
        started_at,
    )
    .unwrap();

    let (frame, sample) = animation.sample(started_at);
    assert!(!sample.geometry_resize_due);
    assert_eq!(frame[0].source_physical_width, 1080.0);
    assert_near(frame[0].source_to_target_transform.scale_x, 1.0);
    assert_near(frame[0].source_to_target_transform.skew_x, 0.0);
    assert_near(frame[0].source_to_target_transform.translate_x, 0.0);
    assert_near(frame[0].source_to_target_transform.skew_y, 0.0);
    assert_near(frame[0].source_to_target_transform.scale_y, 1.0);
    assert_near(frame[0].source_to_target_transform.translate_y, 0.0);

    let (frame, sample) = animation.sample(started_at + Duration::from_millis(180));
    assert!(!sample.geometry_resize_due);
    assert_eq!(frame[0].source_physical_width, 1080.0);

    let (frame, sample) = animation.sample(started_at + Duration::from_millis(200));
    assert!(sample.geometry_resize_due);
    assert_eq!(frame[0].source_physical_width, 1920.0);

    let (_, sample) = animation.sample(started_at + Duration::from_millis(220));
    assert!(!sample.geometry_resize_due);

    let (frame, sample) = animation.sample(started_at + OUTPUT_ROTATION_ANIMATION_DURATION);
    assert!(sample.complete);
    assert_eq!(frame[0], current_target);
}

#[test]
fn producer_request_expires_only_after_the_no_raster_grace_period() {
    let producer = ProducerArbiter::new();
    let started_at = Instant::now();
    let grace = Duration::from_millis(17);

    assert!(producer.try_request(started_at));
    assert!(producer.is_busy());
    assert!(!producer.recover_no_raster(started_at + Duration::from_millis(16), grace));
    assert!(producer.recover_no_raster(started_at + grace, grace));
    assert!(!producer.is_busy());
}

#[test]
fn raster_claim_wins_over_no_raster_recovery() {
    let producer = ProducerArbiter::new();
    let started_at = Instant::now();

    assert!(producer.try_request(started_at));
    producer.begin_raster();
    assert!(!producer.recover_no_raster(started_at + Duration::from_secs(1), Duration::ZERO));
    assert_eq!(producer.finish(), FlutterProducerState::Rasterizing);
    assert!(!producer.is_busy());
}

#[test]
fn late_raster_reclaims_an_expired_reservation() {
    let producer = ProducerArbiter::new();
    let started_at = Instant::now();

    assert!(producer.try_request(started_at));
    assert!(producer.recover_no_raster(
        started_at + Duration::from_millis(20),
        Duration::from_millis(17)
    ));
    producer.begin_raster();
    assert!(producer.is_busy());
    assert_eq!(producer.finish(), FlutterProducerState::Rasterizing);
}

#[test]
fn posix_locale_parser_preserves_chinese_script_distinctions() {
    let simplified = parse_posix_locale("zh_CN.UTF-8").expect("Simplified Chinese locale");
    assert_eq!(simplified.language_code(), c"zh");
    assert_eq!(simplified.country_code(), Some(c"CN"));
    assert_eq!(simplified.script_code(), Some(c"Hans"));

    let traditional = parse_posix_locale("zh_TW.UTF-8").expect("Traditional Chinese locale");
    assert_eq!(traditional.country_code(), Some(c"TW"));
    assert_eq!(traditional.script_code(), Some(c"Hant"));
}

#[test]
fn locale_environment_uses_posix_category_precedence() {
    let locale = locale_from_environment(|name| match name {
        "LC_ALL" => Some(String::new()),
        "LC_MESSAGES" => Some("zh-Hans-SG.UTF-8".to_owned()),
        "LANG" => Some("en_US.UTF-8".to_owned()),
        _ => None,
    })
    .expect("message locale");
    assert_eq!(locale.language_code(), c"zh");
    assert_eq!(locale.country_code(), Some(c"SG"));
    assert_eq!(locale.script_code(), Some(c"Hans"));
    assert_eq!(locale.variant_code(), None);
}

#[test]
fn vm_service_log_parser_only_accepts_the_configured_loopback_service() {
    assert_eq!(
        vm_service_uri_from_log(
            "The Dart VM service is listening on http://127.0.0.1:43125/AUTH=/"
        ),
        Some("http://127.0.0.1:43125/AUTH=/")
    );
    assert_eq!(
        vm_service_uri_from_log("http://0.0.0.0:43125/unsafe=/"),
        None
    );
    assert_eq!(
        vm_service_uri_from_log("application printed http://127.0.0.1:43125/spoof=/"),
        None
    );
    assert_eq!(
        vm_service_uri_from_log("http://127.0.0.1:not-a-port/token=/"),
        None
    );
    assert_eq!(vm_service_uri_from_log("http://127.0.0.1:43125/"), None);
    assert_eq!(vm_service_uri_from_log("ordinary Flutter log"), None);
}

#[test]
fn flutter_scroll_delta_scales_only_finger_scroll() {
    assert_eq!(
        flutter_scroll_delta(Some(15.0), Some(120.0), AxisSource::Wheel, 5.0),
        53.0
    );
    assert_eq!(
        flutter_scroll_delta(Some(-15.0), Some(-60.0), AxisSource::Wheel, 0.05),
        -26.5
    );
    assert_eq!(
        flutter_scroll_delta(Some(7.25), None, AxisSource::Finger, 2.0),
        14.5
    );
    assert_eq!(
        flutter_scroll_delta(Some(7.25), None, AxisSource::Continuous, 2.0),
        7.25
    );
    assert_eq!(
        flutter_scroll_delta(None, None, AxisSource::Finger, 5.0),
        0.0
    );
}

#[test]
fn closing_window_textures_remain_leased_until_flutter_completes() {
    let now = Instant::now();
    let mut leases = WindowCloseTextureLeases::default();
    assert_eq!(
        leases
            .publish(HashMap::from([(41, vec![7, 8])]), now)
            .lease_count,
        0
    );

    let retired = leases.publish(HashMap::new(), now);
    assert_eq!(retired.lease_count, 0);
    assert!(retired.texture_ids.is_empty());
    assert!(leases.retains_texture(7));
    assert!(leases.retains_texture(8));

    let retired = leases.complete(41);
    assert_eq!(retired.lease_count, 1);
    assert_eq!(retired.texture_ids, [7, 8]);
    assert!(!leases.retains_texture(7));
    assert!(!leases.retains_texture(8));
    assert_eq!(leases.complete(41).lease_count, 0);
}

#[test]
fn closing_window_texture_leases_have_a_watchdog() {
    let now = Instant::now();
    let mut leases = WindowCloseTextureLeases::default();
    leases.publish(HashMap::from([(41, vec![7])]), now);
    leases.publish(HashMap::new(), now);

    assert_eq!(
        leases
            .expire(now + WINDOW_CLOSE_LEASE_TIMEOUT - Duration::from_nanos(1))
            .lease_count,
        0
    );
    let retired = leases.expire(now + WINDOW_CLOSE_LEASE_TIMEOUT);
    assert_eq!(retired.lease_count, 1);
    assert_eq!(retired.texture_ids, [7]);
    assert!(!leases.retains_texture(7));
}

#[test]
fn window_close_completion_is_one_positive_little_endian_id() {
    assert_eq!(
        decode_window_close_complete(&0x0102_0304_0506_0708_u64.to_le_bytes()),
        Some(0x0102_0304_0506_0708)
    );
    assert_eq!(decode_window_close_complete(&0_u64.to_le_bytes()), None);
    assert_eq!(decode_window_close_complete(&[1; 7]), None);
    assert_eq!(decode_window_close_complete(&[1; 9]), None);
}

#[test]
fn timeline_vsync_preserves_the_deadline_across_dispatch_latency() {
    let interval = Duration::from_millis(5);
    let (start, target) =
        timeline_vsync_timestamps(1_000_000_000, Duration::from_micros(750), interval);
    assert_eq!(start, 999_250_000);
    assert_eq!(target, 1_004_250_000);

    let (saturated_start, saturated_target) =
        timeline_vsync_timestamps(100, Duration::from_nanos(200), Duration::from_nanos(50));
    assert_eq!((saturated_start, saturated_target), (0, 50));
}

struct PanicsOnDrop;

impl Drop for PanicsOnDrop {
    fn drop(&mut self) {
        panic!("panic payload escaped its containment guard");
    }
}

#[test]
fn external_texture_ffi_guard_forgets_hostile_panic_payloads() {
    assert!(!contain_ffi_unwind(|| std::panic::panic_any(PanicsOnDrop)));
}

#[test]
fn external_texture_resource_budget_is_exact_and_reusable() {
    let budget = Arc::new(ExternalTextureResourceBudget::default());
    let permits = (0..MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES)
        .map(|_| budget.try_acquire().unwrap())
        .collect::<Vec<_>>();
    assert!(budget.try_acquire().is_none());
    assert_eq!(budget.live(), MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES);
    drop(permits);
    assert_eq!(budget.live(), 0);
    assert!(budget.try_acquire().is_some());
}

#[test]
fn cached_shm_binding_retires_after_its_last_flutter_lease() {
    let budget = Arc::new(ExternalTextureResourceBudget::default());
    let retirements = Arc::new(RetiredExternalBindingQueue::new());
    let binding = Arc::new(CachedTextureBinding {
        binding: Some(ExternalTextureBinding {
            dmabuf_image: None,
            texture: 77,
            _resource_permit: budget.try_acquire().unwrap(),
        }),
        retirements: Arc::clone(&retirements),
    });
    let cached = Arc::clone(&binding);
    let pool = Arc::new(Mutex::new(Vec::new()));
    let lease = Box::new(ExternalTextureLease {
        resource: Some(ExternalTextureLeaseResource::Shm {
            _binding: binding,
            _resource_permit: budget.try_acquire().unwrap(),
        }),
        pool: Arc::downgrade(&pool),
    });
    assert_eq!(budget.live(), 2);

    let raw = Box::into_raw(lease).cast();
    // SAFETY: `raw` came from exactly one Box::into_raw above and this is
    // the callback's single ownership-consuming invocation.
    unsafe { retire_external_texture(raw) };
    assert_eq!(lock(&pool).len(), 1);
    assert!(lock(&pool)[0].resource.is_none());
    assert!(lock(&retirements.bindings).is_empty());
    assert!(!retirements.pending.load(Ordering::Acquire));
    assert_eq!(budget.live(), 1);
    drop(cached);
    assert!(retirements.pending.load(Ordering::Acquire));
    assert_eq!(lock(&retirements.bindings).len(), 1);
    let binding = lock(&retirements.bindings).pop().unwrap();
    assert_eq!(binding.texture, 77);
    drop(binding);
    assert_eq!(budget.live(), 0);
}

#[test]
fn shm_source_generation_requires_the_same_snapshot_identity() {
    let pixels = vec![1, 2, 3, 4];
    let pixel_storage = pixels.as_ptr();
    let frame = ShmTextureFrame::new(1, 1, 9, pixels).unwrap();
    assert_eq!(frame.pixels().as_ptr(), pixel_storage);
    let current = ExternalTextureSource::Shm(frame.clone());
    let same_snapshot = ExternalTextureSource::Shm(frame);
    let colliding_revision =
        ExternalTextureSource::Shm(ShmTextureFrame::new(1, 1, 9, vec![5, 6, 7, 8]).unwrap());

    assert!(current.same_generation(&same_snapshot));
    assert!(!current.same_generation(&colliding_revision));
}

#[test]
fn external_texture_queue_preserves_one_jittered_successor() {
    let source = |revision, value| {
        ExternalTextureSource::Shm(
            ShmTextureFrame::new(1, 1, revision, vec![value, 0, 0, 255]).unwrap(),
        )
    };
    let mut slot = ExternalTextureSlot::default();

    let first = source(1, 1);
    assert!(slot.queue(first.clone(), true));
    // Scene-only commits can republish every texture. They must not prime
    // another Flutter frame unless the visual generation really changed.
    assert!(!slot.queue(first, true));
    assert!(slot.advance());
    assert_eq!(slot.current.as_ref().unwrap().generation(), 1);
    assert!(!slot.current_sampled);

    assert!(slot.queue(source(2, 2), true));
    assert!(!slot.advance());
    assert_eq!(slot.current.as_ref().unwrap().generation(), 1);

    // A commit arriving across the tick boundary must not replace the
    // immediate successor or the generation already granted to Flutter.
    assert!(slot.queue(source(3, 3), true));
    assert_eq!(slot.queued.as_ref().unwrap().generation(), 2);
    assert_eq!(slot.lookahead.as_ref().unwrap().generation(), 3);
    slot.current_sampled = true;
    assert!(slot.advance());
    assert_eq!(slot.current.as_ref().unwrap().generation(), 2);
    assert_eq!(slot.queued.as_ref().unwrap().generation(), 3);
    assert!(slot.lookahead.is_none());
    assert!(!slot.current_sampled);
    assert!(!slot.advance());

    slot.current_sampled = true;
    assert!(slot.advance());
    assert_eq!(slot.current.as_ref().unwrap().generation(), 3);
    assert!(!slot.has_queued());

    // If the client gets farther ahead, retain the immediate successor
    // and replace only the far end of the bounded queue.
    assert!(slot.queue(source(4, 4), true));
    assert!(slot.queue(source(5, 5), true));
    assert!(slot.queue(source(6, 6), true));
    assert_eq!(slot.queued.as_ref().unwrap().generation(), 4);
    assert_eq!(slot.lookahead.as_ref().unwrap().generation(), 6);
    slot.current_sampled = true;
    assert!(slot.advance());
    assert_eq!(slot.current.as_ref().unwrap().generation(), 4);
    assert_eq!(slot.queued.as_ref().unwrap().generation(), 6);

    // Like C++, off-scene surfaces do not wait forever for a sample which
    // the shell has explicitly said it will not draw.
    assert!(slot.queue(source(7, 7), false));
    assert!(slot.advance());
    assert_eq!(slot.current.as_ref().unwrap().generation(), 6);
    assert_eq!(slot.queued.as_ref().unwrap().generation(), 7);
}

#[test]
fn released_shm_frames_recycle_their_pixel_allocation() {
    let pool = Arc::new(ShmSnapshotPool::new());
    let mut pixels = Vec::with_capacity(4096);
    pixels.extend_from_slice(&[1, 2, 3, 4]);
    let pixel_storage = pixels.as_ptr();
    let frame = ShmTextureFrame::new_pooled(1, 1, 1, pixels, &pool).unwrap();
    drop(frame);

    let recycled = pool.acquire(4);
    assert_eq!(recycled.as_ptr(), pixel_storage);
    assert!(recycled.capacity() >= 4096);
    assert_eq!(pool.retained_state(), (0, 0));
}

fn queued_pointer(
    phase: sys::FlutterPointerPhase,
    x: f64,
    device: i32,
    buttons: i64,
    replaceable_motion: bool,
) -> InputRecord {
    InputRecord::Pointer(PointerRecord {
        phase,
        x,
        y: x,
        device,
        signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
        scroll_x: 0.0,
        scroll_y: 0.0,
        device_kind: if device == 0 {
            sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse
        } else {
            sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindTouch
        },
        buttons,
        replaceable_motion,
    })
}

fn queued_scroll(delta: f64) -> InputRecord {
    InputRecord::Pointer(PointerRecord {
        phase: sys::FlutterPointerPhase_kHover,
        x: 0.0,
        y: 0.0,
        device: 0,
        signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll,
        scroll_x: 0.0,
        scroll_y: delta,
        device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
        buttons: 0,
        replaceable_motion: false,
    })
}

fn queued_key(pressed: bool) -> InputRecord {
    InputRecord::Keyboard(KeyboardRecord {
        keycode: 30,
        unicode: u32::from('a'),
        modifiers: 0,
        pressed,
    })
}

#[test]
fn input_queue_coalesces_each_motion_tail_by_latest_device_order() {
    let mut events = VecDeque::new();
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kAdd, 0.0, 1, 0, false),
        8,
    );
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kMove, 1.0, 1, 0, true),
        8,
    );
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kMove, 2.0, 2, 0, true),
        8,
    );
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kMove, 3.0, 1, 0, true),
        8,
    );

    let samples: Vec<_> = events
        .iter()
        .filter_map(|event| match event {
            InputRecord::Pointer(event) if event.replaceable_motion => {
                Some((event.device, event.x))
            }
            InputRecord::Pointer(_) | InputRecord::Keyboard(_) => None,
        })
        .collect();
    assert_eq!(samples, [(2, 2.0), (1, 3.0)]);

    // A semantic transition is a compaction boundary even when Flutter
    // represents that transition with the Move phase (second button).
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kMove, 3.0, 1, 3, false),
        8,
    );
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kMove, 4.0, 1, 3, true),
        8,
    );
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kMove, 5.0, 1, 3, true),
        8,
    );

    assert_eq!(events.len(), 5);
    let mut tail = events.iter().rev();
    assert!(matches!(
        tail.next(),
        Some(InputRecord::Pointer(PointerRecord {
            x: 5.0,
            replaceable_motion: true,
            ..
        }))
    ));
    assert!(matches!(
        tail.next(),
        Some(InputRecord::Pointer(PointerRecord {
            buttons: 3,
            replaceable_motion: false,
            ..
        }))
    ));
}

#[test]
fn input_queue_motion_flood_preserves_transitions_and_latest_position() {
    let mut events = VecDeque::new();
    for event in [
        queued_pointer(sys::FlutterPointerPhase_kAdd, 0.0, 0, 0, false),
        queued_pointer(sys::FlutterPointerPhase_kDown, 0.0, 0, 1, false),
        queued_pointer(sys::FlutterPointerPhase_kMove, 0.0, 0, 3, false),
        queued_key(false),
        queued_pointer(sys::FlutterPointerPhase_kUp, 0.0, 0, 0, false),
    ] {
        push_bounded_input(&mut events, event, 6);
    }
    for x in 1..=10_000 {
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kHover, f64::from(x), 0, 0, true),
            6,
        );
    }

    assert_eq!(events.len(), 6);
    assert!(
        matches!(events[0], InputRecord::Pointer(event) if event.phase == sys::FlutterPointerPhase_kAdd)
    );
    assert!(
        matches!(events[1], InputRecord::Pointer(event) if event.phase == sys::FlutterPointerPhase_kDown)
    );
    assert!(
        matches!(events[2], InputRecord::Pointer(event) if event.buttons == 3 && !event.replaceable_motion)
    );
    assert!(matches!(events[3], InputRecord::Keyboard(event) if !event.pressed));
    assert!(
        matches!(events[4], InputRecord::Pointer(event) if event.phase == sys::FlutterPointerPhase_kUp)
    );
    assert!(
        matches!(events[5], InputRecord::Pointer(event) if event.x == 10_000.0 && event.replaceable_motion)
    );
}

#[test]
fn input_queue_resize_starts_a_fresh_flutter_device_lifecycle() {
    let mut input = InputQueue::new(PixelSize::new(1920, 1080));
    input.pointer_x = 1900.0;
    input.pointer_y = 1000.0;
    input.pointer_buttons = 3;
    input.mouse_added = true;
    input.touch_positions.insert(4, (100.0, 200.0));
    input.events.push_back(queued_pointer(
        sys::FlutterPointerPhase_kMove,
        42.0,
        0,
        3,
        false,
    ));

    input.resize(PixelSize::new(1280, 720));

    assert_eq!((input.pointer_x, input.pointer_y), (1280.0, 720.0));
    assert_eq!(input.pointer_buttons, 0);
    assert!(!input.mouse_added);
    assert!(input.touch_positions.is_empty());
    assert!(input.events.is_empty());
}

#[test]
fn compositor_position_remains_authoritative_during_repeated_locked_motion() {
    let mut input = InputQueue::new(PixelSize::new(1920, 1080));

    // A locked pointer can produce an arbitrary stream of relative
    // libinput deltas while its compositor position remains fixed. Every
    // Flutter sample must use that resolved position, not integrate those
    // deltas independently.
    for _ in 0..128 {
        input.handle_pointer_motion_at(713.25, 419.75);
    }

    assert_eq!((input.pointer_x, input.pointer_y), (713.25, 419.75));
    assert_eq!(input.events.len(), 2); // Add plus coalesced Hover.
    assert!(matches!(
        input.events.back(),
        Some(InputRecord::Pointer(PointerRecord {
            x: 713.25,
            y: 419.75,
            replaceable_motion: true,
            ..
        }))
    ));
}

#[test]
fn routed_pointer_leave_and_reentry_create_balanced_flutter_lifecycles() {
    let mut input = InputQueue::new(PixelSize::new(1920, 1080));

    input.handle_pointer_motion_at(100.0, 200.0);
    input.handle_pointer_leave_at(300.0, 400.0);
    input.handle_pointer_leave_at(300.0, 400.0);
    input.handle_pointer_motion_at(500.0, 600.0);

    let phases = input
        .events
        .iter()
        .filter_map(|event| match event {
            InputRecord::Pointer(event) => {
                Some((event.phase, event.x, event.y, event.replaceable_motion))
            }
            InputRecord::Keyboard(_) => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        phases,
        vec![
            (sys::FlutterPointerPhase_kAdd, 100.0, 200.0, false,),
            (sys::FlutterPointerPhase_kHover, 100.0, 200.0, true,),
            (sys::FlutterPointerPhase_kRemove, 300.0, 400.0, false,),
            (sys::FlutterPointerPhase_kAdd, 500.0, 600.0, false,),
            (sys::FlutterPointerPhase_kHover, 500.0, 600.0, true,),
        ]
    );
    assert!(input.mouse_added);
    assert_eq!((input.pointer_x, input.pointer_y), (500.0, 600.0));
}

#[test]
fn routed_pointer_leave_waits_for_flutter_button_capture_to_end() {
    let mut input = InputQueue::new(PixelSize::new(1920, 1080));

    input.handle_pointer_motion_at(100.0, 200.0);
    input.pointer_buttons = 1;
    input.handle_pointer_leave_at(300.0, 400.0);
    assert!(input.mouse_lifecycle_active());
    assert!(input.events.iter().all(|event| !matches!(
        event,
        InputRecord::Pointer(event)
            if event.phase == sys::FlutterPointerPhase_kRemove
    )));

    input.pointer_buttons = 0;
    input.handle_pointer_leave_at(300.0, 400.0);
    assert!(!input.mouse_lifecycle_active());
    assert!(input.events.iter().any(|event| matches!(
        event,
        InputRecord::Pointer(event)
            if event.phase == sys::FlutterPointerPhase_kRemove
    )));
}

#[test]
fn input_queue_device_removal_terminates_and_restarts_lifecycles() {
    let mut input = InputQueue::new(PixelSize::new(1920, 1080));
    input.pointer_buttons = 1;
    input.mouse_added = true;
    input.touch_positions.insert(4, (100.0, 200.0));

    input.cancel_device_lifecycles(true, true);

    assert_eq!(input.pointer_buttons, 0);
    assert!(!input.mouse_added);
    assert!(input.touch_positions.is_empty());
    let terminal_phases = input
        .events
        .iter()
        .filter_map(|event| match event {
            InputRecord::Pointer(event) => Some((event.device, event.phase)),
            InputRecord::Keyboard(_) => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        terminal_phases,
        vec![
            (0, sys::FlutterPointerPhase_kCancel),
            (0, sys::FlutterPointerPhase_kRemove),
            (4, sys::FlutterPointerPhase_kCancel),
            (4, sys::FlutterPointerPhase_kRemove),
        ]
    );
}

#[test]
fn compositor_gesture_cancels_only_its_flutter_touch_slots() {
    let mut input = InputQueue::new(PixelSize::new(1920, 1080));
    input.touch_positions.insert(1, (100.0, 200.0));
    input.touch_positions.insert(2, (300.0, 400.0));

    input.cancel_touch_slots(&[1]);

    assert_eq!(input.touch_positions, HashMap::from([(1, (100.0, 200.0))]));
    let terminal_phases = input
        .events
        .iter()
        .filter_map(|event| match event {
            InputRecord::Pointer(event) => Some((event.device, event.phase)),
            InputRecord::Keyboard(_) => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        terminal_phases,
        vec![
            (2, sys::FlutterPointerPhase_kCancel),
            (2, sys::FlutterPointerPhase_kRemove),
        ]
    );
}

#[test]
fn input_queue_evicts_motion_before_scroll_or_state_transition() {
    let mut events = VecDeque::new();
    for event in [
        queued_pointer(sys::FlutterPointerPhase_kAdd, 0.0, 0, 0, false),
        queued_pointer(sys::FlutterPointerPhase_kHover, 1.0, 0, 0, true),
        queued_scroll(15.0),
        queued_key(false),
        queued_pointer(sys::FlutterPointerPhase_kUp, 1.0, 0, 0, false),
    ] {
        push_bounded_input(&mut events, event, 5);
    }
    push_bounded_input(
        &mut events,
        queued_pointer(sys::FlutterPointerPhase_kHover, 2.0, 0, 0, true),
        5,
    );

    assert_eq!(events.len(), 5);
    assert!(events.iter().any(|event| matches!(
        event,
        InputRecord::Pointer(PointerRecord {
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll,
            ..
        })
    )));
    assert!(
        events
            .iter()
            .any(|event| matches!(event, InputRecord::Keyboard(key) if !key.pressed))
    );
    assert!(events.iter().any(|event| matches!(
        event,
        InputRecord::Pointer(PointerRecord {
            x: 2.0,
            replaceable_motion: true,
            ..
        })
    )));
    assert!(!events.iter().any(|event| matches!(
        event,
        InputRecord::Pointer(PointerRecord {
            x: 1.0,
            replaceable_motion: true,
            ..
        })
    )));
}

#[test]
fn recency_cache_evicts_the_least_recently_used_binding() {
    let mut cache = RecencyCache::new(2);
    assert!(cache.insert(1, "one").is_none());
    assert!(cache.insert(2, "two").is_none());
    assert_eq!(cache.get_by(|key| *key == 1), Some("one"));

    assert_eq!(cache.insert(3, "three"), Some("two"));
    assert_eq!(cache.get_by(|key| *key == 1), Some("one"));
    assert_eq!(cache.get_by(|key| *key == 2), None);
    assert_eq!(cache.get_by(|key| *key == 3), Some("three"));
    assert_eq!(
        cache.stats(),
        RecencyCacheStats {
            hits: 3,
            misses: 1,
            capacity_evictions: 1,
            explicit_removals: 0,
        }
    );
}

#[test]
fn recency_cache_can_retire_every_binding_owned_by_a_texture() {
    let mut cache = RecencyCache::new(4);
    assert!(cache.insert((7, 1), "seven-a").is_none());
    assert!(cache.insert((8, 2), "eight").is_none());
    assert!(cache.insert((7, 3), "seven-b").is_none());

    let mut retired = cache.remove_where(|(texture_id, _)| *texture_id == 7);
    retired.sort_unstable();
    assert_eq!(retired, ["seven-a", "seven-b"]);
    assert_eq!(cache.get_by(|key| *key == (8, 2)), Some("eight"));
    assert_eq!(cache.stats().explicit_removals, 2);
}

#[test]
fn partitioned_recency_cache_keeps_each_texture_buffer_ring_resident() {
    let mut cache = PartitionedRecencyCache::new(4);
    for texture_id in 0..10 {
        for buffer in 0..4 {
            assert!(
                cache
                    .insert(texture_id, buffer, (texture_id, buffer))
                    .is_none()
            );
        }
    }

    // Forty rotating buffers exceed the old global capacity of 32. Every
    // generation must remain a hit when the same ten clients are sampled
    // repeatedly in Flutter's stable scene order.
    for _ in 0..3 {
        for texture_id in 0..10 {
            for buffer in 0..4 {
                assert_eq!(
                    cache.get_by(&texture_id, |candidate| *candidate == buffer),
                    Some((texture_id, buffer))
                );
            }
        }
    }
}

#[test]
fn partitioned_recency_cache_evicts_and_retires_only_one_texture() {
    let mut cache = PartitionedRecencyCache::new(2);
    assert!(cache.insert(7, 1, "seven-a").is_none());
    assert!(cache.insert(7, 2, "seven-b").is_none());
    assert!(cache.insert(8, 1, "eight-a").is_none());
    assert!(cache.insert(8, 2, "eight-b").is_none());

    assert_eq!(cache.insert(7, 3, "seven-c"), Some("seven-a"));
    assert_eq!(cache.get_by(&7, |key| *key == 1), None);
    assert_eq!(cache.get_by(&8, |key| *key == 1), Some("eight-a"));

    let mut retired = cache.remove(&7);
    retired.sort_unstable();
    assert_eq!(retired, ["seven-b", "seven-c"]);
    assert_eq!(cache.get_by(&7, |_| true), None);
    assert_eq!(cache.drain().len(), 2);
}

fn rect(left: f64, top: f64, right: f64, bottom: f64) -> sys::FlutterRect {
    sys::FlutterRect {
        left,
        top,
        right,
        bottom,
    }
}

#[test]
fn evdev_keys_use_the_existing_linux_glfw_contract() {
    assert_eq!(glfw_keycode(1), 256);
    assert_eq!(glfw_keycode(16), u32::from('Q'));
    assert_eq!(glfw_keycode(30), u32::from('A'));
    assert_eq!(glfw_keycode(59), 290);
    assert_eq!(glfw_keycode(105), 263);
    assert_eq!(glfw_keycode(125), 343);
    assert_eq!(glfw_keycode(999), 999);
}

#[test]
fn key_event_message_includes_layout_derived_unicode() {
    let mut message = Vec::new();
    encode_key_event(
        KeyboardRecord {
            keycode: 30,
            unicode: u32::from('à'),
            modifiers: 1,
            pressed: true,
        },
        &mut message,
    );
    let message: serde_json::Value = serde_json::from_slice(&message).unwrap();
    assert_eq!(message["keyCode"], u32::from('A'));
    assert_eq!(message["scanCode"], u32::from('A'));
    assert_eq!(message["unicodeScalarValues"], u32::from('à'));
    assert_eq!(message["modifiers"], 1);
    assert_eq!(message["type"], "keydown");

    let storage = message.as_object().expect("decoded key event");
    assert_eq!(storage["keymap"], "linux");
    let mut bytes = Vec::with_capacity(160);
    let allocation = bytes.as_ptr();
    encode_key_event(
        KeyboardRecord {
            keycode: 30,
            unicode: 0,
            modifiers: 0,
            pressed: false,
        },
        &mut bytes,
    );
    assert_eq!(bytes.as_ptr(), allocation);
    let release: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(release["type"], "keyup");
    assert!(release.get("unicodeScalarValues").is_none());
}

#[test]
fn pending_vsync_batons_are_deduplicated_bounded_and_one_shot() {
    let mut pending = PendingVsyncBatons::default();
    assert_eq!(pending.register(7), VsyncRegistration::Accepted);
    assert_eq!(pending.register(7), VsyncRegistration::Duplicate);
    assert!(pending.complete(7));
    assert!(!pending.complete(7));
    // Reuse after completion is valid; only simultaneous duplicate
    // obligations are ambiguous and suppressed.
    assert_eq!(pending.register(7), VsyncRegistration::Accepted);
    assert!(pending.complete(7));

    for baton in 0..MAX_PENDING_VSYNC_BATONS {
        assert_eq!(
            pending.register(isize::try_from(baton).unwrap()),
            VsyncRegistration::Accepted
        );
    }
    assert_eq!(pending.register(-1), VsyncRegistration::AtCapacity);
    let batons = pending.take_all();
    assert_eq!(batons.len(), MAX_PENDING_VSYNC_BATONS);
    assert!(pending.take_all().is_empty());

    pending.register(41);
    pending.register(42);
    assert_eq!(pending.take_next(), Some(41));
    pending.restore_front(41);
    assert_eq!(pending.take_all(), VecDeque::from([41, 42]));
}

fn queued_platform_task(
    budget: &Arc<PlatformTaskBudget>,
    task: u64,
    target_time_nanos: u64,
    order: u64,
) -> QueuedPlatformTask {
    QueuedPlatformTask {
        task: ScheduledTask {
            runner: 1,
            task,
            target_time_nanos,
        },
        permit: budget.try_acquire().unwrap(),
        order,
    }
}

#[test]
fn platform_task_budget_bounds_channel_and_runtime_ownership() {
    let budget = Arc::new(PlatformTaskBudget::default());
    let mut permits = (0..MAX_PENDING_PLATFORM_TASKS)
        .map(|_| budget.try_acquire().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(budget.pending(), MAX_PENDING_PLATFORM_TASKS);
    assert!(budget.try_acquire().is_none());

    permits.truncate(MAX_PENDING_PLATFORM_TASKS - 1);
    assert_eq!(budget.pending(), MAX_PENDING_PLATFORM_TASKS - 1);
    let replacement = budget.try_acquire().unwrap();
    assert!(budget.try_acquire().is_none());

    drop(replacement);
    drop(permits);
    assert_eq!(budget.pending(), 0);
}

#[test]
fn platform_tasks_run_by_deadline_fifo_and_handle_clock_extremes() {
    let budget = Arc::new(PlatformTaskBudget::default());
    let mut tasks = BinaryHeap::from([
        queued_platform_task(&budget, 1, 50, 0),
        queued_platform_task(&budget, 2, 20, 1),
        queued_platform_task(&budget, 3, 20, 2),
        queued_platform_task(&budget, 4, u64::MAX, 3),
    ]);

    assert_eq!(
        platform_task_dispatch_timeout(&tasks, 0),
        Duration::from_nanos(20)
    );
    assert!(take_next_due_platform_task(&mut tasks, 19).is_none());
    let second = take_next_due_platform_task(&mut tasks, 20).unwrap();
    assert_eq!(second.task.task, 2);
    drop(second);
    let third = take_next_due_platform_task(&mut tasks, 20).unwrap();
    assert_eq!(third.task.task, 3);
    drop(third);
    let first = take_next_due_platform_task(&mut tasks, 50).unwrap();
    assert_eq!(first.task.task, 1);
    drop(first);

    assert_eq!(
        platform_task_dispatch_timeout(&tasks, u64::MAX - 5),
        Duration::from_nanos(5)
    );
    let last = take_next_due_platform_task(&mut tasks, u64::MAX).unwrap();
    assert_eq!(last.task.task, 4);
    drop(last);
    assert_eq!(
        platform_task_dispatch_timeout(&tasks, u64::MAX),
        Duration::from_millis(100)
    );

    tasks.push(queued_platform_task(&budget, 5, 0, 4));
    assert_eq!(
        platform_task_dispatch_timeout(&tasks, u64::MAX),
        Duration::ZERO
    );
    drop(take_next_due_platform_task(&mut tasks, u64::MAX));
    assert_eq!(budget.pending(), 0);
}

#[test]
fn due_platform_task_batch_yields_before_starving_the_event_loop() {
    let budget = Arc::new(PlatformTaskBudget::default());
    let mut tasks = (0..=MAX_PLATFORM_TASKS_PER_DISPATCH)
        .map(|task| {
            let order = u64::try_from(task).unwrap();
            queued_platform_task(&budget, order, 0, order)
        })
        .collect::<BinaryHeap<_>>();

    for expected in 0..MAX_PLATFORM_TASKS_PER_DISPATCH {
        let queued = take_next_due_platform_task(&mut tasks, 0).unwrap();
        assert_eq!(queued.task.task, u64::try_from(expected).unwrap());
        drop(queued);
    }
    assert_eq!(tasks.len(), 1);
    assert_eq!(platform_task_dispatch_timeout(&tasks, 0), Duration::ZERO);
    drop(tasks);
    assert_eq!(budget.pending(), 0);
}

#[test]
fn frame_ready_wakeup_coalesces_until_acknowledged() {
    let wakeup = CoalescedWakeup::default();
    assert!(wakeup.begin());
    for _ in 0..10_000 {
        assert!(!wakeup.begin());
    }
    wakeup.acknowledge();
    assert!(wakeup.begin());
    wakeup.acknowledge();
}

#[test]
fn coalesced_inbox_batches_edges_and_recycles_storage() {
    let inbox = CoalescedInbox::with_capacity(4);
    let mut batch = Vec::with_capacity(4);

    assert!(inbox.push(1));
    assert!(!inbox.push(2));
    assert!(!inbox.push(3));
    inbox.take_into(&mut batch);
    assert_eq!(batch, [1, 2, 3]);

    batch.clear();
    assert!(inbox.push(4));
    assert!(!inbox.push(5));
    inbox.take_into(&mut batch);
    assert_eq!(batch, [4, 5]);

    batch.clear();
    assert!(inbox.push(6));
    inbox.discard_after_failed_wakeup();
    assert!(inbox.push(7));
    inbox.take_into(&mut batch);
    assert_eq!(batch, [7]);
}

fn output_broker() -> OutputBufferBroker {
    let first = [11, 12, 13];
    let second = [21, 22, 23];
    OutputBufferBroker::new([
        OutputPoolDescriptor {
            output_id: OutputId(1),
            render_view_id: RenderViewId::for_output(OutputId(1)).unwrap(),
            configuration_generation: 7,
            size: PixelSize::new(1920, 1080),
            initial_scanout: 0,
            framebuffers: &first,
        },
        OutputPoolDescriptor {
            output_id: OutputId(2),
            render_view_id: RenderViewId::for_output(OutputId(2)).unwrap(),
            configuration_generation: 7,
            size: PixelSize::new(2560, 1440),
            initial_scanout: 0,
            framebuffers: &second,
        },
    ])
    .unwrap()
}

fn pool(broker: &OutputBufferBroker, output: OutputId) -> &OutputBufferPool {
    broker
        .pools
        .iter()
        .find(|pool| pool.output_id == output)
        .unwrap()
}

fn pool_mut(broker: &mut OutputBufferBroker, output: OutputId) -> &mut OutputBufferPool {
    broker
        .pools
        .iter_mut()
        .find(|pool| pool.output_id == output)
        .unwrap()
}

fn output_request(output: OutputId, render_deadline: Instant) -> OutputFrameRequest {
    OutputFrameRequest {
        tick: FrameTick {
            output,
            sequence: 1,
            interval: Duration::from_millis(10),
            render_deadline,
            presentation_target: render_deadline + Duration::from_millis(10),
        },
        dirty_serial: 1,
    }
}

fn acquire_output(broker: &mut OutputBufferBroker, output: OutputId, size: PixelSize) -> u32 {
    let render_deadline = Instant::now();
    let request = output_request(output, render_deadline);
    let view = RenderViewId::for_output(output).unwrap().get();
    assert_eq!(broker.authorize(request, render_deadline), Some(view));
    broker.acquire(view, size).unwrap()
}

#[test]
fn output_authorizations_queue_independently_on_the_single_raster_thread() {
    let mut broker = output_broker();
    let now = Instant::now();
    let first = OutputId(1);
    let second = OutputId(2);
    let first_view = RenderViewId::for_output(first).unwrap().get();
    let second_view = RenderViewId::for_output(second).unwrap().get();

    assert_eq!(
        broker.authorize(output_request(first, now), now),
        Some(first_view)
    );
    assert_eq!(
        broker.authorize(output_request(second, now), now),
        Some(second_view)
    );
    assert!(!broker.target_available(first));
    assert!(!broker.target_available(second));

    broker.begin_transaction();
    let framebuffer = broker
        .acquire(first_view, PixelSize::new(1920, 1080))
        .unwrap();
    assert!(broker.mark_ready(first_view, framebuffer, &[], &[], None, None));
    assert_eq!(broker.finish_transaction().len(), 1);

    assert!(pool(&broker, second).authorized_request.is_some());
    broker.begin_transaction();
    assert!(
        broker
            .acquire(second_view, PixelSize::new(2560, 1440))
            .is_ok()
    );
}

#[test]
fn unclaimed_output_authorization_expires_after_two_output_intervals() {
    let mut broker = output_broker();
    let now = Instant::now();
    let output = OutputId(1);
    let view = RenderViewId::for_output(output).unwrap().get();
    assert_eq!(
        broker.authorize(output_request(output, now), now),
        Some(view)
    );

    assert_eq!(
        broker.expire_authorizations(now + Duration::from_millis(19)),
        0
    );
    assert_eq!(
        broker.expire_authorizations(now + Duration::from_millis(20)),
        1
    );
    assert!(broker.target_available(output));
}

#[test]
fn output_broker_rejects_cross_output_aliases_and_mixed_generations() {
    let first = [1, 2, 3, 4];
    let aliased = [4, 5, 6, 7];
    let descriptor = |output, generation, framebuffers| OutputPoolDescriptor {
        output_id: OutputId(output),
        render_view_id: RenderViewId::for_output(OutputId(output)).unwrap(),
        configuration_generation: generation,
        size: PixelSize::new(64, 48),
        initial_scanout: 0,
        framebuffers,
    };
    assert!(OutputBufferBroker::new([]).is_err());
    assert!(
        OutputBufferBroker::new([descriptor(1, 1, &first), descriptor(2, 1, &aliased),]).is_err()
    );
    let second = [5, 6, 7, 8];
    assert!(
        OutputBufferBroker::new([descriptor(1, 1, &first), descriptor(2, 2, &second),]).is_err()
    );
}

#[test]
fn raster_transaction_publishes_each_rendered_output() {
    let mut broker = output_broker();
    broker.begin_transaction();
    let first_view = RenderViewId::for_output(OutputId(1)).unwrap().get();
    let second_view = RenderViewId::for_output(OutputId(2)).unwrap().get();
    let first = acquire_output(&mut broker, OutputId(1), PixelSize::new(1920, 1080));
    let second = acquire_output(&mut broker, OutputId(2), PixelSize::new(2560, 1440));
    assert_eq!((first, second), (12, 22));
    assert!(broker.mark_ready(
        first_view,
        first,
        &[rect(1.0, 1.0, 5.0, 5.0)],
        &[rect(0.0, 0.0, 1920.0, 1080.0)],
        None,
        None
    ));
    assert!(broker.mark_ready(second_view, second, &[], &[], None, None));

    let outputs = broker.finish_transaction();
    assert_eq!(outputs.len(), 2);
    assert!(
        outputs
            .iter()
            .find(|output| output.output_id == OutputId(1))
            .unwrap()
            .damage
            .is_full()
    );
    assert!(
        outputs
            .iter()
            .find(|output| output.output_id == OutputId(2))
            .unwrap()
            .damage
            .is_empty()
    );
    assert!(outputs.iter().all(|output| {
        output.request.tick.output == output.output_id
            && output.request.tick.presentation_target
                == output.request.tick.render_deadline + output.request.tick.interval
    }));
    assert_eq!(
        outputs
            .iter()
            .map(|output| output.output_id)
            .collect::<HashSet<_>>(),
        HashSet::from([OutputId(1), OutputId(2)])
    );
}

#[test]
fn partial_output_transaction_is_handed_off_independently() {
    let mut broker = output_broker();
    broker.begin_transaction();
    let first_view = RenderViewId::for_output(OutputId(1)).unwrap().get();
    let first = acquire_output(&mut broker, OutputId(1), PixelSize::new(1920, 1080));
    acquire_output(&mut broker, OutputId(2), PixelSize::new(2560, 1440));
    assert!(broker.mark_ready(first_view, first, &[], &[], None, None));

    let outputs = broker.finish_transaction();
    assert_eq!(outputs.len(), 1);
    assert_eq!(outputs[0].output_id, OutputId(1));
    assert_eq!(
        pool(&broker, OutputId(1))
            .slots
            .iter()
            .filter(|slot| slot.state == BufferState::Pending)
            .count(),
        1
    );
    assert_eq!(
        pool(&broker, OutputId(2))
            .slots
            .iter()
            .filter(|slot| slot.state == BufferState::Rendering)
            .count(),
        1
    );
}

#[test]
fn every_pool_entry_starts_with_full_repair_damage() {
    let broker = output_broker();
    for output in [OutputId(1), OutputId(2)] {
        let pool = pool(&broker, output);
        assert!(pool.slots.iter().all(|slot| slot.damage.is_full()));
        assert!(pool.slots.iter().all(|slot| slot.ready_damage.is_none()));
    }
}

#[test]
fn frame_damage_advances_other_slots_without_spreading_selected_repair() {
    let mut broker = output_broker();
    let output = OutputId(1);
    let view = RenderViewId::for_output(output).unwrap().get();
    let size = PixelSize::new(1920, 1080);
    for slot in &mut pool_mut(&mut broker, output).slots {
        slot.damage.clear();
    }
    pool_mut(&mut broker, output).slots[1]
        .damage
        .replace_from_flutter(&[rect(10.0, 10.0, 20.0, 20.0)]);

    broker.begin_transaction();
    let framebuffer = acquire_output(&mut broker, output, size);
    assert_eq!(framebuffer, 12);
    assert!(broker.mark_ready(
        view,
        framebuffer,
        &[rect(30.0, 30.0, 40.0, 40.0)],
        &[rect(10.0, 10.0, 20.0, 20.0), rect(30.0, 30.0, 40.0, 40.0),],
        None,
        None,
    ));

    let ready = broker.finish_transaction().pop().unwrap();
    assert!(ready.damage.intersects_pixel_rect(10, 10, 1, 1));
    assert!(ready.damage.intersects_pixel_rect(30, 30, 1, 1));
    let pool = pool(&broker, output);
    assert!(pool.slots[ready.index].damage.is_empty());
    for (index, slot) in pool.slots.iter().enumerate() {
        if index != ready.index {
            assert!(slot.damage.intersects_pixel_rect(30, 30, 1, 1));
            assert!(!slot.damage.intersects_pixel_rect(10, 10, 1, 1));
        }
    }
}

#[test]
fn empty_damage_preserves_the_selected_buffer_and_other_histories() {
    let mut broker = output_broker();
    let output = OutputId(1);
    let view = RenderViewId::for_output(output).unwrap().get();
    let size = PixelSize::new(1920, 1080);
    for slot in &mut pool_mut(&mut broker, output).slots {
        slot.damage.clear();
    }

    broker.begin_transaction();
    let framebuffer = acquire_output(&mut broker, output, size);
    assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
    let ready = broker.finish_transaction().pop().unwrap();
    assert!(ready.damage.is_empty());
    assert!(
        pool(&broker, output)
            .slots
            .iter()
            .all(|slot| slot.damage.is_empty())
    );
}

#[test]
fn abandoned_raster_invalidates_instead_of_marking_the_slot_current() {
    let mut broker = output_broker();
    let output = OutputId(1);
    let size = PixelSize::new(1920, 1080);
    for slot in &mut pool_mut(&mut broker, output).slots {
        slot.damage.clear();
    }

    broker.begin_transaction();
    let framebuffer = acquire_output(&mut broker, output, size);
    broker.begin_transaction();

    let slot = pool(&broker, output)
        .slots
        .iter()
        .find(|slot| slot.framebuffer == framebuffer)
        .unwrap();
    assert_eq!(slot.state, BufferState::Free);
    assert!(slot.damage.is_full());
    assert!(slot.ready_damage.is_none());
}

#[test]
fn output_leases_retire_independently_without_cross_output_refcounts() {
    let mut broker = output_broker();
    broker.begin_transaction();
    for (output, size) in [
        (OutputId(1), PixelSize::new(1920, 1080)),
        (OutputId(2), PixelSize::new(2560, 1440)),
    ] {
        let view = RenderViewId::for_output(output).unwrap().get();
        let framebuffer = acquire_output(&mut broker, output, size);
        assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
    }
    let outputs = broker.finish_transaction();
    for output in &outputs {
        broker.publish(output).unwrap();
    }

    let first = outputs
        .iter()
        .find(|output| output.output_id == OutputId(1))
        .unwrap();
    let second = outputs
        .iter()
        .find(|output| output.output_id == OutputId(2))
        .unwrap();
    broker.release_output(first.output_id, 0).unwrap();
    broker.release_output(first.output_id, first.index).unwrap();
    assert_eq!(pool(&broker, OutputId(1)).slots[first.index].output_refs, 0);
    assert_eq!(
        pool(&broker, OutputId(2)).slots[second.index].output_refs,
        1
    );
    assert!(broker.release_output(first.output_id, first.index).is_err());
}

#[test]
fn output_publication_validates_only_its_own_slot() {
    let mut broker = output_broker();
    broker.begin_transaction();
    for (output, size) in [
        (OutputId(1), PixelSize::new(1920, 1080)),
        (OutputId(2), PixelSize::new(2560, 1440)),
    ] {
        let view = RenderViewId::for_output(output).unwrap().get();
        let framebuffer = acquire_output(&mut broker, output, size);
        assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
    }
    let mut outputs = broker.finish_transaction();
    let valid_second_index = outputs[1].index;
    outputs[1].index = usize::MAX;

    broker.publish(&outputs[0]).unwrap();
    assert!(broker.publish(&outputs[1]).is_err());
    let first = &pool(&broker, outputs[0].output_id).slots[outputs[0].index];
    assert_eq!(first.state, BufferState::Free);
    assert_eq!(first.output_refs, 1);
    let second = &pool(&broker, outputs[1].output_id).slots[valid_second_index];
    assert_eq!(second.state, BufferState::Pending);
    assert_eq!(second.output_refs, 0);

    outputs[1].index = valid_second_index;
    broker.publish(&outputs[1]).unwrap();
    for output in &outputs {
        let slot = &pool(&broker, output.output_id).slots[output.index];
        assert_eq!(slot.state, BufferState::Free);
        assert_eq!(slot.output_refs, 1);
    }
}

#[test]
fn three_output_buffers_hold_scanning_submitted_and_ready_generations() {
    let mut broker = output_broker();
    let output = OutputId(1);
    let view = RenderViewId::for_output(output).unwrap().get();
    let size = PixelSize::new(1920, 1080);

    for expected_framebuffer in [12, 13] {
        broker.begin_transaction();
        let framebuffer = acquire_output(&mut broker, output, size);
        assert_eq!(framebuffer, expected_framebuffer);
        assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
        let frames = broker.finish_transaction();
        assert_eq!(frames.len(), 1);
        broker.publish(&frames[0]).unwrap();
    }

    let pool = pool(&broker, output);
    assert_eq!(pool.slots.len(), 3);
    assert_eq!(
        pool.slots
            .iter()
            .map(|slot| slot.output_refs)
            .sum::<usize>(),
        3
    );
    assert!(!broker.target_available(output));
}

#[test]
fn screenshot_tag_applies_only_to_its_target_output() {
    let mut broker = output_broker();
    broker
        .tag_next_frame_for_screenshot(OutputId(1), 41)
        .unwrap();
    broker.begin_transaction();
    for (output, size) in [
        (OutputId(1), PixelSize::new(1920, 1080)),
        (OutputId(2), PixelSize::new(2560, 1440)),
    ] {
        let view = RenderViewId::for_output(output).unwrap().get();
        let framebuffer = acquire_output(&mut broker, output, size);
        assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
    }
    assert!(!broker.target_available(OutputId(1)));
    assert!(!broker.target_available(OutputId(2)));
    let outputs = broker.finish_transaction();
    assert_eq!(
        outputs
            .iter()
            .find(|output| output.output_id == OutputId(1))
            .unwrap()
            .screenshot_request_id,
        Some(41)
    );
    assert_eq!(
        outputs
            .iter()
            .find(|output| output.output_id == OutputId(2))
            .unwrap()
            .screenshot_request_id,
        None
    );
    assert!(broker.next_screenshot.is_none());
}
