# Maintainer: Doctor Logix <doctor.logix@gmail.com>
# AUR binary repackaging of Denial's signed first-party Arch packages.
# Upstream first-party repo is primary; this pkgbase exists for AUR-only users.

pkgbase=denial-bin
pkgname=('denial-flutter-engine-bin' 'denial-bin' 'denial-ui-development-bin')
pkgver=0.3.1
pkgrel=1
epoch=1
arch=('x86_64')
url='https://github.com/denialwm/denial'
license=('GPL-3.0-or-later')

_flutter_generation='3.44.7.denial1'
# Upper bound for the Denial version compatible with this ui-development snapshot.
# Derive as MAJOR.(MINOR+1).0 from pkgver; for 0.3.1 this is 0.4.0.
# Must be bumped manually on every minor version bump.
_denial_before='0.4.0'

# Upstream publishes three signed Arch packages per release under
# https://github.com/denialwm/denial/releases/tag/v${pkgver} :
#   denial-${pkgver}-1-x86_64.pkg.tar.zst
#   denial-flutter-engine-1.${pkgver}-1-x86_64.pkg.tar.zst
#   denial-ui-development-${pkgver}-1-x86_64.pkg.tar.zst
# plus adjacent detached .sig files verifiable with validpgpkeys below.
#
# Filename note: the in-repo Pacman package for the engine is
#   denial-flutter-engine-1:${pkgver}-1-x86_64.pkg.tar.zst
# (epoch colon), but GitHub Release assets cannot reliably carry ':' so the
# published direct-download copy uses a dot:
#   denial-flutter-engine-1.${pkgver}-1-x86_64.pkg.tar.zst
# Content is identical; verified by SHA256 against the signed SHA256SUMS
# (x86_64/denial-flutter-engine-1:... hashes match the 1.${pkgver} asset).
source=(
  "https://github.com/denialwm/denial/releases/download/v${pkgver}/denial-${pkgver}-1-x86_64.pkg.tar.zst"
  "https://github.com/denialwm/denial/releases/download/v${pkgver}/denial-${pkgver}-1-x86_64.pkg.tar.zst.sig"
  "https://github.com/denialwm/denial/releases/download/v${pkgver}/denial-flutter-engine-1.${pkgver}-1-x86_64.pkg.tar.zst"
  "https://github.com/denialwm/denial/releases/download/v${pkgver}/denial-flutter-engine-1.${pkgver}-1-x86_64.pkg.tar.zst.sig"
  "https://github.com/denialwm/denial/releases/download/v${pkgver}/denial-ui-development-${pkgver}-1-x86_64.pkg.tar.zst"
  "https://github.com/denialwm/denial/releases/download/v${pkgver}/denial-ui-development-${pkgver}-1-x86_64.pkg.tar.zst.sig"
)
sha256sums=(
  'a0a23e0b850821ef697779e42f30d8a53785d4ec0f576f4b1d5f825f04426d03'
  'SKIP'
  '9a8c83bc3cb33144dac481ed0704a5603ce38aa04d733c84951ce4482334e7cc'
  'SKIP'
  'bf7e4646ff4960f6e7cc6e8bb1914c90dce9768eda2f7c783334e1d55b7ceb2c'
  'SKIP'
)
validpgpkeys=('AE4108FA5E91E26BE0EE331E0F5B3AD16E023091')

# Prevent makepkg from auto-extracting all three package archives into a single
# shared srcdir (their usr/ trees would merge). Each package_*() extracts only
# its own archive directly into its own pkgdir below.
noextract=(
  "denial-${pkgver}-1-x86_64.pkg.tar.zst"
  "denial-flutter-engine-1.${pkgver}-1-x86_64.pkg.tar.zst"
  "denial-ui-development-${pkgver}-1-x86_64.pkg.tar.zst"
)

options=('!strip' '!debug')

package_denial-flutter-engine-bin() {
  pkgdesc='Pinned Flutter Engine runtime for Denial (prebuilt binary)'
  license=('BSD-3-Clause')
  depends=('fontconfig' 'glibc')
  provides=("denial-flutter-engine=${pkgver}" "denial-flutter-engine-abi=${_flutter_generation}")
  conflicts=('denial-flutter-engine' 'denial-flutter-engine-git')

  bsdtar -xpf "$srcdir/denial-flutter-engine-1.${pkgver}-1-x86_64.pkg.tar.zst" \
    -C "$pkgdir" --exclude .PKGINFO --exclude .BUILDINFO --exclude .MTREE
}

package_denial-bin() {
  pkgdesc='Flutter-native Wayland compositor and desktop shell (prebuilt binary)'
  license=(
    'GPL-3.0-or-later'
    'CC-BY-SA-4.0'
    'GPL-3.0-only'
    'OFL-1.1'
  )
  depends=(
    'adobe-source-han-sans-cn-fonts'
    'bash'
    'coreutils'
    'ddcutil'
    "denial-flutter-engine-bin=1:${pkgver}-${pkgrel}"
    "denial-flutter-engine-abi=${_flutter_generation}"
    'dbus'
    'glibc'
    'gtk3'
    'libgcc'
    'libglvnd'
    'libinput'
    'libpulse'
    'libxkbcommon'
    'mesa'
    'pam'
    'rtkit'
    'seatd'
    'systemd-libs'
    'xkeyboard-config'
    'xdg-desktop-portal'
    'xdg-desktop-portal-gtk'
    'xdg-desktop-portal-wlr'
    'xorg-xwayland'
    'zenity'
  )
  optdepends=(
    'denial-ui-development-bin: live Flutter UI editing and hot reload'
    'iwd: Wi-Fi controls without NetworkManager'
    'lact: AMD GPU performance controls'
    'networkmanager: Wi-Fi and network controls through NetworkManager'
    'pipewire-pulse: desktop audio controls'
    'power-profiles-daemon: system power profiles'
    'sddm: graphical login and session selection'
    'upower: battery and power status'
  )
  provides=("denial=${pkgver}")
  conflicts=('denial' 'denial-git')
  backup=(
    'etc/denial/outputs.conf'
    'etc/denial/session.conf'
    'etc/xdg/xdg-desktop-portal-wlr/Denial'
  )

  bsdtar -xpf "$srcdir/denial-${pkgver}-1-x86_64.pkg.tar.zst" \
    -C "$pkgdir" --exclude .PKGINFO --exclude .BUILDINFO --exclude .MTREE
}

package_denial-ui-development-bin() {
  pkgdesc='Pinned live Flutter UI development environment for Denial (prebuilt binary)'
  license=('BSD-3-Clause' 'GPL-3.0-or-later')
  depends=(
    "denial-bin=1:${pkgver}-${pkgrel}"
    "denial-flutter-engine-abi=${_flutter_generation}"
    'fontconfig'
    'git'
    'glibc'
    'libgcc'
  )
  provides=("denial-ui-development=${pkgver}" "denial-ui-development-engine=${_flutter_generation}")
  conflicts=('denial-ui-development' 'denial-ui-development-git')

  bsdtar -xpf "$srcdir/denial-ui-development-${pkgver}-1-x86_64.pkg.tar.zst" \
    -C "$pkgdir" --exclude .PKGINFO --exclude .BUILDINFO --exclude .MTREE
}
