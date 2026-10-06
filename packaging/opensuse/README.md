# openSUSE package adapter

Build the openSUSE Tumbleweed x86-64 runtime packages with:

```sh
sudo zypper install rpm-build bsdtar jq
tools/denial-pc opensuse-package
```

The spec consumes the same GLIBC 2.39-gated staging tree as the Debian and
Fedora adapters. Package-time ELF rewriting is disabled, and both finished
RPMs are extracted and compared byte-for-byte with that shared payload.
Outputs are written below
`$XDG_CACHE_HOME/denial/pc-build/packages/opensuse/` by default.

The two required packages are `denial-flutter-engine` and `denial`. Install a
locally built pair together so Zypper can resolve their exact version lock:

```sh
sudo zypper install \
  denial-flutter-engine-VERSION-RELEASE.x86_64.rpm \
  denial-VERSION-RELEASE.x86_64.rpm
```

The openSUSE adapter differs from the Fedora adapter only where RPM dependency
capabilities are distribution-specific: the D-Bus daemon is `dbus-1`,
Xwayland is `xwayland`, and the CJK fallback-font recommendation is
`google-noto-sans-cjk-fonts`.

This adapter currently produces local RPMs. It is not yet connected to a
published Zypper repository or the signed GitHub Release lane.

## Publication work remaining

`createrepo_c` output from the package pair has been accepted by Zypper as an
RPM-MD repository, so publication does not require a new repository format.
The existing Fedora signing path can be generalized, but openSUSE still needs
its own release boundary:

- promote the openSUSE metadata adapter from the retained native payload under
  the signed-tag no-build guard;
- give the openSUSE RPMs a distinct release-asset namespace because GitHub
  Release assets are flat and the Fedora pair has the same RPM filenames;
- publish a distro-scoped RPM-MD root, for example
  `rpm/opensuse/tumbleweed/x86_64`, with embedded RPM signatures and signed
  `repomd.xml`;
- add a Zypper repository bootstrap file and key-import path; and
- independently verify clean Zypper install, update, reinstall, configuration
  preservation, and removal against the hosted signed snapshot.

Clean installation and a real GDM-launched compositor session are recorded in
[VALIDATION.md](VALIDATION.md).
