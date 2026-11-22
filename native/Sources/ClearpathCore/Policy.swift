import Foundation
import CryptoKit
import Darwin

public enum PolicyError: Error { case invalidSchema, invalidDomain, duplicateKey, tooLarge, conflict }

public struct Policy: Sendable {
    public enum Decision: Equatable, Sendable { case block, safe(String), allow }
    public let adult: Set<String>
    public let custom: Set<String>
    public let allow: Set<String>
    public let safeSearch: [String: String]
    public let digest: String
    public let data: Data

    public init(data: Data) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw PolicyError.tooLarge }
        let object = try JSONSerialization.jsonObject(with: data)
        var bytes = Array(data)
        if bytes.starts(with: [0xEF,0xBB,0xBF]) { bytes.removeFirst(3) }
        var scanner = JSONKeys(bytes: bytes)
        scanner.whitespace()
        guard scanner.i < bytes.count, bytes[scanner.i] == 123 else { throw PolicyError.invalidSchema }
        try scanner.scan()
        scanner.whitespace()
        guard scanner.i == bytes.count else { throw PolicyError.invalidSchema }
        guard let dict = object as? [String: Any],
              Set(dict.keys) == ["adult", "custom", "allow", "safesearch"],
              let adult = dict["adult"] as? [String], let custom = dict["custom"] as? [String],
              let allow = dict["allow"] as? [String], let safe = dict["safesearch"] as? [String: String]
        else { throw PolicyError.invalidSchema }
        self.adult = Set(try adult.map(Self.domain))
        self.custom = Set(try custom.map(Self.domain))
        self.allow = Set(try allow.map(Self.domain))
        var normalized: [String: String] = [:]
        for (name, target) in safe {
            let key = try Self.domain(name)
            guard normalized[key] == nil else { throw PolicyError.duplicateKey }
            normalized[key] = try Self.domain(target)
        }
        let allowed = self.allow
        guard Set(normalized.keys).isDisjoint(with: Set(normalized.values)),
              !normalized.keys.contains(where: { Self.matches($0, rules: allowed) })
        else { throw PolicyError.conflict }
        safeSearch = normalized
        self.data = data
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func domain(_ input: String) throws -> String {
        guard input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.isEmpty, !input.contains(where: { "/:@%?#[]\\".contains($0) })
        else { throw PolicyError.invalidDomain }
        var name = input.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        // Foundation performs the platform's IDNA conversion. Wire names use ASCII A-labels.
        if !name.utf8.allSatisfy({ $0 < 128 }) {
            guard let host = URL(string: "https://\(name)/")?.host else { throw PolicyError.invalidDomain }
            name = host
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  let bytes = Array(label.utf8)
                  return (1...63).contains(bytes.count) && bytes.first != 45 && bytes.last != 45 &&
                      bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw PolicyError.invalidDomain }
        var v4 = in_addr()
        guard inet_pton(AF_INET, name, &v4) != 1 else { throw PolicyError.invalidDomain }
        return name
    }

    public static func matches(_ name: String, rules: Set<String>) -> Bool {
        var suffix = name[...]
        while true {
            if rules.contains(String(suffix)) { return true }
            guard let dot = suffix.firstIndex(of: ".") else { return false }
            suffix = suffix[suffix.index(after: dot)...]
        }
    }

    public func decide(_ input: String) -> Decision {
        guard let name = try? Self.domain(input) else { return .allow }
        if Self.matches(name, rules: custom) { return .block }
        if let target = safeSearch[name] { return .safe(target) }
        if Self.matches(name, rules: allow) { return .allow }
        return Self.matches(name, rules: adult) ? .block : .allow
    }
}

// JSONSerialization validates grammar but accepts duplicate keys. Scan the validated
// document once to reject ambiguous keys, including escaped spellings of the same key.
private struct JSONKeys {
    let bytes: [UInt8]
    var i = 0
    mutating func whitespace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
    mutating func string() throws -> String {
        let start = i
        i += 1
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 92 { i += 1 }
            else if b == 34 {
                guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: .fragmentsAllowed) as? String else { throw PolicyError.invalidSchema }
                return value
            }
        }
        throw PolicyError.invalidSchema
    }
    mutating func scan(_ depth: Int = 0) throws {
        guard depth < 32 else { throw PolicyError.invalidSchema }
        whitespace()
        guard i < bytes.count else { throw PolicyError.invalidSchema }
        if bytes[i] == 123 {
            i += 1; whitespace(); var keys = Set<String>()
            if bytes[i] == 125 { i += 1; return }
            while true {
                whitespace(); let key = try string()
                guard keys.insert(key).inserted else { throw PolicyError.duplicateKey }
                whitespace(); i += 1
                try scan(depth + 1); whitespace()
                if bytes[i] == 125 { i += 1; return }
                i += 1
            }
        } else if bytes[i] == 91 {
            i += 1; whitespace()
            if bytes[i] == 93 { i += 1; return }
            while true {
                try scan(depth + 1); whitespace()
                if bytes[i] == 93 { i += 1; return }
                i += 1
            }
        } else if bytes[i] == 34 { _ = try string() }
        else { while i < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 } }
    }
}
