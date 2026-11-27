//! The composer's Vulkan device: one graphics queue on the GPU the raster
//! context renders with, DMA-BUF imports, pipelines (compose and glass per
//! target format, blur for frost) and per-frame command resources.
//!
//! Every per-frame driver call is deliberate: one command buffer, one
//! descriptor push per distinct image, one instanced draw per run of draws
//! that share an image, one draw per material (plus its frost passes when the
//! scene below it changed), one submit, one semaphore export. Imports,
//! pipelines and descriptor sets are made once and reused.

use denial_kms::drm_vulkan::DrmInstance;
use ash::{Entry, vk};
use gpu_allocator::{
    AllocationSizes, MemoryLocation,
    vulkan::{Allocation, AllocationCreateDesc, AllocationScheme, Allocator, AllocatorCreateDesc},
};
use smithay::backend::allocator::{Buffer, Fourcc, Modifier, dmabuf::Dmabuf, format::FormatSet};
use std::{
    collections::HashMap,
    ffi::CStr,
    os::fd::{AsRawFd, BorrowedFd, FromRawFd, IntoRawFd, OwnedFd, RawFd},
    sync::{Arc, Mutex},
};

use super::material::{self, Frost};
use super::memory_ledger::{self, MemoryLedger};
use super::record::{ClipRecord, Draw, FrostPlan, Glass};
use super::shell_queue;

type Result<T> = std::result::Result<T, String>;

/// The composer's device was lost: nothing it submits runs any more.
static DEVICE_LOST: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether any composer call reported `VK_ERROR_DEVICE_LOST`.
pub(super) fn device_lost() -> bool {
    DEVICE_LOST.load(std::sync::atomic::Ordering::Acquire)
}

fn vk_error(stage: &str, error: vk::Result) -> String {
    if error == vk::Result::ERROR_DEVICE_LOST {
        DEVICE_LOST.store(true, std::sync::atomic::Ordering::Release);
    }
    format!("Stagecraft {stage}: {error:?}")
}

/// A binary semaphore whose payload exports as a sync file.
///
/// # Safety
/// `device` is live.
unsafe fn export_semaphore(device: &ash::Device) -> Result<vk::Semaphore> {
    let mut export = vk::ExportSemaphoreCreateInfo::default()
        .handle_types(vk::ExternalSemaphoreHandleTypeFlags::SYNC_FD);
    // SAFETY: upheld by the caller.
    unsafe {
        device.create_semaphore(
            &vk::SemaphoreCreateInfo::default().push_next(&mut export),
            None,
        )
    }
    .map_err(|e| vk_error("signal semaphore", e))
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The three pipelines' shaders.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum Program {
    /// Slices, client textures and windows.
    Compose,
    /// A material's frost, plain or as glass.
    Glass,
    /// One direction of the frost's Gaussian; renders frost images.
    Blur,
    /// A window over its material: the client and the frost in one draw.
    WindowGlass,
    /// `Compose` for a native window drawn from its layers (`Layers`).
    ComposeLayered,
    /// `WindowGlass` for a native window drawn from its layers.
    WindowGlassLayered,
}

impl Program {
    const ALL: [Self; 6] = [
        Self::Compose,
        Self::Glass,
        Self::Blur,
        Self::WindowGlass,
        Self::ComposeLayered,
        Self::WindowGlassLayered,
    ];

    fn spirv(self) -> (&'static [u8], &'static [u8]) {
        match self {
            Self::Compose => (
                include_bytes!("shaders/compose.vert.spv"),
                include_bytes!("shaders/compose.frag.spv"),
            ),
            Self::Glass => (
                include_bytes!("shaders/glass.vert.spv"),
                include_bytes!("shaders/glass.frag.spv"),
            ),
            Self::Blur => (
                include_bytes!("shaders/blur.vert.spv"),
                include_bytes!("shaders/blur.frag.spv"),
            ),
            Self::WindowGlass => (
                include_bytes!("shaders/compose.vert.spv"),
                include_bytes!("shaders/window_glass.frag.spv"),
            ),
            Self::ComposeLayered => (
                include_bytes!("shaders/compose_layered.vert.spv"),
                include_bytes!("shaders/compose_layered.frag.spv"),
            ),
            Self::WindowGlassLayered => (
                include_bytes!("shaders/compose_layered.vert.spv"),
                include_bytes!("shaders/window_glass_layered.frag.spv"),
            ),
        }
    }
}

/// Further layers a layered draw samples beside its own image.
pub(super) const LAYERS: usize = 3;

/// Components the layered programs pass between their stages
/// (draw_varyings.glsl with LAYERED): 30 locations, the 20 every draw has
/// and a coordinate pair, limits and coverage per further layer and the
/// opacities, counted as four components each, as drivers that count
/// locations do.
const LAYERED_COMPONENTS: u32 = (20 + LAYERS as u32 * 3 + 1) * 4;

/// Frost images are always this format; a blit converts from the target's.
pub(super) const FROST_FORMAT: vk::Format = vk::Format::R8G8B8A8_UNORM;

/// The blur pass's push constants (`Pass` in blur.frag).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub(super) struct BlurPass {
    pub(super) limits: [f32; 4],
    pub(super) step: [f32; 2],
    pub(super) scale: [f32; 2],
    pub(super) sigma: f32,
    pub(super) radius: f32,
}
const DMA_BUF: vk::ExternalMemoryHandleTypeFlags = vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT;

/// How an imported image is used.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum Usage {
    Sampled,
    Target,
}

impl Usage {
    fn flags(self) -> vk::ImageUsageFlags {
        match self {
            Self::Sampled => vk::ImageUsageFlags::SAMPLED,
            Self::Target => vk::ImageUsageFlags::COLOR_ATTACHMENT,
        }
    }

    fn features(self) -> vk::FormatFeatureFlags {
        match self {
            // Client images may be sampled linearly; the target blends.
            Self::Sampled => {
                vk::FormatFeatureFlags::SAMPLED_IMAGE
                    | vk::FormatFeatureFlags::SAMPLED_IMAGE_FILTER_LINEAR
            }
            Self::Target => {
                vk::FormatFeatureFlags::COLOR_ATTACHMENT
                    | vk::FormatFeatureFlags::COLOR_ATTACHMENT_BLEND
            }
        }
    }
}

/// What a target additionally needs for materials to copy from it.
const COPY_USAGE: vk::ImageUsageFlags = vk::ImageUsageFlags::TRANSFER_SRC;
const COPY_FEATURES: vk::FormatFeatureFlags = vk::FormatFeatureFlags::from_raw(
    vk::FormatFeatureFlags::BLIT_SRC.as_raw()
        | vk::FormatFeatureFlags::SAMPLED_IMAGE_FILTER_LINEAR.as_raw(),
);

/// The Vulkan format of a single-plane RGB fourcc, and whether its alpha
/// is padding.
pub(super) fn vulkan_format(fourcc: Fourcc) -> Option<(vk::Format, bool)> {
    Some(match fourcc {
        Fourcc::Argb8888 => (vk::Format::B8G8R8A8_UNORM, false),
        Fourcc::Xrgb8888 => (vk::Format::B8G8R8A8_UNORM, true),
        Fourcc::Abgr8888 => (vk::Format::R8G8B8A8_UNORM, false),
        Fourcc::Xbgr8888 => (vk::Format::R8G8B8A8_UNORM, true),
        Fourcc::Argb2101010 => (vk::Format::A2R10G10B10_UNORM_PACK32, false),
        Fourcc::Xrgb2101010 => (vk::Format::A2R10G10B10_UNORM_PACK32, true),
        Fourcc::Abgr2101010 => (vk::Format::A2B10G10R10_UNORM_PACK32, false),
        Fourcc::Xbgr2101010 => (vk::Format::A2B10G10R10_UNORM_PACK32, true),
        Fourcc::Abgr16161616f => (vk::Format::R16G16B16A16_SFLOAT, false),
        Fourcc::Rgb565 => (vk::Format::R5G6B5_UNORM_PACK16, false),
        Fourcc::Bgr565 => (vk::Format::B5G6R5_UNORM_PACK16, false),
        Fourcc::Xbgr16161616f => (vk::Format::R16G16B16A16_SFLOAT, true),
        _ => return None,
    })
}

/// The Vulkan format of a two-plane YCbCr fourcc, which the composer
/// samples through a conversion to RGB.
pub(super) fn ycbcr_format(fourcc: Fourcc) -> Option<vk::Format> {
    match fourcc {
        Fourcc::Nv12 => Some(vk::Format::G8_B8R8_2PLANE_420_UNORM),
        _ => None,
    }
}

/// How a YCbCr image's samples become RGB.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct YcbcrKey {
    format: vk::Format,
    model: vk::SamplerYcbcrModelConversion,
    x_offset: vk::ChromaLocation,
    y_offset: vk::ChromaLocation,
    filter: vk::Filter,
}

/// A conversion to RGB with the immutable sampler that applies it and the
/// image set and pipeline layouts that carry that sampler at binding 0.
/// Set 0 and the push constants are the shared layout's, so bound draw
/// records stay valid across its pipelines.
#[derive(Clone, Copy)]
pub(super) struct Ycbcr {
    conversion: vk::SamplerYcbcrConversion,
    pub(super) sampler: vk::Sampler,
    image_layout: vk::DescriptorSetLayout,
    pub(super) layout: vk::PipelineLayout,
}

/// The image set's bindings: the sampled image, with `immutable` as its
/// sampler when given; a window's frost; the client's look; a layered
/// window's further layers.
fn image_bindings(immutable: Option<&[vk::Sampler]>) -> [vk::DescriptorSetLayoutBinding<'_>; 4] {
    let sampled = |binding: u32| {
        vk::DescriptorSetLayoutBinding::default()
            .binding(binding)
            .descriptor_type(vk::DescriptorType::COMBINED_IMAGE_SAMPLER)
            .descriptor_count(1)
            .stage_flags(vk::ShaderStageFlags::FRAGMENT)
    };
    let first = match immutable {
        Some(samplers) => sampled(0).immutable_samplers(samplers),
        None => sampled(0),
    };
    [
        first,
        sampled(1),
        sampled(2),
        sampled(3).descriptor_count(LAYERS as u32),
    ]
}

/// How a `size` image of the YCbCr `format`, whose modifier has `features`,
/// converts to RGB. Video carries no colour description through
/// `zwp_linux_dmabuf_v1`, so this guesses as players do: BT.709 from HD up,
/// BT.601 below, narrow range; chroma sited left (MPEG-2 and later) where
/// the device takes it, else between samples.
fn ycbcr_key(
    format: vk::Format,
    features: vk::FormatFeatureFlags,
    (width, height): (u32, u32),
) -> YcbcrKey {
    let hd = width.min(height) >= 720 || width.max(height) >= 1280;
    let model = if hd {
        vk::SamplerYcbcrModelConversion::YCBCR_709
    } else {
        vk::SamplerYcbcrModelConversion::YCBCR_601
    };
    let cosited = features.contains(vk::FormatFeatureFlags::COSITED_CHROMA_SAMPLES);
    let midpoint = features.contains(vk::FormatFeatureFlags::MIDPOINT_CHROMA_SAMPLES);
    let x_offset = if cosited || !midpoint {
        vk::ChromaLocation::COSITED_EVEN
    } else {
        vk::ChromaLocation::MIDPOINT
    };
    let y_offset = if midpoint {
        vk::ChromaLocation::MIDPOINT
    } else {
        vk::ChromaLocation::COSITED_EVEN
    };
    let linear = features.contains(
        vk::FormatFeatureFlags::SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER
            | vk::FormatFeatureFlags::SAMPLED_IMAGE_FILTER_LINEAR,
    );
    YcbcrKey {
        format,
        model,
        x_offset,
        y_offset,
        filter: if linear {
            vk::Filter::LINEAR
        } else {
            vk::Filter::NEAREST
        },
    }
}

/// The DRM format modifiers `physical` has for `format`.
fn query_modifiers(
    instance: &ash::Instance,
    physical: vk::PhysicalDevice,
    format: vk::Format,
) -> Vec<ModifierSupport> {
    let mut list = vk::DrmFormatModifierPropertiesListEXT::default();
    let mut properties = vk::FormatProperties2::default().push_next(&mut list);
    // SAFETY: two-call query on a live physical device of `instance`.
    unsafe { instance.get_physical_device_format_properties2(physical, format, &mut properties) };
    let mut entries = vec![
        vk::DrmFormatModifierPropertiesEXT::default();
        list.drm_format_modifier_count as usize
    ];
    let mut list = vk::DrmFormatModifierPropertiesListEXT::default()
        .drm_format_modifier_properties(&mut entries);
    let mut properties = vk::FormatProperties2::default().push_next(&mut list);
    // SAFETY: as above, with storage for every entry.
    unsafe { instance.get_physical_device_format_properties2(physical, format, &mut properties) };
    entries
        .iter()
        .map(|entry| ModifierSupport {
            modifier: entry.drm_format_modifier,
            planes: entry.drm_format_modifier_plane_count,
            features: entry.drm_format_modifier_tiling_features,
        })
        .collect()
}

/// Whether `physical` is the GPU behind the DRM node `device_number`, and
/// its API version when it is.
fn drm_node_version(
    instance: &ash::Instance,
    physical: vk::PhysicalDevice,
    device_number: libc::dev_t,
) -> Option<u32> {
    // SAFETY: the device belongs to this instance.
    let extensions =
        unsafe { instance.enumerate_device_extension_properties(physical) }.unwrap_or_default();
    if !extensions.iter().any(|extension| {
        extension
            .extension_name_as_c_str()
            .is_ok_and(|own| own == ash::ext::physical_device_drm::NAME)
    }) {
        return None;
    }
    let mut drm = vk::PhysicalDeviceDrmPropertiesEXT::default();
    let api_version = {
        let mut properties = vk::PhysicalDeviceProperties2::default().push_next(&mut drm);
        // SAFETY: the extension is supported by this device.
        unsafe { instance.get_physical_device_properties2(physical, &mut properties) };
        properties.properties.api_version
    };
    let node = |major: i64, minor: i64| {
        libc::major(device_number) as i64 == major && libc::minor(device_number) as i64 == minor
    };
    ((drm.has_render != 0 && node(drm.render_major, drm.render_minor))
        || (drm.has_primary != 0 && node(drm.primary_major, drm.primary_minor)))
    .then_some(api_version)
}

/// What clients may allocate their buffers with when the composer samples
/// them: of `formats`, what GLES imports on the GPU behind the DRM node
/// `device_number`, the RGB formats only with modifiers Vulkan can sample
/// there. GLES imports layouts Vulkan cannot (NVIDIA's compressed kinds);
/// a client that picked one would leave every frame showing it to GLES,
/// and the Vulkan shell has no GLES to leave it to. Other formats, and
/// implicit modifiers, stay as GLES has them.
pub(super) fn sampled_client_formats(
    device_number: libc::dev_t,
    formats: &FormatSet,
) -> Result<FormatSet> {
    // SAFETY: ash keeps the loaded library alive in the entry.
    let entry = unsafe { Entry::load() }
        .map_err(|error| format!("Stagecraft loader unavailable: {error}"))?;
    let app = vk::ApplicationInfo::default()
        .application_name(c"deniald Stagecraft formats")
        .api_version(vk::API_VERSION_1_3);
    let owner = DrmInstance::new(entry, device_number, &app, &[], &[])
        .map_err(|e| vk_error("create instance", e))?;
    let instance = &owner.instance;
    // SAFETY: the instance is live.
    let physicals = unsafe { instance.enumerate_physical_devices() }.unwrap_or_default();
    let physical = physicals
        .into_iter()
        .find(|&physical| drm_node_version(instance, physical, device_number).is_some());
    let filtered = physical.map(|physical| {
        let mut support: HashMap<vk::Format, Vec<ModifierSupport>> = HashMap::new();
        formats
            .iter()
            .filter(|format| {
                let Some((vk_format, _)) = vulkan_format(format.code) else {
                    return true;
                };
                if format.modifier == Modifier::Invalid {
                    return true;
                }
                support
                    .entry(vk_format)
                    .or_insert_with(|| query_modifiers(instance, physical, vk_format))
                    .iter()
                    .any(|entry| {
                        entry.modifier == u64::from(format.modifier)
                            && entry.features.contains(Usage::Sampled.features())
                    })
            })
            .copied()
            .collect::<FormatSet>()
    });
    filtered.ok_or_else(|| "no Vulkan device behind the render node".into())
}

struct ModifierSupport {
    modifier: u64,
    planes: u32,
    features: vk::FormatFeatureFlags,
}

pub(super) struct GpuInner {
    vulkan: DrmInstance,
    physical: vk::PhysicalDevice,
    pub(super) device: ash::Device,
    queue: vk::Queue,
    family: u32,
    /// What the instance and device were created with, for the engine when
    /// it renders on this device (`ShellDevice`).
    device_extensions: Vec<&'static CStr>,
    memory: vk::PhysicalDeviceMemoryProperties,
    /// The largest storage buffer range a descriptor may name.
    max_storage_range: u64,
    /// The layered programs fit the GPU: it passes their varyings from
    /// the vertex to the fragment shader (`LAYERED_COMPONENTS`).
    layered: bool,
    /// Nanoseconds per timestamp tick, when `DENIAL_COMPOSER_GPU_TIMING`
    /// asks for GPU timing (a diagnostic; `gpu_timing`).
    timing: Option<f32>,
    memory_fd: ash::khr::external_memory_fd::Device,
    semaphore_fd: ash::khr::external_semaphore_fd::Device,
    pub(super) push: ash::khr::push_descriptor::Device,
    draws_layout: vk::DescriptorSetLayout,
    image_layout: vk::DescriptorSetLayout,
    /// Shared by every pipeline, so bound sets survive pipeline changes:
    /// set 0 draws and glass records, set 1 the sampled image (pushed),
    /// blur push constants.
    pub(super) layout: vk::PipelineLayout,
    /// Vertex and fragment module per program, in `Program::ALL` order.
    modules: [(vk::ShaderModule, vk::ShaderModule); 6],
    /// Nearest, linear.
    pub(super) samplers: [vk::Sampler; 2],
    command_pool: vk::CommandPool,
    descriptor_pool: vk::DescriptorPool,
    /// By program, target format and pipeline layout (the shared one, or a
    /// YCbCr conversion's).
    pipelines: Mutex<HashMap<(Program, vk::Format, vk::PipelineLayout), vk::Pipeline>>,
    /// The device samples YCbCr images through conversions.
    ycbcr_conversion: bool,
    /// Conversions made so far, kept for the device's life.
    ycbcr: Mutex<Vec<(YcbcrKey, Ycbcr)>>,
    modifiers: Mutex<HashMap<vk::Format, Vec<ModifierSupport>>>,
    /// Largest importable extent per format, modifier and usage; None when
    /// the combination cannot be imported.
    extents: Mutex<HashMap<(vk::Format, u64, vk::ImageUsageFlags), Option<(u32, u32)>>>,
    /// Memory of private images: blocks bound once, images placed in them.
    /// A dedicated allocation maps its memory through the kernel every
    /// time (a quarter millisecond for a frost on a Moto), and frosts and
    /// slices come and go while the shell animates. None once dropped.
    allocator: Mutex<Option<Allocator>>,
    /// The driver's memory reports, when it gives them; the device holds a
    /// pointer to it until destroyed.
    ledger: Option<Box<MemoryLedger>>,
}

impl Drop for GpuInner {
    fn drop(&mut self) {
        // SAFETY: every image, frame and pipeline holds an Arc to this owner,
        // so all work using these objects completed or was abandoned with
        // the device idle (Frame::drop waits).
        unsafe {
            {
                let _queue = shell_queue::lock();
                let _ = self.device.device_wait_idle();
            }
            // Its blocks go before the device; every image holding one of
            // its allocations is gone with its Arc to this owner.
            drop(lock(&self.allocator).take());
            for (_, pipeline) in lock(&self.pipelines).drain() {
                self.device.destroy_pipeline(pipeline, None);
            }
            for (_, ycbcr) in lock(&self.ycbcr).drain(..) {
                self.device.destroy_pipeline_layout(ycbcr.layout, None);
                self.device
                    .destroy_descriptor_set_layout(ycbcr.image_layout, None);
                self.device.destroy_sampler(ycbcr.sampler, None);
                self.device
                    .destroy_sampler_ycbcr_conversion(ycbcr.conversion, None);
            }
            self.device
                .destroy_descriptor_pool(self.descriptor_pool, None);
            self.device.destroy_command_pool(self.command_pool, None);
            for sampler in self.samplers {
                self.device.destroy_sampler(sampler, None);
            }
            for (vertex, fragment) in self.modules {
                self.device.destroy_shader_module(vertex, None);
                self.device.destroy_shader_module(fragment, None);
            }
            self.device.destroy_pipeline_layout(self.layout, None);
            self.device
                .destroy_descriptor_set_layout(self.draws_layout, None);
            self.device
                .destroy_descriptor_set_layout(self.image_layout, None);
            self.device.destroy_device(None);
        }
    }
}

fn device_number(fd: RawFd) -> Result<libc::dev_t> {
    // SAFETY: fstat writes into a valid out-pointer for a live descriptor.
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return Err(format!(
            "Stagecraft render node: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(stat.st_rdev)
}

fn file_identity(fd: BorrowedFd<'_>) -> Result<(libc::dev_t, libc::ino_t)> {
    // SAFETY: as above.
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut stat) } != 0 {
        return Err(format!(
            "Stagecraft DMA-BUF: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok((stat.st_dev, stat.st_ino))
}

fn duplicate(fd: BorrowedFd<'_>) -> Result<OwnedFd> {
    fd.try_clone_to_owned()
        .map_err(|error| format!("Stagecraft could not duplicate a descriptor: {error}"))
}

/// The composer's GPU. Cloning shares it.
#[derive(Clone)]
/// What the allocator holds (`Gpu::memory_report`).
#[derive(Default)]
pub(super) struct MemoryReport {
    /// Each shared block as (bytes in use, block size).
    pub(super) blocks: Vec<(u64, u64)>,
    /// Images in memory of their own (`slice_image`): how many, and bytes.
    pub(super) own: (u64, u64),
    /// Bytes in use per image kind.
    pub(super) kinds: Vec<(String, u64)>,
}

pub(super) struct Gpu(pub(super) Arc<GpuInner>);

impl Gpu {
    /// Whether the GPU draws a native window from its layers (the layered
    /// programs); else the composer merges them into an image first.
    pub(super) fn layered(&self) -> bool {
        self.0.layered
    }

    /// Live device-local memory of the device by source
    /// (`MemoryLedger::device_local`); None when the driver gives no
    /// reports.
    pub(super) fn device_local_memory(&self) -> Option<Vec<(String, u64)>> {
        self.0.ledger.as_ref().map(|ledger| ledger.device_local())
    }

    /// The allocator's shared blocks as (bytes in use, block size), the
    /// images in memory of their own, and the bytes in use per image kind
    /// (`private_image`). Builds a report of
    /// every allocation: for the composer's log marks, never per frame.
    pub(super) fn memory_report(&self) -> MemoryReport {
        let Some(report) = lock(&self.0.allocator)
            .as_ref()
            .map(Allocator::generate_report)
        else {
            return MemoryReport::default();
        };
        let mut blocks = Vec::new();
        let mut own = (0, 0);
        for block in &report.blocks {
            let allocations = &report.allocations[block.allocations.clone()];
            // A dedicated block is exactly its one image.
            if let [allocation] = allocations
                && allocation.size == block.size
            {
                own.0 += 1;
                own.1 += block.size;
                continue;
            }
            let used = allocations.iter().map(|allocation| allocation.size).sum();
            blocks.push((used, block.size));
        }
        let mut kinds: Vec<(String, u64)> = Vec::new();
        for allocation in &report.allocations {
            match kinds.iter_mut().find(|(kind, _)| *kind == allocation.name) {
                Some((_, bytes)) => *bytes += allocation.size,
                None => kinds.push((allocation.name.clone(), allocation.size)),
            }
        }
        MemoryReport { blocks, own, kinds }
    }

    /// Opens the Vulkan device behind `render_node`, the DRM node the raster
    /// context renders with. The engine renders on it too: the instance and
    /// device add what Impeller requires, and the queue entry points the
    /// engine resolves take the shared queue lock.
    pub(super) fn new(render_node: BorrowedFd<'_>) -> Result<Self> {
        let device_number = device_number(render_node.as_raw_fd())?;
        // SAFETY: ash keeps the loaded library alive in the entry.
        let entry = unsafe { Entry::load() }
            .map_err(|error| format!("Stagecraft loader unavailable: {error}"))?;
        // SAFETY: a query on the live entry.
        let version = unsafe { entry.try_enumerate_instance_version() }
            .map_err(|e| vk_error("loader version", e))?
            .unwrap_or(vk::API_VERSION_1_0);
        if version < vk::API_VERSION_1_3 {
            return Err("Stagecraft needs Vulkan 1.3".into());
        }
        let app = vk::ApplicationInfo::default()
            .application_name(c"deniald Stagecraft")
            .api_version(vk::API_VERSION_1_3);
        // Impeller requires a surface and a window-system extension even
        // when it never presents; Wayland is the one deniald has.
        let mut layers: Vec<&'static CStr> = Vec::new();
        if std::env::var_os("DENIAL_VULKAN_VALIDATION").is_some() {
            layers.push(c"VK_LAYER_KHRONOS_validation");
        }
        let owner = DrmInstance::new(
            entry,
            device_number,
            &app,
            &[ash::khr::surface::NAME, ash::khr::wayland_surface::NAME],
            &layers,
        )
        .map_err(|e| vk_error("create instance", e))?;
        let instance = &owner.instance;
        let required = [
            ash::khr::external_memory_fd::NAME,
            ash::ext::external_memory_dma_buf::NAME,
            ash::ext::image_drm_format_modifier::NAME,
            ash::ext::queue_family_foreign::NAME,
            ash::khr::push_descriptor::NAME,
            ash::khr::external_semaphore_fd::NAME,
        ];
        // SAFETY: the instance is live.
        let physicals = unsafe { instance.enumerate_physical_devices() }
            .map_err(|e| vk_error("enumerate devices", e))?;
        let mut matched = None;
        for physical in physicals {
            // SAFETY: the device belongs to this instance.
            let extensions = unsafe { instance.enumerate_device_extension_properties(physical) }
                .unwrap_or_default();
            let has = |name: &CStr| {
                extensions.iter().any(|extension| {
                    extension
                        .extension_name_as_c_str()
                        .is_ok_and(|own| own == name)
                })
            };
            let Some(api_version) = drm_node_version(instance, physical, device_number) else {
                continue;
            };
            if api_version < vk::API_VERSION_1_3 || required.iter().any(|name| !has(name)) {
                return Err(
                    "Vulkan composer GPU lacks Vulkan 1.3 or DMA-BUF, modifier, FOREIGN, \
                     push-descriptor or semaphore-fd support"
                        .into(),
                );
            }
            // SAFETY: a query on a device of this instance.
            let families =
                unsafe { instance.get_physical_device_queue_family_properties(physical) };
            // The engine runs graphics and compute work on the same queue.
            let wanted = vk::QueueFlags::GRAPHICS | vk::QueueFlags::COMPUTE;
            let Some(family) = families
                .iter()
                .position(|family| family.queue_count > 0 && family.queue_flags.contains(wanted))
            else {
                return Err("Stagecraft GPU has no graphics queue".into());
            };
            matched = Some((physical, family as u32));
            break;
        }
        let Some((physical, family)) = matched else {
            return Err("Stagecraft found no Vulkan device for the render node".into());
        };
        let mut features13 = vk::PhysicalDeviceVulkan13Features::default()
            .dynamic_rendering(true)
            .synchronization2(true);
        let mut device_extensions: Vec<&'static CStr> = required.to_vec();
        // Impeller enables what the hardware has of these and assumes the
        // embedder did the same.
        // SAFETY: a query on a device of this instance.
        let extensions =
            unsafe { instance.enumerate_device_extension_properties(physical) }.unwrap_or_default();
        if !extensions.iter().any(|ext| {
            ext.extension_name_as_c_str()
                .is_ok_and(|own| own == ash::khr::swapchain::NAME)
        }) {
            return Err("Vulkan shell needs VK_KHR_swapchain".into());
        }
        device_extensions.push(ash::khr::swapchain::NAME);
        let reports = extensions.iter().any(|ext| {
            ext.extension_name_as_c_str()
                .is_ok_and(|own| own == ash::ext::device_memory_report::NAME)
        });
        let mut supported11 = vk::PhysicalDeviceVulkan11Features::default();
        let mut supported_reports = vk::PhysicalDeviceDeviceMemoryReportFeaturesEXT::default();
        let mut supported = vk::PhysicalDeviceFeatures2::default().push_next(&mut supported11);
        if reports {
            supported = supported.push_next(&mut supported_reports);
        }
        // SAFETY: a query on a Vulkan 1.3 device of this instance.
        unsafe { instance.get_physical_device_features2(physical, &mut supported) };
        let base = supported.features;
        // The driver reports every memory object to the ledger, for the
        // log's memory breakdown (memory_ledger.rs).
        let ledger = (reports && supported_reports.device_memory_report == vk::TRUE).then(|| {
            // SAFETY: a query on a device of this instance.
            let memory = unsafe { instance.get_physical_device_memory_properties(physical) };
            Box::new(MemoryLedger::new(&memory))
        });
        if ledger.is_some() {
            device_extensions.push(ash::ext::device_memory_report::NAME);
        }
        let mut reports_feature =
            vk::PhysicalDeviceDeviceMemoryReportFeaturesEXT::default().device_memory_report(true);
        let mut reports_create = vk::DeviceDeviceMemoryReportCreateInfoEXT::default()
            .pfn_user_callback(Some(memory_ledger::report))
            .user_data(ledger.as_deref().map_or(std::ptr::null_mut(), |ledger| {
                std::ptr::from_ref(ledger).cast_mut().cast()
            }));
        let mut features = vk::PhysicalDeviceFeatures2::default().features(
            vk::PhysicalDeviceFeatures::default()
                .fill_mode_non_solid(base.fill_mode_non_solid == vk::TRUE)
                .sampler_anisotropy(base.sampler_anisotropy == vk::TRUE),
        );
        let ycbcr_conversion = supported11.sampler_ycbcr_conversion == vk::TRUE;
        let mut features11 = vk::PhysicalDeviceVulkan11Features::default()
            .uniform_and_storage_buffer16_bit_access(
                supported11.uniform_and_storage_buffer16_bit_access == vk::TRUE,
            )
            .sampler_ycbcr_conversion(ycbcr_conversion);
        let priorities = [1.0];
        let queues = [vk::DeviceQueueCreateInfo::default()
            .queue_family_index(family)
            .queue_priorities(&priorities)];
        let names: Vec<_> = device_extensions.iter().map(|name| name.as_ptr()).collect();
        let mut create = vk::DeviceCreateInfo::default()
            .queue_create_infos(&queues)
            .enabled_extension_names(&names)
            .push_next(&mut features13)
            .push_next(&mut features11)
            .push_next(&mut features);
        if ledger.is_some() {
            create = create
                .push_next(&mut reports_feature)
                .push_next(&mut reports_create);
        }
        // SAFETY: extensions and features were checked above.
        let device = unsafe { instance.create_device(physical, &create, None) }
            .map_err(|e| vk_error("create device", e))?;
        // SAFETY: queries with a validated family.
        let (memory, queue, limits) = unsafe {
            (
                instance.get_physical_device_memory_properties(physical),
                device.get_device_queue(family, 0),
                instance.get_physical_device_properties(physical).limits,
            )
        };
        if let Err(error) = shell_queue::install(&owner.entry, instance.handle()) {
            // SAFETY: nothing was created from the device yet.
            unsafe { device.destroy_device(None) };
            return Err(error);
        }
        let mut inner = GpuInner {
            ledger,
            device_extensions,
            memory_fd: ash::khr::external_memory_fd::Device::new(instance, &device),
            semaphore_fd: ash::khr::external_semaphore_fd::Device::new(instance, &device),
            push: ash::khr::push_descriptor::Device::new(instance, &device),
            vulkan: owner,
            physical,
            device,
            queue,
            family,
            memory,
            max_storage_range: u64::from(limits.max_storage_buffer_range),
            layered: limits
                .max_vertex_output_components
                .min(limits.max_fragment_input_components)
                >= LAYERED_COMPONENTS,
            timing: (std::env::var_os("DENIAL_COMPOSER_GPU_TIMING").is_some()
                && limits.timestamp_compute_and_graphics == vk::TRUE)
                .then_some(limits.timestamp_period),
            draws_layout: vk::DescriptorSetLayout::null(),
            image_layout: vk::DescriptorSetLayout::null(),
            layout: vk::PipelineLayout::null(),
            modules: [(vk::ShaderModule::null(), vk::ShaderModule::null()); 6],
            samplers: [vk::Sampler::null(); 2],
            command_pool: vk::CommandPool::null(),
            descriptor_pool: vk::DescriptorPool::null(),
            pipelines: Mutex::new(HashMap::new()),
            ycbcr_conversion,
            ycbcr: Mutex::new(Vec::new()),
            modifiers: Mutex::new(HashMap::new()),
            extents: Mutex::new(HashMap::new()),
            allocator: Mutex::new(None),
        };
        // From here on, Drop destroys whatever was created (null handles are
        // ignored by vkDestroy*).
        inner.create_objects()?;
        // 32 MiB blocks hold a full-screen phone slice; a desktop that needs
        // more blocks gets them doubled, up to 128 MiB.
        inner.allocator = Mutex::new(Some(
            Allocator::new(&AllocatorCreateDesc {
                instance: inner.vulkan.instance.clone(),
                device: inner.device.clone(),
                physical_device: physical,
                debug_settings: Default::default(),
                buffer_device_address: false,
                allocation_sizes: AllocationSizes::new(32 << 20, 4 << 20)
                    .with_max_device_memblock_size(128 << 20),
            })
            .map_err(|e| format!("Stagecraft allocator: {e}"))?,
        ));
        // SAFETY: the name is a NUL-terminated array of the live device.
        let properties = unsafe {
            inner
                .vulkan
                .instance
                .get_physical_device_properties(physical)
        };
        tracing::info!(
            device = %properties.device_name_as_c_str().map(|name| name.to_string_lossy()).unwrap_or_default(),
            drm_major = libc::major(device_number),
            drm_minor = libc::minor(device_number),
            family,
            "Stagecraft initialized; the shell renders with Vulkan"
        );
        Ok(Self(Arc::new(inner)))
    }

    /// The device as the engine's Vulkan renderer takes it.
    pub(super) fn shell_device(&self) -> ShellDevice {
        let gpu = &self.0;
        ShellDevice {
            version: vk::API_VERSION_1_3,
            instance: gpu.vulkan.instance.handle(),
            physical: gpu.physical,
            device: gpu.device.handle(),
            family: gpu.family,
            queue: gpu.queue,
            instance_extensions: gpu.vulkan.extensions.clone(),
            device_extensions: gpu.device_extensions.clone(),
        }
    }
}

/// What the engine's Vulkan renderer runs on: the composer's own instance,
/// device and queue. The engine resolves procedures through
/// `shell_queue::instance_proc`.
#[derive(Clone)]
pub struct ShellDevice {
    pub version: u32,
    pub instance: vk::Instance,
    pub physical: vk::PhysicalDevice,
    pub device: vk::Device,
    pub family: u32,
    pub queue: vk::Queue,
    pub instance_extensions: Vec<&'static CStr>,
    pub device_extensions: Vec<&'static CStr>,
}

impl GpuInner {
    fn create_objects(&mut self) -> Result<()> {
        let d = &self.device;
        let stages = vk::ShaderStageFlags::VERTEX | vk::ShaderStageFlags::FRAGMENT;
        let records = |binding: u32| {
            vk::DescriptorSetLayoutBinding::default()
                .binding(binding)
                .descriptor_type(vk::DescriptorType::STORAGE_BUFFER)
                .descriptor_count(1)
                .stage_flags(stages)
        };
        // Draws, glass records, clips, path clip edges.
        let draws = [records(0), records(1), records(2), records(3)];
        // The sampled image; a window over its material also samples its
        // frost (binding 1, pushed only for that program); binding 2 is the
        // client's look; binding 3 holds a layered window's further layers
        // (pushed only for the layered programs).
        let image = image_bindings(None);
        let code = |bytes: &[u8]| -> Vec<u32> {
            bytes
                .chunks_exact(4)
                .map(|word| u32::from_le_bytes([word[0], word[1], word[2], word[3]]))
                .collect()
        };
        // SAFETY: valid create infos on the live device; results are stored
        // in self, which destroys them.
        unsafe {
            self.draws_layout = d
                .create_descriptor_set_layout(
                    &vk::DescriptorSetLayoutCreateInfo::default().bindings(&draws),
                    None,
                )
                .map_err(|e| vk_error("draw set layout", e))?;
            self.image_layout = d
                .create_descriptor_set_layout(
                    &vk::DescriptorSetLayoutCreateInfo::default()
                        .flags(vk::DescriptorSetLayoutCreateFlags::PUSH_DESCRIPTOR_KHR)
                        .bindings(&image),
                    None,
                )
                .map_err(|e| vk_error("image set layout", e))?;
            let sets = [self.draws_layout, self.image_layout];
            let constants = [vk::PushConstantRange::default()
                .stage_flags(vk::ShaderStageFlags::FRAGMENT)
                .size(std::mem::size_of::<BlurPass>() as u32)];
            self.layout = d
                .create_pipeline_layout(
                    &vk::PipelineLayoutCreateInfo::default()
                        .set_layouts(&sets)
                        .push_constant_ranges(&constants),
                    None,
                )
                .map_err(|e| vk_error("pipeline layout", e))?;
            for (index, program) in Program::ALL.into_iter().enumerate() {
                let (vertex, fragment) = program.spirv();
                let module = |bytes: &[u8]| {
                    d.create_shader_module(
                        &vk::ShaderModuleCreateInfo::default().code(&code(bytes)),
                        None,
                    )
                    .map_err(|e| vk_error("shader", e))
                };
                self.modules[index].0 = module(vertex)?;
                self.modules[index].1 = module(fragment)?;
            }
            for (index, filter) in [vk::Filter::NEAREST, vk::Filter::LINEAR]
                .into_iter()
                .enumerate()
            {
                self.samplers[index] = d
                    .create_sampler(
                        &vk::SamplerCreateInfo::default()
                            .mag_filter(filter)
                            .min_filter(filter)
                            .mipmap_mode(vk::SamplerMipmapMode::NEAREST)
                            .address_mode_u(vk::SamplerAddressMode::CLAMP_TO_EDGE)
                            .address_mode_v(vk::SamplerAddressMode::CLAMP_TO_EDGE)
                            .address_mode_w(vk::SamplerAddressMode::CLAMP_TO_EDGE)
                            .max_lod(0.0),
                        None,
                    )
                    .map_err(|e| vk_error("sampler", e))?;
            }
            self.command_pool = d
                .create_command_pool(
                    &vk::CommandPoolCreateInfo::default()
                        .flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER)
                        .queue_family_index(self.family),
                    None,
                )
                .map_err(|e| vk_error("command pool", e))?;
            let sizes = [vk::DescriptorPoolSize::default()
                .ty(vk::DescriptorType::STORAGE_BUFFER)
                .descriptor_count(4 * MAX_FRAMES as u32)];
            self.descriptor_pool = d
                .create_descriptor_pool(
                    &vk::DescriptorPoolCreateInfo::default()
                        .max_sets(MAX_FRAMES as u32)
                        .pool_sizes(&sizes),
                    None,
                )
                .map_err(|e| vk_error("descriptor pool", e))?;
        }
        Ok(())
    }

    pub(super) fn pipeline(&self, program: Program, format: vk::Format) -> Result<vk::Pipeline> {
        self.pipeline_in(program, format, self.layout)
    }

    /// The pipeline of `program` that samples `image` at binding 0: through
    /// its YCbCr conversion when it has one.
    pub(super) fn pipeline_for(
        &self,
        program: Program,
        format: vk::Format,
        image: &Image,
    ) -> Result<vk::Pipeline> {
        self.pipeline_in(program, format, self.layout_for(image))
    }

    /// The pipeline layout that samples `image` at binding 0.
    pub(super) fn layout_for(&self, image: &Image) -> vk::PipelineLayout {
        image.ycbcr.map_or(self.layout, |ycbcr| ycbcr.layout)
    }

    fn pipeline_in(
        &self,
        program: Program,
        format: vk::Format,
        layout: vk::PipelineLayout,
    ) -> Result<vk::Pipeline> {
        let mut pipelines = lock(&self.pipelines);
        if let Some(pipeline) = pipelines.get(&(program, format, layout)) {
            return Ok(*pipeline);
        }
        let (vertex, fragment) = self.modules[Program::ALL
            .iter()
            .position(|own| *own == program)
            .expect("every program has modules")];
        let stages = [
            vk::PipelineShaderStageCreateInfo::default()
                .stage(vk::ShaderStageFlags::VERTEX)
                .module(vertex)
                .name(c"main"),
            vk::PipelineShaderStageCreateInfo::default()
                .stage(vk::ShaderStageFlags::FRAGMENT)
                .module(fragment)
                .name(c"main"),
        ];
        let vertex_input = vk::PipelineVertexInputStateCreateInfo::default();
        // Quads are 4-vertex strips; the blur pass draws one triangle.
        let assembly = vk::PipelineInputAssemblyStateCreateInfo::default().topology(
            if program == Program::Blur {
                vk::PrimitiveTopology::TRIANGLE_LIST
            } else {
                vk::PrimitiveTopology::TRIANGLE_STRIP
            },
        );
        let viewport = vk::PipelineViewportStateCreateInfo::default()
            .viewport_count(1)
            .scissor_count(1);
        let raster = vk::PipelineRasterizationStateCreateInfo::default()
            .polygon_mode(vk::PolygonMode::FILL)
            .cull_mode(vk::CullModeFlags::NONE)
            .line_width(1.0);
        let multisample = vk::PipelineMultisampleStateCreateInfo::default()
            .rasterization_samples(vk::SampleCountFlags::TYPE_1);
        // Premultiplied source over; the blur replaces.
        let blend = [vk::PipelineColorBlendAttachmentState::default()
            .blend_enable(program != Program::Blur)
            .src_color_blend_factor(vk::BlendFactor::ONE)
            .dst_color_blend_factor(vk::BlendFactor::ONE_MINUS_SRC_ALPHA)
            .color_blend_op(vk::BlendOp::ADD)
            .src_alpha_blend_factor(vk::BlendFactor::ONE)
            .dst_alpha_blend_factor(vk::BlendFactor::ONE_MINUS_SRC_ALPHA)
            .alpha_blend_op(vk::BlendOp::ADD)
            .color_write_mask(vk::ColorComponentFlags::RGBA)];
        let blend = vk::PipelineColorBlendStateCreateInfo::default().attachments(&blend);
        let dynamic = [vk::DynamicState::VIEWPORT, vk::DynamicState::SCISSOR];
        let dynamic = vk::PipelineDynamicStateCreateInfo::default().dynamic_states(&dynamic);
        let formats = [format];
        let mut rendering =
            vk::PipelineRenderingCreateInfo::default().color_attachment_formats(&formats);
        let create = vk::GraphicsPipelineCreateInfo::default()
            .stages(&stages)
            .vertex_input_state(&vertex_input)
            .input_assembly_state(&assembly)
            .viewport_state(&viewport)
            .rasterization_state(&raster)
            .multisample_state(&multisample)
            .color_blend_state(&blend)
            .dynamic_state(&dynamic)
            .layout(layout)
            .push_next(&mut rendering);
        // SAFETY: valid create info; the pipeline is stored and destroyed in Drop.
        let pipeline = unsafe {
            self.device
                .create_graphics_pipelines(vk::PipelineCache::null(), &[create], None)
        }
        .map_err(|(_, e)| vk_error("pipeline", e))?[0];
        pipelines.insert((program, format, layout), pipeline);
        Ok(pipeline)
    }

    /// The conversion of `key`, made on first use.
    fn ycbcr(&self, key: YcbcrKey) -> Result<Ycbcr> {
        let mut made = lock(&self.ycbcr);
        if let Some((_, ycbcr)) = made.iter().find(|(own, _)| *own == key) {
            return Ok(*ycbcr);
        }
        let d = &self.device;
        let create = vk::SamplerYcbcrConversionCreateInfo::default()
            .format(key.format)
            .ycbcr_model(key.model)
            .ycbcr_range(vk::SamplerYcbcrRange::ITU_NARROW)
            .components(vk::ComponentMapping::default())
            .x_chroma_offset(key.x_offset)
            .y_chroma_offset(key.y_offset)
            .chroma_filter(key.filter)
            .force_explicit_reconstruction(false);
        let mut ycbcr = Ycbcr {
            conversion: vk::SamplerYcbcrConversion::null(),
            sampler: vk::Sampler::null(),
            image_layout: vk::DescriptorSetLayout::null(),
            layout: vk::PipelineLayout::null(),
        };
        // SAFETY: valid create infos on the live device; whatever was made
        // is destroyed below on failure, else with the device.
        let made_all = unsafe {
            (|| -> std::result::Result<(), vk::Result> {
                ycbcr.conversion = d.create_sampler_ycbcr_conversion(&create, None)?;
                let mut info =
                    vk::SamplerYcbcrConversionInfo::default().conversion(ycbcr.conversion);
                ycbcr.sampler = d.create_sampler(
                    &vk::SamplerCreateInfo::default()
                        .mag_filter(key.filter)
                        .min_filter(key.filter)
                        .mipmap_mode(vk::SamplerMipmapMode::NEAREST)
                        .address_mode_u(vk::SamplerAddressMode::CLAMP_TO_EDGE)
                        .address_mode_v(vk::SamplerAddressMode::CLAMP_TO_EDGE)
                        .address_mode_w(vk::SamplerAddressMode::CLAMP_TO_EDGE)
                        .max_lod(0.0)
                        .push_next(&mut info),
                    None,
                )?;
                let samplers = [ycbcr.sampler];
                let bindings = image_bindings(Some(&samplers));
                ycbcr.image_layout = d.create_descriptor_set_layout(
                    &vk::DescriptorSetLayoutCreateInfo::default()
                        .flags(vk::DescriptorSetLayoutCreateFlags::PUSH_DESCRIPTOR_KHR)
                        .bindings(&bindings),
                    None,
                )?;
                let sets = [self.draws_layout, ycbcr.image_layout];
                let constants = [vk::PushConstantRange::default()
                    .stage_flags(vk::ShaderStageFlags::FRAGMENT)
                    .size(std::mem::size_of::<BlurPass>() as u32)];
                ycbcr.layout = d.create_pipeline_layout(
                    &vk::PipelineLayoutCreateInfo::default()
                        .set_layouts(&sets)
                        .push_constant_ranges(&constants),
                    None,
                )?;
                Ok(())
            })()
        };
        if let Err(error) = made_all {
            // SAFETY: null handles are ignored; nothing uses these yet.
            unsafe {
                d.destroy_pipeline_layout(ycbcr.layout, None);
                d.destroy_descriptor_set_layout(ycbcr.image_layout, None);
                d.destroy_sampler(ycbcr.sampler, None);
                d.destroy_sampler_ycbcr_conversion(ycbcr.conversion, None);
            }
            return Err(vk_error("YCbCr conversion", error));
        }
        tracing::info!(
            ?key,
            "Stagecraft samples YCbCr clients through a conversion"
        );
        made.push((key, ycbcr));
        Ok(ycbcr)
    }

    /// Plane count and features of `modifier` for `format`.
    fn modifier_support(
        &self,
        format: vk::Format,
        modifier: u64,
    ) -> Option<(u32, vk::FormatFeatureFlags)> {
        let mut modifiers = lock(&self.modifiers);
        let list = modifiers
            .entry(format)
            .or_insert_with(|| query_modifiers(&self.vulkan.instance, self.physical, format));
        list.iter()
            .find(|entry| entry.modifier == modifier)
            .map(|entry| (entry.planes, entry.features))
    }

    fn max_extent(
        &self,
        format: vk::Format,
        modifier: u64,
        usage: vk::ImageUsageFlags,
    ) -> Option<(u32, u32)> {
        *lock(&self.extents)
            .entry((format, modifier, usage))
            .or_insert_with(|| {
                let mut modifier_info = vk::PhysicalDeviceImageDrmFormatModifierInfoEXT::default()
                    .drm_format_modifier(modifier)
                    .sharing_mode(vk::SharingMode::EXCLUSIVE);
                let mut external =
                    vk::PhysicalDeviceExternalImageFormatInfo::default().handle_type(DMA_BUF);
                let info = vk::PhysicalDeviceImageFormatInfo2::default()
                    .format(format)
                    .ty(vk::ImageType::TYPE_2D)
                    .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
                    .usage(usage)
                    .push_next(&mut modifier_info)
                    .push_next(&mut external);
                let mut external_properties = vk::ExternalImageFormatProperties::default();
                let max_extent = {
                    let mut properties =
                        vk::ImageFormatProperties2::default().push_next(&mut external_properties);
                    // SAFETY: a query with valid chained structs.
                    unsafe {
                        self.vulkan
                            .instance
                            .get_physical_device_image_format_properties2(
                                self.physical,
                                &info,
                                &mut properties,
                            )
                    }
                    .ok()?;
                    properties.image_format_properties.max_extent
                };
                external_properties
                    .external_memory_properties
                    .external_memory_features
                    .contains(vk::ExternalMemoryFeatureFlags::IMPORTABLE)
                    .then_some((max_extent.width, max_extent.height))
            })
    }

    /// Those of `candidates` a `size` image of `fourcc` imports with for
    /// sampling.
    pub(super) fn importable(
        &self,
        fourcc: Fourcc,
        (width, height): (u32, u32),
        candidates: &[Modifier],
    ) -> Vec<Modifier> {
        let Some((format, _)) = vulkan_format(fourcc) else {
            return Vec::new();
        };
        candidates
            .iter()
            .copied()
            .filter(|modifier| {
                self.max_extent(format, u64::from(*modifier), Usage::Sampled.flags())
                    .is_some_and(|(max_width, max_height)| {
                        width <= max_width && height <= max_height
                    })
            })
            .collect()
    }

    /// Modifiers this device samples `fourcc` with, for slice storage.
    pub(super) fn sampled_modifiers(&self, fourcc: Fourcc) -> Vec<Modifier> {
        let Some((format, _)) = vulkan_format(fourcc) else {
            return Vec::new();
        };
        let _ = self.modifier_support(format, 0);
        lock(&self.modifiers)
            .get(&format)
            .map(|list| {
                list.iter()
                    // As `import` requires for sampled images.
                    .filter(|entry| entry.features.contains(Usage::Sampled.features()))
                    .map(|entry| Modifier::from(entry.modifier))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn memory_type(&self, bits: u32, flags: vk::MemoryPropertyFlags) -> Option<u32> {
        (0..self.memory.memory_type_count).find(|&index| {
            bits & (1 << index) != 0
                && self.memory.memory_types[index as usize]
                    .property_flags
                    .contains(flags)
        })
    }
}

/// An imported DMA-BUF. Destroyed when the last holder drops it; frames
/// hold the images they sampled until their submission completed.
pub struct Image {
    gpu: Arc<GpuInner>,
    pub(super) image: vk::Image,
    memory: vk::DeviceMemory,
    /// Where a private image lives in the allocator's blocks; `memory` is
    /// then null.
    allocation: Option<Allocation>,
    pub(super) view: vk::ImageView,
    pub(super) format: vk::Format,
    pub(super) size: (u32, u32),
    /// The layout it is sampled in.
    pub(super) sampled_layout: vk::ImageLayout,
    /// Shared with other users: ownership moves through FOREIGN.
    pub(super) external: bool,
    /// A target materials can copy from.
    pub(super) copyable: bool,
    /// Sampled with alpha one: a format without alpha.
    pub(super) opaque: bool,
    /// The conversion a YCbCr image is sampled through.
    pub(super) ycbcr: Option<Ycbcr>,
}

impl Image {
    /// The bytes its allocation takes in the allocator's blocks; zero for
    /// an imported image.
    pub(super) fn allocated_bytes(&self) -> u64 {
        self.allocation.as_ref().map_or(0, Allocation::size)
    }

    /// What the engine samples of a lent image: its handles, VkFormat and
    /// size.
    pub fn lent(&self) -> (u64, u64, u32, (u32, u32)) {
        use ash::vk::Handle;
        (
            self.image.as_raw(),
            self.view.as_raw(),
            self.format.as_raw() as u32,
            self.size,
        )
    }
}

impl Drop for Image {
    fn drop(&mut self) {
        // SAFETY: the last holder drops the image only after every submission
        // that used it completed.
        unsafe {
            self.gpu.device.destroy_image_view(self.view, None);
            self.gpu.device.destroy_image(self.image, None);
            self.gpu.device.free_memory(self.memory, None);
        }
        if let Some(allocation) = self.allocation.take()
            && let Some(allocator) = lock(&self.gpu.allocator).as_mut()
            && let Err(error) = allocator.free(allocation)
        {
            tracing::warn!(%error, "Stagecraft: freeing private image memory");
        }
    }
}

impl Gpu {
    /// Whether a frame's record buffer can hold these records: each region
    /// must fit one storage descriptor.
    pub(super) fn records_fit(
        &self,
        draws: usize,
        glasses: usize,
        clips: usize,
        edges: usize,
    ) -> bool {
        Records::default()
            .grown(draws, glasses, clips, edges)
            .ranges()
            .iter()
            .all(|&(_, range)| range <= self.0.max_storage_range)
    }

    /// Imports a DMA-BUF whose memory planes share one buffer: a single-plane
    /// RGB image, or for sampling a two-plane YCbCr one, which draws through
    /// a conversion to RGB.
    pub(super) fn import(&self, dmabuf: &Dmabuf, usage: Usage) -> Result<Arc<Image>> {
        let gpu = &self.0;
        let format = dmabuf.format();
        let yuv = match vulkan_format(format.code) {
            Some(rgb) => Err(rgb),
            None if usage == Usage::Sampled && gpu.ycbcr_conversion => {
                Ok(ycbcr_format(format.code)
                    .ok_or_else(|| format!("Stagecraft cannot import {:?}", format.code))?)
            }
            None => return Err(format!("Stagecraft cannot import {:?}", format.code)),
        };
        let (vk_format, opaque) = match yuv {
            Ok(format) => (format, true),
            Err(rgb) => rgb,
        };
        let modifier = u64::from(format.modifier);
        if format.modifier == Modifier::Invalid {
            return Err("Stagecraft needs an explicit modifier".into());
        }
        let planes = dmabuf.num_planes();
        // A conversion samples with its own filter, so YCbCr images need not
        // filter linearly.
        let needed = if yuv.is_ok() {
            vk::FormatFeatureFlags::SAMPLED_IMAGE
        } else {
            usage.features()
        };
        let features = match gpu.modifier_support(vk_format, modifier) {
            Some((supported, features))
                if supported == planes as u32 && features.contains(needed) =>
            {
                features
            }
            _ => {
                return Err(format!(
                    "Stagecraft cannot import {:?} with modifier {modifier:#x} and {planes} planes",
                    format.code
                ));
            }
        };
        let (width, height) = (dmabuf.width() as u32, dmabuf.height() as u32);
        let fits = |usage: vk::ImageUsageFlags| {
            gpu.max_extent(vk_format, modifier, usage)
                .is_some_and(|max| width <= max.0 && height <= max.1)
        };
        if width == 0 || height == 0 || !fits(usage.flags()) {
            return Err(format!(
                "Stagecraft cannot import a {width}x{height} image with modifier {modifier:#x}"
            ));
        }
        // Materials copy their backdrop out of the target where the layout
        // allows it; elsewhere frames with materials stay on GLES.
        let copyable = usage == Usage::Target
            && features.contains(COPY_FEATURES)
            && fits(usage.flags() | COPY_USAGE);
        let image_usage = if copyable {
            usage.flags() | COPY_USAGE
        } else {
            usage.flags()
        };
        let mut handles = dmabuf.handles();
        let first = handles.next().ok_or("Stagecraft DMA-BUF has no plane")?;
        let identity = file_identity(first)?;
        for handle in handles {
            if file_identity(handle)? != identity {
                return Err("Stagecraft does not import disjoint planes".into());
            }
        }
        let layouts: Vec<_> = dmabuf
            .offsets()
            .zip(dmabuf.strides())
            .map(|(offset, stride)| vk::SubresourceLayout {
                offset: u64::from(offset),
                size: 0,
                row_pitch: u64::from(stride),
                array_pitch: 0,
                depth_pitch: 0,
            })
            .collect();
        let mut explicit = vk::ImageDrmFormatModifierExplicitCreateInfoEXT::default()
            .drm_format_modifier(modifier)
            .plane_layouts(&layouts);
        let mut external = vk::ExternalMemoryImageCreateInfo::default().handle_types(DMA_BUF);
        let create = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(vk_format)
            .extent(vk::Extent3D {
                width,
                height,
                depth: 1,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
            .usage(image_usage)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED)
            .push_next(&mut explicit)
            .push_next(&mut external);
        let d = &gpu.device;
        // SAFETY: the modifier, plane count and extent were validated above.
        let image = unsafe { d.create_image(&create, None) }.map_err(|e| vk_error("image", e))?;
        let mut imported = Image {
            gpu: Arc::clone(gpu),
            image,
            memory: vk::DeviceMemory::null(),
            allocation: None,
            view: vk::ImageView::null(),
            format: vk_format,
            size: (width, height),
            sampled_layout: vk::ImageLayout::GENERAL,
            external: true,
            copyable,
            opaque: opaque && usage == Usage::Sampled,
            ycbcr: None,
        };
        // SAFETY: queries on live objects.
        let requirements = unsafe { d.get_image_memory_requirements(image) };
        let mut fd_properties = vk::MemoryFdPropertiesKHR::default();
        unsafe {
            gpu.memory_fd
                .get_memory_fd_properties(DMA_BUF, first.as_raw_fd(), &mut fd_properties)
        }
        .map_err(|e| vk_error("memory fd properties", e))?;
        let type_index = gpu
            .memory_type(
                requirements.memory_type_bits & fd_properties.memory_type_bits,
                vk::MemoryPropertyFlags::empty(),
            )
            .ok_or("Stagecraft found no memory type for the DMA-BUF")?;
        let fd = duplicate(first)?;
        let mut import = vk::ImportMemoryFdInfoKHR::default()
            .handle_type(DMA_BUF)
            .fd(fd.as_raw_fd());
        let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().image(image);
        let allocate = vk::MemoryAllocateInfo::default()
            .allocation_size(requirements.size)
            .memory_type_index(type_index)
            .push_next(&mut import)
            .push_next(&mut dedicated);
        // SAFETY: a successful import takes ownership of the descriptor.
        imported.memory = unsafe { d.allocate_memory(&allocate, None) }
            .map_err(|e| vk_error("import memory", e))?;
        let _ = fd.into_raw_fd();
        // SAFETY: the memory was allocated for this image.
        unsafe { d.bind_image_memory(image, imported.memory, 0) }
            .map_err(|e| vk_error("bind memory", e))?;
        if yuv.is_ok() {
            let ycbcr = gpu.ycbcr(ycbcr_key(vk_format, features, (width, height)))?;
            imported.ycbcr = Some(ycbcr);
            // A converted view keeps identity components: the conversion
            // gives alpha one.
            let mut info = vk::SamplerYcbcrConversionInfo::default().conversion(ycbcr.conversion);
            let view = vk::ImageViewCreateInfo::default()
                .image(image)
                .view_type(vk::ImageViewType::TYPE_2D)
                .format(vk_format)
                .subresource_range(color_range())
                .push_next(&mut info);
            // SAFETY: a view of the bound image through its conversion.
            imported.view = unsafe { d.create_image_view(&view, None) }
                .map_err(|e| vk_error("image view", e))?;
            return Ok(Arc::new(imported));
        }
        let alpha = if opaque && usage == Usage::Sampled {
            vk::ComponentSwizzle::ONE
        } else {
            vk::ComponentSwizzle::IDENTITY
        };
        let view = vk::ImageViewCreateInfo::default()
            .image(image)
            .view_type(vk::ImageViewType::TYPE_2D)
            .format(vk_format)
            .components(vk::ComponentMapping {
                r: vk::ComponentSwizzle::IDENTITY,
                g: vk::ComponentSwizzle::IDENTITY,
                b: vk::ComponentSwizzle::IDENTITY,
                a: alpha,
            })
            .subresource_range(color_range());
        // SAFETY: a view of the bound image.
        imported.view =
            unsafe { d.create_image_view(&view, None) }.map_err(|e| vk_error("image view", e))?;
        Ok(Arc::new(imported))
    }
}

impl Gpu {
    /// A device-local `FROST_FORMAT` image with `levels` mip levels; its view
    /// shows the last level, which is what frost passes render and sample.
    /// It lives in one of the allocator's shared blocks.
    pub(super) fn private_image(
        &self,
        kind: &'static str,
        size: (u32, u32),
        levels: u32,
        usage: vk::ImageUsageFlags,
    ) -> Result<Image> {
        self.allocate_private(kind, size, levels, usage, false)
    }

    /// A private image for one slice version, in memory of its own: the
    /// driver gets it back when the slice is dropped, and a slice never
    /// keeps a shared block alive. Slices are most of the composer's memory
    /// and come and go in bursts (the pool absorbs most of them).
    pub(super) fn slice_image(
        &self,
        size: (u32, u32),
        usage: vk::ImageUsageFlags,
    ) -> Result<Image> {
        self.allocate_private("slice", size, 1, usage, true)
    }

    fn allocate_private(
        &self,
        kind: &'static str,
        size: (u32, u32),
        levels: u32,
        usage: vk::ImageUsageFlags,
        own_memory: bool,
    ) -> Result<Image> {
        let gpu = &self.0;
        let d = &gpu.device;
        let create = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(FROST_FORMAT)
            .extent(vk::Extent3D {
                width: size.0,
                height: size.1,
                depth: 1,
            })
            .mip_levels(levels)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::OPTIMAL)
            .usage(usage)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED);
        // SAFETY: valid create info; Image's Drop destroys what was made.
        let image =
            unsafe { d.create_image(&create, None) }.map_err(|e| vk_error("private image", e))?;
        let mut private = Image {
            gpu: Arc::clone(gpu),
            image,
            memory: vk::DeviceMemory::null(),
            allocation: None,
            view: vk::ImageView::null(),
            format: FROST_FORMAT,
            size,
            sampled_layout: vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL,
            external: false,
            copyable: false,
            opaque: false,
            ycbcr: None,
        };
        // SAFETY: queries and allocation on the live device.
        unsafe {
            let requirements = d.get_image_memory_requirements(image);
            let allocation = lock(&gpu.allocator)
                .as_mut()
                .ok_or("Stagecraft: allocator gone")?
                .allocate(&AllocationCreateDesc {
                    name: kind,
                    requirements,
                    location: MemoryLocation::GpuOnly,
                    linear: false,
                    allocation_scheme: if own_memory {
                        AllocationScheme::DedicatedImage(image)
                    } else {
                        AllocationScheme::GpuAllocatorManaged
                    },
                })
                .map_err(|e| format!("Stagecraft private image memory: {e}"))?;
            let (memory, at) = (allocation.memory(), allocation.offset());
            // Dropping `private` frees it, bound or not.
            private.allocation = Some(allocation);
            d.bind_image_memory(image, memory, at)
                .map_err(|e| vk_error("bind private image", e))?;
            private.view = d
                .create_image_view(
                    &vk::ImageViewCreateInfo::default()
                        .image(image)
                        .view_type(vk::ImageViewType::TYPE_2D)
                        .format(FROST_FORMAT)
                        .subresource_range(level_range(levels - 1, 1)),
                    None,
                )
                .map_err(|e| vk_error("private image view", e))?;
        }
        Ok(private)
    }
}

impl Gpu {
    /// A private transparent 1x1 image in `GENERAL`, bound where a draw
    /// samples nothing.
    pub(super) fn placeholder(&self) -> Result<Arc<Image>> {
        let mut placeholder = self.private_image(
            "placeholder",
            (1, 1),
            1,
            vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::TRANSFER_DST,
        )?;
        placeholder.sampled_layout = vk::ImageLayout::GENERAL;
        let image = placeholder.image;
        // SAFETY: recording into the one-off buffer; the image is live.
        self.one_off("placeholder clear", |d, command| unsafe {
            let to_clear = [vk::ImageMemoryBarrier2::default()
                .old_layout(vk::ImageLayout::UNDEFINED)
                .new_layout(vk::ImageLayout::GENERAL)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_stage_mask(vk::PipelineStageFlags2::CLEAR)
                .dst_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                .image(image)
                .subresource_range(color_range())];
            d.cmd_pipeline_barrier2(
                command,
                &vk::DependencyInfo::default().image_memory_barriers(&to_clear),
            );
            d.cmd_clear_color_image(
                command,
                image,
                vk::ImageLayout::GENERAL,
                &vk::ClearColorValue { float32: [0.0; 4] },
                &[color_range()],
            );
            let to_sample = [vk::ImageMemoryBarrier2::default()
                .old_layout(vk::ImageLayout::GENERAL)
                .new_layout(vk::ImageLayout::GENERAL)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .src_stage_mask(vk::PipelineStageFlags2::CLEAR)
                .src_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)
                .image(image)
                .subresource_range(color_range())];
            d.cmd_pipeline_barrier2(
                command,
                &vk::DependencyInfo::default().image_memory_barriers(&to_sample),
            );
        })?;
        Ok(Arc::new(placeholder))
    }

    /// A private RGBA8 image SHM client pixels are copied into, sampled in
    /// `GENERAL`. Its contents are undefined until the first upload.
    pub(super) fn upload_image(&self, size: (u32, u32)) -> Result<Arc<Image>> {
        // SAFETY: a query on the live instance.
        let largest = unsafe {
            self.0
                .vulkan
                .instance
                .get_physical_device_properties(self.0.physical)
        }
        .limits
        .max_image_dimension2_d;
        if size.0 > largest || size.1 > largest {
            return Err(format!("Stagecraft: SHM image above {largest} pixels").into());
        }
        let mut image = self.private_image(
            "wl_shm copy",
            size,
            1,
            vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::TRANSFER_DST,
        )?;
        image.sampled_layout = vk::ImageLayout::GENERAL;
        Ok(Arc::new(image))
    }

    /// A merged native window's image: its layers render into it, then the
    /// frame samples it like a client buffer.
    pub(super) fn merge_image(&self, size: (u32, u32)) -> Result<Arc<Image>> {
        // SAFETY: a query on the live instance.
        let limits = unsafe {
            self.0
                .vulkan
                .instance
                .get_physical_device_properties(self.0.physical)
        }
        .limits;
        // Sampled, and drawn into as a framebuffer.
        let width = limits
            .max_image_dimension2_d
            .min(limits.max_framebuffer_width);
        let height = limits
            .max_image_dimension2_d
            .min(limits.max_framebuffer_height);
        if size.0 == 0 || size.1 == 0 || size.0 > width || size.1 > height {
            return Err(format!("Stagecraft: merged window outside {width}x{height}").into());
        }
        Ok(Arc::new(self.private_image(
            "merged window",
            size,
            1,
            vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::COLOR_ATTACHMENT,
        )?))
    }

    /// Records `commands` into a one-off command buffer, submits it and
    /// waits for the queue. Rare setup work only.
    fn one_off(
        &self,
        what: &'static str,
        commands: impl FnOnce(&ash::Device, vk::CommandBuffer),
    ) -> Result<()> {
        let gpu = &self.0;
        let d = &gpu.device;
        // SAFETY: a one-off submission on the live device; the buffer is
        // freed after the queue went idle.
        unsafe {
            let command = d
                .allocate_command_buffers(
                    &vk::CommandBufferAllocateInfo::default()
                        .command_pool(gpu.command_pool)
                        .level(vk::CommandBufferLevel::PRIMARY)
                        .command_buffer_count(1),
                )
                .map_err(|e| vk_error(what, e))?[0];
            let result = (|| {
                d.begin_command_buffer(
                    command,
                    &vk::CommandBufferBeginInfo::default()
                        .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT),
                )?;
                commands(d, command);
                d.end_command_buffer(command)?;
                let commands = [vk::CommandBufferSubmitInfo::default().command_buffer(command)];
                let _queue = shell_queue::lock();
                d.queue_submit2(
                    gpu.queue,
                    &[vk::SubmitInfo2::default().command_buffer_infos(&commands)],
                    vk::Fence::null(),
                )?;
                d.queue_wait_idle(gpu.queue)
            })();
            d.free_command_buffers(gpu.command_pool, &[command]);
            result.map_err(|e| vk_error(what, e))
        }
    }

    /// An app look as a filtered RGBA16F 3D image: `size`³ RGBA texels, red
    /// fastest (the `.cube` order), as GLES uploads it.
    pub(super) fn look_image(&self, size: u32, texels: &[f32]) -> Result<Arc<Image>> {
        let gpu = &self.0;
        let d = &gpu.device;
        if size == 0 || texels.len() != (size as usize).pow(3) * 4 {
            return Err("Stagecraft: look with a wrong texel count".into());
        }
        let format = vk::Format::R16G16B16A16_SFLOAT;
        let create = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_3D)
            .format(format)
            .extent(vk::Extent3D {
                width: size,
                height: size,
                depth: size,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::OPTIMAL)
            .usage(vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::TRANSFER_DST)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED);
        // SAFETY: valid create info; Image's Drop destroys what was made.
        let image =
            unsafe { d.create_image(&create, None) }.map_err(|e| vk_error("look image", e))?;
        let mut look = Image {
            gpu: Arc::clone(gpu),
            image,
            memory: vk::DeviceMemory::null(),
            allocation: None,
            view: vk::ImageView::null(),
            format,
            size: (size, size),
            sampled_layout: vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL,
            external: false,
            copyable: false,
            opaque: false,
            ycbcr: None,
        };
        let bytes = (texels.len() * 2) as vk::DeviceSize;
        // SAFETY: allocations on the live device; the staging buffer is
        // destroyed below, after the one-off copy completed.
        unsafe {
            let requirements = d.get_image_memory_requirements(image);
            let type_index = gpu
                .memory_type(
                    requirements.memory_type_bits,
                    vk::MemoryPropertyFlags::DEVICE_LOCAL,
                )
                .ok_or("Stagecraft found no device memory")?;
            look.memory = d
                .allocate_memory(
                    &vk::MemoryAllocateInfo::default()
                        .allocation_size(requirements.size)
                        .memory_type_index(type_index),
                    None,
                )
                .map_err(|e| vk_error("look memory", e))?;
            d.bind_image_memory(image, look.memory, 0)
                .map_err(|e| vk_error("bind look", e))?;
            look.view = d
                .create_image_view(
                    &vk::ImageViewCreateInfo::default()
                        .image(image)
                        .view_type(vk::ImageViewType::TYPE_3D)
                        .format(format)
                        .subresource_range(color_range()),
                    None,
                )
                .map_err(|e| vk_error("look view", e))?;
            let staging = d
                .create_buffer(
                    &vk::BufferCreateInfo::default()
                        .size(bytes)
                        .usage(vk::BufferUsageFlags::TRANSFER_SRC)
                        .sharing_mode(vk::SharingMode::EXCLUSIVE),
                    None,
                )
                .map_err(|e| vk_error("look staging", e))?;
            let uploaded = (|| -> Result<()> {
                let requirements = d.get_buffer_memory_requirements(staging);
                let type_index = gpu
                    .memory_type(
                        requirements.memory_type_bits,
                        vk::MemoryPropertyFlags::HOST_VISIBLE
                            | vk::MemoryPropertyFlags::HOST_COHERENT,
                    )
                    .ok_or("Stagecraft found no host-visible memory")?;
                let memory = d
                    .allocate_memory(
                        &vk::MemoryAllocateInfo::default()
                            .allocation_size(requirements.size)
                            .memory_type_index(type_index),
                        None,
                    )
                    .map_err(|e| vk_error("look staging memory", e))?;
                let copied = (|| -> Result<()> {
                    d.bind_buffer_memory(staging, memory, 0)
                        .map_err(|e| vk_error("bind look staging", e))?;
                    let mapped = d
                        .map_memory(memory, 0, bytes, vk::MemoryMapFlags::empty())
                        .map_err(|e| vk_error("map look staging", e))?;
                    let halves = std::slice::from_raw_parts_mut(mapped.cast::<u16>(), texels.len());
                    for (half, texel) in halves.iter_mut().zip(texels) {
                        *half = f16_bits(*texel);
                    }
                    d.unmap_memory(memory);
                    self.one_off("look upload", |d, command| {
                        let to_copy = [vk::ImageMemoryBarrier2::default()
                            .old_layout(vk::ImageLayout::UNDEFINED)
                            .new_layout(vk::ImageLayout::TRANSFER_DST_OPTIMAL)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_stage_mask(vk::PipelineStageFlags2::COPY)
                            .dst_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                            .image(image)
                            .subresource_range(color_range())];
                        d.cmd_pipeline_barrier2(
                            command,
                            &vk::DependencyInfo::default().image_memory_barriers(&to_copy),
                        );
                        d.cmd_copy_buffer_to_image(
                            command,
                            staging,
                            image,
                            vk::ImageLayout::TRANSFER_DST_OPTIMAL,
                            &[vk::BufferImageCopy::default()
                                .image_subresource(vk::ImageSubresourceLayers {
                                    aspect_mask: vk::ImageAspectFlags::COLOR,
                                    mip_level: 0,
                                    base_array_layer: 0,
                                    layer_count: 1,
                                })
                                .image_extent(vk::Extent3D {
                                    width: size,
                                    height: size,
                                    depth: size,
                                })],
                        );
                        let to_sample = [vk::ImageMemoryBarrier2::default()
                            .old_layout(vk::ImageLayout::TRANSFER_DST_OPTIMAL)
                            .new_layout(vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .src_stage_mask(vk::PipelineStageFlags2::COPY)
                            .src_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                            .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                            .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)
                            .image(image)
                            .subresource_range(color_range())];
                        d.cmd_pipeline_barrier2(
                            command,
                            &vk::DependencyInfo::default().image_memory_barriers(&to_sample),
                        );
                    })
                })();
                d.free_memory(memory, None);
                copied
            })();
            d.destroy_buffer(staging, None);
            uploaded?;
        }
        Ok(Arc::new(look))
    }
}

/// `value` as IEEE half-precision bits, rounded to nearest even.
fn f16_bits(value: f32) -> u16 {
    let bits = value.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exponent = ((bits >> 23) & 0xff) as i32;
    let mantissa = bits & 0x007f_ffff;
    if exponent == 0xff {
        // Infinity stays infinite; NaN stays NaN.
        return sign | 0x7c00 | if mantissa != 0 { 0x200 } else { 0 };
    }
    let half_exponent = exponent - 127 + 15;
    if half_exponent >= 0x1f {
        return sign | 0x7c00;
    }
    if half_exponent <= 0 {
        if half_exponent < -10 {
            return sign;
        }
        // Subnormal: shift the full mantissa into place, rounding.
        let full = mantissa | 0x0080_0000;
        let shift = (14 - half_exponent) as u32;
        let mut half = full >> shift;
        let rest = full & ((1 << shift) - 1);
        let halfway = 1 << (shift - 1);
        if rest > halfway || (rest == halfway && half & 1 == 1) {
            half += 1;
        }
        return sign | half as u16;
    }
    let mut half = ((half_exponent as u32) << 10) | (mantissa >> 13);
    let rest = mantissa & 0x1fff;
    if rest > 0x1000 || (rest == 0x1000 && half & 1 == 1) {
        // A carry into the exponent is the correct rounding.
        half += 1;
    }
    sign | half as u16
}

fn color_range() -> vk::ImageSubresourceRange {
    level_range(0, 1)
}

pub(super) fn level_range(first: u32, count: u32) -> vk::ImageSubresourceRange {
    vk::ImageSubresourceRange {
        aspect_mask: vk::ImageAspectFlags::COLOR,
        base_mip_level: first,
        level_count: count,
        base_array_layer: 0,
        layer_count: 1,
    }
}

pub(super) const MAX_FRAMES: usize = 8;

/// A run of draws sampling one image.
pub(super) struct Batch {
    pub(super) image: Arc<Image>,
    /// The look its clients are graded with; an identity stand-in when none.
    pub(super) look: Arc<Image>,
    pub(super) nearest: bool,
    pub(super) first: u32,
    pub(super) count: u32,
    /// What `image` holds for the frame: equal values, equal pixels.
    pub(super) content: u64,
    /// A client buffer whose changes the engine's frame damage reports: a
    /// new `content` changes what a frost reads only where that damage
    /// reaches it (`SceneComposer::resolve_frosts`).
    pub(super) damage_tracked: bool,
    /// A native window drawn from its layers: `image` is the lowest and
    /// these lie over it, each draw record naming their placement
    /// (`record::layered`). The layered programs draw the batch.
    pub(super) layers: Option<Layers>,
}

/// The images of a layered draw's further layers, lowest first; a layer
/// the window does not have holds a stand-in its record never samples.
pub(super) type Layers = Arc<[Arc<Image>; LAYERS]>;

/// Whether two draws sample the same further layers.
pub(super) fn same_layers(a: &Option<Layers>, b: &Option<Layers>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.iter().zip(b.iter()).all(|(a, b)| Arc::ptr_eq(a, b)),
        _ => false,
    }
}

/// A material: its frost (made first when `fresh`), then its glass record.
pub(super) struct MaterialStep {
    /// Index of its glass record; also its order among the frame's
    /// materials.
    pub(super) record: u32,
    pub(super) plan: FrostPlan,
    /// Set when the frame is submitted: a cached frost or new images.
    pub(super) frost: Option<Arc<Frost>>,
    pub(super) fresh: bool,
    /// Set with `frost`: what the frost reads below the material
    /// (`SceneComposer::resolve_frosts`), and the submission it was made
    /// for.
    pub(super) below: u64,
    pub(super) made: u64,
    /// A window over the material: drawn with it, instead of the glass
    /// quad.
    pub(super) window: Option<WindowDraw>,
    /// Frozen glass: the slice holding its frost, which it samples instead
    /// of a frost made from the target, and that slice's content.
    pub(super) frozen: Option<(Arc<Image>, u64)>,
}

/// A window drawn over its material (`Program::WindowGlass`).
pub(super) struct WindowDraw {
    /// Index of its draw record.
    pub(super) draw: u32,
    /// The client image, or a stand-in when it has none.
    pub(super) image: Arc<Image>,
    pub(super) look: Arc<Image>,
    pub(super) nearest: bool,
    /// What `image` holds for the frame, as `Batch::content`.
    pub(super) content: u64,
    /// As `Batch::layers` (`Program::WindowGlassLayered`).
    pub(super) layers: Option<Layers>,
}

/// Pixels a frame takes from the output buffer shown before it rather than
/// drawing them again: `rects` (left, top, right, bottom target pixels, as
/// the frame's area) of `source`, which holds that frame whole.
pub(super) struct Repair<'a> {
    pub(super) source: &'a Arc<Image>,
    pub(super) rects: &'a [[i32; 4]],
}

/// A native window's layers merged into its image before the frame draws:
/// `batches` name the layers' draw records, in paint order.
pub(super) struct Merge {
    pub(super) image: Arc<Image>,
    pub(super) batches: Vec<Batch>,
    /// The pixels drawn again, `[x, y, width, height]`, the rest kept as a
    /// submission drew them before; None draws the whole image.
    pub(super) area: Option<[u32; 4]>,
}

/// Renders each merge's layers into its image, or into its area, cleared
/// first, and makes the image readable by the frame's fragment shaders. Earlier submissions on
/// the queue may still sample an image: its writes wait for their reads.
///
/// # Safety
/// Recording into `command` outside any rendering; every image is retained
/// until the submission completes, and set 0 is bound.
unsafe fn record_merges(
    d: &ash::Device,
    command: vk::CommandBuffer,
    merges: &[Merge],
    pipeline: vk::Pipeline,
    push_images: &dyn Fn(&Image, bool, Option<&Image>, Option<&Image>),
) {
    let barriers = |to_draw: bool| -> Vec<_> {
        merges
            .iter()
            .map(|merge| {
                let barrier = vk::ImageMemoryBarrier2::default()
                    .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                    .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                    .image(merge.image.image)
                    .subresource_range(color_range());
                if to_draw {
                    // Cleared below: the old contents need not survive,
                    // unless outside the area drawn.
                    barrier
                        .old_layout(match merge.area {
                            Some(_) => merge.image.sampled_layout,
                            None => vk::ImageLayout::UNDEFINED,
                        })
                        .new_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
                        .src_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                        .dst_stage_mask(vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT)
                        .dst_access_mask(vk::AccessFlags2::COLOR_ATTACHMENT_WRITE)
                } else {
                    barrier
                        .old_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
                        .new_layout(merge.image.sampled_layout)
                        .src_stage_mask(vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT)
                        .src_access_mask(vk::AccessFlags2::COLOR_ATTACHMENT_WRITE)
                        .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                        .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)
                }
            })
            .collect()
    };
    // SAFETY: as the function's contract states.
    unsafe {
        d.cmd_pipeline_barrier2(
            command,
            &vk::DependencyInfo::default().image_memory_barriers(&barriers(true)),
        );
        d.cmd_bind_pipeline(command, vk::PipelineBindPoint::GRAPHICS, pipeline);
        for merge in merges {
            let (width, height) = merge.image.size;
            // The clear and the draws stay within the render area.
            let [x, y, area_width, area_height] = merge.area.unwrap_or([0, 0, width, height]);
            let area = vk::Rect2D {
                offset: vk::Offset2D {
                    x: x as i32,
                    y: y as i32,
                },
                extent: vk::Extent2D {
                    width: area_width,
                    height: area_height,
                },
            };
            let color = [vk::RenderingAttachmentInfo::default()
                .image_view(merge.image.view)
                .image_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
                .load_op(vk::AttachmentLoadOp::CLEAR)
                .store_op(vk::AttachmentStoreOp::STORE)
                .clear_value(vk::ClearValue {
                    color: vk::ClearColorValue { float32: [0.0; 4] },
                })];
            d.cmd_begin_rendering(
                command,
                &vk::RenderingInfo::default()
                    .render_area(area)
                    .layer_count(1)
                    .color_attachments(&color),
            );
            d.cmd_set_viewport(
                command,
                0,
                &[vk::Viewport {
                    x: 0.0,
                    y: 0.0,
                    width: width as f32,
                    height: height as f32,
                    min_depth: 0.0,
                    max_depth: 1.0,
                }],
            );
            d.cmd_set_scissor(command, 0, &[area]);
            for batch in &merge.batches {
                push_images(&batch.image, batch.nearest, Some(&batch.look), None);
                d.cmd_draw(command, 4, batch.count, 0, batch.first);
            }
            d.cmd_end_rendering(command);
        }
        d.cmd_pipeline_barrier2(
            command,
            &vk::DependencyInfo::default().image_memory_barriers(&barriers(false)),
        );
    }
}

/// What a composition records, in paint order.
pub(super) enum Step {
    Draws(Batch),
    Material(MaterialStep),
}

/// SHM client pixels copied into a private image (`Gpu::upload_image`)
/// before the frame draws.
pub(super) struct Upload {
    pub(super) image: Arc<Image>,
    pub(super) frame: crate::ShmTextureFrame,
    /// No submission wrote the image yet: its contents are undefined.
    pub(super) fresh: bool,
}

/// Staging kept by an idle frame between uploads; more is freed.
const STAGING_KEPT: u64 = 4 << 20;

/// How many draw, glass and clip records and path clip edges a frame's
/// record buffer holds, in that order. Each region is a power of two of at
/// least 64 records, so every region starts on a multiple of 256: any
/// device's storage offset alignment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Records {
    draws: usize,
    glasses: usize,
    clips: usize,
    edges: usize,
}

/// A path clip edge: x0, y0, x1, y1 in its clip's space.
type Edge = [f32; 4];

const _: () = assert!(std::mem::size_of::<Draw>() * 64 % 256 == 0);
const _: () = assert!(std::mem::size_of::<Glass>() * 64 % 256 == 0);
const _: () = assert!(std::mem::size_of::<ClipRecord>() * 64 % 256 == 0);
const _: () = assert!(std::mem::size_of::<Edge>() * 64 % 256 == 0);

impl Records {
    fn holds(self, draws: usize, glasses: usize, clips: usize, edges: usize) -> bool {
        draws <= self.draws && glasses <= self.glasses && clips <= self.clips && edges <= self.edges
    }

    /// Room for at least these records, never less than now.
    fn grown(self, draws: usize, glasses: usize, clips: usize, edges: usize) -> Self {
        let room = |wanted: usize, now: usize| wanted.max(now).next_power_of_two().max(64);
        Self {
            draws: room(draws, self.draws),
            glasses: room(glasses, self.glasses),
            clips: room(clips, self.clips),
            edges: room(edges, self.edges),
        }
    }

    /// Each region's byte offset and length: draws, glass records, clips,
    /// edges.
    fn ranges(self) -> [(u64, u64); 4] {
        let draws = (self.draws * std::mem::size_of::<Draw>()) as u64;
        let glasses = (self.glasses * std::mem::size_of::<Glass>()) as u64;
        let clips = (self.clips * std::mem::size_of::<ClipRecord>()) as u64;
        let edges = (self.edges * std::mem::size_of::<Edge>()) as u64;
        [
            (0, draws),
            (draws, glasses),
            (draws + glasses, clips),
            (draws + glasses + clips, edges),
        ]
    }

    fn size(self) -> u64 {
        let [.., (offset, range)] = self.ranges();
        offset + range
    }
}

/// Command resources for one submission in flight.
pub(super) struct Frame {
    gpu: Arc<GpuInner>,
    command: vk::CommandBuffer,
    /// Draw records, glass records, clips, then edges (`Records`).
    draws: vk::Buffer,
    draws_memory: vk::DeviceMemory,
    mapped: *mut u8,
    records: Records,
    draws_set: vk::DescriptorSet,
    wait: vk::Semaphore,
    signal: vk::Semaphore,
    /// Signalled by every submission: completion stays known when its
    /// sync file could not be exported or copied.
    fence: vk::Fence,
    /// A submission was made and has not been seen complete.
    in_flight: bool,
    /// `signal` was signalled with nothing to wait for it (its export
    /// failed): it is replaced before the next submission.
    signal_spent: bool,
    /// The submission's completion, while it may still run.
    pending: Option<OwnedFd>,
    pub(super) serial: u64,
    /// What the submission reads or writes, released when it completed.
    keep: Vec<Arc<Image>>,
    /// Host-visible source of the frame's uploads; null until one.
    staging: vk::Buffer,
    staging_memory: vk::DeviceMemory,
    staging_mapped: *mut u8,
    staging_capacity: u64,
    /// GPU timestamps of the pending submission (`gpu_timing`); null
    /// unless timing.
    queries: vk::QueryPool,
    /// The kind of each part the pending submission's timestamps end.
    query_kinds: Vec<u8>,
    /// Draw instances the pending submission draws.
    query_instances: u32,
}

/// GPU timing, a diagnostic: a timestamp after each part of a submission,
/// summed per kind of part and logged every 1000 submissions.
mod gpu_timing {
    use std::sync::Mutex;

    pub(super) const SLOTS: u32 = 512;
    /// What ran between a timestamp and the one before it.
    pub(super) const UPLOADS: u8 = 0;
    pub(super) const MERGES: u8 = 1;
    pub(super) const CLEAR: u8 = 2;
    pub(super) const DRAWS: u8 = 3;
    pub(super) const FROST: u8 = 4;
    pub(super) const GLASS: u8 = 5;
    pub(super) const WINDOW_GLASS: u8 = 6;
    pub(super) const REPAIR: u8 = 7;
    /// Draw batches by what they show: `DRAWS` shell slices drawn pixel for
    /// pixel, then placed slices, client textures and windows.
    pub(super) const DRAWS_PLACED: u8 = 8;
    pub(super) const DRAWS_TEXTURE: u8 = 9;
    pub(super) const DRAWS_WINDOW: u8 = 10;
    const NAMES: [&str; 11] = [
        "uploads",
        "merges",
        "clear",
        "draws",
        "frosts",
        "glass",
        "window_glass",
        "repair",
        "draws_placed",
        "draws_texture",
        "draws_window",
    ];

    struct Sums {
        frames: u64,
        total: f64,
        parts: [f64; 11],
        counts: [u64; 11],
        instances: u64,
    }

    static SUMS: Mutex<Sums> = Mutex::new(Sums {
        frames: 0,
        total: 0.0,
        parts: [0.0; 11],
        counts: [0; 11],
        instances: 0,
    });

    /// Adds one submission: `ticks[0]` starts it, `ticks[i]` ends a part of
    /// kind `kinds[i - 1]`. `instances` counts its draw instances.
    pub(super) fn add(ticks: &[u64], kinds: &[u8], instances: u32, period_ns: f32) {
        if ticks.len() < 2 || kinds.len() + 1 != ticks.len() {
            return;
        }
        let us = |a: u64, b: u64| b.wrapping_sub(a) as f64 * f64::from(period_ns) / 1000.0;
        let mut sums = SUMS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        sums.frames += 1;
        sums.total += us(ticks[0], ticks[ticks.len() - 1]);
        sums.instances += u64::from(instances);
        for (index, &kind) in kinds.iter().enumerate() {
            sums.parts[kind as usize] += us(ticks[index], ticks[index + 1]);
            sums.counts[kind as usize] += 1;
        }
        if sums.frames == 1000 {
            let f = sums.frames as f64;
            let parts: Vec<String> = (0..11)
                .map(|kind| {
                    format!(
                        "{}={:.0}us/{:.1}",
                        NAMES[kind],
                        sums.parts[kind] / f,
                        sums.counts[kind] as f64 / f
                    )
                })
                .collect();
            tracing::info!(
                frames = sums.frames,
                total_us = format!("{:.0}", sums.total / f),
                instances = format!("{:.1}", sums.instances as f64 / f),
                parts = parts.join(" "),
                "Stagecraft GPU time per submission (part=time/count)"
            );
            *sums = Sums {
                frames: 0,
                total: 0.0,
                parts: [0.0; 11],
                counts: [0; 11],
                instances: 0,
            };
        }
    }
}

// SAFETY: `mapped` points into memory this frame owns; the frame is used by
// one thread at a time behind the composer's lock.
unsafe impl Send for Frame {}

impl Drop for Frame {
    fn drop(&mut self) {
        if self.in_flight {
            self.wait_fence();
        }
        let d = &self.gpu.device;
        // SAFETY: the submission completed (above); the objects belong to
        // this frame. The descriptor set returns with the pool, which is
        // created without FREE_DESCRIPTOR_SET.
        unsafe {
            d.destroy_semaphore(self.wait, None);
            d.destroy_semaphore(self.signal, None);
            d.destroy_fence(self.fence, None);
            d.destroy_buffer(self.draws, None);
            d.free_memory(self.draws_memory, None);
            d.destroy_buffer(self.staging, None);
            d.free_memory(self.staging_memory, None);
            d.destroy_query_pool(self.queries, None);
            d.free_command_buffers(self.gpu.command_pool, &[self.command]);
        }
    }
}

trait AsFdRef {
    fn as_fd_ref(&self) -> BorrowedFd<'_>;
}

impl AsFdRef for OwnedFd {
    fn as_fd_ref(&self) -> BorrowedFd<'_> {
        use std::os::fd::AsFd;
        self.as_fd()
    }
}

/// Whether a sync_file signaled within `timeout_ms` (0 polls, -1 waits).
/// Whether `fd` became readable within `timeout_ms` (-1: until it does).
pub(super) fn wait_fd(fd: BorrowedFd<'_>, timeout_ms: i32) -> bool {
    let mut poll = libc::pollfd {
        fd: fd.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let deadline = (timeout_ms >= 0)
        .then(|| std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms as u64));
    loop {
        // An interrupted wait resumes with what is left of the timeout.
        let left = deadline.map_or(-1, |deadline| {
            deadline
                .saturating_duration_since(std::time::Instant::now())
                .as_millis()
                .min(i32::MAX as u128) as i32
        });
        // SAFETY: one valid pollfd.
        let result = unsafe { libc::poll(&mut poll, 1, left) };
        if result >= 0 {
            return result > 0;
        }
        match std::io::Error::last_os_error().kind() {
            // Interrupted with time left (or no limit): wait again.
            std::io::ErrorKind::Interrupted if left != 0 => {}
            // poll could not allocate: an unbounded wait tries again.
            std::io::ErrorKind::OutOfMemory if timeout_ms < 0 => {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            _ => return false,
        }
    }
}

impl Frame {
    pub(super) fn new(gpu: &Gpu) -> Result<Self> {
        let gpu = Arc::clone(&gpu.0);
        let d = &gpu.device;
        // SAFETY: allocations on the live device; Drop frees what was made.
        let command = unsafe {
            d.allocate_command_buffers(
                &vk::CommandBufferAllocateInfo::default()
                    .command_pool(gpu.command_pool)
                    .level(vk::CommandBufferLevel::PRIMARY)
                    .command_buffer_count(1),
            )
        }
        .map_err(|e| vk_error("command buffer", e))?[0];
        // Diagnostic: names the composer's buffers in validation reports.
        if std::env::var_os("DENIAL_VULKAN_VALIDATION").is_some() {
            tracing::info!(?command, "Stagecraft frame command buffer");
        }
        let mut frame = Self {
            gpu: Arc::clone(&gpu),
            command,
            draws: vk::Buffer::null(),
            draws_memory: vk::DeviceMemory::null(),
            mapped: std::ptr::null_mut(),
            records: Records::default(),
            draws_set: vk::DescriptorSet::null(),
            wait: vk::Semaphore::null(),
            signal: vk::Semaphore::null(),
            fence: vk::Fence::null(),
            in_flight: false,
            signal_spent: false,
            pending: None,
            serial: 0,
            keep: Vec::new(),
            staging: vk::Buffer::null(),
            staging_memory: vk::DeviceMemory::null(),
            staging_mapped: std::ptr::null_mut(),
            staging_capacity: 0,
            queries: vk::QueryPool::null(),
            query_kinds: Vec::new(),
            query_instances: 0,
        };
        // SAFETY: as above.
        unsafe {
            frame.wait = d
                .create_semaphore(&vk::SemaphoreCreateInfo::default(), None)
                .map_err(|e| vk_error("wait semaphore", e))?;
            frame.signal = export_semaphore(d)?;
            frame.fence = d
                .create_fence(&vk::FenceCreateInfo::default(), None)
                .map_err(|e| vk_error("frame fence", e))?;
            let layouts = [gpu.draws_layout];
            frame.draws_set = d
                .allocate_descriptor_sets(
                    &vk::DescriptorSetAllocateInfo::default()
                        .descriptor_pool(gpu.descriptor_pool)
                        .set_layouts(&layouts),
                )
                .map_err(|e| vk_error("draw descriptor set", e))?[0];
        }
        frame.reserve(1, 1, 1, 1)?;
        if gpu.timing.is_some() {
            // SAFETY: a query pool on the live device; Drop destroys it.
            frame.queries = unsafe {
                d.create_query_pool(
                    &vk::QueryPoolCreateInfo::default()
                        .query_type(vk::QueryType::TIMESTAMP)
                        .query_count(gpu_timing::SLOTS),
                    None,
                )
            }
            .map_err(|e| vk_error("timestamp queries", e))?;
        }
        Ok(frame)
    }

    /// Test hook: the frame is in flight on a submission that never ends
    /// (its fence is never submitted); `completion` stands for its sync
    /// file.
    #[cfg(test)]
    pub(super) fn set_stuck(&mut self, completion: OwnedFd) {
        self.pending = Some(completion);
        self.in_flight = true;
    }

    /// Test hook: the stuck submission ended.
    #[cfg(test)]
    pub(super) fn unstick(&mut self) {
        self.completed();
    }

    /// Forgets the submission's sync file, as when it could not be copied:
    /// only the fence tells completion.
    #[cfg(test)]
    pub(super) fn forget_completion(&mut self) {
        self.pending = None;
    }

    /// A copy of the pending submission's completion, None when the frame
    /// has none.
    pub(super) fn pending_completion(&self) -> Option<OwnedFd> {
        if !self.in_flight {
            return None;
        }
        self.pending
            .as_ref()
            .and_then(|fd| duplicate(fd.as_fd_ref()).ok())
    }

    /// Whether the last submission completed; true when none is pending.
    /// Releases what it held once it has.
    pub(super) fn idle(&mut self) -> bool {
        if self.in_flight {
            // The sync file signals before the fence (signal operation
            // order): only the fence says the submission is over.
            // SAFETY: the fence belongs to this frame's device.
            match unsafe { self.gpu.device.get_fence_status(self.fence) } {
                Ok(true) => self.completed(),
                Ok(false) => return false,
                Err(error) => {
                    vk_error("frame fence", error);
                    return false;
                }
            }
        }
        self.keep.clear();
        true
    }

    /// Waits until the submission is over: it completed, or the device is
    /// lost (its objects may then be destroyed). The wait ends: a GPU that
    /// stops completing work is reset, which signals or loses.
    fn wait_fence(&mut self) {
        loop {
            // SAFETY: the fence belongs to this frame's device.
            match unsafe {
                self.gpu
                    .device
                    .wait_for_fences(&[self.fence], true, u64::MAX)
            } {
                Ok(()) => {
                    self.completed();
                    return;
                }
                Err(vk::Result::ERROR_DEVICE_LOST) => {
                    vk_error("frame fence", vk::Result::ERROR_DEVICE_LOST);
                    self.in_flight = false;
                    self.pending = None;
                    return;
                }
                // Out of memory for the wait itself: the fence may still say
                // the work is over; until then what it uses stays held.
                Err(_) => {
                    // SAFETY: the fence belongs to this frame's device.
                    match unsafe { self.gpu.device.get_fence_status(self.fence) } {
                        Ok(true) => {
                            self.completed();
                            return;
                        }
                        Err(vk::Result::ERROR_DEVICE_LOST) => {
                            vk_error("frame fence", vk::Result::ERROR_DEVICE_LOST);
                            self.in_flight = false;
                            self.pending = None;
                            return;
                        }
                        _ => std::thread::sleep(std::time::Duration::from_millis(1)),
                    }
                }
            }
        }
    }

    /// The submission completed: what it held and measured is released.
    fn completed(&mut self) {
        self.in_flight = false;
        self.pending = None;
        {
            if let Some(period) = self.gpu.timing
                && !self.query_kinds.is_empty()
            {
                let mut ticks = vec![0u64; self.query_kinds.len() + 1];
                // SAFETY: the submission that wrote these completed.
                if unsafe {
                    self.gpu.device.get_query_pool_results(
                        self.queries,
                        0,
                        &mut ticks,
                        vk::QueryResultFlags::TYPE_64,
                    )
                }
                .is_ok()
                {
                    gpu_timing::add(&ticks, &self.query_kinds, self.query_instances, period);
                }
                self.query_kinds.clear();
            }
        }
        self.keep.clear();
    }

    fn reserve(&mut self, draws: usize, glasses: usize, clips: usize, edges: usize) -> Result<()> {
        if self.records.holds(draws, glasses, clips, edges) {
            return Ok(());
        }
        let records = self.records.grown(draws, glasses, clips, edges);
        let gpu = Arc::clone(&self.gpu);
        let d = &gpu.device;
        // SAFETY: the frame is idle (only called while recording); the old
        // buffer is no longer referenced by pending work.
        unsafe {
            d.destroy_buffer(self.draws, None);
            d.free_memory(self.draws_memory, None);
            self.draws = vk::Buffer::null();
            self.draws_memory = vk::DeviceMemory::null();
            self.mapped = std::ptr::null_mut();
            self.records = Records::default();
            self.draws = d
                .create_buffer(
                    &vk::BufferCreateInfo::default()
                        .size(records.size())
                        .usage(vk::BufferUsageFlags::STORAGE_BUFFER)
                        .sharing_mode(vk::SharingMode::EXCLUSIVE),
                    None,
                )
                .map_err(|e| vk_error("draw buffer", e))?;
            let requirements = d.get_buffer_memory_requirements(self.draws);
            let type_index = gpu
                .memory_type(
                    requirements.memory_type_bits,
                    vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
                )
                .ok_or("Stagecraft found no host-visible memory")?;
            self.draws_memory = d
                .allocate_memory(
                    &vk::MemoryAllocateInfo::default()
                        .allocation_size(requirements.size)
                        .memory_type_index(type_index),
                    None,
                )
                .map_err(|e| vk_error("draw memory", e))?;
            d.bind_buffer_memory(self.draws, self.draws_memory, 0)
                .map_err(|e| vk_error("bind draw memory", e))?;
            self.mapped = d
                .map_memory(
                    self.draws_memory,
                    0,
                    vk::WHOLE_SIZE,
                    vk::MemoryMapFlags::empty(),
                )
                .map_err(|e| vk_error("map draw memory", e))?
                .cast();
            let infos = records.ranges().map(|(offset, range)| {
                [vk::DescriptorBufferInfo::default()
                    .buffer(self.draws)
                    .offset(offset)
                    .range(range)]
            });
            let writes: [_; 4] = std::array::from_fn(|binding| {
                vk::WriteDescriptorSet::default()
                    .dst_set(self.draws_set)
                    .dst_binding(binding as u32)
                    .descriptor_type(vk::DescriptorType::STORAGE_BUFFER)
                    .buffer_info(&infos[binding])
            });
            d.update_descriptor_sets(&writes, &[]);
        }
        self.records = records;
        Ok(())
    }

    /// Makes the staging buffer hold `bytes` (none frees it, as does a
    /// frame without uploads holding more than `STAGING_KEPT`).
    fn reserve_staging(&mut self, bytes: u64) -> Result<()> {
        if bytes <= self.staging_capacity && (bytes > 0 || self.staging_capacity <= STAGING_KEPT) {
            return Ok(());
        }
        let capacity = bytes.next_power_of_two().max(64 << 10);
        let gpu = Arc::clone(&self.gpu);
        let d = &gpu.device;
        // SAFETY: the frame is idle; no pending work reads the old buffer.
        unsafe {
            d.destroy_buffer(self.staging, None);
            d.free_memory(self.staging_memory, None);
            self.staging = vk::Buffer::null();
            self.staging_memory = vk::DeviceMemory::null();
            self.staging_mapped = std::ptr::null_mut();
            self.staging_capacity = 0;
            if bytes == 0 {
                return Ok(());
            }
            self.staging = d
                .create_buffer(
                    &vk::BufferCreateInfo::default()
                        .size(capacity)
                        .usage(vk::BufferUsageFlags::TRANSFER_SRC)
                        .sharing_mode(vk::SharingMode::EXCLUSIVE),
                    None,
                )
                .map_err(|e| vk_error("staging buffer", e))?;
            let requirements = d.get_buffer_memory_requirements(self.staging);
            let type_index = gpu
                .memory_type(
                    requirements.memory_type_bits,
                    vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
                )
                .ok_or("Stagecraft found no host-visible memory")?;
            self.staging_memory = d
                .allocate_memory(
                    &vk::MemoryAllocateInfo::default()
                        .allocation_size(requirements.size)
                        .memory_type_index(type_index),
                    None,
                )
                .map_err(|e| vk_error("staging memory", e))?;
            d.bind_buffer_memory(self.staging, self.staging_memory, 0)
                .map_err(|e| vk_error("bind staging memory", e))?;
            self.staging_mapped = d
                .map_memory(
                    self.staging_memory,
                    0,
                    vk::WHOLE_SIZE,
                    vk::MemoryMapFlags::empty(),
                )
                .map_err(|e| vk_error("map staging memory", e))?
                .cast();
        }
        self.staging_capacity = capacity;
        Ok(())
    }

    /// Records and submits one composition into `target`, which is cleared
    /// first: `steps` in order, drawing `draws` and `glasses`. `wait` is a
    /// sync_file the submission waits for before any command. Returns the
    /// submission's completion sync_file. The frame must be idle.
    pub(super) fn submit(
        &mut self,
        serial: u64,
        target: &Arc<Image>,
        draws: &[Draw],
        glasses: &[Glass],
        clips: &[ClipRecord],
        edges: &[Edge],
        merges: &[Merge],
        steps: &[Step],
        uploads: &[Upload],
        area: [i32; 4],
        repair: Option<Repair<'_>>,
        wait: Option<OwnedFd>,
    ) -> Result<Option<OwnedFd>> {
        debug_assert!(!self.in_flight);
        let d = &self.gpu.device;
        if self.signal_spent {
            // SAFETY: the frame is idle: nothing waits on the old semaphore.
            unsafe {
                let fresh = export_semaphore(d)?;
                d.destroy_semaphore(std::mem::replace(&mut self.signal, fresh), None);
            }
            self.signal_spent = false;
        }
        // SAFETY: the frame is idle: its fence is not in use.
        unsafe { d.reset_fences(&[self.fence]) }.map_err(|e| vk_error("reset frame fence", e))?;
        // What the frame redraws (left, top, right, bottom target pixels, as
        // `FrostPlan::region`):
        // the whole target replaces its contents, part of it keeps the rest,
        // nothing leaves the target alone.
        let (width, height) = target.size;
        let whole =
            area[0] <= 0 && area[1] <= 0 && area[2] >= width as i32 && area[3] >= height as i32;
        // Target rows count up from the bottom (`record::ndc_from_target`):
        // Vulkan row H - y, as the frost copies map them.
        let [left, top, right, bottom] = [
            area[0].clamp(0, width as i32),
            area[1].clamp(0, height as i32),
            area[2].clamp(0, width as i32),
            area[3].clamp(0, height as i32),
        ];
        let area = vk::Rect2D {
            offset: vk::Offset2D {
                x: left,
                y: height as i32 - bottom,
            },
            extent: vk::Extent2D {
                width: (right - left).max(0) as u32,
                height: (bottom - top).max(0) as u32,
            },
        };
        let draws_target = area.extent.width > 0 && area.extent.height > 0;
        // The rest of what the frame changes comes from the buffer shown
        // before it, copied in before the frame draws.
        let repair = repair.filter(|repair| {
            draws_target
                && !whole
                && !repair.rects.is_empty()
                && target.copyable
                && repair.source.copyable
                && repair.source.size == target.size
                && repair.source.format == target.format
                && !Arc::ptr_eq(repair.source, target)
        });
        let layer = || vk::ImageSubresourceLayers {
            aspect_mask: vk::ImageAspectFlags::COLOR,
            mip_level: 0,
            base_array_layer: 0,
            layer_count: 1,
        };
        let repair_regions: Vec<vk::ImageCopy> = repair
            .iter()
            .flat_map(|repair| repair.rects)
            .filter_map(|&[l, t, r, b]| {
                let [l, t, r, b] = [
                    l.clamp(0, width as i32),
                    t.clamp(0, height as i32),
                    r.clamp(0, width as i32),
                    b.clamp(0, height as i32),
                ];
                (r > l && b > t).then(|| {
                    let offset = vk::Offset3D {
                        x: l,
                        y: height as i32 - b,
                        z: 0,
                    };
                    vk::ImageCopy::default()
                        .src_subresource(layer())
                        .dst_subresource(layer())
                        .src_offset(offset)
                        .dst_offset(offset)
                        .extent(vk::Extent3D {
                            width: (r - l) as u32,
                            height: (b - t) as u32,
                            depth: 1,
                        })
                })
            })
            .collect();
        let repair = repair.filter(|_| !repair_regions.is_empty());
        self.reserve(draws.len(), glasses.len(), clips.len(), edges.len())?;
        // Each upload's pixels, packed into staging in order.
        let mut copies = Vec::with_capacity(uploads.len());
        let mut staged_bytes = 0u64;
        for upload in uploads {
            let pixels = upload.frame.pixels();
            if upload.image.size != (upload.frame.width(), upload.frame.height()) {
                return Err("Stagecraft: upload into an image of another size".into());
            }
            copies.push((staged_bytes, pixels));
            staged_bytes += pixels.len() as u64;
        }
        self.reserve_staging(staged_bytes)?;
        for &(offset, pixels) in &copies {
            // SAFETY: staging holds `staged_bytes`, and no pending work
            // reads it (the frame is idle).
            unsafe {
                std::ptr::copy_nonoverlapping(
                    pixels.as_ptr(),
                    self.staging_mapped.add(offset as usize),
                    pixels.len(),
                );
            }
        }
        // SAFETY: each region of the mapping holds at least these records
        // (reserve), and no pending work reads it.
        unsafe {
            let [draw_at, glass_at, clip_at, edge_at] =
                self.records.ranges().map(|(offset, _)| offset as usize);
            std::ptr::copy_nonoverlapping(
                draws.as_ptr(),
                self.mapped.add(draw_at).cast::<Draw>(),
                draws.len(),
            );
            std::ptr::copy_nonoverlapping(
                glasses.as_ptr(),
                self.mapped.add(glass_at).cast::<Glass>(),
                glasses.len(),
            );
            std::ptr::copy_nonoverlapping(
                clips.as_ptr(),
                self.mapped.add(clip_at).cast::<ClipRecord>(),
                clips.len(),
            );
            std::ptr::copy_nonoverlapping(
                edges.as_ptr(),
                self.mapped.add(edge_at).cast::<Edge>(),
                edges.len(),
            );
        }
        let gpu = Arc::clone(&self.gpu);
        let d = &gpu.device;
        let compose = gpu.pipeline(Program::Compose, target.format)?;
        let glass = gpu.pipeline(Program::Glass, target.format)?;
        let window_glass = gpu.pipeline(Program::WindowGlass, target.format)?;
        let command = self.command;
        // Everything the submission reads or writes, target first.
        self.keep.clear();
        self.keep.push(Arc::clone(target));
        for upload in uploads {
            if !self
                .keep
                .iter()
                .any(|kept| Arc::ptr_eq(kept, &upload.image))
            {
                self.keep.push(Arc::clone(&upload.image));
            }
        }
        for merge in merges {
            let images = merge
                .batches
                .iter()
                .flat_map(|batch| [&batch.image, &batch.look])
                .chain(std::iter::once(&merge.image));
            for image in images {
                if !self.keep.iter().any(|kept| Arc::ptr_eq(kept, image)) {
                    self.keep.push(Arc::clone(image));
                }
            }
        }
        let merge_pipeline = match merges.first() {
            Some(merge) => gpu.pipeline(Program::Compose, merge.image.format)?,
            None => vk::Pipeline::null(),
        };
        let mut layered = false;
        for step in steps {
            let layers = match step {
                Step::Draws(batch) => batch.layers.as_ref(),
                Step::Material(material) => material
                    .window
                    .as_ref()
                    .and_then(|window| window.layers.as_ref()),
            };
            for image in layers.into_iter().flat_map(|layers| layers.iter()) {
                layered = true;
                if !self.keep.iter().any(|kept| Arc::ptr_eq(kept, image)) {
                    self.keep.push(Arc::clone(image));
                }
            }
            let images: [Option<&Arc<Image>>; 2] = match step {
                Step::Draws(batch) => [Some(&batch.image), Some(&batch.look)],
                Step::Material(MaterialStep {
                    frozen: Some((image, _)),
                    ..
                }) => [Some(image), None],
                Step::Material(material) => {
                    let frost = material
                        .frost
                        .as_ref()
                        .ok_or("Stagecraft: material without frost images")?;
                    [Some(&frost.tile), Some(&frost.scratch)]
                }
            };
            let window = match step {
                Step::Material(MaterialStep {
                    window: Some(window),
                    ..
                }) => [Some(&window.image), Some(&window.look)],
                _ => [None, None],
            };
            for image in images.into_iter().chain(window).flatten() {
                if !self.keep.iter().any(|kept| Arc::ptr_eq(kept, image)) {
                    self.keep.push(Arc::clone(image));
                }
            }
        }
        // Made when a frame first draws a window from its layers.
        let (compose_layered, window_glass_layered) = if layered {
            (
                gpu.pipeline(Program::ComposeLayered, target.format)?,
                gpu.pipeline(Program::WindowGlassLayered, target.format)?,
            )
        } else {
            (vk::Pipeline::null(), vk::Pipeline::null())
        };
        let fresh_frost = steps
            .iter()
            .any(|step| matches!(step, Step::Material(material) if material.fresh));
        if fresh_frost && !target.copyable {
            return Err("Stagecraft: materials on a target it cannot copy".into());
        }
        let foreign = vk::QUEUE_FAMILY_FOREIGN_EXT;
        // Sampled images stay GENERAL: ownership moves, the layout does not,
        // so the barriers carry no decompression.
        let sampled_barrier = |image: vk::Image, acquire: bool| {
            let barrier = vk::ImageMemoryBarrier2::default()
                .old_layout(vk::ImageLayout::GENERAL)
                .new_layout(vk::ImageLayout::GENERAL)
                .image(image)
                .subresource_range(color_range());
            if acquire {
                barrier
                    .src_queue_family_index(foreign)
                    .dst_queue_family_index(gpu.family)
                    .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                    .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)
            } else {
                barrier
                    .src_queue_family_index(gpu.family)
                    .dst_queue_family_index(foreign)
                    .src_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
            }
        };
        let target_acquire = if repair.is_some() {
            // The repair copy took it already.
            vk::ImageMemoryBarrier2::default()
                .old_layout(vk::ImageLayout::GENERAL)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .src_stage_mask(vk::PipelineStageFlags2::COPY)
                .src_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                .dst_access_mask(
                    vk::AccessFlags2::COLOR_ATTACHMENT_READ
                        | vk::AccessFlags2::COLOR_ATTACHMENT_WRITE,
                )
        } else if whole {
            // The target's old contents are replaced: no ownership to take,
            // nothing to keep.
            vk::ImageMemoryBarrier2::default()
                .old_layout(vk::ImageLayout::UNDEFINED)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_access_mask(vk::AccessFlags2::COLOR_ATTACHMENT_WRITE)
        } else {
            // Outside the area the target keeps what GLES or an earlier
            // submission left in it.
            vk::ImageMemoryBarrier2::default()
                .old_layout(vk::ImageLayout::GENERAL)
                .src_queue_family_index(foreign)
                .dst_queue_family_index(gpu.family)
                .dst_access_mask(
                    vk::AccessFlags2::COLOR_ATTACHMENT_READ
                        | vk::AccessFlags2::COLOR_ATTACHMENT_WRITE,
                )
        }
        .new_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
        .dst_stage_mask(vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT)
        .image(target.image)
        .subresource_range(color_range());
        let acquire: Vec<_> = self.keep[1..]
            .iter()
            .filter(|image| image.external)
            .map(|image| sampled_barrier(image.image, true))
            .chain(draws_target.then_some(target_acquire))
            .collect();
        let release: Vec<_> = self.keep[1..]
            .iter()
            .filter(|image| image.external)
            .map(|image| sampled_barrier(image.image, false))
            .chain(draws_target.then(|| {
                vk::ImageMemoryBarrier2::default()
                    .old_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
                    .new_layout(vk::ImageLayout::GENERAL)
                    .src_queue_family_index(gpu.family)
                    .dst_queue_family_index(foreign)
                    .src_stage_mask(vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT)
                    .src_access_mask(vk::AccessFlags2::COLOR_ATTACHMENT_WRITE)
                    .image(target.image)
                    .subresource_range(color_range())
            }))
            .collect();
        let mut release = release;
        if let Some(repair) = &repair {
            release.push(
                vk::ImageMemoryBarrier2::default()
                    .old_layout(vk::ImageLayout::GENERAL)
                    .new_layout(vk::ImageLayout::GENERAL)
                    .src_queue_family_index(gpu.family)
                    .dst_queue_family_index(foreign)
                    .src_stage_mask(vk::PipelineStageFlags2::COPY)
                    .image(repair.source.image)
                    .subresource_range(color_range()),
            );
            self.keep.push(Arc::clone(repair.source));
        }
        let attachment = |load: vk::AttachmentLoadOp| {
            [vk::RenderingAttachmentInfo::default()
                .image_view(target.view)
                .image_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
                .load_op(load)
                .store_op(vk::AttachmentStoreOp::STORE)
                .clear_value(vk::ClearValue {
                    color: vk::ClearColorValue { float32: [0.0; 4] },
                })]
        };
        // Renders into the target's area: cleared at the start, loaded after
        // a material's frost passes.
        let begin_target = |load: vk::AttachmentLoadOp| {
            let color = attachment(load);
            // SAFETY: recording; the target is COLOR_ATTACHMENT_OPTIMAL.
            unsafe {
                d.cmd_begin_rendering(
                    command,
                    &vk::RenderingInfo::default()
                        .render_area(area)
                        .layer_count(1)
                        .color_attachments(&color),
                );
                d.cmd_set_viewport(
                    command,
                    0,
                    &[vk::Viewport {
                        x: 0.0,
                        y: 0.0,
                        width: width as f32,
                        height: height as f32,
                        min_depth: 0.0,
                        max_depth: 1.0,
                    }],
                );
                d.cmd_set_scissor(command, 0, &[area]);
            }
        };
        // Binding 0, the client's look (binding 2) and, for a window over
        // its material, its frost (binding 1). The glass program reads
        // binding 0 only. A YCbCr image at binding 0 pushes into its
        // conversion's layout, whose binding 0 holds the sampler.
        let push_images =
            |image: &Image, nearest: bool, look: Option<&Image>, frost: Option<&Image>| {
                let info = |image: &Image, nearest: bool| {
                    [vk::DescriptorImageInfo::default()
                        .sampler(gpu.samplers[usize::from(!nearest)])
                        .image_view(image.view)
                        .image_layout(image.sampled_layout)]
                };
                let infos = [
                    Some(info(image, nearest)),
                    frost.map(|frost| info(frost, false)),
                    look.map(|look| info(look, false)),
                ];
                let mut writes = [vk::WriteDescriptorSet::default(); 3];
                let mut count = 0;
                for (binding, info) in infos.iter().enumerate() {
                    if let Some(info) = info {
                        writes[count] = vk::WriteDescriptorSet::default()
                            .dst_binding(binding as u32)
                            .descriptor_type(vk::DescriptorType::COMBINED_IMAGE_SAMPLER)
                            .image_info(info);
                        count += 1;
                    }
                }
                // SAFETY: recording; the images are retained by `keep`.
                unsafe {
                    gpu.push.cmd_push_descriptor_set(
                        command,
                        vk::PipelineBindPoint::GRAPHICS,
                        gpu.layout_for(image),
                        1,
                        &writes[..count],
                    )
                };
            };
        // Binding 3: a layered draw's further layers.
        let push_layers = |layers: &Layers, nearest: bool| {
            let infos: [vk::DescriptorImageInfo; LAYERS] = std::array::from_fn(|layer| {
                vk::DescriptorImageInfo::default()
                    .sampler(gpu.samplers[usize::from(!nearest)])
                    .image_view(layers[layer].view)
                    .image_layout(layers[layer].sampled_layout)
            });
            let writes = [vk::WriteDescriptorSet::default()
                .dst_binding(3)
                .descriptor_type(vk::DescriptorType::COMBINED_IMAGE_SAMPLER)
                .image_info(&infos)];
            // SAFETY: recording; the images are retained by `keep`.
            unsafe {
                gpu.push.cmd_push_descriptor_set(
                    command,
                    vk::PipelineBindPoint::GRAPHICS,
                    gpu.layout,
                    1,
                    &writes,
                )
            };
        };
        // SAFETY: the frame is idle, every handle is live and retained by
        // `keep` until the submission completes.
        unsafe {
            // The pool resets a buffer implicitly when it begins again.
            d.begin_command_buffer(
                command,
                &vk::CommandBufferBeginInfo::default()
                    .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT),
            )
            .map_err(|e| vk_error("begin commands", e))?;
            let timing = self.gpu.timing.is_some();
            let queries = self.queries;
            // Kinds of the parts stamped so far; the first stamp starts.
            let kinds = std::cell::RefCell::new(Vec::<u8>::new());
            let started = std::cell::Cell::new(false);
            let stamp = |kind: Option<u8>| {
                let mut kinds = kinds.borrow_mut();
                let next = kinds.len() as u32 + u32::from(started.get());
                if !timing || next >= gpu_timing::SLOTS {
                    return;
                }
                d.cmd_write_timestamp2(
                    command,
                    vk::PipelineStageFlags2::ALL_COMMANDS,
                    queries,
                    next,
                );
                match kind {
                    Some(kind) => kinds.push(kind),
                    None => started.set(true),
                }
            };
            if timing {
                d.cmd_reset_query_pool(command, queries, 0, gpu_timing::SLOTS);
            }
            stamp(None);
            if let Some(repair) = &repair {
                // Earlier submissions on this queue wrote the source and may
                // still read the target: the copy waits for both. Both stay
                // GENERAL, so nothing decompresses.
                let acquire = |image: vk::Image, access: vk::AccessFlags2| {
                    vk::ImageMemoryBarrier2::default()
                        .old_layout(vk::ImageLayout::GENERAL)
                        .new_layout(vk::ImageLayout::GENERAL)
                        .src_queue_family_index(foreign)
                        .dst_queue_family_index(gpu.family)
                        .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
                        .src_access_mask(vk::AccessFlags2::MEMORY_WRITE)
                        .dst_stage_mask(vk::PipelineStageFlags2::COPY)
                        .dst_access_mask(access)
                        .image(image)
                        .subresource_range(color_range())
                };
                let to_copy = [
                    acquire(repair.source.image, vk::AccessFlags2::TRANSFER_READ),
                    acquire(target.image, vk::AccessFlags2::TRANSFER_WRITE),
                ];
                d.cmd_pipeline_barrier2(
                    command,
                    &vk::DependencyInfo::default().image_memory_barriers(&to_copy),
                );
                d.cmd_copy_image(
                    command,
                    repair.source.image,
                    vk::ImageLayout::GENERAL,
                    target.image,
                    vk::ImageLayout::GENERAL,
                    &repair_regions,
                );
                stamp(Some(gpu_timing::REPAIR));
            }
            if !uploads.is_empty() {
                // Earlier submissions on this queue may still sample or
                // write the image: the copy waits for both.
                let to_copy: Vec<_> = uploads
                    .iter()
                    .map(|upload| {
                        let barrier = vk::ImageMemoryBarrier2::default()
                            .new_layout(vk::ImageLayout::GENERAL)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_stage_mask(vk::PipelineStageFlags2::COPY)
                            .dst_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                            .image(upload.image.image)
                            .subresource_range(color_range());
                        if upload.fresh {
                            barrier.old_layout(vk::ImageLayout::UNDEFINED)
                        } else {
                            barrier
                                .old_layout(vk::ImageLayout::GENERAL)
                                .src_stage_mask(
                                    vk::PipelineStageFlags2::FRAGMENT_SHADER
                                        | vk::PipelineStageFlags2::COPY,
                                )
                                .src_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                        }
                    })
                    .collect();
                d.cmd_pipeline_barrier2(
                    command,
                    &vk::DependencyInfo::default().image_memory_barriers(&to_copy),
                );
                for (upload, &(offset, _)) in uploads.iter().zip(&copies) {
                    let (width, height) = upload.image.size;
                    d.cmd_copy_buffer_to_image(
                        command,
                        self.staging,
                        upload.image.image,
                        vk::ImageLayout::GENERAL,
                        &[vk::BufferImageCopy::default()
                            .buffer_offset(offset)
                            .image_subresource(vk::ImageSubresourceLayers {
                                aspect_mask: vk::ImageAspectFlags::COLOR,
                                mip_level: 0,
                                base_array_layer: 0,
                                layer_count: 1,
                            })
                            .image_extent(vk::Extent3D {
                                width,
                                height,
                                depth: 1,
                            })],
                    );
                }
                let to_sample: Vec<_> = uploads
                    .iter()
                    .map(|upload| {
                        vk::ImageMemoryBarrier2::default()
                            .old_layout(vk::ImageLayout::GENERAL)
                            .new_layout(vk::ImageLayout::GENERAL)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .src_stage_mask(vk::PipelineStageFlags2::COPY)
                            .src_access_mask(vk::AccessFlags2::TRANSFER_WRITE)
                            .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                            .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)
                            .image(upload.image.image)
                            .subresource_range(color_range())
                    })
                    .collect();
                d.cmd_pipeline_barrier2(
                    command,
                    &vk::DependencyInfo::default().image_memory_barriers(&to_sample),
                );
            }
            // With the engine on this queue, its slice passes precede this
            // submission and leave each slice SHADER_READ_ONLY_OPTIMAL, the
            // layout the composer samples it in: one barrier makes their
            // writes, and the layout transitions whatever stage Impeller
            // ended them in, visible to sampling.
            let slices_written = [vk::MemoryBarrier2::default()
                .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
                .src_access_mask(vk::AccessFlags2::MEMORY_WRITE)
                .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)];
            let memory: &[vk::MemoryBarrier2] = &slices_written;
            d.cmd_pipeline_barrier2(
                command,
                &vk::DependencyInfo::default()
                    .memory_barriers(memory)
                    .image_memory_barriers(&acquire),
            );
            // Every pipeline layout shares set 0 and the push constants, so
            // set 0 stays bound throughout.
            d.cmd_bind_descriptor_sets(
                command,
                vk::PipelineBindPoint::GRAPHICS,
                gpu.layout,
                0,
                &[self.draws_set],
                &[],
            );
            stamp(Some(gpu_timing::UPLOADS));
            if !merges.is_empty() {
                record_merges(d, command, merges, merge_pipeline, &push_images);
            }
            stamp(Some(gpu_timing::MERGES));
            // Nothing changed: the target already shows the frame.
            let steps = if draws_target {
                begin_target(vk::AttachmentLoadOp::CLEAR);
                steps
            } else {
                &[]
            };
            stamp(Some(gpu_timing::CLEAR));
            let mut instances = 0u32;
            // The bound pipeline; null when unknown.
            let pipeline = std::cell::Cell::new(vk::Pipeline::null());
            let use_pipeline = |wanted: vk::Pipeline| {
                if pipeline.get() != wanted {
                    d.cmd_bind_pipeline(command, vk::PipelineBindPoint::GRAPHICS, wanted);
                    pipeline.set(wanted);
                }
            };
            // The glass program's record index (glass.frag's `GlassPass`).
            let push_glass = |record: u32| {
                d.cmd_push_constants(
                    command,
                    gpu.layout,
                    vk::ShaderStageFlags::FRAGMENT,
                    0,
                    &record.to_ne_bytes(),
                );
            };
            let mut bound: Option<(vk::ImageView, bool, vk::ImageView)> = None;
            for step in steps {
                match step {
                    Step::Draws(batch) => {
                        let key = (batch.image.view, batch.nearest, batch.look.view);
                        if let Some(layers) = &batch.layers {
                            use_pipeline(compose_layered);
                            push_images(&batch.image, batch.nearest, Some(&batch.look), None);
                            push_layers(layers, batch.nearest);
                            bound = Some(key);
                        } else {
                            use_pipeline(match batch.image.ycbcr {
                                Some(_) => {
                                    gpu.pipeline_for(Program::Compose, target.format, &batch.image)?
                                }
                                None => compose,
                            });
                            if bound != Some(key) {
                                push_images(&batch.image, batch.nearest, Some(&batch.look), None);
                                bound = Some(key);
                            }
                        }
                        d.cmd_draw(command, 4, batch.count, 0, batch.first);
                        instances += batch.count;
                        stamp(Some(match draws[batch.first as usize].kind() {
                            super::record::KIND_SLICE if batch.nearest => gpu_timing::DRAWS,
                            super::record::KIND_SLICE => gpu_timing::DRAWS_PLACED,
                            super::record::KIND_TEXTURE => gpu_timing::DRAWS_TEXTURE,
                            _ => gpu_timing::DRAWS_WINDOW,
                        }));
                    }
                    Step::Material(MaterialStep {
                        frozen: Some((image, _)),
                        record,
                        ..
                    }) => {
                        bound = None;
                        use_pipeline(glass);
                        push_images(image, false, None, None);
                        push_glass(*record);
                        d.cmd_draw(command, 4, 1, 0, *record);
                        stamp(Some(gpu_timing::GLASS));
                    }
                    Step::Material(material) => {
                        let Some(frost) = &material.frost else {
                            unreachable!("checked above");
                        };
                        if material.fresh {
                            d.cmd_end_rendering(command);
                            material::record(&gpu, command, target, frost, &material.plan)?;
                            stamp(Some(gpu_timing::FROST));
                            // The frost passes bound the blur pipeline.
                            pipeline.set(vk::Pipeline::null());
                            begin_target(vk::AttachmentLoadOp::LOAD);
                        }
                        bound = None;
                        if let Some(window) = &material.window {
                            match &window.layers {
                                Some(layers) => {
                                    use_pipeline(window_glass_layered);
                                    push_layers(layers, window.nearest);
                                }
                                None if window.image.ycbcr.is_some() => {
                                    use_pipeline(gpu.pipeline_for(
                                        Program::WindowGlass,
                                        target.format,
                                        &window.image,
                                    )?)
                                }
                                None => use_pipeline(window_glass),
                            }
                            push_images(
                                &window.image,
                                window.nearest,
                                Some(&window.look),
                                Some(&frost.tile),
                            );
                            d.cmd_draw(command, 4, 1, 0, window.draw);
                            stamp(Some(gpu_timing::WINDOW_GLASS));
                        } else {
                            use_pipeline(glass);
                            push_images(&frost.tile, false, None, None);
                            push_glass(material.record);
                            d.cmd_draw(command, 4, 1, 0, material.record);
                            stamp(Some(gpu_timing::GLASS));
                        }
                    }
                }
            }
            if draws_target {
                d.cmd_end_rendering(command);
            }
            self.query_kinds = kinds.into_inner();
            self.query_instances = instances;
            d.cmd_pipeline_barrier2(
                command,
                &vk::DependencyInfo::default().image_memory_barriers(&release),
            );
            d.end_command_buffer(command)
                .map_err(|e| vk_error("end commands", e))?;
        }
        let waits = if let Some(fd) = wait {
            // SAFETY: a temporary import consumes the descriptor on success.
            unsafe {
                gpu.semaphore_fd.import_semaphore_fd(
                    &vk::ImportSemaphoreFdInfoKHR::default()
                        .semaphore(self.wait)
                        .flags(vk::SemaphoreImportFlags::TEMPORARY)
                        .handle_type(vk::ExternalSemaphoreHandleTypeFlags::SYNC_FD)
                        .fd(fd.as_raw_fd()),
                )
            }
            .map_err(|e| vk_error("import producer fence", e))?;
            let _ = fd.into_raw_fd();
            // Ownership acquires run first, so the wait covers all commands.
            vec![
                vk::SemaphoreSubmitInfo::default()
                    .semaphore(self.wait)
                    .stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS),
            ]
        } else {
            Vec::new()
        };
        let commands = [vk::CommandBufferSubmitInfo::default().command_buffer(command)];
        let signals = [vk::SemaphoreSubmitInfo::default()
            .semaphore(self.signal)
            .stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)];
        let submit = vk::SubmitInfo2::default()
            .wait_semaphore_infos(&waits)
            .command_buffer_infos(&commands)
            .signal_semaphore_infos(&signals);
        // SAFETY: recorded above; the queue is used only behind the
        // composer's lock and the shared queue lock.
        unsafe {
            let _queue = shell_queue::lock();
            d.queue_submit2(gpu.queue, &[submit], self.fence)
        }
        .map_err(|e| vk_error("submit", e))?;
        self.serial = serial;
        self.in_flight = true;
        // SAFETY: the signal operation was just submitted.
        let exported = unsafe {
            gpu.semaphore_fd.get_semaphore_fd(
                &vk::SemaphoreGetFdInfoKHR::default()
                    .semaphore(self.signal)
                    .handle_type(vk::ExternalSemaphoreHandleTypeFlags::SYNC_FD),
            )
        };
        let fd = match exported {
            Ok(fd) => fd,
            Err(error) => {
                // The signal stays signalled with nothing to wait for it; a
                // binary semaphore cannot be signalled again, so the next
                // submission takes a fresh one.
                self.signal_spent = true;
                // Nothing downstream can wait for the work: it finishes
                // here, before the target and the clients it read are
                // handed on. The fence tells when.
                let error = vk_error("export completion", error);
                self.wait_fence();
                return if device_lost() { Err(error) } else { Ok(None) };
            }
        };
        if fd < 0 {
            // SYNC_FD export of an already signalled payload.
            return Ok(None);
        }
        // SAFETY: the export returned a new descriptor this call owns.
        let completion = unsafe { OwnedFd::from_raw_fd(fd) };
        match duplicate({
            use std::os::fd::AsFd;
            completion.as_fd()
        }) {
            Ok(pending) => self.pending = Some(pending),
            // Without a copy the fence tells completion.
            Err(_) => {}
        }
        Ok(Some(completion))
    }
}

/// One ownership and layout change of images the engine's Vulkan renderer
/// samples while it composes a frame the composer could not stage. Lending
/// waits for `wait` (GLES writes) and moves each image from where the
/// composer keeps it (FOREIGN and GENERAL for shared images) into
/// SHADER_READ_ONLY_OPTIMAL on this queue; returning moves it back. Every
/// later submission on the queue, the engine's included, is in the barrier's
/// second scope. Keeps the images until its fence signals.
pub(super) struct Transfer {
    gpu: Arc<GpuInner>,
    pool: vk::CommandPool,
    wait: vk::Semaphore,
    fence: vk::Fence,
    submitted: bool,
    images: Vec<Arc<Image>>,
}

impl Gpu {
    pub(super) fn transfer(
        &self,
        images: Vec<Arc<Image>>,
        lend: bool,
        wait: Option<OwnedFd>,
    ) -> Result<Transfer> {
        let gpu = Arc::clone(&self.0);
        let d = &gpu.device;
        let mut transfer = Transfer {
            gpu: Arc::clone(&gpu),
            pool: vk::CommandPool::null(),
            wait: vk::Semaphore::null(),
            fence: vk::Fence::null(),
            submitted: false,
            images,
        };
        // SAFETY: objects on the live device, destroyed by Drop; the pool is
        // this transfer's own, so no other thread records into it.
        let command = unsafe {
            transfer.pool = d
                .create_command_pool(
                    &vk::CommandPoolCreateInfo::default()
                        .flags(vk::CommandPoolCreateFlags::TRANSIENT)
                        .queue_family_index(gpu.family),
                    None,
                )
                .map_err(|e| vk_error("transfer command pool", e))?;
            transfer.fence = d
                .create_fence(&vk::FenceCreateInfo::default(), None)
                .map_err(|e| vk_error("transfer fence", e))?;
            d.allocate_command_buffers(
                &vk::CommandBufferAllocateInfo::default()
                    .command_pool(transfer.pool)
                    .level(vk::CommandBufferLevel::PRIMARY)
                    .command_buffer_count(1),
            )
            .map_err(|e| vk_error("transfer command buffer", e))?[0]
        };
        let foreign = vk::QUEUE_FAMILY_FOREIGN_EXT;
        let barriers: Vec<_> = transfer
            .images
            .iter()
            .map(|image| {
                let (from, to) = if image.external {
                    if lend {
                        (foreign, gpu.family)
                    } else {
                        (gpu.family, foreign)
                    }
                } else {
                    (vk::QUEUE_FAMILY_IGNORED, vk::QUEUE_FAMILY_IGNORED)
                };
                let barrier = vk::ImageMemoryBarrier2::default()
                    .src_queue_family_index(from)
                    .dst_queue_family_index(to)
                    .image(image.image)
                    .subresource_range(color_range());
                if lend {
                    barrier
                        .old_layout(image.sampled_layout)
                        .new_layout(vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL)
                        .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
                        .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
                        .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)
                } else {
                    barrier
                        .old_layout(vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL)
                        .new_layout(image.sampled_layout)
                        .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
                }
            })
            .collect();
        // Lending also makes every earlier write on the queue (the engine's
        // slice renders) visible to sampling.
        let written = [vk::MemoryBarrier2::default()
            .src_stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS)
            .src_access_mask(vk::AccessFlags2::MEMORY_WRITE)
            .dst_stage_mask(vk::PipelineStageFlags2::FRAGMENT_SHADER)
            .dst_access_mask(vk::AccessFlags2::SHADER_SAMPLED_READ)];
        let memory: &[vk::MemoryBarrier2] = if lend { &written } else { &[] };
        // SAFETY: recording into the command buffer allocated above.
        unsafe {
            d.begin_command_buffer(
                command,
                &vk::CommandBufferBeginInfo::default()
                    .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT),
            )
            .map_err(|e| vk_error("begin transfer", e))?;
            d.cmd_pipeline_barrier2(
                command,
                &vk::DependencyInfo::default()
                    .memory_barriers(memory)
                    .image_memory_barriers(&barriers),
            );
            d.end_command_buffer(command)
                .map_err(|e| vk_error("end transfer", e))?;
        }
        let waits = match wait {
            Some(fd) => {
                // SAFETY: a semaphore on the live device, destroyed by Drop;
                // a temporary import consumes the descriptor on success.
                unsafe {
                    transfer.wait = d
                        .create_semaphore(&vk::SemaphoreCreateInfo::default(), None)
                        .map_err(|e| vk_error("transfer semaphore", e))?;
                    gpu.semaphore_fd
                        .import_semaphore_fd(
                            &vk::ImportSemaphoreFdInfoKHR::default()
                                .semaphore(transfer.wait)
                                .flags(vk::SemaphoreImportFlags::TEMPORARY)
                                .handle_type(vk::ExternalSemaphoreHandleTypeFlags::SYNC_FD)
                                .fd(fd.as_raw_fd()),
                        )
                        .map_err(|e| vk_error("import transfer wait", e))?;
                }
                let _ = fd.into_raw_fd();
                vec![
                    vk::SemaphoreSubmitInfo::default()
                        .semaphore(transfer.wait)
                        .stage_mask(vk::PipelineStageFlags2::ALL_COMMANDS),
                ]
            }
            None => Vec::new(),
        };
        let commands = [vk::CommandBufferSubmitInfo::default().command_buffer(command)];
        let submit = vk::SubmitInfo2::default()
            .wait_semaphore_infos(&waits)
            .command_buffer_infos(&commands);
        // SAFETY: recorded above; the queue is used behind the shared lock.
        unsafe {
            let _queue = shell_queue::lock();
            d.queue_submit2(gpu.queue, &[submit], transfer.fence)
        }
        .map_err(|e| vk_error("submit transfer", e))?;
        transfer.submitted = true;
        Ok(transfer)
    }
}

impl Gpu {
    /// Blocks until the shared queue is idle. Failure paths only.
    pub(super) fn wait_queue_idle(&self) {
        let _queue = shell_queue::lock();
        // SAFETY: the queue is used behind the shared lock.
        if let Err(error) = unsafe { self.0.device.queue_wait_idle(self.0.queue) } {
            tracing::error!(%error, "could not wait for Stagecraft's queue");
        }
    }
}

impl Transfer {
    /// Its submission completed.
    pub(super) fn done(&self) -> bool {
        // SAFETY: a submitted fence of the live device.
        unsafe { self.gpu.device.get_fence_status(self.fence) }.unwrap_or(true)
    }
}

impl Drop for Transfer {
    fn drop(&mut self) {
        let d = &self.gpu.device;
        // SAFETY: a submitted fence of the live device. A device that hangs
        // gets two seconds.
        let idle = !self.submitted
            || unsafe { d.wait_for_fences(&[self.fence], true, 2_000_000_000) }.is_ok();
        if !idle {
            // Still in use by a hung queue: keep everything it references.
            tracing::error!("Stagecraft transfer did not complete; leaking its images");
            std::mem::forget(std::mem::take(&mut self.images));
            return;
        }
        // SAFETY: nothing pending uses these objects any more.
        unsafe {
            if self.wait != vk::Semaphore::null() {
                d.destroy_semaphore(self.wait, None);
            }
            if self.fence != vk::Fence::null() {
                d.destroy_fence(self.fence, None);
            }
            if self.pool != vk::CommandPool::null() {
                d.destroy_command_pool(self.pool, None);
            }
        }
    }
}
