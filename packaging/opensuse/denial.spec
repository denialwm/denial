%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%global __provides_exclude_from ^/usr/lib/denial/.*\\.so$
# denial-settings resolves this bundled private runtime through $ORIGIN/lib.

Name:           denial
Version:        %{denial_version}
Release:        %{denial_release}
Summary:        Flutter-native Wayland compositor and desktop shell
License:        GPL-3.0-or-later AND CC-BY-SA-4.0 AND GPL-3.0-only AND OFL-1.1
URL:            https://github.com/denialwm/denial
ExclusiveArch:  x86_64 aarch64

Requires:       bash
Requires:       coreutils
Requires:       git
Requires:       dbus-1
Requires:       polkit
Requires:       denial-flutter-engine = 1:%{version}-%{release}
Requires:       glibc >= %{glibc_baseline}
Requires:       libEGL.so.1()(64bit)
Requires:       libpam.so.0()(64bit)
Requires:       libpulse.so.0()(64bit)
Requires:       rtkit
Requires:       xkeyboard-config
Requires:       xwayland
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-gtk
Requires:       xdg-desktop-portal-wlr
Requires:       zenity
Recommends:     google-noto-sans-cjk-fonts
Recommends:     libddcutil.so.5()(64bit)
Recommends:     pipewire-pulseaudio
Recommends:     power-profiles-daemon
Recommends:     upower
Suggests:       ddcutil
Suggests:       gdm
Suggests:       iwd
Suggests:       NetworkManager
Suggests:       ModemManager
Suggests:       denial-plugin-manager = %{version}-%{release}
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

%package -n denial-plugin-manager
Summary:        Plugin development and composition tools for Denial
License:        GPL-3.0-or-later
Requires:       denial = %{version}-%{release}
Requires:       git

%description -n denial-plugin-manager
Installs the Plugin Manager app, its backend, and Denial's compiler kit.
A compatible Dart SDK must be available in PATH before compiling plugins.

%prep

%build

%install
install -d -m 0755 %{buildroot}
cp -a -- %{denial_payload}/. %{buildroot}/
cp -a -- %{engine_payload}/. %{buildroot}/
cp -a -- %{plugin_manager_payload}/. %{buildroot}/

%check
test -x %{buildroot}/usr/bin/deniald
test -x %{buildroot}/usr/bin/denialctl
test -x %{buildroot}/usr/bin/denial-portal
test -x %{buildroot}/usr/bin/denial-session
test -x %{buildroot}/usr/bin/denial-settings
test -x %{buildroot}/usr/bin/denial-plugin-manager
test -x %{buildroot}/usr/bin/denial-plugins
test -f %{buildroot}/usr/bin/denial-plugins.installation.json
test -f %{buildroot}/usr/lib/denial/plugin-build-kit/kit.json
test -f %{buildroot}/usr/lib/denial/flutter/lib/libapp.so
test -f %{buildroot}/usr/lib/denial/flutter/lib/libflutter_engine.so
test -f %{buildroot}/usr/lib/denial/settings/lib/libflutter_engine.so

%post
if [ $1 -eq 1 ] && [ -x /usr/lib/systemd/systemd-update-helper ]; then
    /usr/lib/systemd/systemd-update-helper \
        install-user-units denial-session.target denial-portal.service || :
fi

%preun
if [ $1 -eq 0 ] && [ -x /usr/lib/systemd/systemd-update-helper ]; then
    /usr/lib/systemd/systemd-update-helper \
        remove-user-units denial-session.target denial-portal.service || :
fi

%postun
if [ $1 -ge 1 ] && [ -x /usr/lib/systemd/systemd-update-helper ]; then
    /usr/lib/systemd/systemd-update-helper \
        mark-reload-user-units denial-session.target denial-portal.service || :
fi

%files
%config(noreplace) /etc/denial/outputs.conf
%config(noreplace) /etc/denial/session.conf
%config(noreplace) /etc/xdg/xdg-desktop-portal-wlr/Denial
/usr/bin/denial-session
/usr/bin/denial-settings
/usr/bin/denial-portal
/usr/bin/denialctl
/usr/bin/deniald
/usr/lib/denial/flutter/data/flutter_assets
/usr/lib/denial/flutter/lib/libapp.so
/usr/lib/denial/settings
/usr/bin/denial-polkit-agent
/usr/lib/denial/polkit
/usr/lib/systemd/user/denial-polkit-agent.service
/usr/lib/denial/flutter/.denial-ui-source.json
/usr/lib/elogind/system-sleep/denial-suspend-mode
/usr/lib/systemd/system-sleep/denial-suspend-mode
/usr/lib/systemd/user/denial-session.target
/usr/lib/systemd/user/denial-portal.service
/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service
/usr/share/doc/denial
%license /usr/share/licenses/denial/*
/usr/share/man/man1/denial-session.1.gz
/usr/share/man/man1/denial-portal.1.gz
/usr/share/man/man1/denialctl.1.gz
/usr/share/man/man1/deniald.1.gz
/usr/share/wayland-sessions/denial.desktop
/usr/share/applications/dev.denial.Settings.desktop
/usr/share/applications/dev.denial.Welcome.desktop
/usr/share/xdg-desktop-portal/denial-portals.conf
/usr/share/xdg-desktop-portal/portals/denial.portal
/usr/share/polkit-1/rules.d/50-denial-fingerprint.rules
%{?runtime_version_path:%{runtime_version_path}}

%files -n denial-flutter-engine
/usr/lib/denial/flutter/data/icudtl.dat
/usr/lib/denial/flutter/lib/libflutter_engine.so
/usr/share/denial/flutter-engine
/usr/share/doc/denial-flutter-engine
%license /usr/share/licenses/denial-flutter-engine/*

%files -n denial-plugin-manager
/usr/bin/denial-plugin-manager
/usr/bin/denial-plugins
/usr/bin/denial-plugins.installation.json
/usr/lib/denial/plugin-manager
/usr/lib/denial/plugin-build-kit
/usr/share/applications/dev.denial.PluginManager.desktop
/usr/share/doc/denial-plugin-manager
%license /usr/share/licenses/denial-plugin-manager/*

%changelog
* Mon Sep 21 2026 Doctor Logix <doctor.logix@gmail.com> - %{version}-%{release}
- Add the native openSUSE package adapter.
