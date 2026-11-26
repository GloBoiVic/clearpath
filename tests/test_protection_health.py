"""The panel's outage rule, decoded from `clearpath-service status` JSON (#73)."""

import unittest

from test_uninstall_confirmation import run_swift


class ProtectionHealthTests(unittest.TestCase):
    def test_a_filter_that_answers_but_breaks_lookups_counts_as_an_outage(self):
        driver = r'''
import Foundation
func status(_ extra: String) -> FilterStatus {
    let json = #"{"installed":true,"daemonLoaded":true,"pid":42,"dnsPointsToFilter":true,"services":[],"# + extra + "}"
    return try! JSONDecoder().decode(FilterStatus.self, from: Data(json.utf8))
}
precondition(status(#""answering":true,"defaultResolverUsesFilter":true"#).outage == false)
precondition(status(#""answering":false"#).outage == true)
precondition(status(#""answering":true,"defaultResolverUsesFilter":false,"lookupsFailThroughFilter":true"#).outage == true)
precondition(status(#""answering":true,"defaultResolverUsesFilter":false,"lookupsFailThroughFilter":false"#).outage == false)
precondition(status(#""answering":true,"defaultResolverUsesFilter":false"#).outage == false)  // an older service tool
precondition(status(#""answering":false,"recovery":"restored""#).outage == false)
'''
        run_swift(driver, "ProtectionHealth.swift", "RestoreOutcome.swift")

    def test_a_vpn_default_resolver_shows_on_through_the_vpn_or_a_bypass_warning(self):
        driver = r'''
import Foundation
func state(_ extra: String) -> ProtectionState {
    let json = #"{"installed":true,"daemonLoaded":true,"pid":42,"answering":true,"dnsPointsToFilter":true,"services":[],"# + extra + "}"
    return ProtectionState.from(try! JSONDecoder().decode(FilterStatus.self, from: Data(json.utf8)))
}
precondition(state(#""defaultResolverUsesFilter":true"#) == .protected)
let through = state(#""defaultResolverUsesFilter":false,"defaultResolverReachesFilter":true"#)
precondition(through == .protectedThroughVPN && through.isOn && through.note == nil)
precondition(through.headline == "Protection is on through your VPN")
let bypass = state(#""defaultResolverUsesFilter":false,"defaultResolverReachesFilter":false"#)
precondition(bypass == .vpnBypass && !bypass.isOn && !bypass.offersRestore)
precondition(bypass.headline == "Your VPN is bypassing Clearpath")
precondition(bypass.note == "Sites aren’t filtered while your VPN answers lookups itself. Turn off your VPN’s DNS setting to turn protection back on.")
precondition(state(#""defaultResolverUsesFilter":false"#) == .unknown)  // the check got no answer, or an older tool
precondition(state(#""defaultResolverUsesFilter":false,"defaultResolverReachesFilter":true,"lookupsFailThroughFilter":true"#) == .unknown)
precondition(ProtectionState.from(nil) == .unknown)
'''
        run_swift(driver, "ProtectionHealth.swift", "RestoreOutcome.swift")


if __name__ == "__main__":
    unittest.main()
