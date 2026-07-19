# Flutter embedder ABI header

`embedder.h` is the upstream Flutter Engine C ABI used by the Rust host through
generated `bindgen` declarations. It is retained in the repository so native
builds do not depend on the removed C++ compositor source tree.

The header and the bundled `libflutter_engine.so` must be updated and validated
as one compatibility unit. The upstream Flutter license is in `LICENSE`.
