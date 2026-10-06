use std::path::PathBuf;
use std::sync::Arc;

use denial_flutter_engine::EngineLibrary;

/// Load the real embedder ABI and AOT ELF without starting a Flutter engine,
/// opening a display, or interacting with the compositor's running session.
#[test]
#[ignore = "requires an isolated bundle; run tools/denial-pc engine-test-check"]
fn loads_the_bundled_flutter_engine_abi() {
    let bundle = PathBuf::from(
        std::env::var_os("DENIAL_TEST_FLUTTER_BUNDLE")
            .expect("DENIAL_TEST_FLUTTER_BUNDLE must name the isolated candidate"),
    );
    let library = Arc::new(
        EngineLibrary::load(bundle.join("lib/libflutter_engine.so"))
            .expect("candidate must export the Flutter and Denial embedder ABI"),
    );
    assert!(library.runs_aot_compiled_dart_code());
    let aot = library
        .create_aot_data(bundle.join("lib/libapp.so"))
        .expect("candidate must load the bundled AOT data");
    assert!(!aot.as_raw().is_null());
    drop(aot);
}
