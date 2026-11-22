# Observed results — 2026-11-17

## Conclusion

**The policy/DNS mechanism works in isolation. System-wide cross-browser reliability remains unverified.** The recommended next foundation experiment is a signed native DNS Proxy plus browser policy in a disposable VM. There is insufficient evidence to ship a product claiming complete protection or developer-workflow compatibility.

The system DNS, Screen Time, browser policies, privileged services and installed certificates on the host were not changed. All prototype servers used unprivileged loopback sockets and were stopped after their checks. No adult website was contacted over HTTP/TLS. A real adult domain was used only to verify its query was answered locally.

## Environment and execution

Observed host: macOS 27.2.1, build 26B131, arm64; Python 3.9.6 in a workspace virtual environment; dnslib 0.9.26; Swift 6.4.2. These version strings were read from the environment, not inferred from the public macOS release schedule. The host's execution environment can differ from a normal released customer installation.

The initial sandbox denied loopback binding (`Operation not permitted`) and external DNS for source download. The same authorized source-download/isolated-test commands were then run with the execution sandbox restriction lifted, as the current unprivileged user. No `sudo`, network reconfiguration, installer or service registration was run. This is an execution-permission distinction, not a privileged app deployment.

## Automated tests

Command: `.venv/bin/python -m unittest discover -s tests -v`

**28 tests passed; 0 failed, 0 skipped.** The exact final output is stored in [automated-tests.txt](automated-tests.txt). Tests use actual UDP/TCP loopback packets, IPv4 and IPv6 sockets, local fake upstreams and child processes; they do not contact public DNS.

| Behavior | Observation | Evidence boundary |
|---|---|---|
| Adult/custom apex + subdomains | NXDOMAIN for A/AAAA/HTTPS/SVCB/TXT over UDP and TCP; zero fixture upstream calls for blocked names | Tiny sample list; not real-world adult categorization |
| SafeSearch mappings | Configured Google/Bing/DuckDuckGo names produce safe CNAME + matching A/AAAA; normal search hostname never queried upstream | DNS behavior, not browser UI lock |
| Missing safe IPv6 / failed safe target | No unsafe IPv6 address; SERVFAIL on timeout/provider failure | No ordinary search fallback |
| SVCB/HTTPS address hints | Empty local answer for configured safe hosts | Cached/preexisting hints not revoked |
| Custom policy maintenance | Valid import replaces policy atomically; invalid/empty/corrupt input leaves previous file intact | Single writer, no remote update supply chain |
| Invalid reload and restart | Invalid SIGHUP reload keeps in-memory generation; valid file survives process restart | OS reboot/login/autostart not tested or implemented |
| Ordinary development domains | Fixture A/AAAA/TXT forwarded for GitHub, npm, PyPI, Docker, localhost, internal names and DNS-SD syntax | Does not prove real split-DNS/mDNS integration |
| Large answers / upstream truncation | UDP TC causes TCP recovery; large client reply works over TCP | One TCP message per connection |
| Mismatched transaction | Wrong upstream transaction ID rejected | Not a full DNS spoofing/security audit |
| Alternate DNS | Direct query to fixture upstream resolves a name blocked by filter | Confirmed bypass, not a passing protection claim |
| Query privacy | No query-domain output in captured normal resolver stdout/stderr | No packet privacy claim for upstream DNS |

## Live network probes

Command: `.venv/bin/python scripts/live_smoke.py --upstream 1.1.1.1`

**14 probes passed** (10 DNS, 4 HTTPS HEAD). The saved output is [live-smoke.json](live-smoke.json); DNS checks verify the expected response code, address type and configured safe CNAME. Selection of Cloudflare was explicit for this run, not a default system resolver change or an endorsement. IP answers below are observations and are not pinned in the implementation.

| Probe | Observed result |
|---|---|
| `adult.example` A/UDP, `pornhub.com` AAAA/TCP | Local NXDOMAIN, no address |
| `www.google.com` A | CNAME `forcesafesearch.google.com`, A `216.239.38.120` |
| `www.google.com` AAAA | CNAME to safe endpoint, AAAA `2001:4860:4802:32::78` |
| `www.bing.com` A | CNAME `strict.bing.com`, Microsoft CNAME chain, A `150.171.27.16` / `150.171.28.16` |
| `duckduckgo.com` A | CNAME `safe.duckduckgo.com`, A `40.89.244.237` |
| `github.com`, `registry.npmjs.org` A/UDP, `pypi.org` A/TCP | Normal public address answers |
| `registry-1.docker.io` AAAA | Normal IPv6 address answers |
| Google `/safesearch`, GitHub `/`, npm registry `/`, PyPI `/simple/` HTTPS HEAD | Each HTTP 200, curl certificate verification result 0 |

The HTTPS probes used the filter-returned address through process-local `curl --resolve`, without changing system DNS. TLS SNI and certificate checks used the original hostname. This demonstrates valid HTTPS connectivity through the selected safe Google IP. It does **not** prove locked SafeSearch UI, classified search-result accuracy, actual npm/pip installs, Git SSH, container pulls, or browser-managed DNS behavior. Public IPv6 DNS answers are not proof of end-to-end IPv6 HTTPS reachability.

## Upstream source reproductions

Command: `.venv/bin/python scripts/audit_upstream.py /private/tmp/clearpath-distraction-free-audit`

Pinned commit: `7bf0c4718941a716f8be68a79736a9c4f8543a3a`.

```json
{
  "AAAA_query_answer_type": "A",
  "rewrite_preserves_unearned_AD_bit": true,
  "safe_reply_has_uncounted_trailing_bytes": true,
  "blocked_reply_has_uncounted_trailing_bytes": true,
  "trie_subdomain_and_near_miss": "true false"
}
```

All reproduction assertions passed. These are bugs reproduced in two helper functions, not a running-system audit or an exploit. Other findings in [UPSTREAM_AUDIT.md](UPSTREAM_AUDIT.md) are explicitly based on source inspection.

## Apple API check

`swiftc -typecheck -module-cache-path /private/tmp/clearpath-swift-cache scripts/check_networkextension.swift` succeeds. This establishes local SDK availability for DNS/data-provider subclassing and optional hostname access. No extension was signed, installed, activated or loaded. Apple's documentation supplies the deployment and capability assessment in [ARCHITECTURE.md](ARCHITECTURE.md); runtime coverage remains to be tested.

## Outstanding validation

Safari, Chrome, Firefox, private sessions, locked SafeSearch controls, browser-managed policies, DoH/DoT/DoQ, Private Relay, VPN coexistence, actual alternate-DNS capture by a native extension, ECH/QUIC metadata, warm connections, real reboot/logout/sleep/wake, network changes, NAT64, scoped/private DNS and native rollback are **unverified**. Full developer tool workflows, production blocklist accuracy/freshness/licensing integration, failure-mode guarantees and long-running load/security testing also remain unverified. Detailed expected outcomes and safe VM rollback are in [TESTING.md](TESTING.md).

# Filter service in a disposable VM — 2026-11-21

`clearpath-service` install and rollback (#9), run in a disposable Tart VM: macOS 26.6.2 (25G83), arm64, image `ghcr.io/cirruslabs/macos-tahoe-base@sha256:65c3133a633fda8753cf1f71f2d55727792d534a2125b0032466563dcc8e58fd`, cloned to a clean snapshot before first boot. One network service, Ethernet, on automatic (DHCP) DNS. Synthetic policy (`adult.example`, `blocked.example`, `www.google.com` → `forcesafesearch.google.com`) and a loopback fixture upstream on `127.0.0.1:1053`. Victor's Mac was not changed.

| Check | Observed |
|---|---|
| Install | Recovery record written first (Ethernet: automatic; full `scutil --dns`). Daemon answering on `127.0.0.1:53`, then Ethernet DNS set to `127.0.0.1`. Filter process runs as `nobody`. |
| System blocking | `dscacheutil` and Python `getaddrinfo`: `blocked.example`, `sub.blocked.example`, `adult.example`, `www.adult.example` fail; none reached the fixture upstream. `allowed.example` → `192.0.2.42`; `www.google.com` → alias of `forcesafesearch.google.com`. The VM's own background lookups also went through the filter. |
| Restart on exit | `kill -9` of the filter: a new process, still `nobody`, answered after 0.2–0.3 s in three timed kills. A filter that dies within 2 s of starting waits out launchd's 2 s `ThrottleInterval` first. |
| Menu-bar app quit | App opened and quit; filter pid unchanged, still blocking. |
| Logout | `launchctl bootout gui/501`: filter pid unchanged through the logout and the auto-login that followed. |
| Reboot | Filter started at boot as `nobody`, blocked names failed, allowed names resolved once the fixture was restarted. |
| Uninstall | Ethernet back to automatic, `scutil --dns` resolver #1 identical to the record, daemon unloaded, plist and folder gone, nothing on port 53. A second uninstall succeeded with nothing to do. |
| Install that never answers | Filter replaced by `/usr/bin/true`: install waited 10 s, rolled back and exited 1, leaving DNS automatic and no files or daemon. |
| Install killed partway | Left record, files and a loaded daemon with DNS unchanged. A new install refused; `uninstall` removed everything. |
| Port 53 taken | Install refused (exit 2) and changed nothing. |

Not shown here: an install interrupted after some services had moved to the filter (covered by `ServiceTests` with a simulated Mac), more than one network service, VPNs and network changes (#10), and browsers (#11, #25).

## Automatic DNS routing in a disposable VM

Issue #10 used a disposable Tart clone of the macOS 26.6.2 (25G83) arm64 image above. The virtual Ethernet peer supplied synthetic DHCP and discarded other frames. The guest used the search domain `lab.example` and two DNS fixtures bound to guest loopback aliases. A separate IPv6 loopback server backed a supplemental System Configuration scope for `vpn.example`.

| Check | Observed |
|---|---|
| Ordinary lookup and browser | The installed daemon returned the first DHCP resolver's answer. `dscacheutil` expanded `public` to `public.lab.example`. Safari requested the synthetic page and received HTTP 200. |
| Blocking and SafeSearch | Public and scoped blocked fixtures returned NXDOMAIN and did not reach either upstream. The SafeSearch response used the forced target, which the default fixture resolved. |
| Split DNS and IPv6 | Queries for `host.vpn.example` used the distinct IPv6 scope over UDP and TCP. The default fixture did not receive those names. A scope aimed back at the listener returned SERVFAIL. |
| Developer discovery | A scoped unicast DNS-SD PTR query reached the private fixture. `dns-sd` registered and discovered the lab service on `.local` through Bonjour. |
| Network change and outage | Disabling Ethernet temporarily returned SERVFAIL for an allowed lookup. On re-enabling Ethernet, DHCP supplied the second resolver and the same daemon answered from it. |
| Captive portal redirect | The synthetic portal name resolved and its HTTP redirect reached the sign-in page. macOS Captive Network Assistant remains unverified. |
| Suspend and resume | The same daemon PID returned an allowed answer and kept the blocked fixture unresolved after Tart resumed the guest. The guest rejected native `pmset sleepnow` with `0xe00002e2`. |
| Reboot | Launchd started a new daemon. The blocked fixture returned NXDOMAIN before the lab DNS servers started. Allowed DNS resumed when the guest fixtures came back. |
| Rollback | Uninstall restored automatic DNS and the exact recorded `scutil --dns` output. A second installation with two explicit DNS servers used the saved first server, then restored the server order and search domains exactly. The daemon stopped and the service reported uninstalled. |

A loopback regression changed the active route after a truncated private UDP reply and verified that the TCP retry stayed on the private resolver. The final guest build also sent an explicitly scoped `corp.local` lookup to the IPv6 fixture and kept an ordinary Bonjour name out of unicast DNS.

The split-DNS fixture exercises macOS resolver state. Vendor VPN compatibility, physical Ethernet-to-Wi-Fi handoff, IPv6 as the VM's default resolver, and traffic sent around the loopback filter remain acceptance items.

# Browser setup in a disposable VM — 2026-11-22

Issue #11 used `clearpath-browser-clean-11`, a disposable Tart clone of the pinned macOS 26.6.2 (25G83) arm64 image above, with Safari 26.6.2, Chrome 158.0.8127.37 and Firefox 160.0.1. The guest ran the installed `clearpath-service` LaunchDaemon with a synthetic policy (SHA256 `7bab6cde…6c9be`): `adult.example` and `blocked.example` blocked with subdomains, `www.google.com` → `forcesafesearch.google.com`, `www.bing.com` → `strict.bing.com`, and `duckduckgo.com` and `www.duckduckgo.com` → `safe.duckduckgo.com`. The filter's upstream was a guest loopback fixture on `127.0.0.1:1053`. It answered `allowed.example` with a loopback HTTP origin, sent only search-provider and browser-download zones to Cloudflare DNS-over-HTTPS, and answered nothing else. The guest's app build targeted macOS 15 (#33). Victor's Mac was not changed.

| Check | Observed |
|---|---|
| Setup window | **Check DNS status** reported the installed filter as answering and system DNS pointing to it. **Show browser profile in Finder** revealed the bundled profile. |
| Profile | `io.clearpath.browser-policy.v1` (SHA256 `59f85531…d839aac`), approved in Device Management, installed one Chrome and one Firefox managed-preferences payload. macOS wrote both `com.google.Chrome` and `org.mozilla.firefox` to `/Library/Managed Preferences`. |
| Chrome policy | `chrome://policy`: `DnsOverHttpsMode` = `off` and `ForceGoogleSafeSearch` = `true`, both Platform, Machine, Mandatory, status OK. |
| Firefox policy | `about:policies#active`: `DNSOverHTTPS` with `Enabled` false and `Locked` true, and no Errors section. |
| Blocking, all three browsers, normal and private windows | `adult.example`, `sub.adult.example`, `blocked.example` and `sub.blocked.example` failed to resolve (Chrome `DNS_PROBE_FINISHED_NXDOMAIN`, Firefox "Server Not Found", Safari "Can't Find the Server"). `allowed.example` loaded. The origin logged requests only for `allowed.example`. |
| Google | `google.com/safesearch?safe=off`: every browser and mode showed "You can't change your SafeSearch setting right now because someone else… controls settings". Chrome also rewrote the URL to `safe=active`. |
| Bing | `bing.com/account/general?adlt=off`: every browser and mode showed "Your country or region requires a strict Bing SafeSearch setting". |
| DuckDuckGo | `duckduckgo.com/?q=cloud+formations&kp=-2` returned results with no SafeSearch control in the filter bar, in every browser and mode. |
| Profile removal | Removing only **Clearpath Browser Policies** in Device Management left no system profiles and an empty `/Library/Managed Preferences`. After restarting, Chrome showed "No policies set" and Firefox showed "The Enterprise Policies service is inactive." |
| Filter rollback | `clearpath-service uninstall` restored Ethernet to automatic DNS. `scutil --dns` matched the pre-install capture exactly. The daemon, plist and support folder were gone. Unprivileged `clearpath-service status` and the setup window both reported the filter as not installed. |

An earlier profile put both browsers' settings in one payload and nested Firefox's `DNSOverHTTPS` dictionary. macOS stored that payload but wrote only Chrome's managed preferences, so `about:policies` showed Enterprise Policies inactive. The profile now uses separate payloads and Firefox's flattened keys (`DNSOverHTTPS__Enabled`, `DNSOverHTTPS__Locked`). Firefox 160's macOS parser expands these keys. The VM did not test which of the two changes alone would have been enough.

Not shown here: whether Chrome or Firefox would have used their own encrypted DNS in this VM without the profile, Google SafeSearch from the Chrome policy alone (the DNS mapping was active at the same time), signed-in search accounts, iCloud Private Relay (the VM had no Apple Account), and the remaining V1 acceptance matrix in #25.

# VM driving helpers in a disposable VM — 2026-11-22

Issue #38 ran the `scripts/vm` helpers in `clearpath-38-smoke`, a disposable Tart clone of the pinned image above (macOS 26.6.2, 25G83, arm64) started with the read-only share. The run did not touch DNS, profiles or `sudo`, and Victor's Mac was not changed. Victor approved the run in chat and then clicked **Allow** on the guest dialog described below. The clone was stopped and deleted.

| Check | Observed |
|---|---|
| Clone, start, guest agent | `tart clone <digest>` and `tart run --no-audio --no-clipboard --dir=clearpath-proof:<lab>:ro` worked. `tart exec` answered on the first try and `sw_vers` reported 26.6.2 (25G83). The share held the five helpers and the documented `cp` copied them to `/tmp`. |
| `vm-windowid`, `screencapture -l`, `base64` | Returned `40 150 57 723 625` for System Settings. The window capture came back as a 1446×1250 PNG (2× scale). |
| `vm-ocr` | Found "About" at window point (301, 248), matching the screenshot. |
| `vm-click` | After the dialog was dismissed, a click on the Bluetooth row (window origin plus the OCR point) opened the Bluetooth page. |
| `vm-typepw` | `printf '%s' dnstest \| tart exec -i <vm> /tmp/vm-typepw` typed into System Settings' search box (a normal text field). So `tart exec -i` works. |
| `vm-key` | `cmd+a` then `delete` cleared the search box. |
| Stop and delete | `tart stop` and `tart delete` removed the clone. `tart list` showed only the cached images. |

**Surprise.** The first `screencapture` through the guest agent raised *"tart-guest-agent" is requesting to bypass the system private window picker and directly access your screen and audio*. While it was up, `vm-click`, `vm-key` and `vm-typepw` exited 0 but changed nothing, `lsappinfo` named `UserNotificationCenter` as the front app, and Escape did not dismiss it. After **Allow**, the same helpers worked. `docs/TESTING.md` now says this.

Not run: `vm-click --double`, and `vm-typepw` into a password field (it needs an administrator prompt).
