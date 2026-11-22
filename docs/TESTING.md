# Test procedures and safe rollback

## Tests safe to run in this workspace

```sh
swift test --package-path native --scratch-path artifacts/native-build
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python -m clearpath.policy policy.example.json
swiftc -typecheck -module-cache-path artifacts/swift-module-cache scripts/check_networkextension.swift
```

The unit/integration suite uses local fixture servers, temporary policy files and subprocesses. It tests domain boundaries and IDNA, record types, SafeSearch failure, CNAME aliases, UDP/TCP and IPv6 listeners/upstreams, EDNS, malformed input, answer truncation, response-ID validation, parallel queries, no-query logging, atomic imports, SIGHUP, graceful termination and process restart. It also **expects a bypass** when querying the fixture upstream directly.

`tests/test_swift_filter.py` builds the Swift `clearpath-filter` and runs it from a temp folder on a free loopback port against a loopback fixture upstream. It checks blocked apex and subdomains, forced Google/Bing/DuckDuckGo answers, allowed answers, HTTPS/SVCB, CNAME aliases, an unavailable safe target, silent, malformed and mismatched upstream replies, malformed client queries, TCP pipelining, IPv6, the loopback and port guards, startup refusal on a bad policy or upstream, and that no query name is logged. The Swift package tests cover the same engine in-process. This is deliberate evidence against overstating DNS-only protection.

Run the Swift command from the repo root. It uses the ignored `artifacts/` directory to avoid a Swift 6.4.2 crash when the compiler sees the same cache through both `/tmp` and `/private/tmp`.

The Swift command checks that the installed SDK accepts the provider subclasses and hostname API. It does not build a signed extension, exercise callbacks or prove flow metadata availability. The upstream reproduction command is documented in UPSTREAM_AUDIT.md.

Optional network probes:

```sh
.venv/bin/python scripts/live_smoke.py --upstream 1.1.1.1
```

This starts temporary loopback listeners, queries a selected public resolver for allowed/forced-safe endpoints and uses per-process `curl --resolve` for HTTPS HEAD requests. It preserves TLS certificate validation. It sends no HTTP request to an adult site; adult fixture names are answered locally. The script records fixed test domains, DNS answers and HTTP/TLS status. It does not inspect search results or prove a locked browser setting.

## Cross-browser validation: disposable macOS VM only

**Not performed in this session.** Host networking, profiles, existing browser preferences and Screen Time were deliberately left alone. No Chrome/Firefox installation, VM creation, reboot or provider activation occurred. Chrome and Firefox were not present in the top-level `/Applications` inventory; they may exist elsewhere. Safari's presence is not a test result.

1. Create a disposable macOS VM on supported Apple hardware, with an admin lab account, no personal iCloud/browser login, no shared credentials and a clean snapshot. Choose the minimum supported macOS and the latest stable version for separate runs. Install current Safari/Chrome/Firefox in the VM. Record OS build and browser versions.
2. Save the VM's full DNS state (`scutil --dns`), network-service list and original DNS settings for **each** service. Record whether each uses DHCP-provided DNS or explicit server addresses. Record any VPN/profile/proxy settings. Keep the VM console available throughout.
3. Run the prototype on `127.0.0.1:1053`. Browsers cannot normally select a custom system DNS port. For this DNS-path experiment, use a VM-only, audited UDP **and** TCP port-53 relay to that listener; configure only the VM's active service to use its loopback relay. Never try to point a browser at port 1053 using ordinary macOS DNS UI. The Python prototype intentionally rejects listening directly on port 53; the Swift filter accepts port 53, which the `clearpath-service` LaunchDaemon described below uses.
4. If `socat` is installed inside the VM, two foreground VM terminals can run `sudo socat UDP4-RECVFROM:53,bind=127.0.0.1,reuseaddr,fork UDP4-SENDTO:127.0.0.1:1053` and `sudo socat TCP4-LISTEN:53,bind=127.0.0.1,reuseaddr,fork TCP4:127.0.0.1:1053`. These are lab relays, not a proposed production service. Select the VM's actual service by name; do not select the first service automatically. Check for an existing port-53 listener before starting. If changing the real host instead, stop and obtain explicit authorization first.
5. Run baseline rows below with browser policies absent. In the VM only, install a clearly identified test configuration profile with Chrome's settings from `examples/chrome-policy.json`, using the `com.google.Chrome` preference domain. For Firefox, use its documented managed profile or VM-local `distribution/policies.json` mechanism with `examples/firefox-policies.json`. Keep originals. Verify displayed values and errors in `chrome://policy` and `about:policies`; JSON parsing alone is insufficient.
6. Use fresh VM browser profiles, normal and private/incognito/guest sessions. Clear caches in the disposable profiles and restart the browser between policy generations. Do not clear host browsing history or caches. Use controlled synthetic domains for browser negative tests. A lab upstream can resolve `adult.example` and `blocked.example` to a lab HTTP server when filtering is absent; through the filter those names must fail without reaching that server. Do not require visiting real adult content to establish the DNS-path test.

### Required matrix and expected interpretation

Record timestamp, versions, policy SHA256, browser policy export, observed result and pass/fail for **each browser**, not a single aggregate checkmark.

| Case | Safari | Chrome | Firefox | Expected evidence |
|---|---|---|---|---|
| Synthetic adult and custom domains, apex + subdomain | Test | Test | Test | Filtered DNS NXDOMAIN and no hit at the controlled origin; nearby allowed name loads |
| A + AAAA + HTTPS/SVCB | Test | Test | Test | No alternate address path for blocked/search hosts; inspect IPv4/IPv6 behavior |
| Google SafeSearch | Test | Test | Test | Visit `https://www.google.com/safesearch`; filtering shown locked; attempts to switch off fail; test benign text/image/video queries, signed out |
| Regional Google hostname | Test | Test | Test | Every supported country hostname has explicit rule and locked setting; an omitted hostname is a documented gap |
| Bing / DuckDuckGo | Test | Test | Test | Safe mode locked, attempts to disable via controls/query parameters fail; HTTPS valid |
| Private/incognito/guest + new profiles | Test | Test | Test | Same blocking/SafeSearch boundary; capture policy scope differences |
| Browser Secure DNS enabled, no policy | N/A or OS path | Test | Test | A successful bypass is expected for unfiltered DoH; record it |
| Browser Secure DNS enabled, policy applied | OS path | Test | Test | Setting is locked/off and requests traverse controlled DNS; confirm with a VM-only packet trace |
| Alternate plain DNS, IPv4 and IPv6 | Test | Test | Test | High-port PoC is bypassable. Future native DNS Proxy must demonstrate capture of explicit UDP/TCP 53 destinations |
| DoT/DoQ/custom DoH, HTTPS proxy, SOCKS, VPN/Tor | Test relevant paths | Test | Test | Treat as bypass unless measured otherwise; known endpoint lists are not comprehensive |
| Private Relay on/off, encrypted DNS profile | Test | Relevant OS path | Relevant OS path | Report actual DNS/browser path; this experiment does not disable them on the host |
| Warm cache and preexisting HTTP/2/QUIC connection | Test | Test | Test | Document retained access after new block; fresh DNS proof does not revoke old content |
| Search target unavailable | Test | Test | Test | Protected searches fail instead of silently using ordinary endpoint; unrelated tools still resolve |
| Prototype/relay killed | Test | Test | Test | Lab DNS may stop working; no system-wide crash/fail-open claim; restore via console |
| Process restart | Test | Test | Test | On-disk valid policy reloaded; no protection during stopped interval |
| Browser restart, VM reboot/logout/login | Test | Test | Test | Manual PoC does not auto-start; no persistence claim. Future signed system extension must pass separately |
| Sleep/wake, network switch, captive portal, IPv6-only/NAT64 | Test | Test | Test | Recovery and scoped DNS behavior measured; currently unverified |

Do not use an adult image appearing/not appearing as the sole test: SafeSearch is provider classification, not a guarantee of perfect content detection. Test unsupported search engines explicitly and record that they are currently outside the SafeSearch rules.

## Filter service install and rollback in the VM

`clearpath-service` replaces the socat relay above for the Swift filter. Run it only inside the disposable VM; on Victor's Mac it waits for the authorized trial. The VM tool is [Tart](https://github.com/cirruslabs/tart) with a Cirrus Labs macOS base image, installed from its GitHub release with the checksum verified (Victor, 2026-11-21). Victor approves `sudo` and DNS changes inside the VM per issue.

1. From a clean snapshot (`tart clone <image> <name>` before first boot), copy in `clearpath-filter`, `clearpath-service`, a synthetic policy and a loopback fixture upstream on `127.0.0.1:1053` that logs each name it is asked.
2. Record the before state: `networksetup -listallnetworkservices`, `networksetup -getdnsservers <service>` for each, `scutil --dns` and `clearpath-service status`.
3. `sudo clearpath-service install --filter … --policy … --upstream 127.0.0.1 --upstream-port 1053`. The fixture upstream keeps test lookups inside the VM. `recovery.json` must hold the before state.
4. Check through the system resolver (`dscacheutil -q host -a name <name>` after `sudo dscacheutil -flushcache`): blocked names fail and never appear in the fixture log, allowed names resolve, SafeSearch names return the safe alias.
5. Kill the filter (`sudo kill -9 <pid>` from `status`): launchd restarts it and it answers again. Open and quit the menu-bar app; the filter's pid is unchanged. Log out (`sudo launchctl bootout gui/<uid>`) and reboot: the filter runs as `nobody` before login and keeps blocking.
6. `sudo clearpath-service uninstall`: DNS matches the recorded state, no daemon, no Clearpath files, nothing on port 53.
7. Partial installs: an install whose filter never answers rolls itself back. An install killed partway (`pkill -9 -f "clearpath-service install"`) leaves the record, files and daemon; a new install refuses, and `uninstall` restores everything.

Rollback if the tool itself fails: `sudo networksetup -setdnsservers <service> <recorded servers>` (or `Empty` for automatic) for each service in `/Library/Application Support/Clearpath/recovery.json`, then `sudo launchctl bootout system/io.clearpath.filter`, then remove `/Library/LaunchDaemons/io.clearpath.filter.plist` and that folder. Or restore the VM snapshot.

## Automatic routing in the VM

Use an isolated guest network with a synthetic DHCP peer and DNS servers bound inside the guest. Supply a search domain and two different default resolver addresses, then install without `--upstream`. Victor approved guest networking and privileged tests for #10 in a disposable VM only.

- Query an allowed synthetic name through the system resolver, query the short form through the search suffix, and load a synthetic HTTP page. Query a blocked name through the system resolver and confirm that no upstream saw it.
- Renew DHCP with the second DNS address while Clearpath is running. Confirm new lookups go to that address and the daemon PID stays the same.
- Connect a split-DNS fixture with a dedicated server. Check a DNS-SD record and an allowed private name through the scope, including UDP and TCP and IPv4 and IPv6 where available. Confirm the default fixture sees no scoped requests, including when the private resolver is unavailable. Verify `.local` discovery through Bonjour using the system APIs.
- Verify the available network cycle, VM sleep and wake, captive portal, and reboot cases. Record the operating system, fixture or VPN, and each failed or unavailable row separately.
- Uninstall from the installation location. Compare the saved settings with the current settings before stopping any guest DNS fixtures, and confirm the daemon is unloaded.

## Developer regression plan in that VM

| Workflow | Concrete smoke test | Current evidence |
|---|---|---|
| Local HTTP and hot reload | Serve a tiny app on `localhost:8000`, `127.0.0.1`, `[::1]`; load in all browsers; edit file and verify HMR/WebSocket reconnect | Not run in browsers |
| Git HTTPS + SSH | Clone/fetch a small public repository; `git ls-remote`; SSH to a lab host; use existing host-key verification, no private credentials | GitHub HTTPS HEAD passed; real Git/SSH through filter unverified |
| npm / Python package access | `npm view` and download/install a tiny package in a temp project/venv; delete scratch afterwards | Registry/PyPI DNS and HTTPS HEAD passed; full package workflows unverified |
| Containers | Pull a tiny image and resolve from a container; test published localhost port and Docker DNS behavior | Registry AAAA resolution passed; Docker not exercised |
| Databases | Connect to loopback PostgreSQL and a Unix socket; connect to a private lab hostname | DNS forwarding fixture only; real database connections unverified |
| Private DNS and VPN | Resolve lab split-DNS name before/during/after VPN connection; test Tailscale/WireGuard/OpenVPN if supported | Synthetic split DNS passed in the VM. Vendor VPN clients remain unverified. |
| Toolchain/Apple services | Xcode download/build, Homebrew update/download in VM, code signing, local DNS-SD/mDNS, captive portal | Unverified |
| Administrator control | Run an ordinary admin operation, stop prototype, remove only test profile/provider, restore network, restart | Full admin authority retained by design; native uninstall unverified |

Avoid broad blocklists for developer/VPN services. Fix list false positives with explicit reviewed exceptions rather than exempting every developer process from domain policy.

## Native provider acceptance gate

After obtaining the normal Developer ID entitlement/profile, build and activate the DNS Proxy **only in the VM**. Repeat the matrix without the port-53 relay or system-DNS replacement. Confirm the selected app config, provider start/stop callbacks, IPv4/IPv6 UDP/TCP capture, explicit alternate resolver capture, source-app metadata, original/scoped resolver routing, no recursive loops, update atomicity, logout/reboot, recovery and uninstall. A successful compile of `check_networkextension.swift` proves none of these runtime properties.

If adding a content filter, separately measure hostname availability for all three browsers with ECH, QUIC, DoH and a VPN. Missing metadata must produce an explicit coverage state, not a claim that unknown connections were inspected. Measure coexistence with existing network extensions in a VM before asking to activate anything on the host.

## Rollback

**Current workspace experiment:** Ctrl-C in the prototype terminal (or SIGTERM to its exact PID). Tests close listeners and stop their child processes. There are no installed services or modified network settings to undo. Remove the workspace `.venv`, scratch policies and temporary audit checkout if no longer wanted; no privileged cleanup is needed. A SIGHUP-rejected file remains invalid on disk: restore your known-good policy copy before restarting. No persistent last-good backup is created automatically.

**VM DNS relay experiment:** while the relay/filter still runs, restore the exact saved DNS server list for every changed service. Use DHCP/`empty` only for a service known to have been using DHCP DNS originally. Confirm ordinary name resolution, including private names, before stopping both relays and the filter. Remove only the test browser profile/policies and restore saved browser files. Confirm policy dashboards are clear of the test settings, then restart browsers. Restore the VM snapshot if uncertain. Do not stop the sole DNS listener before restoring DNS.

**Future native provider:** first disable/remove only this product's saved DNS/filter manager configuration and deactivate its extension using supported APIs. Confirm original resolution and VPN/private routing. Then remove only its own app/extension and test policies; never delete unrelated network profiles, certificates or settings. If provider teardown fails, retain the app until removal succeeds or restore the VM snapshot. This procedure is a design requirement, not a verified implemented uninstaller.

No rollback procedure involves disabling SIP, changing Screen Time, removing another app's networking extension, resetting all network services or deleting all managed preferences.
