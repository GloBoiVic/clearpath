"""Build/package in the workspace only. Never installs or activates an extension.

Default bundle is ad-hoc signed for inspection only. A distributable build requires
an explicitly selected Developer ID identity and two matching provisioning profiles.
"""
import argparse
import datetime
import fnmatch
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "io.clearpath.Clearpath"
PROVIDER_ID = APP_ID + ".DNSProxy"
CAPABILITY = "dns-proxy-systemextension"


def read_profile(path):
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def validate_profile(profile, bundle_id, team, group, host=False):
    ent = profile.get("Entitlements", {})
    app_id = ent.get("com.apple.application-identifier", ent.get("application-identifier", ""))
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("expired or invalid provisioning profile")
    if team not in profile.get("TeamIdentifier", []) or not fnmatch.fnmatchcase(team + "." + bundle_id, app_id):
        raise ValueError("profile team/application identifier mismatch")
    if CAPABILITY not in ent.get("com.apple.developer.networking.networkextension", []):
        raise ValueError("profile does not grant DNS Proxy system-extension capability")
    if group not in ent.get("com.apple.security.application-groups", []):
        raise ValueError("profile does not grant the Mach service app group")
    if host and not ent.get("com.apple.developer.system-extension.install"):
        raise ValueError("host profile does not grant system-extension installation")
    # Development profiles are not distributable Developer ID artifacts.
    if ent.get("get-task-allow") or profile.get("ProvisionedDevices"):
        raise ValueError("a Developer ID distribution profile is required")


def metadata(team, build):
    group = team + ".io.clearpath.shared"
    common = {"CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "0.2.0",
              "CFBundleVersion": str(build), "LSMinimumSystemVersion": "15.0"}
    host = {**common, "CFBundleIdentifier": APP_ID, "CFBundleName": "Clearpath", "CFBundleExecutable": "clearpathctl",
            "CFBundlePackageType": "APPL", "LSUIElement": True, "NSLocalNetworkUsageDescription": "Preserve access to your existing DNS resolver and local development services."}
    provider = {**common, "CFBundleIdentifier": PROVIDER_ID, "CFBundleName": "Clearpath DNS Proxy", "CFBundleExecutable": "ClearpathDNSProxy",
                "CFBundlePackageType": "SYSX", "NetworkExtension": {
                    "NEMachServiceName": group + ".dns-proxy",
                    "NEProviderClasses": {"com.apple.networkextension.dns-proxy": "ClearpathDNSProxyProvider"}}}
    entitlements = {"com.apple.developer.networking.networkextension": [CAPABILITY],
                    "com.apple.security.application-groups": [group],
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.network.client": True}
    host_entitlements = {**entitlements, "com.apple.developer.system-extension.install": True}
    # Direct-distribution CLI host must read the explicitly supplied policy path.
    # Only the system extension is sandboxed; no Powerbox/UI or privileged helper.
    host_entitlements.pop("com.apple.security.app-sandbox")
    host_entitlements.pop("com.apple.security.network.client")
    if team != "UNSIGNED00":
        entitlements = {**entitlements, "com.apple.application-identifier": team + "." + PROVIDER_ID,
                        "com.apple.developer.team-identifier": team}
        host_entitlements = {**host_entitlements, "com.apple.application-identifier": team + "." + APP_ID,
                             "com.apple.developer.team-identifier": team}
    return host, provider, host_entitlements, entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(ROOT / "artifacts/native"))
    parser.add_argument("--identity")
    parser.add_argument("--team", default="UNSIGNED00")
    parser.add_argument("--host-profile")
    parser.add_argument("--provider-profile")
    parser.add_argument("--build-number", type=int, default=1)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    if args.build_number < 1 or not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("positive build number and ten-character team identifier required")
    if args.identity:
        if not args.identity.startswith("Developer ID Application:") or not args.host_profile or not args.provider_profile or args.team == "UNSIGNED00":
            parser.error("signing requires Developer ID Application identity, team and both profiles")
        for path, bundle_id, host in [(args.host_profile, APP_ID, True), (args.provider_profile, PROVIDER_ID, False)]:
            validate_profile(read_profile(path), bundle_id, args.team, args.team + ".io.clearpath.shared", host)
    elif args.team != "UNSIGNED00" or args.host_profile or args.provider_profile:
        parser.error("profiles and real team identifiers require an explicit signing identity")
    output = Path(args.output).resolve()
    # Build outputs cannot target /Applications, system directories, or existing apps.
    if ROOT not in output.parents or "artifacts" not in output.relative_to(ROOT).parts:
        parser.error("output must be beneath this workspace's artifacts directory")
    output.mkdir(parents=True, exist_ok=True)
    app = output / "Clearpath.app"
    if app.exists():
        parser.error("output app already exists; select a fresh output directory")
    scratch = ROOT / "artifacts/native-build"
    base = ["swift", "build", "--package-path", str(ROOT / "native"), "--scratch-path", str(scratch), "-c", args.configuration]
    subprocess.run(base, check=True)
    products = Path(subprocess.check_output(base + ["--show-bin-path"], text=True).strip())
    host, provider, host_ent, provider_ent = metadata(args.team, args.build_number)
    extension = app / "Contents/Library/SystemExtensions" / (PROVIDER_ID + ".systemextension")
    for bundle, info, ent, executable, profile in [
        (extension, provider, provider_ent, "ClearpathDNSProxy", args.provider_profile),
        (app, host, host_ent, "clearpathctl", args.host_profile),
    ]:
        (bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copy2(products / executable, bundle / "Contents/MacOS" / executable)
        if profile:
            shutil.copy2(profile, bundle / "Contents/embedded.provisionprofile")
        ent_path = output / (executable + ".entitlements")
        ent_path.write_bytes(plistlib.dumps(ent))
        command = ["codesign", "--force", "--sign", args.identity or "-", "--entitlements", str(ent_path)]
        if args.identity:
            command += ["--options", "runtime", "--timestamp"]
        subprocess.run(command + [str(bundle)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    report = {"app": str(app.relative_to(ROOT)), "provider": PROVIDER_ID, "minimum_macos": "15.0",
              "signing": "Developer ID" if args.identity else "ad-hoc; inspection only; cannot activate",
              "installed": False, "activated": False, "notarized": False}
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
