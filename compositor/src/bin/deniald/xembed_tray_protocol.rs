//! Backend-neutral messages exchanged with the optional XEmbed tray host.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum XEmbedTrayEventKind {
    #[cfg_attr(not(feature = "xwayland"), allow(dead_code))]
    Added,
    #[cfg_attr(not(feature = "xwayland"), allow(dead_code))]
    Updated,
    Removed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct XEmbedTrayIcon {
    pub(super) window_id: u32,
    pub(super) title: String,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) rgba: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct XEmbedTrayEvent {
    pub(super) kind: XEmbedTrayEventKind,
    pub(super) window_id: u32,
    pub(super) icon: Option<XEmbedTrayIcon>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum XEmbedTrayAction {
    Activate,
    SecondaryActivate,
    ContextMenu,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct XEmbedTrayCommand {
    pub(super) action: XEmbedTrayAction,
    pub(super) window_id: u32,
    pub(super) x: i32,
    pub(super) y: i32,
}
