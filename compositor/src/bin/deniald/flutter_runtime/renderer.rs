//! Flutter EGL renderer, external textures, and output projection.

use super::*;

#[path = "renderer/gl.rs"]
mod gl_resources;
#[path = "renderer/gpu_timing.rs"]
mod gpu_timing;
#[path = "renderer/output_projection.rs"]
mod output_projection;
#[path = "renderer/texture.rs"]
mod texture;

use gl_resources::{
    ContextBinding, GlApi, GlTarget, ShaderBlit, create_shader_blit, destroy_depth_stencils,
    destroy_shader_blit, destroy_targets,
};
use gpu_timing::GpuTimingState;
pub(crate) use output_projection::{OutputGeometryTransition, OutputRotationAdvance};
pub(super) use output_projection::{
    OutputRotationAnimation, PendingOutputGeometry, RuntimeRenderOutput,
};
pub(super) use texture::FlutterGlHandler;
pub use texture::SampledBufferHoldBatch;
pub(crate) use texture::{
    ExternalTextureFrame, ShmSnapshotPool, ShmTextureFrame, SyncedWaylandScene,
};
