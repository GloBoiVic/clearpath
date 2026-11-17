# Observed results — 2026-11-17

> Initial Python experiment evidence, retained for comparison. For the subsequent native implementation, current test counts, signing gate and unverified acceptance criteria, see [native results](native/RESULTS.md).

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
