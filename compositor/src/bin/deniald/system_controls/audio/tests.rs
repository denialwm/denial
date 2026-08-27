use super::*;
use std::mem::{offset_of, size_of};

#[test]
fn pulse_ffi_prefixes_match_the_installed_stable_abi() {
    assert_eq!(size_of::<PaSampleSpec>(), 12);
    assert_eq!(size_of::<PaChannelMap>(), 132);
    assert_eq!(size_of::<PaCVolume>(), 132);
    assert_eq!(offset_of!(PaServerInfo, default_sink_name), 48);
    assert_eq!(offset_of!(PaSinkInfoPrefix, volume), 172);
    assert_eq!(offset_of!(PaSinkInfoPrefix, mute), 304);
    assert_eq!(offset_of!(PaSinkInfoPrefix, active_port), 392);
    assert_eq!(size_of::<PaSinkInfoPrefix>(), 400);
    assert_eq!(offset_of!(PaSinkPortInfo, description), 8);
    assert_eq!(offset_of!(PaSinkPortInfo, available), 20);
    assert_eq!(size_of::<PaSinkPortInfo>(), 24);
    assert_eq!(offset_of!(PaSinkInputInfoPrefix, volume), 172);
    assert_eq!(offset_of!(PaSinkInputInfoPrefix, mute), 336);
    assert_eq!(offset_of!(PaSinkInputInfoPrefix, proplist), 344);
}

#[test]
fn active_port_supplies_the_label_and_explicit_unavailability() {
    let raw_sink_description = CString::new("acp3xalc5682m98357 Headphones").unwrap();
    let port_description = CString::new("Headphones").unwrap();
    let mut port = PaSinkPortInfo {
        name: ptr::null(),
        description: port_description.as_ptr(),
        priority: 300,
        available: PA_PORT_AVAILABLE_NO,
    };
    // SAFETY: this FFI prefix contains only integer fields, C structs made of
    // integers, and pointers. Zero is a valid inactive value for each field.
    let mut info = unsafe { std::mem::zeroed::<PaSinkInfoPrefix>() };
    info.description = raw_sink_description.as_ptr();
    info.active_port = &mut port;

    assert_eq!(
        sink_description(&info, raw_sink_description.as_c_str()),
        "Headphones"
    );
    assert!(!sink_is_available(&info));

    let mut available_port = PaSinkPortInfo {
        name: ptr::null(),
        description: port_description.as_ptr(),
        priority: 300,
        available: 0,
    };
    info.active_port = &mut available_port;
    assert!(sink_is_available(&info));
}

#[test]
fn audio_stream_names_truncate_only_at_utf8_boundaries() {
    assert_eq!(truncate_utf8("Denial".into(), 16), "Denial");
    assert_eq!(truncate_utf8("Denia 🌊".into(), 9), "Denia ");
}
