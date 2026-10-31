# Fork changelog

## Tailscale 1.104.4 — Intel macOS 11 Big Sur

- Added a separate, pinned macOS 11 build using [Tailscale v1.104.4](https://github.com/tailscale/tailscale/releases/tag/v1.104.4) and [Go 1.27.3](https://go.dev/dl/), targeting `darwin/amd64`, `GOAMD64=v1`, and macOS 11.0. The original older-macOS build remains separate.
- Added a narrow Security.framework compatibility implementation for `SecTrustCopyCertificateChain`, which Go 1.27.3 references but Big Sur does not export. It copies the evaluated certificate chain with Core Foundation ownership semantics; normal trust, hostname, usage, and validity checks remain in Go and macOS. Focused verification and ABI tests are included.
- Kept the macOS 11 build free of the inherited old-kernel peer-credential authorization bypass and fallback certificate roots. The legacy patches remain available only through the original build path.
- Improved the native menu-bar app with local device name, Tailscale IPv4, dynamically detected version, clear connection state, and a peer list that excludes the local device. The existing bounded asynchronous CLI execution and lifecycle fixes are retained.
- Verified on Intel macOS 11.7.11: authentication, native utun routing, MagicDNS, peer connectivity, Screen Sharing, launchd startup, and persistence after reboot. This is community verification, not official Tailscale support or a guarantee for other hosts. Direct UDP was not established in the bounded peer test; DERP connectivity worked.

## Earlier fork baseline — Tailscale 1.102.4

- Hardened the inherited menu-bar GUI's memory management, command lifecycle, output bounds, and status parsing.
- Documented the verified Intel Big Sur baseline while preserving the original project's older macOS work and attribution.
