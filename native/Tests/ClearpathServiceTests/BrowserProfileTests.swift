import Foundation
import XCTest
@testable import ClearpathService

final class BrowserProfileTests: XCTestCase {
    func testProfileManagesBrowserDNSChromeAndBraveSafeSearchAndSafariPrivateTrackingProtection() throws {
        let data = try BrowserProfile.configuration()
        XCTAssertEqual(data, try BrowserProfile.configuration())
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "io.clearpath.browser-policy.v1")
        XCTAssertEqual(profile["PayloadScope"] as? String, "System")
        XCTAssertEqual(profile["PayloadRemovalDisallowed"] as? Bool, false)

        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 4)
        let uuids = ([profile] + payloads).compactMap { $0["PayloadUUID"] as? String }
        XCTAssertEqual(Set(uuids).count, 5)
        let chrome = try settings(for: "com.google.Chrome", in: payloads)
        XCTAssertEqual(Set(chrome.keys), ["DnsOverHttpsMode", "ForceGoogleSafeSearch"])
        XCTAssertEqual(chrome["DnsOverHttpsMode"] as? String, "off")
        XCTAssertEqual(chrome["ForceGoogleSafeSearch"] as? Bool, true)
        // Brave is Chromium: its secure DNS bypassed Clearpath until locked (#69). TorDisabled turns off
        // Brave's Tor windows, which resolve names through Tor; regular private windows stay (Victor, 2026-11-26).
        let brave = try settings(for: "com.brave.Browser", in: payloads)
        XCTAssertEqual(Set(brave.keys), ["DnsOverHttpsMode", "ForceGoogleSafeSearch", "TorDisabled"])
        XCTAssertEqual(brave["DnsOverHttpsMode"] as? String, "off")
        XCTAssertEqual(brave["ForceGoogleSafeSearch"] as? Bool, true)
        XCTAssertEqual(brave["TorDisabled"] as? Bool, true)
        let firefox = try settings(for: "org.mozilla.firefox", in: payloads)
        XCTAssertEqual(firefox as? [String: Bool], [
            "EnterprisePoliciesEnabled": true,
            "DNSOverHTTPS__Enabled": false,
            "DNSOverHTTPS__Locked": true
        ])
        // With this protection on, Safari private windows bypassed the system DNS path (#61).
        // Only the private key is managed; regular browsing stays unmanaged (Victor, 2026-11-26).
        let safari = try settings(for: "com.apple.Safari", in: payloads)
        XCTAssertEqual(safari as? [String: Bool], ["EnableEnhancedPrivacyInPrivateBrowsing": false])
    }

    private func settings(for domain: String, in payloads: [[String: Any]]) throws -> [String: Any] {
        typealias Domain = [String: [[String: [String: Any]]]]
        let payload = try XCTUnwrap(payloads.first {
            ($0["PayloadContent"] as? [String: Domain])?[domain] != nil
        })
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        let domains = try XCTUnwrap(payload["PayloadContent"] as? [String: Domain])
        XCTAssertEqual(Set(domains.keys), [domain])
        return try XCTUnwrap(domains[domain]?["Forced"]?.first?["mcx_preference_settings"])
    }
}
