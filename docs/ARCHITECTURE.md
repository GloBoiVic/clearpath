# Architecture

## V1 architecture (decided 2026-11-21)

Product rules are in `docs/BRIEF.md` → V1. The diagram is `docs/architecture/clearpath-v1.excalidraw`.

**Victor's decision, 2026-11-21: no paid Apple Developer Program for now.** Apple only allows the DNS proxy system extension to paid members, so V1 does not use it. V1 uses the option the 2026-11-17 assessment below set aside, a local DNS service, and accepts its costs. The extension stays the upgrade path.

Components:

- **Filter service.** A Swift background system service (a LaunchDaemon that launchd restarts on exit) runs the `clearpath-filter` loopback listener and drops to `nobody` after binding. The installed network services point their DNS at it. The filter reuses the policy and DNS code from `native-dns-foundation` and selects the upstream from the live System Configuration store for each forwarded lookup. A supplemental suffix takes priority, with the most specific match first. Ordinary lookups use the active network service's saved manual DNS or its current negotiated servers. An unusable matching scope fails rather than falling back to the ordinary resolver. Upstreams use IP literals and exclude the loopback listener. macOS continues to apply its search domains and handle Bonjour. VPNs and applications that send DNS outside the loopback listener can still bypass local filtering. Detecting a DNS setting or policy changed outside Clearpath is tracked in #21.
- **Service control.** `clearpath-service` installs, removes and reports the filter service: LaunchDaemon `io.clearpath.filter`, files in `/Library/Application Support/Clearpath`, and a recovery record of every network service's original DNS written before any change. The filter binds port 53 as root, then runs as `nobody`. Uninstall restores DNS before it stops the daemon.
- **Menu-bar app.** A Swift menu-bar app with no Dock icon: setup, status, block a site, request a removal, partner settings, uninstall. It controls the filter service locally. Quitting it does not stop filtering.
- **Browser profile.** The existing generator's Chrome and Firefox policy profile, installed during setup, turns off their built-in encrypted DNS so they cannot skip the filter.
- **Partner service.** A small open-source, self-hostable web service on a free tier. It stores partner emails, the pairing, check-ins, status events and approval requests, sends email, and serves the one-tap Approve and Deny links. It never receives browsing data. It raises the 24-hour "hasn't checked in" alert and applies the 7-day no-answer rule.
- **Python** stays as the test harness and reference implementation, not the shipping runtime.

Fail closed: if the filter service is down, lookups fail until launchd restarts it. If it stays down, the menu-bar app offers "Restore internet", which restores the previous DNS setting and alerts the partner.

Costs accepted with the local DNS service, to be measured in the VM before Victor's Mac: VPN and split-DNS coexistence, network changes and sleep/wake, captive portals, and an administrator can change the DNS setting back (detected and alerted, not prevented). Bypasses listed in the assessment below (encrypted DNS to arbitrary endpoints, VPNs, proxies, Tor, Private Relay) still apply.

# Technical foundation assessment — 2026-11-17

The assessment that led to the V1 architecture. Its preference for the DNS proxy extension is superseded for V1 by the decision above.

## Decision and acceptance boundary

Use local domain policy, provider-supported SafeSearch DNS aliases, and explicit browser configuration. A **Swift `NEDNSProxyProvider` system extension** is the preferred next deployment experiment: it avoids replacing each network service's DNS settings and does not require owning a loopback port 53 or a full VPN tunnel. This is a conditional architecture decision, not a claim that the extension has been built or activated.

The demonstrated boundary is narrower: blocked domains cannot resolve **through this prototype**, configured search names resolve to forced-safe endpoints, and unrelated DNS can pass through. It preserves administrator access. It cannot prevent an administrator from removing protection, selecting another browser, changing policy, using a VM, or booting another OS. Reliable voluntary filtering is a plausible product; unavoidable protection under those freedoms is not a supportable promise.

## Options considered

| Mechanism | Useful capabilities | Material costs or gaps | Decision |
|---|---|---|---|
| `/etc/hosts` | Simple static names | No wildcard policy, weak updates, no CNAME, alternate resolvers/caches bypass; modifies global state | Reject as foundation |
| Local DNS daemon + system DNS replacement | Small, easy to demonstrate, all cooperative browsers | Requires privileged deployment, original resolver backup, VPN/split-DNS integration, sleep/network-change recovery; encrypted DNS bypass | Use high-port experiment only |
| Managed encrypted DNS profile / remote family DNS | Less local resolver code | Provider sees queries; custom policy often cloud controlled; standalone browser DoH may ignore it; profile installation/removal and local trust model need testing | Optional future mode, not privacy default |
| Native DNS Proxy | DNS flow interception without routing all IP traffic | Signing, entitlement, approval and lifecycle work; port-53 scope excludes arbitrary DoH/DoT/DoQ | Preferred next native spike |
| Native content filter | Allow/drop flows, app identity, hostnames where supplied | Cannot rewrite traffic; not a universal decrypted URL feed; missing host metadata, tunnels and shared IPs remain difficult | Optional later guard, evidence required |
| Packet tunnel or transparent TLS proxy | Broader traffic control | Routing conflicts, VPN coexistence, transport implementation burden; TLS interception requires a root certificate and harms trust | Reject for this scope |
| Browser policies / extensions alone | Google SafeSearch policy; browser URL rules and DoH controls | Browser specific; removable by admin; portable/new browsers outside coverage; Safari needs another layer | Supplement DNS |
| macOS 26+ URL Filter | System-operated WebKit/URLSession URL checks | PIR server and dataset tooling; other engines must participate voluntarily; does not rewrite SafeSearch | Not the minimum cross-browser solution |

Apple's [DNS proxy API](https://developer.apple.com/documentation/networkextension/nednsproxyprovider) describes transparent interception of UDP/TCP port 53 flows and exposes system DNS settings. This is why switching from one ordinary DNS server to another may be capturable by the native provider, whereas this isolated listener cannot capture it. Actual interception of explicit alternate resolvers remains untested.

[Deployment requirements](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) permit macOS DNS proxies and content filters as system extensions from macOS 10.15. They run independently of the logged-in user. Direct distribution uses Developer ID signing. [Apple's entitlement setup](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) requires a capability-enabled provisioning profile. A free/open-source app can still incur developer signing/distribution costs. This experiment does not obtain signing, bypass SIP, install profiles, or request extension activation.

Apple [content filters](https://developer.apple.com/documentation/networkextension/content-filter-providers) separate the restrictive data-provider sandbox from a control provider that updates rules. This is useful for local privacy. Apple's [WWDC25 explanation](https://developer.apple.com/videos/play/wwdc2025/234/) describes allow/drop verdicts rather than traffic modification. Use DNS to enforce safe endpoints; do not assume a content filter can inject URL parameters. [`remoteHostname`](https://developer.apple.com/documentation/networkextension/nefiltersocketflow) is optional; [`url`](https://developer.apple.com/documentation/networkextension/nefilterflow/url) is documented only for WebKit-originated flows. Metadata coverage must be measured in each browser, not inferred from Safari or from SDK compilation.

The newer [URL Filter API](https://developer.apple.com/documentation/networkextension/url-filters) uses a local Bloom filter with PIR server lookups. Its automatic coverage is WebKit and URLSession; other networking engines must opt in. That server dependency and participation boundary make it a poor fit for this minimal local-first experiment.

## Proposed data path

```text
local domain files -> validate candidate -> atomic policy snapshot
                                           |
browser/system plain DNS -> native DNS Proxy -> local policy decision
                                           | block: NXDOMAIN
                                           | safe: resolve only provider safe target
                                           | allow: original network/scoped resolver
Chrome/Firefox policies -> prevent browser-managed DoH bypass
optional flow filter -> extra observable-host/domain/known-bypass checks
```

The prototype substitutes a loopback UDP/TCP server for the unimplemented native provider. Allowed requests go to one **explicit** upstream IP. It deliberately does not discover, overwrite, or claim to preserve the Mac's scoped DNS configuration. Before shipping, preserve VPN DNS, resolver search domains, captive portals, per-interface behavior and `.local`/mDNS. Do not resolve upstream targets using the OS resolver from inside intercepted DNS, which risks recursion.

## Policy and SafeSearch semantics

Decision order: explicit custom block; exact SafeSearch hostname; explicit allow exception; adult-list suffix block; otherwise forward. Exceptions intentionally bypass adult-list blocks; custom blocks always win. Allow rules overlapping a safe hostname are rejected. Matching uses label boundaries, lowercase ASCII/IDNA hostnames and a single optional trailing dot. IP literals, URL syntax, empty labels and oversized labels are not accepted as rules. Single-label and DNS-SD queries are forwarded. This prototype does not include a Public Suffix List; a rule such as `co.uk` can overblock and must be reviewed.

Use these provider-documented CNAME mappings, keeping the original HTTPS host and certificate verification:

| Provider | Example protected name | Forced endpoint | Scope |
|---|---|---|---|
| Google | `www.google.com` | `forcesafesearch.google.com` | Only configured Google search/country hostnames |
| Bing | `www.bing.com`, `edgeservices.bing.com` | `strict.bing.com` | Search and documented Edge sidebar endpoint |
| DuckDuckGo | `duckduckgo.com` | `safe.duckduckgo.com` | Configured search hostname |

Sources: [Google](https://support.google.com/websearch/answer/186669), [Microsoft](https://support.microsoft.com/en-us/bing/blocking-explicit-content-with-safesearch), [DuckDuckGo](https://duckduckgo.com/duckduckgo-help-pages/features/safe-search). The sample also maps Google/Bing apex names and one Google regional name; those extras need browser validation. Do not rewrite all of `*.google.com`: that can break developer APIs, login and unrelated services. No universal rule covers every search engine. Unsupported engines require an explicit product decision to allow, block, or add verified provider support. YouTube Restricted Mode and content inside mixed-use sites are outside the implemented policy.

For A/AAAA, resolve the safe target through the explicit upstream and return CNAME plus its matching records. If it has no IPv6 record, return no unsafe IPv6 address. If resolution fails, return SERVFAIL, never ordinary search IPs. For protected hosts, suppress HTTPS/SVCB records to avoid alternate address hints. Rewrites do not assert the DNSSEC AD bit; synthesized policy answers cannot preserve authoritative DNSSEC signatures. The prototype trusts its upstream for allowed answers and performs **no independent DNSSEC validation**. Local DNS-rewriting compatibility with validating clients is unverified.

## Browser configuration

Inert samples are under `examples/`; they are not installed. Chrome's [`DnsOverHttpsMode`](https://chromium.googlesource.com/chromium/src/+/376fc41e87a058f7a7b300b0ec3a4982b4ec0960/components/policy/resources/templates/policy_definitions/Miscellaneous/DnsOverHttpsMode.yaml) supports `off`, and [`ForceGoogleSafeSearch`](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Miscellaneous/ForceGoogleSafeSearch.yaml) forces Google SafeSearch. On macOS, an arbitrary JSON file in this repository is not a policy deployment: use a VM-only configuration profile/managed preference payload for `com.google.Chrome` and verify `chrome://policy`. A fresh Chrome user-data directory does not isolate machine policies.

Firefox's [policy documentation](https://mozilla.github.io/policy-templates/) supports `DNSOverHTTPS.Enabled=false` with `Locked=true`, plus `WebsiteFilter`. These settings do not supply universal SafeSearch; DNS still supplies the safe endpoints. Firefox supports `policies.json` in an app's distribution directory; a cloned unsigned/modified bundle may have signing implications. Use a disposable VM and verify `about:policies`, including private windows and later updates. Safari uses the controlled system path in the proposed configuration; Private Relay, VPNs and encrypted DNS profiles require separate validation. No Screen Time dependency is proposed.

## Privacy, lists and operational limits

All policy decisions stay local. No browsing/query log, analytics, account, URL history, TLS interception or root certificate is implemented. The upstream resolver still sees allowed DNS names and safe-target queries; the network can observe plaintext DNS. HTTPS endpoints see ordinary requests. Live smoke output deliberately records only fixed test domains. Local-only filtering does not mean queries never leave the device.

The tiny sample adult list proves matching, not classification quality. A production list pipeline needs versioned sources, license/attribution review, freshness health, size/change thresholds, staging, atomic promotion, last-known-good disk generations, and false-positive exceptions. HaGeZi is a candidate, but its repository carries [GPLv3](https://github.com/hagezi/dns-blocklists/blob/main/LICENSE); inspect dataset/source notices before redistribution. No third-party dataset is bundled here. The local importer validates syntax and rejects empty/corrupt input; it is not a supply-chain updater or crash-durable generation store.

The experiment bounds request workers at 32, returns truncation for UDP answers exceeding the client's clamped size, and supports one request per TCP connection. It has no cache, encrypted upstream, multi-resolver failover, mDNS routing, DNSSEC validator, DoH server, exhaustive DNS parser fuzzing or production load/security audit. Known CNAME block targets are checked; DNAME, unknown alias mechanisms and hardcoded IPs are not covered.

DNS caches, existing TCP/QUIC connections, service workers and offline content can outlive policy changes. A high-port resolver cannot revoke those connections. A flow filter may help with new observable connections, but that remains a hypothesis. Shared-host/path-specific adult material cannot be blocked precisely with domain policy. DoH to arbitrary HTTPS endpoints, DoT/DoQ, Private Relay, Tor, VPNs, remote browsers and proxies can bypass DNS-only filtering. Broad IP/443 or VPN blocklists would damage developer workflows without guaranteeing protection; do not ship them as the default.

## Next decision gate

Proceed to a signed DNS Proxy spike **in a disposable macOS VM**, with the same policy tests ported to Swift, only after accepting the cooperative threat model. Measure flow capture, original resolver routing, browser policy effectiveness, provider outage behavior and lifecycle recovery using the matrix in TESTING.md. Add a content filter only for a measured gap that it can actually close. If arbitrary encrypted DNS must be impossible while all admin/network tools remain unrestricted, revise that requirement before building the application.
