# Fork changelog

## Tailscale 1.104.7 — Intel macOS 11 Big Sur

- Updated the pinned upstream source to v1.104.7 and the isolated build toolchain to Go 1.27.4. The existing macOS 11 deployment target, certificate-chain shim, and peer-credential authorization remain unchanged.
- Included upstream daemon fixes for transient UDP read errors during network changes and the Go TLS ClientHello middlebox compatibility fix. Upstream macOS network-extension DNS changes are not assumed to apply to this standalone daemon.
- Updated the version-aware menu self-test and hash-bound package builder for the accepted 1.104.7 assets. The guarded upgrade retains the verified 1.104.4 implicit-utun daemon hash; the existing state and rollback behavior are unchanged.
- Built the CLI and daemon twice with matching hashes and passed local certificate, ABI, GUI, local API, socket, and installer fixture checks. The exact package passed an in-place upgrade on Intel macOS 11.7.11 with identity preserved, native utun networking, peer connectivity, MagicDNS, Screen Sharing, a responsive connected menu, and reboot persistence. The 1.104.4 release remains available for rollback.

## macOS 11 Intel package installer

- Added a separate unsigned `.pkg` builder for the exact verified 1.104.4 release assets. It checks archive and executable hashes, installs the CLI, daemon, Big Sur launchd plist, and menu app, and leaves authentication interactive.
- Added guarded preinstall and postinstall scripts for fresh installation and in-place upgrade. They preserve state, back up installed program files, stop only the matching launchd job before payload replacement, and accept the verified prior Big Sur plist's implicit `utun` setting while rejecting conflicting installations. Sandboxed script tests cover normal and failure paths.

## Tailscale 1.104.4 — Intel macOS 11 Big Sur

- Added a separate, pinned macOS 11 build using [Tailscale v1.104.4](https://github.com/tailscale/tailscale/releases/tag/v1.104.4) and [Go 1.27.3](https://go.dev/dl/), targeting `darwin/amd64`, `GOAMD64=v1`, and macOS 11.0. The original older-macOS build remains separate.
- Added a narrow Security.framework compatibility implementation for `SecTrustCopyCertificateChain`, which Go 1.27.3 references but Big Sur does not export. It copies the evaluated certificate chain with Core Foundation ownership semantics; normal trust, hostname, usage, and validity checks remain in Go and macOS. Focused verification and ABI tests are included.
- Kept the macOS 11 build free of the inherited old-kernel peer-credential authorization bypass and fallback certificate roots. The legacy patches remain available only through the original build path.
- Improved the native menu-bar app with local device name, Tailscale IPv4, dynamically detected version, clear connection state, and a peer list that excludes the local device. The existing bounded asynchronous CLI execution and lifecycle fixes are retained.
- Verified on Intel macOS 11.7.11: authentication, native utun routing, MagicDNS, peer connectivity, Screen Sharing, and automatic daemon and menu-bar startup after reboot. The menu showed the connected state, local device details, and installed version; it remained responsive in bounded observation. This is community verification, not official Tailscale support or a guarantee for other hosts. Direct UDP was not established in the bounded peer test; DERP connectivity worked.

## Earlier fork baseline — Tailscale 1.102.4

- Hardened the inherited menu-bar GUI's memory management, command lifecycle, output bounds, and status parsing.
- Documented the verified Intel Big Sur baseline while preserving the original project's older macOS work and attribution.
