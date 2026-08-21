%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%global __provides_exclude_from ^/usr/lib/denial/.*\\.so$

Name:           denial
Version:        %{denial_version}
Release:        %{denial_release}
Summary:        Flutter-native Wayland compositor and desktop shell
License:        GPL-3.0-or-later AND CC-BY-SA-4.0 AND GPL-3.0-only AND OFL-1.1
URL:            https://github.com/denialwm/denial
ExclusiveArch:  x86_64

Requires:       bash
Requires:       coreutils
Requires:       dbus
Requires:       denial-flutter-engine = 1:%{version}-%{release}
Requires:       glibc >= %{glibc_baseline}
Requires:       libEGL.so.1()(64bit)
Requires:       libpam.so.0()(64bit)
Requires:       libpulse.so.0()(64bit)
Requires:       rtkit
Requires:       xkeyboard-config
Requires:       xorg-x11-server-Xwayland
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-gtk
Requires:       xdg-desktop-portal-wlr
Requires:       zenity
Recommends:     google-noto-sans-cjk-vf-fonts
Recommends:     libddcutil.so.5()(64bit)
Recommends:     pipewire-pulseaudio
Recommends:     power-profiles-daemon
Recommends:     upower
Suggests:       ddcutil
Suggests:       gdm
Suggests:       iwd
Suggests:       NetworkManager
Conflicts:      denial-git
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%description
Denial owns the Wayland desktop scene, shell, motion, and composition using
Flutter as part of the compositor foundation.

%package -n denial-flutter-engine
Epoch:          1
Summary:        Pinned Flutter Engine runtime for Denial
License:        BSD-3-Clause
Requires:       fontconfig
Requires:       glibc >= %{glibc_baseline}
Provides:       denial-flutter-engine-abi = %{flutter_engine_abi}
Conflicts:      denial-flutter-engine-git

%description -n denial-flutter-engine
Source-built Flutter Engine generation coupled to Denial's embedder ABI.

%prep

%build

%install
install -d -m 0755 %{buildroot}
cp -a -- %{denial_payload}/. %{buildroot}/
cp -a -- %{engine_payload}/. %{buildroot}/

%check
test -x %{buildroot}/usr/bin/deniald
test -x %{buildroot}/usr/bin/denialctl
test -x %{buildroot}/usr/bin/denial-session
test -f %{buildroot}/usr/lib/denial/flutter/lib/libapp.so
test -f %{buildroot}/usr/lib/denial/flutter/lib/libflutter_engine.so

%post
if [ $1 -eq 1 ] && [ -x /usr/lib/systemd/systemd-update-helper ]; then
    /usr/lib/systemd/systemd-update-helper \
        install-user-units denial-session.target || :
fi

%preun
if [ $1 -eq 0 ] && [ -x /usr/lib/systemd/systemd-update-helper ]; then
    /usr/lib/systemd/systemd-update-helper \
        remove-user-units denial-session.target || :
fi

%postun
if [ $1 -ge 1 ] && [ -x /usr/lib/systemd/systemd-update-helper ]; then
    /usr/lib/systemd/systemd-update-helper \
        mark-reload-user-units denial-session.target || :
fi

%files
%config(noreplace) /etc/denial/outputs.conf
%config(noreplace) /etc/denial/session.conf
%config(noreplace) /etc/xdg/xdg-desktop-portal-wlr/Denial
/usr/bin/denial-session
/usr/bin/denialctl
/usr/bin/deniald
/usr/lib/denial/flutter/data/flutter_assets
/usr/lib/denial/flutter/lib/libapp.so
/usr/lib/systemd/user/denial-session.target
/usr/share/doc/denial
%license /usr/share/licenses/denial/*
/usr/share/man/man1/denial-session.1.gz
/usr/share/man/man1/denialctl.1.gz
/usr/share/man/man1/deniald.1.gz
/usr/share/wayland-sessions/denial.desktop
/usr/share/xdg-desktop-portal/denial-portals.conf
%{?runtime_version_path:%{runtime_version_path}}

%files -n denial-flutter-engine
/usr/lib/denial/flutter/data/icudtl.dat
/usr/lib/denial/flutter/lib/libflutter_engine.so
/usr/share/denial/flutter-engine
/usr/share/doc/denial-flutter-engine
%license /usr/share/licenses/denial-flutter-engine/*

%changelog
* Wed Aug 12 2026 Doctor Logix <doctor.logix@gmail.com> - %{version}-%{release}
- Add the native Fedora package adapter.
