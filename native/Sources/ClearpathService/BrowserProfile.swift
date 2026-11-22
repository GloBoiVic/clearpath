import Foundation

/// The browser settings shared by every install. Blocking and SafeSearch stay in the DNS policy.
public enum BrowserProfile {
    private static let identifier = "io.clearpath.browser-policy.v1"
    private static let name = "Clearpath Browser Policies"

    public static func configuration() throws -> Data {
        let preferences: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadIdentifier": identifier + ".preferences",
            "PayloadUUID": "55DF331F-AE03-5EF6-AD7C-782689FC6145",
            "PayloadVersion": 1,
            "PayloadDisplayName": "Secure DNS settings",
            "PayloadContent": [
                "com.google.Chrome": forced(["DnsOverHttpsMode": "off"]),
                "org.mozilla.firefox": forced([
                    "EnterprisePoliciesEnabled": true,
                    "DNSOverHTTPS": ["Enabled": false, "Locked": true]
                ])
            ]
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadIdentifier": identifier,
            "PayloadUUID": "B68A3543-1786-5EE8-9951-19B494DC4CB2",
            "PayloadVersion": 1,
            "PayloadDisplayName": name,
            "PayloadOrganization": "Clearpath",
            "PayloadDescription": "Turns off Chrome and Firefox Secure DNS so they use the Mac's DNS settings.",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [preferences]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private static func forced(_ settings: [String: Any]) -> [String: Any] {
        ["Forced": [["mcx_preference_settings": settings]]]
    }
}
