//! GLES atlas rendering and DRM plane-state construction primitives.

use super::*;

pub(super) fn render_diagnostic_atlas(
    renderer: &mut GlesRenderer,
    dmabuf: &mut Dmabuf,
    atlas_size: PixelSize,
    scanouts: &[Scanout],
    frame_number: u64,
) -> Result<(), Box<dyn Error>> {
    let render_size = (
        i32::try_from(atlas_size.width)?,
        i32::try_from(atlas_size.height)?,
    )
        .into();
    let mut framebuffer = renderer.bind(dmabuf)?;
    let mut frame = renderer.render(&mut framebuffer, render_size, Transform::Normal)?;
    frame.clear(
        Color32F::new(0.015, 0.02, 0.035, 1.0),
        &[Rectangle::from_size(render_size)],
    )?;

    for (index, scanout) in scanouts.iter().enumerate() {
        let rect = physical_rect(scanout.source_rect)?;
        frame.clear(COLORS[index % COLORS.len()], &[rect])?;

        let marker_size = (
            (rect.size.w / 7).clamp(24, 240),
            (rect.size.h / 9).clamp(24, 180),
        );
        let travel = rect
            .size
            .w
            .saturating_sub(marker_size.0)
            .saturating_sub(64)
            .max(1);
        let phase = ((frame_number.saturating_mul(12) + index as u64 * 97)
            % u64::try_from(travel.saturating_mul(2))?) as i32;
        let offset = if phase <= travel {
            phase
        } else {
            travel.saturating_mul(2) - phase
        };
        let marker = Rectangle::new(
            (rect.loc.x + 32 + offset, rect.loc.y + 32).into(),
            marker_size.into(),
        );
        frame.clear(Color32F::new(0.96, 0.98, 1.0, 1.0), &[marker])?;
    }

    frame.finish()?.wait()?;
    Ok(())
}

pub(super) fn render_blank_target(
    renderer: &mut GlesRenderer,
    dmabuf: &mut Dmabuf,
    target_size: PixelSize,
) -> Result<(), Box<dyn Error>> {
    let render_size = (
        i32::try_from(target_size.width)?,
        i32::try_from(target_size.height)?,
    )
        .into();
    let mut framebuffer = renderer.bind(dmabuf)?;
    let mut frame = renderer.render(&mut framebuffer, render_size, Transform::Normal)?;
    frame.clear(
        Color32F::new(0.0, 0.0, 0.0, 1.0),
        &[Rectangle::from_size(render_size)],
    )?;
    frame.finish()?.wait()?;
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn render_blank_output_swapchains(
    renderer: &mut GlesRenderer,
    swapchains: &mut OutputSwapchains,
) -> Result<(), Box<dyn Error>> {
    for pool in &mut swapchains.outputs {
        let buffer = pool
            .buffers
            .get_mut(pool.current)
            .ok_or("physical output's initial scanout index exceeds its pool")?;
        render_blank_target(renderer, &mut buffer.dmabuf, pool.size)?;
    }
    Ok(())
}

pub(super) fn plane_state(
    scanout: &Scanout,
    framebuffer: smithay::reexports::drm::control::framebuffer::Handle,
) -> PlaneState<'static> {
    plane_state_for_mode_and_source(
        scanout,
        framebuffer,
        scanout.output.mode,
        scanout.source_rect,
        smithay_output_transform(scanout.output.transform),
    )
}

pub(super) fn current_scanout_state(
    scanout: &Scanout,
    swapchain: &RenderSwapchains,
) -> Result<(framebuffer::Handle, PlaneState<'static>), Box<dyn Error>> {
    #[cfg(feature = "flutter")]
    if let Some(outputs) = swapchain.outputs() {
        let pool = outputs
            .for_output(scanout.output.id)
            .ok_or("scanout has no physical Flutter buffer pool")?;
        let framebuffer = pool
            .buffers
            .get(pool.current)
            .ok_or("physical Flutter scanout index exceeds its pool")?
            .framebuffer();
        return Ok((
            framebuffer,
            output_plane_state(scanout, framebuffer, pool.size),
        ));
    }
    let framebuffer = swapchain
        .atlas()
        .ok_or("diagnostic scanout has no atlas swapchain")?
        .current_framebuffer();
    Ok((framebuffer, plane_state(scanout, framebuffer)))
}

#[cfg(feature = "flutter")]
pub(super) fn output_plane_state(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
    size: PixelSize,
) -> PlaneState<'static> {
    plane_state_for_mode_and_source(
        scanout,
        framebuffer,
        scanout.output.mode,
        PixelRect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height,
        },
        Transform::Normal,
    )
}

pub(super) fn plane_state_for_mode(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
    mode: Mode,
) -> PlaneState<'static> {
    plane_state_for_mode_and_source(
        scanout,
        framebuffer,
        mode,
        scanout.source_rect,
        smithay_output_transform(scanout.output.transform),
    )
}

pub(super) fn plane_state_for_mode_and_source(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
    mode: Mode,
    source: PixelRect,
    transform: Transform,
) -> PlaneState<'static> {
    let (width, height) = mode.size();
    PlaneState {
        handle: scanout.surface.plane(),
        config: Some(PlaneConfig {
            src: Rectangle::<f64, Buffer>::new(
                (source.x as f64, source.y as f64).into(),
                (source.width as f64, source.height as f64).into(),
            ),
            dst: Rectangle::<i32, Physical>::from_size(
                (i32::from(width), i32::from(height)).into(),
            ),
            transform,
            alpha: scanout.plane_properties.smithay_opaque_alpha,
            damage_clips: None,
            fb: framebuffer,
            fence: None,
        }),
    }
}

pub(super) fn physical_rect(rect: PixelRect) -> Result<Rectangle<i32, Physical>, Box<dyn Error>> {
    Ok(Rectangle::new(
        (i32::try_from(rect.x)?, i32::try_from(rect.y)?).into(),
        (i32::try_from(rect.width)?, i32::try_from(rect.height)?).into(),
    ))
}

pub(super) fn smithay_output_transform(transform: OutputTransform) -> Transform {
    match transform {
        OutputTransform::Normal => Transform::Normal,
        OutputTransform::Rotate90 => Transform::_90,
        OutputTransform::Rotate180 => Transform::_180,
        OutputTransform::Rotate270 => Transform::_270,
        OutputTransform::Flipped => Transform::Flipped,
        OutputTransform::Flipped90 => Transform::Flipped90,
        OutputTransform::Flipped180 => Transform::Flipped180,
        OutputTransform::Flipped270 => Transform::Flipped270,
    }
}
