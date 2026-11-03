//! Optional, dynamically loaded Vulkan image-to-DMA-BUF bridge.
//!
//! Flutter remains a GLES renderer. The caller must complete the GLES source
//! writer and the previous destination reader before `copy`; this milestone
//! uses a bounded host fence wait rather than sync-file semaphore interop.
//! Imports are pooled in `TransferPair`, including strong DMA-BUF leases.

use ash::{Entry, vk};
use smithay::backend::allocator::{
    Buffer, Fourcc, Modifier,
    dmabuf::{Dmabuf, DmabufFlags},
};
use std::{
    ffi::CStr,
    mem::MaybeUninit,
    os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd},
    sync::Arc,
};

const WAIT_NS: u64 = 1_000_000_000;
const HANDLE: vk::ExternalMemoryHandleTypeFlags = vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT;
const BUFFER_USAGE: vk::BufferUsageFlags = vk::BufferUsageFlags::TRANSFER_DST;

type Result<T> = std::result::Result<T, String>;

fn vk_error(stage: &str, error: vk::Result) -> String {
    format!("Vulkan transfer {stage}: {error:?}")
}

struct InstanceOwner {
    instance: ash::Instance,
    // The dynamic library must outlive every dispatch table.
    _entry: Entry,
}

impl Drop for InstanceOwner {
    fn drop(&mut self) {
        // SAFETY: All devices retain this owner and have already been destroyed.
        unsafe { self.instance.destroy_instance(None) };
    }
}

struct DeviceOwner {
    device: ash::Device,
    instance: Arc<InstanceOwner>,
    physical: vk::PhysicalDevice,
    fd_api: ash::khr::external_memory_fd::Device,
    memory: vk::PhysicalDeviceMemoryProperties,
    family: u32,
    queue: vk::Queue,
    pool: vk::CommandPool,
    command: vk::CommandBuffer,
    fence: vk::Fence,
    timestamp_pool: vk::QueryPool,
    timestamp_valid_bits: u32,
    timestamp_period: f32,
}

impl Drop for DeviceOwner {
    fn drop(&mut self) {
        // SAFETY: The last reference can only go away after submitted work
        // completed. A timed-out submission retains (or quarantines) its owner.
        unsafe {
            self.device.destroy_query_pool(self.timestamp_pool, None);
            self.device.destroy_fence(self.fence, None);
            self.device.destroy_command_pool(self.pool, None);
            self.device.destroy_device(None);
        }
    }
}

struct PairInner {
    owner: Arc<DeviceOwner>,
    image: vk::Image,
    image_memory: vk::DeviceMemory,
    buffer: vk::Buffer,
    buffer_memory: vk::DeviceMemory,
    region: vk::BufferImageCopy,
    _source: Dmabuf,
    _destination: Dmabuf,
}

impl Drop for PairInner {
    fn drop(&mut self) {
        // SAFETY: Partially constructed handles are null; completed pairs are
        // retained by the helper for the entire GPU submission lifetime.
        unsafe {
            self.owner.device.destroy_image(self.image, None);
            self.owner.device.destroy_buffer(self.buffer, None);
            self.owner.device.free_memory(self.image_memory, None);
            self.owner.device.free_memory(self.buffer_memory, None);
        }
    }
}

/// Reusable imports and allocation leases for one scene/LINEAR bridge pair.
/// The worker must retain this pair until its destination GLES reader finishes.
pub struct TransferPair(Arc<PairInner>);

/// One physical rendering GPU's transfer queue and reusable command resources.
/// Loader or capability absence is a candidate rejection, not a fatal backend
/// dependency. A failed/late submission poisons this helper; never resubmit it.
pub struct VulkanTransfer {
    owner: Arc<DeviceOwner>,
    pending: Option<Arc<PairInner>>,
    poisoned: bool,
    timestamp_result_warned: bool,
}

impl VulkanTransfer {
    pub fn new(source_fd: RawFd) -> Result<Self> {
        let device_number = device_number(source_fd)?;
        // SAFETY: ash owns the loaded library and validates required symbols.
        let entry = unsafe { Entry::load() }
            .map_err(|e| format!("Vulkan transfer loader unavailable: {e}"))?;
        // SAFETY: Query only; the entry is alive.
        let version = unsafe { entry.try_enumerate_instance_version() }
            .map_err(|e| vk_error("loader version", e))?
            .unwrap_or(vk::API_VERSION_1_0);
        if version < vk::API_VERSION_1_1 {
            return Err("Vulkan transfer requires Vulkan 1.1".into());
        }
        let instance_version = version.min(vk::API_VERSION_1_2);
        let app = vk::ApplicationInfo::default().api_version(instance_version);
        let create = vk::InstanceCreateInfo::default().application_info(&app);
        // SAFETY: Valid create-info and no borrowed pointers retained by Vulkan.
        let instance = unsafe { entry.create_instance(&create, None) }
            .map_err(|e| vk_error("create instance", e))?;
        let root = Arc::new(InstanceOwner {
            instance,
            _entry: entry,
        });
        let required = [
            ash::ext::physical_device_drm::NAME,
            ash::khr::external_memory_fd::NAME,
            ash::ext::external_memory_dma_buf::NAME,
            ash::ext::image_drm_format_modifier::NAME,
            ash::ext::queue_family_foreign::NAME,
        ];
        // SAFETY: The instance is live.
        let devices = unsafe { root.instance.enumerate_physical_devices() }
            .map_err(|e| vk_error("enumerate devices", e))?;
        let mut matched = None;
        for physical in devices {
            // SAFETY: Physical device belongs to this live instance.
            let extensions = unsafe {
                root.instance
                    .enumerate_device_extension_properties(physical)
            }
            .map_err(|e| vk_error("enumerate device extensions", e))?;
            let has = |name: &CStr| {
                extensions.iter().any(|e| {
                    // SAFETY: Vulkan extension names are NUL-terminated fixed arrays.
                    unsafe { CStr::from_ptr(e.extension_name.as_ptr()) == name }
                })
            };
            if !has(ash::ext::physical_device_drm::NAME) {
                continue;
            }
            let mut drm = vk::PhysicalDeviceDrmPropertiesEXT::default();
            let mut properties = vk::PhysicalDeviceProperties2::default().push_next(&mut drm);
            // SAFETY: This device advertises the DRM properties extension.
            unsafe {
                root.instance
                    .get_physical_device_properties2(physical, &mut properties)
            };
            let api_version = properties.properties.api_version;
            let identity_matches = (drm.has_render != 0
                && node_matches(device_number, drm.render_major, drm.render_minor))
                || (drm.has_primary != 0
                    && node_matches(device_number, drm.primary_major, drm.primary_minor));
            if !identity_matches {
                continue;
            }
            // DRM modifiers require image-format-list, either via Vulkan 1.2
            // or the device extension on a Vulkan 1.1 path.
            let needs_format_list =
                instance_version < vk::API_VERSION_1_2 || api_version < vk::API_VERSION_1_2;
            if api_version < vk::API_VERSION_1_1
                || required.iter().any(|e| !has(e))
                || (needs_format_list && !has(ash::khr::image_format_list::NAME))
            {
                return Err("Vulkan transfer source GPU lacks Vulkan 1.1 or required DMA-BUF/modifier/FOREIGN extensions".into());
            }
            // SAFETY: Valid physical device query.
            let families = unsafe {
                root.instance
                    .get_physical_device_queue_family_properties(physical)
            };
            let family = families
                .iter()
                .position(|q| {
                    q.queue_count > 0
                        && q.queue_flags.intersects(
                            vk::QueueFlags::TRANSFER
                                | vk::QueueFlags::GRAPHICS
                                | vk::QueueFlags::COMPUTE,
                        )
                })
                .ok_or_else(|| "Vulkan transfer source GPU has no transfer queue".to_string())?
                as u32;
            matched = Some((
                physical,
                family,
                needs_format_list,
                families[family as usize].timestamp_valid_bits,
            ));
            break;
        }
        let (physical, family, needs_format_list, timestamp_valid_bits) =
            matched.ok_or_else(|| {
                "Vulkan transfer cannot match source DRM FD to a Vulkan physical device".to_string()
            })?;
        let priorities = [1.0];
        let queues = [vk::DeviceQueueCreateInfo::default()
            .queue_family_index(family)
            .queue_priorities(&priorities)];
        let mut names: Vec<_> = required.iter().map(|e| e.as_ptr()).collect();
        if needs_format_list {
            names.push(ash::khr::image_format_list::NAME.as_ptr());
        }
        let create = vk::DeviceCreateInfo::default()
            .queue_create_infos(&queues)
            .enabled_extension_names(&names);
        // SAFETY: Required extensions were checked and family has a queue.
        let device = unsafe { root.instance.create_device(physical, &create, None) }
            .map_err(|e| vk_error("create device", e))?;
        let fd_api = ash::khr::external_memory_fd::Device::new(&root.instance, &device);
        // SAFETY: Physical/device queries with validated family/index.
        let (memory, queue) = unsafe {
            (
                root.instance
                    .get_physical_device_memory_properties(physical),
                device.get_device_queue(family, 0),
            )
        };
        // The owner cleans up partial construction through null handles.
        let mut owner = DeviceOwner {
            device,
            instance: root,
            physical,
            fd_api,
            memory,
            family,
            queue,
            pool: vk::CommandPool::null(),
            command: vk::CommandBuffer::null(),
            fence: vk::Fence::null(),
            timestamp_pool: vk::QueryPool::null(),
            timestamp_valid_bits,
            timestamp_period: 0.0,
        };
        let pool_info = vk::CommandPoolCreateInfo::default()
            .flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER)
            .queue_family_index(family);
        // SAFETY: Valid pool family; all partial resources have RAII owners.
        unsafe {
            owner.pool = owner
                .device
                .create_command_pool(&pool_info, None)
                .map_err(|e| vk_error("create command pool", e))?;
            let allocate = vk::CommandBufferAllocateInfo::default()
                .command_pool(owner.pool)
                .level(vk::CommandBufferLevel::PRIMARY)
                .command_buffer_count(1);
            owner.command = owner
                .device
                .allocate_command_buffers(&allocate)
                .map_err(|e| vk_error("allocate command buffer", e))?[0];
            owner.fence = owner
                .device
                .create_fence(&vk::FenceCreateInfo::default(), None)
                .map_err(|e| vk_error("create completion fence", e))?;
        }
        // SAFETY: The selected physical device belongs to the retained instance.
        let properties = unsafe {
            owner
                .instance
                .instance
                .get_physical_device_properties(physical)
        };
        owner.timestamp_period = properties.limits.timestamp_period;
        if crate::render_audit_enabled() {
            if (1..=64).contains(&timestamp_valid_bits)
                && owner.timestamp_period.is_finite()
                && owner.timestamp_period > 0.0
            {
                let query_info = vk::QueryPoolCreateInfo::default()
                    .query_type(vk::QueryType::TIMESTAMP)
                    .query_count(2);
                // SAFETY: Timestamp support was checked for the selected queue.
                match unsafe { owner.device.create_query_pool(&query_info, None) } {
                    Ok(pool) => owner.timestamp_pool = pool,
                    Err(error) => tracing::warn!(
                        ?error,
                        "Vulkan transfer GPU timestamp audit unavailable: query pool creation failed"
                    ),
                }
            } else {
                tracing::warn!(
                    timestamp_valid_bits,
                    timestamp_period = owner.timestamp_period,
                    "Vulkan transfer GPU timestamp audit unsupported on selected queue"
                );
            }
        }
        // SAFETY: Vulkan guarantees a NUL-terminated device name in this array.
        let device_name = unsafe { CStr::from_ptr(properties.device_name.as_ptr()) };
        tracing::info!(
            device = %device_name.to_string_lossy(),
            drm_major = libc::major(device_number),
            drm_minor = libc::minor(device_number),
            transfer_family = family,
            "Vulkan DMA-BUF transfer helper initialized"
        );
        Ok(Self {
            owner: Arc::new(owner),
            pending: None,
            poisoned: false,
            timestamp_result_warned: false,
        })
    }

    /// Exact importable TRANSFER_SRC capabilities for the single-memory-plane
    /// 8-bit source model. Intersect with EGL FBO-renderable capabilities before
    /// allocating, then validate the returned DMA-BUF metadata via import_pair.
    pub fn source_modifiers(&self, fourcc: Fourcc, width: u32, height: u32) -> Vec<Modifier> {
        let Some(format) = image_format(fourcc) else {
            return Vec::new();
        };
        self.modifier_properties(format)
            .into_iter()
            .filter(|m| {
                m.drm_format_modifier_plane_count == 1
                    && m.drm_format_modifier_tiling_features
                        .contains(vk::FormatFeatureFlags::TRANSFER_SRC)
            })
            .filter(|m| {
                self.check_source(format, m.drm_format_modifier, width, height)
                    .is_ok()
            })
            .map(|m| Modifier::from(m.drm_format_modifier))
            .filter(|m| *m != Modifier::Invalid)
            .collect()
    }

    fn modifier_properties(&self, format: vk::Format) -> Vec<vk::DrmFormatModifierPropertiesEXT> {
        let mut list = vk::DrmFormatModifierPropertiesListEXT::default();
        let mut properties = vk::FormatProperties2::default().push_next(&mut list);
        // SAFETY: Live device and extension checked at initialization. First
        // query obtains the count, second provides that many writable entries.
        unsafe {
            self.owner
                .instance
                .instance
                .get_physical_device_format_properties2(
                    self.owner.physical,
                    format,
                    &mut properties,
                )
        };
        let mut modifiers = vec![
            vk::DrmFormatModifierPropertiesEXT::default();
            list.drm_format_modifier_count as usize
        ];
        list.p_drm_format_modifier_properties = modifiers.as_mut_ptr();
        let mut properties = vk::FormatProperties2::default().push_next(&mut list);
        // SAFETY: List points to a vector with capacity equal to queried count.
        unsafe {
            self.owner
                .instance
                .instance
                .get_physical_device_format_properties2(
                    self.owner.physical,
                    format,
                    &mut properties,
                )
        };
        modifiers.truncate(list.drm_format_modifier_count as usize);
        modifiers
    }

    fn check_source(
        &self,
        format: vk::Format,
        modifier: u64,
        width: u32,
        height: u32,
    ) -> Result<()> {
        if width == 0 || height == 0 {
            return Err("Vulkan transfer empty source extent".into());
        }
        let mut drm = vk::PhysicalDeviceImageDrmFormatModifierInfoEXT::default()
            .drm_format_modifier(modifier)
            .sharing_mode(vk::SharingMode::EXCLUSIVE);
        let mut external = vk::PhysicalDeviceExternalImageFormatInfo::default().handle_type(HANDLE);
        let info = vk::PhysicalDeviceImageFormatInfo2::default()
            .format(format)
            .ty(vk::ImageType::TYPE_2D)
            .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
            .usage(vk::ImageUsageFlags::TRANSFER_SRC)
            .push_next(&mut drm)
            .push_next(&mut external);
        let mut external_properties = vk::ExternalImageFormatProperties::default();
        let mut properties =
            vk::ImageFormatProperties2::default().push_next(&mut external_properties);
        // SAFETY: Supported extension structures and exact create parameters.
        unsafe {
            self.owner
                .instance
                .instance
                .get_physical_device_image_format_properties2(
                    self.owner.physical,
                    &info,
                    &mut properties,
                )
        }
        .map_err(|e| vk_error("query source modifier/usage", e))?;
        let p = properties.image_format_properties;
        if width > p.max_extent.width
            || height > p.max_extent.height
            || p.max_extent.depth < 1
            || p.max_mip_levels < 1
            || p.max_array_layers < 1
            || !p.sample_counts.contains(vk::SampleCountFlags::TYPE_1)
        {
            return Err("Vulkan transfer source extent exceeds modifier/usage limits".into());
        }
        validate_external(
            external_properties.external_memory_properties,
            "source image",
        )
    }

    /// Import each allocation once with actual modifier, pitch, offset, FD masks
    /// and backing extent. Dedicated imports are valid and intentional even
    /// when the driver reports both dedicated-requirements flags as false.
    pub fn import_pair(
        &self,
        source: &Dmabuf,
        destination_linear: &Dmabuf,
    ) -> Result<TransferPair> {
        if self.poisoned {
            return Err("Vulkan transfer helper is poisoned after a failed submission".into());
        }
        let source_format = source.format();
        let destination_format = destination_linear.format();
        if source.num_planes() != 1 || destination_linear.num_planes() != 1 {
            return Err("Vulkan transfer requires one memory plane per DMA-BUF".into());
        }
        if source_format.code != destination_format.code
            || source.size() != destination_linear.size()
            || source.flags() != destination_linear.flags()
        {
            return Err(
                "Vulkan transfer source/bridge size, color format or orientation mismatch".into(),
            );
        }
        // Interlace or future unknown flags cannot be interpreted by this path.
        if source.flags().bits() & !DmabufFlags::Y_INVERT.bits() != 0 {
            return Err("Vulkan transfer unsupported DMA-BUF flags".into());
        }
        if source_format.modifier == Modifier::Invalid
            || destination_format.modifier != Modifier::Linear
        {
            return Err("Vulkan transfer needs explicit source and LINEAR bridge modifiers".into());
        }
        let format = image_format(source_format.code)
            .ok_or_else(|| "Vulkan transfer unsupported color format".to_string())?;
        let size = source.size();
        let width = u32::try_from(size.w).map_err(|_| "Vulkan transfer negative width")?;
        let height = u32::try_from(size.h).map_err(|_| "Vulkan transfer negative height")?;
        let modifier = u64::from(source_format.modifier);
        if !self.modifier_properties(format).iter().any(|m| {
            m.drm_format_modifier == modifier
                && m.drm_format_modifier_plane_count == 1
                && m.drm_format_modifier_tiling_features
                    .contains(vk::FormatFeatureFlags::TRANSFER_SRC)
        }) {
            return Err(
                "Vulkan transfer source modifier is not single-plane TRANSFER_SRC capable".into(),
            );
        }
        self.check_source(format, modifier, width, height)?;
        let source_fd = source.handles().next().unwrap().as_raw_fd();
        let destination_fd = destination_linear.handles().next().unwrap().as_raw_fd();
        let source_extent = backing_extent(source_fd)?;
        let destination_extent = backing_extent(destination_fd)?;
        if same_backing(source_fd, destination_fd)? {
            return Err("Vulkan transfer source and bridge alias the same DMA-BUF".into());
        }
        let pitch = destination_linear.strides().next().unwrap();
        let offset = destination_linear.offsets().next().unwrap();
        let layout = CopyLayout::new(width, height, pitch, u64::from(offset), destination_extent)?;
        let source_pitch = source.strides().next().unwrap();
        let source_offset = source.offsets().next().unwrap();
        if source_pitch == 0 || u64::from(source_offset) >= source_extent {
            return Err("Vulkan transfer invalid source pitch or offset".into());
        }
        // Exact bridge usage query; FD import capability is independent of image support.
        let external_info = vk::PhysicalDeviceExternalBufferInfo::default()
            .usage(BUFFER_USAGE)
            .handle_type(HANDLE);
        let mut external_properties = vk::ExternalBufferProperties::default();
        // SAFETY: Valid physical device and query structures.
        unsafe {
            self.owner
                .instance
                .instance
                .get_physical_device_external_buffer_properties(
                    self.owner.physical,
                    &external_info,
                    &mut external_properties,
                )
        };
        validate_external(
            external_properties.external_memory_properties,
            "bridge buffer",
        )?;
        let mut pair = PairInner {
            owner: self.owner.clone(),
            image: vk::Image::null(),
            image_memory: vk::DeviceMemory::null(),
            buffer: vk::Buffer::null(),
            buffer_memory: vk::DeviceMemory::null(),
            region: vk::BufferImageCopy::default()
                .buffer_offset(layout.offset)
                .buffer_row_length(layout.row_length)
                .buffer_image_height(height)
                .image_subresource(
                    vk::ImageSubresourceLayers::default()
                        .aspect_mask(vk::ImageAspectFlags::COLOR)
                        .mip_level(0)
                        .base_array_layer(0)
                        .layer_count(1),
                )
                .image_extent(vk::Extent3D {
                    width,
                    height,
                    depth: 1,
                }),
            _source: source.clone(),
            _destination: destination_linear.clone(),
        };
        let plane_layouts = [vk::SubresourceLayout {
            offset: u64::from(source_offset),
            size: 0,
            row_pitch: u64::from(source_pitch),
            array_pitch: 0,
            depth_pitch: 0,
        }];
        let mut drm = vk::ImageDrmFormatModifierExplicitCreateInfoEXT::default()
            .drm_format_modifier(modifier)
            .plane_layouts(&plane_layouts);
        let mut external = vk::ExternalMemoryImageCreateInfo::default().handle_types(HANDLE);
        let image_create = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(format)
            .extent(vk::Extent3D {
                width,
                height,
                depth: 1,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
            .usage(vk::ImageUsageFlags::TRANSFER_SRC)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED)
            .push_next(&mut drm)
            .push_next(&mut external);
        // SAFETY: Exact modifier/format/extent/usage checked above; layout is the
        // actual exported metadata. Partial resources are owned by `pair`.
        unsafe {
            pair.image = self
                .owner
                .device
                .create_image(&image_create, None)
                .map_err(|e| vk_error("create imported source image", e))?;
            let image_info = vk::ImageMemoryRequirementsInfo2::default().image(pair.image);
            let mut dedicated = vk::MemoryDedicatedRequirements::default();
            let mut requirements = vk::MemoryRequirements2::default().push_next(&mut dedicated);
            self.owner
                .device
                .get_image_memory_requirements2(&image_info, &mut requirements);
            pair.image_memory = self.import_memory(
                source_fd,
                source_extent,
                requirements.memory_requirements,
                pair.image,
                vk::Buffer::null(),
            )?;
            self.owner
                .device
                .bind_image_memory(pair.image, pair.image_memory, 0)
                .map_err(|e| vk_error("bind source image memory", e))?;
            let mut external = vk::ExternalMemoryBufferCreateInfo::default().handle_types(HANDLE);
            // Use the referenced copy span, not the whole backing allocation:
            // importing a whole allocation as a buffer can inflate requirements
            // past its real extent when the driver rounds resource sizes.
            let buffer_create = vk::BufferCreateInfo::default()
                .size(layout.end)
                .usage(BUFFER_USAGE)
                .sharing_mode(vk::SharingMode::EXCLUSIVE)
                .push_next(&mut external);
            pair.buffer = self
                .owner
                .device
                .create_buffer(&buffer_create, None)
                .map_err(|e| vk_error("create imported bridge buffer", e))?;
            let buffer_info = vk::BufferMemoryRequirementsInfo2::default().buffer(pair.buffer);
            let mut dedicated = vk::MemoryDedicatedRequirements::default();
            let mut requirements = vk::MemoryRequirements2::default().push_next(&mut dedicated);
            self.owner
                .device
                .get_buffer_memory_requirements2(&buffer_info, &mut requirements);
            pair.buffer_memory = self.import_memory(
                destination_fd,
                destination_extent,
                requirements.memory_requirements,
                vk::Image::null(),
                pair.buffer,
            )?;
            self.owner
                .device
                .bind_buffer_memory(pair.buffer, pair.buffer_memory, 0)
                .map_err(|e| vk_error("bind bridge buffer memory", e))?;
        }
        Ok(TransferPair(Arc::new(pair)))
    }

    fn import_memory(
        &self,
        fd: RawFd,
        extent: u64,
        requirements: vk::MemoryRequirements,
        image: vk::Image,
        buffer: vk::Buffer,
    ) -> Result<vk::DeviceMemory> {
        if requirements.size == 0 || requirements.size > extent {
            return Err(format!(
                "Vulkan transfer backing extent {extent} smaller than resource requirement {}",
                requirements.size
            ));
        }
        let mut properties = vk::MemoryFdPropertiesKHR::default();
        // SAFETY: Borrowed actual DMA-BUF FD; query does not consume it.
        unsafe {
            self.owner
                .fd_api
                .get_memory_fd_properties(HANDLE, fd, &mut properties)
        }
        .map_err(|e| vk_error("query DMA-BUF memory type mask", e))?;
        let types = compatible_memory_types(
            requirements.memory_type_bits,
            properties.memory_type_bits,
            &self.owner.memory,
        );
        if types.is_empty() {
            return Err(format!(
                "Vulkan transfer has no usable memory type (resource mask {:#x}, FD mask {:#x})",
                requirements.memory_type_bits, properties.memory_type_bits,
            ));
        }
        let mut last_error = vk::Result::ERROR_OUT_OF_DEVICE_MEMORY;
        for memory_type in types {
            let duplicate = duplicate_fd(fd)?;
            let mut dedicated = vk::MemoryDedicatedAllocateInfo::default()
                .image(image)
                .buffer(buffer);
            let mut import = vk::ImportMemoryFdInfoKHR::default()
                .handle_type(HANDLE)
                .fd(duplicate.as_raw_fd());
            let allocate = vk::MemoryAllocateInfo::default()
                .allocation_size(extent)
                .memory_type_index(memory_type)
                .push_next(&mut import)
                .push_next(&mut dedicated);
            // SAFETY: Actual FD mask intersection, sufficient backing extent,
            // valid dedicated resource and zero bind offset. Failure retains FD
            // ownership; successful DMA-BUF import transfers it to Vulkan.
            match unsafe { self.owner.device.allocate_memory(&allocate, None) } {
                Ok(memory) => {
                    let _ = duplicate.into_raw_fd();
                    return Ok(memory);
                }
                Err(error) => {
                    last_error = error;
                    if error == vk::Result::ERROR_DEVICE_LOST {
                        break;
                    }
                }
            }
        }
        Err(vk_error(
            "dedicated DMA-BUF memory import (all compatible types)",
            last_error,
        ))
    }

    /// Synchronous worker-side copy. Source ownership is acquired from EXTERNAL
    /// (same physical device GLES); bridge ownership from FOREIGN. Both are
    /// released before fence completion. The worker then samples on destination
    /// GLES and exports that final writer's fence for KMS.
    pub fn copy(&mut self, pair: &TransferPair) -> Result<()> {
        self.copy_timed(pair, None)
    }

    pub(super) fn copy_timed(
        &mut self,
        pair: &TransferPair,
        mut timing: Option<&mut super::Timings>,
    ) -> Result<()> {
        let start = timing.as_ref().map(|_| std::time::Instant::now());
        if self.poisoned {
            return Err("Vulkan transfer helper is poisoned after a failed submission".into());
        }
        if !Arc::ptr_eq(&pair.0.owner, &self.owner) {
            return Err("Vulkan transfer pair belongs to another helper".into());
        }
        let d = &self.owner.device;
        let command = self.owner.command;
        if let Some(timing) = timing.as_deref_mut() {
            timing.vk_gpu_us = None;
        }
        let timestamp_pool = self.owner.timestamp_pool;
        let gpu_timing = timing.is_some() && timestamp_pool != vk::QueryPool::null();
        // SAFETY: &mut self serializes pool, queue and fence use. Previous copy
        // completed or poisoned this helper. Pair keeps every referenced object
        // alive. Caller completed GLES writer/reader accesses as documented.
        unsafe {
            d.reset_command_buffer(command, vk::CommandBufferResetFlags::empty())
                .map_err(|e| vk_error("reset command buffer", e))?;
            d.begin_command_buffer(
                command,
                &vk::CommandBufferBeginInfo::default()
                    .flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT),
            )
            .map_err(|e| vk_error("begin transfer", e))?;
            if gpu_timing {
                // Reuse only after the previous submission's existing fence
                // completed. Reset is device-side, requiring no host-reset feature.
                d.cmd_reset_query_pool(command, timestamp_pool, 0, 2);
                d.cmd_write_timestamp(
                    command,
                    vk::PipelineStageFlags::TOP_OF_PIPE,
                    timestamp_pool,
                    0,
                );
            }
            let range = vk::ImageSubresourceRange::default()
                .aspect_mask(vk::ImageAspectFlags::COLOR)
                .base_mip_level(0)
                .level_count(1)
                .base_array_layer(0)
                .layer_count(1);
            let acquire_image = vk::ImageMemoryBarrier::default()
                .src_access_mask(vk::AccessFlags::empty())
                .dst_access_mask(vk::AccessFlags::TRANSFER_READ)
                .old_layout(vk::ImageLayout::GENERAL)
                .new_layout(vk::ImageLayout::TRANSFER_SRC_OPTIMAL)
                .src_queue_family_index(vk::QUEUE_FAMILY_EXTERNAL)
                .dst_queue_family_index(self.owner.family)
                .image(pair.0.image)
                .subresource_range(range);
            let acquire_buffer = vk::BufferMemoryBarrier::default()
                .src_access_mask(vk::AccessFlags::empty())
                .dst_access_mask(vk::AccessFlags::TRANSFER_WRITE)
                .src_queue_family_index(vk::QUEUE_FAMILY_FOREIGN_EXT)
                .dst_queue_family_index(self.owner.family)
                .buffer(pair.0.buffer)
                .offset(0)
                .size(vk::WHOLE_SIZE);
            d.cmd_pipeline_barrier(
                command,
                vk::PipelineStageFlags::TOP_OF_PIPE,
                vk::PipelineStageFlags::TRANSFER,
                vk::DependencyFlags::empty(),
                &[],
                &[acquire_buffer],
                &[acquire_image],
            );
            d.cmd_copy_image_to_buffer(
                command,
                pair.0.image,
                vk::ImageLayout::TRANSFER_SRC_OPTIMAL,
                pair.0.buffer,
                &[pair.0.region],
            );
            let release_image = vk::ImageMemoryBarrier::default()
                .src_access_mask(vk::AccessFlags::TRANSFER_READ)
                .dst_access_mask(vk::AccessFlags::empty())
                .old_layout(vk::ImageLayout::TRANSFER_SRC_OPTIMAL)
                .new_layout(vk::ImageLayout::GENERAL)
                .src_queue_family_index(self.owner.family)
                .dst_queue_family_index(vk::QUEUE_FAMILY_EXTERNAL)
                .image(pair.0.image)
                .subresource_range(range);
            let release_buffer = vk::BufferMemoryBarrier::default()
                .src_access_mask(vk::AccessFlags::TRANSFER_WRITE)
                .dst_access_mask(vk::AccessFlags::empty())
                .src_queue_family_index(self.owner.family)
                .dst_queue_family_index(vk::QUEUE_FAMILY_FOREIGN_EXT)
                .buffer(pair.0.buffer)
                .offset(0)
                .size(vk::WHOLE_SIZE);
            d.cmd_pipeline_barrier(
                command,
                vk::PipelineStageFlags::TRANSFER,
                vk::PipelineStageFlags::BOTTOM_OF_PIPE,
                vk::DependencyFlags::empty(),
                &[],
                &[release_buffer],
                &[release_image],
            );
            if gpu_timing {
                // Enclose the copy and both ownership/layout barriers, not
                // queue submission or the host's fence-wakeup latency.
                d.cmd_write_timestamp(
                    command,
                    vk::PipelineStageFlags::BOTTOM_OF_PIPE,
                    timestamp_pool,
                    1,
                );
            }
            d.end_command_buffer(command)
                .map_err(|e| vk_error("end transfer", e))?;
            d.reset_fences(&[self.owner.fence])
                .map_err(|e| vk_error("reset completion fence", e))?;
            let commands = [command];
            let submits = [vk::SubmitInfo::default().command_buffers(&commands)];
            self.pending = Some(pair.0.clone());
            if let (Some(timing), Some(start)) = (&mut timing, start) {
                timing.vk_record_us = super::micros(start);
            }
            let submit_start = timing.as_ref().map(|_| std::time::Instant::now());
            if let Err(error) = d.queue_submit(self.owner.queue, &submits, self.owner.fence) {
                self.poisoned = true;
                // Keep leases even on ambiguous submission failure until Drop
                // checks completion; never recycle resources into another route.
                return Err(vk_error("queue submit; helper poisoned", error));
            }
            if let (Some(timing), Some(start)) = (&mut timing, submit_start) {
                timing.vk_submit_us = super::micros(start);
            }
            let wait_start = timing.as_ref().map(|_| std::time::Instant::now());
            match d.wait_for_fences(&[self.owner.fence], true, WAIT_NS) {
                Ok(()) => {
                    if let (Some(timing), Some(start)) = (&mut timing, wait_start) {
                        timing.vk_wait_us = super::micros(start);
                    }
                    if gpu_timing {
                        let mut timestamps = [0u64; 2];
                        // No WAIT/PARTIAL flags: only accept complete results,
                        // after the fence wait already required by the copy.
                        match d.get_query_pool_results(
                            timestamp_pool,
                            0,
                            &mut timestamps,
                            vk::QueryResultFlags::TYPE_64,
                        ) {
                            Ok(()) => {
                                if let Some(timing) = timing.as_deref_mut() {
                                    timing.vk_gpu_us = Some(timestamp_elapsed_us(
                                        timestamps,
                                        self.owner.timestamp_valid_bits,
                                        self.owner.timestamp_period,
                                    ));
                                }
                            }
                            Err(error) => {
                                if !self.timestamp_result_warned {
                                    tracing::warn!(
                                        ?error,
                                        "Vulkan transfer GPU timestamp audit results unavailable after completion"
                                    );
                                    self.timestamp_result_warned = true;
                                }
                            }
                        }
                    }
                    self.pending = None;
                    Ok(())
                }
                Err(error) => {
                    self.poisoned = true;
                    Err(vk_error(
                        "bounded completion wait; helper poisoned and DMA-BUF leases retained",
                        error,
                    ))
                }
            }
        }
    }
}

fn timestamp_elapsed_us(timestamps: [u64; 2], valid_bits: u32, period: f32) -> f64 {
    // Subtract modulo the queue's counter width, including a 64-bit rollover.
    let mask = u64::MAX >> (64 - valid_bits);
    let ticks = timestamps[1].wrapping_sub(timestamps[0]) & mask;
    ticks as f64 * f64::from(period) / 1000.0
}

impl Drop for VulkanTransfer {
    fn drop(&mut self) {
        if let Some(pending) = self.pending.take() {
            // SAFETY: Live fence and owner retained by `pending`; nonblocking
            // query only. Device-loss permits freeing Vulkan resources, but
            // external allocation leases remain quarantined for driver safety.
            let complete = unsafe { self.owner.device.get_fence_status(self.owner.fence) };
            if complete != Ok(true) {
                // There is no safe bounded Vulkan cancellation primitive. Do
                // not block shutdown on vkDeviceWaitIdle or free in-flight
                // foreign memory. Quarantine this one poisoned helper and its
                // leases until process exit; normal and setup-failure paths are
                // fully RAII. New helpers are the caller's recovery decision.
                tracing::error!(
                    ?complete,
                    "Vulkan transfer quarantining unfinished DMA-BUF imports until process exit"
                );
                std::mem::forget(pending);
            }
        }
    }
}

fn validate_external(properties: vk::ExternalMemoryProperties, resource: &str) -> Result<()> {
    if !properties
        .external_memory_features
        .contains(vk::ExternalMemoryFeatureFlags::IMPORTABLE)
        || !properties.compatible_handle_types.contains(HANDLE)
    {
        return Err(format!(
            "Vulkan transfer {resource} is not DMA-BUF importable"
        ));
    }
    // DEDICATED_ONLY is satisfied unconditionally by this module's imports.
    Ok(())
}

fn image_format(fourcc: Fourcc) -> Option<vk::Format> {
    match fourcc {
        Fourcc::Argb8888 | Fourcc::Xrgb8888 => Some(vk::Format::B8G8R8A8_UNORM),
        Fourcc::Abgr8888 | Fourcc::Xbgr8888 => Some(vk::Format::R8G8B8A8_UNORM),
        _ => None,
    }
}

fn compatible_memory_types(
    resource_mask: u32,
    fd_mask: u32,
    memory: &vk::PhysicalDeviceMemoryProperties,
) -> Vec<u32> {
    (0..memory.memory_type_count.min(32))
        .filter(|i| {
            resource_mask & fd_mask & (1u32 << i) != 0
                && !memory.memory_types[*i as usize].property_flags.intersects(
                    vk::MemoryPropertyFlags::PROTECTED
                        | vk::MemoryPropertyFlags::DEVICE_COHERENT_AMD
                        | vk::MemoryPropertyFlags::LAZILY_ALLOCATED,
                )
        })
        .collect()
}

#[derive(Debug, PartialEq, Eq)]
struct CopyLayout {
    offset: u64,
    row_length: u32,
    end: u64,
}

impl CopyLayout {
    fn new(width: u32, height: u32, pitch: u32, offset: u64, backing: u64) -> Result<Self> {
        if width == 0
            || height == 0
            || pitch % 4 != 0
            || pitch > i32::MAX as u32
            || offset % 4 != 0
            || pitch / 4 < width
        {
            return Err("Vulkan transfer unrepresentable bridge pitch/offset/extent".into());
        }
        // Last row only references width texels; preceding rows include padding.
        let end = u64::from(height - 1)
            .checked_mul(u64::from(pitch))
            .and_then(|bytes| bytes.checked_add(u64::from(width) * 4))
            .and_then(|bytes| bytes.checked_add(offset))
            .ok_or_else(|| "Vulkan transfer bridge byte range overflow".to_string())?;
        if end > backing {
            return Err("Vulkan transfer bridge byte range exceeds DMA-BUF backing".into());
        }
        Ok(Self {
            offset,
            row_length: pitch / 4,
            end,
        })
    }
}

fn fd_stat(fd: RawFd) -> Result<libc::stat> {
    let mut stat = MaybeUninit::<libc::stat>::uninit();
    // SAFETY: fstat writes the entire stat on success; fd remains caller-owned.
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(format!(
            "Vulkan transfer fstat: {}",
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: Successful fstat initialized stat.
    Ok(unsafe { stat.assume_init() })
}

fn device_number(fd: RawFd) -> Result<libc::dev_t> {
    let stat = fd_stat(fd)?;
    if stat.st_mode & libc::S_IFMT != libc::S_IFCHR {
        return Err("Vulkan transfer source FD is not a DRM character device".into());
    }
    Ok(stat.st_rdev)
}

fn node_matches(device: libc::dev_t, major: i64, minor: i64) -> bool {
    major >= 0
        && minor >= 0
        && u64::from(libc::major(device)) == major as u64
        && u64::from(libc::minor(device)) == minor as u64
}

fn same_backing(a: RawFd, b: RawFd) -> Result<bool> {
    let a = fd_stat(a)?;
    let b = fd_stat(b)?;
    Ok(a.st_dev == b.st_dev && a.st_ino == b.st_ino)
}

fn duplicate_fd(fd: RawFd) -> Result<OwnedFd> {
    // SAFETY: Duplicates a borrowed FD without changing its ownership.
    let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
    if duplicate < 0 {
        return Err(format!(
            "Vulkan transfer duplicate DMA-BUF FD: {}",
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: Successful fcntl returns a new exclusively owned FD.
    Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
}

fn backing_extent(fd: RawFd) -> Result<u64> {
    let stat = fd_stat(fd)?;
    if stat.st_size > 0 {
        return Ok(stat.st_size as u64);
    }
    // DMA-BUF's documented llseek SEEK_END(0) yields its allocation size;
    // offsets have no read/write meaning. Use a temporary duplicate, retaining
    // the original lease, and restore the shared offset to zero as Smithay does.
    let duplicate = duplicate_fd(fd)?;
    // SAFETY: Live duplicate; DMA-BUF implements this query without mapping.
    let end = unsafe { libc::lseek(duplicate.as_raw_fd(), 0, libc::SEEK_END) };
    let error = (end <= 0).then(std::io::Error::last_os_error);
    // SAFETY: Restore the queried descriptor's offset; no memory access.
    unsafe { libc::lseek(duplicate.as_raw_fd(), 0, libc::SEEK_SET) };
    if let Some(error) = error {
        return Err(format!(
            "Vulkan transfer cannot query DMA-BUF backing extent: {error}"
        ));
    }
    Ok(end as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_timestamp_period_and_counter_rollover() {
        assert_eq!(timestamp_elapsed_us([100, 2100], 64, 2.5), 5.0);
        assert_eq!(timestamp_elapsed_us([u64::MAX - 3, 6], 64, 100.0), 1.0);
        assert_eq!(timestamp_elapsed_us([250, 4], 8, 100.0), 1.0);
        // Ignore undefined high bits for a narrower counter.
        assert_eq!(timestamp_elapsed_us([0x1fa, 0x204], 8, 100.0), 1.0);
        assert_eq!(timestamp_elapsed_us([9, 9], 36, 1.0), 0.0);
    }

    #[test]
    fn padded_rows_and_nonzero_offset() {
        assert_eq!(
            CopyLayout::new(73, 55, 512, 256, 32768).unwrap(),
            CopyLayout {
                offset: 256,
                row_length: 128,
                end: 28196
            }
        );
        // The last row's unreferenced padding is not required by the copy.
        assert!(CopyLayout::new(73, 55, 512, 256, 28196).is_ok());
        assert!(CopyLayout::new(73, 55, 512, 256, 28195).is_err());
    }

    #[test]
    fn reject_unrepresentable_layouts() {
        for (w, h, pitch, off) in [
            (0, 1, 4, 0),
            (1, 0, 4, 0),
            (2, 1, 4, 0),
            (1, 1, 5, 0),
            (1, 1, 4, 1),
        ] {
            assert!(CopyLayout::new(w, h, pitch, off, 100).is_err());
        }
        assert!(CopyLayout::new(1, 2, 4, u64::MAX - 3, u64::MAX).is_err());
        assert!(CopyLayout::new(1, 1, 0x8000_0000, 0, u64::MAX).is_err());
        assert!(CopyLayout::new(u32::MAX, 1, u32::MAX - 3, 0, u64::MAX).is_err());
    }

    #[test]
    fn native_and_single_row_ranges() {
        assert_eq!(
            CopyLayout::new(1920, 1200, 7680, 0, 9_216_000).unwrap().end,
            9_216_000
        );
        assert_eq!(CopyLayout::new(1, 1, 256, 8, 12).unwrap().end, 12);
    }

    #[test]
    fn memory_type_intersection_excludes_unsupported_features() {
        let mut memory = vk::PhysicalDeviceMemoryProperties {
            memory_type_count: 4,
            ..Default::default()
        };
        memory.memory_types[1].property_flags = vk::MemoryPropertyFlags::PROTECTED;
        memory.memory_types[0].property_flags = vk::MemoryPropertyFlags::DEVICE_COHERENT_AMD;
        memory.memory_types[2].property_flags = vk::MemoryPropertyFlags::LAZILY_ALLOCATED;
        assert_eq!(compatible_memory_types(0b1111, 0b1010, &memory), vec![3]);
        assert_eq!(compatible_memory_types(0b1111, 0b1111, &memory), vec![3]);
        assert!(compatible_memory_types(0b0001, 0b1000, &memory).is_empty());
    }

    #[test]
    fn explicit_channel_and_alpha_mapping() {
        assert_eq!(
            image_format(Fourcc::Argb8888),
            Some(vk::Format::B8G8R8A8_UNORM)
        );
        assert_eq!(
            image_format(Fourcc::Xrgb8888),
            Some(vk::Format::B8G8R8A8_UNORM)
        );
        assert_eq!(
            image_format(Fourcc::Abgr8888),
            Some(vk::Format::R8G8B8A8_UNORM)
        );
        assert_eq!(
            image_format(Fourcc::Xbgr8888),
            Some(vk::Format::R8G8B8A8_UNORM)
        );
        assert_eq!(image_format(Fourcc::Nv12), None);
    }

    #[test]
    fn device_identity_uses_both_drm_node_numbers() {
        let device = libc::makedev(226, 128);
        assert!(node_matches(device, 226, 128));
        assert!(!node_matches(device, 226, 129));
        assert!(!node_matches(device, -1, 128));
    }
}
