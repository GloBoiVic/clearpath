import AppKit
import ServiceManagement
import SwiftUI

struct ProtectionSetup: View {
    private let profile = Bundle.main.url(forResource: "Clearpath Browser Policies", withExtension: "mobileconfig")
    @State private var filter: FilterStatus?
    @State private var location: SetupInstaller.Location?
    @State private var loginStatus = SMAppService.Status.notFound
    @State private var loginFailed = false
    @State private var feedback: String?
    @State private var checkedAt: Date?
    @State private var checking = false
    @State private var installing = false

    private var loginReadyToRegister: Bool {
        location == .installHere && filter?.protected == true && filter?.communityList != nil
    }

    var body: some View {
        Form {
            installation
            if filter?.protected == true {
                Section("Safari") {
                    Text("iCloud Private Relay can bypass Clearpath in Safari. If it’s on, turn it off in System Settings under your Apple Account → iCloud → Private Relay.")
                }
                Section("Browser profile") {
                    Text("Open the Clearpath browser profile from Finder, then approve it in System Settings → General → Device Management. It covers Safari, Chrome, Brave and Firefox.")
                    if let profile {
                        Button("Show browser profile in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([profile])
                        }
                    } else {
                        Text("The Clearpath browser profile is missing from this build.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Restart Safari, Chrome, Brave and Firefox. In Safari, Settings → Advanced shows “Use advanced tracking and fingerprinting protection” off and dimmed, so Clearpath also filters private windows. Prevent cross-site tracking stays on. In Chrome, open chrome://policy and verify DnsOverHttpsMode is off and ForceGoogleSafeSearch is true. In Brave, open brave://policy and verify the same two, and that TorDisabled is true. In Firefox, open about:policies and verify DNSOverHTTPS is disabled and locked.")
                        .textSelection(.enabled)
                    Text("To undo this step, remove only Clearpath Browser Policies in Device Management, then restart the browsers.")
                        .foregroundStyle(.secondary)
                }
            }
            if filter?.protected == true || SetupPartners.usesPartnerService { SetupPartners() }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            await checkStatus()
            if ProcessInfo.processInfo.arguments.contains(SetupInstaller.continuation), loginReadyToRegister {
                registerLoginItem()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SetupInstaller.loginItem.status
        }
    }

    private var installation: some View {
        Section("DNS filter") {
            if installing {
                ProgressView("Installing Clearpath…")
            } else if checking {
                Text("Checking DNS status…")
            } else {
                Text(filter?.message ?? "Clearpath couldn’t read the DNS filter status.")
            }
            if let feedback { Text(feedback).textSelection(.enabled) }
            switch location {
            case .copyToApplications, .installHere:
                if filter?.setupInstallAvailable == true {
                    Text("Clearpath installs in Applications and asks for your Mac password to turn on DNS protection.")
                    Button("Install Clearpath", action: install)
                        .buttonStyle(.borderedProminent)
                        .disabled(checking || installing)
                }
            case .reopenInstalledCopy:
                Button("Open Clearpath in Applications") { Task { await reopenInstalledCopy() } }
                    .disabled(checking || installing)
            case .conflict:
                Text("A different item already exists at Applications → Clearpath. Open that app from Finder or move the item before retrying.")
            case .unverified:
                Text("This build of Clearpath could not be verified. Build a fresh copy before installing.")
            default:
                EmptyView()
            }
            if location == .installHere && filter?.protected == true {
                LabeledContent("Open at login", value: loginStatus == .enabled ? "On" : "Off")
                if loginStatus == .requiresApproval {
                    Button("Open Login Items Settings", action: SMAppService.openSystemSettingsLoginItems)
                } else if loginReadyToRegister && loginStatus != .enabled {
                    Button("Enable open at login", action: registerLoginItem)
                }
                if loginFailed, loginStatus != .enabled, loginStatus != .requiresApproval {
                    Text("Clearpath couldn’t register to open at login. Try again.")
                }
            }
            HStack {
                Button("Check DNS status") { Task { await checkStatus() } }.disabled(checking || installing)
                if let checkedAt {
                    Text("Last checked \(checkedAt, style: .time)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func checkStatus() async {
        guard !checking else { return }
        checking = true
        let result = await Task.detached(priority: .userInitiated) {
            (FilterStatus.read(), SetupInstaller.location())
        }.value
        filter = result.0
        location = result.1
        loginStatus = SetupInstaller.loginItem.status
        checkedAt = .now
        checking = false
    }

    private func install() {
        guard let location, !installing, !checking, filter?.setupInstallAvailable == true else { return }
        feedback = nil
        installing = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { SetupInstaller.install(at: location) }.value
            switch outcome {
            case .installed:
                if location == .copyToApplications {
                    await reopenInstalledCopy()
                }
            case .cancelled:
                feedback = "Installation canceled. Clearpath made no changes to this Mac."
            case .failed(let message):
                feedback = message
            }
            await checkStatus()
            if case .installed = outcome, loginReadyToRegister { registerLoginItem() }
            installing = false
        }
    }

    private func reopenInstalledCopy() async {
        do {
            try await SetupInstaller.reopenInApplications()
        } catch {
            feedback = "Clearpath couldn’t reopen from Applications. Open Clearpath from Finder to continue setup."
        }
    }

    private func registerLoginItem() {
        let service = SetupInstaller.loginItem
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register(); loginFailed = false } catch { loginFailed = true }
        }
        loginStatus = service.status
    }
}
