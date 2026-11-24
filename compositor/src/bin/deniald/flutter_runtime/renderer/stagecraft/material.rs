//! Backdrop materials on the composer's queue: each material's frost is the
//! target as drawn so far, copied out of its region, halved with linear
//! blits and blurred with two Gaussian passes of the engine's strength. Recorded inline into the
//! frame's command buffer, between its draws, so a frame stays one submit.
//!
//! A frost is reused while the engine reports the scene below the material
//! unchanged (its backdrop token) and the plan is the same; only the glass
//! draw is recorded then.

use std::sync::Arc;

use ash::vk;

use super::device::{BlurPass, FROST_FORMAT, Gpu, GpuInner, Image, Program, level_range};
use super::record::FrostPlan;

type Result<T> = std::result::Result<T, String>;

/// Images one material's frost lives in.
pub(super) struct Frost {
    /// The copied region and its halvings, one mip level each. Its view
    /// shows the last level: the finished frost.
    pub(super) tile: Arc<Image>,
    /// The horizontal pass's result, the vertical pass's input.
    pub(super) scratch: Arc<Image>,
    region_size: (u32, u32),
    halvings: u32,
}

impl Frost {
    pub(super) fn new(gpu: &Gpu, plan: FrostPlan) -> Result<Self> {
        let size = plan.level_size(0);
        let last = plan.level_size(plan.levels() - 1);
        let tile = gpu.private_image(
            size,
            plan.levels(),
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
            region_size: plan.region_size(),
            halvings: plan.halvings,
        })
    }

    /// Whether these images have `plan`'s sizes.
    pub(super) fn fits(&self, plan: &FrostPlan) -> bool {
        self.region_size == plan.region_size() && self.halvings == plan.halvings
    }
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
    let constants = |step: [f32; 2], sigma: f32, radius: f32| BlurPass {
        step,
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
        constants([1.0 / width as f32, 0.0], plan.sigma[0], plan.radius[0]),
    );
    dependency(&[
        barrier(frost.scratch.image, whole, ATTACHMENT, SAMPLED),
        barrier(tile, level_range(last, 1), SAMPLED, ATTACHMENT),
    ]);
    pass(
        &frost.tile,
        &frost.scratch,
        constants([0.0, 1.0 / height as f32], plan.sigma[1], plan.radius[1]),
    );
    dependency(&[barrier(tile, level_range(last, 1), ATTACHMENT, SAMPLED)]);
    Ok(())
}
