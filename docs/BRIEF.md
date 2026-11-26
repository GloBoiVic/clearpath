# Clearpath

A free, open-source macOS app that blocks adult and NSFW websites in every browser, with an accountability partner instead of spyware.

## Mission

Adult content is one search away on the open web. Clearpath puts friction between the user and that content, so that at a moment of weakness the site is blocked, and getting around the block can't happen without the user's accountability partner knowing.

**Core rule:** using the Mac with Clearpath feels identical to using it without, except adult and NSFW sites are blocked. Development work, VPNs, local networking and normal browsing must keep working. There is no pause.

**Privacy rule:** no browsing data, screenshots, history, blocked attempts or counts ever leave the Mac. Only status events and approval requests do.

## Problem and user

Someone who wants reliable, voluntary protection from adult content on their own Mac, with a person they trust holding them accountable, and without a company watching their screen. Today the user is Victor, on his own Mac.

## Replaces

Covenant Eyes and similar paid accountability services, which charge a subscription and send screenshots of the user's screen to their servers. Also Screen Time content limits, and the open-source project distraction-free, which `docs/UPSTREAM_AUDIT.md` audits and decides not to fork.

## V1

V1 runs on Victor's Mac only. He keeps his admin account. The diagram is `docs/architecture/clearpath-v1.excalidraw` (open it at excalidraw.com, File > Open).

**The promise.** Strong, not impossible to bypass. An admin can remove or work around Clearpath; when that happens, the partner is alerted. The partner covers the gap; Clearpath does not fight an anti-tamper arms race.

**What gets blocked**
- A community adult blocklist, updated automatically every week, plus sites the user adds.
- Mixed sites that expose NSFW content (Reddit, X, Tumblr) stay open by default and are one click away from the user's block list.
- SafeSearch is forced on Google, Bing and DuckDuckGo. YouTube is not forced. Other search engines stay open and are one click away from blocking.
- A blocked site shows the browser's normal "can't reach this site" error plus a quiet "Blocked by Clearpath" notification. Nothing about the attempt is stored or sent. There is no custom block page, because one would need a trusted certificate installed.

**The one-way lock**
- Adding a block is instant and needs no one. Removing any block (adult list, the user's own sites, mixed sites) needs partner approval. Updates from the blocklist source itself apply automatically; only removals the user starts need approval.
- Locks start as soon as Clearpath is set up. Until the partner accepts the invite, the user can correct the partner's email or swap the person freely.
- The partner opens the email link to review the site, then selects Approve or Deny on the confirmation page. No account, signup or password for the partner.
- A backup partner is strongly recommended at setup. Requests go to both partners at once; either can approve.
- The first valid confirmed response is final. Approval applies the request and denial stops it. If nobody answers in 7 days, the request goes through and both partners are told. A user with no partner waits the same 7 days.
- Changing a partner follows the same rule: the other partner or the one being replaced approves, or 7 days pass. The replaced partner is always told.

**Alerts to the partner** (email only in V1)
- Protection went down, or the user pressed "Restore internet" after the filter failed to restart.
- The Mac's DNS setting was changed away from Clearpath.
- The blocklist was edited outside the app.
- Clearpath was uninstalled without approval, or with approval (an informational note, not an alarm).
- The Mac hasn't checked in for 24 hours. The email says "hasn't checked in", notes the Mac may just be off, and suggests the partner check in with the user.

**Leaving**
- Uninstall with approval: request it, then a partner approves or 7 days pass.
- Uninstall right now: open **Leave Clearpath** from the shield menu, type **I understand my partner will be notified**, wait 60 seconds, and approve the macOS administrator prompt. This works offline. With a configured pairing service, Clearpath saves an uninstall-without-approval event for delivery in #22. An accepted partner who never receives the event still gets the missed-check-in alert after 24 hours.
- Both uninstall routes use the same cleanup. Clearpath verifies the previous DNS settings before stopping the filter. It removes its background services, support files, login item, browser profile and app. If macOS requires manual profile removal, Clearpath guides the user through Device Management and verifies removal on retry.

**Failure.** If the filter crashes, internet lookups stop until it restarts on its own, within seconds. If it stays down, the menu bar shows the problem and a "Restore internet" button; using it alerts the partner. A crash never silently leaves the user unprotected, and never leaves them stuck offline.

**Onboarding** explains what to expect and what the partner is for. A user can skip the partner; onboarding says plainly that without one they can undo Clearpath without anyone knowing. It asks the user to turn off iCloud Private Relay if it is on, since Safari's lookups would skip Clearpath.

**The app.** A menu-bar app with no Dock icon. The icon shows that protection is on and whether a partner is connected; its panel shows status, "Block a site" and pending requests. It opens windows for setup, the blocked-sites list, partner settings and uninstall. The filter keeps running when the menu-bar app is quit.

**V1 browsers:** Safari, Chrome and Firefox.

## Not in V1

- Distribution to other people, a public website or an installer for others.
- Apple's DNS proxy system extension; it needs the paid Apple Developer Program. It is the upgrade path later.
- Discord or text-message alerts.
- The community for finding a partner. Onboarding recommends asking a trusted friend.
- YouTube Restricted Mode, and blocking adult content inside mixed sites without blocking the whole site.
- Any pause or temporary off switch.

## Data

- **On the Mac:** the policy (adult list, the user's blocks, allow exceptions, SafeSearch mappings) as a JSON file. No query log, browsing history, analytics or account.
- **In the partner service:** partner emails, the pairing, check-ins, status events and approval requests, including the site name in a removal request so the partner knows what they are approving. Never browsing.
- The network's normal DNS server still sees allowed lookups, as it does without Clearpath.

## Done when

On Victor's Mac, for a full day of normal use: Safari, Chrome and Firefox get blocked sites blocked and SafeSearch forced, while development tools, VPNs and local networking work as before. A removal request reaches the partner by email and is applied only after approval or 7 days. Each alert trigger reaches the partner. Uninstall restores the Mac cleanly. All of this is proven in a disposable macOS VM before it touches Victor's Mac.

## What the code does today

1. **Filter DNS on a loopback test port.** `python -m clearpath.dns` (`clearpath/dns.py`) listens on `127.0.0.1:1053`, answers blocked domains with NXDOMAIN, answers configured search hosts with their forced-safe address, and forwards everything else to one upstream DNS server you name. Browsers don't use it automatically.
2. **Manage the block list.** `python -m clearpath.policy` (`clearpath/policy.py`) validates a policy file and imports a plain domain list into it, replacing the file atomically. The running filter reloads on `kill -HUP`, keeping the old policy if the new one is invalid.
3. **Install from the setup window (disposable VM only so far).** One macOS administrator prompt authorizes installing the ad-hoc signed app in Applications and setting up DNS. `clearpath-service install` validates the community adult list and bundles it with the default SafeSearch rules before changing DNS. The service records each network service's DNS, starts the filter LaunchDaemon on `127.0.0.1:53` and points system DNS at it. The filter drops to `nobody`. A failed install reports the rollback result. The app reopens from Applications and registers to open at login. Setup guides browser profile installation and can finish locally without a partner. The service refreshes its adult list weekly. `clearpath-service uninstall` restores recorded DNS and removes the jobs and service files. `clearpath-service status` reports the state as JSON.
4. **Record evidence.** 28 automated tests (`tests/test_filter.py`), an optional live probe against a public DNS server (`scripts/live_smoke.py`), the upstream audit (`scripts/audit_upstream.py`) and a Swift check that the macOS SDK has the DNS Proxy API (`scripts/check_networkextension.swift`). Results are in `docs/RESULTS.md`.

Commands:

- `python -m clearpath.dns --policy FILE --upstream IP [--upstream-port 53] [--port 1053] [--listen 127.0.0.1]`
- `python -m clearpath.policy FILE [--import-list domains.txt --category NAME]`
- `python scripts/live_smoke.py --upstream IP [--upstream-port 53]`

It reads the policy JSON and domain list text files and writes the policy JSON on import. Network: a loopback listener on an unprivileged port (it refuses port 53 and non-loopback addresses), plus outbound DNS to the one upstream given. Python 3.9+ with `requirements.txt` (dnslib 0.9.26). Python is the test harness, not the shipping runtime.

## Not done today

- The shield checks the live filter and system DNS. When the filter stays down, an administrator can restore the saved DNS settings. The service records a local restore event for partner delivery in #20. A blocked lookup posts a payload-free local notification event. The menu-bar app displays a generic alert if macOS notification permission is granted. The app must be running to show it, while the daemon continues filtering if the app quits. The menu bar can add and show blocks from the installed policy. On a solo install, a removal request applies after seven days on the Mac's clock. Once Partner settings reports a partner service, solo removals stop and open solo requests are cancelled. Partner setup with invitations works with the loopback pairing service and synthetic email sink. An accepted partner changes only through partner approval or seven days. A hosted partner service is pending. System DNS and profile changes are for disposable VM testing.
- The Swift filtering engine (policy, DNS handling, upstream transport) from the `native-dns-foundation` branch is in `native/`. It runs as `clearpath-filter`, a loopback DNS server, and as the `clearpath-service` LaunchDaemon. Automatic routing uses current network resolver state for forwarded lookups. The VPN and developer-network acceptance results are tracked in [RESULTS.md](RESULTS.md). The DNS proxy extension code stays on the foundation branch as the upgrade path.
- Browser setup observations are recorded in [RESULTS.md](RESULTS.md). The full V1 acceptance matrix remains tracked in [#25](https://github.com/GloBoiVic/clearpath/issues/25).
- The example blocklist has three real domains plus test fixtures.
- No Python linter, formatter or type checker.

## Money

Free and open source (MIT). No paid Apple Developer Program for now (Victor, 2026-11-21). The partner service and email sending run on free tiers; cost $0 at V1 scale. Creating those accounts is a Hard stop, asked when the work reaches it.

## Milestones

1. **M1 Baseline:** every recorded check passes on this Mac and runs on every PR. Done.
2. **V1:** the product above. Planned as GitHub issues by `victor-kit:vk-plan`; the look comes first from `victor-kit:vk-design`.

## Decisions

| Decision | Made by | Why |
|---|---|---|
| Onboard with the `python-tool` pack | agent | The code on `main` is Python; no pack fits a Swift + Python mix yet |
| Proof: unit tests and policy validation | agent | They are the repo's own checks and pass |
| The agent squash-merges once proof and review pass; PRs touching Hard stops, `AGENTS.md`, `.claude/`, `.githooks/` or the PR template wait for Victor | Victor, 2026-11-21 | |
| Extra Hard stops: changing this Mac's DNS or network settings; installing a configuration profile, system extension, certificate or browser policy; anything with `sudo`; sending queries to a public DNS server | Victor accepted the recommendation, 2026-11-21 | The repo's own docs already say host changes need his authorization |
| Repo stays public | Victor (existing setting) | It was already public before onboarding |
| V1 product as described under V1 above: Victor's Mac only, admin account kept, partner alerts instead of anti-tamper, one-way lock, no pause, no YouTube forcing, email only | Victor, 2026-11-21 | Friction at the moment of weakness, without spyware |
| No paid Apple Developer Program for now; V1 uses a local DNS service | Victor, 2026-11-21 | Get it built and running first |
| Menu-bar app for V1 | Victor, 2026-11-21 | Stays out of the way |
| First valid response is final | Victor, 2026-11-21 | Either partner can act immediately. A denial that arrives first stops the request. |
| Open the email link, then tap Approve or Deny | Victor, 2026-11-21 | Opening the link leaves the decision pending, including when a mail scanner opens it. |
| A replaced partner's open links stop working when the change applies; open requests then wait for the remaining partner or seven days | Victor accepted the recommendation, 2026-11-25 | A replaced person loses all say at once. The new partner gets only requests made after they accept. |
| Partner-change emails show both the current and the new partner's address | Victor accepted the recommendation, 2026-11-25 | Deciders know who is leaving and who is coming in. |
| An invitation created by an approved partner change is locked to the approved address. It can be resent to that address; a different address needs a new partner change. Invitations sent during setup stay freely correctable until accepted. | Victor accepted the recommendation, 2026-11-25 | Closes a loophole where the owner could re-point an approved invitation to an address they control |
| An accepted partner can be replaced, not removed without a replacement, for now ([#49](https://github.com/GloBoiVic/clearpath/issues/49)) | Victor accepted the recommendation, 2026-11-25 | Keeps the change to what #18 asked |
| Install Clearpath from the setup window | Victor, 2026-11-25 | The app moves to Applications, opens at login, and asks for the Mac password once. |
| Run the trial without a partner | Victor, 2026-11-25 | The trial setup can finish without a configured partner service. |
| Solo removals count seven days on the Mac's clock; documented as a known limit | Victor, 2026-11-26 | A solo install has no partner server to keep time. Moving the clock forward is no weaker than a solo admin uninstalling at once. |
| Ship Uninstall now for the trial | Victor, 2026-11-25 | “Build 'Uninstall now' as your way out. Everything gets removed: the app, the filter, and the browser settings. The partner-approved uninstall comes later.” |
| Allow clean uninstall and use the missed-check-in alert | Victor accepted the recommendation, 2026-11-21 | The service sends a specific uninstall email when it receives an event. The 24-hour alert covers a missed event. |

Approved by Victor on 2026-11-21.
