import AppKit
import SwiftUI

// Only synthetic states are available in the design prototype.
enum Sample: String {
    case connected, unknown, failed

    var headline: String {
        switch self {
        case .connected: return "Protection is on"
        case .unknown: return "Protection status unknown"
        case .failed: return "Protection is offline"
        }
    }

    var partner: String { self == .unknown ? "Not connected" : "Connected" }
}

struct Panel: View {
    let sample: Sample
    @Environment(\.openWindow) private var openWindow
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clearpath").font(.headline)
                Spacer()
                Text("Design preview").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: sample == .connected ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(sample == .connected ? Color.green : Color.orange)
                Text(sample.headline)
            }
            .font(.system(size: 17, weight: .semibold))
            row("Partner", icon: "person.2", value: sample.partner)
            row("Pending requests", icon: "tray", value: "None")
            Divider()
            if sample == .failed {
                Text("Restoring internet alerts your partner.").foregroundStyle(.secondary)
            }
            Button {
                notice = sample == .failed ? "Restore internet" : "Block a site"
            } label: {
                Label(sample == .failed ? "Restore internet" : "Block a site",
                      systemImage: sample == .failed ? "network" : "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            destination("Blocked sites", icon: "globe")
            destination("Partner settings", icon: "person.crop.circle") {
                openWindow(id: "partner-settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(16)
        .frame(width: 320)
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: {
            Text("This action is available only in the finished app.")
        }
    }

    private func row(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func destination(_ title: String, icon: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else { notice = title }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct PathShield: View {
    let sample: Sample

    var body: some View {
        ZStack {
            Image(systemName: sample == .unknown ? "shield" : "shield.fill")
            if sample == .connected {
                Path { path in
                    path.move(to: CGPoint(x: 10, y: 3))
                    path.addQuadCurve(to: CGPoint(x: 10, y: 9), control: CGPoint(x: 2, y: 6))
                    path.addQuadCurve(to: CGPoint(x: 7, y: 15), control: CGPoint(x: 16, y: 11))
                }.stroke(lineWidth: 1.4).blendMode(.destinationOut)
            } else {
                Text(sample == .failed ? "!" : "?").font(.system(size: 9, weight: .bold))
                    .blendMode(sample == .failed ? .destinationOut : .normal)
            }
        }.frame(width: 18, height: 18).compositingGroup()
    }
}

@main
struct ClearpathApp: App {
    let sample = Sample(rawValue: ProcessInfo.processInfo.environment["CLEARPATH_SAMPLE"] ?? "connected") ?? .unknown

    var body: some Scene {
        MenuBarExtra {
            Panel(sample: sample)
        } label: {
            PathShield(sample: sample)
                .accessibilityLabel("Clearpath design preview. \(sample.headline). Partner: \(sample.partner)")
        }.menuBarExtraStyle(.window)
        Window("Partner settings", id: "partner-settings") {
            PartnerSettings()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
