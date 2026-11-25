import SwiftUI

struct InstalledSiteBlocks: Decodable, Sendable {
    let custom: [String]
    let adult: [String]
    let allow: [String]
}

@MainActor
final class SiteBlockModel: ObservableObject {
    @Published private(set) var rules: InstalledSiteBlocks?
    @Published private(set) var listError: String?
    @Published private(set) var busy = false
    @Published private(set) var addMessage: String?

    func refresh() async {
        guard !busy else { return }
        busy = true
        await readRules()
        busy = false
    }

    func add(_ domain: String) async -> Bool {
        guard !busy, !domain.isEmpty else { return false }
        guard domain.utf8.count <= 1024 else {
            addMessage = "Enter a domain such as example.com."
            return false
        }
        busy = true
        addMessage = nil
        let result = await Task.detached(priority: .userInitiated) {
            SiteBlockCommand.run(["block-site"], input: Data(domain.utf8))
        }.value
        let message = result?.text.trimmingCharacters(in: .newlines) ?? ""
        let saved = result?.status == 0
        addMessage = saved ? "Added \(message)." :
            (message.isEmpty ? "Clearpath couldn’t add the site. Check Set up protection." : message)
        if saved { await readRules() }
        busy = false
        return saved
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

    static func run(_ arguments: [String], input: Data? = nil) -> Self? {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "clearpath-service") else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            if let input, let pipe = inputPipe {
                defer { try? pipe.fileHandleForWriting.close() }
                try pipe.fileHandleForWriting.write(contentsOf: input)
            }
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
                    Section("Sites you added") {
                        if rules.custom.isEmpty { Text("No sites added yet.").foregroundStyle(.secondary) }
                        domains(rules.custom)
                    }
                    Section("Adult list rules") {
                        if rules.adult.isEmpty { Text("No adult list rules.").foregroundStyle(.secondary) }
                        domains(rules.adult)
                    }
                    if !rules.allow.isEmpty {
                        Section("Adult list exceptions") { domains(rules.allow) }
                    }
                }
                .listStyle(.inset)
            } else if let error = model.listError {
                Text(error).foregroundStyle(.secondary).padding()
            } else {
                ProgressView("Loading blocked sites…")
            }
            HStack {
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
            }
            .padding()
        }
        .frame(minWidth: 440, maxWidth: 440, minHeight: 320)
        .task { await model.refresh() }
    }

    private func domains(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { Text($0).textSelection(.enabled) }
    }
}
