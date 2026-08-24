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
#[cfg(test)]
pub(super) use output_projection::{
    AnimatedOutputRotation, animated_rotation_transform, shortest_rotation_delta,
};
pub(crate) use output_projection::{OutputGeometryTransition, OutputRotationAdvance};
pub(super) use output_projection::{
    OutputRotationAnimation, PendingOutputGeometry, RuntimeRenderOutput,
};
pub(super) use texture::FlutterGlHandler;
pub use texture::SampledBufferHoldBatch;
#[cfg(test)]
pub(super) use texture::{
    CachedTextureBinding, ExternalTextureBinding, ExternalTextureLease,
    ExternalTextureLeaseResource, ExternalTextureResourceBudget, ExternalTextureSlot,
    ExternalTextureSource, FlutterProducerState, PartitionedRecencyCache, ProducerArbiter,
    RecencyCache, RecencyCacheStats, RetiredExternalBindingQueue, contain_ffi_unwind,
    retire_external_texture, vm_service_uri_from_log,
};
pub(crate) use texture::{
    ExternalTextureFrame, ShmSnapshotPool, ShmTextureFrame, SyncedWaylandScene,
};
