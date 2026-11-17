import XCTest
@testable import ClearpathCore

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func examplePolicy() throws -> Policy { try Policy(data: Data(contentsOf: repository.appendingPathComponent("policy.example.json"))) }
func changedPolicy(_ change: (inout [String: Any]) -> Void) throws -> Policy {
    var object = try JSONSerialization.jsonObject(with: examplePolicy().data) as! [String: Any]
    change(&object)
    return try Policy(data: JSONSerialization.data(withJSONObject: object))
}

actor Fixture: DNSUpstream {
    enum Mode { case normal, fail, noAAAA, truncated, wrongID, wrongQuestion, blockedAlias, safeAlias, big, partialTC }
    var calls: [(String?, UInt16, Bool)] = []
    let mode: Mode
    init(_ mode: Mode = .normal) { self.mode = mode }
    func exchange(_ packet: [UInt8], tcp: Bool) async throws -> [UInt8] {
        let query = try DNSMessage(packet)
        calls.append((query.name.host, query.type, tcp))
        if mode == .fail { throw DNSError.timeout }
        if (mode == .truncated || mode == .partialTC) && !tcp {
            var response = query.response(truncated: true)
            if mode == .partialTC { response[7] = 1; response += [0xC0] }
            return response
        }
        if mode == .wrongQuestion { return try DNSMessage(DNSMessage.query("wrong.example", type: query.type, id: query.id)).response() }
        let rr = DNSRecord(name: query.name, type: query.type == 28 ? 28 : 1,
                           data: query.type == 28 ? Array(repeating: 0, count: 15) + [1] : [192,0,2,42])
        var records = [rr]
        if mode == .noAAAA && query.type == 28 { records = [] }
        if mode == .blockedAlias || mode == .safeAlias {
            records = [DNSRecord(name: query.name, type: 5, cname: DNSName(mode == .blockedAlias ? "adult.example" : "www.google.com"))]
        }
        if mode == .big { records = (0..<20).map { _ in rr } }
        var response = query.response(answers: records)
        if mode == .wrongID { response[0] ^= 1 }
        return response
    }
}

final class PolicyTests: XCTestCase {
    func testSharedPythonCorpus() throws {
        let policy = try examplePolicy()
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("tests/fixtures/policy-cases.json"))) as! [[String: String]]
        for entry in cases {
            let value: String
            switch policy.decide(entry["host"]!) {
            case .allow: value = "allow"
            case .block: value = "block"
            case .safe(let target): value = "safe:" + target
            }
            XCTAssertEqual(value, entry["decision"], entry["host"]!)
        }
    }
    func testIDNAAndDomainValidation() throws {
        XCTAssertEqual(try Policy.domain("BÜCHER.example."), "xn--bcher-kva.example")
        for bad in ["*.example.com", "http://example.com", "", "a..com", "com", "a.com..", "a.com ", "127.0.0.1", "x@y.com", "a_foo.com", String(repeating: "x", count: 64) + ".com"] {
            XCTAssertThrowsError(try Policy.domain(bad), bad)
        }
    }
    func testPrecedence() throws {
        let policy = try changedPolicy { object in
            object["allow"] = ["sub.adult.example"]
            object["custom"] = ["private.sub.adult.example", "www.google.com"]
        }
        XCTAssertEqual(policy.decide("sub.adult.example"), .allow)
        XCTAssertEqual(policy.decide("private.sub.adult.example"), .block)
        XCTAssertEqual(policy.decide("www.google.com"), .block)
    }
    func testRejectAmbiguousJSONAndConflicts() throws {
        for bad in ["{}", "[]", "{\"adult\":[],\"adult\":[]}", "{\"adult\":[],\"\\u0061dult\":[]}", "{\"adult\":["] {
            XCTAssertThrowsError(try Policy(data: Data(bad.utf8)))
        }
        XCTAssertThrowsError(try Policy(data: Data([0xEF,0xBB,0xBF]) + Data("{\"adult\":[],\"adult\":[]}".utf8)))
        XCTAssertThrowsError(try changedPolicy { $0["allow"] = ["google.com"] })
        XCTAssertThrowsError(try changedPolicy { $0["safesearch"] = ["one.example": "two.example", "two.example": "one.example"] })
    }
    func testDigestMatchesReference() throws {
        XCTAssertEqual(try examplePolicy().digest, "2a493ed5aea556232f6c1817d3db3e8fa3b68bc79e5a45796c66d464cf6b5429")
    }
}

final class ResolverTests: XCTestCase {
    func testBlockedDomainsNeverReachUpstream() async throws {
        let resolver = Resolver(policy: try examplePolicy()), fixture = Fixture()
        for host in ["adult.example", "sub.adult.example", "blocked.example", "pornhub.com"] {
            for type: UInt16 in [1,28,65,64,16] {
                for tcp in [true,false] {
                    let result = try DNSMessage(await resolver.resolve(DNSMessage.query(host, type: type), tcp: tcp, upstream: fixture))
                    XCTAssertEqual(result.rcode, 3); XCTAssertTrue(result.answers.isEmpty)
                }
            }
        }
        let calls = await fixture.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testSafeSearchIPv4IPv6AllMappings() async throws {
        let policy = try examplePolicy(), fixture = Fixture()
        for (name,target) in policy.safeSearch {
            for type: UInt16 in [1,28] {
                for tcp in [false,true] {
                    let query = DNSMessage.query(name, type: type)
                    let result = try DNSMessage(await Resolver(policy: policy).resolve(query, tcp: tcp, upstream: fixture))
                    XCTAssertEqual(result.id, try DNSMessage(query).id)
                    XCTAssertEqual(result.answers.first?.cname?.host, target)
                    XCTAssertEqual(result.answers.last?.type, type)
                    XCTAssertEqual(result.flags & 0x20, 0)
                }
            }
        }
        let calls = await fixture.calls
        XCTAssertFalse(calls.contains { $0.0.map { policy.safeSearch[$0] != nil } == true })
    }
    func testSafeOutageAndNoAAAA() async throws {
        let resolver = Resolver(policy: try examplePolicy()), failed = Fixture(.fail), noAAAA = Fixture(.noAAAA)
        let bad = try DNSMessage(await resolver.resolve(DNSMessage.query("www.google.com", type: 1), tcp: false, upstream: failed))
        XCTAssertEqual(bad.rcode, 2)
        let calls = await failed.calls; XCTAssertEqual(calls.first?.0, "forcesafesearch.google.com")
        let result = try DNSMessage(await resolver.resolve(DNSMessage.query("www.google.com", type: 28), tcp: false, upstream: noAAAA))
        XCTAssertEqual(result.rcode, 0); XCTAssertEqual(result.answers.count, 1); XCTAssertEqual(result.answers[0].type, 5)
    }
    func testSafeHTTPSHintsAndCNAME() async throws {
        let resolver = Resolver(policy: try examplePolicy()), fixture = Fixture()
        for type: UInt16 in [64,65,16] {
            let result = try DNSMessage(await resolver.resolve(DNSMessage.query("www.google.com", type: type), tcp: false, upstream: fixture))
            XCTAssertTrue(result.answers.isEmpty); XCTAssertEqual(result.rcode, 0)
        }
        let result = try DNSMessage(await resolver.resolve(DNSMessage.query("www.google.com", type: 5), tcp: false, upstream: fixture))
        XCTAssertEqual(result.answers[0].cname?.host, "forcesafesearch.google.com")
        let calls = await fixture.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testAliasesCannotReturnUnsafeAddresses() async throws {
        let resolver = Resolver(policy: try examplePolicy())
        for (mode,expected): (Fixture.Mode, UInt16) in [(.blockedAlias,3),(.safeAlias,2)] {
            let result = try DNSMessage(await resolver.resolve(DNSMessage.query("alias.example", type: 1), tcp: false, upstream: Fixture(mode)))
            XCTAssertEqual(result.rcode, expected)
        }
    }
    func testNormalDevelopmentDomains() async throws {
        let resolver = Resolver(policy: try examplePolicy()), fixture = Fixture()
        for host in ["github.com", "registry.npmjs.org", "pypi.org", "registry-1.docker.io", "localhost", "db.internal", "_postgresql._tcp.dev.example"] {
            let result = try DNSMessage(await resolver.resolve(DNSMessage.query(host, type: 1), tcp: false, upstream: fixture))
            XCTAssertEqual(result.rcode, 0); XCTAssertEqual(result.answers.first?.data, [192,0,2,42])
        }
    }
    func testTruncatedUpstreamIncludingPartialRecordRetriesTCP() async throws {
        let resolver = Resolver(policy: try examplePolicy())
        for mode: Fixture.Mode in [.truncated, .partialTC] {
            let fixture = Fixture(mode)
            let result = try DNSMessage(await resolver.resolve(DNSMessage.query("github.com", type: 1), tcp: false, upstream: fixture))
            XCTAssertEqual(result.rcode, 0); XCTAssertFalse(result.truncated)
            let calls = await fixture.calls; XCTAssertEqual(calls.map(\.2), [false,true])
        }
    }
    func testWrongIDOrQuestionRejected() async throws {
        for mode: Fixture.Mode in [.wrongID,.wrongQuestion] {
            let result = try DNSMessage(await Resolver(policy: examplePolicy()).resolve(DNSMessage.query("github.com", type: 1), tcp: false, upstream: Fixture(mode)))
            XCTAssertEqual(result.rcode, 2)
        }
    }
    func testLargeUDPTruncatesButTCPReturnsFullAnswer() async throws {
        let resolver = Resolver(policy: try examplePolicy()), query = DNSMessage.query("github.com", type: 1)
        let udp = try DNSMessage(await resolver.resolve(query, tcp: false, upstream: Fixture(.big)))
        let tcp = try DNSMessage(await resolver.resolve(query, tcp: true, upstream: Fixture(.big)))
        XCTAssertTrue(udp.truncated); XCTAssertFalse(tcp.truncated); XCTAssertEqual(tcp.answers.count, 20)
    }
    func testMalformedReturnsFORMERR() async throws {
        let fixture = Fixture(), resolver = Resolver(policy: try examplePolicy())
        let query = DNSMessage.query("adult.example", type: 1)
        for length in 0..<query.count {
            let result = await resolver.resolve(Array(query.prefix(length)), tcp: false, upstream: fixture)
            XCTAssertEqual(result[3] & 15, 1)
        }
        let calls = await fixture.calls; XCTAssertTrue(calls.isEmpty)
    }
}

final class WireTests: XCTestCase {
    func testEDNSRewriteDoesNotKeepOPTOrAD() throws {
        var query = DNSMessage.query("www.google.com", type: 1)
        query[3] = 0x20; query[11] = 1
        query += [0,0,41,4,208,0,0,128,0,0,0]
        let parsed = try DNSMessage(query)
        XCTAssertEqual(parsed.udpLimit, 1232)
        let response = try DNSMessage(parsed.response(code: 3))
        XCTAssertEqual(response.flags & 0x20, 0); XCTAssertTrue(response.additional.isEmpty)
        XCTAssertEqual(response.wire.count, query.count - 11)
    }
    func testCompressionCycleAndTrailingGarbageRejected() throws {
        XCTAssertThrowsError(try DNSMessage([0,1,1,0,0,1,0,0,0,0,0,0,0xC0,0x0C,0,1,0,1]))
        XCTAssertThrowsError(try DNSMessage(DNSMessage.query("example.com", type: 1) + [0]))
    }
    func testStreamFragmentationAndPipeline() throws {
        let packet = DNSMessage.query("example.com", type: 28)
        let bytes = try DNSStream.frame(packet) + DNSStream.frame(packet)
        var stream = DNSStream(), messages: [[UInt8]] = []
        for byte in bytes { messages += try stream.append([byte]) }
        XCTAssertEqual(messages, [packet,packet]); XCTAssertFalse(stream.hasPartialFrame)
        XCTAssertThrowsError(try stream.append([0,0]))
    }
    func testStreamPipelineBound() throws {
        let packet = try DNSStream.frame(DNSMessage.query("example.com", type: 1))
        var stream = DNSStream()
        XCTAssertThrowsError(try stream.append(Array(repeating: packet, count: 65).flatMap { $0 }))
    }
    func testMalformedRandomPacketsDoNotCrash() {
        var state: UInt64 = 0x12345678
        for length in 0..<512 {
            let bytes: [UInt8] = (0..<length).map { _ in
                state = state &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: state >> 32)
            }
            _ = try? DNSMessage(bytes)
        }
    }
}

final class PreferencesMock: ProxyPreferences {
    var state: DNSProxyConfiguration?
    var saves = 0
    var failSave = false
    var failRollback = false
    var replaceDuringSave = false
    var events: [String] = []
    func load() async throws -> DNSProxyConfiguration? { events.append("load"); return state }
    func save(_ config: DNSProxyConfiguration) async throws {
        events.append(config.enabled ? "enable" : "disable"); saves += 1; state = config
        if replaceDuringSave {
            state = DNSProxyConfiguration(providerID: "another.provider", enabled: true, policyData: Data())
            throw DNSError.closed
        }
        if (failSave && saves == 1) || (failRollback && saves > 1) { throw DNSError.closed }
    }
    func remove() async throws { events.append("remove"); if failRollback { throw DNSError.closed }; state = nil }
}
final class ExtensionMock: ExtensionRequests {
    let preferences: PreferencesMock
    var result: ExtensionResult = .completed
    init(_ preferences: PreferencesMock) { self.preferences = preferences }
    func activate() async throws -> ExtensionResult { preferences.events.append("activate"); return result }
    func deactivate() async throws -> ExtensionResult { preferences.events.append("deactivate-extension"); return result }
}
final class LifecycleTests: XCTestCase {
    func testActivateAndIdempotentRetry() async throws {
        let p = PreferencesMock(), policy = try examplePolicy()
        let controller = Lifecycle(preferences: p, extensions: ExtensionMock(p))
        let first = try await controller.activate(policy: policy)
        let second = try await controller.activate(policy: policy)
        XCTAssertEqual(first, .completed); XCTAssertEqual(second, .completed)
        XCTAssertEqual(p.saves, 1); XCTAssertEqual(p.state?.policyData, policy.data)
    }
    func testFailedSaveRestoresOriginal() async throws {
        let p = PreferencesMock(), policy = try examplePolicy()
        let original = DNSProxyConfiguration(enabled: false, policyData: policy.data)
        p.state = original; p.failSave = true
        do { _ = try await Lifecycle(preferences: p, extensions: ExtensionMock(p)).activate(policy: policy); XCTFail() } catch {}
        XCTAssertEqual(p.state, original); XCTAssertEqual(p.saves, 2)
    }
    func testFailedFirstSaveRemovesOnlyNewConfig() async throws {
        let p = PreferencesMock(); p.failSave = true
        do { _ = try await Lifecycle(preferences: p, extensions: ExtensionMock(p)).activate(policy: examplePolicy()); XCTFail() } catch {}
        XCTAssertNil(p.state); XCTAssertTrue(p.events.contains("remove"))
    }
    func testRollbackFailureReported() async throws {
        let p = PreferencesMock(); p.failSave = true; p.failRollback = true
        do { _ = try await Lifecycle(preferences: p, extensions: ExtensionMock(p)).activate(policy: examplePolicy()); XCTFail() }
        catch { XCTAssertEqual(error as? LifecycleError, .rollbackFailed) }
    }
    func testForeignConfigNeverModified() async throws {
        let p = PreferencesMock(); p.state = DNSProxyConfiguration(providerID: "another.provider", enabled: true, policyData: Data())
        let controller = Lifecycle(preferences: p, extensions: ExtensionMock(p))
        do { _ = try await controller.activate(policy: examplePolicy()); XCTFail() } catch {}
        do { try await controller.deactivate(); XCTFail() } catch {}
        do { _ = try await controller.uninstall(); XCTFail() } catch {}
        XCTAssertEqual(p.saves, 0); XCTAssertFalse(p.events.contains("remove")); XCTAssertFalse(p.events.contains("deactivate-extension"))
    }
    func testRollbackDoesNotOverwriteConcurrentChange() async throws {
        let p = PreferencesMock(); p.replaceDuringSave = true
        do { _ = try await Lifecycle(preferences: p, extensions: ExtensionMock(p)).activate(policy: examplePolicy()); XCTFail() }
        catch { XCTAssertEqual(error as? LifecycleError, .rollbackFailed) }
        XCTAssertEqual(p.state?.providerID, "another.provider")
        XCTAssertFalse(p.events.contains("remove")); XCTAssertEqual(p.saves, 1)
    }
    func testRebootRequiredDoesNotEnablePreferences() async throws {
        let p = PreferencesMock(), ext = ExtensionMock(p); ext.result = .rebootRequired
        let result = try await Lifecycle(preferences: p, extensions: ext).activate(policy: examplePolicy())
        XCTAssertEqual(result, .rebootRequired); XCTAssertNil(p.state); XCTAssertEqual(p.saves, 0)
    }
    func testUninstallOrderAndIdempotence() async throws {
        let p = PreferencesMock(); p.state = DNSProxyConfiguration(enabled: true, policyData: try examplePolicy().data)
        let controller = Lifecycle(preferences: p, extensions: ExtensionMock(p))
        _ = try await controller.uninstall()
        XCTAssertNil(p.state)
        XCTAssertLessThan(p.events.firstIndex(of: "disable")!, p.events.firstIndex(of: "remove")!)
        XCTAssertLessThan(p.events.firstIndex(of: "remove")!, p.events.firstIndex(of: "deactivate-extension")!)
        try await controller.deactivate()
    }
    func testPolicyUpdateRequiresDeactivation() async throws {
        let p = PreferencesMock(); p.state = DNSProxyConfiguration(enabled: true, policyData: try examplePolicy().data)
        let candidate = try changedPolicy { $0["custom"] = ["new.example"] }
        do { _ = try await Lifecycle(preferences: p, extensions: ExtensionMock(p)).activate(policy: candidate); XCTFail() } catch {}
        XCTAssertEqual(p.saves, 0)
    }
}
