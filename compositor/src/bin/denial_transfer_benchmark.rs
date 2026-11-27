//! Render-node-only, offscreen paced transfer probe. Never opens a KMS device.

use denial_kms::gpu_transfer;

fn main() {
    // The probe always records transfer timings.
    // SAFETY: nothing else runs yet, so no thread reads the environment.
    unsafe { std::env::set_var("DENIAL_RENDER_AUDIT", "1") };
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
