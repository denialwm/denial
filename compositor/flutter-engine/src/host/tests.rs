use std::ffi::CString;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

struct DropProbe(&'static AtomicUsize);

impl Drop for DropProbe {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn successful_shutdown_releases_the_lifetime_graph() {
    static DROPS: AtomicUsize = AtomicUsize::new(0);
    DROPS.store(0, Ordering::SeqCst);

    assert_eq!(release_or_leak(DropProbe(&DROPS), Ok::<(), ()>(())), Ok(()));
    assert_eq!(DROPS.load(Ordering::SeqCst), 1);
}

#[test]
fn failed_shutdown_leaks_the_lifetime_graph() {
    static DROPS: AtomicUsize = AtomicUsize::new(0);
    DROPS.store(0, Ordering::SeqCst);

    assert_eq!(release_or_leak(DropProbe(&DROPS), Err::<(), _>(7)), Err(7));
    assert_eq!(DROPS.load(Ordering::SeqCst), 0);
}

#[test]
fn damage_slice_rejects_incoherent_and_pathological_lengths() {
    let mut rect = sys::FlutterRect {
        left: 0.0,
        top: 0.0,
        right: 1.0,
        bottom: 1.0,
    };
    let valid = sys::FlutterDamage {
        struct_size: mem::size_of::<sys::FlutterDamage>(),
        num_rects: 1,
        damage: &mut rect,
    };
    // SAFETY: `damage` points to the aligned local `rect`, which remains
    // readable for the declared single-element slice throughout the call.
    assert_eq!(unsafe { damage_slice(&valid) }.map(<[_]>::len), Some(1));

    let null_nonempty = sys::FlutterDamage {
        num_rects: 1,
        damage: ptr::null_mut(),
        ..valid
    };
    // SAFETY: the null/non-empty pair is deliberately invalid, but
    // damage_slice rejects it before constructing or reading a slice.
    assert!(unsafe { damage_slice(&null_nonempty) }.is_none());

    let oversized = sys::FlutterDamage {
        num_rects: MAX_FLUTTER_DAMAGE_RECTS + 1,
        damage: NonNull::<sys::FlutterRect>::dangling().as_ptr(),
        ..valid
    };
    // SAFETY: the oversized length is rejected before the aligned
    // dangling sentinel can be dereferenced.
    assert!(unsafe { damage_slice(&oversized) }.is_none());

    let short_struct = sys::FlutterDamage {
        struct_size: mem::size_of::<usize>(),
        num_rects: 0,
        damage: ptr::null_mut(),
    };
    // SAFETY: `short_struct` is a live Rust value; its advertised short
    // ABI size makes damage_slice return before inspecting the pointer.
    assert!(unsafe { damage_slice(&short_struct) }.is_none());
}

#[test]
fn inbound_strings_and_payloads_are_bounded_before_copying() {
    let channel = CString::new("denial/native").expect("static test channel has no NUL");
    assert_eq!(
        // SAFETY: channel owns a live NUL-terminated allocation for the
        // duration of the bounded scan.
        unsafe { bounded_c_str(channel.as_ptr(), MAX_PLATFORM_CHANNEL_BYTES) },
        Some(channel.as_c_str())
    );

    let oversized_channel = CString::new(vec![b'x'; MAX_PLATFORM_CHANNEL_BYTES + 1])
        .expect("test channel has no interior NUL");
    assert!(
        // SAFETY: the CString allocation contains more than every byte
        // examined up to the cap, including a later trailing NUL.
        unsafe { bounded_c_str(oversized_channel.as_ptr(), MAX_PLATFORM_CHANNEL_BYTES) }.is_none()
    );

    let bytes = [1_u8, 2, 3];
    assert_eq!(
        // SAFETY: bytes.as_ptr() is readable for bytes.len() bytes and the
        // array outlives the copy.
        unsafe { copy_platform_payload(bytes.as_ptr(), bytes.len()) },
        Some(bytes.to_vec())
    );
    // SAFETY: the invalid null/non-empty pair is rejected by length
    // validation before any source read.
    assert!(unsafe { copy_platform_payload(ptr::null(), 1) }.is_none());
    assert!(
        // SAFETY: the excessive length is rejected before the dangling
        // sentinel pointer can be dereferenced.
        unsafe {
            copy_platform_payload(
                NonNull::<u8>::dangling().as_ptr(),
                MAX_PLATFORM_MESSAGE_BYTES + 1,
            )
        }
        .is_none()
    );
}
