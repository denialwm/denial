### 1. Install prerequisites

On the x86-64 build machine, install:

- Git, jq, Ninja, pkg-config and Rustup
- aarch64-linux-gnu-gcc, g++ and ar
- The host dependencies listed in docs/BUILDING.md
- An ARM64 sysroot containing development libraries for DRM, EGL, GBM, libinput, libseat, udev, libxkbcommon, Fontconfig and GTK 3

Clone Denial:

git clone https://github.com/denialwm/denial.git
cd denial

### 2. Configure the build

Choose the sysroot and job count:

export TARGET_SYSROOT=/absolute/path/to/aarch64-linux-sysroot
export DENIAL_BUILD_JOBS=6

export DENIAL_USER_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/denial"
export DENIAL_PC_DEPENDENCY_ROOT="$DENIAL_USER_CACHE/pc-dependencies"
export DENIAL_FLUTTER_ENGINE_CACHE_ROOT="$DENIAL_USER_CACHE/flutter-engine"

mkdir -p "$DENIAL_USER_CACHE"
export DENIAL_CROSS_WORK
DENIAL_CROSS_WORK="$(mktemp -d "$DENIAL_USER_CACHE/cross-linux-arm64.XXXXXX")"

The sysroot must match the target device’s libc and libraries. An Android/NDK sysroot will not work.

### 3. Download the locked dependencies

tools/denial-pc bootstrap
tools/denial-flutter-engine prepare-app-build
rustup target add aarch64-unknown-linux-gnu

The first run needs network access. These commands use the Flutter and Skia revisions locked by prebuilt/flutter-engine/SOURCE_LOCK.json.

### 4. Build the ARM64 Flutter engine

export DENIAL_ENGINE_SOURCE="$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/checkout/engine/src"
export DENIAL_HOST_ENGINE_OUT="$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/build/out/denial_host_release"
export DENIAL_ARM_ENGINE_ROOT="$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/build-arm64"
export DENIAL_ARM_ENGINE_OUT="$DENIAL_ARM_ENGINE_ROOT/out/denial_linux_arm64_release"
export DENIAL_DEPOT_TOOLS="$DENIAL_ENGINE_SOURCE/flutter/third_party/depot_tools"

test -d "$DENIAL_ENGINE_SOURCE"
test -d "$DENIAL_HOST_ENGINE_OUT"

(
    cd "$DENIAL_ENGINE_SOURCE"

    PATH="$DENIAL_DEPOT_TOOLS/.cipd_bin:$DENIAL_DEPOT_TOOLS:$PATH" \
    DEPOT_TOOLS_UPDATE=0 \
    VPYTHON_VIRTUALENV_ROOT="$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/vpython" \
    ./flutter/tools/gn \
        --runtime-mode=release \
        --linux \
        --linux-cpu=arm64 \
        --enable-fontconfig \
        --out-dir="$DENIAL_ARM_ENGINE_ROOT" \
        --target-dir=denial_linux_arm64_release

    PATH="$DENIAL_DEPOT_TOOLS/.cipd_bin:$DENIAL_DEPOT_TOOLS:$PATH" \
    DEPOT_TOOLS_UPDATE=0 \
    VPYTHON_VIRTUALENV_ROOT="$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/vpython" \
    /usr/bin/ninja \
        -C "$DENIAL_ARM_ENGINE_OUT" \
        -j "$DENIAL_BUILD_JOBS" \
        libflutter_engine.so \
        libflutter_linux_gtk.so \
        clang_x64/gen_snapshot \
        flutter_patched_sdk \
        flutter/shell/platform/linux:publish_headers_linux
)

Confirm the result:

file "$DENIAL_ARM_ENGINE_OUT/libflutter_engine.so"
file "$DENIAL_ARM_ENGINE_OUT/clang_x64/gen_snapshot"

The engine must report ARM aarch64. clang_x64/gen_snapshot must report x86-64 because it runs on the build machine while generating ARM64 AOT code.

### 5. Create the Flutter cross-build view

export DENIAL_ENGINE_VIEW="$DENIAL_CROSS_WORK/engine-view"
export DENIAL_ARM_ENGINE_VIEW="$DENIAL_ENGINE_VIEW/out/denial_linux_arm64_release"

mkdir -p "$DENIAL_ENGINE_VIEW/out" "$DENIAL_ARM_ENGINE_VIEW"

ln -s "$DENIAL_ENGINE_SOURCE/flutter" "$DENIAL_ENGINE_VIEW/flutter"
ln -s "$DENIAL_HOST_ENGINE_OUT" \
    "$DENIAL_ENGINE_VIEW/out/denial_host_release"

for path in "$DENIAL_ARM_ENGINE_OUT"/*; do
    name="${path##*/}"
    test "$name" = gen_snapshot && continue
    ln -s "$path" "$DENIAL_ARM_ENGINE_VIEW/$name"
done

ln -s "$DENIAL_ARM_ENGINE_OUT/clang_x64/gen_snapshot" \
    "$DENIAL_ARM_ENGINE_VIEW/gen_snapshot"

### 6. Build the ARM64 shell

export DENIAL_FLUTTER="$DENIAL_PC_DEPENDENCY_ROOT/flutter/bin/flutter"
export DENIAL_SHELL_ASSEMBLY="$DENIAL_CROSS_WORK/shell-assembly"

(
    cd dart_shell

    "$DENIAL_FLUTTER" pub get

    "$DENIAL_FLUTTER" assemble \
        --local-engine-src-path="$DENIAL_ENGINE_VIEW" \
        --local-engine=denial_linux_arm64_release \
        --local-engine-host=denial_host_release \
        --suppress-analytics \
        --resource-pool-size="$DENIAL_BUILD_JOBS" \
        --output="$DENIAL_SHELL_ASSEMBLY" \
        -dTargetFile=lib/main.dart \
        -dBuildMode=release \
        -dTargetPlatform=linux-arm64 \
        -dDartObfuscation=false \
        -dTrackWidgetCreation=true \
        -dTreeShakeIcons=true \
        release_bundle_linux-arm64_assets
)

Verify the AOT library:

file "$DENIAL_SHELL_ASSEMBLY/lib/libapp.so"

It must report ARM aarch64.

### 7. Cross-build the Rust compositor

Configure Cargo and pkg-config:

export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR="$TARGET_SYSROOT"
export PKG_CONFIG_LIBDIR="$TARGET_SYSROOT/usr/lib/pkgconfig:$TARGET_SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$TARGET_SYSROOT/usr/lib64/pkgconfig:$TARGET_SYSROOT/usr/share/pkgconfig"

export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
export CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
export AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
export CFLAGS_aarch64_unknown_linux_gnu="--sysroot=$TARGET_SYSROOT"
export CXXFLAGS_aarch64_unknown_linux_gnu="--sysroot=$TARGET_SYSROOT"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--sysroot=$TARGET_SYSROOT -C link-arg=-Wl,-rpath-link,$TARGET_SYSROOT/usr/lib -C link-arg=-Wl,-rpath-link,$TARGET_SYSROOT/lib"
export CARGO_TARGET_DIR="$DENIAL_CROSS_WORK/rust"
export CARGO_NET_OFFLINE=true

Check the target dependencies:

pkg-config --exists libdrm gbm egl libinput libseat libudev xkbcommon

Build:

(
    cd compositor

    cargo build \
        --locked \
        --offline \
        --release \
        --target aarch64-unknown-linux-gnu \
        --features flutter \
        --bin deniald \
        --bin denialctl \
        --jobs "$DENIAL_BUILD_JOBS"

    cargo build \
        --locked \
        --offline \
        --release \
        --target aarch64-unknown-linux-gnu \
        -p denial-portal \
        --jobs "$DENIAL_BUILD_JOBS"
)

### 8. Assemble the deployable payload

export DENIAL_PAYLOAD="$DENIAL_CROSS_WORK/payload"
export DENIAL_RUST_RELEASE="$CARGO_TARGET_DIR/aarch64-unknown-linux-gnu/release"

install -d \
    "$DENIAL_PAYLOAD/bin" \
    "$DENIAL_PAYLOAD/bundle/lib" \
    "$DENIAL_PAYLOAD/bundle/data/flutter_assets"

install -m755 "$DENIAL_RUST_RELEASE/deniald" \
    "$DENIAL_PAYLOAD/bin/deniald"
install -m755 "$DENIAL_RUST_RELEASE/denialctl" \
    "$DENIAL_PAYLOAD/bin/denialctl"
install -m755 "$DENIAL_RUST_RELEASE/denial-portal" \
    "$DENIAL_PAYLOAD/bin/denial-portal"

install -m755 "$DENIAL_ARM_ENGINE_OUT/libflutter_engine.so" \
    "$DENIAL_PAYLOAD/bundle/lib/libflutter_engine.so"
install -m755 "$DENIAL_SHELL_ASSEMBLY/lib/libapp.so" \
    "$DENIAL_PAYLOAD/bundle/lib/libapp.so"
install -m644 "$DENIAL_ARM_ENGINE_OUT/icudtl.dat" \
    "$DENIAL_PAYLOAD/bundle/data/icudtl.dat"

cp -a "$DENIAL_SHELL_ASSEMBLY/flutter_assets/." \
    "$DENIAL_PAYLOAD/bundle/data/flutter_assets/"

install -m644 packaging/arch/outputs.conf \
    "$DENIAL_PAYLOAD/outputs.conf"

Verify every native artifact:

file \
    "$DENIAL_PAYLOAD/bin/deniald" \
    "$DENIAL_PAYLOAD/bin/denialctl" \
    "$DENIAL_PAYLOAD/bin/denial-portal" \
    "$DENIAL_PAYLOAD/bundle/lib/libflutter_engine.so" \
    "$DENIAL_PAYLOAD/bundle/lib/libapp.so"

Every file must report ARM aarch64.

Create the archive:

(
    cd "$DENIAL_PAYLOAD"
    find bin bundle -type f -print0 |
        sort -z |
        xargs -0 sha256sum > SHA256SUMS
)

tar -C "$DENIAL_CROSS_WORK" \
    -czf "$DENIAL_CROSS_WORK/denial-linux-arm64.tar.gz" \
    payload

printf 'Finished: %s\n' \
    "$DENIAL_CROSS_WORK/denial-linux-arm64.tar.gz"

### 9. Start it on the device

After installing the target runtime dependencies and extracting the payload:

cd /path/to/payload
sha256sum -c SHA256SUMS

export DENIAL_SHELL_PROFILE=mobile

bin/deniald \
    --device /dev/dri/card0 \
    --output-config outputs.conf \
    --wayland \
    --flutter-bundle bundle \
    --flutter-renderer impeller

If rendering uses a separate DRM render node, add:

--render-device /dev/dri/renderD128

The compositor must be launched from a proper seat/VT environment with access to DRM, input devices and the system services Denial uses.