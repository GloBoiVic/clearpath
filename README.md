# Clearpath foundation experiment

Clearpath is a free, open-source macOS app that blocks adult and NSFW websites in every browser, with an accountability partner instead of spyware. See the [product brief](docs/BRIEF.md) and [architecture](docs/ARCHITECTURE.md). Do not fork distraction-free's resolver or installer. DNS filtering works when requests reach it. Arbitrary encrypted DNS, proxies, VPNs and administrator access can bypass it. Browser setup observations and the remaining V1 acceptance cases are in [docs/RESULTS.md](docs/RESULTS.md).

This repository contains a Swift DNS filter and service, an isolated Python DNS harness, and the menu-bar app. Run `./build.sh` on macOS 15 or later with the Swift toolchain. The shield shows live DNS protection status and offers **Restore internet** if the installed filter stays down. Use **Block a site** to enter a domain or choose a shortcut, and **Blocked sites** to see the installed rules. **Set up protection** installs the filter and guides browser setup. **Partner settings** can connect to a local pairing service. When the app is running and macOS allows notifications, a blocked lookup shows a quiet generic **Blocked by Clearpath** alert. The filter sends no domain or attempt data, and continues filtering if the app quits; events while the app is not running are not shown later.

## Install Clearpath from setup (disposable VM only)

Open the ad-hoc signed `Clearpath.app` from the build and click **Install Clearpath**. Authorize the install in the macOS administrator prompt. Clearpath installs in Applications, downloads and validates the HaGeZi adult blocklist, and turns on DNS filtering with the bundled Google, Bing, and DuckDuckGo SafeSearch rules. Canceling the prompt leaves the Mac unchanged. If the installer changes DNS and then fails, it restores the saved settings and reports the result.

Clearpath reopens from Applications and registers to open at login. Setup shows the login item status and offers a link to Login Items if macOS requires approval. Once protection is on, continue with the browser instructions and **Finish setup**. For the solo trial, acknowledge the solo warning to finish. Reopening an installed copy preserves its DNS settings, rules, and login item.

To remove the installed app, open the shield menu and choose **Leave Clearpath**. Type **I understand my partner will be notified**, wait 60 seconds and approve the macOS administrator prompt. Clearpath restores the recorded DNS before stopping the filter and removes its browser profile, login item, service files and app. If macOS requires manual profile removal, follow the instructions in the window and choose **Check profile and continue**. You can run uninstall offline.

## Try partner invitations locally

Run these commands from the repo on macOS. The pairing service uses Python 3.9+ and the standard library.

```sh
partner_demo_dir=$(mktemp -d)
python3 -m clearpath.partners --state-dir "$partner_demo_dir" &
partner_demo_pid=$!
./build.sh --build-only
CLEARPATH_PARTNER_STATE="$partner_demo_dir" artifacts/Clearpath.app/Contents/MacOS/Clearpath
```

Open the shield menu and choose **Partner settings**. Invite synthetic addresses ending in `@example.test`. The service delivers messages as private `.eml` files under `$partner_demo_dir/mail`. View the message as text and paste the complete invitation link into a browser. Choose **Accept invitation**, then choose **Refresh** in Partner settings. Opening the link alone leaves the invitation pending. You can replace an unaccepted invite, which immediately invalidates the previous link. Invitations expire after seven days.

**Set up protection** has the same partner rows and **Finish setup**. With no partner, check the acknowledgement first. To replace an accepted partner, enter the new address and choose **Request change**. The partner-change emails land in a folder under `mail`; open the link from either email and choose **Approve** or **Deny**. Approval sends the new partner an invitation and the replaced partner a notice in `mail/<id>-applied`.

The service binds only to `127.0.0.1`. The default port is 8765. To use another port, pass `--port` to the service and set `CLEARPATH_PARTNER_PORT` to the same value when launching the app. Run the service and app as the same local user. The state directory contains the app's owner credential, one pairing database and the mail sink. Keep the entire directory private, including the invitation links in the mail sink. To stop the service after quitting the app, run `kill "$partner_demo_pid"`.

This slice uses a local file sink with synthetic addresses. Remote deployment and real email delivery are pending.

## Test the site removal flow

Run `swift test --package-path native --scratch-path artifacts/native-build --filter SiteRemovalTests` on macOS with Python 3.9+ on `PATH`. The test starts the real pairing service with a fixture clock and private mail sink. It sends synthetic requests through the installed-policy writer and checks the running filter with loopback DNS.

On a solo install, **Request removal** in **Blocked sites** records the request with the date it applies, seven days later. The block stays until then, and the site-block service removes it on its own after that time.

With a trusted pairing service configured for an installation, open **Blocked sites**, choose **Request removal** on a rule, and follow the request status in the same window. The installer accepts `--partner-config PATH` pointing to a JSON object with the HTTPS `origin` and `ownerKey` for that pairing. The installed copy is root-only. The pairing service can be started behind a trusted TLS reverse proxy with `--public-origin` set to the same HTTPS origin. The proxy must pass that origin's host to the service. For the menu-bar app's **Partner settings**, set `CLEARPATH_PARTNER_ORIGIN` to that origin and `CLEARPATH_PARTNER_STATE` to a private client directory containing its matching `owner-key` file. Keep the server database and mail sink under the trusted service operator's control. Hosted deployment and external delivery are tracked in #24.

### Test missed check-in alerts

With the same pairing configuration, the installed background service checks in at startup and hourly, even when the menu-bar app is closed. After 24 hours without a check-in, the pairing service alerts accepted partners once per outage. A successful check-in starts a fresh window. Run `swift test --package-path native --scratch-path artifacts/native-build --filter PartnerCheckInTests` to exercise the worker, a fixture clock and the local mail sink without installing a system service.

## Run locally

Python 3.9+ and a virtual environment are required. The Swift filter is the native runtime, and the Python DNS implementation is an experiment harness.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v
```

Tests use only temporary loopback UDP/TCP listeners and fixture DNS servers. A restrictive execution sandbox may require permission to bind loopback sockets. They never send test names to an external DNS server.

For explicit live probes (ordinary DNS names go to the selected provider):

```sh
.venv/bin/python scripts/live_smoke.py --upstream 1.1.1.1
```

For manual `dig` experiments, select an upstream you trust; this is a process argument, not a change to the Mac's DNS settings:

```sh
.venv/bin/python -m clearpath.dns --upstream 1.1.1.1 --port 1053
# In a second terminal:
dig @127.0.0.1 -p 1053 adult.example A
dig @127.0.0.1 -p 1053 www.google.com AAAA
dig @127.0.0.1 -p 1053 www.bing.com A +tcp
dig @127.0.0.1 -p 1053 www.google.com HTTPS
```

Expected: NXDOMAIN, Google forced-safe CNAME plus any safe IPv6 records, Bing strict CNAME/address chain, and an empty HTTPS answer. Ordinary browsers will **not** use this high-port listener automatically.

## Swift filter

`native/` holds the Swift filter engine that V1 ships: policy, DNS handling, upstream transport, and `clearpath-filter`, a loopback-only UDP/TCP DNS server with the same options as the Python prototype. Run by hand, it does not change the Mac's DNS.

```sh
swift test --package-path native --scratch-path artifacts/native-build
swift build --package-path native --scratch-path artifacts/native-build --product clearpath-filter
"$(swift build --package-path native --scratch-path artifacts/native-build --show-bin-path)/clearpath-filter" \
  --policy policy.example.json --upstream 1.1.1.1 --port 1053
```

The listener accepts only `127.0.0.1` or `::1`, and port 53 or ports 1024 and up. `--user NAME` makes a filter started as root give up root once the listener is bound. `--upstream` must be an IP address. That resolver sees allowed names and safe-target lookups. An invalid policy stops startup. The running filter checks for policy changes several times a second and keeps its last valid policy if a reload fails.

### Filter service (disposable VM only)

`clearpath-service` installs the filter as a root LaunchDaemon (`io.clearpath.filter`) on `127.0.0.1:53` and points every network service's DNS at it. It changes system DNS and needs `sudo`, so run it only in a disposable VM until Victor authorizes his Mac (`docs/TESTING.md`).

```sh
bin="$(swift build --package-path native --scratch-path artifacts/native-build --show-bin-path)"
sudo "$bin/clearpath-service" install --filter "$bin/clearpath-filter" --policy policy.json [--upstream IP] [--upstream-port N]
"$bin/clearpath-service" status      # JSON: daemon, DNS and recovery state
sudo "$bin/clearpath-service" restore    # emergency recovery if the filter stays down
sudo "$bin/clearpath-service" uninstall
```

Install refuses unless it runs as root, port 53 is free, the policy is valid, and no earlier install is present. Before changing anything it writes each network service's DNS setting (automatic or the exact servers) to `/Library/Application Support/Clearpath/recovery.json`. It starts the daemon, waits until the filter answers, and then moves DNS to it. The filter runs as `nobody` and launchd restarts it if it exits. In automatic mode, the filter uses the current network's negotiated DNS or the active service's saved manual servers. For names with a supplemental DNS match, it uses that resolver. `--upstream` selects a fixed resolver for controlled testing.

If installation fails, it rolls itself back. `uninstall` restores DNS from the record and checks it before stopping the daemon, then removes only Clearpath's files. It also cleans up an interrupted install and is safe to run twice. If you changed macOS network locations after installing, switch back to the installation location before running `uninstall`.

**Restore internet** asks macOS for administrator approval and uses the saved DNS settings after giving the filter time to restart. It verifies the settings before showing success, which means DNS filtering is off. Retry the same action if it was interrupted. The service and saved configuration stay installed. `status` exposes a local restore event for future partner delivery. An installation made with an older service tool lacks the helper for the button. Use an updated `clearpath-service restore` from the Terminal on that installation.

**Block a site** saves a custom rule through the installed service with no restart. The rule covers the domain and its subdomains. **Blocked sites** shows custom rules, adult list rules, and adult list exceptions. The same operations are available as `clearpath-service block-site example.com` and `clearpath-service blocked-sites`. An older installation needs the updated service before it can accept additions. When reinstalling in a disposable VM, keep a copy of the installed policy first so you can use it as the new installation’s input.

**Community blocklist.** New service installations check for a HaGeZi NSFW list refresh at startup and hourly, including after sleep. The service downloads only when seven days have passed since its last successful check. A failed refresh keeps the installed rules and retries at the next check. `clearpath-service status` reports the last successful check and source version under `communityList`. Existing installations need the updated service installed before automatic refresh begins. [HaGeZi NSFW domains](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt) · [GPLv3 license](https://github.com/hagezi/dns-blocklists/blob/main/LICENSE)

### Browser setup (disposable VM only)

After protection is on, open **Set up protection** from the shield menu and choose **Check DNS status** to check the filter and the Mac's DNS settings. For Safari, turn off iCloud Private Relay if it’s on. [Apple’s Private Relay instructions](https://support.apple.com/guide/mac-help/mchlecadabe0/mac)

For Chrome and Firefox, select **Show browser profile in Finder**, open **Clearpath Browser Policies.mobileconfig**, and approve it in **System Settings → General → Device Management**. Restart the browsers and verify their policies in `chrome://policy` and `about:policies`. The profile disables browser-managed Secure DNS and enables Chrome’s Google SafeSearch policy. The filter supplies domain blocking and the Google, Bing, and DuckDuckGo SafeSearch rules configured in your DNS policy. [Chrome DNS policy](https://chromeenterprise.google/policies/#DnsOverHttpsMode) · [Chrome Google SafeSearch policy](https://chromeenterprise.google/policies/#ForceGoogleSafeSearch) · [Firefox DNS policy](https://mozilla.github.io/policy-templates/#dnsoverhttps)

To roll back, remove only **Clearpath Browser Policies** (`io.clearpath.browser-policy.v1`) in Device Management, restart the browsers, and run the filter uninstall command above. See the [VM validation procedure](docs/TESTING.md#browser-setup-validation-disposable-macos-vm-only).

## Maintain a custom list

Copy the example policy to a working file. It contains just three real adult domains and synthetic fixtures, **not a complete adult blocklist**. Each block covers the apex and subdomains. SafeSearch covers only the exact hostnames configured.

```sh
cp policy.example.json policy.local.json
.venv/bin/python -m clearpath.policy policy.local.json
# domains.txt: one domain per line; optional *. prefix and # comments
.venv/bin/python -m clearpath.policy policy.local.json --import-list domains.txt --category custom
.venv/bin/python -m clearpath.dns --policy policy.local.json --upstream 1.1.1.1
```

Import validates the complete candidate and replaces the file atomically. Use one writer at a time. After an update, send `kill -HUP <prototype-pid>` to the specific running prototype, or restart it. Invalid reloads preserve the previous in-memory policy. Invalid files on a fresh start cause startup failure. Empty imports are rejected; to deliberately clear a list, edit its JSON array and validate it. Keep your own previous policy copy before making changes.

Stop the foreground prototype with **Ctrl-C**. No system rollback is needed. See [testing and rollback](docs/TESTING.md) for the separate disposable-VM procedure, [architecture](docs/ARCHITECTURE.md), [upstream audit](docs/UPSTREAM_AUDIT.md), and [observed results](docs/RESULTS.md).

The code is MIT licensed. No upstream application code or third-party blocklist dataset is vendored. dnslib is a pinned BSD-licensed experiment dependency in maintenance mode; it is not a production resolver recommendation.

## Contributing

Every change must pass the unit tests above and the example policy check:

```sh
.venv/bin/python -m clearpath.policy policy.example.json
```

After cloning, run `git config core.hooksPath .githooks` to turn on the guard that refuses force-pushes and direct pushes to `main`.

Agents: read `AGENTS.md`.
