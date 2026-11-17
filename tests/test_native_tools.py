import datetime
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

from clearpath.policy import Policy

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


browser = module("browser_profile")
builder = module("build_native")


class BrowserProfileTests(unittest.TestCase):
    def test_removable_profile_has_only_owned_browser_payloads(self):
        policy = Policy.load(ROOT / "policy.example.json")
        profile = plistlib.loads(plistlib.dumps(browser.generate(policy)))
        self.assertEqual(profile["PayloadIdentifier"], browser.PROFILE_ID)
        self.assertFalse(profile["PayloadRemovalDisallowed"])
        self.assertEqual(profile["PayloadScope"], "System")
        chrome, firefox = profile["PayloadContent"]
        self.assertEqual(chrome["PayloadType"], "com.google.Chrome")
        self.assertEqual(chrome["DnsOverHttpsMode"], "off")
        self.assertTrue(chrome["ForceGoogleSafeSearch"])
        self.assertEqual(chrome["URLBlocklist"], ["blocked.example"])
        self.assertEqual(firefox["PayloadType"], "org.mozilla.firefox")
        self.assertEqual(firefox["DNSOverHTTPS"], {"Enabled": False, "Locked": True})
        self.assertTrue(firefox["EnterprisePoliciesEnabled"])
        self.assertEqual(firefox["WebsiteFilter"]["Block"], ["*://blocked.example/*", "*://*.blocked.example/*"])
        self.assertEqual(len({p["PayloadUUID"] for p in [profile,chrome,firefox]}), 3)
        self.assertEqual(profile, browser.generate(policy))
        self.assertNotIn("ScreenTime", str(profile))

    def test_custom_supplement_does_not_silently_truncate(self):
        from dataclasses import replace
        policy = Policy.load(ROOT / "policy.example.json")
        with self.assertRaises(ValueError):
            browser.generate(replace(policy, custom=frozenset(f"x{i}.example" for i in range(501))))
        result = browser.generate(replace(policy, custom=frozenset()))
        self.assertNotIn("URLBlocklist", result["PayloadContent"][0])
        self.assertNotIn("WebsiteFilter", result["PayloadContent"][1])


class BundleTests(unittest.TestCase):
    def test_bundle_and_entitlements_match(self):
        host, provider, host_ent, provider_ent = builder.metadata("TESTTEAM01", 2)
        self.assertEqual(provider["CFBundlePackageType"], "SYSX")
        self.assertEqual(host["CFBundlePackageType"], "APPL")
        self.assertEqual(provider["CFBundleIdentifier"], builder.PROVIDER_ID)
        self.assertEqual(provider["NetworkExtension"]["NEProviderClasses"], {"com.apple.networkextension.dns-proxy": "ClearpathDNSProxyProvider"})
        group = provider_ent["com.apple.security.application-groups"][0]
        self.assertTrue(provider["NetworkExtension"]["NEMachServiceName"].startswith(group + "."))
        self.assertTrue(provider_ent["com.apple.security.app-sandbox"])
        self.assertNotIn("com.apple.security.app-sandbox", host_ent)
        self.assertTrue(host_ent["com.apple.developer.system-extension.install"])
        for ent, bundle in ((host_ent,builder.APP_ID),(provider_ent,builder.PROVIDER_ID)):
            self.assertEqual(ent["com.apple.developer.networking.networkextension"], [builder.CAPABILITY])
            self.assertEqual(ent["com.apple.application-identifier"], "TESTTEAM01." + bundle)

    def test_profile_validation_checks_capabilities_identity_and_expiry(self):
        valid = {"ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=10), "TeamIdentifier": ["TESTTEAM01"],
                 "Entitlements": {"com.apple.application-identifier": "TESTTEAM01." + builder.APP_ID,
                                  "com.apple.developer.networking.networkextension": [builder.CAPABILITY],
                                  "com.apple.security.application-groups": ["TESTTEAM01.io.clearpath.shared"],
                                  "com.apple.developer.system-extension.install": True}}
        builder.validate_profile(valid, builder.APP_ID, "TESTTEAM01", "TESTTEAM01.io.clearpath.shared", True)
        import copy
        for mutate in (
            lambda p: p.update(ExpirationDate=datetime.datetime(2000,1,1)),
            lambda p: p.update(TeamIdentifier=["OTHERTEAM1"]),
            lambda p: p["Entitlements"].update({"com.apple.developer.networking.networkextension": ["dns-proxy"]}),
            lambda p: p["Entitlements"].update({"com.apple.application-identifier": "TESTTEAM01.someone.else"}),
            lambda p: p["Entitlements"].update({"com.apple.security.application-groups": []}),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p.update(ProvisionedDevices=["development-device"]),
        ):
            candidate = copy.deepcopy(valid)
            mutate(candidate)
            with self.assertRaises(ValueError):
                builder.validate_profile(candidate, builder.APP_ID, "TESTTEAM01", "TESTTEAM01.io.clearpath.shared", True)


if __name__ == "__main__":
    unittest.main()
