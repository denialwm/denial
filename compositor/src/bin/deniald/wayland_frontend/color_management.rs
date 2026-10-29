//! `wp_color_management_v1` and `wp_color_representation_v1`.
//!
//! Clients describe their pixels with parametric image descriptions; the
//! renderer converts each tagged surface into the scene. Outputs and surface
//! feedback describe what the scene expects, so a client that renders in it
//! skips the conversion. ICC profiles are not supported.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, PoisonError};

use denial_core::topology::OutputId;
use smithay::output::Output;
use smithay::reexports::wayland_protocols::wp::color_management::v1::server::{
    wp_color_management_output_v1::{self, WpColorManagementOutputV1},
    wp_color_management_surface_feedback_v1::{self, WpColorManagementSurfaceFeedbackV1},
    wp_color_management_surface_v1::{self, WpColorManagementSurfaceV1},
    wp_color_manager_v1::{self, WpColorManagerV1},
    wp_image_description_creator_icc_v1::{self, WpImageDescriptionCreatorIccV1},
    wp_image_description_creator_params_v1::{self, WpImageDescriptionCreatorParamsV1},
    wp_image_description_info_v1::WpImageDescriptionInfoV1,
    wp_image_description_v1::{self, WpImageDescriptionV1},
};
use smithay::reexports::wayland_protocols::wp::color_representation::v1::server::{
    wp_color_representation_manager_v1::{self, WpColorRepresentationManagerV1},
    wp_color_representation_surface_v1::{self, WpColorRepresentationSurfaceV1},
};
use smithay::reexports::wayland_server::protocol::{wl_output::WlOutput, wl_surface::WlSurface};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, Weak,
    backend::GlobalId,
};
use smithay::wayland::compositor::{Cacheable, with_states};
use tracing::info;

use super::{RuntimeState, WaylandFrontend};
use crate::color_space::{
    AlphaMode, Chromaticities, DescriptionRecord, ImageDescription, Luminances, NAMED_PRIMARIES,
    RenderIntent, SurfaceColor, TransferFunction, named_primaries, named_transfer_functions, tf,
};

const COLOR_MANAGER_VERSION: u32 = 3;
const COLOR_REPRESENTATION_VERSION: u32 = 1;

/// The intents Denial honours, as protocol values.
const INTENTS: [u32; 2] = [0, 1];
/// `wp_color_manager_v1.feature`: parametric with every setter, extended
/// target volumes, and the two Windows encodings.
const FEATURES: [u32; 7] = [1, 2, 3, 4, 5, 6, 7];
const FEATURE_WINDOWS_BT2100: u32 = 8;

pub(super) struct ColorManagement {
    _manager: GlobalId,
    _representation: GlobalId,
    /// What each output expects.
    outputs: BTreeMap<OutputId, Arc<DescriptionRecord>>,
    /// What a surface on no output is preferred to use.
    fallback: Arc<DescriptionRecord>,
    output_objects: Vec<WpColorManagementOutputV1>,
    feedbacks: Vec<WpColorManagementSurfaceFeedbackV1>,
    /// Information objects whose `done` waits for the end of dispatch: it
    /// destroys the object, which must not happen in the request creating it.
    unfinished_information: Vec<WpImageDescriptionInfoV1>,
}

impl ColorManagement {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _manager: display
                .create_global::<RuntimeState, WpColorManagerV1, _>(COLOR_MANAGER_VERSION, ()),
            _representation: display
                .create_global::<RuntimeState, WpColorRepresentationManagerV1, _>(
                    COLOR_REPRESENTATION_VERSION,
                    (),
                ),
            outputs: BTreeMap::new(),
            fallback: DescriptionRecord::new(ImageDescription::srgb(), true),
            output_objects: Vec::new(),
            feedbacks: Vec::new(),
            unfinished_information: Vec::new(),
        }
    }

    fn output(&self, output: Option<OutputId>) -> Option<&Arc<DescriptionRecord>> {
        output.and_then(|output| self.outputs.get(&output))
    }
}

/// Double-buffered color state of one surface.
#[derive(Clone, Debug, Default)]
pub(crate) struct SurfaceColorState {
    description: Option<(Arc<DescriptionRecord>, RenderIntent)>,
    alpha: AlphaMode,
    coefficients: Option<(u32, u32)>,
    chroma_location: Option<u32>,
    /// What the renderer sees: None while the surface says nothing.
    color: Option<Arc<SurfaceColor>>,
}

impl SurfaceColorState {
    /// Keeps the previous Arc while nothing changed in value, so clients that
    /// set the same description every frame cause no conversion work.
    fn refresh(&mut self) {
        let color = (self.description.is_some() || self.alpha != AlphaMode::default()).then(|| {
            SurfaceColor {
                description: self.description.clone(),
                alpha: self.alpha,
            }
        });
        if self.color.as_deref() != color.as_ref() {
            self.color = color.map(Arc::new);
        }
    }
}

impl Cacheable for SurfaceColorState {
    fn commit(&mut self, _display: &DisplayHandle) -> Self {
        self.clone()
    }

    fn merge_into(self, into: &mut Self, _display: &DisplayHandle) {
        *into = self;
    }
}

/// The committed color of a surface, for its texture frames.
pub(crate) fn surface_color(
    states: &smithay::wayland::compositor::SurfaceData,
) -> Option<Arc<SurfaceColor>> {
    let mut cached = states.cached_state.get::<SurfaceColorState>();
    cached.current().color.clone()
}

fn update_pending(surface: &WlSurface, change: impl FnOnce(&mut SurfaceColorState)) {
    with_states(surface, |states| {
        let mut cached = states.cached_state.get::<SurfaceColorState>();
        let pending = cached.pending();
        change(pending);
        pending.refresh();
    });
}

/// Which extension objects a surface already has: each may exist once.
#[derive(Default)]
struct SurfaceExtensions {
    management: bool,
    representation: bool,
}

fn claim_extension(
    surface: &WlSurface,
    claim: impl FnOnce(&mut SurfaceExtensions) -> &mut bool,
) -> bool {
    with_states(surface, |states| {
        states
            .data_map
            .insert_if_missing_threadsafe(|| Mutex::new(SurfaceExtensions::default()));
        let mut extensions = states
            .data_map
            .get::<Mutex<SurfaceExtensions>>()
            .expect("surface extensions were just inserted")
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let slot = claim(&mut extensions);
        !std::mem::replace(slot, true)
    })
}

fn release_extension(
    surface: &WlSurface,
    release: impl FnOnce(&mut SurfaceExtensions) -> &mut bool,
) {
    with_states(surface, |states| {
        if let Some(extensions) = states.data_map.get::<Mutex<SurfaceExtensions>>() {
            *release(&mut extensions.lock().unwrap_or_else(PoisonError::into_inner)) = false;
        }
    });
}

pub(super) struct OutputObject {
    output: Option<OutputId>,
    wl_output: WlOutput,
}

pub(super) struct SurfaceObject {
    surface: Weak<WlSurface>,
}

pub(super) struct FeedbackObject {
    surface: Weak<WlSurface>,
    /// The preferred identity last announced.
    preferred: Mutex<u64>,
}

/// A `wp_image_description_v1`: ready with its record, or failed.
pub(super) struct DescriptionObject(Option<Arc<DescriptionRecord>>);

#[derive(Default)]
pub(super) struct ParamsBuilder {
    tf: Option<TransferFunction>,
    primaries: Option<(Chromaticities, Option<u32>)>,
    luminances: Option<Luminances>,
    mastering_primaries: Option<Chromaticities>,
    mastering_luminance: Option<(f64, f64)>,
    max_cll: Option<f64>,
    max_fall: Option<f64>,
}

impl WaylandFrontend {
    /// Finish the information objects created during this dispatch.
    pub(super) fn finish_color_information(&mut self) {
        for info in self.color_management.unfinished_information.drain(..) {
            if info.is_alive() {
                info.done();
            }
        }
    }

    /// Recompute what every output expects and tell the clients that watch a
    /// changed one. Every SDR output expects the sRGB scene.
    pub(super) fn refresh_color_outputs(&mut self) {
        let ids = self
            .outputs
            .iter()
            .map(|entry| entry.id)
            .collect::<Vec<_>>();
        let color = &mut self.color_management;
        color.outputs.retain(|id, _| ids.contains(id));
        let mut changed = Vec::new();
        for id in ids {
            let description = ImageDescription::srgb();
            if color
                .outputs
                .get(&id)
                .is_some_and(|record| record.description == description)
            {
                continue;
            }
            color
                .outputs
                .insert(id, DescriptionRecord::new(description, true));
            changed.push(id);
        }
        color.output_objects.retain(Resource::is_alive);
        for object in &color.output_objects {
            let Some(data) = object.data::<OutputObject>() else {
                continue;
            };
            if data.output.is_some_and(|output| changed.contains(&output)) {
                object.image_description_changed();
                if data.wl_output.version() >= 2 {
                    data.wl_output.done();
                }
            }
        }
        self.refresh_color_feedback();
    }

    /// Announce a new preferred description to surfaces whose output changed.
    pub(super) fn refresh_color_feedback(&mut self) {
        self.color_management.feedbacks.retain(Resource::is_alive);
        for feedback in &self.color_management.feedbacks {
            let Some(data) = feedback.data::<FeedbackObject>() else {
                continue;
            };
            let Ok(surface) = data.surface.upgrade() else {
                continue;
            };
            let identity = self.preferred_description(&surface).identity;
            let mut last = data
                .preferred
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if std::mem::replace(&mut *last, identity) != identity {
                send_preferred_changed(feedback, identity);
            }
        }
    }

    fn preferred_description(&self, surface: &WlSurface) -> Arc<DescriptionRecord> {
        let color = &self.color_management;
        color
            .output(self.surface_output_id(surface))
            .or_else(|| color.outputs.values().next())
            .unwrap_or(&color.fallback)
            .clone()
    }

    fn color_output_id(&self, wl_output: &WlOutput) -> Option<OutputId> {
        let output = Output::from_resource(wl_output)?;
        self.outputs
            .iter()
            .find(|entry| entry.output == output)
            .map(|entry| entry.id)
    }
}

fn send_preferred_changed(feedback: &WpColorManagementSurfaceFeedbackV1, identity: u64) {
    if feedback.version() >= 2 {
        feedback.preferred_changed2((identity >> 32) as u32, identity as u32);
    } else {
        feedback.preferred_changed(identity as u32);
    }
}

fn init_description(
    data_init: &mut DataInit<'_, RuntimeState>,
    id: New<WpImageDescriptionV1>,
    record: Option<Arc<DescriptionRecord>>,
    failure: (wp_image_description_v1::Cause, &str),
) {
    let resource = data_init.init(id, DescriptionObject(record.clone()));
    match record {
        Some(record) if resource.version() >= 2 => {
            resource.ready2((record.identity >> 32) as u32, record.identity as u32);
        }
        Some(record) => resource.ready(record.identity as u32),
        None => resource.failed(failure.0, failure.1.to_owned()),
    }
}

impl GlobalDispatch<WpColorManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<WpColorManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        let manager = data_init.init(resource, ());
        let version = manager.version();
        for intent in INTENTS {
            if let Ok(intent) = intent.try_into() {
                manager.supported_intent(intent);
            }
        }
        let windows_bt2100 = (version >= 3).then_some(FEATURE_WINDOWS_BT2100);
        for feature in FEATURES.into_iter().chain(windows_bt2100) {
            if let Ok(feature) = feature.try_into() {
                manager.supported_feature(feature);
            }
        }
        for name in named_transfer_functions(version) {
            if let Ok(name) = name.try_into() {
                manager.supported_tf_named(name);
            }
        }
        for name in NAMED_PRIMARIES {
            if let Ok(name) = name.try_into() {
                manager.supported_primaries_named(name);
            }
        }
        manager.done();
    }
}

impl Dispatch<WpColorManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &WpColorManagerV1,
        request: wp_color_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_manager_v1::Request;
        match request {
            Request::GetOutput { id, output } => {
                let output_id = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.color_output_id(&output));
                let object = data_init.init(
                    id,
                    OutputObject {
                        output: output_id,
                        wl_output: output,
                    },
                );
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.color_management.output_objects.push(object);
                }
            }
            Request::GetSurface { id, surface } => {
                if !claim_extension(&surface, |extensions| &mut extensions.management) {
                    resource.post_error(
                        wp_color_manager_v1::Error::SurfaceExists,
                        "the surface already has a color management surface",
                    );
                    return;
                }
                data_init.init(
                    id,
                    SurfaceObject {
                        surface: surface.downgrade(),
                    },
                );
            }
            Request::GetSurfaceFeedback { id, surface } => {
                let identity = state
                    .wayland
                    .as_ref()
                    .map(|frontend| frontend.preferred_description(&surface).identity)
                    .unwrap_or_default();
                let feedback = data_init.init(
                    id,
                    FeedbackObject {
                        surface: surface.downgrade(),
                        preferred: Mutex::new(identity),
                    },
                );
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.color_management.feedbacks.push(feedback);
                }
            }
            Request::CreateIccCreator { obj } => {
                data_init.init(obj, ());
                resource.post_error(
                    wp_color_manager_v1::Error::UnsupportedFeature,
                    "ICC profiles are not supported",
                );
            }
            Request::CreateParametricCreator { obj } => {
                data_init.init(obj, Mutex::new(ParamsBuilder::default()));
            }
            Request::CreateWindowsScrgb { image_description } => {
                let record = DescriptionRecord::new(ImageDescription::windows_scrgb(), false);
                init_description(
                    data_init,
                    image_description,
                    Some(record),
                    (wp_image_description_v1::Cause::Unsupported, ""),
                );
            }
            Request::CreateWindowsBt2100 { image_description } => {
                let record = DescriptionRecord::new(ImageDescription::windows_bt2100(), false);
                init_description(
                    data_init,
                    image_description,
                    Some(record),
                    (wp_image_description_v1::Cause::Unsupported, ""),
                );
            }
            Request::GetImageDescription {
                image_description, ..
            } => {
                // No extension Denial implements hands out references.
                init_description(
                    data_init,
                    image_description,
                    None,
                    (
                        wp_image_description_v1::Cause::Unsupported,
                        "unknown image description reference",
                    ),
                );
            }
            Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<WpColorManagementOutputV1, OutputObject> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &WpColorManagementOutputV1,
        request: wp_color_management_output_v1::Request,
        data: &OutputObject,
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_management_output_v1::Request;
        match request {
            Request::GetImageDescription { image_description } => {
                let record = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.color_management.output(data.output).cloned());
                init_description(
                    data_init,
                    image_description,
                    record,
                    (
                        wp_image_description_v1::Cause::NoOutput,
                        "the output is gone",
                    ),
                );
            }
            Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<WpColorManagementSurfaceV1, SurfaceObject> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        resource: &WpColorManagementSurfaceV1,
        request: wp_color_management_surface_v1::Request,
        data: &SurfaceObject,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_management_surface_v1::{Error, Request};
        let surface = data.surface.upgrade().ok();
        match request {
            Request::SetImageDescription {
                image_description,
                render_intent,
            } => {
                let Some(surface) = surface else {
                    resource.post_error(Error::Inert, "the surface is gone");
                    return;
                };
                let Some(intent) = RenderIntent::from_protocol(render_intent.into()) else {
                    resource.post_error(Error::RenderIntent, "unsupported rendering intent");
                    return;
                };
                let Some(record) = image_description
                    .data::<DescriptionObject>()
                    .and_then(|object| object.0.clone())
                else {
                    resource.post_error(
                        Error::ImageDescription,
                        "the image description is not ready",
                    );
                    return;
                };
                update_pending(&surface, |pending| {
                    pending.description = Some((record, intent));
                });
            }
            Request::UnsetImageDescription => {
                let Some(surface) = surface else {
                    resource.post_error(Error::Inert, "the surface is gone");
                    return;
                };
                update_pending(&surface, |pending| pending.description = None);
            }
            Request::Destroy => {
                if let Some(surface) = surface {
                    update_pending(&surface, |pending| pending.description = None);
                    release_extension(&surface, |extensions| &mut extensions.management);
                }
            }
            _ => unreachable!(),
        }
    }
}

impl Dispatch<WpColorManagementSurfaceFeedbackV1, FeedbackObject> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &WpColorManagementSurfaceFeedbackV1,
        request: wp_color_management_surface_feedback_v1::Request,
        data: &FeedbackObject,
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_management_surface_feedback_v1::{Error, Request};
        match request {
            Request::GetPreferred { image_description }
            | Request::GetPreferredParametric { image_description } => {
                let Ok(surface) = data.surface.upgrade() else {
                    data_init.init(image_description, DescriptionObject(None));
                    resource.post_error(Error::Inert, "the surface is gone");
                    return;
                };
                let record = state
                    .wayland
                    .as_ref()
                    .map(|frontend| frontend.preferred_description(&surface));
                init_description(
                    data_init,
                    image_description,
                    record,
                    (wp_image_description_v1::Cause::NoOutput, "no output"),
                );
            }
            Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<WpImageDescriptionCreatorIccV1, ()> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &WpImageDescriptionCreatorIccV1,
        request: wp_image_description_creator_icc_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        // The creator is refused when made; a client that gets this far is
        // already disconnected.
        if let wp_image_description_creator_icc_v1::Request::Create { image_description } = request
        {
            data_init.init(image_description, DescriptionObject(None));
        }
    }
}

fn chromaticities(values: [i32; 8]) -> Chromaticities {
    let c = |value: i32| f64::from(value) / 1_000_000.0;
    [
        (c(values[0]), c(values[1])),
        (c(values[2]), c(values[3])),
        (c(values[4]), c(values[5])),
        (c(values[6]), c(values[7])),
    ]
}

impl Dispatch<WpImageDescriptionCreatorParamsV1, Mutex<ParamsBuilder>> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        resource: &WpImageDescriptionCreatorParamsV1,
        request: wp_image_description_creator_params_v1::Request,
        data: &Mutex<ParamsBuilder>,
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_image_description_creator_params_v1::{Error, Request};
        let mut params = data.lock().unwrap_or_else(PoisonError::into_inner);
        let version = resource.version();
        let already_set = |what: &str| {
            resource.post_error(Error::AlreadySet, format!("{what} is already set"));
        };
        match request {
            Request::SetTfNamed { tf } => {
                let tf = u32::from(tf);
                if params.tf.is_some() {
                    return already_set("the transfer function");
                }
                if !named_transfer_functions(version).contains(&tf) {
                    resource.post_error(
                        Error::InvalidTf,
                        format!("unsupported transfer function {tf}"),
                    );
                    return;
                }
                params.tf = Some(TransferFunction::Named(tf));
            }
            Request::SetTfPower { eexp } => {
                if params.tf.is_some() {
                    return already_set("the transfer function");
                }
                if !(10_000..=100_000).contains(&eexp) {
                    resource.post_error(Error::InvalidTf, "the exponent must be within 1.0..=10.0");
                    return;
                }
                params.tf = Some(TransferFunction::Power(eexp));
            }
            Request::SetPrimariesNamed { primaries } => {
                let name = u32::from(primaries);
                if params.primaries.is_some() {
                    return already_set("the primaries");
                }
                let Some(chromaticities) = named_primaries(name) else {
                    resource.post_error(
                        Error::InvalidPrimariesNamed,
                        format!("unsupported primaries {name}"),
                    );
                    return;
                };
                params.primaries = Some((chromaticities, Some(name)));
            }
            Request::SetPrimaries {
                r_x,
                r_y,
                g_x,
                g_y,
                b_x,
                b_y,
                w_x,
                w_y,
            } => {
                if params.primaries.is_some() {
                    return already_set("the primaries");
                }
                params.primaries = Some((
                    chromaticities([r_x, r_y, g_x, g_y, b_x, b_y, w_x, w_y]),
                    None,
                ));
            }
            Request::SetLuminances {
                min_lum,
                max_lum,
                reference_lum,
            } => {
                if params.luminances.is_some() {
                    return already_set("the luminances");
                }
                let min = f64::from(min_lum) / 10_000.0;
                let (max, reference) = (f64::from(max_lum), f64::from(reference_lum));
                if max <= min || reference <= min {
                    resource.post_error(
                        Error::InvalidLuminance,
                        "maximum and reference luminance must exceed the minimum",
                    );
                    return;
                }
                params.luminances = Some(Luminances {
                    min,
                    max,
                    reference,
                });
            }
            Request::SetMasteringDisplayPrimaries {
                r_x,
                r_y,
                g_x,
                g_y,
                b_x,
                b_y,
                w_x,
                w_y,
            } => {
                if params.mastering_primaries.is_some() {
                    return already_set("the mastering display primaries");
                }
                params.mastering_primaries =
                    Some(chromaticities([r_x, r_y, g_x, g_y, b_x, b_y, w_x, w_y]));
            }
            Request::SetMasteringLuminance { min_lum, max_lum } => {
                if params.mastering_luminance.is_some() {
                    return already_set("the mastering luminance");
                }
                let (min, max) = (f64::from(min_lum) / 10_000.0, f64::from(max_lum));
                if max <= min {
                    resource.post_error(
                        Error::InvalidLuminance,
                        "the maximum mastering luminance must exceed the minimum",
                    );
                    return;
                }
                params.mastering_luminance = Some((min, max));
            }
            Request::SetMaxCll { max_cll } => {
                if params.max_cll.is_some() {
                    return already_set("max_cll");
                }
                params.max_cll = Some(f64::from(max_cll));
            }
            Request::SetMaxFall { max_fall } => {
                if params.max_fall.is_some() {
                    return already_set("max_fall");
                }
                params.max_fall = Some(f64::from(max_fall));
            }
            Request::Create { image_description } => {
                let params = std::mem::take(&mut *params);
                let (Some(tf), Some((primaries, primaries_named))) = (params.tf, params.primaries)
                else {
                    data_init.init(image_description, DescriptionObject(None));
                    resource.post_error(
                        Error::IncompleteSet,
                        "the transfer function and the primaries are required",
                    );
                    return;
                };
                if let (Some(cll), Some(fall)) = (params.max_cll, params.max_fall)
                    && fall > cll
                {
                    data_init.init(image_description, DescriptionObject(None));
                    resource.post_error(Error::InvalidLuminance, "max_fall exceeds max_cll");
                    return;
                }
                let mut luminances = params.luminances.unwrap_or_else(|| tf.default_luminances());
                if tf == TransferFunction::Named(tf::ST2084_PQ) {
                    luminances.max = luminances.min + 10_000.0;
                }
                let target_luminance = params
                    .mastering_luminance
                    .unwrap_or((luminances.min, luminances.max));
                if version < 2
                    && [params.max_cll, params.max_fall]
                        .into_iter()
                        .flatten()
                        .any(|light| light <= target_luminance.0 || light > target_luminance.1)
                {
                    data_init.init(image_description, DescriptionObject(None));
                    resource.post_error(
                        Error::InvalidLuminance,
                        "max_cll and max_fall must lie within the mastering luminance",
                    );
                    return;
                }
                let description = ImageDescription {
                    tf,
                    primaries,
                    primaries_named,
                    luminances,
                    target_primaries: params.mastering_primaries.unwrap_or(primaries),
                    target_luminance,
                    max_cll: params.max_cll,
                    max_fall: params.max_fall,
                };
                let record = description
                    .supported()
                    .then(|| DescriptionRecord::new(description, false));
                init_description(
                    data_init,
                    image_description,
                    record,
                    (
                        wp_image_description_v1::Cause::Unsupported,
                        "the primaries or luminances do not describe a color space",
                    ),
                );
            }
            _ => unreachable!(),
        }
    }
}

impl Dispatch<WpImageDescriptionV1, DescriptionObject> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &WpImageDescriptionV1,
        request: wp_image_description_v1::Request,
        data: &DescriptionObject,
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_image_description_v1::{Error, Request};
        match request {
            Request::GetInformation { information } => {
                let Some(record) = data.0.clone() else {
                    data_init.init(information, ());
                    resource.post_error(Error::NotReady, "the image description is not ready");
                    return;
                };
                if !record.informative {
                    data_init.init(information, ());
                    resource.post_error(
                        Error::NoInformation,
                        "this image description has no information",
                    );
                    return;
                }
                let info = data_init.init(information, ());
                send_information(&info, &record.description);
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.color_management.unfinished_information.push(info);
                }
            }
            Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

fn send_information(info: &WpImageDescriptionInfoV1, description: &ImageDescription) {
    let xy = |value: f64| (value * 1_000_000.0).round() as i32;
    let primaries = |c: Chromaticities| {
        [
            xy(c[0].0),
            xy(c[0].1),
            xy(c[1].0),
            xy(c[1].1),
            xy(c[2].0),
            xy(c[2].1),
            xy(c[3].0),
            xy(c[3].1),
        ]
    };
    let [rx, ry, gx, gy, bx, by, wx, wy] = primaries(description.primaries);
    info.primaries(rx, ry, gx, gy, bx, by, wx, wy);
    if let Some(name) = description
        .primaries_named
        .and_then(|name| name.try_into().ok())
    {
        info.primaries_named(name);
    }
    match description.tf {
        TransferFunction::Named(name) => {
            if let Ok(name) = name.try_into() {
                info.tf_named(name);
            }
        }
        TransferFunction::Power(exponent) => info.tf_power(exponent),
    }
    let luminance = |value: f64| value.round().clamp(0.0, f64::from(u32::MAX)) as u32;
    let minimum = |value: f64| (value * 10_000.0).round().clamp(0.0, f64::from(u32::MAX)) as u32;
    info.luminances(
        minimum(description.luminances.min),
        luminance(description.luminances.max),
        luminance(description.luminances.reference),
    );
    let [rx, ry, gx, gy, bx, by, wx, wy] = primaries(description.target_primaries);
    info.target_primaries(rx, ry, gx, gy, bx, by, wx, wy);
    info.target_luminance(
        minimum(description.target_luminance.0),
        luminance(description.target_luminance.1),
    );
    if let Some(cll) = description.max_cll {
        info.target_max_cll(luminance(cll));
    }
    if let Some(fall) = description.max_fall {
        info.target_max_fall(luminance(fall));
    }
}

impl Dispatch<WpImageDescriptionInfoV1, ()> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &WpImageDescriptionInfoV1,
        _request: <WpImageDescriptionInfoV1 as Resource>::Request,
        _data: &(),
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
    }
}

impl GlobalDispatch<WpColorRepresentationManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<WpColorRepresentationManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_representation_surface_v1::{AlphaMode, Coefficients, Range};
        let manager = data_init.init(resource, ());
        for mode in [
            AlphaMode::PremultipliedElectrical,
            AlphaMode::PremultipliedOptical,
            AlphaMode::Straight,
        ] {
            manager.supported_alpha_mode(mode);
        }
        // Denial samples RGB buffers only, and those carry no matrix.
        manager.supported_coefficients_and_ranges(Coefficients::Identity, Range::Full);
        manager.done();
    }
}

impl Dispatch<WpColorRepresentationManagerV1, ()> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        resource: &WpColorRepresentationManagerV1,
        request: wp_color_representation_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_representation_manager_v1::{Error, Request};
        match request {
            Request::GetSurface { id, surface } => {
                if !claim_extension(&surface, |extensions| &mut extensions.representation) {
                    resource.post_error(
                        Error::SurfaceExists,
                        "the surface already has a color representation surface",
                    );
                    return;
                }
                data_init.init(
                    id,
                    SurfaceObject {
                        surface: surface.downgrade(),
                    },
                );
            }
            Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<WpColorRepresentationSurfaceV1, SurfaceObject> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        resource: &WpColorRepresentationSurfaceV1,
        request: wp_color_representation_surface_v1::Request,
        data: &SurfaceObject,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        use wp_color_representation_surface_v1::{Error, Request};
        let surface = data.surface.upgrade().ok();
        if surface.is_none() && !matches!(request, Request::Destroy) {
            resource.post_error(Error::Inert, "the surface is gone");
            return;
        }
        match request {
            Request::SetAlphaMode { alpha_mode } => {
                let Some(mode) = AlphaMode::from_protocol(alpha_mode.into()) else {
                    resource.post_error(Error::AlphaMode, "unsupported alpha mode");
                    return;
                };
                if let Some(surface) = surface {
                    update_pending(&surface, |pending| pending.alpha = mode);
                }
            }
            Request::SetCoefficientsAndRange {
                coefficients,
                range,
            } => {
                let (coefficients, range) = (u32::from(coefficients), u32::from(range));
                if (coefficients, range) != (1, 1) {
                    resource.post_error(
                        Error::Coefficients,
                        "only identity coefficients with full range are supported",
                    );
                    return;
                }
                if let Some(surface) = surface {
                    update_pending(&surface, |pending| {
                        pending.coefficients = Some((coefficients, range));
                    });
                }
            }
            Request::SetChromaLocation { chroma_location } => {
                let location = u32::from(chroma_location);
                if !(1..=6).contains(&location) {
                    resource.post_error(Error::ChromaLocation, "invalid chroma location");
                    return;
                }
                if let Some(surface) = surface {
                    update_pending(&surface, |pending| pending.chroma_location = Some(location));
                }
            }
            Request::Destroy => {
                if let Some(surface) = surface {
                    update_pending(&surface, |pending| {
                        pending.alpha = AlphaMode::default();
                        pending.coefficients = None;
                        pending.chroma_location = None;
                    });
                    release_extension(&surface, |extensions| &mut extensions.representation);
                }
            }
            _ => unreachable!(),
        }
    }
}

/// Log a surface's color whenever a commit changes it. `root` is the
/// surface whose toplevel names the app.
pub(super) fn note_committed_color(surface: &WlSurface, root: &WlSurface) {
    let changed = with_states(surface, |states| {
        let color = surface_color(states);
        states
            .data_map
            .insert_if_missing_threadsafe(|| Mutex::new(None::<Arc<SurfaceColor>>));
        let mut logged = states
            .data_map
            .get::<Mutex<Option<Arc<SurfaceColor>>>>()
            .expect("logged color was just inserted")
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        (*logged != color).then(|| {
            *logged = color.clone();
            color
        })
    });
    let Some(color) = changed else {
        return;
    };
    let app_id = with_states(root, |states| {
        states
            .data_map
            .get::<smithay::wayland::shell::xdg::XdgToplevelSurfaceData>()?
            .lock()
            .ok()?
            .app_id
            .clone()
    });
    let app_id = app_id.as_deref();
    match color.as_deref() {
        Some(SurfaceColor {
            description: Some((record, intent)),
            alpha,
        }) => info!(
            app_id = app_id.unwrap_or("unknown"),
            description = record.description.summary(),
            ?intent,
            ?alpha,
            "surface describes its color"
        ),
        Some(SurfaceColor { alpha, .. }) => info!(
            app_id = app_id.unwrap_or("unknown"),
            ?alpha,
            "surface sets its alpha mode"
        ),
        None => info!(
            app_id = app_id.unwrap_or("unknown"),
            "surface no longer describes its color"
        ),
    }
}
