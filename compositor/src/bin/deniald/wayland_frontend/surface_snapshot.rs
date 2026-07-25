use std::error::Error;
use std::sync::Arc;

use smithay::reexports::wayland_server::protocol::{wl_buffer, wl_shm};
use smithay::wayland::shm::{BufferAccessError, BufferData, with_buffer_contents};

use super::super::flutter_runtime::{ShmSnapshotPool, ShmTextureFrame};

const SHM_BYTES_PER_PIXEL: usize = 4;
const MAX_SHM_TEXTURE_DIMENSION: usize = 16_384;
const MAX_SHM_SNAPSHOT_BYTES: usize = 256 * 1024 * 1024;
const MIN_SHM_CACHE_BUDGET_BYTES: usize = 256 * 1024 * 1024;
const MAX_SHM_CACHE_BUDGET_BYTES: usize = 512 * 1024 * 1024;
const SHM_CACHE_ATLAS_MULTIPLIER: usize = 4;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ShmLayout {
    width: usize,
    height: usize,
    offset: usize,
    stride: usize,
    row_bytes: usize,
    payload_len: usize,
}

pub(super) fn rgba_payload_len(width: u32, height: u32) -> Option<usize> {
    usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?
        .checked_mul(SHM_BYTES_PER_PIXEL)
}

/// Keep enough CPU-backed SHM for at least two 8K frames, then scale with the
/// Flutter atlas. The upper bound avoids allowing a large or malicious output
/// layout to turn the snapshot cache into an unbounded memory reservation.
pub(super) fn shm_cache_budget_for_atlas(width: u32, height: u32) -> usize {
    rgba_payload_len(width, height)
        .unwrap_or(MAX_SHM_CACHE_BUDGET_BYTES)
        .saturating_mul(SHM_CACHE_ATLAS_MULTIPLIER)
        .clamp(MIN_SHM_CACHE_BUDGET_BYTES, MAX_SHM_CACHE_BUDGET_BYTES)
}

fn validate_shm_layout(
    width: i32,
    height: i32,
    offset: i32,
    stride: i32,
    pool_len: usize,
    available_cache_bytes: usize,
) -> Result<ShmLayout, &'static str> {
    let width = usize::try_from(width).map_err(|_| "SHM buffer has a negative width")?;
    let height = usize::try_from(height).map_err(|_| "SHM buffer has a negative height")?;
    if width == 0 || height == 0 {
        return Err("SHM buffer has an empty extent");
    }
    if width > MAX_SHM_TEXTURE_DIMENSION || height > MAX_SHM_TEXTURE_DIMENSION {
        return Err("SHM buffer exceeds the maximum texture dimension");
    }
    let offset = usize::try_from(offset).map_err(|_| "SHM buffer has a negative pool offset")?;
    let stride = usize::try_from(stride).map_err(|_| "SHM buffer has a negative stride")?;
    let row_bytes = width
        .checked_mul(SHM_BYTES_PER_PIXEL)
        .ok_or("SHM row byte count overflows usize")?;
    if stride < row_bytes {
        return Err("SHM buffer stride is smaller than one pixel row");
    }
    let last_row = (height - 1)
        .checked_mul(stride)
        .ok_or("SHM buffer row offset overflows usize")?;
    let required = offset
        .checked_add(last_row)
        .and_then(|end| end.checked_add(row_bytes))
        .ok_or("SHM buffer range overflows usize")?;
    if required > pool_len {
        return Err("SHM buffer range exceeds its pool");
    }
    let payload_len = row_bytes
        .checked_mul(height)
        .ok_or("SHM texture payload overflows usize")?;
    let allocation_limit = available_cache_bytes.min(MAX_SHM_SNAPSHOT_BYTES);
    if payload_len > allocation_limit {
        return Err("SHM texture payload exceeds the snapshot memory budget");
    }
    Ok(ShmLayout {
        width,
        height,
        offset,
        stride,
        row_bytes,
        payload_len,
    })
}

pub(super) fn snapshot_shm_buffer(
    buffer: &wl_buffer::WlBuffer,
    revision: u64,
    available_cache_bytes: usize,
    snapshot_pool: &Arc<ShmSnapshotPool>,
) -> Result<Option<ShmTextureFrame>, Box<dyn Error>> {
    let snapshot = with_buffer_contents(
        buffer,
        |source, pool_len, data: BufferData| -> Result<ShmTextureFrame, Box<dyn Error>> {
            let force_opaque = match data.format {
                wl_shm::Format::Argb8888 => false,
                wl_shm::Format::Xrgb8888 => true,
                format => {
                    return Err(format!("unsupported advertised SHM format {format:?}").into());
                }
            };
            let layout = validate_shm_layout(
                data.width,
                data.height,
                data.offset,
                data.stride,
                pool_len,
                available_cache_bytes,
            )?;
            let mut rgba = snapshot_pool.acquire(layout.payload_len);
            rgba.try_reserve_exact(layout.payload_len)
                .map_err(|error| format!("could not reserve SHM snapshot memory: {error}"))?;
            rgba.resize(layout.payload_len, 0);
            for row in 0..layout.height {
                let source_offset = layout.offset + row * layout.stride;
                let destination_offset = row * layout.row_bytes;
                // SAFETY: `with_buffer_contents` guarantees that `source` is
                // live for this closure. The checked range above covers the
                // complete source row and `rgba` owns the destination range.
                // Copying raw bytes avoids creating a Rust reference to SHM
                // that is writable from another process.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        source.add(source_offset),
                        rgba.as_mut_ptr().add(destination_offset),
                        layout.row_bytes,
                    );
                }
            }
            normalize_shm_8888(&mut rgba, force_opaque);
            ShmTextureFrame::new_pooled(
                u32::try_from(layout.width)?,
                u32::try_from(layout.height)?,
                revision,
                rgba,
                snapshot_pool,
            )
            .map_err(Into::into)
        },
    );
    match snapshot {
        Ok(snapshot) => snapshot.map(Some),
        Err(BufferAccessError::NotManaged) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn normalize_shm_8888(pixels: &mut [u8], force_opaque: bool) {
    for pixel in pixels.chunks_exact_mut(4) {
        let value = u32::from_ne_bytes([pixel[0], pixel[1], pixel[2], pixel[3]]);
        pixel[0] = ((value >> 16) & 0xff) as u8;
        pixel[1] = ((value >> 8) & 0xff) as u8;
        pixel[2] = (value & 0xff) as u8;
        pixel[3] = if force_opaque {
            0xff
        } else {
            ((value >> 24) & 0xff) as u8
        };
    }
}

#[cfg(test)]
mod tests {
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
            validate_shm_layout(width, height, 0, stride, pool_len, MAX_SHM_SNAPSHOT_BYTES)
                .unwrap();
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
}
