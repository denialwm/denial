use super::{
    MAX_SHM_CACHE_BUDGET_BYTES, MAX_SHM_SNAPSHOT_BYTES, SHM_CACHE_ATLAS_MULTIPLIER,
    normalize_shm_8888, rgba_payload_len, shm_cache_budget_for_atlas, validate_shm_layout,
};

#[test]
fn converts_argb8888_native_words_to_rgba_bytes() {
    let mut pixels = [0x80_11_22_33_u32, 0xff_aa_bb_cc]
        .into_iter()
        .flat_map(u32::to_ne_bytes)
        .collect::<Vec<_>>();
    normalize_shm_8888(&mut pixels, false);
    assert_eq!(pixels, [0x11, 0x22, 0x33, 0x80, 0xaa, 0xbb, 0xcc, 0xff]);
}

#[test]
fn forces_xrgb8888_alpha_opaque() {
    let mut pixels = 0x00_7f_40_20_u32.to_ne_bytes();
    normalize_shm_8888(&mut pixels, true);
    assert_eq!(pixels, [0x7f, 0x40, 0x20, 0xff]);
}

#[test]
fn accepts_8k_but_rejects_payloads_over_the_per_snapshot_limit() {
    let width = 7_680;
    let height = 4_320;
    let stride = width * 4;
    let pool_len = usize::try_from(stride * height).unwrap();
    let layout =
        validate_shm_layout(width, height, 0, stride, pool_len, MAX_SHM_SNAPSHOT_BYTES).unwrap();
    assert_eq!(layout.payload_len, 132_710_400);

    let error = validate_shm_layout(
        8_193,
        8_193,
        0,
        8_193 * 4,
        usize::MAX,
        MAX_SHM_SNAPSHOT_BYTES,
    )
    .unwrap_err();
    assert_eq!(
        error,
        "SHM texture payload exceeds the snapshot memory budget"
    );
}

#[test]
fn rejects_dimension_and_payload_arithmetic_overflow() {
    assert_eq!(rgba_payload_len(u32::MAX, u32::MAX), None);
    assert_eq!(
        validate_shm_layout(16_385, 1, 0, 16_385 * 4, usize::MAX, usize::MAX),
        Err("SHM buffer exceeds the maximum texture dimension")
    );
}

#[test]
fn atlas_scaled_cache_budget_is_bounded() {
    assert_eq!(shm_cache_budget_for_atlas(1, 1), 256 * 1024 * 1024);
    assert_eq!(
        shm_cache_budget_for_atlas(7_680, 4_320),
        132_710_400 * SHM_CACHE_ATLAS_MULTIPLIER
    );
    assert_eq!(
        shm_cache_budget_for_atlas(u32::MAX, u32::MAX),
        MAX_SHM_CACHE_BUDGET_BYTES
    );
}
