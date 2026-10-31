# Tailscale for macOS 11 Big Sur — Intel

An unofficial, independently maintained fork of [startergo/tailscale-legacy-macos](https://github.com/startergo/tailscale-legacy-macos). The original project backports Tailscale to much older macOS releases. This fork adds a separate Intel macOS 11 build for current Tailscale source, since current official Tailscale builds no longer support Big Sur. It is not affiliated with or supported by Tailscale.

**Verified:** Tailscale **1.104.4**, built with Go **1.27.3**, on an Intel Mac running **macOS 11.7.11**. Native utun, authentication, MagicDNS, peer connectivity, Screen Sharing, launchd startup, and restart persistence were tested on that system. Other macOS versions and CPU architectures are not claimed. See [fork release notes](FORK_CHANGELOG.md).

## Build on a newer Mac

Use macOS 13 or newer with Xcode Command Line Tools, `git`, `curl`, and an Intel or Apple Silicon CPU. Go 1.27.3 itself requires macOS 13 or newer; **run the resulting binaries on Big Sur, not the build toolchain**. Keep the downloaded source and toolchain in ignored `src/`.

```sh
git clone https://github.com/dankhan/tailscale-legacy-macos.git
cd tailscale-legacy-macos
git clone --branch v1.104.4 --depth 1 https://github.com/tailscale/tailscale.git src/tailscale-upstream
mkdir -p src/toolchains/go1.27.3
curl -fL https://go.dev/dl/go1.27.3.darwin-arm64.tar.gz -o src/toolchains/go1.27.3.tar.gz
printf '%s  %s\n' 'dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2' 'src/toolchains/go1.27.3.tar.gz' | shasum -a 256 -c -
tar -xzf src/toolchains/go1.27.3.tar.gz -C src/toolchains/go1.27.3
./build-macos11.sh
./gui/build-gui.sh 11.0
```

The download above is for an **Apple Silicon build host**. On an Intel build host, use `go1.27.3.darwin-amd64.tar.gz` and SHA-256 `b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750` instead. Checksums are from [Go's official download page](https://go.dev/dl/). The build script checks the exact [Tailscale v1.104.4](https://github.com/tailscale/tailscale/releases/tag/v1.104.4) commit and Go version, targets `darwin/amd64` with `GOAMD64=v1` and a macOS 11.0 minimum, and writes `out-macos11/tailscale` and `out-macos11/tailscaled`. `out/TailscaleMenu.app` is the GUI output. These generated files are not tracked.

The macOS 11 build uses `shim/macos11_certchain.c` for Go's macOS 12 certificate-chain symbol. It retains normal Security.framework trust evaluation and does **not** apply the inherited peer-credential bypass or fallback-root patch used for older systems. Run the focused certificate checks with `./test/certchain-security/run.sh` on a supported build Mac.

## Install on Big Sur

For a **fresh installation**, transfer the verified output files to the target Mac and run the following in its Terminal from a directory containing `out-macos11/`, `out/TailscaleMenu.app`, and `deploy/`. Review the files and back up any existing installation first; these commands are not an in-place upgrade procedure.

```sh
sudo install -d -o root -g wheel -m 700 /var/lib/tailscale
sudo install -o root -g admin -m 755 out-macos11/tailscale /usr/local/bin/tailscale
sudo install -o root -g admin -m 755 out-macos11/tailscaled /usr/local/bin/tailscaled
sudo install -o root -g wheel -m 644 deploy/com.tailscale.tailscaled.macos11.plist /Library/LaunchDaemons/com.tailscale.tailscaled.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.tailscale.tailscaled.plist
sudo ditto out/TailscaleMenu.app /Applications/TailscaleMenu.app
```

The macOS 11 plist runs native `utun`, stores state at `/var/lib/tailscale/tailscaled.state`, and uses `/var/run/tailscaled.socket`. Do not run two native Tailscale daemons at once. Add `TailscaleMenu.app` in **System Preferences → Users & Groups → Login Items** for menu-bar startup. The menu uses the installed CLI and production socket; it does not manage the launchd job.

Authenticate interactively, then check status and a peer you control:

```sh
/usr/local/bin/tailscale --socket=/var/run/tailscaled.socket up
/usr/local/bin/tailscale --socket=/var/run/tailscaled.socket status
/usr/local/bin/tailscale --socket=/var/run/tailscaled.socket ip -4
/usr/local/bin/tailscale --socket=/var/run/tailscaled.socket ping <peer-hostname>
scutil --dns
```

MagicDNS should resolve both the peer's short name and its tailnet FQDN when enabled in the tailnet. If names fail while IP connectivity works, inspect `scutil --dns` and the daemon log. One Big Sur installation needed resolver registration to settle; no extra DNS manager is included here. Screen Sharing can then use a reachable peer's Tailscale name or IP.

## Manual upgrade and rollback

Before replacing an existing installation, back up **both installed binaries, the launchd plist, and the authentication state** into a private root-owned directory. Record SHA-256 checksums and the current Tailscale IP. Stop only the existing `com.tailscale.tailscaled` launchd job, install the two verified new binaries, and restart the **unchanged** plist. Allow startup to settle before checking identity, DNS, peer connectivity, GUI behavior, and reboot persistence. Keep the pre-upgrade state backup in case a version change migrates its format.

To roll back, stop that launchd job, restore the backed-up CLI and daemon as root-owned mode 755 files, restore the pre-upgrade state **only if needed and only while the daemon is stopped**, then restart the original plist. Do not delete or overwrite a working state file during ordinary binary rollback.

## Scope and attribution

The inherited `build.sh`, MacPorts shims, older-target patches, packages, and documents remain for the original project's macOS 10.6/10.9 work; they are **not** the macOS 11 build path. The macOS 11 result is an unsupported community build, verified on one Intel Big Sur configuration. Direct UDP connectivity depends on the network; DERP relay connectivity is valid but may be slower. The GUI reads human-readable CLI status, so future CLI output changes may require maintenance.

Original project: [startergo/tailscale-legacy-macos](https://github.com/startergo/tailscale-legacy-macos). Tailscale source and its licensing remain with [tailscale/tailscale](https://github.com/tailscale/tailscale). This fork preserves the inherited project's attribution and files.
