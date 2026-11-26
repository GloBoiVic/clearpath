import SwiftUI

struct InstalledSiteBlocks: Decodable, Sendable {
    let custom: [String]
    let allow: [String]
    let activeAdult: [String]

    private enum Keys: String, CodingKey { case custom, adult, allow }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        custom = try values.decode([String].self, forKey: .custom)
        allow = try values.decode([String].self, forKey: .allow)
        let adult = try values.decode([String].self, forKey: .adult)
        let exceptions = Set(allow)
        activeAdult = adult.filter { name in
            var suffix = name[...]
            while true {
                if exceptions.contains(String(suffix)) { return false }
                guard let dot = suffix.firstIndex(of: ".") else { return true }
                suffix = suffix[suffix.index(after: dot)...]
            }
        }
    }
}

enum SiteBlockRule: String, Decodable {
    case custom, adult
}

struct SiteRemovalRequest: Decodable, Identifiable {
    enum Outcome: String, Decodable {
        case pending, approved, denied, timedOut = "timed_out"
    }

    let id: UUID
    let domain: String
    let rule: SiteBlockRule
    let submitted: Bool
    let outcome: Outcome
    let applied: Bool
    /// Present on a solo install, where the request applies at this time.
    let deadline: Date?

    var pending: Bool { !applied && outcome != .denied }

    var status: String {
        switch outcome {
        case .pending:
            if let deadline { return "Applies \(deadline.formatted(date: .abbreviated, time: .shortened))" }
            return submitted ? "Awaiting decision or deadline" : "Waiting to reach pairing service"
        case .approved: return applied ? "Approved and applied" : "Approved, awaiting application"
        case .timedOut: return applied ? "Applied after seven days" : "Deadline passed, awaiting application"
        case .denied: return "Denied"
        }
    }
}

@MainActor
final class SiteBlockModel: ObservableObject {
    @Published private(set) var rules: InstalledSiteBlocks?
    @Published private(set) var listError: String?
    @Published private(set) var busy = false
    @Published private(set) var addMessage: String?
    @Published private(set) var requests: [SiteRemovalRequest]?
    @Published private(set) var requestError: String?
    @Published private(set) var removalMessage: String?

    var pendingCount: Int? { requests?.filter(\.pending).count }

    func refresh(includeRequests: Bool = false) async {
        guard !busy else { return }
        busy = true
        await readRules()
        if includeRequests { await readRequests() }
        busy = false
    }

    func refreshRequests() async {
        guard !busy else { return }
        busy = true
        let previouslyApplied = appliedRequests
        await readRequests()
        if rules != nil, previouslyApplied != appliedRequests { await readRules() }
        busy = false
    }

    private var appliedRequests: Set<UUID> {
        Set(requests?.filter(\.applied).map(\.id) ?? [])
    }

    func add(_ domain: String) async -> Bool {
        guard !busy, !domain.isEmpty else { return false }
        guard domain.utf8.count <= 1024, !domain.utf8.contains(0) else {
            addMessage = "Enter a domain such as example.com."
            return false
        }
        busy = true
        addMessage = nil
        let result = await Task.detached(priority: .userInitiated) {
            SiteBlockCommand.run(["block-site", domain])
        }.value
        let message = result?.text.trimmingCharacters(in: .newlines) ?? ""
        let saved = result?.status == 0
        addMessage = saved ? "Added \(message)." :
            (message.isEmpty ? "Clearpath couldn’t add the site. Check Set up protection." : message)
        if saved { await readRules() }
        busy = false
        return saved
    }

    func requestRemoval(_ domain: String, rule: SiteBlockRule) async {
        guard !busy else { return }
        busy = true
        removalMessage = nil
        let result = await Task.detached(priority: .userInitiated) {
            SiteBlockCommand.run(["request-site-removal", rule.rawValue, domain])
        }.value
        let message = result?.text.trimmingCharacters(in: .newlines) ?? ""
        if result?.status == 0 {
            removalMessage = "Removal requested for \(domain)."
        } else {
            removalMessage = message.isEmpty ? "Clearpath couldn’t request this removal." : message
        }
        await readRequests()
        busy = false
    }

    private func readRequests() async {
        let result = await Task.detached(priority: .userInitiated) {
            SiteBlockCommand.run(["site-removals"])
        }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        requests = result.flatMap {
            $0.status == 0 ? try? decoder.decode([SiteRemovalRequest].self, from: $0.data) : nil
        }
        requestError = requests == nil ? "Site removal requests are unavailable. Check Set up protection and the pairing service." : nil
    }

    private func readRules() async {
        let result = await Task.detached(priority: .userInitiated) {
            SiteBlockCommand.run(["blocked-sites"])
        }.value
        if let result, result.status == 0 {
            rules = try? JSONDecoder().decode(InstalledSiteBlocks.self, from: result.data)
        } else {
            rules = nil
        }
        listError = rules == nil ? "Blocked sites couldn’t be loaded. Check Set up protection and try again." : nil
    }
}

private struct SiteBlockCommand: Sendable {
    let status: Int32
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }

    static func run(_ arguments: [String]) -> Self? {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "clearpath-service") else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Self(status: process.terminationStatus, data: data)
        } catch {
            return nil
        }
    }
}

struct BlockSiteView: View {
    @ObservedObject var model: SiteBlockModel
    @FocusState private var domainFocused: Bool
    @State private var domain = ""

    var body: some View {
        Form {
            Section {
                TextField("Domain", text: $domain, prompt: Text("example.com"))
                    .focused($domainFocused)
                Button("Add block") {
                    let input = domain
                    Task {
                        if await model.add(input), domain == input { domain = "" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || domain.isEmpty)
                if let message = model.addMessage { Text(message).textSelection(.enabled) }
            } footer: {
                Text("A block covers the domain and its subdomains.")
            }
            Section("Mixed sites") {
                shortcut("Reddit", domain: "reddit.com")
                shortcut("X", domain: "x.com")
                shortcut("Tumblr", domain: "tumblr.com")
            }
            Section("Other search engines") {
                shortcut("Brave Search", domain: "search.brave.com")
                shortcut("Startpage", domain: "startpage.com")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, maxWidth: 440, minHeight: 360)
        .task {
            domainFocused = true
            await model.refresh()
        }
    }

    private func shortcut(_ name: String, domain: String) -> some View {
        let added = model.rules?.custom.contains(domain) == true
        return HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(domain).foregroundStyle(.secondary)
            }
            Spacer()
            Button(added ? "Added" : "Block") { Task { await model.add(domain) } }
                .accessibilityLabel(added ? "\(name) block added" : "Block \(name)")
                .disabled(model.busy || added)
        }
    }
}

struct BlockedSitesView: View {
    @ObservedObject var model: SiteBlockModel

    var body: some View {
        VStack {
            if let rules = model.rules {
                List {
                    requests
                    Section("Sites you added") {
                        if rules.custom.isEmpty { Text("No sites added yet.").foregroundStyle(.secondary) }
                        domains(rules.custom, rule: .custom)
                    }
                    Section("Adult list rules") {
                        let active = rules.activeAdult
                        if active.isEmpty { Text("No adult list rules.").foregroundStyle(.secondary) }
                        domains(active, rule: .adult)
                    }
                    if !rules.allow.isEmpty {
                        Section("Adult list exceptions") {
                            ForEach(rules.allow, id: \.self) { Text($0).textSelection(.enabled) }
                        }
                    }
                }
                .listStyle(.inset)
            } else if let error = model.listError {
                Text(error).foregroundStyle(.secondary).padding()
            } else {
                ProgressView("Loading blocked sites…")
            }
            HStack {
                if let message = model.removalMessage {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh(includeRequests: true) } }.disabled(model.busy)
            }
            .padding()
        }
        .frame(minWidth: 440, maxWidth: 440, minHeight: 320)
        .task {
            await model.refresh(includeRequests: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { await model.refreshRequests() }
            }
        }
    }

    private var requests: some View {
        Section("Removal requests") {
            if let requests = model.requests {
                if requests.isEmpty { Text("No removal requests.").foregroundStyle(.secondary) }
                ForEach(requests.reversed()) { request in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.domain).textSelection(.enabled)
                        let rule = request.rule == .custom ? "Custom block" : "Adult list rule"
                        Text("\(rule) · \(request.status)").foregroundStyle(.secondary)
                    }
                }
            } else if let error = model.requestError {
                Text(error).foregroundStyle(.secondary)
            }
        }
    }

    private func domains(_ names: [String], rule: SiteBlockRule) -> some View {
        let pending = Set(model.requests?.filter { $0.pending && $0.rule == rule }.map(\.domain) ?? [])
        return ForEach(names, id: \.self) { domain in
            HStack {
                Text(domain).textSelection(.enabled)
                Spacer()
                if pending.contains(domain) {
                    Text("Requested").foregroundStyle(.secondary)
                } else {
                    Button("Request removal") { Task { await model.requestRemoval(domain, rule: rule) } }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Request removal of \(domain)")
                        .disabled(model.busy || model.requests == nil)
                }
            }
        }
    }
}
