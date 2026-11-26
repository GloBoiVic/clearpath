import Foundation

/// Managed browser DNS settings, Chrome's Google SafeSearch policy and Safari's private-window protection.
public enum BrowserProfile {
    static let identifier = "io.clearpath.browser-policy.v1"
    static let uuid = "B68A3543-1786-5EE8-9951-19B494DC4CB2"
    private static let name = "Clearpath Browser Policies"

    public static func configuration() throws -> Data {
        let preferences = [
            preferencesPayload(
                domain: "com.google.Chrome", suffix: "chrome",
                uuid: "4ECC228B-CAAF-57D4-A726-CB43BE59A5CB",
                name: "Clearpath Chrome settings",
                settings: [
                    "DnsOverHttpsMode": "off",
                    "ForceGoogleSafeSearch": true
                ]
            ),
            preferencesPayload(
                domain: "org.mozilla.firefox", suffix: "firefox",
                uuid: "9C6A5945-36DB-5678-B285-FD08B9BD1568",
                name: "Clearpath Firefox settings",
                settings: [
                    "EnterprisePoliciesEnabled": true,
                    // Firefox's documented flat form; macOS did not apply the nested dictionary.
                    "DNSOverHTTPS__Enabled": false,
                    "DNSOverHTTPS__Locked": true
                ]
            ),
            preferencesPayload(
                domain: "com.apple.Safari", suffix: "safari",
                uuid: "2B41B8F6-B92F-5D27-A4A9-808E8947797D",
                name: "Clearpath Safari settings",
                settings: [
                    // Safari's "advanced tracking and fingerprinting protection" key, undocumented by Apple.
                    // While it is on, private windows bypass the system DNS path (#61). Safari then dims
                    // the whole setting, so it reads as off in every window.
                    "EnableEnhancedPrivacyInPrivateBrowsing": false
                ]
            )
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuid,
            "PayloadVersion": 1,
            "PayloadDisplayName": name,
            "PayloadOrganization": "Clearpath",
            "PayloadDescription": "Turns off Chrome and Firefox Secure DNS, forces Google SafeSearch in Chrome, and turns off Safari's advanced tracking and fingerprinting protection so Clearpath also filters Safari private windows.",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": preferences
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    static func isInstalled(using system: SystemControl) throws -> Bool {
        let listing = try system.run(.profiles, ["show", "-type", "configuration", "-output", "stdout-xml"])
        let output = listing.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if listing.status == 0, output == "There are no configuration profiles installed in the system domain" {
            return false
        }
        let failure = ServiceError.failed("Clearpath couldn’t verify the installed browser profile. Try again.")
        guard listing.status == 0,
              let document = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any] else {
            throw failure
        }
        if document.isEmpty { return false }
        guard document.count == 1,
              let profiles = (document["_computerlevel"] ?? document["_computerLevel"]) as? [[String: Any]] else {
            throw failure
        }
        var matchingUUID: UUID?
        for profile in profiles {
            guard let installedID = profile["ProfileIdentifier"] as? String else { throw failure }
            if installedID == identifier {
                guard matchingUUID == nil, let installedUUID = profile["ProfileUUID"] as? String,
                      let parsed = UUID(uuidString: installedUUID) else {
                    throw failure
                }
                matchingUUID = parsed
            }
        }
        return matchingUUID?.uuidString == uuid
    }

    private static func preferencesPayload(
        domain: String, suffix: String, uuid: String, name: String, settings: [String: Any]
    ) -> [String: Any] {
        [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadIdentifier": identifier + "." + suffix,
            "PayloadUUID": uuid,
            "PayloadVersion": 1,
            "PayloadDisplayName": name,
            "PayloadContent": [domain: ["Forced": [["mcx_preference_settings": settings]]]]
        ]
    }
}
