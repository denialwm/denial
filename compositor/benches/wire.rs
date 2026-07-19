use std::fs;
use std::hint::black_box;
use std::path::PathBuf;
use std::time::Instant;

use flatbuffers::FlatBufferBuilder;
use serde_json::{Value, json};

#[allow(
    clippy::all,
    clippy::undocumented_unsafe_blocks,
    dead_code,
    deprecated,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    mismatched_lifetime_syntaxes,
    unsafe_op_in_unsafe_fn,
    unused_imports
)]
mod generated {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../protocol/generated/rust/denial_generated.rs"
    ));
}

use generated::denial::wire as fb;

const PROTOCOL_VERSION: u16 = 1;
const PLACEMENT_PACKET_BYTES: usize = 80;

fn measure(mut iterations: usize, mut operation: impl FnMut()) -> f64 {
    for _ in 0..200 {
        operation();
    }
    iterations = iterations.max(1);
    let mut samples = [0.0; 5];
    for sample in &mut samples {
        let start = Instant::now();
        for _ in 0..iterations {
            operation();
        }
        *sample = start.elapsed().as_secs_f64() * 1_000_000.0 / iterations as f64;
    }
    samples.sort_by(f64::total_cmp);
    samples[samples.len() / 2]
}

fn json_input_layout(count: usize) -> Value {
    let windows = (0..count)
        .map(|index| {
            json!({
                "objectId": 0x1_0000_0000_u64 + index as u64,
                "surfaceId": 0x2_0000_0000_u64 + index as u64,
                "windowId": 0x3_0000_0000_u64 + index as u64,
                "rect": [-12.5 + index as f64 * 3.25, 4.75 + index as f64, 640.5, 480.25],
                "sourceRect": [0.25, 1.5, 1280.5, 960.25],
                "z": index % 5,
                "visible": index % 7 != 0 || index == 0,
                "hitTest": index % 3 != 0 || index == 0,
                "geometryLocked": index % 2 == 0,
            })
        })
        .collect::<Vec<_>>();
    json!({
        "type": "input_layout",
        "epoch": 0x1_0000_0000_u64 + count as u64,
        "keyboardCapture": count % 2 == 1,
        "exclusiveShellMode": count == 32,
        "shellRegions": [{"rect": [-0.5, 0.25, 177.75, 72.5], "mode": "flutter"}],
        "windows": windows,
    })
}

fn json_window_response(count: usize) -> Value {
    let windows = (0..count)
        .map(|index| {
            json!({
                "objectId": 0x1_0000_0000_u64 + index as u64,
                "surfaceId": 0x2_0000_0000_u64 + index as u64,
                "windowId": 0x3_0000_0000_u64 + index as u64,
                "textureId": index + 1,
                "width": 1280,
                "height": 960,
                "surfaceX": 0.25,
                "surfaceY": 1.5,
                "surfaceWidth": 1280.5,
                "surfaceHeight": 960.25,
                "textureSourceX": 2.5,
                "textureSourceY": 3.75,
                "textureSourceWidth": 1275.5,
                "textureSourceHeight": 955.25,
                "geometryX": -12.5,
                "geometryY": 4.75,
                "geometryWidth": 640.5,
                "geometryHeight": 480.25,
                "monitorId": index % 2,
                "transform": index % 8,
                "scale120": 120,
                "title": format!("Golden café 🐒 {index}"),
                "appId": format!("dev.denial.golden.{index}"),
            })
        })
        .collect::<Vec<_>>();
    json!({"type": "windows", "requestId": 77, "windows": windows})
}

fn flat_window_response(count: usize) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::with_capacity(1024 + count * 256);
    let mut windows = Vec::with_capacity(count);
    for index in 0..count {
        let title = builder.create_string(&format!("Golden café 🐒 {index}"));
        let app_id = builder.create_string(&format!("dev.denial.golden.{index}"));
        windows.push(fb::Window::create(
            &mut builder,
            &fb::WindowArgs {
                object_id: 0x1_0000_0000_u64 + index as u64,
                object_kind: if index % 2 == 0 {
                    fb::ObjectKind::RootSurface
                } else {
                    fb::ObjectKind::Surface
                },
                surface_id: 0x2_0000_0000_u64 + index as u64,
                window_id: 0x3_0000_0000_u64 + index as u64,
                texture_id: index as u64 + 1,
                title: Some(title),
                app_id: Some(app_id),
                width: 1280,
                height: 960,
                surface_x: 0.25,
                surface_y: 1.5,
                surface_width: 1280.5,
                surface_height: 960.25,
                texture_source_x: 2.5,
                texture_source_y: 3.75,
                texture_source_width: 1275.5,
                texture_source_height: 955.25,
                geometry_x: -12.5,
                geometry_y: 4.75,
                geometry_width: 640.5,
                geometry_height: 480.25,
                monitor_id: (index % 2) as i64,
                transform: (index % 8) as u32,
                scale_120: 120,
                status_color_argb: 0xff12_3456,
                has_status_color: index == 0,
                ..Default::default()
            },
        ));
    }
    let windows = builder.create_vector(&windows);
    let snapshot = fb::WindowSnapshot::create(
        &mut builder,
        &fb::WindowSnapshotArgs {
            windows: Some(windows),
        },
    );
    let response = fb::WindowResponse::create(
        &mut builder,
        &fb::WindowResponseArgs {
            kind: fb::WindowResponseKind::Windows,
            success: true,
            windows: Some(snapshot),
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 41,
            request_id: 77,
            payload_type: fb::Payload::WindowResponse,
            payload: Some(response.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn placement_packet() -> [u8; PLACEMENT_PACKET_BYTES] {
    let mut packet = [0_u8; PLACEMENT_PACKET_BYTES];
    packet[0..4].copy_from_slice(b"DENP");
    packet[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    packet[6..8].copy_from_slice(&2_u16.to_le_bytes());
    packet[8..12].copy_from_slice(&(PLACEMENT_PACKET_BYTES as u32).to_le_bytes());
    packet[12..20].copy_from_slice(&41_u64.to_le_bytes());
    packet[20..28].copy_from_slice(&0x3_0000_0000_u64.to_le_bytes());
    packet[28..36].copy_from_slice(&4_i64.to_le_bytes());
    packet[36..44].copy_from_slice(&7_i64.to_le_bytes());
    packet[44] = 1;
    packet[45] = 1;
    packet[48..56].copy_from_slice(&(-12.5_f64).to_le_bytes());
    packet[56..64].copy_from_slice(&4.75_f64.to_le_bytes());
    packet[64..72].copy_from_slice(&640.5_f64.to_le_bytes());
    packet[72..80].copy_from_slice(&480.25_f64.to_le_bytes());
    packet
}

fn benchmark_count(count: usize) {
    let label = match count {
        1 => "one",
        8 => "eight",
        _ => "many",
    };
    let iterations = match count {
        1 => 20_000,
        8 => 6_000,
        _ => 1_500,
    };
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../protocol/golden");
    let json_input = json_input_layout(count).to_string();
    let flat_input =
        fs::read(root.join(format!("dart_input_{label}.denw"))).expect("read Dart input fixture");
    let json_windows = json_window_response(count).to_string();
    let flat_windows = flat_window_response(count);

    let json_decode_us = measure(iterations, || {
        black_box(serde_json::from_str::<Value>(&json_input).expect("parse JSON fixture"));
    });
    let flat_verify_us = measure(iterations, || {
        let envelope = fb::root_as_envelope(&flat_input).expect("verify FlatBuffer fixture");
        black_box(
            envelope
                .payload_as_input_layout()
                .expect("input layout")
                .epoch(),
        );
    });
    let json_encode_us = measure(iterations, || {
        black_box(json_window_response(count).to_string());
    });
    let flat_encode_us = measure(iterations, || {
        black_box(flat_window_response(count));
    });

    println!(
        "RUST count={count} input_json_bytes={} input_flat_bytes={} \
         input_json_decode_us={json_decode_us:.3} input_flat_verify_us={flat_verify_us:.3} \
         windows_json_bytes={} windows_flat_bytes={} \
         windows_json_encode_us={json_encode_us:.3} windows_flat_encode_us={flat_encode_us:.3}",
        json_input.len(),
        flat_input.len(),
        json_windows.len(),
        flat_windows.len(),
    );
}

fn main() {
    for count in [1, 8, 32] {
        benchmark_count(count);
    }
    let json = json!({
        "type": "window_placement",
        "windowId": 0x3_0000_0000_u64,
        "monitorId": 4,
        "workspaceId": 7,
        "phase": "update",
        "change": "resize",
        "x": -12.5,
        "y": 4.75,
        "width": 640.5,
        "height": 480.25,
    });
    let json_encode_us = measure(20_000, || {
        black_box(json.to_string());
    });
    let fixed_encode_us = measure(20_000, || {
        black_box(placement_packet());
    });
    println!(
        "RUST placement_json_bytes={} placement_fixed_bytes={} \
         placement_json_encode_us={json_encode_us:.3} placement_fixed_encode_us={fixed_encode_us:.3}",
        json.to_string().len(),
        PLACEMENT_PACKET_BYTES,
    );
}
