# Native runtime acceptance gate

**Status: not run.** The host has an Apple Development identity but no Developer ID Application identity or profile granting `dns-proxy-systemextension`. Hardware virtualization is supported, but no prepared VM/tooling was available. Neither obstacle was bypassed using security-setting changes. The implementation remains a foundation under validation, not daily-use protection.

Use the exact [native installation/rollback procedure](../../native/README.md) in a disposable macOS VM. Do not use the earlier DNS relay for these native tests: that would prove a different data path. Never activate or install profiles on the everyday host without explicit authorization.

## Record before starting

Record UTC timestamp, Git commit, `sw_vers`, hardware architecture, Xcode version, policy SHA256, app/provider bundle versions, expected app IDs and profile identifier. Record Safari/Chrome/Firefox versions and policy dashboards. Save `scutil --dns`, network service DNS settings, route/VPN information and installed profile identifiers **inside the VM only**; private network names and profile contents need not be published. Keep baseline and screenshots in a private VM evidence folder until reviewed for privacy.

Use a clean admin lab account and snapshot with no personal browser/cloud login. Prepare a controlled web origin and lab DNS server on the VM's private test network. `adult.example`, `sub.adult.example`, `blocked.example`, `sub.blocked.example` should resolve/reach that origin before filtering; `allowed.example` should remain reachable with filtering. Prefer this to opening adult content. Do not put fake adult fixture addresses in `/etc/hosts`, which would test a DNS bypass instead of the provider.

## Before browser tests

1. Verify the real Developer ID signatures, embedded profile grants, Gatekeeper/notarization expectations and bundle layout. Copy the signed app into the VM's `/Applications`, activate and approve it, and record the command's result. Neither `codesign --verify` on an ad-hoc bundle nor a saved `isEnabled` flag proves activation.
2. Record `systemextensionsctl list`, process state and lifecycle-only log entries from subsystem `io.clearpath.Clearpath.DNSProxy`. Confirm the expected provider class starts with a validated policy. Do not enable query or URL logging to produce evidence.
3. Query blocked fixtures and a known normal name with the system resolver and explicit alternate DNS over UDP/TCP, IPv4/IPv6. The provider must capture ordinary port-53 destinations or the gap must be recorded. If any normal name stops resolving, deactivate using the VM console and investigate before continuing.
4. Install only `io.clearpath.browser-policy.v1` and verify effective keys in `chrome://policy` and `about:policies`, including policy errors/conflicts. Record an unfiltered-DoH baseline first. Profile installation, acceptance and removal are manual supported OS operations, not a script that overwrites managed preferences.

## Per-browser evidence table

Fill every cell with observed result, timestamp and evidence reference. Blank/not-run is never a pass. Repeat normal and private/incognito sessions, including a new browser profile and guest mode where available.

| Case | Safari | Chrome | Firefox | Pass condition |
|---|---|---|---|---|
| Adult fixture apex + subdomain | Not run | Not run | Not run | Browser cannot reach controlled origin; origin records zero hits; nearby allowed domain loads |
| Custom fixture apex + subdomain | Not run | Not run | Not run | Same outcome for custom policy; custom block still wins over allow/SafeSearch entries |
| Google SafeSearch | Not run | Not run | Not run | `/safesearch` shows filtering locked; user controls and disabling query parameters cannot turn it off; valid HTTPS |
| Supported Google regional hostname | Not run | Not run | Not run | Explicitly configured name enforces lock; omitted names documented as uncovered |
| Bing and DuckDuckGo SafeSearch | Not run | Not run | Not run | Settings remain strict when controls/query parameters attempt to disable them |
| Normal browsing | Not run | Not run | Not run | Several normal sites load, login redirects work using lab accounts, downloads and WebSockets function |
| Browser-managed DoH | Relevant OS path | Not run | Not run | Without policy, document bypass; with policy, effective setting locked/off and expected DNS path used |
| Private Relay / VPN / encrypted DNS profile | Not run | Not run | Not run | Record actual routing/bypasses and conflicts, not an assumed guarantee |
| Warm DNS/cache + open QUIC/HTTP2 connection | Not run | Not run | Not run | Record retained access after a new rule; verify fresh connections separately |
| Safe target outage | Not run | Not run | Not run | Search fails instead of receiving ordinary unfiltered addresses; unrelated domains still work |
| Control command/app exits | Not run | Not run | Not run | Blocked fixtures/SafeSearch still filtered after host process is absent |
| Logout/login + reboot | Not run | Not run | Not run | Without reopening Clearpath, provider reappears and all relevant filtering tests pass |
| Sleep/wake + network switch | Not run | Not run | Not run | New original resolver destinations work, no stale hardcoded/public DNS, no recursion |

Provider SafeSearch is search-engine classification, not complete filtering of adult material on mixed-use sites. Do not test the limitation by claiming a benign query's results establish classification accuracy for every query.

## Developer and networking regression gate

With native interception active, run the [existing developer matrix](../TESTING.md#developer-regression-plan-in-that-vm): localhost IPv4/IPv6 HTTP, hot reload/WebSockets, Git HTTPS and SSH to a lab host, npm/pip downloads in disposable projects, Docker DNS/pull/published ports, loopback and private-name database connections, split DNS and VPN transitions, mDNS/DNS-SD and captive portals. Compare to baseline. Repeat on IPv6-only/NAT64 networking if it is a supported environment. Existing process-local live probes do not satisfy this gate.

## Rollback and failure injection

1. Close the control process, then deactivate from the installed bundle. Confirm DNS and development services work. Repeated deactivate must be harmless.
2. Uninstall with the control command. Confirm saved preference removal precedes system-extension deactivation. If reboot is requested, retain the app, reboot, and verify its provider is absent before deleting the bundle.
3. Remove **only** the Clearpath browser profile. Verify its keys disappear while preexisting profiles and their effective policies remain. Compare DNS/scoped resolver/network/VPN state and normal/private browsing to baseline. Restart browsers and reboot the VM; confirm networking still works.
4. Repeat with an invalid policy, missing options, policy above the inline limit, user-denied extension approval, failed preference save, pending-reboot removal, sudden provider termination and a second preexisting DNS proxy. Ensure failures are reported without wiping unrelated configuration. Mocked transaction tests cover ordering and rollback logic but do not replace these OS tests.
5. If rollback fails or cannot be confirmed, retain the app and use System Settings in the VM console to disable only Clearpath's DNS Proxy. Restore the snapshot if necessary. Never reset all network services, remove all profiles, disable SIP, modify Screen Time, or delete another app's extension as a shortcut.

The release gate remains closed until these runtime outcomes are recorded. A machine-readable checklist is retained in [acceptance.json](acceptance.json); update it only with measured evidence.
