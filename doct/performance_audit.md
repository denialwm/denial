# Denial Performance Audit

## Summary

Denial used about 14.6% of one CPU core during gameplay. The workload is distributed across Flutter rasterization, Mesa/amdgpu submission, and compositor event handling. No major CPU bottleneck or busy loop was found.

## Findings

- `EGLFence::create` accounted for about 12.6% of raster-thread samples inclusively, but had no measurable self cost. Mesa performs GL command draining, Radeon buffer validation, GPU submission, and native-fence creation beneath this call.
- Native fencing is already efficient: Denial creates one fence per atlas frame, shares it across outputs and sampled-buffer release, and avoids the blocking `glFinish` fallback.
- `malloc` and `free` contributed about 4.3% of raster samples, or roughly 0.26% of one CPU core. Only a small portion was directly attributable to Smithay's fence allocation.
- `polling::Poller::wait_impl`, `run_flutter_event_loop`, and `Space::refresh` each consumed about 0.13% of one CPU core or less. The event loop blocks normally and does not busy-poll.
- The frame scheduler skips idle frames and renders only for Flutter demand or updated application textures, bounded by the fastest output clock.

## Conclusion

The compositor is already well optimized. Remaining opportunities—such as avoiding Mesa's redundant follow-up `glFlush`, removing small fence allocations, or reusing Smithay scratch storage—are micro-optimizations unlikely to produce a material reduction in total CPU usage.
