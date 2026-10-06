//! Privileged DMA-BUF fingerprint presentation and local panel illumination.

use std::error::Error;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Deserialize;
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::allocator::{Buffer as AllocatorBuffer, Fourcc};
use smithay::backend::drm::{DrmDevice, DrmDeviceFd};
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::renderer::{ExportMem, ImportDma};
use smithay::reexports::drm::control::{Device as ControlDevice, connector, property};
use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};
use smithay::utils::Rectangle;
use smithay::wayland::dmabuf::get_dmabuf;
use tracing::{info, warn};

use super::flutter_runtime::{FlutterRuntime, ShmTextureFrame};
use super::kms_state::Scanout;
use super::{OutputId, RuntimeState};

#[path = "fingerprint_presentation/state.rs"]
mod state;
use state::{Phase, Session, StopReason};

pub mod protocol {
    pub mod server {
        #![allow(
            dead_code,
            non_camel_case_types,
            non_upper_case_globals,
            non_snake_case,
            unused_imports,
            unused_unsafe,
            unused_variables,
            clippy::all,
            missing_docs
        )]
        use wayland_server;
        use wayland_server::protocol::*;
        pub mod __interfaces {
            use wayland_server::backend as wayland_backend;
            use wayland_server::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/denial-fingerprint-v1.xml");
        }
        use self::__interfaces::*;
        wayland_scanner::generate_server_code!("protocol/denial-fingerprint-v1.xml");
    }
}

use protocol::server::denial_fingerprint_manager_v1::{
    self as manager, DenialFingerprintManagerV1,
};
use protocol::server::denial_fingerprint_session_v1::{
    self as session, DenialFingerprintSessionV1,
};

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Profile {
    sensor: String,
    output: String,
    panel_name: String,
    panel_width: u32,
    panel_height: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    max_duration_ms: u32,
    settle_ms: u32,
    illumination_property: String,
    illumination_on: u64,
    illumination_off: u64,
}

impl Profile {
    fn validate(&self) -> Result<(), &'static str> {
        if self.sensor.is_empty()
            || self.output.is_empty()
            || self.panel_name.is_empty()
            || self.x < 0
            || self.y < 0
            || self.width == 0
            || self.height == 0
            || self.width > 1024
            || self.height > 1024
            || self.panel_width > u16::MAX.into()
            || self.panel_height > u16::MAX.into()
            || (self.x as u32)
                .checked_add(self.width)
                .is_none_or(|v| v > self.panel_width)
            || (self.y as u32)
                .checked_add(self.height)
                .is_none_or(|v| v > self.panel_height)
            || !(100..=30_000).contains(&self.max_duration_ms)
            || self.settle_ms > 1000
            || self.settle_ms >= self.max_duration_ms
            || self.illumination_property.is_empty()
            || self.illumination_on == self.illumination_off
        {
            return Err("invalid fingerprint profile geometry or illumination policy");
        }
        Ok(())
    }

    fn load(path: &Path) -> Result<Self, Box<dyn Error>> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.is_file()
            || metadata.uid() != 0
            || metadata.mode() & 0o022 != 0
            || metadata.len() > 8192
        {
            return Err("fingerprint profile must be a root-owned, protected regular file".into());
        }
        let profile: Self = serde_json::from_slice(&fs::read(path)?)?;
        profile.validate()?;
        Ok(profile)
    }
}

pub(super) struct GlobalData {
    display: DisplayHandle,
    profile: Arc<Profile>,
}

pub(super) fn init(display: &DisplayHandle) {
    let path = Path::new("/etc/denial/fingerprint.json");
    if !path.exists() {
        return;
    }
    match Profile::load(path) {
        Ok(profile) => {
            display.create_global::<RuntimeState, DenialFingerprintManagerV1, _>(
                1,
                GlobalData {
                    display: display.clone(),
                    profile: Arc::new(profile),
                },
            );
            info!("enabled privileged fingerprint presentation protocol");
        }
        Err(error) => warn!(%error, "fingerprint presentation profile rejected"),
    }
}

fn authorized(client: &Client, _display: &DisplayHandle) -> bool {
    super::wayland_frontend::is_root_client(client)
}

impl GlobalDispatch<DenialFingerprintManagerV1, GlobalData> for RuntimeState {
    fn can_view(client: Client, data: &GlobalData) -> bool {
        authorized(&client, &data.display)
    }

    fn bind(
        _state: &mut Self,
        handle: &DisplayHandle,
        client: &Client,
        resource: New<DenialFingerprintManagerV1>,
        data: &GlobalData,
        init: &mut DataInit<'_, Self>,
    ) {
        let resource = init.init(resource, data.profile.clone());
        if !authorized(client, handle) {
            resource.post_error(
                manager::Error::Unauthorized,
                "fingerprint presentation requires the system service",
            );
        }
    }
}

impl Dispatch<DenialFingerprintManagerV1, Arc<Profile>> for RuntimeState {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &DenialFingerprintManagerV1,
        request: manager::Request,
        profile: &Arc<Profile>,
        handle: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        match request {
            manager::Request::Destroy => {}
            manager::Request::GetSession { id, sensor } => {
                if !authorized(client, handle) {
                    init.post_error(
                        id,
                        manager::Error::Unauthorized as u32,
                        "unauthorized fingerprint client",
                    );
                    return;
                }
                if sensor != profile.sensor {
                    init.post_error(
                        id,
                        manager::Error::InvalidSensor as u32,
                        "unknown sensor profile",
                    );
                    return;
                }
                if state
                    .fingerprint
                    .resource
                    .as_ref()
                    .is_some_and(Resource::is_alive)
                    || state.fingerprint.session.contact.is_some()
                {
                    init.post_error(
                        id,
                        manager::Error::Busy as u32,
                        "fingerprint presentation is occupied",
                    );
                    return;
                }
                let session = init.init(id, ());
                state
                    .fingerprint
                    .session
                    .new_client()
                    .expect("checked idle presentation");
                state.fingerprint.profile = Some(profile.clone());
                state.fingerprint.display = Some(handle.clone());
                state.fingerprint.resource = Some(session.clone());
                session.configured(
                    profile.output.clone(),
                    profile.panel_width,
                    profile.panel_height,
                    profile.x,
                    profile.y,
                    profile.width,
                    profile.height,
                    profile.max_duration_ms,
                );
            }
        }
        let _ = resource;
    }
}

impl Dispatch<DenialFingerprintSessionV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &DenialFingerprintSessionV1,
        request: session::Request,
        _data: &(),
        _handle: &DisplayHandle,
        _init: &mut DataInit<'_, Self>,
    ) {
        if state.fingerprint.resource.as_ref() != Some(resource) {
            return;
        }
        let controller = &mut state.fingerprint;
        match request {
            session::Request::Destroy => controller.session.stop(StopReason::Revoked),
            session::Request::Withdraw { serial } => {
                if let Err(error) = controller.session.withdraw(serial) {
                    resource.post_error(session::Error::InvalidSerial, error);
                }
            }
            session::Request::Present {
                serial,
                buffer,
                x,
                y,
                width,
                height,
            } => {
                let profile = controller.profile.as_ref().expect("session has a profile");
                if (x, y, width, height) != (profile.x, profile.y, profile.width, profile.height) {
                    resource.post_error(
                        session::Error::InvalidGeometry,
                        "image must cover the configured sensor rectangle",
                    );
                    return;
                }
                let Ok(dmabuf) = get_dmabuf(&buffer).cloned() else {
                    resource.post_error(
                        session::Error::InvalidBuffer,
                        "fingerprint image must be a DMA-BUF",
                    );
                    return;
                };
                if dmabuf.size() != (width as i32, height as i32).into()
                    || !matches!(dmabuf.format().code, Fourcc::Argb8888 | Fourcc::Xrgb8888)
                {
                    resource.post_error(
                        session::Error::InvalidBuffer,
                        "unsupported fingerprint image dimensions or format",
                    );
                    return;
                }
                match controller.session.begin(
                    serial,
                    Instant::now(),
                    Duration::from_millis(profile.max_duration_ms.into()),
                    false,
                ) {
                    Ok(_) => {
                        controller.image = Some((buffer, dmabuf));
                        controller.texture_registered = false;
                        controller.visual_until = None;
                        controller.retain_after_stop = true;
                        controller.hbm = None;
                        controller.prepared = false;
                        controller.reveal_home = false;
                        controller.fade_target = false;
                    }
                    Err(error) => resource.post_error(session::Error::InvalidState, error),
                }
            }
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        resource: &DenialFingerprintSessionV1,
        _data: &(),
    ) {
        if state.fingerprint.resource.as_ref() == Some(resource) {
            state.fingerprint.session.stop(StopReason::Revoked);
            state.fingerprint.resource = None;
        }
    }
}

struct IlluminationRestore {
    drm: DrmDeviceFd,
    connector: connector::Handle,
    property: property::Handle,
    value: u64,
}

impl IlluminationRestore {
    fn restore(&self) -> std::io::Result<()> {
        self.drm
            .set_property(self.connector, self.property, self.value)
    }
}

impl Drop for IlluminationRestore {
    fn drop(&mut self) {
        if let Err(error) = self.restore() {
            warn!(%error, "could not restore fingerprint illumination during teardown");
        }
    }
}

#[derive(Default)]
pub(super) struct Controller {
    display: Option<DisplayHandle>,
    profile: Option<Arc<Profile>>,
    resource: Option<DenialFingerprintSessionV1>,
    session: Session,
    image: Option<(WlBuffer, Dmabuf)>,
    output: Option<OutputId>,
    hbm: Option<(connector::Handle, property::Handle, u64)>,
    prepared: bool,
    illumination_restore: Option<IlluminationRestore>,
    texture_registered: bool,
    layout_key: Option<(u64, bool, bool, bool, bool)>,
    layout_epoch: u64,
    reveal_home: bool,
    fade_target: bool,
    // Presentation-only pixels may bridge the brief fprintd/PAM handoff.
    // The single cached image remains compositor-owned when the client exits.
    visual_until: Option<Instant>,
    retain_after_stop: bool,
    ambient_until: Option<Instant>,
}

impl Controller {
    pub(super) fn active(&self) -> bool {
        self.session.contact.is_some() || self.ambient_until.is_some()
    }

    pub(super) fn exclusive_for(&self, output: OutputId) -> bool {
        self.output == Some(output) && self.ambient_until.is_some()
    }

    pub(super) fn epoch_for(&self, output: OutputId) -> u64 {
        if self.output == Some(output) {
            self.layout_epoch
        } else {
            0
        }
    }

    pub(super) fn presented(&mut self, output: OutputId, epoch: u64) {
        if self.output == Some(output) && epoch == self.layout_epoch && epoch != 0 {
            self.session.presented(self.session.epoch());
        }
    }

    pub(super) fn independent_wake(&mut self) {
        self.ambient_until = None;
        self.reveal_home = false;
        self.fade_target = false;
        self.visual_until = None;
        self.retain_after_stop = false;
        self.session.independent_wake();
        self.session.stop(StopReason::Revoked);
    }

    pub(super) fn unlocked(&mut self) {
        let visual = self.visual_until.is_some();
        let reveal = self.ambient_until.is_some();
        self.independent_wake();
        self.reveal_home = reveal;
        self.fade_target = visual;
        if visual {
            // Flutter owns the 220 ms animation. This bound only removes a
            // stale scene if it never receives/finishes the authentication UI.
            self.visual_until = Some(Instant::now() + Duration::from_secs(1));
        }
    }

    pub(super) fn authenticated_wake(&mut self) {
        // Keep Flutter's black scene until the trusted authentication boundary
        // becomes unlocked, so no lock-screen flash precedes the home fade.
        self.session.independent_wake();
        if self.ambient_until.is_some() {
            self.ambient_until = Some(Instant::now() + Duration::from_secs(3));
        }
    }

    fn release_image(&mut self) {
        if let Some((buffer, _)) = self.image.take() {
            if buffer.is_alive() {
                buffer.release();
            }
        }
    }

    fn prepare(&mut self, drm: &DrmDevice, scanouts: &[Scanout]) -> Result<bool, Box<dyn Error>> {
        let profile = self.profile.as_ref().ok_or("missing fingerprint profile")?;
        let scanout = scanouts
            .iter()
            .find(|s| s.output.name == profile.output)
            .ok_or("fingerprint output is absent")?;
        if scanout.output.mode.size() != (profile.panel_width as u16, profile.panel_height as u16) {
            return Err("fingerprint panel dimensions changed".into());
        }
        let panel_path = format!("/sys/class/drm/card{}-{}/panelName", 0, profile.output);
        if fs::read_to_string(panel_path)?.trim() != profile.panel_name {
            return Err("fingerprint panel identity differs from profile".into());
        }
        let mut hbm = None;
        for (property, value) in drm.get_properties(scanout.output.connector)? {
            let info = drm.get_property(property)?;
            if info.name().to_bytes() == profile.illumination_property.as_bytes() {
                if value != profile.illumination_off {
                    return Err("panel illumination is already owned by another operation".into());
                }
                hbm = Some((scanout.output.connector, property, value));
                break;
            }
        }
        self.hbm = Some(hbm.ok_or("panel lacks local fingerprint illumination")?);
        self.output = Some(scanout.output.id);
        let contact = self.session.contact.as_mut().ok_or("missing contact")?;
        contact.restore_off = !scanout.powered || self.ambient_until.is_some();
        if contact.restore_off {
            self.ambient_until = Some(Instant::now() + Duration::from_secs(3));
        }
        self.prepared = true;
        info!(
            serial = contact.serial,
            screen_off = contact.restore_off,
            "fingerprint contact prepared"
        );
        Ok(!scanout.powered)
    }

    pub(super) fn service(
        &mut self,
        drm: &DrmDevice,
        renderer: &mut GlesRenderer,
        scanouts: &[Scanout],
        runtime: &mut FlutterRuntime,
    ) -> Result<(bool, Vec<(OutputId, bool)>), Box<dyn Error>> {
        let now = Instant::now();
        if self.layout_epoch != 0 && runtime.fingerprint_scene_epoch() != self.layout_epoch {
            // A replacement Flutter runtime owns a new texture registry.
            self.texture_registered = false;
            self.visual_until = None;
            self.layout_key = None;
            self.session.stop(StopReason::Unavailable);
        }
        let mut power = Vec::new();
        if self.session.contact.is_none() {
            if self.visual_until.is_some_and(|until| now >= until) {
                self.visual_until = None;
                self.reveal_home = false;
                self.fade_target = false;
            }
            if self.ambient_until.is_some_and(|until| now >= until) {
                if let Some(output) = self.output {
                    if scanouts.iter().any(|s| s.output.id == output && s.powered) {
                        power.push((output, false));
                    } else {
                        self.ambient_until = None;
                    }
                }
            }
            let changed = self.sync_scene(runtime, renderer)?;
            return Ok((changed, power));
        }
        if self.resource.as_ref().is_none_or(|r| !r.is_alive()) {
            self.session.stop(StopReason::Revoked);
        }
        if !self.prepared
            && self
                .session
                .contact
                .as_ref()
                .is_some_and(|c| c.phase != Phase::Stopping)
        {
            match self.prepare(drm, scanouts) {
                Ok(wake) => {
                    if wake {
                        power.push((self.output.unwrap(), true));
                    }
                }
                Err(error) => {
                    warn!(%error, "fingerprint presentation preparation failed");
                    self.session.stop(StopReason::Unavailable);
                }
            }
        }
        if self.prepared
            && self
                .output
                .is_some_and(|id| !scanouts.iter().any(|s| s.output.id == id))
        {
            self.session.stop(StopReason::Unavailable);
        }
        if self
            .session
            .contact
            .as_ref()
            .is_some_and(|c| now >= c.deadline)
        {
            self.session.stop(StopReason::Timeout);
        }
        if self
            .session
            .contact
            .as_ref()
            .is_some_and(|c| c.phase == Phase::Presented)
        {
            let (connector, property, _) =
                self.hbm.ok_or("presented fingerprint lacks HBM control")?;
            let profile = self.profile.as_ref().unwrap();
            self.illumination_restore = Some(IlluminationRestore {
                drm: drm.device_fd().clone(),
                connector,
                property,
                value: self.hbm.unwrap().2,
            });
            match drm.set_property(connector, property, profile.illumination_on) {
                Ok(()) => {
                    if !self.session.illumination_enabled(
                        Instant::now(),
                        Duration::from_millis(profile.settle_ms.into()),
                    ) {
                        if let Some(contact) = self.session.contact.as_mut() {
                            contact.illumination_enabled = true;
                        }
                        self.session.stop(StopReason::Timeout);
                    }
                    info!("fingerprint local illumination enabled after image scanout");
                }
                Err(error) => {
                    warn!(%error, "fingerprint local illumination failed");
                    // An unsuccessful ioctl may have partially changed hardware.
                    if let Some(contact) = self.session.contact.as_mut() {
                        contact.illumination_enabled = true;
                    }
                    self.session.stop(StopReason::Unavailable);
                }
            }
        }
        if let Some(serial) = self.session.ready(Instant::now()) {
            if let Some(resource) = self.resource.as_ref() {
                resource.ready(serial);
            }
            info!(serial, "fingerprint presentation ready for acquisition");
        }
        if self
            .session
            .contact
            .as_ref()
            .is_some_and(|c| c.phase == Phase::Stopping)
        {
            if self.session.contact.as_ref().unwrap().illumination_enabled {
                let (connector, property, original) =
                    self.hbm.ok_or("active illumination lacks restore state")?;
                // Propagate restore failure: presenting ordinary UI with an
                // unconfirmed illumination state is never an acceptable fallback.
                drm.set_property(connector, property, original)?;
                // The guard also covers an early return or renderer failure.
                self.illumination_restore.take();
                self.session.contact.as_mut().unwrap().illumination_enabled = false;
                info!("fingerprint local illumination restored");
            }
            let output_off = self.output.is_none_or(|id| {
                scanouts
                    .iter()
                    .find(|s| s.output.id == id)
                    .is_none_or(|s| !s.powered)
            });
            let contact = self.session.contact.as_ref().unwrap();
            if contact.restore_off && !output_off {
                self.ambient_until = Some(now + Duration::from_secs(3));
            }
            if self.retain_after_stop
                && self.texture_registered
                && !output_off
                && contact.stop_reason == Some(StopReason::Released)
            {
                self.visual_until = Some(now + Duration::from_millis(400));
            } else {
                self.visual_until = None;
            }
            // Flutter samples only the owned copy. Hardware cleanup and
            // wl_buffer.release therefore need not wait for a UI fade or a
            // replacement frame, and cannot block fprintd's match result.
            self.release_image();
            if let Some((serial, reason)) = self
                .session
                .finish(true, output_off || self.ambient_until.is_some())
            {
                if let Some(resource) = self.resource.as_ref() {
                    let reason = match reason {
                        StopReason::Released => session::StopReason::Released,
                        StopReason::Timeout => session::StopReason::Timeout,
                        StopReason::Unavailable => session::StopReason::Unavailable,
                        StopReason::Revoked => session::StopReason::Revoked,
                    };
                    resource.stopped(serial, reason);
                }
                info!(serial, "fingerprint presentation stopped");
            }
        }
        let changed = self.sync_scene(runtime, renderer)?;
        // Ready/stopped are generated outside Wayland request dispatch. Flush
        // them now: a stationary finger need not send another client request.
        if let Some(display) = self.display.as_mut() {
            display.flush_clients()?;
        }
        Ok((changed, power))
    }

    fn sync_scene(
        &mut self,
        runtime: &mut FlutterRuntime,
        renderer: &mut GlesRenderer,
    ) -> Result<bool, Box<dyn Error>> {
        let Some(output) = self.output else {
            return Ok(false);
        };
        let acquiring = self.prepared
            && self
                .session
                .contact
                .as_ref()
                .is_some_and(|c| c.phase != Phase::Stopping);
        let visible = acquiring || self.visual_until.is_some();
        let black = self.ambient_until.is_some();
        let key = (
            self.session.epoch(),
            black,
            visible,
            self.reveal_home,
            self.fade_target,
        );
        if self.layout_key == Some(key) {
            return Ok(false);
        }
        if acquiring && !self.texture_registered {
            let image = self
                .image
                .as_ref()
                .ok_or("fingerprint image missing")?
                .1
                .clone();
            let started = Instant::now();
            let revision = self
                .layout_epoch
                .checked_add(1)
                .ok_or("fingerprint layout epoch exhausted")?;
            let copy = match copy_presentation_image(renderer, &image, revision) {
                Ok(copy) => copy,
                Err(error) => {
                    warn!(%error, "fingerprint presentation image copy failed");
                    self.session.stop(StopReason::Unavailable);
                    self.visual_until = None;
                    return self.sync_scene(runtime, renderer);
                }
            };
            runtime.register_fingerprint_texture(copy)?;
            info!(
                copy_us = started.elapsed().as_micros() as u64,
                "fingerprint presentation image copied"
            );
            self.texture_registered = true;
        }
        self.layout_epoch = self
            .layout_epoch
            .checked_add(1)
            .ok_or("fingerprint layout epoch exhausted")?;
        let profile = self.profile.as_ref().ok_or("fingerprint profile missing")?;
        runtime.set_fingerprint_scene(
            output,
            self.layout_epoch,
            black,
            visible,
            self.reveal_home,
            self.fade_target,
            [
                profile.x as f64,
                profile.y as f64,
                profile.width as f64,
                profile.height as f64,
            ],
            [profile.panel_width as f64, profile.panel_height as f64],
        )?;
        self.layout_key = Some(key);
        Ok(true)
    }
}

fn copy_presentation_image(
    renderer: &mut GlesRenderer,
    image: &Dmabuf,
    revision: u64,
) -> Result<ShmTextureFrame, Box<dyn Error>> {
    let size = image.size();
    let texture = renderer.import_dmabuf(image, None)?;
    let mapping = renderer.copy_texture(&texture, Rectangle::from_size(size), Fourcc::Abgr8888)?;
    let mut rgba = renderer.map_texture(&mapping)?.to_vec();
    normalize_presentation_pixels(
        &mut rgba,
        size.w as usize,
        size.h as usize,
        image.y_inverted(),
        image.format().code == Fourcc::Xrgb8888,
    )?;
    Ok(ShmTextureFrame::new_owned(
        size.w as u32,
        size.h as u32,
        revision,
        rgba,
    )?)
}

fn normalize_presentation_pixels(
    rgba: &mut [u8],
    width: usize,
    height: usize,
    inverted: bool,
    opaque: bool,
) -> Result<(), &'static str> {
    let row = width.checked_mul(4).ok_or("presentation row overflow")?;
    if row == 0 || height == 0 || row.checked_mul(height) != Some(rgba.len()) {
        return Err("invalid presentation copy size");
    }
    if inverted {
        for y in 0..height / 2 {
            let (top, bottom) = rgba.split_at_mut((height - 1 - y) * row);
            top[y * row..(y + 1) * row].swap_with_slice(&mut bottom[..row]);
        }
    }
    if opaque {
        for pixel in rgba.chunks_exact_mut(4) {
            pixel[3] = 255;
        }
    }
    Ok(())
}

#[cfg(test)]
mod protocol_tests {
    use super::*;
    use smithay::reexports::wayland_server::Display;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;

    #[test]
    fn presentation_copy_preserves_color_alpha_and_normalizes_orientation() {
        let original = vec![1, 2, 3, 4, 5, 6, 7, 8];
        let mut pixels = original.clone();
        normalize_presentation_pixels(&mut pixels, 1, 2, false, false).unwrap();
        assert_eq!(pixels, original);
        normalize_presentation_pixels(&mut pixels, 1, 2, true, true).unwrap();
        assert_eq!(pixels, [5, 6, 7, 255, 1, 2, 3, 255]);
        assert!(normalize_presentation_pixels(&mut pixels, 2, 2, false, false).is_err());
        assert!(normalize_presentation_pixels(&mut pixels, usize::MAX, 1, false, false).is_err());
    }

    #[test]
    fn trusted_unlock_retains_visual_but_independent_wake_clears_it() {
        let mut controller = Controller::default();
        controller.visual_until = Some(Instant::now() + Duration::from_millis(400));
        controller.ambient_until = Some(Instant::now() + Duration::from_secs(3));
        controller.unlocked();
        assert!(controller.reveal_home);
        assert!(controller.visual_until.is_some());
        assert!(controller.ambient_until.is_none());
        controller.independent_wake();
        assert!(!controller.reveal_home);
        assert!(controller.visual_until.is_none());
    }

    #[test]
    fn awake_unlock_fades_target_without_replacing_normal_home_motion() {
        let mut controller = Controller::default();
        controller.visual_until = Some(Instant::now() + Duration::from_millis(400));
        controller.unlocked();
        assert!(controller.fade_target);
        assert!(!controller.reveal_home);
        assert!(controller.visual_until.is_some());
    }

    #[test]
    fn registry_filter_uses_cached_identity_without_reentering_backend_lock() {
        let (done, result) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            for uid in [Some(0), Some(1000), None] {
                let mut display = Display::<RuntimeState>::new().unwrap();
                let mut handle = display.handle();
                let profile: Profile = serde_json::from_str(
                    r#"{
                    "sensor":"test", "output":"DSI-1", "panel_name":"test",
                    "panel_width":1220, "panel_height":2712, "x":508, "y":2338,
                    "width":204, "height":204, "max_duration_ms":10000, "settle_ms":100,
                    "illumination_property":"HBM", "illumination_on":2, "illumination_off":0
                }"#,
                )
                .unwrap();
                handle.create_global::<RuntimeState, DenialFingerprintManagerV1, _>(
                    1,
                    GlobalData {
                        display: handle.clone(),
                        profile: Arc::new(profile),
                    },
                );
                let (mut client, server) = UnixStream::pair().unwrap();
                client
                    .set_read_timeout(Some(Duration::from_secs(1)))
                    .unwrap();
                handle
                    .insert_client(
                        server,
                        super::super::wayland_frontend::fingerprint_test_client(uid),
                    )
                    .unwrap();
                // wl_display.get_registry(new_id=2), then sync(new_id=3).
                for word in [1u32, (12 << 16) | 1, 2, 1, 12 << 16, 3] {
                    client.write_all(&word.to_ne_bytes()).unwrap();
                }
                display
                    .dispatch_clients(&mut RuntimeState::default())
                    .unwrap();
                display.flush_clients().unwrap();
                let mut bytes = [0u8; 4096];
                let length = client.read(&mut bytes).unwrap();
                let interface = b"denial_fingerprint_manager_v1";
                let advertised = bytes[..length]
                    .windows(interface.len())
                    .any(|part| part == interface);
                assert_eq!(advertised, uid == Some(0));
            }
            done.send(()).unwrap();
        });
        result
            .recv_timeout(Duration::from_secs(3))
            .expect("Wayland registry dispatch deadlocked");
        worker.join().unwrap();
    }
}
