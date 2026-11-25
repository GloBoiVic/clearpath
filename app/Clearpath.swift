import AppKit
import SwiftUI

struct Panel: View {
    @ObservedObject var health: ProtectionHealth
    @ObservedObject var siteBlocks: SiteBlockModel
    let openBlockSite: () -> Void
    let openBlockedSites: () -> Void
    let openPartnerSettings: () -> Void
    let openSetup: () -> Void
    let openUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clearpath").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: health.state == .protected ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(health.state == .protected ? Color.green : Color.orange)
                Text(health.state.headline)
            }
            .font(.system(size: 17, weight: .semibold))
            row("Partner", icon: "person.2", value: "See settings")
            row("Pending requests", icon: "tray", value: siteBlocks.pendingCount.map(String.init) ?? "Unavailable")
            Divider()
            if health.state == .restored {
                Text("DNS filtering is off.").foregroundStyle(.secondary)
            }
            if health.restoreFailed {
                Text("Clearpath couldn’t confirm that DNS was restored.").foregroundStyle(.secondary)
            }
            if health.state.offersRestore {
                if health.restoreAvailable {
                    Text("Administrator approval is required. Clearpath records a restore event for partner alerts.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Restore internet is unavailable for this service installation. See Set up protection.")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                if health.state.offersRestore {
                    Task { await health.restore() }
                } else {
                    openBlockSite()
                }
            } label: {
                let restoring = health.state.offersRestore || health.state == .restoring
                Label(restoring ? "Restore internet" : "Block a site", systemImage: restoring ? "network" : "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(health.state == .restoring || (health.state.offersRestore && !health.restoreAvailable))
            destination("Blocked sites", icon: "globe", action: openBlockedSites)
            destination("Partner settings", icon: "person.crop.circle", action: openPartnerSettings)
            destination("Set up protection", icon: "gearshape", action: openSetup)
            if SetupInstaller.runningFromApplications {
                destination("Leave Clearpath", icon: "rectangle.portrait.and.arrow.right", action: openUninstall)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func row(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func destination(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The menu-bar mark: a path through a shield, drawn as a template image so the menu bar tints it.
func shieldImage(for state: ProtectionState) -> NSImage {
    let filled = state == .protected || state == .offline || state == .interrupted
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        guard let context = NSGraphicsContext.current else { return false }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let symbol = NSImage(systemSymbolName: filled ? "shield.fill" : "shield",
                                accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: (18 - size.width) / 2, y: (18 - size.height) / 2,
                                   width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if state == .protected {
            context.compositingOperation = .destinationOut
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 10, y: 3))
            path.curve(to: NSPoint(x: 10, y: 9), controlPoint: NSPoint(x: 2, y: 6))
            path.curve(to: NSPoint(x: 7, y: 15), controlPoint: NSPoint(x: 16, y: 11))
            path.lineWidth = 1.4
            path.stroke()
        } else {
            if filled { context.compositingOperation = .destinationOut }
            let mark = NSAttributedString(string: state == .unknown ? "?" : "!", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.black,
            ])
            let size = mark.size()
            mark.draw(at: NSPoint(x: (18 - size.width) / 2, y: (18 - size.height) / 2))
        }
        return true
    }
    image.isTemplate = true
    return image
}
