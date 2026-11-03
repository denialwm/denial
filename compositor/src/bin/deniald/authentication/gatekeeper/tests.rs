use super::*;
use std::io::Cursor;
struct Duplex {
    response: Cursor<Vec<u8>>,
    request: Vec<u8>,
}
impl Read for Duplex {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        self.response.read(b)
    }
}
impl Write for Duplex {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        self.request.extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn response(status: i32, service: i32, retry: u32, sid: u64, data: &[u8]) -> Duplex {
    let mut h = vec![0u8; 40];
    h[..8].copy_from_slice(b"NXGR1\0\0\0");
    h[8..12].copy_from_slice(&status.to_le_bytes());
    h[12..16].copy_from_slice(&service.to_le_bytes());
    h[16..20].copy_from_slice(&retry.to_le_bytes());
    h[20..24].copy_from_slice(&UID.to_le_bytes());
    h[24..32].copy_from_slice(&sid.to_le_bytes());
    h[32..36].copy_from_slice(&(data.len() as u32).to_le_bytes());
    h.extend_from_slice(data);
    Duplex {
        response: Cursor::new(h),
        request: vec![],
    }
}
#[test]
fn enrollment_transports_secret_bytes_only_in_private_body() {
    let mut d = response(0, 0, 0, 123, &[1, 2, 3]);
    let (sid, handle) = exchange(&mut d, 1, None, 0, &[], b"123456").unwrap();
    assert_eq!((sid, handle), (123, vec![1, 2, 3]));
    assert_eq!(&d.request[..8], b"NXGK1\0\0\0");
    assert_eq!(u32_at(&d.request, 8), 1);
    assert_eq!(u32_at(&d.request, 32), 0);
    assert_eq!(u32_at(&d.request, 36), 0);
    assert_eq!(u32_at(&d.request, 40), 6);
    assert_eq!(&d.request[48..], b"123456");
}
#[test]
fn token_is_bound_to_fresh_challenge_and_credential() {
    let c = Credential {
        uid: UID,
        sid: 123,
        handle: vec![1, 2, 3],
    };
    let challenge = u64::MAX;
    let mut hat = vec![0u8; 69];
    hat[1..9].copy_from_slice(&challenge.to_le_bytes());
    hat[9..17].copy_from_slice(&c.sid.to_le_bytes());
    hat[28] = 1;
    hat[37..].fill(0xaa);
    let mut d = response(0, 0, 0, 123, &hat);
    assert_eq!(
        exchange(&mut d, 3, Some(&c), challenge, b"123456", &[])
            .unwrap()
            .1,
        hat
    );
    assert_eq!(u64_at(&d.request, 16), challenge);
    assert_eq!(u64_at(&d.request, 24), 123);
    for at in [0, 1, 9, 28] {
        let mut bad = hat.clone();
        bad[at] ^= 1;
        assert!(matches!(
            exchange(
                &mut response(0, 0, 0, 123, &bad),
                3,
                Some(&c),
                challenge,
                b"123456",
                &[]
            ),
            Err(Failure::Protocol)
        ));
    }
    let complete = response(0, 0, 0, 123, &hat).response.into_inner();
    for n in 0..complete.len() {
        let mut d = Duplex {
            response: Cursor::new(complete[..n].to_vec()),
            request: vec![],
        };
        assert!(exchange(&mut d, 3, Some(&c), challenge, b"123456", &[]).is_err());
    }
}
#[test]
fn rejection_and_throttling_never_return_a_token_or_retry() {
    let c = Credential {
        uid: UID,
        sid: 123,
        handle: vec![1],
    };
    let mut d = response(-libc::EAGAIN, -2, 10000, 0, &[]);
    assert!(matches!(
        exchange(&mut d, 3, Some(&c), 7, b"123456", &[]),
        Err(Failure::Throttled(10000))
    ));
    assert_eq!(d.request.len(), 55);
    assert!(matches!(
        exchange(
            &mut response(-libc::EACCES, -1, 0, 0, &[]),
            3,
            Some(&c),
            7,
            b"123456",
            &[]
        ),
        Err(Failure::Rejected)
    ));
    assert!(matches!(
        exchange(
            &mut response(0, 0, 0, 124, &[1]),
            2,
            Some(&c),
            0,
            b"123456",
            b"654321"
        ),
        Err(Failure::Protocol)
    ));
}
#[test]
fn native_credential_record_is_preserved_without_hash_fallback() {
    let store = super::super::tests::temporary_pin_store("gatekeeper-record");
    fs::create_dir_all(store.path().parent().unwrap()).unwrap();
    let c = Credential {
        uid: UID,
        sid: 123,
        handle: vec![1, 2, 3],
    };
    let value = json!({"version":2,"length":6,"gatekeeper":c.encode()});
    fs::write(store.path(), value.to_string()).unwrap();
    let loaded = store.enrollment_credential().unwrap();
    assert_eq!(loaded.sid, 123);
    assert_eq!(loaded.handle, [1, 2, 3]);
    store.clear().unwrap();
    assert!(store.load().unwrap().is_none());
    assert!(store.enrollment_credential().is_err());
    let retained: Value = serde_json::from_str(&fs::read_to_string(store.path()).unwrap()).unwrap();
    assert_eq!(retained["gatekeeper"]["handle"], json!([1, 2, 3]));
    assert_eq!(retained["enabled"], false);
    assert!(Credential::decode(&json!({"uid":0,"secure_user_id":123,"handle":[1]})).is_err());
    assert!(Credential::decode(&json!({"uid":UID,"secure_user_id":0,"handle":[1]})).is_err());
    let (a, _b) = UnixStream::pair().unwrap();
    if unsafe { libc::geteuid() } != 0 {
        assert!(root_peer(&a).is_err());
    }
    fs::remove_dir_all(store.path().parent().unwrap().parent().unwrap()).unwrap();
}

#[test]
fn broker_request_preserves_full_challenge_and_rejects_other_namespaces() {
    let mut request = [0u8; 24];
    request[..8].copy_from_slice(b"NXEA1\0\0\0");
    request[8..16].copy_from_slice(&u64::MAX.to_le_bytes());
    request[16..20].copy_from_slice(&UID.to_le_bytes());
    assert_eq!(authorization_challenge(&request).unwrap(), u64::MAX);
    for offset in [0, 7, 16, 20] {
        let mut bad = request;
        bad[offset] ^= 1;
        assert!(authorization_challenge(&bad).is_err());
    }
    request[8..16].fill(0);
    assert!(authorization_challenge(&request).is_err());
}
