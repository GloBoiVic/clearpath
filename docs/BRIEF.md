# Clearpath

A proof of concept for a local-first macOS filter that blocks adult domains and forces search-engine SafeSearch at the DNS level.

## Problem and user

(guess) Someone who wants reliable, voluntary protection from adult content on their own Mac, without a cloud service seeing or logging their browsing. Today the user is Victor, testing whether the approach can work.

## Replaces

(guess) Screen Time content limits and the open-source project distraction-free, which `docs/UPSTREAM_AUDIT.md` audits and decides not to fork.

## Main jobs

What the code does today:

1. **Filter DNS on a loopback test port.** `python -m clearpath.dns` (`clearpath/dns.py`) listens on `127.0.0.1:1053`, answers blocked domains with NXDOMAIN, answers configured search hosts (Google, Bing, DuckDuckGo) with their forced-safe address, and forwards everything else to one upstream DNS server you name. Browsers don't use it automatically.
2. **Manage the block list.** `python -m clearpath.policy` (`clearpath/policy.py`) validates a policy file and imports a plain domain list into it, replacing the file atomically. The running filter reloads on `kill -HUP`, keeping the old policy if the new one is invalid.
3. **Record evidence.** 28 automated tests (`tests/test_filter.py`), an optional live probe against a public DNS server (`scripts/live_smoke.py`), the upstream audit (`scripts/audit_upstream.py`) and a Swift check that the macOS SDK has the DNS Proxy API (`scripts/check_networkextension.swift`). Results are in `docs/RESULTS.md`.

## Data

- Policy: adult domains, custom blocks, allow exceptions, SafeSearch host mappings. A JSON file (`policy.example.json`; your working copy `policy.local.json` is git-ignored). Lives on the Mac.
- No query log, browsing history, analytics or account. The chosen upstream DNS server still sees allowed lookups.

## Platform

Commands it offers:

- `python -m clearpath.dns --policy FILE --upstream IP [--upstream-port 53] [--port 1053] [--listen 127.0.0.1]`
- `python -m clearpath.policy FILE [--import-list domains.txt --category NAME]`
- `python scripts/live_smoke.py --upstream IP`

What it reads and writes: reads the policy JSON and domain list text files; writes the policy JSON on import. Network: a loopback listener on an unprivileged port (it refuses port 53 and non-loopback addresses), plus outbound DNS to the one upstream given.

Python 3.9+ with pip and `requirements.txt` (dnslib 0.9.26). Python is the experiment harness, not the planned shipping runtime; `docs/ARCHITECTURE.md` recommends a native Swift DNS Proxy system extension next.

## Reference

None.

## Not done today

- No app, UI, installer or background service. Nothing changes the Mac's DNS settings, profiles, certificates or Screen Time.
- No native macOS DNS Proxy on `main`. That work is on the unmerged branch `native-dns-foundation`.
- Cross-browser protection (Safari, Chrome, Firefox) is not validated; the VM procedure in `docs/TESTING.md` has not been run.
- No complete adult block list; the example has three real domains plus test fixtures.
- No CI, linter, formatter or type checker.
- No DNS cache, encrypted upstream, DNSSEC validation or failover. Encrypted DNS, VPNs, proxies and an administrator can bypass it.

## Done when

(guess) A user turns protection on for their own Mac, and Safari, Chrome and Firefox all get blocked domains and SafeSearch for a whole day without breaking normal browsing, VPNs or local networking, then turns it off cleanly.

## Money

(guess) Free and open source (MIT). Running cost zero today. Shipping the native extension needs Apple Developer ID signing, which needs a paid Apple Developer Program membership.

## Milestones

1. **M1 Baseline:** close the onboarding gaps, so every recorded check passes on this Mac and runs on every PR (the Swift SDK check, CI).
2. Later milestones are Victor's to add. The native DNS Proxy work on `native-dns-foundation` is in flight.

## Decisions at kickoff

| Decision | Made by | Why |
|---|---|---|
| Onboard with the `python-tool` pack | agent | The code on `main` is Python; no pack fits a Swift + Python mix yet |
| Proof: unit tests and policy validation | agent | They are the repo's own checks and pass; the Swift check crashes on this Mac and becomes a gap |
| The agent squash-merges once proof and review pass; PRs touching Hard stops, `AGENTS.md`, `.claude/`, `.githooks/` or the PR template wait for Victor | Victor, 2026-11-21 | |
| Extra Hard stops: changing this Mac's DNS or network settings; installing a configuration profile, system extension, certificate or browser policy; anything with `sudo`; sending queries to a public DNS server | Victor accepted the recommendation, 2026-11-21 | The repo's own docs already say host changes need his authorization |
| Repo stays public | already public | |

Approved by Victor on 2026-11-21.
