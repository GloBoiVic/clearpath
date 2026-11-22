import Foundation

public enum DNSError: Error { case malformed, unsupported, oversized, mismatch, timeout, closed }

public struct DNSName: Equatable, Hashable, Sendable {
    public let labels: [[UInt8]]
    public init(_ host: String) { labels = host.split(separator: ".").map { Array($0.utf8) } }
    init(labels: [[UInt8]]) { self.labels = labels }
    public var host: String? {
        guard labels.allSatisfy({ $0.allSatisfy { $0 > 32 && $0 < 127 && $0 != 46 && $0 != 92 } }) else { return nil }
        return labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ".").lowercased()
    }
    public var wire: [UInt8] { labels.flatMap { [UInt8($0.count)] + $0 } + [0] }
}

public struct DNSRecord: Sendable {
    public let name: DNSName
    public let type: UInt16
    public let klass: UInt16
    public let ttl: UInt32
    public let data: [UInt8]
    public let cname: DNSName?
    public init(name: DNSName, type: UInt16, klass: UInt16 = 1, ttl: UInt32 = 60, data: [UInt8] = [], cname: DNSName? = nil) {
        self.name = name; self.type = type; self.klass = klass; self.ttl = ttl; self.data = data; self.cname = cname
    }
    var wire: [UInt8] {
        let body = cname?.wire ?? data
        var packet = name.wire
        packet.append(contentsOf: u16(type))
        packet.append(contentsOf: u16(klass))
        packet.append(contentsOf: u32(ttl))
        packet.append(contentsOf: u16(UInt16(body.count)))
        packet.append(contentsOf: body)
        return packet
    }
}

func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 255)] }
func u32(_ v: UInt32) -> [UInt8] { u16(UInt16(v >> 16)) + u16(UInt16(v & 65535)) }

private struct DNSReader {
    let bytes: [UInt8]
    var i = 0
    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, i <= bytes.count, n <= bytes.count - i else { throw DNSError.malformed }
        defer { i += n }; return Array(bytes[i..<i+n])
    }
    mutating func short() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
    mutating func long() throws -> UInt32 { let a = try short(); return UInt32(a) << 16 | UInt32(try short()) }
    mutating func name() throws -> DNSName {
        var cursor = i, labels: [[UInt8]] = [], visited = Set<Int>(), end: Int?, length = 1
        while true {
            guard cursor < bytes.count, visited.insert(cursor).inserted, visited.count <= 128 else { throw DNSError.malformed }
            let n = Int(bytes[cursor])
            if n & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { throw DNSError.malformed }
                if end == nil { end = cursor + 2 }
                let next = ((n & 63) << 8) | Int(bytes[cursor + 1])
                guard next >= 12, next < cursor else { throw DNSError.malformed }
                cursor = next
            } else {
                guard n <= 63, cursor + 1 + n <= bytes.count else { throw DNSError.malformed }
                cursor += 1
                if n == 0 { i = end ?? cursor; return DNSName(labels: labels) }
                length += n + 1
                guard length <= 255 else { throw DNSError.malformed }
                labels.append(Array(bytes[cursor..<cursor+n])); cursor += n
            }
        }
    }
    mutating func record() throws -> DNSRecord {
        let owner = try name(), type = try short(), klass = try short(), ttl = try long(), size = Int(try short())
        let start = i
        let alias = type == 5 ? try name() : nil
        if alias != nil && i != start + size { throw DNSError.malformed }
        i = start
        let data = try take(size)
        if (type == 1 && size != 4) || (type == 28 && size != 16) { throw DNSError.malformed }
        if (type == 64 || type == 65) && !Self.validServiceBinding(data) { throw DNSError.malformed }
        return DNSRecord(name: owner, type: type, klass: klass, ttl: ttl, data: data, cname: alias)
    }
    /// SVCB/HTTPS RDATA (RFC 9460): priority, an uncompressed target name, then
    /// key/length/value parameters in strictly increasing key order, all inside RDATA.
    static func validServiceBinding(_ data: [UInt8]) -> Bool {
        var i = 2, length = 1
        while true {
            guard i < data.count else { return false }
            let n = Int(data[i]); i += 1
            if n == 0 { break }
            length += n + 1
            guard n <= 63, n <= data.count - i, length <= 255 else { return false }  // n > 63 also rejects pointers
            i += n
        }
        var previous = -1
        while i < data.count {
            guard data.count - i >= 4 else { return false }
            let key = Int(data[i]) << 8 | Int(data[i+1]), size = Int(data[i+2]) << 8 | Int(data[i+3])
            i += 4
            guard key > previous, size <= data.count - i else { return false }
            previous = key; i += size
        }
        return true
    }
}

public struct DNSMessage: Sendable {
    public let wire: [UInt8]
    public let id: UInt16
    public let flags: UInt16
    public let name: DNSName
    public let type: UInt16
    public let klass: UInt16
    public let answers: [DNSRecord]
    public let additional: [DNSRecord]
    public var rcode: UInt16 { flags & 15 }
    public var truncated: Bool { flags & 0x200 != 0 }
    public var udpLimit: Int { max(512, min(1232, Int(additional.first(where: { $0.type == 41 })?.klass ?? 512))) }

    public init(_ wire: [UInt8]) throws {
        guard (12...65535).contains(wire.count) else { throw DNSError.malformed }
        var r = DNSReader(bytes: wire)
        id = try r.short(); flags = try r.short()
        let q = try r.short(), a = Int(try r.short()), ns = Int(try r.short()), ar = Int(try r.short())
        guard q == 1, a + ns + ar <= 4096 else { throw DNSError.malformed }
        name = try r.name(); type = try r.short(); klass = try r.short()
        // A truncated UDP response can end mid-record. Identity and question are
        // still checked before TCP retry; incomplete sections are never forwarded.
        if flags & 0x8200 == 0x8200 {
            answers = []; additional = []; self.wire = wire; return
        }
        answers = try (0..<a).map { _ in try r.record() }
        for _ in 0..<ns { _ = try r.record() }
        additional = try (0..<ar).map { _ in try r.record() }
        guard r.i == wire.count else { throw DNSError.malformed }
        self.wire = wire
    }
    public func validateQuery() throws {
        guard flags & 0xF800 == 0, answers.isEmpty else { throw DNSError.unsupported }
    }
    public func validateResponse(to query: DNSMessage) throws {
        guard flags & 0x8000 != 0, flags & 0x7800 == query.flags & 0x7800,
              id == query.id, name.host == query.name.host, name.labels.map({ $0.map(asciiLower) }) == query.name.labels.map({ $0.map(asciiLower) }),
              type == query.type, klass == query.klass else { throw DNSError.mismatch }
    }
    public func response(code: UInt16 = 0, answers: [DNSRecord] = [], truncated: Bool = false) -> [UInt8] {
        let flags: UInt16 = 0x8080 | (self.flags & 0x0100) | (truncated ? 0x0200 : 0) | code
        var packet = u16(id)
        packet.append(contentsOf: u16(flags))
        packet.append(contentsOf: u16(1))
        packet.append(contentsOf: u16(UInt16(answers.count)))
        packet.append(contentsOf: [0,0,0,0])
        packet.append(contentsOf: name.wire)
        packet.append(contentsOf: u16(type))
        packet.append(contentsOf: u16(klass))
        for record in answers { packet.append(contentsOf: record.wire) }
        return packet
    }
    public static func query(_ host: String, type: UInt16, id: UInt16 = .random(in: .min ... .max)) -> [UInt8] {
        var packet = u16(id)
        packet.append(contentsOf: [1,0,0,1,0,0,0,0,0,0])
        packet.append(contentsOf: DNSName(host).wire)
        packet.append(contentsOf: u16(type))
        packet.append(contentsOf: [0,1])
        return packet
    }
    public static func error(for packet: [UInt8], code: UInt16) -> [UInt8] {
        Array((packet + [0,0]).prefix(2)) + u16(0x8000 | code) + [0,0,0,0,0,0,0,0]
    }
}

private func asciiLower(_ c: UInt8) -> UInt8 { (65...90).contains(c) ? c + 32 : c }

/// Incremental DNS-over-TCP framing; supports split frames and pipelined messages.
public struct DNSStream: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public var hasPartialFrame: Bool { !buffer.isEmpty }
    public mutating func append(_ bytes: [UInt8]) throws -> [[UInt8]] {
        guard buffer.count + bytes.count <= 262144 else { throw DNSError.oversized }
        buffer += bytes; var messages: [[UInt8]] = []; var offset = 0
        while buffer.count - offset >= 2 {
            let n = Int(buffer[offset]) << 8 | Int(buffer[offset+1])
            guard n >= 12 else { throw DNSError.malformed }
            guard buffer.count - offset >= n + 2 else { break }
            guard messages.count < 64 else { throw DNSError.oversized }
            messages.append(Array(buffer[offset+2..<offset+n+2])); offset += n+2
        }
        buffer.removeFirst(offset)
        return messages
    }
    public static func frame(_ packet: [UInt8]) throws -> [UInt8] {
        guard (12...65535).contains(packet.count) else { throw DNSError.oversized }
        return u16(UInt16(packet.count)) + packet
    }
}
