#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

pub mod bus;
pub mod cpu_scheduling;
pub mod loop_wake;
#[cfg(feature = "flutter")]
pub mod wakeup;
