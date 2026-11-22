import Foundation
import XCTest
@testable import ClearpathService

final class BrowserProfileTests: XCTestCase {
    func testProfileOnlyManagesBrowserDNSAndCanBeRemovedByIdentifier() throws {
        let data = try BrowserProfile.configuration()
        XCTAssertEqual(data, try BrowserProfile.configuration())
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "io.clearpath.browser-policy.v1")
        XCTAssertEqual(profile["PayloadScope"] as? String, "System")
        XCTAssertEqual(profile["PayloadRemovalDisallowed"] as? Bool, false)

        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        XCTAssertNotEqual(payload["PayloadUUID"] as? String, profile["PayloadUUID"] as? String)
        let domains = try XCTUnwrap(payload["PayloadContent"] as? [String: [String: [[String: [String: Any]]]]])
        XCTAssertEqual(Set(domains.keys), ["com.google.Chrome", "org.mozilla.firefox"])
        let chrome = try XCTUnwrap(domains["com.google.Chrome"]?["Forced"]?.first?["mcx_preference_settings"])
        XCTAssertEqual(chrome as? [String: String], ["DnsOverHttpsMode": "off"])
        let firefox = try XCTUnwrap(domains["org.mozilla.firefox"]?["Forced"]?.first?["mcx_preference_settings"])
        XCTAssertEqual(Set(firefox.keys), ["EnterprisePoliciesEnabled", "DNSOverHTTPS"])
        XCTAssertEqual(firefox["EnterprisePoliciesEnabled"] as? Bool, true)
        XCTAssertEqual(firefox["DNSOverHTTPS"] as? [String: Bool], ["Enabled": false, "Locked": true])
    }
}
