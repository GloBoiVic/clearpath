# Clearpath foundation experiment

Clearpath is a free, open-source macOS app that blocks adult and NSFW websites in every browser, with an accountability partner instead of spyware. See the [product brief](docs/BRIEF.md) and [architecture](docs/ARCHITECTURE.md). Do not fork distraction-free's resolver or installer. DNS filtering works when requests reach it. Arbitrary encrypted DNS, proxies, VPNs and administrator access can bypass it. Browser setup observations and the remaining V1 acceptance cases are in [docs/RESULTS.md](docs/RESULTS.md).

This repository contains a Swift DNS filter and service, an isolated Python DNS harness, and the menu-bar app. Run `./build.sh` on macOS with the Swift toolchain. The shield panel displays synthetic status data, and **Set up protection** can check the real DNS service and reveal the Chrome and Firefox profile. The service installer and Device Management make system changes during the disposable VM procedure. **Partner settings** can connect to a local pairing service.

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

The service binds only to `127.0.0.1`. The default port is 8765. To use another port, pass `--port` to the service and set `CLEARPATH_PARTNER_PORT` to the same value when launching the app. Run the service and app as the same local user. The state directory contains the app's owner credential, one pairing database and the mail sink. Keep the entire directory private, including the invitation links in the mail sink. To stop the service after quitting the app, run `kill "$partner_demo_pid"`.

This slice uses a local file sink with synthetic addresses. Remote deployment and real email delivery are pending.

## Run locally

Python 3.9+ and a virtual environment are required; macOS does not guarantee a bundled Python. Python is an experiment harness, not the proposed shipping runtime.

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

The listener accepts only `127.0.0.1` or `::1`, and port 53 or ports 1024 and up. `--user NAME` makes a filter started as root give up root once the listener is bound. `--upstream` must be an IP address; that resolver sees allowed names and safe-target lookups. An invalid policy stops startup. It does not reload the policy on SIGHUP yet; restart it after a change.

### Filter service (disposable VM only)

`clearpath-service` installs the filter as a root LaunchDaemon (`io.clearpath.filter`) on `127.0.0.1:53` and points every network service's DNS at it. It changes system DNS and needs `sudo`, so run it only in a disposable VM until Victor authorizes his Mac (`docs/TESTING.md`).

```sh
bin="$(swift build --package-path native --scratch-path artifacts/native-build --show-bin-path)"
sudo "$bin/clearpath-service" install --filter "$bin/clearpath-filter" --policy policy.json [--upstream IP] [--upstream-port N]
"$bin/clearpath-service" status      # JSON: installed, daemon pid, answering, each service's DNS
sudo "$bin/clearpath-service" uninstall
```

Install refuses unless it runs as root, port 53 is free, the policy is valid, and no earlier install is present. Before changing anything it writes each network service's DNS setting (automatic or the exact servers) to `/Library/Application Support/Clearpath/recovery.json`. It starts the daemon, waits until the filter answers, and then moves DNS to it. The filter runs as `nobody` and launchd restarts it if it exits. In automatic mode, the filter uses the current network's negotiated DNS or the active service's saved manual servers. For names with a supplemental DNS match, it uses that resolver. `--upstream` selects a fixed resolver for controlled testing.

If installation fails, it rolls itself back. `uninstall` restores DNS from the record and checks it before stopping the daemon, then removes only Clearpath's files. It also cleans up an interrupted install and is safe to run twice. If you changed macOS network locations after installing, switch back to the installation location before running `uninstall`.

### Browser setup (disposable VM only)

After installing the filter with your DNS policy, open **Set up protection** from the shield menu and choose **Check DNS status**. This checks the filter and the Mac's DNS settings. For Safari, turn off iCloud Private Relay if it’s on. [Apple’s Private Relay instructions](https://support.apple.com/guide/mac-help/mchlecadabe0/mac)

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
