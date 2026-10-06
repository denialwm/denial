use super::*;
use smithay::backend::allocator::{Fourcc, Modifier, dmabuf::DmabufFlags};

// Identity-only handles: these tests never submit a buffer to EGL or KMS.
fn buffer() -> Dmabuf {
    let mut builder = Dmabuf::builder(
        (1920, 1080),
        Fourcc::Xrgb8888,
        Modifier::Linear,
        DmabufFlags::empty(),
    );
    let fd: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
    assert!(builder.add_plane(fd, 0, 1920 * 4));
    builder.build().unwrap()
}

fn configuration(buffers: &[Dmabuf]) -> PreparedRendererConfiguration {
    PreparedRendererConfiguration::new(
        &[OutputRenderTargetPool {
            output_id: OutputId(1),
            render_view_id: RenderViewId::for_output(OutputId(1)).unwrap(),
            configuration_generation: 2,
            size: PixelSize::new(1920, 1080),
            initial_scanout: 0,
            dmabufs: buffers.iter().map(|buffer| (buffer, None)).collect(),
        }],
        PixelSize::new(1920, 1080),
        RendererBackend::ImpellerGles,
        false,
    )
}

#[test]
fn prepared_pool_accepts_cloned_handles_but_rejects_reallocated_buffers() {
    let buffers = [buffer(), buffer(), buffer()];
    let prepared = configuration(&buffers);
    assert!(prepared.validate(&configuration(&buffers.clone())).is_ok());
    let mut replacement = buffers.clone();
    replacement[1] = buffer();
    assert!(prepared.validate(&configuration(&replacement)).is_err());
    // FBO order and the initially scanned-out slot are part of the broker state.
    replacement = buffers.clone();
    replacement.swap(0, 1);
    assert!(prepared.validate(&configuration(&replacement)).is_err());
    let mut expected = configuration(&buffers);
    expected.pools[0].initial_scanout = 1;
    assert!(prepared.validate(&expected).is_err());
}

#[test]
fn prepared_pool_rejects_stale_topology_and_renderer_configuration() {
    let buffers = [buffer(), buffer(), buffer()];
    let prepared = configuration(&buffers);
    let changes: &[fn(&mut PreparedRendererConfiguration)] = &[
        |config| config.pools[0].output_id = OutputId(2),
        |config| config.pools[0].render_view_id = RenderViewId::for_output(OutputId(2)).unwrap(),
        |config| config.pools[0].configuration_generation += 1,
        |config| config.pools[0].size = PixelSize::new(3840, 2160),
        |config| config.desktop_size = PixelSize::new(4480, 1440),
        |config| config.renderer_backend = RendererBackend::SkiaGles,
        |config| config.offscreen_blit = true,
        |config| {
            config.pools.clear();
        },
    ];
    for change in changes {
        let mut expected = configuration(&buffers);
        change(&mut expected);
        assert!(
            prepared.validate(&expected).is_err(),
            "accepted {expected:?}"
        );
    }
}

#[test]
fn prepared_blit_pool_requires_the_same_render_allocation() {
    let scanout = buffer();
    let render = buffer();
    let pool = |render| OutputRenderTargetPool {
        output_id: OutputId(1),
        render_view_id: RenderViewId::for_output(OutputId(1)).unwrap(),
        configuration_generation: 2,
        size: PixelSize::new(1920, 1080),
        initial_scanout: 0,
        dmabufs: vec![(&scanout, render)],
    };
    let config = |pool| {
        PreparedRendererConfiguration::new(
            &[pool],
            PixelSize::new(1920, 1080),
            RendererBackend::ImpellerGles,
            true,
        )
    };
    let prepared = config(pool(Some(&render)));
    let cloned_render = render.clone();
    let replacement_render = buffer();
    assert!(
        prepared
            .validate(&config(pool(Some(&cloned_render))))
            .is_ok()
    );
    assert!(
        prepared
            .validate(&config(pool(Some(&replacement_render))))
            .is_err()
    );
    assert!(prepared.validate(&config(pool(None))).is_err());
}
