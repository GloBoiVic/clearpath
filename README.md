# Clearpath filtering foundation

**Current status:** a Swift macOS DNS Proxy system extension, native policy/DNS engine, activation/deactivation control command, removable browser policy generator, and isolated tests are implemented. **The extension has not been activated; cross-browser protection, reboot persistence and real-system rollback are not yet validated.** Signing/entitlement prerequisites remain missing in this environment. See [native implementation and safe deployment](native/README.md) and [current evidence](docs/native/RESULTS.md).

The original Python DNS experiment, working policy behavior, upstream reproductions and initial research are preserved. The native implementation builds on the independent-core/DNS-Proxy/browser-policy decision. No full UI, accountability partner or recovery system is implemented. No system networking, Screen Time, browser configuration or privileged service on the development Mac was changed. The native activation commands can change configuration only when explicitly invoked from an installed signed app; do not run them on an everyday Mac without authorization.

## Native build — no activation

```sh
swift test --package-path native --scratch-path artifacts/native-build
swift build --package-path native --scratch-path artifacts/native-build -c release
```

Requires macOS 15+ and Xcode 16+. [Native instructions](native/README.md) cover workspace-only packaging, Developer ID profiles, read-only prerequisite checks, explicit probes, browser policy generation and VM-only activation/rollback. The [VM acceptance checklist](docs/native/VM_VALIDATION.md) distinguishes completed isolated tests from unperformed runtime/browser tests.

## Original Python experiment

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
