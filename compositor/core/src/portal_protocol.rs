//! Private, bounded protocol between `deniald` and `denial-portal`.
//!
//! Each message is one `SOCK_SEQPACKET` record. The fixed representation keeps
//! parsing independent from the user-editable settings document and leaves no
//! ambiguity about partial reads or unbounded allocation.

use std::fmt;

pub const PORTAL_SOCKET_FILE: &str = "portal.sock";
pub const PROTOCOL_VERSION: u16 = 2;
const MAGIC: [u8; 8] = *b"DENIALP\0";
const HEADER_BYTES: usize = 16;
const SNAPSHOT_PAYLOAD_BYTES: usize = 20;
pub const MAX_MESSAGE_BYTES: usize = HEADER_BYTES + SNAPSHOT_PAYLOAD_BYTES;
const KIND_HELLO: u16 = 1;
const KIND_THEME_SNAPSHOT: u16 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum DesktopColorSchemePreference {
    NoPreference = 0,
    PreferDark = 1,
    PreferLight = 2,
}

impl DesktopColorSchemePreference {
    pub const fn settings_name(self) -> &'static str {
        match self {
            Self::NoPreference => "noPreference",
            Self::PreferDark => "preferDark",
            Self::PreferLight => "preferLight",
        }
    }

    pub fn from_settings_name(value: &str) -> Option<Self> {
        match value {
            "noPreference" => Some(Self::NoPreference),
            "preferDark" => Some(Self::PreferDark),
            "preferLight" => Some(Self::PreferLight),
            _ => None,
        }
    }

    pub const fn effective_brightness(self) -> DesktopThemeBrightness {
        match self {
            Self::PreferLight => DesktopThemeBrightness::Light,
            Self::NoPreference | Self::PreferDark => DesktopThemeBrightness::Dark,
        }
    }

    pub const fn portal_value(self) -> u32 {
        match self {
            Self::NoPreference => 0,
            Self::PreferDark => 1,
            Self::PreferLight => 2,
        }
    }
}

impl TryFrom<u8> for DesktopColorSchemePreference {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::NoPreference),
            1 => Ok(Self::PreferDark),
            2 => Ok(Self::PreferLight),
            _ => Err(ProtocolError::InvalidPreference(value)),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum DesktopThemeBrightness {
    Dark = 0,
    Light = 1,
}

impl DesktopThemeBrightness {
    pub const fn flutter_name(self) -> &'static str {
        match self {
            Self::Dark => "dark",
            Self::Light => "light",
        }
    }
}

impl TryFrom<u8> for DesktopThemeBrightness {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Dark),
            1 => Ok(Self::Light),
            _ => Err(ProtocolError::InvalidBrightness(value)),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopAccentColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl DesktopAccentColor {
    /// Denial's brand accent, used only until Flutter resolves a wallpaper.
    pub const DENIAL_DEFAULT: Self = Self::new(0xd0, 0xbc, 0xff);

    pub const fn new(red: u8, green: u8, blue: u8) -> Self {
        Self { red, green, blue }
    }

    pub const fn from_srgb24(value: u32) -> Self {
        Self::new(
            ((value >> 16) & 0xff) as u8,
            ((value >> 8) & 0xff) as u8,
            (value & 0xff) as u8,
        )
    }

    pub const fn srgb24(self) -> u32 {
        ((self.red as u32) << 16) | ((self.green as u32) << 8) | self.blue as u32
    }

    pub fn portal_value(self) -> (f64, f64, f64) {
        (
            f64::from(self.red) / 255.0,
            f64::from(self.green) / 255.0,
            f64::from(self.blue) / 255.0,
        )
    }
}

impl Default for DesktopAccentColor {
    fn default() -> Self {
        Self::DENIAL_DEFAULT
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopThemeSnapshot {
    pub revision: u64,
    pub configured_preference: DesktopColorSchemePreference,
    pub effective_brightness: DesktopThemeBrightness,
    pub portal_color_scheme: u32,
    pub accent_color: DesktopAccentColor,
}

impl DesktopThemeSnapshot {
    pub const fn new(revision: u64, configured_preference: DesktopColorSchemePreference) -> Self {
        Self {
            revision,
            configured_preference,
            effective_brightness: configured_preference.effective_brightness(),
            portal_color_scheme: configured_preference.portal_value(),
            accent_color: DesktopAccentColor::DENIAL_DEFAULT,
        }
    }

    pub const fn with_accent(mut self, accent_color: DesktopAccentColor) -> Self {
        self.accent_color = accent_color;
        self
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClientMessage {
    Hello,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServerMessage {
    ThemeSnapshot(DesktopThemeSnapshot),
}

pub fn encode_client_message(message: ClientMessage) -> [u8; HEADER_BYTES] {
    match message {
        ClientMessage::Hello => encode_header(KIND_HELLO, 0),
    }
}

pub fn decode_client_message(bytes: &[u8]) -> Result<ClientMessage, ProtocolError> {
    let (kind, payload) = decode_header(bytes)?;
    match (kind, payload.len()) {
        (KIND_HELLO, 0) => Ok(ClientMessage::Hello),
        (KIND_HELLO, length) => Err(ProtocolError::InvalidPayloadLength(length)),
        (kind, _) => Err(ProtocolError::UnexpectedKind(kind)),
    }
}

pub fn encode_server_message(message: ServerMessage) -> [u8; MAX_MESSAGE_BYTES] {
    match message {
        ServerMessage::ThemeSnapshot(snapshot) => {
            let mut bytes = [0; MAX_MESSAGE_BYTES];
            bytes[..HEADER_BYTES]
                .copy_from_slice(&encode_header(KIND_THEME_SNAPSHOT, SNAPSHOT_PAYLOAD_BYTES));
            bytes[HEADER_BYTES..HEADER_BYTES + 8].copy_from_slice(&snapshot.revision.to_le_bytes());
            bytes[HEADER_BYTES + 8] = snapshot.configured_preference as u8;
            bytes[HEADER_BYTES + 9] = snapshot.effective_brightness as u8;
            bytes[HEADER_BYTES + 10..HEADER_BYTES + 14]
                .copy_from_slice(&snapshot.portal_color_scheme.to_le_bytes());
            bytes[HEADER_BYTES + 14] = snapshot.accent_color.red;
            bytes[HEADER_BYTES + 15] = snapshot.accent_color.green;
            bytes[HEADER_BYTES + 16] = snapshot.accent_color.blue;
            bytes
        }
    }
}

pub fn decode_server_message(bytes: &[u8]) -> Result<ServerMessage, ProtocolError> {
    let (kind, payload) = decode_header(bytes)?;
    if kind != KIND_THEME_SNAPSHOT {
        return Err(ProtocolError::UnexpectedKind(kind));
    }
    if payload.len() != SNAPSHOT_PAYLOAD_BYTES {
        return Err(ProtocolError::InvalidPayloadLength(payload.len()));
    }
    let revision = u64::from_le_bytes(
        payload[..8]
            .try_into()
            .expect("validated snapshot revision width"),
    );
    if revision == 0 {
        return Err(ProtocolError::InvalidRevision);
    }
    let configured_preference = DesktopColorSchemePreference::try_from(payload[8])?;
    let effective_brightness = DesktopThemeBrightness::try_from(payload[9])?;
    let portal_color_scheme = u32::from_le_bytes(
        payload[10..14]
            .try_into()
            .expect("validated portal value width"),
    );
    let accent_color = DesktopAccentColor::new(payload[14], payload[15], payload[16]);
    let expected =
        DesktopThemeSnapshot::new(revision, configured_preference).with_accent(accent_color);
    if effective_brightness != expected.effective_brightness
        || portal_color_scheme != expected.portal_color_scheme
    {
        return Err(ProtocolError::InconsistentSnapshot);
    }
    Ok(ServerMessage::ThemeSnapshot(expected))
}

fn encode_header(kind: u16, payload_bytes: usize) -> [u8; HEADER_BYTES] {
    let mut bytes = [0; HEADER_BYTES];
    bytes[..8].copy_from_slice(&MAGIC);
    bytes[8..10].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    bytes[10..12].copy_from_slice(&kind.to_le_bytes());
    bytes[12..16].copy_from_slice(
        &u32::try_from(payload_bytes)
            .expect("portal protocol payload length fits u32")
            .to_le_bytes(),
    );
    bytes
}

fn decode_header(bytes: &[u8]) -> Result<(u16, &[u8]), ProtocolError> {
    if bytes.len() < HEADER_BYTES {
        return Err(ProtocolError::Truncated(bytes.len()));
    }
    if bytes[..8] != MAGIC {
        return Err(ProtocolError::InvalidMagic);
    }
    let version = u16::from_le_bytes(bytes[8..10].try_into().expect("header version width"));
    if version != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(version));
    }
    let kind = u16::from_le_bytes(bytes[10..12].try_into().expect("header kind width"));
    let payload_bytes = u32::from_le_bytes(
        bytes[12..16]
            .try_into()
            .expect("header payload length width"),
    ) as usize;
    if payload_bytes > MAX_MESSAGE_BYTES - HEADER_BYTES
        || bytes.len() != HEADER_BYTES + payload_bytes
    {
        return Err(ProtocolError::InvalidPayloadLength(payload_bytes));
    }
    Ok((kind, &bytes[HEADER_BYTES..]))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProtocolError {
    Truncated(usize),
    InvalidMagic,
    UnsupportedVersion(u16),
    UnexpectedKind(u16),
    InvalidPayloadLength(usize),
    InvalidRevision,
    InvalidPreference(u8),
    InvalidBrightness(u8),
    InconsistentSnapshot,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated(length) => {
                write!(formatter, "truncated portal message ({length} bytes)")
            }
            Self::InvalidMagic => formatter.write_str("invalid portal message magic"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported portal protocol version {version}")
            }
            Self::UnexpectedKind(kind) => {
                write!(formatter, "unexpected portal message kind {kind}")
            }
            Self::InvalidPayloadLength(length) => {
                write!(formatter, "invalid portal payload length {length}")
            }
            Self::InvalidRevision => formatter.write_str("portal snapshot revision is zero"),
            Self::InvalidPreference(value) => {
                write!(formatter, "invalid color-scheme preference {value}")
            }
            Self::InvalidBrightness(value) => {
                write!(formatter, "invalid desktop brightness {value}")
            }
            Self::InconsistentSnapshot => {
                formatter.write_str("portal snapshot derived values are inconsistent")
            }
        }
    }
}

impl std::error::Error for ProtocolError {}
