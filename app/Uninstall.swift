import AppKit
import ServiceManagement
import SwiftUI

struct UninstallView: View {
    @State private var confirmation = UninstallConfirmation(
        sentence: PartnerWording.uninstallSentence(solo: PartnerWording.currentSolo))
    @State private var running = false
    @State private var manualProfile = false
    @State private var feedback: String?
    private let clock = ContinuousClock()

    var body: some View {
        Form {
            Section("Uninstall now") {
                Text("Clearpath will restore your previous DNS settings and remove the filter, browser profile, and app. If a partner service is configured, Clearpath saves an uninstall event for your partner.")
                Text("Type this sentence to start the 60-second countdown.")
                Text(confirmation.sentence).fontWeight(.semibold)
                TextField("Confirmation sentence", text: Binding(
                    get: { confirmation.text },
                    set: { confirmation.update($0, at: clock.now) }
                ))
                .disabled(running)

                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let now = clock.now
                    if let seconds = confirmation.secondsRemaining(at: now), seconds > 0 {
                        Text("\(seconds) seconds remaining").monospacedDigit().foregroundStyle(.secondary)
                    }
                    if running {
                        ProgressView("Uninstalling Clearpath…")
                    } else {
                        Button(manualProfile ? "Check profile and continue" : "Uninstall now", role: .destructive, action: uninstall)
                            .disabled(!confirmation.allowsAuthorization(at: now))
                    }
                }
                Text("macOS will ask for administrator approval.").foregroundStyle(.secondary)
            }
            if manualProfile {
                Section("Remove the browser profile") {
                    Text("Your previous DNS settings are restored. Remove the browser profile to finish uninstalling.")
                    Text("In System Settings → General → Device Management, select Clearpath Browser Policies and click Remove. Then return here and choose Check profile and continue.")
                    Text("Profile identifier: io.clearpath.browser-policy.v1").textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
            if let feedback {
                Section { Text(feedback).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func uninstall() {
        guard !running, confirmation.allowsAuthorization(at: clock.now) else { return }
        running = true
        feedback = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { SetupInstaller.authorizeUninstall() }.value
            running = false
            switch result {
            case .completed("removed"):
                let alert = NSAlert()
                alert.messageText = "Clearpath was uninstalled"
                alert.informativeText = "Your previous DNS settings were restored. Restart Chrome, Brave and Firefox if they were open."
                alert.addButton(withTitle: "Done")
                alert.runModal()
                NSApp.terminate(nil)
            case .completed("remove-browser-profile"):
                manualProfile = true
            case .cancelled:
                feedback = "Administrator approval was canceled. You can try again here."
            case .failed(let message):
                feedback = message
            case .completed:
                feedback = "Clearpath couldn’t confirm that uninstall finished. Try again."
            }
        }
    }
}

enum UninstallLoginItem {
    static let argument = "--unregister-login-item"

    /// The privileged helper invokes this in the signed-in user's GUI session, before taking the app away.
    static func run() -> Int32 {
        guard getuid() != 0, geteuid() == getuid(), SetupInstaller.runningFromApplications,
              let domain = Bundle.main.bundleIdentifier else { return 1 }
        let item = SetupInstaller.loginItem
        do { try item.unregister() } catch {
            guard item.status == .notRegistered || item.status == .notFound else { return 1 }
        }
        guard item.status == .notRegistered || item.status == .notFound else { return 1 }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        print("unregistered")
        return 0
    }
}
