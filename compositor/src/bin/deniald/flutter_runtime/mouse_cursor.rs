use std::ffi::CStr;
use std::str;

pub const CHANNEL: &CStr = c"flutter/mousecursor";

const ACTIVATE_SYSTEM_CURSOR: &str = "activateSystemCursor";
const MAX_PACKET_BYTES: usize = 4096;

// Flutter's mouse-cursor channel uses StandardMethodCodec, whose values begin
// with these stable StandardMessageCodec tags.
const VALUE_NULL: u8 = 0;
const VALUE_INT32: u8 = 3;
const VALUE_INT64: u8 = 4;
const VALUE_STRING: u8 = 7;
const VALUE_MAP: u8 = 13;
const SUCCESS_ENVELOPE: u8 = 0;
const ERROR_ENVELOPE: u8 = 1;

#[derive(Debug)]
struct CursorArguments<'a> {
    device: i64,
    kind: &'a str,
}

#[derive(Debug, Default)]
pub(super) struct MouseCursorPlugin {
    pending_shape: Option<&'static str>,
}

impl MouseCursorPlugin {
    pub(super) fn handle_platform_message(&mut self, data: &[u8]) -> Vec<u8> {
        if data.len() > MAX_PACKET_BYTES {
            return error("Bad Arguments", "Mouse cursor request is too large.");
        }

        let mut decoder = StandardDecoder::new(data);
        let Ok(method) = decoder.read_string_value() else {
            return error(
                "Bad Arguments",
                "Mouse cursor request is not a valid method call.",
            );
        };
        if method != ACTIVATE_SYSTEM_CURSOR {
            return Vec::new();
        }
        let Ok(arguments) = decode_cursor_arguments(&mut decoder) else {
            return error("Bad Arguments", "Mouse cursor arguments are malformed.");
        };
        if !decoder.is_finished() {
            return error("Bad Arguments", "Mouse cursor request has trailing data.");
        }
        if arguments.device < 0 {
            return error("Bad Arguments", "Mouse cursor device must be non-negative.");
        }
        let Some(shape) = cursor_shape_for_flutter_kind(arguments.kind) else {
            return error("Bad Arguments", "Mouse cursor kind is not supported.");
        };

        self.pending_shape = Some(shape);
        success()
    }

    pub(super) fn take_request(&mut self) -> Option<&'static str> {
        self.pending_shape.take()
    }
}

fn decode_cursor_arguments<'a>(
    decoder: &mut StandardDecoder<'a>,
) -> Result<CursorArguments<'a>, ()> {
    if decoder.read_map_size()? != 2 {
        return Err(());
    }
    let mut device = None;
    let mut kind = None;
    for _ in 0..2 {
        match decoder.read_string_value()? {
            "device" if device.is_none() => device = Some(decoder.read_integer_value()?),
            "kind" if kind.is_none() => kind = Some(decoder.read_string_value()?),
            _ => return Err(()),
        }
    }
    Ok(CursorArguments {
        device: device.ok_or(())?,
        kind: kind.ok_or(())?,
    })
}

struct StandardDecoder<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> StandardDecoder<'a> {
    const fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    fn is_finished(&self) -> bool {
        self.offset == self.data.len()
    }

    fn read_byte(&mut self) -> Result<u8, ()> {
        let byte = *self.data.get(self.offset).ok_or(())?;
        self.offset += 1;
        Ok(byte)
    }

    fn read_exact<const N: usize>(&mut self) -> Result<[u8; N], ()> {
        let end = self.offset.checked_add(N).ok_or(())?;
        let bytes = self.data.get(self.offset..end).ok_or(())?;
        self.offset = end;
        bytes.try_into().map_err(|_| ())
    }

    fn read_size(&mut self) -> Result<usize, ()> {
        match self.read_byte()? {
            254 => Ok(usize::from(u16::from_ne_bytes(self.read_exact()?))),
            255 => usize::try_from(u32::from_ne_bytes(self.read_exact()?)).map_err(|_| ()),
            size => Ok(usize::from(size)),
        }
    }

    fn read_string_value(&mut self) -> Result<&'a str, ()> {
        if self.read_byte()? != VALUE_STRING {
            return Err(());
        }
        let length = self.read_size()?;
        let end = self.offset.checked_add(length).ok_or(())?;
        let bytes = self.data.get(self.offset..end).ok_or(())?;
        self.offset = end;
        str::from_utf8(bytes).map_err(|_| ())
    }

    fn read_integer_value(&mut self) -> Result<i64, ()> {
        match self.read_byte()? {
            VALUE_INT32 => Ok(i64::from(i32::from_ne_bytes(self.read_exact()?))),
            VALUE_INT64 => Ok(i64::from_ne_bytes(self.read_exact()?)),
            _ => Err(()),
        }
    }

    fn read_map_size(&mut self) -> Result<usize, ()> {
        if self.read_byte()? != VALUE_MAP {
            return Err(());
        }
        self.read_size()
    }
}

fn cursor_shape_for_flutter_kind(kind: &str) -> Option<&'static str> {
    Some(match kind {
        "none" => "none",
        "basic" => "default",
        "click" => "pointer",
        "forbidden" => "not-allowed",
        "wait" => "wait",
        "progress" => "progress",
        "contextMenu" => "context-menu",
        "help" => "help",
        "text" => "text",
        "verticalText" => "vertical-text",
        "cell" => "cell",
        "precise" => "crosshair",
        "move" => "move",
        "grab" => "grab",
        "grabbing" => "grabbing",
        "noDrop" => "no-drop",
        "alias" => "alias",
        "copy" => "copy",
        "disappearing" => "default",
        "allScroll" => "all-scroll",
        "resizeLeftRight" => "ew-resize",
        "resizeUpDown" => "ns-resize",
        "resizeUpLeftDownRight" => "nwse-resize",
        "resizeUpRightDownLeft" => "nesw-resize",
        "resizeUp" => "n-resize",
        "resizeDown" => "s-resize",
        "resizeLeft" => "w-resize",
        "resizeRight" => "e-resize",
        "resizeUpLeft" => "nw-resize",
        "resizeUpRight" => "ne-resize",
        "resizeDownLeft" => "sw-resize",
        "resizeDownRight" => "se-resize",
        "resizeColumn" => "col-resize",
        "resizeRow" => "row-resize",
        "zoomIn" => "zoom-in",
        "zoomOut" => "zoom-out",
        "handwriting" => "handwriting",
        "person" => "person",
        "pin" => "pin",
        _ => return None,
    })
}

fn success() -> Vec<u8> {
    vec![SUCCESS_ENVELOPE, VALUE_NULL]
}

fn error(code: &str, message: &str) -> Vec<u8> {
    let mut response = Vec::with_capacity(code.len() + message.len() + 8);
    response.push(ERROR_ENVELOPE);
    write_string_value(&mut response, code);
    write_string_value(&mut response, message);
    response.push(VALUE_NULL);
    response
}

fn write_string_value(output: &mut Vec<u8>, value: &str) {
    output.push(VALUE_STRING);
    write_size(output, value.len());
    output.extend_from_slice(value.as_bytes());
}

fn write_size(output: &mut Vec<u8>, size: usize) {
    if size < 254 {
        output.push(size as u8);
    } else if let Ok(size) = u16::try_from(size) {
        output.push(254);
        output.extend_from_slice(&size.to_ne_bytes());
    } else {
        let size = u32::try_from(size).expect("bounded platform response length fits u32");
        output.push(255);
        output.extend_from_slice(&size.to_ne_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, device: i64, kind: &str) -> Vec<u8> {
        let mut request = Vec::new();
        write_string_value(&mut request, method);
        request.extend_from_slice(&[VALUE_MAP, 2]);
        write_string_value(&mut request, "device");
        if let Ok(device) = i32::try_from(device) {
            request.push(VALUE_INT32);
            request.extend_from_slice(&device.to_ne_bytes());
        } else {
            request.push(VALUE_INT64);
            request.extend_from_slice(&device.to_ne_bytes());
        }
        write_string_value(&mut request, "kind");
        write_string_value(&mut request, kind);
        request
    }

    #[test]
    fn accepts_flutter_standard_method_codec_requests_and_replies() {
        let mut plugin = MouseCursorPlugin::default();
        let request = b"\x07\x14activateSystemCursor\
            \x0d\x02\
            \x07\x06device\x03\x00\x00\x00\x00\
            \x07\x04kind\x07\x05click";

        assert_eq!(
            plugin.handle_platform_message(request),
            [SUCCESS_ENVELOPE, VALUE_NULL]
        );
        assert_eq!(plugin.take_request(), Some("pointer"));
    }

    #[test]
    fn accepts_standard_and_shell_cursor_requests_last_writer_wins() {
        let mut plugin = MouseCursorPlugin::default();

        assert_eq!(
            plugin.handle_platform_message(&call(ACTIVATE_SYSTEM_CURSOR, 0, "click")),
            [SUCCESS_ENVELOPE, VALUE_NULL]
        );
        assert_eq!(
            plugin.handle_platform_message(&call(ACTIVATE_SYSTEM_CURSOR, 0, "handwriting")),
            [SUCCESS_ENVELOPE, VALUE_NULL]
        );
        assert_eq!(plugin.take_request(), Some("handwriting"));
        assert_eq!(plugin.take_request(), None);
    }

    #[test]
    fn normalizes_flutter_resize_names_to_protocol_cursor_shapes() {
        assert_eq!(
            cursor_shape_for_flutter_kind("resizeUpLeftDownRight"),
            Some("nwse-resize")
        );
        assert_eq!(
            cursor_shape_for_flutter_kind("resizeColumn"),
            Some("col-resize")
        );
    }

    #[test]
    fn rejects_invalid_cursor_requests_without_replacing_pending_state() {
        let mut plugin = MouseCursorPlugin::default();
        plugin.handle_platform_message(&call(ACTIVATE_SYSTEM_CURSOR, 0, "text"));

        let mut trailing = call(ACTIVATE_SYSTEM_CURSOR, 0, "click");
        trailing.push(0);
        for request in [
            call(ACTIVATE_SYSTEM_CURSOR, -1, "click"),
            call(ACTIVATE_SYSTEM_CURSOR, 0, "unknown"),
            trailing,
            b"{\"method\":\"activateSystemCursor\"}".to_vec(),
        ] {
            let response = plugin.handle_platform_message(&request);
            assert_eq!(response.first(), Some(&ERROR_ENVELOPE));
            assert_ne!(response, b"[\"Bad Arguments\"]");
        }
        assert_eq!(plugin.take_request(), Some("text"));
    }

    #[test]
    fn unknown_methods_remain_unimplemented() {
        let mut plugin = MouseCursorPlugin::default();
        assert!(
            plugin
                .handle_platform_message(&call("MouseCursor.unknown", 0, "basic"))
                .is_empty()
        );
    }
}
