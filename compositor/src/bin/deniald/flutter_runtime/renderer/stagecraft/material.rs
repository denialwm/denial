//! Backdrop materials on the composer's queue: each material's frost is the
//! target as drawn so far, copied out of its region, halved with linear
//! blits and blurred with two Gaussian passes of the engine's strength. Recorded inline into the
//! frame's command buffer, between its draws, so a frame stays one submit.
//!
//! A frost is reused while the engine reports the scene below the material
//! unchanged (its backdrop token) and the plan is the same; only the glass
//! draw is recorded then. Its images are kept while their sizes fit the
//! plan: a frost that grows or shrinks frame to frame (a window scaled by an
//! animation) is made again in the same images, with room to grow, and
//! takes new ones only once it outgrows them or uses less than half.

use std::sync::Arc;

use ash::vk;

use super::device::{BlurPass, FROST_FORMAT, Gpu, GpuInner, Image, Program, level_range};
use super::record::FrostPlan;

type Result<T> = std::result::Result<T, String>;

/// Images one material's frost lives in. A plan's texels sit at their top
/// left; the rest is room the frost may grow into.
pub(super) struct Frost {
    /// The copied region and its halvings, one mip level each. Its view
    /// shows the last level: the finished frost.
    pub(super) tile: Arc<Image>,
    /// The horizontal pass's result, the vertical pass's input.
    pub(super) scratch: Arc<Image>,
    /// Level 0's texels the images hold.
    storage: (u32, u32),
    halvings: u32,
    levels: u32,
}

impl Frost {
    /// Images exactly `plan`'s size.
    pub(super) fn new(gpu: &Gpu, plan: FrostPlan) -> Result<Self> {
        Self::holding(gpu, plan, plan.level_size(0))
    }

    /// Images with room for `plan` to grow by a quarter on each axis.
    pub(super) fn with_room(gpu: &Gpu, plan: FrostPlan) -> Result<Self> {
        Self::holding(gpu, plan, room(plan.level_size(0)))
    }

    fn holding(gpu: &Gpu, plan: FrostPlan, storage: (u32, u32)) -> Result<Self> {
        let levels = plan.levels();
        let last = level(storage, levels - 1);
        let tile = gpu.private_image(
            storage,
            levels,
            vk::ImageUsageFlags::TRANSFER_DST
                | vk::ImageUsageFlags::TRANSFER_SRC
                | vk::ImageUsageFlags::SAMPLED
                | vk::ImageUsageFlags::COLOR_ATTACHMENT,
        )?;
        let scratch = gpu.private_image(
            last,
            1,
            vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::COLOR_ATTACHMENT,
        )?;
        Ok(Self {
            tile: Arc::new(tile),
            scratch: Arc::new(scratch),
            storage,
            halvings: plan.halvings,
            levels,
        })
    }

    /// Whether `plan` can be made in these images: its levels fit, and they
    /// hold no more than twice the room `with_room` would give it.
    pub(super) fn fits(&self, plan: &FrostPlan) -> bool {
        let (width, height) = plan.level_size(0);
        let (room_width, room_height) = room((width, height));
        let area = |(w, h): (u32, u32)| u64::from(w) * u64::from(h);
        self.halvings == plan.halvings
            && self.levels == plan.levels()
            && width <= self.storage.0
            && height <= self.storage.1
            && area(self.storage) <= 2 * area((room_width, room_height))
    }

    /// The last level's texels the images hold: what the glass and the blur
    /// passes map texture coordinates over.
    pub(super) fn last_storage(&self) -> (u32, u32) {
        level(self.storage, self.levels - 1)
    }
}

/// Level 0's texels for a plan of `size` to grow into: a quarter more on
/// each axis, in steps of 16.
fn room((width, height): (u32, u32)) -> (u32, u32) {
    let grown = |value: u32| (value + value / 4).next_multiple_of(16);
    (grown(width), grown(height))
}

/// Mip `level`'s size of an image `size` at level 0, as Vulkan sizes it.
fn level((width, height): (u32, u32), level: u32) -> (u32, u32) {
    ((width >> level).max(1), (height >> level).max(1))
}

fn barrier(
    image: vk::Image,
    range: vk::ImageSubresourceRange,
    (old_layout, src_stage, src_access): (
        vk::ImageLayout,
        vk::PipelineStageFlags2,
        vk::AccessFlags2,
    ),
    (new_layout, dst_stage, dst_access): (
        vk::ImageLayout,
        vk::PipelineStageFlags2,
        vk::AccessFlags2,
    ),
) -> vk::ImageMemoryBarrier2<'static> {
    vk::ImageMemoryBarrier2::default()
        .old_layout(old_layout)
        .new_layout(new_layout)
        .src_stage_mask(src_stage)
        .src_access_mask(src_access)
        .dst_stage_mask(dst_stage)
        .dst_access_mask(dst_access)
        .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
        .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
        .image(image)
        .subresource_range(range)
}

type Access = (vk::ImageLayout, vk::PipelineStageFlags2, vk::AccessFlags2);

const ATTACHMENT: Access = (
    vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
    vk::PipelineStageFlags2::COLOR_ATTACHMENT_OUTPUT,
    vk::AccessFlags2::from_raw(
        vk::AccessFlags2::COLOR_ATTACHMENT_READ.as_raw()
            | vk::AccessFlags2::COLOR_ATTACHMENT_WRITE.as_raw(),
    ),
);
const BLIT_SOURCE: Access = (
    vk::ImageLayout::TRANSFER_SRC_OPTIMAL,
    vk::PipelineStageFlags2::BLIT,
    vk::AccessFlags2::TRANSFER_READ,
);
const BLIT_DESTINATION: Access = (
    vk::ImageLayout::TRANSFER_DST_OPTIMAL,
    vk::PipelineStageFlags2::BLIT,
    vk::AccessFlags2::TRANSFER_WRITE,
);
const SAMPLED: Access = (
    vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL,
    vk::PipelineStageFlags2::FRAGMENT_SHADER,
    vk::AccessFlags2::SHADER_SAMPLED_READ,
);
/// Contents discarded. The stages still order the new writes after an
/// earlier submission's blits, passes and glass draws on the same images
/// (a frost remade across frames); a rare path, so no finer mask.
const DISCARDED: Access = (
    vk::ImageLayout::UNDEFINED,
    vk::PipelineStageFlags2::ALL_COMMANDS,
    vk::AccessFlags2::NONE,
);

fn offset(x: u32, y: u32) -> vk::Offset3D {
    vk::Offset3D {
        x: x as i32,
        y: y as i32,
        z: 0,
    }
}

fn layer(level: u32) -> vk::ImageSubresourceLayers {
    vk::ImageSubresourceLayers {
        aspect_mask: vk::ImageAspectFlags::COLOR,
        mip_level: level,
        base_array_layer: 0,
        layer_count: 1,
    }
}

/// Records `frost`'s making from `target`, which is outside a render pass
/// in `COLOR_ATTACHMENT_OPTIMAL` and is left that way. The tile's last level
/// ends `SHADER_READ_ONLY_OPTIMAL`.
///
/// # Safety
/// `command` is recording, outside rendering; every handle is live until the
/// submission completes.
pub(super) unsafe fn record(
    gpu: &GpuInner,
    command: vk::CommandBuffer,
    target: &Image,
    frost: &Frost,
    plan: &FrostPlan,
) -> Result<()> {
    let d = &gpu.device;
    let blur = gpu.pipeline(Program::Blur, FROST_FORMAT)?;
    let tile = frost.tile.image;
    let levels = plan.levels();
    let last = levels - 1;
    let dependency = |barriers: &[vk::ImageMemoryBarrier2]| {
        // SAFETY: upheld by the caller.
        unsafe {
            d.cmd_pipeline_barrier2(
                command,
                &vk::DependencyInfo::default().image_memory_barriers(barriers),
            )
        }
    };
    let whole = level_range(0, 1);
    dependency(&[
        barrier(target.image, whole, ATTACHMENT, BLIT_SOURCE),
        barrier(tile, level_range(0, levels), DISCARDED, BLIT_DESTINATION),
    ]);
    // Target row y is memory row H - 1 - y: copy the region's memory rows
    // upside down, so the tile is top-down in target pixels.
    let (width0, height0) = plan.level_size(0);
    // Level 0 halves the pixels it covers exactly (or copies the region).
    let (covered_width, covered_height) = if plan.halvings > 0 {
        FrostPlan::covered_extent(plan.region_size(), (width0, height0))
    } else {
        plan.region_size()
    };
    let [left, top] = [plan.region[0] as u32, plan.region[1] as u32];
    let (right, bottom) = (left + covered_width, top + covered_height);
    let height = target.size.1;
    let blit = |source: vk::Image,
                source_layer: u32,
                from: [vk::Offset3D; 2],
                to_level: u32,
                to: [vk::Offset3D; 2],
                filter: vk::Filter| {
        let region = vk::ImageBlit::default()
            .src_subresource(layer(source_layer))
            .src_offsets(from)
            .dst_subresource(layer(to_level))
            .dst_offsets(to);
        // SAFETY: upheld by the caller; layouts set by the barriers above.
        unsafe {
            d.cmd_blit_image(
                command,
                source,
                vk::ImageLayout::TRANSFER_SRC_OPTIMAL,
                tile,
                vk::ImageLayout::TRANSFER_DST_OPTIMAL,
                &[region],
                filter,
            )
        }
    };
    blit(
        target.image,
        0,
        [
            offset(left, height - bottom),
            vk::Offset3D {
                z: 1,
                ..offset(right, height - top)
            },
        ],
        0,
        [
            offset(0, height0),
            vk::Offset3D {
                z: 1,
                ..offset(width0, 0)
            },
        ],
        if plan.halvings > 0 {
            vk::Filter::LINEAR
        } else {
            vk::Filter::NEAREST
        },
    );
    for level in 1..levels {
        dependency(&[barrier(
            tile,
            level_range(level - 1, 1),
            BLIT_DESTINATION,
            BLIT_SOURCE,
        )]);
        let (to_width, to_height) = plan.level_size(level);
        let (from_width, from_height) =
            FrostPlan::covered_extent(plan.level_size(level - 1), (to_width, to_height));
        blit(
            tile,
            level - 1,
            [
                offset(0, 0),
                vk::Offset3D {
                    z: 1,
                    ..offset(from_width, from_height)
                },
            ],
            level,
            [
                offset(0, 0),
                vk::Offset3D {
                    z: 1,
                    ..offset(to_width, to_height)
                },
            ],
            vk::Filter::LINEAR,
        );
    }
    dependency(&[
        barrier(tile, level_range(last, 1), BLIT_DESTINATION, SAMPLED),
        barrier(frost.scratch.image, whole, DISCARDED, ATTACHMENT),
        barrier(target.image, whole, BLIT_SOURCE, ATTACHMENT),
    ]);
    let (width, height) = plan.level_size(last);
    let area = vk::Rect2D {
        offset: vk::Offset2D { x: 0, y: 0 },
        extent: vk::Extent2D { width, height },
    };
    let pass = |into: &Image, from: &Image, constants: BlurPass| {
        let color = [vk::RenderingAttachmentInfo::default()
            .image_view(into.view)
            .image_layout(vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL)
            .load_op(vk::AttachmentLoadOp::DONT_CARE)
            .store_op(vk::AttachmentStoreOp::STORE)];
        let info = [vk::DescriptorImageInfo::default()
            .sampler(gpu.samplers[1])
            .image_view(from.view)
            .image_layout(vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL)];
        let write = vk::WriteDescriptorSet::default()
            .dst_binding(0)
            .descriptor_type(vk::DescriptorType::COMBINED_IMAGE_SAMPLER)
            .image_info(&info);
        // SAFETY: upheld by the caller.
        unsafe {
            d.cmd_begin_rendering(
                command,
                &vk::RenderingInfo::default()
                    .render_area(area)
                    .layer_count(1)
                    .color_attachments(&color),
            );
            gpu.push.cmd_push_descriptor_set(
                command,
                vk::PipelineBindPoint::GRAPHICS,
                gpu.layout,
                1,
                &[write],
            );
            let bytes = std::slice::from_raw_parts(
                (&raw const constants).cast::<u8>(),
                std::mem::size_of::<BlurPass>(),
            );
            d.cmd_push_constants(
                command,
                gpu.layout,
                vk::ShaderStageFlags::FRAGMENT,
                0,
                bytes,
            );
            d.cmd_draw(command, 3, 1, 0, 0);
            d.cmd_end_rendering(command);
        }
    };
    // Both passes read and write the plan's texels at the top left of the
    // last level's storage, clamped to them as the sampler clamps at an
    // image's edges.
    let (storage_width, storage_height) = frost.last_storage();
    let (sw, sh) = (storage_width as f32, storage_height as f32);
    let constants = |step: [f32; 2], sigma: f32, radius: f32| BlurPass {
        limits: [
            0.5 / sw,
            0.5 / sh,
            (width as f32 - 0.5) / sw,
            (height as f32 - 0.5) / sh,
        ],
        step,
        scale: [width as f32 / sw, height as f32 / sh],
        sigma: sigma.max(0.0001),
        radius: radius.clamp(0.0, 64.0),
    };
    // SAFETY: upheld by the caller.
    unsafe {
        d.cmd_bind_pipeline(command, vk::PipelineBindPoint::GRAPHICS, blur);
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
    pass(
        &frost.scratch,
        &frost.tile,
        constants([1.0 / sw, 0.0], plan.sigma[0], plan.radius[0]),
    );
    dependency(&[
        barrier(frost.scratch.image, whole, ATTACHMENT, SAMPLED),
        barrier(tile, level_range(last, 1), SAMPLED, ATTACHMENT),
    ]);
    pass(
        &frost.tile,
        &frost.scratch,
        constants([0.0, 1.0 / sh], plan.sigma[1], plan.radius[1]),
    );
    dependency(&[barrier(tile, level_range(last, 1), ATTACHMENT, SAMPLED)]);
    Ok(())
}
