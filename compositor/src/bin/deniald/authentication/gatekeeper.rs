//! Native PIN provider and one-enrollment challenge broker. No PIN persistence.
use super::*;
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

pub(super) const UID: u32 = 941003;
const HANDLE_MAX: usize = 4096;
const PROVIDER_SOCKET: &str = "/run/nx809j-gatekeeper/worker.sock";
const ENROLL_DIRECTORY: &str = "/run/nx809j-fingerprint";
const ENROLL_SOCKET: &str = "/run/nx809j-fingerprint/enroll.sock";
const LIMIT: Duration = Duration::from_secs(25);

pub(super) fn enabled() -> bool {
    fs::read("/sys/firmware/devicetree/base/compatible")
        .is_ok_and(|b| b.starts_with(b"nubia,nx809j\0"))
}

pub(super) struct Credential {
    pub(super) uid: u32,
    pub(super) sid: u64,
    pub(super) handle: Vec<u8>,
}
impl Clone for Credential {
    fn clone(&self) -> Self {
        Self {
            uid: self.uid,
            sid: self.sid,
            handle: self.handle.clone(),
        }
    }
}
impl Drop for Credential {
    fn drop(&mut self) {
        erase_bytes(&mut self.handle);
    }
}
impl Credential {
    pub(super) fn decode(value: &Value) -> io::Result<Self> {
        let uid = value["uid"]
            .as_u64()
            .filter(|v| *v == u64::from(UID))
            .ok_or_else(invalid)? as u32;
        let sid = value["secure_user_id"]
            .as_u64()
            .filter(|v| *v != 0)
            .ok_or_else(invalid)?;
        let bytes = value["handle"]
            .as_array()
            .filter(|v| !v.is_empty() && v.len() <= HANDLE_MAX)
            .ok_or_else(invalid)?;
        let handle = bytes
            .iter()
            .map(|v| {
                v.as_u64()
                    .filter(|v| *v <= 255)
                    .map(|v| v as u8)
                    .ok_or_else(invalid)
            })
            .collect::<io::Result<Vec<_>>>()?;
        Ok(Self { uid, sid, handle })
    }
    pub(super) fn encode(&self) -> Value {
        json!({"uid": self.uid, "secure_user_id": self.sid, "handle": self.handle})
    }
}

#[derive(Clone, Debug)]
pub(super) enum Failure {
    Rejected,
    Throttled(u32),
    Unavailable,
    Protocol,
}
impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Rejected => f.write_str("PIN rejected"),
            Self::Throttled(ms) => write!(f, "PIN retry after {ms} milliseconds"),
            Self::Unavailable => f.write_str("native PIN provider unavailable"),
            Self::Protocol => f.write_str("invalid native PIN response"),
        }
    }
}
impl Error for Failure {}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid native credential")
}
fn root_peer(stream: &UnixStream) -> io::Result<()> {
    let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
    let mut n = std::mem::size_of_val(&peer) as libc::socklen_t;
    // SAFETY: peer and n describe valid writable buffers.
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut peer as *mut libc::ucred).cast(),
            &mut n,
        )
    } != 0
        || n as usize != std::mem::size_of_val(&peer)
        || peer.uid != 0
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}
fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn u64_at(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
}

fn call(
    op: u32,
    current: Option<&Credential>,
    challenge: u64,
    password: &[u8],
    desired: &[u8],
) -> Result<(u64, Vec<u8>), Failure> {
    let mut stream = UnixStream::connect(PROVIDER_SOCKET).map_err(|_| Failure::Unavailable)?;
    root_peer(&stream).map_err(|_| Failure::Unavailable)?;
    stream
        .set_read_timeout(Some(LIMIT))
        .map_err(|_| Failure::Unavailable)?;
    stream
        .set_write_timeout(Some(LIMIT))
        .map_err(|_| Failure::Unavailable)?;
    exchange(&mut stream, op, current, challenge, password, desired)
}
fn exchange(
    stream: &mut (impl Read + Write),
    op: u32,
    current: Option<&Credential>,
    challenge: u64,
    password: &[u8],
    desired: &[u8],
) -> Result<(u64, Vec<u8>), Failure> {
    let handle = current.map_or(&[][..], |c| &c.handle);
    if password.len() > 1024
        || desired.len() > 1024
        || handle.len() > HANDLE_MAX
        || current.is_some_and(|c| c.uid != UID || c.sid == 0)
    {
        return Err(Failure::Protocol);
    }
    let mut packet = vec![0u8; 48];
    packet[..8].copy_from_slice(b"NXGK1\0\0\0");
    packet[8..12].copy_from_slice(&op.to_le_bytes());
    packet[16..24].copy_from_slice(&challenge.to_le_bytes());
    packet[24..32].copy_from_slice(&current.map_or(0, |c| c.sid).to_le_bytes());
    for (at, n) in [
        (32, handle.len()),
        (36, password.len()),
        (40, desired.len()),
    ] {
        packet[at..at + 4].copy_from_slice(&(n as u32).to_le_bytes());
    }
    packet.extend_from_slice(handle);
    packet.extend_from_slice(password);
    packet.extend_from_slice(desired);
    let sent = stream.write_all(&packet);
    erase_bytes(&mut packet);
    sent.map_err(|_| Failure::Unavailable)?;
    let mut reply = [0u8; 40];
    stream
        .read_exact(&mut reply)
        .map_err(|_| Failure::Unavailable)?;
    if &reply[..8] != b"NXGR1\0\0\0" || u32_at(&reply, 20) != UID || u32_at(&reply, 36) != 0 {
        return Err(Failure::Protocol);
    }
    let status = u32_at(&reply, 8) as i32;
    let service = u32_at(&reply, 12) as i32;
    let retry = u32_at(&reply, 16);
    let sid = u64_at(&reply, 24);
    let n = u32_at(&reply, 32) as usize;
    if status != 0 {
        if n != 0 || sid != 0 {
            return Err(Failure::Protocol);
        }
        return match (status, service, retry) {
            (s, -1, 0) if s == -libc::EACCES => Err(Failure::Rejected),
            (s, -2, ms) if s == -libc::EAGAIN && ms > 0 => Err(Failure::Throttled(ms)),
            _ => Err(Failure::Unavailable),
        };
    }
    if service != 0
        || retry != 0
        || sid == 0
        || (op == 3 && n != 69)
        || (op != 3 && !(1..=HANDLE_MAX).contains(&n))
        || current.is_some_and(|c| c.sid != sid)
    {
        return Err(Failure::Protocol);
    }
    let mut data = vec![0u8; n];
    if stream.read_exact(&mut data).is_err() {
        erase_bytes(&mut data);
        return Err(Failure::Protocol);
    }
    let mut extra = [0u8; 1];
    if !matches!(stream.read(&mut extra), Ok(0)) {
        erase_bytes(&mut data);
        return Err(Failure::Protocol);
    }
    if op == 3
        && (data[0] != 0
            || u64_at(&data, 1) != challenge
            || u64_at(&data, 9) != sid
            || data[25..29] != [0, 0, 0, 1]
            || data[37..].iter().all(|b| *b == 0))
    {
        erase_bytes(&mut data);
        return Err(Failure::Protocol);
    }
    Ok((sid, data))
}

pub(super) fn enroll(
    current: Option<&Credential>,
    password: &[u8],
    desired: &[u8],
) -> Result<Credential, Failure> {
    let (sid, handle) = call(
        if current.is_some() { 2 } else { 1 },
        current,
        0,
        password,
        desired,
    )?;
    Ok(Credential {
        uid: UID,
        sid,
        handle,
    })
}
pub(super) fn verify(
    current: &Credential,
    password: &[u8],
    challenge: u64,
) -> Result<Vec<u8>, Failure> {
    call(3, Some(current), challenge, password, &[]).map(|(_, data)| data)
}

/// One-shot root broker, alive only while the corresponding fprintd enrollment
/// is pending. The sensor worker consumes one challenge; no reusable token cache.
pub(super) struct Authorization {
    stop: Arc<AtomicBool>,
    error: Arc<Mutex<Option<Failure>>>,
    thread: Option<JoinHandle<()>>,
    socket: PathBuf,
    inode: u64,
    _lock: File,
}
impl Authorization {
    pub(super) fn start(credential: Credential, pin: SecureString) -> io::Result<Self> {
        if unsafe { libc::geteuid() } != 0 {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let directory = Path::new(ENROLL_DIRECTORY);
        if !directory.exists() {
            fs::DirBuilder::new().mode(0o700).create(directory)?;
        }
        let meta = fs::symlink_metadata(directory)?;
        if !meta.is_dir() || meta.uid() != 0 || meta.mode() & 0o777 != 0o700 {
            return Err(invalid());
        }
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(directory.join("enroll.lock"))?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let socket = PathBuf::from(ENROLL_SOCKET);
        if let Ok(meta) = fs::symlink_metadata(&socket) {
            if !meta.file_type().is_socket() || meta.uid() != 0 {
                return Err(invalid());
            }
            fs::remove_file(&socket)?;
        }
        let listener = UnixListener::bind(&socket)?;
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
        let inode = fs::symlink_metadata(&socket)?.ino();
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let error = Arc::new(Mutex::new(None));
        let stopping = Arc::clone(&stop);
        let failure = Arc::clone(&error);
        let thread = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(120);
            while !stopping.load(Ordering::SeqCst) && Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut client, _)) => {
                        let result = answer(&mut client, &credential, &pin);
                        if let Err(error) = result {
                            *lock_unpoisoned(&failure) = Some(
                                error
                                    .downcast_ref::<Failure>()
                                    .cloned()
                                    .unwrap_or(Failure::Unavailable),
                            );
                        }
                        return;
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(20))
                    }
                    Err(_) => {
                        *lock_unpoisoned(&failure) = Some(Failure::Unavailable);
                        return;
                    }
                }
            }
        });
        Ok(Self {
            stop,
            error,
            thread: Some(thread),
            socket,
            inode,
            _lock: lock,
        })
    }
    pub(super) fn error(&self) -> Option<Failure> {
        lock_unpoisoned(&self.error).clone()
    }
}
impl Drop for Authorization {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        if fs::symlink_metadata(&self.socket).is_ok_and(|m| m.ino() == self.inode) {
            let _ = fs::remove_file(&self.socket);
        }
    }
}
fn authorization_challenge(request: &[u8; 24]) -> io::Result<u64> {
    let challenge = u64_at(request, 8);
    if &request[..8] != b"NXEA1\0\0\0"
        || u32_at(request, 16) != UID
        || u32_at(request, 20) != 0
        || challenge == 0
    {
        return Err(invalid());
    }
    Ok(challenge)
}

fn answer(
    client: &mut UnixStream,
    credential: &Credential,
    pin: &SecureString,
) -> Result<(), Box<dyn Error>> {
    root_peer(client)?;
    client.set_read_timeout(Some(Duration::from_secs(2)))?;
    client.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut request = [0u8; 24];
    client.read_exact(&mut request)?;
    let challenge = authorization_challenge(&request)?;
    let mut header = [0u8; 16];
    header[..8].copy_from_slice(b"NXER1\0\0\0");
    match verify(credential, pin.as_bytes(), challenge) {
        Ok(mut hat) => {
            let sent = client
                .write_all(&header)
                .and_then(|()| client.write_all(&hat));
            erase_bytes(&mut hat);
            sent?;
            Ok(())
        }
        Err(error) => {
            let (status, delay) = match error {
                Failure::Rejected => (-libc::EACCES, 0),
                Failure::Throttled(ms) => (-libc::EAGAIN, ms),
                _ => (-libc::EIO, 0),
            };
            header[8..12].copy_from_slice(&status.to_le_bytes());
            header[12..16].copy_from_slice(&delay.to_le_bytes());
            client.write_all(&header)?;
            Err(error.into())
        }
    }
}

#[cfg(test)]
#[path = "gatekeeper/tests.rs"]
mod tests;
