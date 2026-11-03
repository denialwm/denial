//! Copy native-endian Wayland ARGB/XRGB8888 into owned RGBA storage.
//!
//! Read SHM through raw pointers: another process may write it concurrently,
//! so it must never be borrowed as a Rust slice. No reads exceed one row.

/// # Safety
/// `source` must be readable and `destination` writable for `pixels * 4`
/// bytes, with no overlap. The destination may be uninitialized. Callers
/// remain responsible for the wl_shm access/SIGBUS guard and range checks.
pub(super) unsafe fn copy_shm_8888(
    mut source: *const u8,
    mut destination: *mut u8,
    pixels: usize,
    force_opaque: bool,
) -> bool {
    let mut alpha_or = 0u8;
    #[cfg(all(target_arch = "aarch64", target_endian = "little"))]
    let pixels = {
        let mut remaining = pixels;
        use std::arch::aarch64::{
            vdupq_n_u8, vgetq_lane_u8, vld1q_u8, vorrq_u8, vqtbl1q_u8, vst1q_u8,
        };
        // SAFETY: AArch64 guarantees baseline NEON for this target.
        let mut all_channels = unsafe { vdupq_n_u8(0) };
        // AArch64's baseline SIMD handles four pixels without alignment
        // requirements. XRGB's undefined alpha byte must become 0xff.
        let shuffle = [2, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15];
        let opaque = [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255];
        // SAFETY: both local arrays contain sixteen initialized bytes.
        let (shuffle, opaque) = unsafe { (vld1q_u8(shuffle.as_ptr()), vld1q_u8(opaque.as_ptr())) };
        while remaining >= 4 {
            // SAFETY: four complete pixels remain inside the caller's row.
            // Unaligned vector accesses are supported; no padding is read.
            unsafe {
                let converted = vqtbl1q_u8(vld1q_u8(source), shuffle);
                let converted = if force_opaque {
                    vorrq_u8(converted, opaque)
                } else {
                    converted
                };
                all_channels = vorrq_u8(all_channels, converted);
                vst1q_u8(destination, converted);
                source = source.add(16);
                destination = destination.add(16);
            }
            remaining -= 4;
        }
        // SAFETY: baseline NEON and compile-time lane indices within 0..16.
        alpha_or |= unsafe {
            vgetq_lane_u8::<3>(all_channels)
                | vgetq_lane_u8::<7>(all_channels)
                | vgetq_lane_u8::<11>(all_channels)
                | vgetq_lane_u8::<15>(all_channels)
        };
        remaining
    };
    for _ in 0..pixels {
        // SAFETY: one complete pixel remains. Native-endian loading matches
        // Wayland's numeric ARGB format on both little- and big-endian hosts.
        unsafe {
            let value = source.cast::<u32>().read_unaligned();
            destination.add(0).write(((value >> 16) & 0xff) as u8);
            destination.add(1).write(((value >> 8) & 0xff) as u8);
            destination.add(2).write((value & 0xff) as u8);
            let alpha = if force_opaque {
                255
            } else {
                (value >> 24) as u8
            };
            destination.add(3).write(alpha);
            alpha_or |= alpha;
            source = source.add(4);
            destination = destination.add(4);
        }
    }
    alpha_or == 0
}

#[cfg(test)]
mod tests {
    use super::copy_shm_8888;

    #[test]
    fn transparency_summary_uses_alpha_only_and_includes_every_vector_tail() {
        for pixels in 1..130 {
            let mut source = vec![0u8; pixels * 4];
            let mut destination = vec![0u8; pixels * 4];
            for rgba in source.chunks_exact_mut(4) {
                rgba[..3].copy_from_slice(&[71, 83, 29]);
            }
            assert!(unsafe {
                copy_shm_8888(source.as_ptr(), destination.as_mut_ptr(), pixels, false)
            });
            assert!(!unsafe {
                copy_shm_8888(source.as_ptr(), destination.as_mut_ptr(), pixels, true)
            });
            for index in 0..pixels {
                source[index * 4 + 3] = 1;
                assert!(!unsafe {
                    copy_shm_8888(source.as_ptr(), destination.as_mut_ptr(), pixels, false)
                });
                source[index * 4 + 3] = 0;
            }
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn exact_row_access_at_guard_pages() {
        use std::ffi::c_void;
        unsafe extern "C" {
            fn mmap(
                address: *mut c_void,
                len: usize,
                protection: i32,
                flags: i32,
                fd: i32,
                offset: isize,
            ) -> *mut c_void;
            fn mprotect(address: *mut c_void, len: usize, protection: i32) -> i32;
            fn munmap(address: *mut c_void, len: usize) -> i32;
        }
        // A multiple of all supported Linux base-page sizes on these targets.
        const REGION: usize = 65536;
        // SAFETY: two independent anonymous mappings; the second half of each
        // mapping is inaccessible. Any vector overread/overwrite faults here.
        unsafe {
            let source = mmap(std::ptr::null_mut(), REGION * 2, 3, 0x22, -1, 0).cast::<u8>();
            let destination = mmap(std::ptr::null_mut(), REGION * 2, 3, 0x22, -1, 0).cast::<u8>();
            assert_ne!(source as usize, usize::MAX);
            assert_ne!(destination as usize, usize::MAX);
            assert_eq!(mprotect(source.add(REGION).cast(), REGION, 0), 0);
            assert_eq!(mprotect(destination.add(REGION).cast(), REGION, 0), 0);
            for pixels in 0..130 {
                let source_row = source.add(REGION - pixels * 4);
                let destination_row = destination.add(REGION - pixels * 4);
                source_row.write_bytes(0xba, pixels * 4);
                for opaque in [false, true] {
                    copy_shm_8888(source_row, destination_row, pixels, opaque);
                    for index in 0..pixels * 4 {
                        assert_eq!(
                            destination_row.add(index).read(),
                            if opaque && index % 4 == 3 { 255 } else { 0xba }
                        );
                    }
                }
            }
            assert_eq!(munmap(source.cast(), REGION * 2), 0);
            assert_eq!(munmap(destination.cast(), REGION * 2), 0);
        }
    }

    #[test]
    fn all_vector_tails_alignments_and_alpha_values_match_numeric_argb() {
        for pixels in 0..130 {
            for source_alignment in 0..16 {
                for destination_alignment in 0..16 {
                    let mut source = vec![0xa5; source_alignment + pixels * 4 + 16];
                    let mut expected = Vec::new();
                    for pixel in 0..pixels {
                        let argb = (pixel as u32).wrapping_mul(0x9e3779b9) ^ 0x30579bc1;
                        source[source_alignment + pixel * 4..source_alignment + pixel * 4 + 4]
                            .copy_from_slice(&argb.to_ne_bytes());
                        expected.extend_from_slice(&[
                            (argb >> 16) as u8,
                            (argb >> 8) as u8,
                            argb as u8,
                            (argb >> 24) as u8,
                        ]);
                    }
                    for opaque in [false, true] {
                        let mut destination = vec![0x5a; destination_alignment + pixels * 4 + 16];
                        // SAFETY: both row ranges are allocated and do not overlap.
                        unsafe {
                            copy_shm_8888(
                                source.as_ptr().add(source_alignment),
                                destination.as_mut_ptr().add(destination_alignment),
                                pixels,
                                opaque,
                            );
                        }
                        for (index, actual) in destination.iter().enumerate() {
                            let expected = if index >= destination_alignment
                                && index < destination_alignment + pixels * 4
                            {
                                let offset = index - destination_alignment;
                                if opaque && offset % 4 == 3 {
                                    255
                                } else {
                                    expected[offset]
                                }
                            } else {
                                0x5a
                            };
                            assert_eq!(
                                *actual, expected,
                                "pixels={pixels} src={source_alignment} dst={destination_alignment} opaque={opaque} byte={index}"
                            );
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn padded_rows_ignore_padding_and_preserve_source() {
        let width = 13;
        let stride = width * 4 + 19;
        let height = 7;
        let source: Vec<u8> = (0..stride * height).map(|n| (n * 37) as u8).collect();
        let before = source.clone();
        let mut destination = vec![0; width * height * 4];
        for row in 0..height {
            // SAFETY: each source row and packed destination row fit exactly.
            unsafe {
                copy_shm_8888(
                    source.as_ptr().add(row * stride),
                    destination.as_mut_ptr().add(row * width * 4),
                    width,
                    false,
                );
            }
            for pixel in 0..width {
                let index = row * stride + pixel * 4;
                let value = u32::from_ne_bytes(source[index..index + 4].try_into().unwrap());
                assert_eq!(
                    &destination[(row * width + pixel) * 4..(row * width + pixel + 1) * 4],
                    &[
                        (value >> 16) as u8,
                        (value >> 8) as u8,
                        value as u8,
                        (value >> 24) as u8
                    ]
                );
            }
        }
        assert_eq!(source, before);
    }
}
