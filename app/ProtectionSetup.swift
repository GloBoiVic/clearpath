import AppKit
import SwiftUI

struct ProtectionSetup: View {
    private let profile = Bundle.main.url(forResource: "Clearpath Browser Policies", withExtension: "mobileconfig")
    @State private var status = "Check whether the filter is installed, answering, and configured for system DNS."
    @State private var checkedAt: Date?
    @State private var checking = false

    var body: some View {
        Form {
            Section("DNS filter") {
                Text("Use the local install guide to build and install the Clearpath filter with your DNS policy.")
                Link("Open the local install guide",
                     destination: URL(string: "https://github.com/GloBoiVic/clearpath/blob/main/README.md#filter-service-disposable-vm-only")!)
                Text(status)
                HStack {
                    Button("Check DNS status", action: checkStatus).disabled(checking)
                    if let checkedAt {
                        Text("Last checked \(checkedAt, style: .time)").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Safari") {
                Text("iCloud Private Relay can bypass Clearpath in Safari. If it’s on, turn it off in System Settings under your Apple Account → iCloud → Private Relay.")
            }
            Section("Chrome and Firefox") {
                Text("Open the Clearpath browser profile from Finder, then approve it in System Settings → General → Device Management.")
                if let profile {
                    Button("Show browser profile in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([profile])
                    }
                } else {
                    Text("The Clearpath browser profile is missing from this build.")
                        .foregroundStyle(.secondary)
                }
                Text("Restart both browsers. In Chrome, open chrome://policy and verify DnsOverHttpsMode is off and ForceGoogleSafeSearch is true. In Firefox, open about:policies and verify DNSOverHTTPS is disabled and locked.")
                    .textSelection(.enabled)
                Text("To undo this step, remove only Clearpath Browser Policies in Device Management, then restart the browsers.")
                    .foregroundStyle(.secondary)
            }
            SetupPartners()
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func checkStatus() {
        checking = true
        checkedAt = nil
        status = "Checking DNS status…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FilterStatus.read()
            }.value
            status = result?.message ?? "Clearpath couldn’t read the DNS filter status."
            checkedAt = .now
            checking = false
        }
    }
}
