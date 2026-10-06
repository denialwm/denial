#[cfg(any(test, feature = "xwayland"))]
use std::collections::BTreeSet;
use std::error::Error;
use std::ffi::OsStr;
#[cfg(feature = "xwayland")]
use std::io;

#[cfg(feature = "xwayland")]
use x11rb::NONE;
#[cfg(feature = "xwayland")]
use x11rb::connection::Connection;
#[cfg(feature = "xwayland")]
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _};

#[cfg(feature = "xwayland")]
const XIM_SERVERS_PROPERTY: &[u8] = b"XIM_SERVERS";
#[cfg(any(test, feature = "xwayland"))]
const XIM_SERVER_PREFIX: &[u8] = b"@server=";
#[cfg(feature = "xwayland")]
const MAX_XIM_SERVERS: u32 = 64;
#[cfg(any(test, feature = "xwayland"))]
const MAX_XIM_SERVER_NAME_BYTES: usize = 256;

/// Discover the unambiguous live XIM server registered with Xwayland.
///
/// XIM servers append a selection atom named `@server=NAME` to the root
/// `XIM_SERVERS` property. The property may retain stale entries, so ownership
/// of every advertised selection is checked before deriving `@im=NAME`.
#[cfg(feature = "xwayland")]
pub(crate) fn discover_xim_modifier(
    display_name: &OsStr,
) -> Result<Option<String>, Box<dyn Error>> {
    let display_name = display_name
        .to_str()
        .ok_or_else(|| io::Error::other("Xwayland display name is not UTF-8"))?;
    let (connection, screen_index) = x11rb::connect(Some(display_name))?;
    let root = connection
        .setup()
        .roots
        .get(screen_index)
        .ok_or_else(|| io::Error::other("Xwayland did not expose its requested screen"))?
        .root;
    let property = connection
        .intern_atom(true, XIM_SERVERS_PROPERTY)?
        .reply()?
        .atom;
    if property == NONE {
        return Ok(None);
    }
    let reply = connection
        .get_property(false, root, property, AtomEnum::ATOM, 0, MAX_XIM_SERVERS)?
        .reply()?;
    if reply.bytes_after != 0 {
        return Ok(None);
    }
    let atoms = reply
        .value32()
        .ok_or_else(|| io::Error::other("XIM_SERVERS is not an ATOM list"))?
        .collect::<Vec<_>>();
    let mut registrations = Vec::with_capacity(atoms.len());
    for atom in atoms {
        let active = connection.get_selection_owner(atom)?.reply()?.owner != NONE;
        let name = connection.get_atom_name(atom)?.reply()?.name;
        registrations.push((name, active));
    }
    Ok(select_xim_modifier(
        registrations
            .iter()
            .map(|(name, active)| (name.as_slice(), *active)),
    ))
}

#[cfg(not(feature = "xwayland"))]
pub(crate) fn discover_xim_modifier(
    _display_name: &OsStr,
) -> Result<Option<String>, Box<dyn Error>> {
    Ok(None)
}

#[cfg(any(test, feature = "xwayland"))]
fn select_xim_modifier<'a>(
    registrations: impl IntoIterator<Item = (&'a [u8], bool)>,
) -> Option<String> {
    let active = registrations
        .into_iter()
        .filter_map(|(name, owned)| owned.then(|| modifier_from_server_atom(name)).flatten())
        .collect::<BTreeSet<_>>();
    (active.len() == 1)
        .then(|| active.into_iter().next())
        .flatten()
}

#[cfg(any(test, feature = "xwayland"))]
fn modifier_from_server_atom(atom_name: &[u8]) -> Option<String> {
    let server = atom_name.strip_prefix(XIM_SERVER_PREFIX)?;
    if server.is_empty()
        || server.len() > MAX_XIM_SERVER_NAME_BYTES
        || server.iter().any(|byte| byte.is_ascii_control())
    {
        return None;
    }
    let server = std::str::from_utf8(server).ok()?;
    Some(format!("@im={server}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_only_one_live_well_formed_xim_server() {
        assert_eq!(
            select_xim_modifier([(b"@server=fcitx".as_slice(), true)]),
            Some("@im=fcitx".to_owned())
        );
        assert_eq!(
            select_xim_modifier([
                (b"@server=stale".as_slice(), false),
                (b"@server=ibus".as_slice(), true),
            ]),
            Some("@im=ibus".to_owned())
        );
        assert_eq!(
            select_xim_modifier([
                (b"@server=fcitx".as_slice(), true),
                (b"@server=ibus".as_slice(), true),
            ]),
            None
        );
        assert_eq!(
            select_xim_modifier([
                (b"not-a-server".as_slice(), true),
                (b"@server=".as_slice(), true),
                (b"@server=bad\0name".as_slice(), true),
            ]),
            None
        );
    }
}
