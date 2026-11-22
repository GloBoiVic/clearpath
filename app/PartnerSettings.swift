import SwiftUI

private struct PartnerCopy: Decodable {
    var settings: [String: String]

    static let bundled: PartnerCopy? = {
        guard let url = Bundle.main.url(forResource: "partner-copy", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PartnerCopy.self, from: data)
    }()

    subscript(key: String) -> String { settings[key] ?? key }
}

private enum PartnerRole: String, CaseIterable, Identifiable {
    case primary, backup
    var id: String { rawValue }
}

private struct InvitationSlot: Decodable {
    enum Status: String, Decodable {
        case empty, pending, expired, accepted
    }

    let email: String?
    let revision: Int
    let status: Status
}

private struct InvitationClient {
    enum Failure: Error {
        case unavailable, conflict, invalidEmail
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func request(_ path: String, body: Data? = nil) async throws -> Data {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["CLEARPATH_PARTNER_STATE"],
              let port = UInt16(env["CLEARPATH_PARTNER_PORT"] ?? "8765"), port > 0,
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw Failure.unavailable
        }
        let keyFile = URL(fileURLWithPath: directory).appendingPathComponent("owner-key")
        let key = try String(contentsOf: keyFile, encoding: .ascii)
        guard key.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw Failure.unavailable
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await Self.session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case body == nil ? 200 : 201: return data
        case 400 where body != nil: throw Failure.invalidEmail
        case 409: throw Failure.conflict
        default: throw Failure.unavailable
        }
    }

    func status() async throws -> [String: InvitationSlot] {
        let data = try await request("/partners")
        let slots = try JSONDecoder().decode([String: InvitationSlot].self, from: data)
        guard Set(slots.keys) == Set(PartnerRole.allCases.map(\.rawValue)) else {
            throw Failure.unavailable
        }
        return slots
    }

    func invite(_ role: PartnerRole, email: String, revision: Int) async throws {
        struct Submission: Encodable {
            let email: String
            let revision: Int
        }
        let body = try JSONEncoder().encode(Submission(email: email, revision: revision))
        _ = try await request("/partners/\(role.rawValue)", body: body)
    }
}

struct PartnerSettings: View {
    @State private var slots: [String: InvitationSlot] = [:]
    @State private var email: [PartnerRole: String] = [:]
    @State private var busy = false
    @State private var feedback: String?
    private let client = InvitationClient()

    var body: some View {
        Group {
            if let copy = PartnerCopy.bundled {
                Form {
                    ForEach(PartnerRole.allCases) { role in
                        Section(copy[role.rawValue]) {
                            if let slot = slots[role.rawValue] {
                                row(role, slot: slot, copy: copy)
                            }
                            if role == .backup {
                                Text(copy["recommendation"]).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let feedback {
                        Text(copy[feedback]).foregroundStyle(.secondary)
                    }
                    Button(copy["refresh"]) { Task { await refresh() } }
                }
                .formStyle(.grouped)
                .disabled(busy)
                .task { await refresh() }
            }
        }
        .frame(width: 440)
    }

    private func row(_ role: PartnerRole, slot: InvitationSlot, copy: PartnerCopy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(copy[slot.status.rawValue], systemImage: slot.status == .accepted
                  ? "checkmark.circle" : "envelope")
                .foregroundStyle(.secondary)
            if slot.status == .accepted {
                Text(slot.email ?? "")
            } else {
                let address = Binding(get: { email[role] ?? "" },
                                      set: { email[role] = $0 })
                TextField(copy["email"], text: address)
                    .textContentType(.emailAddress)
                Button(copy[slot.status == .empty ? "send" : "replace"]) {
                    let value = address.wrappedValue
                    Task { await submit(role, email: value, slot: slot) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.wrappedValue.isEmpty)
            }
        }
    }

    @MainActor private func loadStatus() async throws {
        slots = try await client.status()
        for role in PartnerRole.allCases {
            email[role] = slots[role.rawValue]?.email ?? ""
        }
        feedback = nil
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await loadStatus()
        } catch {
            slots = [:]
            feedback = "failure"
        }
    }

    @MainActor private func submit(_ role: PartnerRole, email: String, slot: InvitationSlot) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.invite(role, email: email, revision: slot.revision)
            try await loadStatus()
        } catch InvitationClient.Failure.invalidEmail {
            feedback = "invalidEmail"
        } catch InvitationClient.Failure.conflict {
            slots = [:]
            feedback = "conflict"
        } catch {
            slots = [:]
            feedback = "failure"
        }
    }
}
