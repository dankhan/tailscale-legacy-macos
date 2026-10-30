# MagicDNS on macOS 11 Big Sur

## Verified result

Tailscale **1.102.4**, built with **Go 1.26.6**, works on the tested Intel x86_64
MacBook Pro running **macOS 11.7.11 (20G1443)**. The user confirmed native utun
networking, authentication, tailnet connectivity, launchd daemon persistence,
automatic menu-bar GUI startup at login, and macOS Screen Sharing. MagicDNS
resolution and hostname-based Screen Sharing continued working after a reboot.
This verifies this repository's legacy build on that configuration; it is not a
claim of official Tailscale support or universal Big Sur compatibility.

## Original failure and evidence

Tailscale was running with MagicDNS enabled. Direct queries to Quad100
(`100.100.100.100`) succeeded, while system lookups, Finder, and Screen Sharing
could not resolve the same tailnet FQDN. IP-based Screen Sharing worked.

Read-only investigation on 2026-10-31 found:

- `/etc` is Apple's normal symlink to `/private/etc`; `/etc/resolver` and
  `/private/etc/resolver` were the same directory, inode 84066748.
- The directory and its canonical parents were root:wheel 0755. The current
  tailnet file was a regular root:wheel 0644 file with valid LF-terminated ASCII,
  no BOM, and no unexpected ACLs or attributes reported.
- The active suffix, discovered through structured Tailscale status, was
  `tail2cfc6e.ts.net`. That value is an observation, not an installation constant.
- Native logs selected `dns.darwinConfigurator` and recorded the correct
  Quad100 nameservers, match domains, and search suffix.
- All 67 native nameserver files (tailnet, `ts.net`, and reverse zones) had the
  same valid nameserver directives. A separate `search.tailscale` file existed.
- `dig @100.100.100.100 dans-macbook-pro.tail2cfc6e.ts.net A` returned
  `100.99.42.29`, but `dscacheutil -q host` returned no record.
- Unrestricted `scutil --dns` showed Wi-Fi defaults and mDNS domains, but no
  resolver for the tailnet. Wi-Fi had no manually configured DNS override.

The native tailnet file contained exactly:

```text
# Added by tailscaled
nameserver 100.100.100.100
nameserver fd7a:115c:a1e0::53
```

Its SHA256 was
`57960503f4bd6e8afe1c6543597386a5af61efdec1bb5b8b0f42960670c1b352`.
The search file contained:

```text
# Added by tailscaled
search tail2cfc6e.ts.net
```

Big Sur's installed `resolver(5)` manual accepts IPv4/IPv6 nameservers and uses
the filename as the domain when an explicit `domain` directive is absent.
Qualified-name resolution does not require a search directive. No file-format,
location, ownership, or domain-matching defect was identified.

## Successful registration refresh

The user subsequently ran this command once:

```sh
printf 'notify State:/Network/PrivateDNS\nquit\n' | sudo /usr/sbin/scutil
```

macOS then published the resolver and MagicDNS FQDN resolution worked. After a
reboot, registration and hostname-based Screen Sharing still worked without
another notification. No separate DNS reconciler was installed or activated;
its redundant implementation and installer hooks have been removed.

**The missed initial discovery notification hypothesis remains unconfirmed.**
configd had started on October 27; `/etc/resolver` was created on October 31.
This ordering and the successful refresh are consistent with stale discovery
state, but do not identify why automatic discovery failed. Retained logs did not
establish a parser rejection, FSEvents failure, or permission denial. The
successful reboot demonstrates persistence on this Mac, not that every Big Sur
installation needs the workaround or that every lifecycle case has been tested.

## How native integration works

The installed Apple binaries identified themselves as configd-1109.140.1 and
mDNSResponder-1310.140.1. Relevant version-matched source references:

- [Tailscale v1.102.4: darwinConfigurator.SetDNS](https://github.com/tailscale/tailscale/blob/v1.102.4/net/dns/manager_darwin.go#L24-L115)
  creates split resolver files and a search file. There is no explicit split-file
  refresh notification in this path. Its separate global-DNS implementation is
  not needed for these domain-specific resolvers.
- [Tailscale DNS manager](https://github.com/tailscale/tailscale/blob/v1.102.4/net/dns/manager.go#L172-L215)
  programs internal DNS separately from OS configuration. A successful Quad100
  query therefore does not establish that macOS registered the resolver.
- [Apple configd: file monitor and publication](https://github.com/apple-oss-distributions/configd/blob/configd-1109.140.1/Plugins/IPMonitor/dns-configuration.c#L1542-L1745)
  imports flat files, compares configuration signatures, and publishes changes.
  Its FSEvents monitor invokes a synthetic resolver-directory change callback.
- [Apple configd: flat-file parser](https://github.com/apple-oss-distributions/configd/blob/configd-1109.140.1/dnsinfo/dnsinfo_flatfile.c#L276-L565)
  reads `/etc/resolver`, parses nameservers, and derives an omitted domain from
  the filename.
- [Apple IPMonitor: DNS input changes](https://github.com/apple-oss-distributions/configd/blob/configd-1109.140.1/Plugins/IPMonitor/ip_plugin.c#L7815-L7828),
  [notification subscriptions](https://github.com/apple-oss-distributions/configd/blob/configd-1109.140.1/Plugins/IPMonitor/ip_plugin.c#L8382-L8430), and
  [PrivateDNS key construction](https://github.com/apple-oss-distributions/configd/blob/configd-1109.140.1/Plugins/IPMonitor/ip_plugin.c#L8504-L8513)
  explain why notifying the existing PrivateDNS input triggers recalculation.
  The command sends a notification; it does not replace that key's value.
- [Apple mDNSResponder: configuration consumption](https://github.com/apple-oss-distributions/mDNSResponder/blob/mDNSResponder-1310.140.1/mDNSMacOSX/mDNSMacOSX.c#L4767-L4802)
  obtains published DNS configuration through `dns_configuration_copy()` and
  tracks its generation. A cache flush alone does not establish registration.

This file-based split-DNS path does not require the official Tailscale Network
Extension. The evidence places the original failure after native file generation
and before publication of the expected resolver; it does not prove a specific
Tailscale or macOS defect.

## Diagnostics for future installations

These commands are read-only. Run from an ordinary Terminal: an application
sandbox can hide SystemConfiguration or block DNS/socket access, producing
misleading failures.

```sh
/usr/local/bin/tailscale --socket=/var/run/tailscaled.socket status --json
/usr/sbin/scutil --dns
/usr/sbin/networksetup -getdnsservers Wi-Fi
/usr/sbin/networksetup -getsearchdomains Wi-Fi
/bin/ls -ldeO@ /etc /private /private/etc /private/etc/resolver
```

Inspect `CurrentTailnet.MagicDNSEnabled` and `MagicDNSSuffix` locally. Status may
contain personal network details; redact it before sharing. Use the actual
network service name if it is not `Wi-Fi`. Substitute a validated suffix and a
known host from the current tailnet below; do not reuse this Mac's suffix:

```sh
/bin/ls -leO@ /private/etc/resolver/<tailnet-suffix>
/bin/cat /private/etc/resolver/<tailnet-suffix>
/usr/bin/dig +time=2 +tries=1 @100.100.100.100 <host-FQDN> A
/usr/bin/dscacheutil -q host -a name <host-FQDN>
printf 'show State:/Network/Global/DNS\nshow State:/Network/PrivateDNS\nquit\n' | /usr/sbin/scutil
```

The angle-bracket values are placeholders, not commands to paste literally.
An empty PrivateDNS array is not an inventory of resolver files and is not itself
a defect; check the aggregate `scutil --dns` output. A direct `dig` success tests
Quad100, while `dscacheutil` tests the system resolution path used by applications.

If native files are valid and Quad100 answers but the corresponding resolver is
absent from `scutil --dns`, consider the single notification above as a deliberate
repair after reviewing the evidence. It may cause configd to import **all**
existing resolver files. Do not put it unconditionally in installers or recurring
jobs. Afterwards verify the domain and Quad100 nameservers in `scutil --dns`, a
successful system FQDN lookup, unchanged ordinary DNS servers, and hostname-based
Screen Sharing. Reboot validation should be scheduled separately from any active
remote session.

The notification creates no persistent configuration or service, so there is no
stored change to uninstall or inverse notification to send. It can refresh
effective DNS; if behavior regresses, retain diagnostics and investigate rather
than deleting native resolver files or clearing PrivateDNS. Do not restart DNS
services, flush caches, or change global/Wi-Fi DNS as an automatic follow-up.

**Do not install a duplicate DNS file manager when native Tailscale already
creates the files correctly.** Diagnose missing publication first. The removed
reconciler would have duplicated a working step and conflicted with native file
ownership; current evidence does not justify another privileged service.
