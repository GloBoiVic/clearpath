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


if __name__ == "__main__":
    unittest.main()
