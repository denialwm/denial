use std::env;
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let header = manifest.join("../../third_party/flutter_embedder/embedder.h");
    println!("cargo:rerun-if-changed={}", header.display());

    let bindings = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .allowlist_function("FlutterEngine.*")
        .allowlist_type("Flutter.*")
        .allowlist_var("FLUTTER_ENGINE_VERSION")
        .derive_default(true)
        .generate_comments(false)
        .layout_tests(false)
        .generate()
        .expect("generate Flutter embedder bindings");

    let output = PathBuf::from(env::var_os("OUT_DIR").expect("build output directory"));
    bindings
        .write_to_file(output.join("flutter_embedder.rs"))
        .expect("write Flutter embedder bindings");
}
