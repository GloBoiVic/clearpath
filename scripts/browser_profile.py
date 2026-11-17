"""Generate a removable macOS browser policy profile. Never installs it.

Custom blocks supplement native DNS. Adult lists stay in native DNS to avoid
browser rule limits. Existing macOS/browser policies are never read or rewritten.
"""
import argparse
import json
from pathlib import Path
import plistlib
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from clearpath.policy import Policy

PROFILE_ID = "io.clearpath.browser-policy.v1"


def payload(identifier, kind, display, values):
    return {
        "PayloadIdentifier": identifier,
        "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)).upper(),
        "PayloadType": kind,
        "PayloadVersion": 1,
        "PayloadDisplayName": display,
        **values,
    }


def generate(policy):
    # Use Firefox's stricter cap (two patterns per domain); reject overflow rather
    # than silently truncating protection. DNS continues to support larger lists.
    custom = sorted(policy.custom)
    if len(custom) > 500:
        raise ValueError("browser supplement supports at most 500 custom domains; native DNS is separate")
    chrome = {"DnsOverHttpsMode": "off", "ForceGoogleSafeSearch": True}
    firefox = {"EnterprisePoliciesEnabled": True, "DNSOverHTTPS": {"Enabled": False, "Locked": True}}
    if custom:
        chrome["URLBlocklist"] = custom
        firefox["WebsiteFilter"] = {"Block": [pattern for host in custom for pattern in (f"*://{host}/*", f"*://*.{host}/*")]}
    content = [
        payload(PROFILE_ID + ".chrome", "com.google.Chrome", "Clearpath Chrome DNS and SafeSearch", chrome),
        payload(PROFILE_ID + ".firefox", "org.mozilla.firefox", "Clearpath Firefox DNS", firefox),
    ]
    return payload(PROFILE_ID, "Configuration", "Clearpath Browser Policies", {
        "PayloadScope": "System",
        "PayloadOrganization": "Clearpath",
        "PayloadDescription": "Disables browser-managed encrypted DNS, forces Google SafeSearch in Chrome, and supplements custom domain blocks. Remove this profile to restore prior managed policy state. Native DNS filtering is configured separately.",
        "PayloadRemovalDisallowed": False,
        "PayloadContent": content,
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", default="policy.example.json")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    profile = generate(Policy.load(args.policy))
    target = Path(args.output)
    # Refuse accidental overwrite of a profile prepared from a different policy.
    with target.open("xb") as out:
        out.write(plistlib.dumps(profile, fmt=plistlib.FMT_XML, sort_keys=True))
    print(json.dumps({"profile": str(target), "identifier": PROFILE_ID, "installed": False}))


if __name__ == "__main__":
    main()
