import Foundation

/// Managed browser DNS settings and Chrome's Google SafeSearch policy.
public enum BrowserProfile {
    private static let identifier = "io.clearpath.browser-policy.v1"
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
            )
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadIdentifier": identifier,
            "PayloadUUID": "B68A3543-1786-5EE8-9951-19B494DC4CB2",
            "PayloadVersion": 1,
            "PayloadDisplayName": name,
            "PayloadOrganization": "Clearpath",
            "PayloadDescription": "Turns off Chrome and Firefox Secure DNS and forces Google SafeSearch in Chrome.",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": preferences
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
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
