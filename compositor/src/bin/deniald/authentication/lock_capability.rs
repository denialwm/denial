//! Account metadata tells whether the account has a password or fingerprint.
//! With neither and no PIN record, the lock screen opens with a swipe. Unknown
//! providers keep the password prompt. No password or fingerprint scan is
//! attempted.

use super::*;
use futures_lite::future;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::process::{Command, Stdio};
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::OwnedObjectPath;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Capability {
    Pending,
    Unknown,
    Available,
    Unavailable,
}

#[derive(Clone, Copy)]
struct Account {
    locked: bool,
    password_mode: i32,
}

fn classify(account: Option<Account>, fingerprint: Option<bool>) -> Capability {
    match (account, fingerprint) {
        (
            Some(Account {
                locked: false,
                password_mode: 0,
            }),
            _,
        )
        | (_, Some(true)) => Capability::Available,
        (Some(Account { locked: true, .. }), _)
        | (
            Some(Account {
                password_mode: 1 | 2,
                ..
            }),
            _,
        ) => Capability::Unavailable,
        _ => Capability::Unknown,
    }
}

/// fprintd announces no enrollment changes, so a capability that rests on
/// fingerprints is read again after this.
const FINGERPRINT_RECHECK: Duration = Duration::from_secs(30);

pub(super) fn run_worker(shared: &Arc<SharedAuthentication>) {
    let shadow = ShadowWatch::new()
        .inspect_err(|error| {
            warn!(%error, "cannot watch /etc/shadow; rechecking the lock capability every 30 s");
        })
        .ok();
    future::block_on(async {
        while !lock_unpoisoned(&shared.state).stopping {
            let (capability, settled) = probe().unwrap_or_else(|error| {
                tracing::debug!(%error, "could not determine automatic lock capability");
                (Capability::Unknown, false)
            });
            publish(shared, capability);
            // Passwords and account locks change only with /etc/shadow.
            let recheck = async {
                match &shadow {
                    Some(shadow) if settled => shadow.changed().await,
                    Some(shadow) => {
                        future::race(shadow.changed(), async {
                            async_io::Timer::after(FINGERPRINT_RECHECK).await;
                        })
                        .await
                    }
                    None => {
                        async_io::Timer::after(FINGERPRINT_RECHECK).await;
                    }
                }
            };
            future::race(recheck, shared.capability_stop.wait()).await;
        }
    });
}

fn publish(shared: &SharedAuthentication, capability: Capability) {
    let mut state = lock_unpoisoned(&shared.state);
    // Losing the metadata provider must not lock out an account previously
    // established to have no credential.
    let capability = if capability == Capability::Unknown
        && state.account_credential == Capability::Unavailable
    {
        Capability::Unavailable
    } else {
        capability
    };
    if state.account_credential == capability {
        return;
    }
    state.account_credential = capability;
    match capability {
        Capability::Unavailable => info!(
            "account has no usable password or fingerprint; the lock screen opens with a swipe unless a PIN is set"
        ),
        Capability::Unknown => {
            warn!("account credentials are unknown; the lock screen asks for the password")
        }
        _ => info!(?capability, "account credential changed"),
    }
}

/// Reports a replaced or rewritten /etc/shadow. passwd, usermod and
/// AccountsService write a new file and rename it over the old one.
struct ShadowWatch {
    inotify: async_io::Async<OwnedFd>,
}

impl ShadowWatch {
    fn new() -> io::Result<Self> {
        // SAFETY: inotify_init1 has no pointer arguments.
        let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: inotify_init1 returned a new descriptor that nothing else owns.
        let inotify = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: the path is a NUL-terminated literal.
        let watch = unsafe {
            libc::inotify_add_watch(
                inotify.as_raw_fd(),
                c"/etc".as_ptr(),
                libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO,
            )
        };
        if watch < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            inotify: async_io::Async::new(inotify)?,
        })
    }

    /// Returns once /etc/shadow changed, or when the watch failed.
    async fn changed(&self) {
        let mut buffer = [0_u8; 4096];
        loop {
            if self.inotify.readable().await.is_err() {
                return;
            }
            // SAFETY: the buffer is valid for its whole length.
            let read = unsafe {
                libc::read(
                    self.inotify.get_ref().as_raw_fd(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                )
            };
            if read < 0 {
                let error = io::Error::last_os_error();
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) {
                    continue;
                }
                return;
            }
            if names_shadow(&buffer[..read as usize]) {
                return;
            }
        }
    }
}

/// Whether a run of inotify events names /etc/shadow.
fn names_shadow(mut events: &[u8]) -> bool {
    const HEADER: usize = std::mem::size_of::<libc::inotify_event>();
    while events.len() >= HEADER {
        // SAFETY: the kernel wrote a whole event header here; read_unaligned
        // copies it out of the byte buffer.
        let event =
            unsafe { std::ptr::read_unaligned(events.as_ptr().cast::<libc::inotify_event>()) };
        let end = HEADER.saturating_add(event.len as usize).min(events.len());
        let name = &events[HEADER..end];
        if name.split(|byte| *byte == 0).next() == Some(b"shadow".as_slice()) {
            return true;
        }
        events = &events[end..];
    }
    false
}

/// The capability, and whether only a change to /etc/shadow can alter it.
fn probe() -> Result<(Capability, bool), String> {
    // An explicitly selected PAM stack can authenticate independently of a
    // local password. AccountsService cannot establish its capabilities.
    if configured_pam_service() != "login" {
        return Ok((Capability::Unknown, true));
    }
    let connection = crate::bus::blocking_system();
    let account = match connection
        .as_ref()
        .ok()
        .and_then(|connection| account(connection).ok())
    {
        Some(account) => account,
        None => password_status().ok_or("account metadata is unavailable")?,
    };
    if !account.locked && account.password_mode == 0 {
        return Ok((Capability::Available, true));
    }
    let fingerprint = connection
        .as_ref()
        .ok()
        .and_then(|connection| fingerprint_enrolled(connection).ok())
        .map(|enrolled| {
            enrolled
                && PamBackend::load()
                    .and_then(|backend| backend.validate_account())
                    .is_ok()
        });
    Ok((classify(Some(account), fingerprint), false))
}

fn parse_password_status(output: &str, username: &str) -> Option<Account> {
    let mut fields = output.split_whitespace();
    if fields.next()? != username {
        return None;
    }
    match fields.next()? {
        "L" => Some(Account {
            locked: true,
            password_mode: 0,
        }),
        "NP" => Some(Account {
            locked: false,
            password_mode: 2,
        }),
        "P" => Some(Account {
            locked: false,
            password_mode: 0,
        }),
        _ => None,
    }
}

fn password_status() -> Option<Account> {
    let username = current_username();
    if username.starts_with('-') || username.is_empty() {
        return None;
    }
    // shadow-utils allows an unprivileged user to query their own status.
    // Fixed paths avoid selecting an executable from the shell's PATH. -S is
    // read-only; never invoke passwd without it or provide password input.
    for path in ["/usr/bin/passwd", "/bin/passwd"] {
        let Ok(mut child) = Command::new(path)
            .args(["-S", &username])
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            continue;
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
            }
        };
        if status.is_some_and(|status| status.success()) {
            let mut output = String::new();
            if child
                .stdout
                .take()?
                .take(1024)
                .read_to_string(&mut output)
                .is_ok()
                && let Some(account) = parse_password_status(&output, &username)
            {
                return Some(account);
            }
        }
    }
    None
}

fn account(connection: &Connection) -> zbus::Result<Account> {
    let manager = Proxy::new(
        connection,
        "org.freedesktop.Accounts",
        "/org/freedesktop/Accounts",
        "org.freedesktop.Accounts",
    )?;
    // Use the native UID, never USER or another shell-supplied identity.
    let uid = unsafe { libc::getuid() };
    let path: OwnedObjectPath = manager.call("FindUserById", &(i64::from(uid),))?;
    let user = Proxy::new(
        connection,
        "org.freedesktop.Accounts",
        path,
        "org.freedesktop.Accounts.User",
    )?;
    Ok(Account {
        locked: user.get_property("Locked")?,
        password_mode: user.get_property("PasswordMode")?,
    })
}

fn fingerprint_enrolled(connection: &Connection) -> zbus::Result<bool> {
    let bus = zbus::blocking::fdo::DBusProxy::new(connection)?;
    // An absent, non-activatable service cannot provide native unlock.
    let running = bus.name_has_owner("net.reactivated.Fprint".try_into()?)?;
    if !running {
        let names = bus.list_activatable_names()?;
        if !names
            .iter()
            .any(|name| name.as_str() == "net.reactivated.Fprint")
        {
            return Ok(false);
        }
    }
    let manager = Proxy::new(
        connection,
        "net.reactivated.Fprint",
        "/net/reactivated/Fprint/Manager",
        "net.reactivated.Fprint.Manager",
    )?;
    let devices: Vec<OwnedObjectPath> = manager.call("GetDevices", &())?;
    for path in devices {
        let device = Proxy::new(
            connection,
            "net.reactivated.Fprint",
            path,
            "net.reactivated.Fprint.Device",
        )?;
        let fingers: Vec<String> = device.call("ListEnrolledFingers", &("",))?;
        if !fingers.is_empty() {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unusable_accounts_require_a_validated_fingerprint() {
        for account in [
            Account {
                locked: true,
                password_mode: 0,
            },
            Account {
                locked: false,
                password_mode: 1,
            },
            Account {
                locked: false,
                password_mode: 2,
            },
        ] {
            assert_eq!(
                classify(Some(account), Some(false)),
                Capability::Unavailable
            );
            assert_eq!(classify(Some(account), Some(true)), Capability::Available);
            assert_eq!(classify(Some(account), None), Capability::Unavailable);
        }
    }

    #[test]
    fn unknown_metadata_is_never_credential_free() {
        assert_eq!(classify(None, Some(false)), Capability::Unknown);
        assert_eq!(
            classify(
                Some(Account {
                    locked: false,
                    password_mode: 7
                }),
                Some(false)
            ),
            Capability::Unknown
        );
        assert_eq!(
            classify(
                Some(Account {
                    locked: false,
                    password_mode: 0
                }),
                None
            ),
            Capability::Available
        );
    }

    #[test]
    fn only_events_naming_shadow_count() {
        fn event(name: &[u8]) -> Vec<u8> {
            let mut padded = name.to_vec();
            padded.resize(16, 0);
            let mut bytes = Vec::new();
            for field in [1_u32, libc::IN_MOVED_TO, 0, padded.len() as u32] {
                bytes.extend_from_slice(&field.to_ne_bytes());
            }
            bytes.extend_from_slice(&padded);
            bytes
        }
        assert!(!names_shadow(
            &[event(b"nshadow"), event(b"shadow-")].concat()
        ));
        assert!(!names_shadow(&event(b"gshadow")));
        assert!(names_shadow(&[event(b"passwd"), event(b"shadow")].concat()));
        assert!(!names_shadow(&event(b"shadow")[..10]));
    }

    #[test]
    fn password_status_fallback_accepts_only_the_native_users_known_status() {
        let locked = parse_password_status("alice L 2026-01-01 0 99999 7 -1\n", "alice").unwrap();
        assert_eq!(classify(Some(locked), Some(false)), Capability::Unavailable);
        let empty = parse_password_status("alice NP 2026-01-01 0 99999 7 -1\n", "alice").unwrap();
        assert_eq!(classify(Some(empty), Some(false)), Capability::Unavailable);
        let password = parse_password_status("alice P 2026-01-01 0 99999 7 -1\n", "alice").unwrap();
        assert_eq!(classify(Some(password), Some(false)), Capability::Available);
        for output in ["bob L", "alice", "alice invalid", "", "warning: alice L"] {
            assert!(parse_password_status(output, "alice").is_none());
        }
    }
}
