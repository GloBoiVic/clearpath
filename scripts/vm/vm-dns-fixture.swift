// vm-dns-fixture: a synthetic DNS resolver for the disposable VM. Never forwards to a public server.
// Usage: vm-dns-fixture answer IP PORT
//          answers every A question with 192.0.2.42 and anything else with an empty NOERROR.
//        vm-dns-fixture vpn IP PORT SUFFIX [TARGET-IP TARGET-PORT]
//          stands in for a VPN resolver such as Tailscale MagicDNS: names under SUFFIX get
//          100.64.0.7; everything else is forwarded to TARGET, or by default to the first DNS
//          server configured on the primary network service, read again for every question,
//          the way Tailscale reads the interface DNS (#73).
// Each question is logged to standard output as "<mode> <name> <type> [via <server>]".
import Foundation
import SystemConfiguration

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var value = sockaddr_in()
    value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    value.sin_family = sa_family_t(AF_INET)
    value.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &value.sin_addr) == 1 else { fail("not an IPv4 address: \(ip)") }
    return value
}

/// The question's name and type, or nil for anything that isn't one plain question.
func question(_ packet: [UInt8]) -> (name: String, type: UInt16, end: Int)? {
    guard packet.count >= 12, packet[2] & 0x80 == 0, packet[4] == 0, packet[5] == 1 else { return nil }
    var labels: [String] = []
    var index = 12
    while index < packet.count {
        let length = Int(packet[index])
        if length == 0 { break }
        guard length < 64, index + 1 + length < packet.count else { return nil }
        labels.append(String(decoding: packet[(index + 1)...(index + length)], as: UTF8.self).lowercased())
        index += 1 + length
    }
    guard index + 5 <= packet.count else { return nil }
    let type = UInt16(packet[index + 1]) << 8 | UInt16(packet[index + 2])
    return (labels.joined(separator: "."), type, index + 5)
}

/// A response to the question with an optional A record for it.
func answer(_ packet: [UInt8], end: Int, a: [UInt8]?) -> [UInt8] {
    var reply = Array(packet[0..<end])
    reply[2] = 0x80 | (packet[2] & 0x01) | 0x04  // response, keep RD, authoritative
    reply[3] = 0x80                                 // RA, NOERROR
    reply[6] = 0; reply[7] = a == nil ? 0 : 1
    reply[8] = 0; reply[9] = 0; reply[10] = 0; reply[11] = 0
    if let a { reply += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4] + a }
    return reply
}

func primaryServiceDNS() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "vm-dns-fixture" as CFString, nil, nil),
          let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let id = global["PrimaryService"] as? String else { return nil }
    for key in ["Setup:/Network/Service/\(id)/DNS", "State:/Network/Service/\(id)/DNS"] {
        if let dns = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
           let first = (dns["ServerAddresses"] as? [String])?.first { return first }
    }
    return nil
}

func forward(_ packet: [UInt8], to ip: String, port: UInt16) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var target = address(ip, port)
    let sent = withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard sent == packet.count else { return nil }
    var reply = [UInt8](repeating: 0, count: 4096)
    let count = recv(fd, &reply, reply.count, 0)
    return count >= 12 ? Array(reply.prefix(count)) : nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, let port = UInt16(arguments[2]) else { fail("usage: see the header of vm-dns-fixture.swift") }
let mode = arguments[0]
guard mode == "answer" && arguments.count == 3 || mode == "vpn" && (arguments.count == 4 || arguments.count == 6) else {
    fail("usage: see the header of vm-dns-fixture.swift")
}
let suffix = mode == "vpn" ? arguments[3].lowercased() : ""
let fixedTarget: (String, UInt16)? = arguments.count == 6 ? (arguments[4], UInt16(arguments[5]) ?? 0) : nil
if let fixedTarget, fixedTarget.1 == 0 { fail("TARGET-PORT must be 1-65535") }

let fd = socket(AF_INET, SOCK_DGRAM, 0)
var local = address(arguments[1], port)
var reuse: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
guard withUnsafePointer(to: &local, {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}) == 0 else { fail("could not bind \(arguments[1]):\(port)") }
print("\(mode) fixture on \(arguments[1]):\(port)")
fflush(stdout)

let output = NSLock()
func log(_ line: String) { output.lock(); print(line); fflush(stdout); output.unlock() }

while true {
    var buffer = [UInt8](repeating: 0, count: 4096)
    var client = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let count = withUnsafeMutablePointer(to: &client) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
    }
    guard count > 0 else { continue }
    let packet = Array(buffer.prefix(count))
    guard let asked = question(packet) else { continue }
    let reply: (@escaping ([UInt8]) -> Void) -> Void = { body in
        DispatchQueue.global().async { body(packet) }
    }
    let clientCopy = client, lengthCopy = length
    func send(_ response: [UInt8]) {
        var to = clientCopy
        _ = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, response, response.count, 0, $0, lengthCopy) }
        }
    }
    if mode == "answer" {
        log("answer \(asked.name) \(asked.type)")
        send(answer(packet, end: asked.end, a: asked.type == 1 ? [192, 0, 2, 42] : nil))
    } else if asked.name == suffix || asked.name.hasSuffix("." + suffix) {
        log("vpn \(asked.name) \(asked.type)")
        send(answer(packet, end: asked.end, a: asked.type == 1 ? [100, 64, 0, 7] : nil))
    } else {
        // Forward on another thread, as a real resolver does, so a loop can build up.
        reply { packet in
            let (server, serverPort) = fixedTarget ?? (primaryServiceDNS() ?? "", 53)
            log("vpn \(asked.name) \(asked.type) via \(server)")
            guard !server.isEmpty, let response = forward(packet, to: server, port: serverPort) else {
                var failed = answer(packet, end: asked.end, a: nil)
                failed[3] = 0x82  // SERVFAIL, as Tailscale answers after its deadline
                send(failed)
                return
            }
            send(response)
        }
    }
}
