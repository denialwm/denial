# denial-flutter-engine — standalone seed spec for local (lc) builds
#
# The raw Flutter engine is a SHA-256-pinned, source-built generation produced
# by the Denial Flutter/Skia fork pipeline (see
# prebuilt/flutter-engine/SOURCE_LOCK.json and BUILD_INFO.md in the denial
# source tree). denial.spec BuildRequires this package, so a local
# build repository must contain it before the main spec is built.
#
# This spec seeds the local repository with that pinned generation. Its
# Source is the signed release artifact; %prep extracts it, %check re-proves
# the pinned SHA-256 and the exported embedder entry points, and %install
# ships exactly the payload that the denial-flutter-engine subpackage of
# denial.spec carries, so both lanes produce identical packages.
#
#   lc init --repo <repo>
#   lc build --source packaging/fedora/engine-seed/ --torepo <repo> \
#       --spec denial-flutter-engine.spec
#   lc build --source <denial sources> --torepo <repo> --enable-network
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

%global glibc_baseline     2.39
%global flutter_engine_abi 3.44.7.denial1
%global pinned_engine_sha256 237db59d4018e52c68f0a087586cf51c5ef02aae08e75f33813ea92f86c510d5

Name:           denial-flutter-engine
Version:        0.3.1
Release:        1%{?dist}
Epoch:          1
Summary:        Pinned Flutter Engine runtime for Denial
License:        BSD-3-Clause
URL:            https://github.com/denialwm/denial
Source0:        https://github.com/denialwm/denial/releases/download/v%{version}/%{name}-%{version}-1.x86_64.rpm
ExclusiveArch:  x86_64

BuildRequires:  cpio
BuildRequires:  rpm

Requires:       fontconfig
Requires:       glibc >= %{glibc_baseline}
Provides:       denial-flutter-engine-abi = %{flutter_engine_abi}
Conflicts:      denial-flutter-engine-git

%description
Source-built Flutter Engine generation coupled to Denial's embedder ABI. The
generation is pinned by SHA-256 in the Denial source tree; this package ships
the verified artifact for the v0.3.1 release.

%prep
mkdir %{name}
( cd %{name} && rpm2cpio %{SOURCE0} | cpio -idm --quiet )

%build

%install
install -d -m 0755 %{buildroot}
cp -a -- %{name}/. %{buildroot}/

%check
engine_so=%{name}/usr/lib/denial/flutter/lib/libflutter_engine.so
test -f "$engine_so"
test -f %{name}/usr/lib/denial/flutter/data/icudtl.dat
test -f %{name}/usr/share/denial/flutter-engine/manifest.json
test -f %{name}/usr/share/denial/flutter-engine/SOURCE_LOCK.json
# The generation must match the SHA-256 pinned in the Denial source tree.
test "$(sha256sum "$engine_so" | cut -d' ' -f1)" = "%{pinned_engine_sha256}"
# The raw embedder must export Denial's required entry points.
for symbol in \
    FlutterEngineGetProcAddresses \
    DenialFlutterEngineRequestFrameForExternalTextures \
    DenialFlutterEngineScheduleFrameForExternalTextures; do
    nm -D --defined-only "$engine_so" | grep -Fq " $symbol" \
        || { echo "missing embedder entry point: $symbol" >&2; exit 1; }
done

%files
/usr/lib/denial/flutter/data/icudtl.dat
/usr/lib/denial/flutter/lib/libflutter_engine.so
/usr/share/denial/flutter-engine
/usr/share/doc/denial-flutter-engine
%license /usr/share/licenses/denial-flutter-engine/*

%changelog
* Tue Sep 10 2026 Sunny Yang <sunny@users.noreply.github.com> - 0.3.1-1
- Standalone seed spec so local (lc) build repositories can provide
  denial-flutter-engine to the source-build denial spec. Payload is
  byte-identical to the denial-flutter-engine subpackage of denial.spec.
