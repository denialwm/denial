# Denial documentation

This directory contains Denial's project-level design, development, protocol,
performance, packaging, and release documentation. Component-specific build
metadata and attribution remain beside the files they describe.

Project-level release documents live at the repository root:

- [Changelog](../CHANGELOG.md)
- [Roadmap](../ROADMAP.md)
- [Security policy](../SECURITY.md)
- [Beta contribution policy](../CONTRIBUTING.md)

## Development and architecture

- [Install Denial](INSTALL.md)
- [Build Denial](BUILDING.md)
- [Distribution support](DISTRIBUTION_SUPPORT.md)
- [Known issues](KNOWN_ISSUES.md)
- [Architecture](architecture.md)
- [Session startup and locking](SESSION_STARTUP.md)
- [denialctl](DENIALCTL.md)
- [Keyboard window resizing](keyboard-shortcuts.md)
- [Live Flutter UI development](UI_DEVELOPMENT.md)
- [Custom Flutter shells](CUSTOM_SHELLS.md)
- [Plugin system: accepted agent implementation contract](PLUGIN_SYSTEM.md)
- [Plugin Manager: Git distribution and backend contract](PLUGIN_MANAGER.md)
- [Plugin SDK package and validation](../packages/denial_sdk/README.md)
- [Flutter plugin contracts](../packages/denial_flutter_sdk/README.md)
- [Original top-bar plugin](../plugins/denial_top_bar/README.md)
- [Windows-style taskbar](https://github.com/denialwm/denial-plugins/tree/main/plugins/denial_taskbar)
- [Screenshots and screen sharing](SCREEN_CAPTURE.md)
- [Window rendering diagnostics](RENDER_AUDIT.md)

## Protocols

- [Platform-channel inventory](protocol/CHANNEL_INVENTORY.md)
- [Denial wire format](protocol/WIRE_FORMAT.md)
- [Control protocol v1](protocol/control-v1.md)
- [Pet protocol v1](protocol/pet-v1.md)
- [Wayland text input v3](protocol/text-input-v3.md)

The versioned FlatBuffers schema and generated bindings remain under
[`protocol/`](../protocol/).

## Packaging and releases

- [Packaging overview](packaging/arch/README.md)
- [Arch repository details](packaging/arch/INSTALL.md)
- [Build trust and release evidence](BUILD_TRUST.md)
- [Publishing design](packaging/arch/PUBLISHING.md)
- [Builder runbook](packaging/arch/BUILDER.md)
- [Release-signing operations](packaging/arch/SIGNING.md)
- [Package validation evidence](packaging/arch/VALIDATION.md)
- [Alpine Linux 3.24 runtime validation](../packaging/alpine/VALIDATION.md)
- [openSUSE Tumbleweed runtime validation](../packaging/opensuse/VALIDATION.md)
- [Trusted-branch candidate validation](packaging/arch/BRANCH_VALIDATION.md)

## Colocated references

The following documentation stays with its implementation or artifact:

- [`compositor/README.md`](../compositor/README.md)
- [`protocol/golden/README.md`](../protocol/golden/README.md)
- [Flutter Engine validation](flutter-engine/3.47.5/VALIDATION.md)
- [`prebuilt/flutter-engine/.../BUILD_INFO.md`](../prebuilt/flutter-engine/linux-x64-release/BUILD_INFO.md)
- [`tools/flutter-embedder-bindings/README.md`](../tools/flutter-embedder-bindings/README.md)
