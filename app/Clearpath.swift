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
    let openPartnerSettings: () -> Void
    let openSetup: () -> Void
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
            destination("Partner settings", icon: "person.crop.circle", action: openPartnerSettings)
            destination("Set up protection", icon: "gearshape", action: openSetup)
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

/// The menu-bar mark: a path through a shield, drawn as a template image so the menu bar tints it.
func shieldImage(for sample: Sample) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        guard let context = NSGraphicsContext.current else { return false }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let symbol = NSImage(systemSymbolName: sample == .unknown ? "shield" : "shield.fill",
                                accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: (18 - size.width) / 2, y: (18 - size.height) / 2,
                                   width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if sample == .connected {
            context.compositingOperation = .destinationOut
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 10, y: 3))
            path.curve(to: NSPoint(x: 10, y: 9), controlPoint: NSPoint(x: 2, y: 6))
            path.curve(to: NSPoint(x: 7, y: 15), controlPoint: NSPoint(x: 16, y: 11))
            path.lineWidth = 1.4
            path.stroke()
        } else {
            if sample == .failed { context.compositingOperation = .destinationOut }
            let mark = NSAttributedString(string: sample == .failed ? "!" : "?", attributes: [
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
