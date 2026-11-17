# Native foundation evidence — 2026-11-17

## Outcome

The native DNS Proxy integration, Swift filtering core, lifecycle control, removable browser policy generator, build/signing tooling and tests are implemented. **No native extension or browser profile was installed or activated. Runtime acceptance remains blocked.** This is a tested implementation foundation, not a claim of completed cross-browser protection.

The original Python prototype and its evidence remain intact. No system network services, DNS addresses, routes, Screen Time settings, security settings, privileged services or installed certificates were modified. The only signing performed was ad-hoc signing of workspace inspection artifacts, not use of the user's development key.

## Prerequisites checked

[preflight.json](preflight.json) records a read-only check with execution sandbox restrictions lifted so Keychain results were meaningful:

- macOS 27.2.1, arm64; Xcode 27.2 / Swift 6.4.2 in the observed environment. These are observed version strings, not a statement about supported public OS releases.
- One Apple Development identity; **zero Developer ID Application identities**.
- Two existing provisioning profiles examined; **zero granting `dns-proxy-systemextension`**. No profile/certificate contents or account identifiers were exported into this repository.
- Hardware virtualization is supported. No `tart`, `prlctl`, `vmrun` or `utmctl` tool was found; no prepared VM was supplied or started. No guest installation image was downloaded.
- Clearpath was not listed among installed system extensions.

An initial sandbox-only identity query reported zero identities; the unsandboxed read-only check above supersedes that result. Missing distribution signing and DNS capability grants block the selected supported activation path. The existing development identity was not used or modified. No SIP/developer-mode workaround was attempted. VM preparation alone would not resolve the missing entitlement/profile gate.

## Automated tests

| Check | Observed result | Evidence |
|---|---|---|
| Swift package, including provider/control compilation | **32 tests passed, 0 failures** | [swift-tests.txt](swift-tests.txt) |
| Existing Python regressions + new parity/browser/build tests | **33 tests passed, 0 failures** | [python-tests.txt](python-tests.txt) |
| Native live DNS, HTTPS and Git probes | **17/17 passed** | [live-probes.json](live-probes.json) |
| Host and system-extension bundle signatures | Both ad-hoc signatures verify structurally | [package-checks.json](package-checks.json) |
| Provider class in executable | `ClearpathDNSProxyProvider` appears in Objective-C class list and matches plist mapping | [package-checks.json](package-checks.json) |
| CLI safety boundaries | Missing mutation flag and uninstalled binary rejected before manager use | [package-checks.json](package-checks.json) |
| Generated browser `.mobileconfig` | XML/plist lint passed; two owned/removable payloads verified by tests | Python test evidence; profile not installed |

Swift tests cover the shared Python policy corpus/hash, label-boundary matching, IDNA example and invalid domains, custom/allow/SafeSearch precedence, duplicate JSON/schema/conflict rejection, local adult/custom blocking, all configured SafeSearch mappings over A/AAAA, no unsafe fallback, suppressed HTTPS/SVCB hints, alias blocks, upstream identity/question validation, malformed/truncated/compressed DNS input, EDNS/AD cleanup, TCP fragmentation/pipelining and bounds. Real Network.framework IPv4/IPv6 UDP and TCP loopback sockets, split TCP frames, transaction deadlines, cancellation and hostname-upstream rejection were tested. Synthetic parser cases are not a comprehensive DNS fuzz/security audit.

Nine lifecycle tests use fake preference/extension backends: idempotent activation, save-failure rollback, removal of only new configuration, rollback failure reporting, foreign-configuration refusal, concurrent-change preservation, reboot-required activation without enabling preferences, ordered deactivation/removal and explicit policy-update gating. **These are not actual Apple preference writes, OS approval, or native rollback tests.**

The GitHub Actions workflow is configured to run Python/Swift tests and inspection packaging on macOS. A local pass is not a GitHub-hosted CI result; check the workflow run for the pushed implementation branch separately.

## Live probe boundary

The final release `clearpathctl probe` binary ran through the same Swift policy/DNS/Network.framework code used by the provider. The probe explicitly selected `1.1.1.1`; it did not change the system resolver or invoke manager APIs. All fixed test domains were deliberate test inputs.

Observed DNS results:

- Synthetic adult/custom entries and a listed real adult domain returned local NXDOMAIN. No adult HTTP/TLS request was made.
- Google returned `forcesafesearch.google.com` CNAME with safe A/AAAA addresses; protected HTTPS query returned no routing hints.
- Bing and DuckDuckGo returned their provider strict/safe CNAME chains and address records.
- GitHub, npm, PyPI and Docker registry names resolved normally. DNS-over-TCP was exercised against the selected upstream.
- Four certificate-validated HTTPS HEAD requests (Google SafeSearch endpoint, GitHub, npm registry, PyPI) returned HTTP 200 / verification result 0 using per-process addresses from native results.
- `git ls-remote` read the public Clearpath repository using Git's per-process `http.curloptResolve` setting with the native-returned GitHub address. No credential helper was used.

This establishes actual network behavior of the native core and transport. It does **not** establish Network Extension flow delivery, browser DNS routing, locked browser SafeSearch controls, actual package installs, SSH, containers, scoped/private DNS, end-to-end IPv6 HTTPS or developer workflows with interception active. Dynamic addresses in evidence are observations, not configuration constants.

## Packaging boundary

`scripts/build_native.py` produced a release host app containing the system extension under `Contents/Library/SystemExtensions`, with correct provider class mapping and team-prefixed Mach-service group metadata. Signature checks passed for the ad-hoc inspection artifacts. Framework dependency inspection found only system libraries/frameworks; no unbundled project dylib was required.

The inspection bundle is intentionally not eligible for native activation. Real Developer ID profile embedding, signing, notarization, supported OS installation, user approval, provider-start option delivery and actual preference persistence remain untested. The builder's validation of profile metadata is tested using synthetic profiles, not claimed as an Apple provisioning authority.

## Acceptance status

| Acceptance criterion | Status |
|---|---|
| Adult/custom sites blocked in Safari, Chrome, Firefox | **Not run / blocked** |
| SafeSearch visibly locked in supported browsers/engines | **Not run / blocked**; native DNS mapping passed |
| Normal browsing/development through native interception | **Not run / blocked**; process-local DNS/HTTPS/Git passed |
| Protection after control process exits | **Not run / blocked**; implemented as an OS-owned system extension |
| Protection after OS reboot/logout/sleep/network switch | **Not run / blocked** |
| Complete actual install/deactivate/uninstall/profile rollback | **Not run / blocked**; ordering/failure paths passed with mocks |
| Known bypasses/limitations documented | Done in [native README](../../native/README.md) |
| Existing Python functionality retained | Regression suite passed |

The machine-readable [acceptance.json](acceptance.json) and [VM validation procedure](VM_VALIDATION.md) intentionally keep unperformed items open. The next required work is eligible signing/profile setup and a disposable VM, then actual provider/browser/lifecycle/rollback validation. No host activation is authorized by this implementation work.
