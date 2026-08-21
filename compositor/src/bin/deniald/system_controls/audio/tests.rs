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
    assert_eq!(offset_of!(PaSinkInputInfoPrefix, volume), 172);
    assert_eq!(offset_of!(PaSinkInputInfoPrefix, mute), 336);
    assert_eq!(offset_of!(PaSinkInputInfoPrefix, proplist), 344);
}

#[test]
fn audio_stream_names_truncate_only_at_utf8_boundaries() {
    assert_eq!(truncate_utf8("Denial".into(), 16), "Denial");
    assert_eq!(truncate_utf8("Denia 🌊".into(), 9), "Denia ");
}
