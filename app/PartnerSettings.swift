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

    /// A requested replacement of an accepted partner that has not been applied.
    struct Change: Decodable {
        enum Outcome: String, Decodable {
            case pending, denied
        }

        let email: String
        let outcome: Outcome
    }

    let email: String?
    let revision: Int
    let status: Status
    let change: Change?
    /// The invitation came from an approved partner change, so only a new change can redirect it.
    let approved: Bool?

    var invited: Bool { status == .pending || status == .accepted }
    /// The address can change only through a partner change request.
    var locked: Bool { status == .accepted || approved == true }
}

private struct SetupState: Decodable {
    let complete: Bool
    let solo: Bool
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
        guard let directory = env["CLEARPATH_PARTNER_STATE"] else {
            throw Failure.unavailable
        }
        let origin: URLComponents
        if let configured = env["CLEARPATH_PARTNER_ORIGIN"] {
            guard let parts = URLComponents(string: configured), parts.scheme == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.path.isEmpty, parts.query == nil, parts.fragment == nil else {
                throw Failure.unavailable
            }
            origin = parts
        } else {
            guard let port = UInt16(env["CLEARPATH_PARTNER_PORT"] ?? "8765"), port > 0,
                  let local = URLComponents(string: "http://127.0.0.1:\(port)") else {
                throw Failure.unavailable
            }
            origin = local
        }
        var endpoint = origin
        endpoint.path = path
        guard let url = endpoint.url else { throw Failure.unavailable }
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

    /// Sends a new invitation to an unaccepted slot, or asks the partners to approve replacing an accepted one.
    func invite(_ role: PartnerRole, email: String, revision: Int, change: Bool) async throws {
        struct Submission: Encodable {
            let email: String
            let revision: Int
        }
        let body = try JSONEncoder().encode(Submission(email: email, revision: revision))
        _ = try await request("/partners/\(role.rawValue)" + (change ? "/change" : ""), body: body)
    }

    func setup() async throws -> SetupState {
        try JSONDecoder().decode(SetupState.self, from: try await request("/setup"))
    }

    func finishSetup(solo: Bool) async throws {
        _ = try await request("/setup", body: try JSONEncoder().encode(["solo": solo]))
    }
}

@MainActor
private final class PartnerModel: ObservableObject {
    @Published var slots: [String: InvitationSlot] = [:]
    @Published var setup: SetupState?
    @Published var email: [PartnerRole: String] = [:]
    @Published var busy = false
    @Published var feedback: String?
    private let client = InvitationClient()

    /// No partner is invited or accepted, so finishing setup means going without one.
    var solo: Bool { !slots.values.contains(where: \.invited) }

    private func load() async throws {
        slots = try await client.status()
        setup = try await client.setup()
        for role in PartnerRole.allCases {
            let slot = slots[role.rawValue]
            email[role] = slot?.locked == true ? "" : slot?.email ?? ""
        }
        feedback = nil
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await action()
            try await load()
        } catch InvitationClient.Failure.invalidEmail {
            feedback = "invalidEmail"
        } catch InvitationClient.Failure.conflict {
            slots = [:]
            setup = nil
            feedback = "conflict"
        } catch {
            slots = [:]
            setup = nil
            feedback = "failure"
        }
    }

    func refresh() async { await perform {} }

    func submit(_ role: PartnerRole, slot: InvitationSlot) async {
        let address = email[role] ?? ""
        await perform {
            try await client.invite(role, email: address, revision: slot.revision, change: slot.locked)
        }
    }

    /// Sends an approved invitation again to the same address.
    func resend(_ role: PartnerRole, slot: InvitationSlot) async {
        await perform {
            try await client.invite(role, email: slot.email ?? "", revision: slot.revision, change: false)
        }
    }

    func finish(solo: Bool) async {
        await perform { try await client.finishSetup(solo: solo) }
    }
}

/// One partner's status, with the invitation or change request that fits it.
private struct PartnerRow: View {
    @ObservedObject var model: PartnerModel
    let role: PartnerRole
    let slot: InvitationSlot
    let copy: PartnerCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(copy[slot.status.rawValue], systemImage: slot.status == .accepted
                  ? "checkmark.circle" : "envelope")
                .foregroundStyle(.secondary)
            if slot.locked {
                Text(slot.email ?? "")
            }
            if slot.locked, slot.status != .accepted, slot.change?.outcome != .pending {
                Button(copy[slot.status == .expired ? "send" : "replace"]) {
                    Task { await model.resend(role, slot: slot) }
                }
            }
            if let change = slot.change {
                Label(copy[change.outcome == .pending ? "changePending" : "changeDenied"],
                      systemImage: change.outcome == .pending ? "clock" : "xmark.circle")
                    .foregroundStyle(.secondary)
                Text(change.email).foregroundStyle(.secondary)
            }
            if slot.change?.outcome != .pending {
                let accepted = slot.locked
                let address = Binding(get: { model.email[role] ?? "" },
                                      set: { model.email[role] = $0 })
                TextField(copy[accepted ? "changeEmail" : "email"], text: address)
                    .textContentType(.emailAddress)
                Button(copy[accepted ? "requestChange" : slot.status == .empty ? "send" : "replace"]) {
                    Task { await model.submit(role, slot: slot) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.wrappedValue.isEmpty)
            }
            if slot.locked {
                Text(copy["changeRule"]).foregroundStyle(.secondary)
            }
        }
    }
}

struct PartnerSettings: View {
    @StateObject private var model = PartnerModel()

    var body: some View {
        Group {
            if let copy = PartnerCopy.bundled {
                Form {
                    ForEach(PartnerRole.allCases) { role in
                        Section(copy[role.rawValue]) {
                            if let slot = model.slots[role.rawValue] {
                                PartnerRow(model: model, role: role, slot: slot, copy: copy)
                            }
                            if role == .backup {
                                Text(copy["recommendation"]).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let feedback = model.feedback {
                        Text(copy[feedback]).foregroundStyle(.secondary)
                    }
                    Button(copy["refresh"]) { Task { await model.refresh() } }
                }
                .formStyle(.grouped)
                .disabled(model.busy)
                .task { await model.refresh() }
            }
        }
        .frame(width: 440)
    }
}

/// The Partners section of Setup: invite partners, then finish setup with or without one.
struct SetupPartners: View {
    @StateObject private var model = PartnerModel()
    @State private var acknowledged = false

    var body: some View {
        if let copy = PartnerCopy.bundled {
            Section(copy["partners"]) {
                ForEach(PartnerRole.allCases) { role in
                    if let slot = model.slots[role.rawValue] {
                        Text(copy[role.rawValue]).font(.headline)
                        PartnerRow(model: model, role: role, slot: slot, copy: copy)
                    }
                }
                Text(copy["recommendation"]).foregroundStyle(.secondary)
                if let setup = model.setup {
                    if setup.complete {
                        Label(copy["complete"], systemImage: "lock")
                    } else {
                        Text(copy["soloWarning"]).foregroundStyle(.secondary)
                        let solo = model.solo
                        if solo {
                            Toggle(copy["soloAcknowledge"], isOn: $acknowledged)
                        }
                        Button(copy["finish"]) { Task { await model.finish(solo: solo) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(solo && !acknowledged)
                    }
                }
                if let feedback = model.feedback {
                    Text(copy[feedback]).foregroundStyle(.secondary)
                }
                Button(copy["refresh"]) { Task { await model.refresh() } }
            }
            .disabled(model.busy)
            .task { await model.refresh() }
        }
    }
}
