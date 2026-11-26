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

# Trial-build check in a disposable VM — 2026-11-26

Issue #53 ran the trial build before it goes on Victor's Mac (#54). Environment:

- **VM:** `clearpath-53-trial`, a Tart 2.41.1 clone of the pinned image above (macOS 26.6.2, 25G83, arm64), cloned before first boot, default Tart NAT and the read-only share.
- **Build:** `./build.sh --build-only` from `main` at 48a79b6.
- **Browsers:** Safari 26.6.2, Chrome 158.0.8127.89 and Firefox 161.0, downloaded from Google and Mozilla in the guest.
- **Community list:** 2026.1125.2346.19, downloaded by the install.

Every guest administrator prompt, `sudo`, DNS change, profile, public lookup and lifecycle step had Victor's approval in chat. Victor's Mac was not changed.

| Check | Result | Observed |
|---|---|---|
| Pre-install baseline | — | Ethernet on automatic DNS (resolver #1 `fe80::…%en0`, `192.168.64.1`). No Clearpath app, jobs, support folder or Managed Preferences. Open at Login empty. |
| Install from the setup window | Pass | One administrator prompt. The setup window then showed **Protection is on. The community blocklist is active.** and **Open at login: On**. The three jobs were loaded, the filter ran as `nobody` on `127.0.0.1:53`, and Ethernet DNS was `127.0.0.1`. |
| Solo setup | Pass | Partners → acknowledge → **Finish setup** showed "Setup complete without a partner". |
| Open at login | Pass | System Settings listed Clearpath under Open at Login. The app started on its own after both reboots. |
| Browser profile | Pass | Device Management installed `io.clearpath.browser-policy.v1`. `chrome://policy`: `DnsOverHttpsMode` off and `ForceGoogleSafeSearch` true, Platform, Machine, Mandatory, OK. `about:policies`: `DNSOverHTTPS` Enabled false, Locked true, no errors. Firefox `about:networking`: DoH mode Off. |
| Chrome, normal and Incognito | Pass | `pornhub.com`: `DNS_PROBE_FINISHED_NXDOMAIN`. Google: "Filtering on", can't change, URL rewritten to `safe=active`. Bing: "requires a strict Bing SafeSearch setting". DuckDuckGo: no SafeSearch control. `example.com`, `wikipedia.org` and `apple.com` loaded. |
| Firefox, normal and private | Pass | Same results. Firefox 161 words a DNS failure as "Could not connect to the server" (it says the same for the locally blocked `example.org`). Its DNS cache held `www.pornhub.com` with no address. |
| Safari, normal window | Pass | `pornhub.com`: "Safari Can't Find the Server". SafeSearch was forced on all three engines, and ordinary sites loaded. |
| **Safari, private window** | **Fail (fixed in #61, below)** | Clearpath had no effect: `pornhub.com` loaded its age-gate page, the locally blocked `example.org` loaded, Google SafeSearch showed off, Bing offered Moderate and DuckDuckGo showed "Safe search: off". With Safari's "Use advanced tracking and fingerprinting protection" (on in Private Browsing by default) turned off, a private window failed `example.org` like a normal window. |
| SafeSearch DNS | Pass, one gap | `www.google.com` and `google.com` → `forcesafesearch.google.com`. `www.bing.com` and `bing.com` → `strict.bing.com`. `duckduckgo.com` → `safe.duckduckgo.com`. **`www.duckduckgo.com` → SERVFAIL (#60)**: it is a CNAME of `duckduckgo.com` and the default policy doesn't map it, so the filter fails closed. |
| Add a block from the menu bar | Pass | **Block a site** → `example.org`. About a second later `example.org` and `www.example.org` went from NOERROR to NXDOMAIN. The block survived a power loss and a reboot. |
| **Removal request (solo seven-day rule)** | **Fail (#59)** | The panel showed **Pending requests: Unavailable**. **Request removal** created nothing, and `clearpath-service request-site-removal` said "Site removal requests need a configured pairing service." (exit 2). The block stayed. |
| Scoped resolver (VPN stand-in) | Pass | A supplemental `vpn.example` resolver pointed at a guest fixture on `[::1]:5354`. Names resolved through it via the system resolver and through the filter (A over UDP and TCP; the AAAA query reached the fixture and returned NOERROR with no record, as the fixture has none), and the fixture saw no other names. With the fixture stopped, the filter answered SERVFAIL. The scope was removed afterwards and `scutil --dns` matched the post-install state. |
| Local networking | Pass | A page on `localhost`, `127.0.0.1` and `[::1]:8000` loaded in all three browsers (Safari's captures were in a private window). `dns-sd` registered, browsed and resolved a `.local` service, and the page loaded by the `.local` host name. |
| Developer smoke | Pass | `git ls-remote` over HTTPS, `pip download six` and `npm view` / `npm pack is-number` worked through the filter. Docker, databases, SSH and hot reload weren't available or weren't run. |
| Network change | Pass | Ethernet off: lookups SERVFAIL. Ethernet on: answered again within about 2 s from the same filter PID, still blocking. |
| Filter killed | Pass | `kill -9`: a new filter (as `nobody`) answered within about 0.2 s, with blocking and SafeSearch intact. The panel stayed **Protection is on**. |
| Sleep and wake | Not verifiable | The guest refused `pmset sleepnow` with `Unable to sleep system: error 0xe00002e2`, as in #10. `tart suspend` worked, but the saved state couldn't be restored ("invalid argument") because the clone wasn't started with `--suspendable`. |
| Power loss | Pass | The unrestorable saved state was discarded, so the guest cold-booted. The filter started 6 s after boot and the app 22 s after, with DNS still `127.0.0.1` and blocking, the custom block and SafeSearch working. |
| Reboot | Pass | After `sudo reboot`: filter 6 s after boot, app 21 s after, same checks passed. |
| Restore internet | Pass | Replaced `policy.json` with invalid JSON and killed the filter. launchd kept retrying (exit 1) and the panel showed **Protection is offline** with **Restore internet**. One administrator prompt then restored DNS. The panel showed **Previous DNS settings restored / DNS filtering is off**, and both the network-service DNS and `scutil --dns` matched the pre-install baseline exactly. A repeated restore kept the same event ID. |
| Uninstall now | Pass | **Leave Clearpath** → typed sentence → 60 s countdown → **Uninstall now** → one administrator prompt. The window showed "Clearpath was uninstalled. Your previous DNS settings were restored." DNS matched the baseline. No app, jobs, launchd entry, support folder, uninstall event, Clearpath profile or login item remained. Chrome showed "No policies set" and Firefox "Enterprise Policies service is inactive" after a restart. After another reboot it was the same, and Clearpath didn't start. The only difference from the baseline is an empty, root-owned `/Library/Managed Preferences` folder, which macOS created when the profile was installed. |
| Wording | Minor (#62) | In solo mode, the uninstall sentence ("I understand my partner will be notified") and the Restore internet note ("records a restore event for partner alerts") mention a partner who doesn't exist. |

Not shown here: vendor VPN clients, Wi-Fi, real Mac sleep, iCloud Private Relay (no Apple Account), signed-in search accounts, and an uninstall from a healthy filter (this run uninstalled after Restore internet; #23 covered the healthy case).

## Recovery on Victor's Mac

Before installing, save the current DNS state with read-only commands:

```sh
networksetup -listallnetworkservices | tail -n +2 | while IFS= read -r s; do
  s=${s#\*}; echo "== $s"; networksetup -getdnsservers "$s"
done > ~/Desktop/clearpath-dns-before.txt
scutil --dns >> ~/Desktop/clearpath-dns-before.txt
```

If something goes wrong, use the first step that works:

1. **Protection is offline and the internet is down:** shield → **Restore internet**, then approve the administrator prompt. DNS goes back to the saved settings, and Clearpath stays installed but stops filtering. (Proven above.)
2. **To remove Clearpath:** shield → **Leave Clearpath**. Type the sentence, wait 60 seconds, choose **Uninstall now** and approve the prompt. If it asks, remove **Clearpath Browser Policies** in System Settings → General → Device Management, then choose **Check profile and continue**. Restart Chrome and Firefox. (Proven above and in #23.)
3. **If the app itself won't help**, use the installed service tool in Terminal:

   ```sh
   sudo "/Library/Application Support/Clearpath/clearpath-service" restore     # DNS back only, while the filter is down; Clearpath stays installed
   sudo "/Library/Application Support/Clearpath/clearpath-service" uninstall   # DNS back, then the filter and its jobs removed
   ```

   `uninstall` restores DNS from `recovery.json` and waits until macOS stops using `127.0.0.1`. Only then does it stop the three jobs and remove Clearpath's own files. After it, drag `/Applications/Clearpath.app` to the Trash. Then remove **Clearpath Browser Policies** in Device Management and Clearpath from Login Items, and restart Chrome and Firefox. They use the same tool and DNS-restore path as the app. #9 proved `clearpath-service uninstall` in a VM ([Filter service in a disposable VM](#filter-service-in-a-disposable-vm--2026-11-21)); this run didn't call them by hand.

   Last resort, only if that tool is missing or refuses: for each service that shows `127.0.0.1` in `networksetup -getdnsservers "<service>"`, set it back to what `~/Desktop/clearpath-dns-before.txt` recorded for it. Use `sudo networksetup -setdnsservers "Wi-Fi" Empty` if that service was automatic, or `sudo networksetup -setdnsservers "Wi-Fi" <saved servers>` if it had its own. Then ask for help before deleting anything.
4. **Check:** compare `scutil --dns` with `~/Desktop/clearpath-dns-before.txt`, and confirm that ordinary sites load.

Each of these steps on Victor's Mac is a Hard stop: he runs it himself after saying yes in chat.

# Safari private windows in a disposable VM — 2026-11-26

Issue #61 looked for a way to stop Safari private windows bypassing Clearpath (#53). VM: `clearpath-61-safari`, a Tart 2.41.1 clone of the pinned image (macOS 26.6.2, 25G83, Safari 26.6.2), no Apple Account. Clearpath was built from `main` at 255cec2 and installed from the setup window, with `example.org` blocked from the menu bar. Every VM step had Victor's approval. Victor's Mac was not changed. Only the #53 domains were visited, and no adult domain.

**What a profile can do without an MDM server:**

| Option | Result |
|---|---|
| Turn off Safari Private Browsing | **Not possible.** Apple's `AllowPrivateBrowsing` (declaration `com.apple.configuration.safari.settings`, macOS 26) is MDM-only with supervision; Apple lists local enrollment as N/A. The older restriction `allowSafariPrivateBrowsing=false` in a `com.apple.applicationaccess` payload shows as "Allow Private Browsing in Safari: False", but the install fails: "One or more keys in the payload must be installed from a Mobile Device Management server." |
| Turn off "Use advanced tracking and fingerprinting protection" | **Possible.** Apple doesn't document it. Safari reads `EnableEnhancedPrivacyInPrivateBrowsing` and `EnableEnhancedPrivacyInRegularBrowsing` from `com.apple.Safari`, and a forced managed-preferences payload installs through Device Management. |

Victor chose to lock only the private key (#61). With only `EnableEnhancedPrivacyInPrivateBrowsing` forced to false:

| Check | Result | Observed |
|---|---|---|
| Baseline, no profile | Fail, as #53 | A private window loaded the blocked `example.org`. |
| Private window | Pass | `example.org`: "Safari Can't Find the Server". Google: "Filtering on", can't change. Bing: "requires a strict Bing SafeSearch setting". DuckDuckGo: no "Safe search: off" control. `example.com` loaded. |
| Safari settings | Locked | Settings → Advanced shows "Use advanced tracking and fingerprinting protection" unchecked and dimmed. Neither the checkbox nor the menu responds, so the user can't choose "in all browsing". Settings → Privacy: Prevent cross-site tracking and Hide IP address from trackers stay on and can be changed. |
| Normal window with the user's own regular key on | Pass | The regular key was set to true as the guest user (`defaults write`), and Settings then read "in all browsing", still dimmed. `example.org` and a never-visited `www.example.org` failed, and SafeSearch was forced on all three engines. |
| Control: same user setting, no profile | **Fail** | A normal window loaded `example.org`. On a Mac without the profile, protection set to "in all browsing" bypasses Clearpath in normal windows too. |
| Final build (8ac02db) | Pass | Device Management showed the new description and installed `io.clearpath.browser-policy.v1` with three payloads. `/Library/Managed Preferences/admin/com.apple.Safari.plist` held only `EnableEnhancedPrivacyInPrivateBrowsing` false. Private and normal windows passed the checks above. The profile was then removed. |

One normal-window load of `http://example.org/` succeeded with the final build because Safari served it from its HTTP cache: that page had been loaded in a normal window during the control run. The same URL with a query string, and `www.example.org`, failed, and the system resolver answered NXDOMAIN. Cached pages outliving a new block is the known DNS limit in [ARCHITECTURE.md](ARCHITECTURE.md#privacy-lists-and-operational-limits). Private windows keep no disk cache.

**What Safari private browsing covers now:** with Clearpath Browser Policies installed, private windows use the system DNS path, so blocked sites fail and SafeSearch is forced as in normal windows. The cost: Safari treats its advanced tracking and fingerprinting protection as off in every window, and the user can't turn it on while the profile is installed. **Not covered:** Private Browsing can't be turned off, and a Mac without the profile is still bypassed in private windows. **Not tested:** iCloud Private Relay (no Apple Account in the VM), other Safari versions, and the new setup-window copy (the guest ran the app from `main`; the copy was type-checked but not viewed).

