# Native macOS filtering foundation

The native implementation is built and tested in isolation. **It has not been activated on a Mac.** Read [current evidence](../docs/native/RESULTS.md) before relying on it. The baseline is macOS 15+, Xcode 16+ and Swift 5.9 package syntax. No third-party Swift dependencies are required.

## Components

- `ClearpathCore`: immutable validated policy, matching, bounded DNS wire reader, filtered DNS resolver, TCP framing, and testable preference/activation transaction.
- `ClearpathNetwork`: Network.framework DNS transport to the **original flow's resolver endpoint**. No hardcoded public resolver, hosts-file change, DNS configuration replacement or route installation. A deadline and task cancellation release each transaction. UDP truncation retries TCP to the same endpoint.
- `ClearpathDNSProxy`: real `NEDNSProxyProvider` system-extension entry point. It handles UDP and TCP flows, retains sessions, writes replies with their original endpoints, and imposes session/batch/buffer bounds and backpressure. System-started options carry the validated policy, independent of the control process. Only lifecycle events are logged.
- `clearpathctl`: a minimal command in a host `.app` bundle to validate a policy, make explicit process-local probes, read saved status, activate/deactivate, or uninstall. It has no window or account system. Only explicit mutation commands request OS changes; they require an installed signed app and `--allow-system-changes`.

The host is an ordinary unsandboxed Developer ID command so it can read an explicitly supplied policy file without a file-picker UI. The provider is sandboxed, with network-client and Mach-service app-group entitlements. There is no root LaunchDaemon, privileged helper, XPC control server, login item, packet tunnel, kernel extension or certificate interception. The Mach service app group is required by Network Extension registration; it is not used for browsing-history storage.

## Local build and tests — no installation

From the repository root:

```sh
swift test --package-path native --scratch-path artifacts/native-build
swift build --package-path native --scratch-path artifacts/native-build -c release
swift build --package-path native --scratch-path artifacts/native-build -c release --show-bin-path
```

Use the last command's output as `BIN` below; it varies by SwiftPM/Xcode version:

```sh
BIN="$(swift build --package-path native --scratch-path artifacts/native-build -c release --show-bin-path)"
"$BIN/clearpathctl" validate policy.example.json
# Numeric QTYPE: A=1, AAAA=28, CNAME=5, HTTPS=65; explicit resolver and port:
"$BIN/clearpathctl" probe policy.example.json www.google.com 1 1.1.1.1 53
.venv/bin/python scripts/native_smoke.py --binary "$BIN/clearpathctl" --upstream 1.1.1.1 --output artifacts/native-live.json
```

The `probe` path uses the **same Swift engine and Network.framework transport**, but does not intercept application traffic or use either manager API. Live probes disclose allowed test names and safe endpoints to the explicitly selected DNS resolver. No adult website is contacted over HTTP/TLS. They are not browser tests.

Create a workspace inspection bundle without your signing key:

```sh
.venv/bin/python scripts/build_native.py --output artifacts/native-inspection
```

Output is `artifacts/native-inspection/Clearpath.app`. Select a fresh output path on subsequent builds; the script refuses to overwrite an existing app. The default bundle is ad-hoc signed for structure/signature inspection **only** and cannot activate the provider. The script never copies to `/Applications`, registers extensions, installs profiles, or changes system configuration. Python is only build/test tooling, not a runtime dependency of the app.

## Signing gate

Apple's [deployment table](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) supports macOS DNS Proxy system extensions. [Developer ID Network Extension entitlement setup](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) and normal system-extension approval are still required. An Apple Development certificate alone does not satisfy this repository's direct-distribution build path. Do not disable SIP or enable system-extension developer mode to bypass verification.

Register the exact app IDs `io.clearpath.Clearpath` and `io.clearpath.Clearpath.DNSProxy` for the distributing team. The host and extension need `dns-proxy-systemextension` in their Developer ID profiles, and the host needs `com.apple.developer.system-extension.install`. Both use the team's macOS app group `<TEAMID>.io.clearpath.shared`; the provider Mach service name must have that group as its prefix. If these bundle IDs are unavailable to your team, update the constants in build tooling and lifecycle code together and rerun tests. No secret profile or certificate belongs in Git.

```sh
.venv/bin/python scripts/native_preflight.py --output artifacts/native-preflight.json
.venv/bin/python scripts/build_native.py \
  --output artifacts/native-signed \
  --team YOURTEAMID \
  --identity 'Developer ID Application: Your Name (YOURTEAMID)' \
  --host-profile /path/to/host.provisionprofile \
  --provider-profile /path/to/provider.provisionprofile \
  --build-number 2
```

The builder validates profile team/app ID, expiry, DNS capability and app group; rejects device/development profiles; signs the extension first and host second with hardened runtime; and checks each signature. The system remains the final authority for signing/profile eligibility. This is not a notarization workflow. Before distributing beyond a controlled VM, notarize/staple using your team's supported Apple tooling and verify Gatekeeper acceptance. Signing with real profiles, notarization and activation are currently untested here.

## Policy behavior

The existing `policy.example.json` format is preserved. Decision order remains custom block, exact SafeSearch mapping, adult allow exception, adult suffix block, allow. Duplicate JSON keys, schema errors, invalid hostnames, cyclic SafeSearch maps and unsafe allow overlaps are rejected. Native and Python decisions share a corpus and policy hash. Foundation performs native Unicode IDNA conversion; Python uses its built-in IDNA implementation. Prefer ASCII A-label rules for cross-runtime reproducibility; Unicode edge-case parity beyond the tested corpus is not guaranteed.

The core accepts bounded 16 MiB JSON; this first provider configuration deliberately limits the **inline persisted policy to 512 KiB**. The preference store has no published general-purpose large-dataset size guarantee. Oversized policies are rejected rather than silently truncated. This is a constraint, not proof of scalability to a full community adult list. A large-list storage/update design needs separate validation. The bundled sample still contains only three real adult domains and synthetic test domains; it is not a comprehensive adult classification dataset.

The provider loads a complete policy snapshot from [start options](https://developer.apple.com/documentation/networkextension/nednsproxyproviderprotocol/providerconfiguration). No user-writable filesystem path is followed by a root provider. To change policy, validate the candidate, explicitly deactivate, then reactivate with the new file. Different live policies are rejected to avoid pretending a preference save atomically updates existing flows. There is a protection gap while disabled. Keep a previous policy copy for deliberate reactivation; there is no recovery/accountability workflow.

Allowed DNS answers are forwarded as original wire bytes. Only names, questions, counts and bounded resource-record fields needed for filtering are decoded. Synthesized answers contain fresh counts/flags and no unearned DNSSEC AD bit or dangling EDNS OPT bytes. Safe A/AAAA replies contain a forced-safe CNAME and only the safe target's address/CNAME chain. An unavailable target returns SERVFAIL; protected HTTPS/SVCB hints are suppressed. The transport trusts the original upstream and performs no independent DNSSEC validation or DNS encryption upgrade.

## Browser policies

```sh
.venv/bin/python scripts/browser_profile.py --policy policy.example.json --output artifacts/Clearpath-Browsers.mobileconfig
```

This writes a removable `io.clearpath.browser-policy.v1` profile with Chrome (`com.google.Chrome`) and Firefox (`org.mozilla.firefox`) payloads. It does not install it, read existing profiles or modify browser app bundles. Chrome gets `DnsOverHttpsMode=off`, `ForceGoogleSafeSearch=true`, and custom-domain URL blocks. Firefox gets enterprise policy support, locked `DNSOverHTTPS.Enabled=false`, and custom WebsiteFilter patterns. The generator rejects more than 500 custom domains instead of overflowing Firefox's rule cap; adult lists remain in DNS. The generated profile can reveal configured custom domain names to local administrators, as can the source policy.

Sources: [Chrome macOS policy deployment](https://support.google.com/chrome/a/answer/9020077), [Firefox DNSOverHTTPS](https://firefox-admin-docs.mozilla.org/reference/policies/dnsoverhttps/), [Firefox WebsiteFilter](https://firefox-admin-docs.mozilla.org/reference/policies/websitefilter/). Disabling browser DoH routes queries through the configured DNS path; it does not itself encrypt upstream DNS. No developer-tools, private-browsing, extension-install or administrator restrictions are added. Existing management policies may conflict; inspect browser policy dashboards before relying on this profile. Installation/effect/removal have not been browser-validated here.

## VM-only install, activate and rollback

Do not perform these steps on the everyday Mac without explicit authorization. Use a disposable macOS VM with an admin account, no personal credentials and a clean snapshot. No prepared VM or eligible signing/profile setup was available in this session. See the [runtime validation checklist](../docs/native/VM_VALIDATION.md).

1. Read and save baseline DNS/scoped resolver, network services, profiles, VPN settings and installed extensions **in the VM**. Keep its console and snapshot available. Build and verify a properly signed app. Copy **only that app** to `/Applications/Clearpath.app` in the VM; there is no privileged installer script. Do not move the ad-hoc inspection bundle there.
2. Use `/Applications/Clearpath.app/Contents/MacOS/clearpathctl activate /path/to/policy.json --allow-system-changes`. Approve macOS's system-extension and DNS-filtering requests. The control command waits for extension approval, then saves only its own enabled DNS configuration and reads it back. If macOS requires reboot, it reports that state without enabling new DNS preferences; keep the app installed and retry after reboot.
3. Install only the generated Clearpath browser profile through the VM's supported configuration-profile UI. Verify Chrome `chrome://policy` and Firefox `about:policies`; test Safari separately. System profiles may require an administrator. A normal browser window closing must not disable the OS-owned provider; record this, don't infer it from process independence.
4. **Deactivate:** `clearpathctl deactivate --allow-system-changes` from the installed bundle. It loads and verifies ownership, saves disabled state, and reads it back. Test ordinary DNS, developer/private/VPN names and normal browsing while the app remains installed. It does not touch network-service DNS addresses, routes, Screen Time or other providers.
5. **Uninstall:** run `clearpathctl uninstall --allow-system-changes`. It disables, removes only the owned DNS preference, verifies removal, and then requests system-extension deactivation. A reported reboot-required state is pending removal, not a completed uninstall. Keep the app until extension removal is verified after reboot.
6. Remove only profile `io.clearpath.browser-policy.v1` in the VM. Existing profiles are not overwritten by the generator and must remain installed. Verify browser policy dashboards, normal/private DNS, VPN routing and restart behavior against baseline. Only then remove Clearpath.app. Retain/restore the VM snapshot if rollback cannot be verified.

Activation save/readback failures restore the previous owned configuration or remove only a newly created one. A concurrent/unfamiliar configuration is left intact and reported as an unverified rollback, rather than overwritten. These transaction paths are tested with mocks; actual Apple preference writes and uninstallation remain a runtime gate. There is no factory-network reset or blanket profile deletion command. If DNS fails while testing, use the VM console to disable only Clearpath's DNS Proxy in System Settings before deleting its app; never stop/remove the only active resolver blindly.

## Known limits

System-extension lifetime and persisted manager configuration implement independence from the control process in the intended design. **App-closure and reboot persistence are not yet demonstrated.** Start failure/OS crash behavior and coexistence with other DNS proxies need VM evidence. There is no fail-closed guarantee if macOS disables the provider.

DoH/DoT/DoQ to arbitrary endpoints, Private Relay, VPNs, proxies, hardcoded IPs, new/unmanaged browsers, caches and existing connections remain possible bypasses. Browser policies reduce selected paths; they do not make an administrator unable to remove them. Local/scoped/VPN DNS preservation follows original endpoints, interface and flow metadata, but is not established by public DNS probes. The provider caps sessions at 128, batch sizes at 64, accumulated data at 256 KiB and idle flow time at 30 seconds. Rejected/exhausted flows are dropped; sustained load/fuzz/security review is still needed. TCP messages are processed in order, with fresh bounded upstream connections. DNAME and other unhandled alias/routing mechanisms and DNSSEC-validating client compatibility remain unverified.

Normal browsing/developer-tool tests through the native provider, locked SafeSearch UI, complete browser policy rollback and repeated OS restarts must pass before daily-use installation can be recommended.
