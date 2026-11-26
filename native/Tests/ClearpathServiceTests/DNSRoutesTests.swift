import XCTest
@testable import ClearpathService

final class DNSRoutesTests: XCTestCase {
    private let globalDNS = "State:/Network/Global/DNS"
    private let globalIPv4 = "State:/Network/Global/IPv4"
    private let globalIPv6 = "State:/Network/Global/IPv6"
    private let ethernet = "State:/Network/Service/ethernet/DNS"
    private let wifi = "State:/Network/Service/wifi/DNS"
    private let tunnel = "State:/Network/Service/tunnel/DNS"
    private let otherTunnel = "State:/Network/Service/other-tunnel/DNS"

    func test_handoff_uses_the_new_primary_and_live_dhcp_instead_of_install_time_addresses() {
        var state: [String: [String: Any]] = [
            globalDNS: ["ServerAddresses": ["127.0.0.1"]],
            globalIPv4: ["PrimaryService": "ethernet", "PrimaryInterface": "en0"],
            ethernet: ["ServerAddresses": ["192.0.2.53"]],
            wifi: ["ServerAddresses": ["198.51.100.53"]],
        ]
        let saved = ["ethernet": ["192.0.2.80"], "wifi": []]
        XCTAssertEqual(DNSRoutes(state: state, saved: saved, port: 53).route(for: "public.example"),
                       .init(servers: ["192.0.2.80"], interface: "en0", port: 53))

        state[globalIPv4] = ["PrimaryService": "wifi", "PrimaryInterface": "en1"]
        XCTAssertEqual(DNSRoutes(state: state, saved: saved, port: 53).route(for: "public.example"),
                       .init(servers: ["198.51.100.53"], interface: "en1", port: 53))

        state[globalIPv4] = nil
        state[globalIPv6] = ["PrimaryService": "wifi", "PrimaryInterface": "en1"]
        state[wifi] = ["ServerAddresses": ["2001:db8::53"]]
        XCTAssertEqual(DNSRoutes(state: state, saved: saved, port: 53).route(for: "public.example"),
                       .init(servers: ["2001:db8::53"], interface: "en1", port: 53))
        state[wifi] = nil
        XCTAssertNil(DNSRoutes(state: state, saved: saved, port: 53).route(for: "public.example"))
    }

    func test_longest_dns_suffix_and_order_select_the_private_resolver_at_label_boundaries() {
        let state: [String: [String: Any]] = [
            globalDNS: ["ServerAddresses": ["192.0.2.53"]],
            tunnel: ["SupplementalMatchDomains": ["Corp.Example."], "ServerAddresses": ["192.0.2.54"],
                     "InterfaceName": "utun1"],
            otherTunnel: ["SupplementalMatchDomains": ["dev.corp.example", "corp.example"],
                          "SupplementalMatchOrders": [10, 20], "ServerAddresses": ["2001:db8::53"],
                          "InterfaceName": "utun2", "ServerPort": 5354],
        ]
        let routes = DNSRoutes(state: state, saved: [:], port: 53)
        XCTAssertEqual(routes.route(for: "corp.example")?.interface, "utun2")
        XCTAssertEqual(routes.route(for: "_build._tcp.dev.corp.example"),
                       .init(servers: ["2001:db8::53"], interface: "utun2", port: 5354, scoped: true))
        XCTAssertEqual(routes.route(for: "notcorp.example")?.servers, ["192.0.2.53"])
        XCTAssertNil(routes.route(for: "printer.local"))
        XCTAssertNil(routes.route(for: "4.3.254.169.in-addr.arpa"))
    }

    func test_a_matching_but_unusable_or_ambiguous_scope_cannot_fall_back_to_public_dns() {
        var state: [String: [String: Any]] = [
            globalDNS: ["ServerAddresses": ["192.0.2.53"]],
            tunnel: ["SupplementalMatchDomains": ["corp.example"]],
        ]
        XCTAssertEqual(DNSRoutes(state: state, saved: [:], port: 53).route(for: "host.corp.example")?.servers, [])

        state[otherTunnel] = ["SupplementalMatchDomains": ["corp.example"], "ServerAddresses": ["192.0.2.54"]]
        let ambiguous = DNSRoutes(state: state, saved: [:], port: 53)
        XCTAssertNil(ambiguous.route(for: "host.corp.example"))
        XCTAssertEqual(ambiguous.route(for: "public.example")?.servers, ["192.0.2.53"])
    }

    /// Tailscale's DNS (#73): the VPN becomes the Mac's default resolver and forwards ordinary
    /// names to the interface DNS, which is Clearpath. Sending them back to the VPN loops.
    func test_a_vpn_default_resolver_never_receives_ordinary_names_from_the_filter() {
        var state: [String: [String: Any]] = [
            globalDNS: ["ServerAddresses": ["100.100.100.100"]],
            globalIPv4: ["PrimaryService": "ethernet", "PrimaryInterface": "en0"],
            ethernet: ["ServerAddresses": ["192.0.2.1"]],
            "Setup:/Network/Service/ethernet/DNS": ["ServerAddresses": ["127.0.0.1"]],
            tunnel: ["SupplementalMatchDomains": ["", "tailnet.example"], "ServerAddresses": ["100.100.100.100"],
                     "InterfaceName": "utun4"],
        ]
        let automatic = DNSRoutes(state: state, saved: ["ethernet": []], port: 53)
        XCTAssertEqual(automatic.route(for: "public.example"), .init(servers: ["192.0.2.1"], interface: "en0", port: 53))
        XCTAssertEqual(automatic.route(for: "host.tailnet.example"),
                       .init(servers: ["100.100.100.100"], interface: "utun4", port: 53, scoped: true))
        XCTAssertEqual(DNSRoutes(state: state, saved: ["ethernet": ["192.0.2.80"]], port: 53).route(for: "public.example")?.servers,
                       ["192.0.2.80"])

        // The same VPN published only as the global resolver, without a catch-all scope.
        state[tunnel] = ["SupplementalMatchDomains": ["tailnet.example"], "ServerAddresses": ["100.100.100.100"]]
        XCTAssertEqual(DNSRoutes(state: state, saved: ["ethernet": []], port: 53).route(for: "public.example")?.servers,
                       ["192.0.2.1"])
    }

    func test_a_vpn_catchall_still_leaves_specific_vpn_scopes_in_place() {
        let routes = DNSRoutes(state: [
            globalDNS: ["ServerAddresses": ["192.0.2.53"]],
            tunnel: ["SupplementalMatchDomains": [""], "ServerAddresses": ["192.0.2.54"]],
            otherTunnel: ["SupplementalMatchDomains": ["dev.corp.example"], "ServerAddresses": ["192.0.2.55"]],
        ], saved: [:], port: 53)
        XCTAssertEqual(routes.route(for: "public.example")?.servers, ["192.0.2.53"])
        XCTAssertEqual(routes.route(for: "host.dev.corp.example")?.servers, ["192.0.2.55"])
    }

    func test_saved_dns_restores_manual_scopes_without_overriding_live_vpn_scopes() {
        let routes = DNSRoutes(state: [
            tunnel: ["SupplementalMatchDomains": ["vpn.example"], "ServerAddresses": ["192.0.2.54"]],
            "Setup:/Network/Service/tunnel/DNS": [
                "SupplementalMatchDomains": ["vpn.example", "manual.example"], "ServerAddresses": ["127.0.0.1"],
            ],
        ], saved: ["tunnel": ["192.0.2.55"]], port: 53)
        XCTAssertEqual(routes.route(for: "host.vpn.example")?.servers, ["192.0.2.54"])
        XCTAssertEqual(routes.route(for: "host.manual.example")?.servers, ["192.0.2.55"])
    }

    func test_explicit_local_scope_keeps_other_bonjour_names_out_of_unicast() {
        let routes = DNSRoutes(state: [
            tunnel: ["SupplementalMatchDomains": ["corp.local", ""], "ServerAddresses": ["192.0.2.54"]],
        ], saved: [:], port: 53)
        XCTAssertEqual(routes.route(for: "host.corp.local")?.servers, ["192.0.2.54"])
        XCTAssertNil(routes.route(for: "printer.local"))
    }
}
