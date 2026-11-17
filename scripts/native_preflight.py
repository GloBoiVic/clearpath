"""Read-only prerequisite report; does not prompt, install, provision, or start a VM."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_native import CAPABILITY, PROVIDER_ID, read_profile


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    return result.returncode, result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    code, identities = command(["security", "find-identity", "-v", "-p", "codesigning"])
    _, hv = command(["sysctl", "-n", "kern.hv_support"])
    _, extensions = command(["systemextensionsctl", "list"])
    paths = [Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
             Path.home() / "Library/MobileDevice/Provisioning Profiles"]
    profiles, dns_profiles, unreadable = 0, 0, 0
    for directory in paths:
        if not directory.exists():
            continue
        for path in directory.iterdir():
            if path.suffix not in (".mobileprovision", ".provisionprofile"):
                continue
            profiles += 1
            try:
                profile = read_profile(path)
                if CAPABILITY in profile.get("Entitlements", {}).get("com.apple.developer.networking.networkextension", []):
                    dns_profiles += 1
            except (OSError, ValueError, subprocess.CalledProcessError):
                unreadable += 1
    report = {
        "os": command(["sw_vers", "-productVersion"])[1].strip(),
        "architecture": command(["uname", "-m"])[1].strip(),
        "identity_query_succeeded": code == 0,
        "developer_id_application_identities": identities.count('"Developer ID Application:'),
        "apple_development_identities": identities.count('"Apple Development:'),
        "profiles_examined": profiles, "dns_proxy_systemextension_profiles": dns_profiles,
        "unreadable_profiles": unreadable,
        "hardware_virtualization_supported": True if hv.strip() == "1" else None,
        "vm_tools_found": [tool for tool in ("tart", "prlctl", "vmrun", "utmctl") if shutil.which(tool)],
        "clearpath_extension_listed": PROVIDER_ID in extensions,
        "runtime_validation_performed": False,
        "notes": "Counts only; no certificate/profile contents or account identifiers exported. No VM was provisioned or started. An absent Developer ID identity or DNS entitlement profile blocks this direct-distribution activation path."
    }
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
