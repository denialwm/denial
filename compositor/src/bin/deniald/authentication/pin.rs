//! Optional numeric unlock PIN. The account password stays the primary
//! credential: a PIN unlock still passes PAM account policy, the lock screen
//! always offers the password next to the PIN, and outside the lock screen
//! the PIN only proves itself to Settings, to change it or the fingerprints.
//! Settings asks for the account password only to set the first PIN, or one
//! forgotten, and to turn PIN unlock off.
//! Fingerprint unlock needs a PIN: without a record the reader stays off.
//!
//! NX809J records contain the opaque Gatekeeper handle and SID; other devices
//! use Argon2id. Records are written after account-password verification or an
//! authenticated PIN change. PINs are never persisted. Native checks use the
//! restricted root worker socket and never fall back to a host hash.

use super::*;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;

pub(super) const MIN_LENGTH: usize = 4;
pub(super) const MAX_LENGTH: usize = 12;
/// A new PIN has six digits. Records of other lengths made before still
/// unlock until the PIN is changed.
pub(super) const NEW_LENGTH: usize = 6;
const RECORD_VERSION: u64 = 1;
const MAX_RECORD_BYTES: u64 = 32768;
const SALT_BYTES: usize = 16;
// OWASP's Argon2id baseline: 19 MiB, two passes, one lane.
const MEMORY_KIB: u32 = 19 * 1024;
const PASSES: u32 = 2;

pub(super) fn valid_pin(pin: &[u8]) -> bool {
    (MIN_LENGTH..=MAX_LENGTH).contains(&pin.len()) && pin.iter().all(u8::is_ascii_digit)
}

pub(super) fn valid_new_pin(pin: &[u8]) -> bool {
    pin.len() == NEW_LENGTH && valid_pin(pin)
}

#[derive(Clone, Debug)]
pub(super) struct PinStore {
    path: PathBuf,
}

pub(super) struct PinRecord {
    length: u32,
    hash: String,
    native: Option<gatekeeper::Credential>,
    enabled: bool,
}

impl PinRecord {
    pub(super) fn length(&self) -> u32 {
        self.length
    }

    pub(super) fn verify(&self, pin: &[u8]) -> bool {
        // Wrong lengths are rejected without hashing; the length is not secret
        // because the lock screen draws one slot per digit.
        if pin.len() != self.length as usize || !valid_pin(pin) {
            return false;
        }
        if let Some(credential) = &self.native {
            return match gatekeeper::verify(credential, pin, 0) {
                Ok(mut token) => {
                    erase_bytes(&mut token);
                    true
                }
                Err(_) => false,
            };
        }
        PasswordHash::new(&self.hash)
            .is_ok_and(|hash| Argon2::default().verify_password(pin, &hash).is_ok())
    }
}

impl PinStore {
    pub(super) fn for_current_user() -> Option<Self> {
        if unsafe { libc::geteuid() } != unsafe { libc::getuid() } {
            return Self::for_uid(unsafe { libc::getuid() });
        }
        let state_home = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .filter(|path| path.is_absolute())
                    .map(|home| home.join(".local/state"))
            })?;
        Some(Self::at(state_home.join("denial/lock-pin")))
    }

    pub(super) fn for_uid(uid: libc::uid_t) -> Option<Self> {
        use std::os::unix::ffi::OsStrExt;
        let mut record: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result = std::ptr::null_mut();
        let mut buffer = vec![0u8; 65536];
        // SAFETY: passwd, buffer and result remain valid throughout this call.
        if unsafe {
            libc::getpwuid_r(
                uid,
                &mut record,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        } != 0
            || result.is_null()
            || record.pw_dir.is_null()
        {
            return None;
        }
        let home = unsafe { CStr::from_ptr(record.pw_dir) }.to_bytes();
        let home = PathBuf::from(std::ffi::OsStr::from_bytes(home));
        home.is_absolute()
            .then(|| Self::at(home.join(".local/state/denial/lock-pin")))
    }

    pub(super) fn at(path: PathBuf) -> Self {
        Self { path }
    }

    pub(super) fn load(&self) -> io::Result<Option<PinRecord>> {
        self.load_record()
            .map(|record| record.filter(|record| record.enabled))
    }

    fn load_record(&self) -> io::Result<Option<PinRecord>> {
        let mut file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&self.path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let metadata = file.metadata()?;
        // SAFETY: getuid has no preconditions and cannot fail.
        let uid = unsafe { libc::getuid() };
        if !metadata.is_file() || metadata.uid() != uid || metadata.len() > MAX_RECORD_BYTES {
            return Err(invalid_record());
        }
        let mut text = String::new();
        Read::by_ref(&mut file)
            .take(MAX_RECORD_BYTES)
            .read_to_string(&mut text)?;
        let record: Value = serde_json::from_str(&text).map_err(|_| invalid_record())?;
        let length = record
            .get("length")
            .and_then(Value::as_u64)
            .filter(|length| (MIN_LENGTH as u64..=MAX_LENGTH as u64).contains(length))
            .ok_or_else(invalid_record)?;
        if record.get("version").and_then(Value::as_u64) == Some(2) {
            let native = gatekeeper::Credential::decode(&record["gatekeeper"])?;
            return Ok(Some(PinRecord {
                length: length as u32,
                hash: String::new(),
                native: Some(native),
                enabled: record
                    .get("enabled")
                    .and_then(Value::as_bool)
                    .unwrap_or(true),
            }));
        }
        let hash = record
            .get("hash")
            .and_then(Value::as_str)
            .filter(|hash| {
                PasswordHash::new(hash)
                    .is_ok_and(|hash| hash.algorithm == Algorithm::Argon2id.ident())
            })
            .ok_or_else(invalid_record)?;
        if record.get("version").and_then(Value::as_u64) != Some(RECORD_VERSION) {
            return Err(invalid_record());
        }
        Ok(Some(PinRecord {
            length: length as u32,
            hash: hash.to_owned(),
            native: None,
            enabled: true,
        }))
    }

    pub(super) fn save(&self, pin: &[u8]) -> io::Result<u32> {
        let _change = self.change_lock()?;
        if !valid_new_pin(pin) {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        if gatekeeper::enabled() {
            if self.load_record()?.is_some_and(|r| r.native.is_some()) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "changing a native PIN requires the current PIN",
                ));
            }
            let credential = gatekeeper::enroll(None, &[], pin).map_err(io::Error::other)?;
            return self.save_credential(pin.len() as u32, &credential);
        }
        let mut salt = [0u8; SALT_BYTES];
        fill_random(&mut salt)?;
        let salt = SaltString::encode_b64(&salt).map_err(|_| invalid_record())?;
        let params = Params::new(MEMORY_KIB, PASSES, 1, None).map_err(|_| invalid_record())?;
        let hash = Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
            .hash_password(pin, &salt)
            .map_err(|_| invalid_record())?
            .to_string();
        let length = pin.len() as u32;
        let record = json!({"version": RECORD_VERSION, "length": length, "hash": hash});
        self.replace(record.to_string().as_bytes())?;
        Ok(length)
    }

    fn save_credential(&self, length: u32, credential: &gatekeeper::Credential) -> io::Result<u32> {
        let value = json!({"version": 2, "length": length, "enabled": true, "gatekeeper": credential.encode()});
        self.replace(value.to_string().as_bytes())?;
        Ok(length)
    }

    pub(super) fn enrollment_credential(&self) -> io::Result<gatekeeper::Credential> {
        self.load()?.and_then(|r| r.native).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "configure a native lock PIN before enrolling fingerprints",
            )
        })
    }

    fn change_native(
        &self,
        record: &PinRecord,
        current: &[u8],
        desired: &[u8],
    ) -> io::Result<Value> {
        let _change = self.change_lock()?;
        let latest = self.load_record()?.ok_or_else(invalid_record)?;
        if !latest
            .native
            .as_ref()
            .zip(record.native.as_ref())
            .is_some_and(|(a, b)| a.uid == b.uid && a.sid == b.sid && a.handle == b.handle)
        {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        if !valid_new_pin(desired) {
            return Ok(json!({"event": "invalid-pin"}));
        }
        let credential = record.native.as_ref().ok_or_else(invalid_record)?;
        match gatekeeper::enroll(Some(credential), current, desired) {
            Ok(replacement) => Ok(
                json!({"event": "saved", "length": self.save_credential(desired.len() as u32, &replacement)?}),
            ),
            Err(gatekeeper::Failure::Rejected) => Ok(json!({"event": "wrong-pin"})),
            Err(gatekeeper::Failure::Throttled(ms)) => {
                Ok(json!({"event": "rate-limited", "retry_ms": ms}))
            }
            Err(error) => Err(io::Error::other(error)),
        }
    }

    pub(super) fn clear(&self) -> io::Result<()> {
        let _change = self.change_lock()?;
        // Retain the only handle needed to authenticate this native identity.
        if let Some(record) = self.load_record()? {
            if let Some(credential) = record.native.as_ref() {
                let value = json!({"version":2, "length":record.length, "enabled":false, "gatekeeper":credential.encode()});
                return self.replace(value.to_string().as_bytes());
            }
        }
        match fs::remove_file(&self.path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    fn change_lock(&self) -> io::Result<File> {
        use std::os::fd::AsRawFd;
        let directory = self.path.parent().ok_or(io::ErrorKind::InvalidInput)?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(self.path.with_extension("lock"))?;
        // Keep credential changes serialized through both trusted call and fsync.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        Ok(lock)
    }

    /// Writes a private sibling and renames it over the record, so a reader
    /// never sees a partial record and a crash keeps the previous one.
    fn replace(&self, contents: &[u8]) -> io::Result<()> {
        let directory = self.path.parent().ok_or(io::ErrorKind::InvalidInput)?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        let staging = directory.join(format!(".lock-pin.{}", std::process::id()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&staging)?;
            file.write_all(contents)?;
            file.sync_all()?;
            fs::rename(&staging, &self.path)?;
            File::open(directory)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(&staging);
        }
        result
    }

    #[cfg(test)]
    pub(super) fn path(&self) -> &std::path::Path {
        &self.path
    }
}

fn invalid_record() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid lock PIN record")
}

fn fill_random(bytes: &mut [u8]) -> io::Result<()> {
    let mut filled = 0;
    while filled < bytes.len() {
        // SAFETY: the pointer and length describe the unfilled tail of `bytes`.
        let count = unsafe {
            libc::getrandom(bytes[filled..].as_mut_ptr().cast(), bytes.len() - filled, 0)
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
            continue;
        }
        filled += count as usize;
    }
    Ok(())
}

/// One PIN attempt: the shell answers a numeric prompt, the record decides,
/// and PAM account policy still runs exactly as it does for fingerprints.
pub(super) fn authenticate(
    record: &PinRecord,
    backend: &dyn AuthenticationBackend,
    conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
    cancelled: &dyn Fn() -> bool,
) -> BackendResult {
    let Some(mut response) = conversation(PromptStyle::Pin, "PIN") else {
        return BackendResult::Cancelled;
    };
    let matched = record.verify(response.as_bytes());
    response.clear();
    if cancelled() {
        return BackendResult::Cancelled;
    }
    if !matched {
        return BackendResult::Failure;
    }
    match backend.validate_account() {
        Ok(()) => BackendResult::Success,
        Err(error) => {
            warn!(%error, "PIN matched but PAM account policy refused the unlock");
            BackendResult::Error
        }
    }
}

/// `deniald --lock-pin`: Settings runs this as the session user. Secrets come
/// one per stdin line and never through argv, the environment or JSON:
/// `status`; `set` + password + new PIN (+ current PIN for an existing native
/// credential); a native credential is never reset using the account password;
/// `change` + current PIN + new PIN; `check` + PIN, before the fingerprints
/// change; `clear` + password.
pub(crate) fn run_settings() -> Result<(), Box<dyn Error>> {
    let store = PinStore::for_current_user().ok_or("no state directory for the lock PIN")?;
    let mut input = io::BufReader::new(io::stdin());
    let command = read_bounded_line(&mut input)?.ok_or("lock PIN command closed")?;
    let mut secret = |closed: &'static str| -> Result<SecureString, Box<dyn Error>> {
        let mut bytes = read_bounded_line(&mut input)?.ok_or(closed)?;
        let secret = SecureString::new(&bytes);
        erase_bytes(&mut bytes);
        Ok(secret)
    };
    let reply = match command.as_slice() {
        b"status" => status_event(&store),
        b"set" | b"clear" => {
            let password = secret("password input closed")?;
            let mut backend = PamBackend::load()?;
            if authenticate_password(&mut backend, &current_username(), &password)
                != BackendResult::Success
            {
                json!({"event": "authentication-failed"})
            } else if command == b"clear" {
                store.clear()?;
                json!({"event": "cleared"})
            } else {
                let desired = secret("PIN input closed")?;
                if let Some(record) = store.load_record()?.filter(|r| r.native.is_some()) {
                    store.change_native(
                        &record,
                        secret("current PIN input closed")?.as_bytes(),
                        desired.as_bytes(),
                    )?
                } else {
                    save_event(&store, &desired)?
                }
            }
        }
        b"change" | b"check" => {
            let current = secret("PIN input closed")?;
            // Without a record there is no PIN to prove; the password sets one.
            let record = store.load()?;
            if command == b"change" && record.as_ref().is_some_and(|r| r.native.is_some()) {
                store.change_native(
                    record.as_ref().unwrap(),
                    current.as_bytes(),
                    secret("PIN input closed")?.as_bytes(),
                )?
            } else {
                let checked = check_event(record.as_ref(), &current)?;
                if command == b"check" || checked["event"] != "confirmed" {
                    checked
                } else {
                    save_event(&store, &secret("PIN input closed")?)?
                }
            }
        }
        _ => return Err("unknown lock PIN command".into()),
    };
    println!("{reply}");
    Ok(())
}

/// Whether `pin` is the PIN of `record`: `confirmed`, `wrong-pin`, or
/// `rate-limited` with the provider's wait. No record means a wrong PIN.
pub(super) fn check_event(
    record: Option<&PinRecord>,
    pin: &SecureString,
) -> Result<Value, Box<dyn Error>> {
    if let Some(credential) = record.and_then(|r| r.native.as_ref()) {
        return Ok(match gatekeeper::verify(credential, pin.as_bytes(), 0) {
            Ok(mut token) => {
                erase_bytes(&mut token);
                json!({"event": "confirmed"})
            }
            Err(gatekeeper::Failure::Rejected) => json!({"event": "wrong-pin"}),
            Err(gatekeeper::Failure::Throttled(ms)) => {
                json!({"event": "rate-limited", "retry_ms": ms})
            }
            Err(error) => return Err(error.into()),
        });
    }
    Ok(if record.is_some_and(|r| r.verify(pin.as_bytes())) {
        json!({"event": "confirmed"})
    } else {
        json!({"event": "wrong-pin"})
    })
}

fn save_event(store: &PinStore, pin: &SecureString) -> io::Result<Value> {
    Ok(if valid_new_pin(pin.as_bytes()) {
        json!({"event": "saved", "length": store.save(pin.as_bytes())?})
    } else {
        json!({"event": "invalid-pin"})
    })
}

fn status_event(store: &PinStore) -> Value {
    match store.load_record() {
        Ok(record) => json!({
            "event": "status",
            "length": record.as_ref().filter(|record| record.enabled).map_or(0, |record| record.length()),
            "requires_current_pin": record.as_ref().is_some_and(|record| record.native.is_some()),
        }),
        Err(error) => {
            eprintln!("lock PIN record: {error}");
            json!({"event": "status", "length": 0, "invalid": true})
        }
    }
}
