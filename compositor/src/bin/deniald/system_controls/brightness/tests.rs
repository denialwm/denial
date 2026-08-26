use super::super::{BrightnessCommand, CONTROL_STEP, SystemControlEvent};
use super::*;
use std::collections::HashMap;
use std::mem::{offset_of, size_of};
use std::ptr;
use std::sync::mpsc;

struct FakeBrightnessProvider {
    provider_name: &'static str,
    connector: &'static str,
    level: f64,
}

impl BrightnessProvider for FakeBrightnessProvider {
    fn name(&self) -> &'static str {
        self.provider_name
    }

    fn controls(&mut self, connector: &str) -> bool {
        connector == self.connector
    }

    fn read(&mut self, connector: &str) -> Result<f64, String> {
        self.controls(connector)
            .then_some(self.level)
            .ok_or_else(|| "unclaimed output".into())
    }

    fn set(&mut self, connector: &str, level: f64) -> Result<(), String> {
        if !self.controls(connector) {
            return Err("unclaimed output".into());
        }
        self.level = level;
        Ok(())
    }
}

#[test]
fn ddc_ffi_prefixes_match_the_installed_stable_abi() {
    assert_eq!(offset_of!(DdcDisplayInfo, dref), 192);
    assert_eq!(size_of::<DdcDisplayInfo>(), 200);
    assert_eq!(offset_of!(DdcDisplayInfo2, drm_card_connector), 200);
    assert_eq!(size_of::<DdcDisplayInfo2>(), 304);
    assert_eq!(size_of::<DdcNonTableValue>(), 4);
}

#[test]
fn stable_ddc_metadata_prefers_i2c_identity_and_rejects_ambiguous_edids() {
    let edid = [7; 128];
    let connectors = [
        DrmConnectorIdentity {
            name: "DP-1".into(),
            i2c_bus: Some(8),
            edid: Some(edid),
        },
        DrmConnectorIdentity {
            name: "DP-2".into(),
            i2c_bus: Some(9),
            edid: Some(edid),
        },
    ];
    let display = DdcDisplayInfo {
        marker: [0; 4],
        dispno: 1,
        path: DdcIoPath {
            io_mode: 0,
            path: 9,
        },
        usb_bus: 0,
        usb_device: 0,
        mfg_id: [0; 4],
        model_name: [0; 14],
        serial: [0; 14],
        product_code: 0,
        edid_bytes: edid,
        vcp_version: [0; 2],
        dref: ptr::null_mut(),
    };
    assert_eq!(
        connector_for_stable_display(&display, &connectors).as_deref(),
        Some("DP-2")
    );

    let usb_display = DdcDisplayInfo {
        path: DdcIoPath {
            io_mode: 1,
            path: 0,
        },
        ..display
    };
    assert_eq!(
        connector_for_stable_display(&usb_display, &connectors),
        None
    );
    assert_eq!(
        connector_for_stable_display(&usb_display, &connectors[..1]).as_deref(),
        Some("DP-1")
    );
}

#[test]
fn brightness_providers_coexist_and_claim_outputs_independently() {
    let mut controls = BrightnessProviders {
        providers: vec![
            Box::new(FakeBrightnessProvider {
                provider_name: "kernel backlight",
                connector: "eDP-1",
                level: 0.5,
            }),
            Box::new(FakeBrightnessProvider {
                provider_name: "DDC/CI",
                connector: "DP-1",
                level: 0.8,
            }),
        ],
        desired: HashMap::new(),
        failure_latched: HashMap::new(),
    };
    let (sender, receiver) = mpsc::sync_channel(8);
    let sender = SystemControlEventSender::new(sender, Arc::new(AtomicBool::new(false)));

    controls.set("eDP-1", 1, 0.35, &sender);
    assert_eq!(
        receiver.recv().unwrap(),
        SystemControlEvent::BrightnessLevel {
            monitor_id: 1,
            level: 0.35,
        }
    );
    controls.read("eDP-1", 1, &sender);
    assert_eq!(
        receiver.recv().unwrap(),
        SystemControlEvent::BrightnessLevel {
            monitor_id: 1,
            level: 0.35,
        }
    );

    controls.set("DP-1", 2, 0.65, &sender);
    assert_eq!(
        receiver.recv().unwrap(),
        SystemControlEvent::BrightnessLevel {
            monitor_id: 2,
            level: 0.65,
        }
    );
    controls.read("DP-1", 2, &sender);
    assert_eq!(
        receiver.recv().unwrap(),
        SystemControlEvent::BrightnessLevel {
            monitor_id: 2,
            level: 0.65,
        }
    );
}

#[test]
fn kernel_backlights_are_limited_to_internal_connectors() {
    assert!(internal_connector("eDP-1"));
    assert!(internal_connector("LVDS-1"));
    assert!(internal_connector("DSI-1"));
    assert!(!internal_connector("DP-1"));
    assert!(!internal_connector("HDMI-A-1"));
    assert!(connected_internal_connector("eDP-1", "connected\n"));
    assert!(!connected_internal_connector("eDP-2", "disconnected\n"));
    assert!(!connected_internal_connector("DP-1", "connected\n"));
}

#[test]
fn ddc_connector_names_drop_only_the_card_prefix() {
    assert_eq!(connector_from_ddc_name("card2-DP-4"), "DP-4");
    assert_eq!(connector_from_ddc_name("DP-4"), "DP-4");
    assert_eq!(connector_from_ddc_name("card2-HDMI-A-1"), "HDMI-A-1");
}

#[test]
fn brightness_batch_coalesces_detents_per_connector() {
    let (sender, receiver) = mpsc::channel();
    sender
        .send(BrightnessCommand::Adjust {
            connector: "DP-4".into(),
            monitor_id: 4,
            delta: CONTROL_STEP,
        })
        .unwrap();
    sender
        .send(BrightnessCommand::Adjust {
            connector: "DP-4".into(),
            monitor_id: 4,
            delta: CONTROL_STEP,
        })
        .unwrap();
    let first = receiver.recv().unwrap();
    let batch = receive_brightness_batch(first, &receiver).unwrap();
    assert_eq!(batch["DP-4"], (4, PendingBrightnessCommand::Adjust(0.10)));
}

#[test]
fn brightness_read_cannot_discard_a_pending_write() {
    let mut pending = HashMap::new();
    merge_brightness_command(
        &mut pending,
        "DP-4".into(),
        4,
        PendingBrightnessCommand::Set(0.61),
    );
    merge_brightness_command(
        &mut pending,
        "DP-4".into(),
        4,
        PendingBrightnessCommand::Read,
    );
    assert_eq!(pending["DP-4"], (4, PendingBrightnessCommand::Set(0.61)));
}
