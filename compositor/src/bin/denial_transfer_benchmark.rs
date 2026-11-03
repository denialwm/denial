//! Render-node-only, offscreen paced transfer probe. Never opens a KMS device.
// cpu_scheduling reaches RTKit over the shared bus; the probe never calls it.
#[allow(dead_code)]
#[path = "deniald/bus.rs"]
mod bus;
#[path = "deniald/cpu_scheduling.rs"]
mod cpu_scheduling;
#[path = "deniald/egl_context.rs"]
mod egl_context;
#[path = "deniald/gpu_transfer/mod.rs"]
mod gpu_transfer;

fn render_audit_enabled() -> bool {
    true
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    if let Err(error) = gpu_transfer::benchmark::run() {
        eprintln!("transfer benchmark failed: {error}");
        std::process::exit(1);
    }
}
