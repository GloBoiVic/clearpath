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
    enum Mode { case normal, fail, noAAAA, truncated, wrongID, wrongQuestion, blockedAlias, safeAlias, big, partialTC,
             safeRedirect, safeBlocked, safeFork, safeLoop, safeChain }
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
        let edge = DNSName("edge.example"), cname = { (from: DNSName, to: String) in DNSRecord(name: from, type: 5, cname: DNSName(to)) }
        switch mode {
        case .safeRedirect: records = [cname(query.name, "www.google.com"), DNSRecord(name: DNSName("www.google.com"), type: 1, data: [192,0,2,99])]
        case .safeBlocked: records = [cname(query.name, "adult.example"), DNSRecord(name: DNSName("adult.example"), type: 1, data: [192,0,2,99])]
        case .safeFork: records = [cname(query.name, "edge.example"), cname(query.name, "other.example"), DNSRecord(name: edge, type: 1, data: [192,0,2,7])]
        case .safeLoop: records = [cname(query.name, "edge.example"), cname(edge, query.name.host!)]
        case .safeChain: records = [cname(query.name, "edge.example"), DNSRecord(name: edge, type: 1, data: [192,0,2,7]), DNSRecord(name: DNSName("stray.example"), type: 1, data: [192,0,2,99])]
        default: break
        }
        var response = query.response(answers: records)
        if mode == .wrongID { response[0] ^= 1 }
        return response
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; change(&stored) }
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
        XCTAssertEqual(try examplePolicy().digest, "43f822f88174ad7e6be6e9d51f5c079af1af9a5c4925908737e365105c88e79d")
    }
}

final class ResolverTests: XCTestCase {
    func testBlockedLookupsPublishOnlyForBlockedQueriesAndAliases() async throws {
        let notices = LockedValue(0)
        let resolver = Resolver(policy: try examplePolicy(), onBlocked: {
            notices.update { $0 += 1 }
        })
        _ = await resolver.resolve(DNSMessage.query("adult.example", type: 1), tcp: false, upstream: Fixture())
        _ = await resolver.resolve(DNSMessage.query("alias.example", type: 1), tcp: false, upstream: Fixture(.blockedAlias))
        _ = await resolver.resolve(DNSMessage.query("allowed.example", type: 1), tcp: false, upstream: Fixture())
        XCTAssertEqual(notices.read(), 2)
    }

    func testCheckNamesAreAnsweredByTheFilterWithItsMarkerAndNeverForwarded() async throws {
        // #76: a VPN in front of Clearpath proves it forwards to Clearpath when this marker comes back.
        let notices = LockedValue(0)
        let resolver = Resolver(policy: try examplePolicy(), onBlocked: { notices.update { $0 += 1 } }), fixture = Fixture()
        for tcp in [false, true] {
            let check = try DNSMessage(await resolver.resolve(DNSMessage.query("3f9a1c.Resolver-Check.example", type: 16), tcp: tcp, upstream: fixture))
            XCTAssertEqual(check.rcode, 0)
            XCTAssertEqual(check.answers.map(\.type), [16])
            XCTAssertEqual(check.answers.first?.data, FilterCheck.marker)
            XCTAssertEqual(check.answers.first?.ttl, 0)
            let other = try DNSMessage(await resolver.resolve(DNSMessage.query("3f9a1c.resolver-check.example", type: 1), tcp: tcp, upstream: fixture))
            XCTAssertEqual(other.rcode, 0); XCTAssertTrue(other.answers.isEmpty)
        }
        let calls = await fixture.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(notices.read(), 0)
        XCTAssertEqual(FilterCheck.marker, [9] + Array("clearpath".utf8))
    }

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
    func testSafeTargetRedirectsFailClosed() async throws {
        let resolver = Resolver(policy: try examplePolicy())
        for mode: Fixture.Mode in [.safeRedirect, .safeBlocked, .safeFork, .safeLoop] {
            for tcp in [false, true] {
                let result = try DNSMessage(await resolver.resolve(DNSMessage.query("www.google.com", type: 1), tcp: tcp, upstream: Fixture(mode)))
                XCTAssertEqual(result.rcode, 2, "\(mode)"); XCTAssertTrue(result.answers.isEmpty)
            }
        }
        let chained = try DNSMessage(await resolver.resolve(DNSMessage.query("www.google.com", type: 1), tcp: false, upstream: Fixture(.safeChain)))
        XCTAssertEqual(chained.rcode, 0)
        XCTAssertEqual(chained.answers.map(\.type), [5, 5, 1])
        XCTAssertEqual(chained.answers.last?.data, [192,0,2,7])
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

final class BlockNoticeGateTests: XCTestCase {
    func testSuppressesBurstsWithoutKeepingCounts() {
        let clock = LockedValue(Date(timeIntervalSince1970: 100))
        let publications = LockedValue(0)
        let gate = BlockNoticeGate(minimumInterval: 30, now: {
            clock.read()
        }, publish: {
            publications.update { $0 += 1 }
        })
        gate.blockedLookup()
        gate.blockedLookup()
        clock.update { $0.addTimeInterval(29) }
        gate.blockedLookup()
        clock.update { $0.addTimeInterval(1) }
        gate.blockedLookup()
        XCTAssertEqual(publications.read(), 2)
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
    func testServiceBindingRDATAValidated() throws {
        func response(_ rdata: [UInt8], type: UInt16) throws -> DNSMessage {
            let query = try DNSMessage(DNSMessage.query("example.com", type: type))
            return try DNSMessage(query.response(answers: [DNSRecord(name: query.name, type: type, data: rdata)]))
        }
        for type: UInt16 in [64, 65] {
            XCTAssertNoThrow(try response([0,1,0], type: type))
            XCTAssertNoThrow(try response([0,1,3,99,100,110,7,101,120,97,109,112,108,101,0, 0,1,0,3,2,104,50], type: type))  // cdn.example, alpn=h2
            let bad: [[UInt8]] = [[], [0], [0,1], [0,1,0xC0,0x0C], [0,1,5,1,2], [0,1,0, 0,1,0,9,1], [0,1,0, 0,1], [0,1,0, 0,3,0,0, 0,1,0,0]]
            for rdata in bad { XCTAssertThrowsError(try response(rdata, type: type), "\(rdata)") }
        }
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
