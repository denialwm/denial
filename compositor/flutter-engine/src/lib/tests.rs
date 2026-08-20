use super::*;

#[test]
fn loads_the_bundled_flutter_engine_abi() {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let bundle = std::env::var_os("DENIAL_TEST_FLUTTER_BUNDLE")
        .map(PathBuf::from)
        .unwrap_or_else(|| repository.join("dart_shell/build/linux/x64/release/bundle"));
    let engine = bundle.join("lib/libflutter_engine.so");
    assert!(engine.is_file(), "repository has no Flutter engine bundle");
    let library = EngineLibrary::load(engine).expect("load bundled Flutter engine");
    assert!(library.runs_aot_compiled_dart_code());
    let library = Arc::new(library);
    let app = bundle.join("lib/libapp.so");
    let _aot = library.create_aot_data(app).expect("load bundled AOT data");
}
