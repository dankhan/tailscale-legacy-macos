# Fork Changelog

This file records fork-specific changes, their rationale, verification evidence,
and compatibility implications separately from the original project. Each entry
distinguishes inherited code, fork source changes, documentation, and observations
from a local deployment.

## 2026-10-31 — Verified macOS 11 Big Sur support and GUI reliability improvements

### Context and upstream base

Base: `startergo/tailscale-legacy-macos` commit
`ac93594` (`gui: menu-bar status item for legacy macOS (TailscaleMenu.app)`).
The inherited project targets substantially older macOS releases and supplies the
legacy build scripts, compatibility patches/shims, packaging, daemon service, and
initial menu-bar GUI. Its history also already tracks Snow Leopard executables
and MacPorts shim libraries; this change does not remove or replace those files.

Target: an Intel MacBook Pro running macOS 11.7.11, using Tailscale 1.102.4 and
Go 1.26.6. The objective was reliable native connectivity for remote access to
another Mac. Big Sur operation was verified on actual hardware; it was not
introduced through a new Tailscale core compatibility patch.

### Fork-specific GUI changes and rationale

- Correct Objective-C manual memory management, including scanner results,
  retained timer/controller references, and login URL replacement/lifetime.
  This addresses invalid releases, leaks, and stale state during repeated polls.
- Declare `NSMenuDelegate` and `NSApplicationDelegate` conformance, validate status
  field counts before indexing, and parse login URLs without the old scanner
  edge case. These changes make menu/status handling safer and remove related
  compiler warnings.
- Move CLI execution off the main thread onto a serial operation queue; admit
  one request at a time and disable conflicting actions. A stalled CLI should
  not freeze the menu or cause overlapping connection requests.
- Bound command time and captured output, use nonblocking pipe reads and
  monotonic deadlines, support cancellation, and terminate/reap only the spawned
  CLI child. Surface cleanup failures rather than continually admitting work.
- Apply state and AppKit changes on the main thread. Stop polling, cancel active
  work, defer application termination until completion, and release lifecycle
  references safely.

These GUI improvements are fork-specific until accepted by the original project.
No new changes were made to the upstream Tailscale Go core. The inherited legacy
patches remain as before; the existing Tailscale 1.102.4 binaries and installed
menu-bar application were not modified by this preservation work.

### MagicDNS: deployment observation and documentation

Native Tailscale already generated valid `/etc/resolver` files and Quad100
answered queries. Initially macOS did not publish those resolvers. One
SystemConfiguration DNS notification caused macOS to recognize the existing
configuration; DNS and hostname-based Screen Sharing remained functional after
reboot. The precise cause of the initial missed discovery remains unconfirmed.
See [the technical findings and troubleshooting commands](doc/magicdns.md).

A separate DNS reconciler was prototyped and passed isolated tests, then was
deliberately discarded: it duplicated native file generation and conflicted
with native ownership. It was never installed or enabled. This entry records
that engineering decision; no reconciler or additional service is included.
The notification was a local deployment action, not an installer or core change.

Documentation-only changes add the verified configuration to README and retain
the investigation in `doc/magicdns.md`. Repository housekeeping adds targeted
ignore rules for generated/local files without hiding source assets or fixtures.

### Verification evidence

The completed local validation reported:

- Successful x86_64 GUI build with macOS 11.0 deployment target; compiler warnings
  eliminated and static analysis successful.
- Successful GUI self-test and synthetic concurrency, timeout, and memory tests.
- Working native utun networking, tailnet authentication, and Screen Sharing over
  a Tailscale IP.
- Working MagicDNS hostname-based Screen Sharing after resolver registration.
- Automatic daemon startup through launchd and menu-bar GUI startup at login,
  with functionality confirmed after reboot.

The preservation review rechecks the GUI build, compiler diagnostics, static
analysis, self-test, diff whitespace, and ignore rules. The earlier synthetic
harnesses were temporary and are not retained in this source tree; their results
are recorded as earlier validation, not a reproducible committed test suite.
Reboot/network observations are user-confirmed deployment results, not automated
checks run during repository preservation. These tests do not prove indefinite
stability or compatibility with other macOS versions.

### Known limitations

- The Tailscale core is an unofficial legacy build. Current upstream security
  updates are not incorporated automatically; upgrades require review and tests.
- Human-readable CLI status parsing may need updates when CLI output changes.
- Older macOS releases have not been independently retested with this modified
  GUI, despite the inherited project's older deployment targets.
- The original MagicDNS registration issue may recur on fresh installations.
  Do not assume every Big Sur host needs the notification or a second DNS manager.

## Future entries

Add a dated entry with a descriptive title, upstream base version or commit,
changes made, rationale, testing performed, compatibility/security implications,
and related commit or PR links. Separate source changes from documentation and
local deployment observations. Keep detailed investigations in linked documents.
